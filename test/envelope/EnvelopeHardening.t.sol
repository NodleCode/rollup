// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

// Hardening tests added during the OZ-v5 / ZkSync-aligned refactor of the vendored vault.
// Each test maps back to a finding in the audit:
//   T1 — direct ERC721 / ERC1155 transfers must revert (fix for S1 receivers footgun)
//   T2 — mfaAuthorizer is now a per-deploy constructor arg (fix for S3 hardcoded key)

import {Test} from "forge-std/Test.sol";
import {EnvelopeVault} from "../../src/envelope/V4/EnvelopeVault.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC721Mock} from "./mocks/ERC721Mock.sol";
import {ERC1155Mock} from "./mocks/ERC1155Mock.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract EnvelopeHardeningTest is Test, ERC721Holder, ERC1155Holder {
    EnvelopeVault public vault;
    ERC721Mock public erc721;
    ERC1155Mock public erc1155;

    address constant ALICE = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    address constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);

    function setUp() public {
        vault = new EnvelopeVault(address(0), address(this));
        erc721 = new ERC721Mock();
        erc1155 = new ERC1155Mock();
    }

    receive() external payable {}

    // ── T1 ─────────────────────────────────────────────────────────────────
    // Direct safeTransferFrom into EnvelopeVault must revert (S1). Previously the
    // receiver hooks fell off the end and returned bytes4(0); some token
    // implementations would treat that as accepted, leaving tokens stuck.

    function test_T1_directERC721TransferReverts() public {
        erc721.mint(address(this), 42);
        vm.expectRevert(EnvelopeVault.DirectTransfersNotAllowed.selector);
        erc721.safeTransferFrom(address(this), address(vault), 42);
    }

    function test_T1_directERC1155TransferReverts() public {
        erc1155.mint(address(this), 7, 1, "");
        vm.expectRevert(EnvelopeVault.DirectTransfersNotAllowed.selector);
        erc1155.safeTransferFrom(address(this), address(vault), 7, 1, "");
    }

    function test_T1_directERC1155BatchTransferReverts() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        amounts[0] = 1; amounts[1] = 1;
        erc1155.mint(address(this), 1, 1, "");
        erc1155.mint(address(this), 2, 1, "");
        vm.expectRevert(EnvelopeVault.DirectTransfersNotAllowed.selector);
        erc1155.safeBatchTransferFrom(address(this), address(vault), ids, amounts, "");
    }

    // ── T2 ─────────────────────────────────────────────────────────────────
    // mfaAuthorizer is now per-deploy. Prove a freshly-deployed EnvelopeVault
    // accepts MFA signatures from a *test* signer rather than the upstream key.

    function test_T2_customMfaAuthorizerAcceptsItsSignature() public {
        uint256 mfaPrivKey = uint256(keccak256("nodle.vault.mfa-test-signer"));
        address mfaSigner = vm.addr(mfaPrivKey);

        EnvelopeVault nodleVault = new EnvelopeVault(mfaSigner, address(this));
        assertEq(nodleVault.mfaAuthorizer(), mfaSigner, "constructor arg ignored");

        // make an MFA-gated deposit, then craft both signatures with our test keys.
        uint256 depositPrivKey = uint256(keccak256("nodle.vault.deposit-key"));
        address depositSigner = vm.addr(depositPrivKey);

        uint256 idx = nodleVault.makeSelflessMFADeposit{value: 1 wei}(
            address(0), 0, 1, 0, depositSigner, address(this)
        );

        // withdrawal signature (signed by deposit pubkey)
        bytes32 wdHash = MessageHashUtilsLite.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    nodleVault.ENVELOPE_SALT(),
                    block.chainid,
                    address(nodleVault),
                    idx,
                    address(this),
                    nodleVault.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 wv, bytes32 wr, bytes32 ws) = vm.sign(depositPrivKey, wdHash);
        bytes memory wdSig = abi.encodePacked(wr, ws, wv);

        // MFA signature (signed by configured mfaAuthorizer, includes fee amounts)
        uint256 serviceFee = 0;
        uint256 gasAbsorptionFee = 0;
        uint256 deadline = 0; // no expiry
        bytes32 mfaHash = MessageHashUtilsLite.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    nodleVault.ENVELOPE_SALT(),
                    block.chainid,
                    address(nodleVault),
                    idx,
                    address(this),
                    serviceFee,
                    gasAbsorptionFee,
                    deadline
                )
            )
        );
        (uint8 mv, bytes32 mr, bytes32 ms) = vm.sign(mfaPrivKey, mfaHash);
        bytes memory mfaSig = abi.encodePacked(mr, ms, mv);

        nodleVault.withdrawMFADeposit(idx, address(this), wdSig, mfaSig, serviceFee, gasAbsorptionFee, 0);
    }

    function test_T2_zeroMfaAuthorizerRejectsAllMfaWithdrawals() public {
        // vault deployed with mfaAuthorizer = address(0). Any MFA withdrawal must fail.
        uint256 depositPrivKey = uint256(keccak256("dep"));
        address depositSigner = vm.addr(depositPrivKey);

        uint256 idx = vault.makeSelflessMFADeposit{value: 1 wei}(
            address(0), 0, 1, 0, depositSigner, address(this)
        );

        // empty/garbage MFA sig must not pass when authorizer is 0
        bytes memory wdSig = hex"00";
        bytes memory mfaSig = hex"00";
        vm.expectRevert();
        vault.withdrawMFADeposit(idx, address(this), wdSig, mfaSig, 0, 0, 0);
    }
}

/// @dev Local copy of OZ's MessageHashUtils.toEthSignedMessageHash to avoid pulling
/// the full library into a test-only file.
library MessageHashUtilsLite {
    function toEthSignedMessageHash(bytes32 messageHash) internal pure returns (bytes32 digest) {
        assembly ("memory-safe") {
            mstore(0x00, "\x19Ethereum Signed Message:\n32")
            mstore(0x1c, messageHash)
            digest := keccak256(0x00, 0x3c)
        }
    }
}

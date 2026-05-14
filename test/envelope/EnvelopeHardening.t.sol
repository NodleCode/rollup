// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

// Hardening tests added during the OZ-v5 / ZkSync-aligned refactor of Peanut V4.4.
// Each test maps back to a finding in the audit:
//   T1 — direct ERC721 / ERC1155 transfers must revert (fix for S1 receivers footgun)
//   T2 — MFA_AUTHORIZER is now a per-deploy constructor arg (fix for S3 hardcoded key)
//   T4 — _storeDeposit rejects deposits with no withdrawal authority (fix for S4)
//   T5 — _withdrawDeposit L2ECO branch sends to recipient, not sender (upstream bug fix)

import {Test} from "forge-std/Test.sol";
import {EnvelopeVault} from "../../src/envelope/V4/PeanutV4.4.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC721Mock} from "./mocks/ERC721Mock.sol";
import {ERC1155Mock} from "./mocks/ERC1155Mock.sol";
import {L2ECOMock} from "./mocks/L2ECOMock.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract PeanutHardeningTest is Test, ERC721Holder, ERC1155Holder {
    EnvelopeVault public peanut;
    ERC721Mock public erc721;
    ERC1155Mock public erc1155;

    address constant ALICE = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    address constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);

    function setUp() public {
        peanut = new EnvelopeVault(address(0), address(0));
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
        vm.expectRevert("DIRECT TRANSFERS NOT ALLOWED");
        erc721.safeTransferFrom(address(this), address(peanut), 42);
    }

    function test_T1_directERC1155TransferReverts() public {
        erc1155.mint(address(this), 7, 1, "");
        vm.expectRevert("DIRECT TRANSFERS NOT ALLOWED");
        erc1155.safeTransferFrom(address(this), address(peanut), 7, 1, "");
    }

    function test_T1_directERC1155BatchTransferReverts() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        amounts[0] = 1; amounts[1] = 1;
        erc1155.mint(address(this), 1, 1, "");
        erc1155.mint(address(this), 2, 1, "");
        vm.expectRevert("DIRECT TRANSFERS NOT ALLOWED");
        erc1155.safeBatchTransferFrom(address(this), address(peanut), ids, amounts, "");
    }

    // ── T2 ─────────────────────────────────────────────────────────────────
    // MFA_AUTHORIZER is now per-deploy. Prove a freshly-deployed EnvelopeVault
    // accepts MFA signatures from a *test* signer rather than the upstream key.

    function test_T2_customMfaAuthorizerAcceptsItsSignature() public {
        uint256 mfaPrivKey = uint256(keccak256("nodle.peanut.mfa-test-signer"));
        address mfaSigner = vm.addr(mfaPrivKey);

        EnvelopeVault nodlePeanut = new EnvelopeVault(address(0), mfaSigner);
        assertEq(nodlePeanut.MFA_AUTHORIZER(), mfaSigner, "constructor arg ignored");

        // make an MFA-gated deposit, then craft both signatures with our test keys.
        uint256 depositPrivKey = uint256(keccak256("nodle.peanut.deposit-key"));
        address depositSigner = vm.addr(depositPrivKey);

        uint256 idx = nodlePeanut.makeSelflessMFADeposit{value: 1 wei}(
            address(0), 0, 1, 0, depositSigner, address(this)
        );

        // withdrawal signature (signed by deposit pubkey)
        bytes32 wdHash = MessageHashUtilsLite.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    nodlePeanut.PEANUT_SALT(),
                    block.chainid,
                    address(nodlePeanut),
                    idx,
                    address(this),
                    nodlePeanut.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 wv, bytes32 wr, bytes32 ws) = vm.sign(depositPrivKey, wdHash);
        bytes memory wdSig = abi.encodePacked(wr, ws, wv);

        // MFA signature (signed by configured MFA_AUTHORIZER)
        bytes32 mfaHash = MessageHashUtilsLite.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    nodlePeanut.PEANUT_SALT(),
                    block.chainid,
                    address(nodlePeanut),
                    idx,
                    address(this)
                )
            )
        );
        (uint8 mv, bytes32 mr, bytes32 ms) = vm.sign(mfaPrivKey, mfaHash);
        bytes memory mfaSig = abi.encodePacked(mr, ms, mv);

        nodlePeanut.withdrawMFADeposit(idx, address(this), wdSig, mfaSig);
    }

    function test_T2_zeroMfaAuthorizerRejectsAllMfaWithdrawals() public {
        // peanut deployed with mfaAuthorizer = address(0). Any MFA withdrawal must fail.
        uint256 depositPrivKey = uint256(keccak256("dep"));
        address depositSigner = vm.addr(depositPrivKey);

        uint256 idx = peanut.makeSelflessMFADeposit{value: 1 wei}(
            address(0), 0, 1, 0, depositSigner, address(this)
        );

        // empty/garbage MFA sig must not pass when authorizer is 0
        bytes memory wdSig = hex"00";
        bytes memory mfaSig = hex"00";
        vm.expectRevert();
        peanut.withdrawMFADeposit(idx, address(this), wdSig, mfaSig);
    }

    // ── T4 ─────────────────────────────────────────────────────────────────
    // A deposit with both pubKey20 == 0 AND recipient == 0 has no auth — anyone
    // could withdraw it. The new _storeDeposit guard rejects this footgun.

    function test_T4_dualZeroDepositRejected() public {
        vm.expectRevert("DEPOSIT MUST HAVE AUTH");
        peanut.makeDeposit{value: 1 wei}(address(0), 0, 1, 0, address(0));
    }

    function test_T4_dualZeroCustomDepositRejected() public {
        vm.expectRevert("DEPOSIT MUST HAVE AUTH");
        peanut.makeCustomDeposit{value: 1 wei}(
            address(0), 0, 1, 0, address(0), address(this), false, address(0), uint40(0), false, ""
        );
    }

    function test_T4_pubKeyOnlyAccepted() public {
        uint256 idx = peanut.makeDeposit{value: 1 wei}(address(0), 0, 1, 0, PUBKEY20);
        assertEq(idx, 0);
    }

    function test_T4_recipientOnlyAccepted() public {
        uint256 idx = peanut.makeCustomDeposit{value: 1 wei}(
            address(0), 0, 1, 0, address(0), address(this), false, ALICE, uint40(0), false, ""
        );
        assertEq(idx, 0);
    }

    // ── T5 ─────────────────────────────────────────────────────────────────
    // Upstream copy-paste bug: _withdrawDeposit's contractType==4 (L2ECO) branch
    // transferred to _deposit.senderAddress instead of _recipientAddress. The
    // recipient would receive nothing while the deposit was marked claimed.
    // Patch sends to _recipientAddress (matching all other contractType branches)
    // and routes through SafeERC20 (consistent with the contractType==1 branch).

    function test_T5_L2ECOWithdrawGoesToRecipientNotSender() public {
        uint256 depositPrivKey = uint256(keccak256("l2eco-link-key"));
        address pubKey20 = vm.addr(depositPrivKey);
        uint256 senderPk = uint256(keccak256("l2eco-sender"));
        address sender = vm.addr(senderPk);
        address recipient = address(0xDECAF);

        // Multiplier = 2 → vault stores `amount * 2` (inflation-invariant).
        L2ECOMock eco = new L2ECOMock(2);
        eco.mint(sender, 100);

        vm.prank(sender);
        eco.approve(address(peanut), 100);

        vm.prank(sender);
        uint256 idx = peanut.makeDeposit(address(eco), 4, 100, 0, pubKey20);

        // Sanity: vault holds the raw tokens, deposit stores the scaled amount.
        assertEq(eco.balanceOf(address(peanut)), 100, "vault should hold raw tokens");
        assertEq(eco.balanceOf(sender), 0, "sender's tokens should be in the vault");
        EnvelopeVault.Deposit memory d = peanut.getDeposit(idx);
        assertEq(d.amount, 200, "deposit amount should be inflation-invariant (amount * multiplier)");

        // Recipient (not sender) claims using the link's private key.
        bytes32 digest = MessageHashUtilsLite.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    peanut.PEANUT_SALT(),
                    block.chainid,
                    address(peanut),
                    idx,
                    recipient,
                    peanut.ANYONE_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(depositPrivKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        peanut.withdrawDeposit(idx, recipient, sig);

        // The fix: recipient gets 100, sender stays at 0.
        // If the bug were still present, sender would have 100 and recipient 0.
        assertEq(eco.balanceOf(recipient), 100, "recipient must receive the L2ECO tokens");
        assertEq(eco.balanceOf(sender), 0, "sender must NOT receive the L2ECO tokens back");
        assertEq(eco.balanceOf(address(peanut)), 0, "vault should be drained");
    }

    function test_T5_L2ECOSenderReclaimStillGoesToSender() public {
        // Counterpart sanity: _withdrawDepositSender (sender-initiated reclaim path)
        // is correctly routed to senderAddress — we shouldn't have over-corrected.
        uint256 senderPk = uint256(keccak256("l2eco-reclaim-sender"));
        address sender = vm.addr(senderPk);
        address pubKey20 = vm.addr(uint256(keccak256("l2eco-reclaim-key")));

        L2ECOMock eco = new L2ECOMock(1);
        eco.mint(sender, 50);

        vm.prank(sender);
        eco.approve(address(peanut), 50);
        vm.prank(sender);
        uint256 idx = peanut.makeDeposit(address(eco), 4, 50, 0, pubKey20);

        assertEq(eco.balanceOf(sender), 0);

        vm.prank(sender);
        peanut.withdrawDepositSender(idx);

        assertEq(eco.balanceOf(sender), 50, "sender reclaim should return the tokens");
        assertEq(eco.balanceOf(address(peanut)), 0);
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

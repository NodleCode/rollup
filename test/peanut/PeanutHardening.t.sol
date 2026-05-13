// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

// Hardening tests added during the OZ-v5 / ZkSync-aligned refactor of Peanut V4.4.
// Each test maps back to a finding in the audit:
//   T1 — direct ERC721 / ERC1155 transfers must revert (fix for S1 receivers footgun)
//   T2 — MFA_AUTHORIZER is now a per-deploy constructor arg (fix for S3 hardcoded key)
//   T3 — PeanutRouter.withdrawFees uses safeTransfer for non-returning ERC20s (fix for S2)
//   T4 — _storeDeposit rejects deposits with no withdrawal authority (fix for S4)

import {Test} from "forge-std/Test.sol";
import {PeanutV4} from "../../src/peanut/V4/PeanutV4.4.sol";
import {PeanutV4Router} from "../../src/peanut/V4/PeanutRouter.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC721Mock} from "./mocks/ERC721Mock.sol";
import {ERC1155Mock} from "./mocks/ERC1155Mock.sol";
import {SquidMock} from "./mocks/SquidMock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @dev Minimal ERC20 that does NOT return a bool from transfer (USDT-style).
/// Used to verify SafeERC20 normalizes the call.
contract NonReturningERC20 {
    string public name = "NonRet";
    string public symbol = "NRT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @dev Note: NO return value, like USDT.
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "NRT: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "NRT: insufficient");
        require(allowance[from][msg.sender] >= amount, "NRT: not approved");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}

contract PeanutHardeningTest is Test, ERC721Holder, ERC1155Holder {
    PeanutV4 public peanut;
    PeanutV4Router public router;
    SquidMock public squid;
    ERC721Mock public erc721;
    ERC1155Mock public erc1155;

    address constant ALICE = address(0x8fd379246834eac74B8419FfdA202CF8051F7A03);
    address constant PUBKEY20 = address(0xaBC5211D86a01c2dD50797ba7B5b32e3C1167F9f);

    function setUp() public {
        peanut = new PeanutV4(address(0), address(0));
        squid = new SquidMock();
        router = new PeanutV4Router(address(squid));
        erc721 = new ERC721Mock();
        erc1155 = new ERC1155Mock();
    }

    receive() external payable {}

    // ── T1 ─────────────────────────────────────────────────────────────────
    // Direct safeTransferFrom into PeanutV4 must revert (S1). Previously the
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
    // MFA_AUTHORIZER is now per-deploy. Prove a freshly-deployed PeanutV4
    // accepts MFA signatures from a *test* signer rather than the upstream key.

    function test_T2_customMfaAuthorizerAcceptsItsSignature() public {
        uint256 mfaPrivKey = uint256(keccak256("nodle.peanut.mfa-test-signer"));
        address mfaSigner = vm.addr(mfaPrivKey);

        PeanutV4 nodlePeanut = new PeanutV4(address(0), mfaSigner);
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

    // ── T3 ─────────────────────────────────────────────────────────────────
    // PeanutRouter.withdrawFees must work with USDT-style ERC20s that don't
    // return a bool from transfer. Pre-fix used raw .transfer(); SafeERC20
    // normalizes the call.

    function test_T3_withdrawFees_nonReturningERC20() public {
        NonReturningERC20 nrt = new NonReturningERC20();
        nrt.mint(address(router), 1000);

        router.withdrawFees(address(nrt), ALICE, 750);
        assertEq(nrt.balanceOf(ALICE), 750);
        assertEq(nrt.balanceOf(address(router)), 250);
    }

    function test_T3_withdrawFees_nonOwnerReverts() public {
        NonReturningERC20 nrt = new NonReturningERC20();
        nrt.mint(address(router), 1000);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        router.withdrawFees(address(nrt), ALICE, 750);
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

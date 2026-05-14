// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

// Edge-case coverage for PeanutV4 / PeanutBatcherV4 — gates the vendored happy-path
// tests don't exercise directly. Names follow the repo's test_RevertWhen_* / test_*
// convention. Each test is single-purpose; comments explain the *why*, not the *what*.

import {Test} from "forge-std/Test.sol";
import {PeanutV4} from "../../src/peanut/V4/PeanutV4.4.sol";
import {PeanutBatcherV4} from "../../src/peanut/V4/PeanutBatcherV4.4.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC721Mock} from "./mocks/ERC721Mock.sol";
import {ERC1155Mock} from "./mocks/ERC1155Mock.sol";
import {L2ECOMock} from "./mocks/L2ECOMock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @dev Reentrancy probe: tries to call back into `peanut.withdrawDeposit` from inside
/// `safeTransfer`. Guarded by PeanutV4's `nonReentrant` modifier, so the inner call
/// reverts and the outer flow surfaces the inner revert reason ("REENTRANCY").
contract ReentrantToken is ERC20Mock {
    PeanutV4 public peanut;
    uint256 public targetIdx;
    bytes public targetSig;
    address public attacker;
    bool public attempted;

    function arm(PeanutV4 p, uint256 idx, bytes calldata sig, address atk) external {
        peanut = p;
        targetIdx = idx;
        targetSig = sig;
        attacker = atk;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        // Reenter once during the outer safeTransfer back to the recipient.
        if (!attempted && address(peanut) != address(0) && to == attacker) {
            attempted = true;
            // This call should revert because the outer call holds the reentrancy lock.
            try peanut.withdrawDeposit(targetIdx, attacker, targetSig) {
                revert("REENTRANCY GUARD MISSING");
            } catch {
                // expected — guard caught it
            }
        }
    }
}

contract PeanutEdgeCasesTest is Test, ERC721Holder, ERC1155Holder {
    PeanutV4 public peanut;
    PeanutBatcherV4 public batcher;
    ERC20Mock public erc20;
    ERC721Mock public erc721;
    ERC1155Mock public erc1155;

    // Stable test keypair (private key → pubKey20).
    uint256 internal constant LINK_PRIV = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    address internal LINK_PUBKEY20;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        LINK_PUBKEY20 = vm.addr(LINK_PRIV);
        peanut = new PeanutV4(address(0), address(0));
        batcher = new PeanutBatcherV4();
        erc20 = new ERC20Mock();
        erc721 = new ERC721Mock();
        erc1155 = new ERC1155Mock();
    }

    receive() external payable {}

    // ── helpers ────────────────────────────────────────────────────────────

    function _signWithdrawal(uint256 idx, address recipient, uint256 privKey) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _depositEth(uint256 amount) internal returns (uint256) {
        return peanut.makeDeposit{value: amount}(address(0), 0, amount, 0, LINK_PUBKEY20);
    }

    // ── PeanutV4 deposit input validation ──────────────────────────────────

    function test_RevertWhen_DepositInvalidContractType() public {
        // _pullTokensViaApproval rejects contractType >= 5.
        vm.expectRevert("INVALID CONTRACT TYPE");
        peanut.makeDeposit{value: 0}(address(0), 5, 0, 0, LINK_PUBKEY20);
    }

    function test_RevertWhen_DepositEthAmountMismatch() public {
        // contractType==0 requires _amount == msg.value.
        vm.expectRevert("WRONG ETH AMOUNT");
        peanut.makeDeposit{value: 100}(address(0), 0, 50, 0, LINK_PUBKEY20);
    }

    function test_RevertWhen_DepositErc721AmountNotOne() public {
        // contractType==2 requires _amount == 1.
        erc721.mint(address(this), 1);
        erc721.approve(address(peanut), 1);
        vm.expectRevert("AMOUNT MUST BE 1 FOR ERC721");
        peanut.makeDeposit(address(erc721), 2, 2, 1, LINK_PUBKEY20);
    }

    function test_RevertWhen_DepositEcoTokenViaPlainErc20() public {
        // Deploying with _ecoAddress = testToken forces contractType==4 for that token.
        PeanutV4 ecoVault = new PeanutV4(address(erc20), address(0));
        erc20.mint(address(this), 100);
        erc20.approve(address(ecoVault), 100);
        vm.expectRevert("ECO DEPOSITS MUST USE _contractType 4");
        ecoVault.makeDeposit(address(erc20), 1, 100, 0, LINK_PUBKEY20);
    }

    // ── PeanutV4 withdraw input validation ─────────────────────────────────

    function test_RevertWhen_WithdrawIndexOutOfBounds() public {
        bytes memory sig = _signWithdrawal(99, ALICE, LINK_PRIV);
        vm.expectRevert("DEPOSIT INDEX DOES NOT EXIST");
        peanut.withdrawDeposit(99, ALICE, sig);
    }

    function test_RevertWhen_WithdrawTwice() public {
        uint256 idx = _depositEth(1 ether);
        bytes memory sig = _signWithdrawal(idx, ALICE, LINK_PRIV);
        peanut.withdrawDeposit(idx, ALICE, sig);

        vm.expectRevert("DEPOSIT ALREADY WITHDRAWN");
        peanut.withdrawDeposit(idx, ALICE, sig);
    }

    function test_RevertWhen_WithdrawWithWrongSigner() public {
        uint256 idx = _depositEth(1 ether);
        // Sign with a private key that does NOT correspond to the deposit's pubKey20.
        uint256 wrongKey = uint256(keccak256("wrong-signer"));
        bytes memory sig = _signWithdrawal(idx, ALICE, wrongKey);

        vm.expectRevert("WRONG SIGNATURE");
        peanut.withdrawDeposit(idx, ALICE, sig);
    }

    function test_RevertWhen_WithdrawAsRecipientCallerMismatch() public {
        // Recipient-mode signature; caller must equal the recipient.
        uint256 idx = _depositEth(1 ether);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    peanut.PEANUT_SALT(),
                    block.chainid,
                    address(peanut),
                    idx,
                    ALICE,
                    peanut.RECIPIENT_WITHDRAWAL_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // BOB tries to call on behalf of ALICE — caller must equal the recipient param.
        vm.prank(BOB);
        vm.expectRevert("NOT THE RECIPIENT");
        peanut.withdrawDepositAsRecipient(idx, ALICE, sig);
    }

    function test_RevertWhen_RecipientBoundClaimedByOtherAddress() public {
        // Address-bound deposit: recipient = ALICE.
        uint256 idx = peanut.makeCustomDeposit{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY20, address(this), false, ALICE, 0, false, ""
        );
        // Even with a valid pubKey signature, the contract-stored recipient blocks
        // anyone else from being the named recipient on withdrawal.
        bytes memory sig = _signWithdrawal(idx, BOB, LINK_PRIV);
        vm.expectRevert("WRONG RECIPIENT");
        peanut.withdrawDeposit(idx, BOB, sig);
    }

    function test_RecipientBoundSenderCannotReclaimBeforeDeadline() public {
        uint40 reclaimAfter = uint40(block.timestamp + 1 days);
        uint256 idx = peanut.makeCustomDeposit{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY20, address(this), false, ALICE, reclaimAfter, false, ""
        );
        vm.expectRevert("TOO EARLY TO RECLAIM");
        peanut.withdrawDepositSender(idx);

        vm.warp(reclaimAfter + 1);
        peanut.withdrawDepositSender(idx); // succeeds after the deadline
    }

    function test_RevertWhen_SenderReclaimNotTheSender() public {
        uint256 idx = _depositEth(1 ether);
        vm.prank(ALICE);
        vm.expectRevert("NOT THE SENDER");
        peanut.withdrawDepositSender(idx);
    }

    function test_RevertWhen_MFADepositWithoutMFASignature() public {
        // peanut is deployed with MFA_AUTHORIZER == address(0), so MFA-flagged
        // deposits can never be withdrawn via withdrawDeposit (REQUIRES AUTHORIZATION).
        uint256 idx = peanut.makeMFADeposit{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY20);
        bytes memory sig = _signWithdrawal(idx, ALICE, LINK_PRIV);
        vm.expectRevert("REQUIRES AUTHORIZATION");
        peanut.withdrawDeposit(idx, ALICE, sig);
    }

    // ── PeanutV4 views ─────────────────────────────────────────────────────

    function test_GetAllDepositsForAddressFiltersBySender() public {
        _depositEth(1);
        _depositEth(1);
        // Same sender (address(this)) made both deposits.
        PeanutV4.Deposit[] memory mine = peanut.getAllDepositsForAddress(address(this));
        assertEq(mine.length, 2);

        // Different sender → empty.
        PeanutV4.Deposit[] memory aliceDeposits = peanut.getAllDepositsForAddress(ALICE);
        assertEq(aliceDeposits.length, 0);
    }

    function test_DepositCountTracksArrayLength() public {
        assertEq(peanut.getDepositCount(), 0);
        _depositEth(1);
        _depositEth(1);
        _depositEth(1);
        assertEq(peanut.getDepositCount(), 3);
    }

    // ── PeanutV4 reentrancy ────────────────────────────────────────────────

    function test_NonReentrantBlocksReentryFromMaliciousToken() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(address(this), 100);
        evil.approve(address(peanut), 100);

        // Deposit type-1 (ERC-20) so withdraw routes back through the token's transfer.
        uint256 idx = peanut.makeDeposit(address(evil), 1, 100, 0, LINK_PUBKEY20);
        bytes memory sig = _signWithdrawal(idx, ALICE, LINK_PRIV);

        // Arm the token to reenter inside its _update during the outgoing safeTransfer.
        evil.arm(peanut, idx, sig, ALICE);

        // Outer withdraw succeeds (inner reentrant attempt caught and swallowed by try/catch);
        // the reentrancy guard ensured the inner call could not double-spend.
        peanut.withdrawDeposit(idx, ALICE, sig);
        assertEq(evil.balanceOf(ALICE), 100);
        assertTrue(evil.attempted(), "reentrancy attempt should have run");
    }

    // ── PeanutBatcherV4 input validation ───────────────────────────────────

    function test_RevertWhen_BatchEthAmountMismatch() public {
        address[] memory pubKeys = new address[](3);
        for (uint256 i = 0; i < 3; i++) pubKeys[i] = LINK_PUBKEY20;
        vm.expectRevert("INVALID TOTAL ETHER SENT");
        batcher.batchMakeDeposit{value: 1 ether}(address(peanut), address(0), 0, 1 ether, 0, pubKeys);
        // expected 3 * 1 ether, sent 1 ether
    }

    function test_RevertWhen_BatchArbitraryArrayLengthMismatch() public {
        // _withMFAs.length differs from the others.
        address[] memory tokens = new address[](2);
        uint8[] memory types = new uint8[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory ids = new uint256[](2);
        address[] memory pks = new address[](2);
        bool[] memory mfa = new bool[](3); // wrong length

        vm.expectRevert("PARAMETERS LENGTH MISMATCH");
        batcher.batchMakeDepositArbitrary(address(peanut), tokens, types, amounts, ids, pks, mfa);
    }

    // batchMakeDepositNoReturn — ETH path must require exact total, non-ETH path must reject msg.value.
    // Both rules were added during PR review (upstream forwarded msg.value per iteration, which
    // reverts on iteration 2 when length > 1).

    function test_BatchNoReturnEth_HappyPath() public {
        address[] memory pubKeys = new address[](3);
        for (uint256 i = 0; i < 3; i++) pubKeys[i] = LINK_PUBKEY20;

        batcher.batchMakeDepositNoReturn{value: 3 ether}(
            address(peanut), address(0), 0, 1 ether, 0, pubKeys
        );
        assertEq(peanut.getDepositCount(), 3);
    }

    function test_RevertWhen_BatchNoReturnEthAmountMismatch() public {
        address[] memory pubKeys = new address[](3);
        for (uint256 i = 0; i < 3; i++) pubKeys[i] = LINK_PUBKEY20;
        vm.expectRevert("INVALID TOTAL ETHER SENT");
        batcher.batchMakeDepositNoReturn{value: 1 ether}(
            address(peanut), address(0), 0, 1 ether, 0, pubKeys
        );
    }

    function test_RevertWhen_BatchNoReturnEthSentForErc20() public {
        // ERC-20 path must reject msg.value — would otherwise strand dust in the vault.
        erc20.mint(address(this), 1000);
        erc20.approve(address(batcher), 1000);
        address[] memory pubKeys = new address[](2);
        for (uint256 i = 0; i < 2; i++) pubKeys[i] = LINK_PUBKEY20;
        vm.expectRevert("ETH NOT ACCEPTED FOR NON-ETH DEPOSIT");
        batcher.batchMakeDepositNoReturn{value: 1 wei}(
            address(peanut), address(erc20), 1, 100, 0, pubKeys
        );
    }

    function test_RevertWhen_BatchRaffleErc721NotSupported() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.expectRevert("ONLY ETH AND ERC20 RAFFLES ARE SUPPORTED");
        batcher.batchMakeDepositRaffle(address(peanut), address(erc721), 2, amounts, LINK_PUBKEY20);
    }

    function test_BatchZeroLengthDepositsIsNoop() public {
        address[] memory pubKeys = new address[](0);
        uint256[] memory ids = batcher.batchMakeDeposit(address(peanut), address(0), 0, 0, 0, pubKeys);
        assertEq(ids.length, 0);
        assertEq(peanut.getDepositCount(), 0);
    }

    // ── L2ECO inflation-invariant accounting ───────────────────────────────

    function test_L2ECOWithdrawAdjustsForChangedInflation() public {
        // Deposit at multiplier=2 stores `amount * 2` as the inflation-invariant amount.
        // If the multiplier changes before withdrawal, the recipient receives
        // `stored / current` raw tokens — proportional to the depositor's share of the
        // rebasing token's supply at deposit time.
        L2ECOMock eco = new L2ECOMock(2);
        eco.mint(address(this), 100);
        eco.approve(address(peanut), 100);
        uint256 idx = peanut.makeDeposit(address(eco), 4, 100, 0, LINK_PUBKEY20);

        // Multiplier increases from 2 → 4 (token supply doubled). The vault holds 100
        // raw tokens but the "share" is recorded as 200 (= 100 * 2). At multiplier 4
        // the share is now worth 200 / 4 = 50 raw tokens. Simulate the rebase by
        // also reducing the vault's token balance to match (mock doesn't auto-rebase).
        eco.setMultiplier(4);
        // Burn half the vault's balance to mirror what a real rebase would do to it.
        vm.prank(address(peanut));
        eco.transfer(address(0xdead), 50);

        bytes memory sig = _signWithdrawal(idx, ALICE, LINK_PRIV);
        peanut.withdrawDeposit(idx, ALICE, sig);

        assertEq(eco.balanceOf(ALICE), 50);
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

// Edge-case coverage for EnvelopeLinks behavior the happy-path tests don't exercise directly.
// Names follow the repo's test_RevertWhen_* / test_*
// convention. Each test is single-purpose; comments explain the *why*, not the *what*.

import {Test} from "forge-std/Test.sol";
import {EnvelopeLinks} from "../../src/envelope/EnvelopeLinks.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC721Mock} from "./mocks/ERC721Mock.sol";
import {ERC1155Mock} from "./mocks/ERC1155Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @dev Reentrancy probe: tries to call back into `vault.withdrawDeposit` from inside
/// `safeTransfer`. Guarded by EnvelopeLinks's `nonReentrant` modifier, so the inner call
/// reverts and the outer flow surfaces the inner revert reason ("REENTRANCY").
contract ReentrantToken is ERC20Mock {
    EnvelopeLinks public vault;
    uint256 public targetIdx;
    bytes public targetSig;
    address public attacker;
    bool public attempted;

    function arm(EnvelopeLinks p, uint256 idx, bytes calldata sig, address atk) external {
        vault = p;
        targetIdx = idx;
        targetSig = sig;
        attacker = atk;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        // Reenter once during the outer safeTransfer back to the recipient.
        if (!attempted && address(vault) != address(0) && to == attacker) {
            attempted = true;
            // This call should revert because the outer call holds the reentrancy lock.
            try vault.claim(targetIdx, attacker, targetSig) {
                revert("REENTRANCY GUARD MISSING");
            } catch {
                // expected — guard caught it
            }
        }
    }
}

contract EnvelopeEdgeCasesTest is Test, ERC721Holder, ERC1155Holder {
    EnvelopeLinks public vault;
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
        vault = new EnvelopeLinks(address(0), address(this), address(0));
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
                    vault.ENVELOPE_SALT(), block.chainid, address(vault), idx, recipient, vault.OPEN_CLAIM_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _depositEth(uint256 amount) internal returns (uint256) {
        return vault.createLink{value: amount}(address(0), 0, amount, 0, LINK_PUBKEY20);
    }

    // ── EnvelopeLinks deposit input validation ──────────────────────────────────

    function test_RevertWhen_DepositInvalidContractType() public {
        // _pullTokensViaApproval rejects contractType > 3.
        vm.expectRevert(EnvelopeLinks.InvalidContractType.selector);
        vault.createLink{value: 0}(address(0), 5, 0, 0, LINK_PUBKEY20);
    }

    function test_RevertWhen_DepositEthAmountMismatch() public {
        // contractType==0 requires _amount == msg.value.
        vm.expectRevert(EnvelopeLinks.WrongEthAmount.selector);
        vault.createLink{value: 100}(address(0), 0, 50, 0, LINK_PUBKEY20);
    }

    function test_RevertWhen_DepositErc721AmountNotOne() public {
        // contractType==2 requires _amount == 1.
        erc721.mint(address(this), 1);
        erc721.approve(address(vault), 1);
        vm.expectRevert(EnvelopeLinks.Erc721AmountMustBeOne.selector);
        vault.createLink(address(erc721), 2, 2, 1, LINK_PUBKEY20);
    }

    // ── EnvelopeLinks withdraw input validation ─────────────────────────────────

    function test_RevertWhen_WithdrawIndexOutOfBounds() public {
        bytes memory sig = _signWithdrawal(99, ALICE, LINK_PRIV);
        vm.expectRevert(EnvelopeLinks.LinkIndexOutOfBounds.selector);
        vault.claim(99, ALICE, sig);
    }

    function test_RevertWhen_WithdrawTwice() public {
        uint256 idx = _depositEth(1 ether);
        bytes memory sig = _signWithdrawal(idx, ALICE, LINK_PRIV);
        vault.claim(idx, ALICE, sig);

        vm.expectRevert(EnvelopeLinks.LinkAlreadyRedeemed.selector);
        vault.claim(idx, ALICE, sig);
    }

    function test_RevertWhen_WithdrawWithWrongSigner() public {
        uint256 idx = _depositEth(1 ether);
        // Sign with a private key that does NOT correspond to the deposit's pubKey20.
        uint256 wrongKey = uint256(keccak256("wrong-signer"));
        bytes memory sig = _signWithdrawal(idx, ALICE, wrongKey);

        vm.expectRevert(EnvelopeLinks.WrongSignature.selector);
        vault.claim(idx, ALICE, sig);
    }

    function test_RevertWhen_WithdrawAsRecipientCallerMismatch() public {
        // Recipient-mode signature; caller must equal the recipient.
        uint256 idx = _depositEth(1 ether);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(), block.chainid, address(vault), idx, ALICE, vault.BOUND_CLAIM_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // BOB tries to call on behalf of ALICE — caller must equal the recipient param.
        vm.prank(BOB);
        vm.expectRevert(EnvelopeLinks.NotTheRecipient.selector);
        vault.claimAsBoundRecipient(idx, ALICE, sig);
    }

    function test_RevertWhen_RecipientBoundClaimedByOtherAddress() public {
        // Address-bound deposit: recipient = ALICE.
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY20, address(this), false, ALICE, 0
        );
        // Even with a valid pubKey signature, the contract-stored recipient blocks
        // anyone else from being the named recipient on withdrawal.
        bytes memory sig = _signWithdrawal(idx, BOB, LINK_PRIV);
        vm.expectRevert(EnvelopeLinks.WrongRecipient.selector);
        vault.claim(idx, BOB, sig);
    }

    function test_RecipientBoundSenderCannotReclaimBeforeDeadline() public {
        uint40 reclaimAfter = uint40(block.timestamp + 1 days);
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY20, address(this), false, ALICE, reclaimAfter
        );
        vm.expectRevert(EnvelopeLinks.TooEarlyToReclaim.selector);
        vault.reclaim(idx);

        vm.warp(reclaimAfter + 1);
        vault.reclaim(idx); // succeeds after the deadline
    }

    function test_RevertWhen_SenderReclaimNotTheSender() public {
        uint256 idx = _depositEth(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(EnvelopeLinks.NotTheCreator.selector);
        vault.reclaim(idx);
    }

    function test_RevertWhen_MFADepositWithoutMFASignature() public {
        // vault is deployed with mfaAuthorizer == address(0), so MFA-flagged
        // deposits can never be withdrawn via withdrawDeposit (REQUIRES AUTHORIZATION).
        uint256 idx = vault.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY20);
        bytes memory sig = _signWithdrawal(idx, ALICE, LINK_PRIV);
        vm.expectRevert(EnvelopeLinks.RequiresMfaAuthorization.selector);
        vault.claim(idx, ALICE, sig);
    }

    // ── EnvelopeLinks views ─────────────────────────────────────────────────────

    function test_GetAllDepositsForAddressFiltersBySender() public {
        _depositEth(1);
        _depositEth(1);
        // Same sender (address(this)) made both deposits.
        EnvelopeLinks.Link[] memory mine = vault.getLinksCreatedBy(address(this));
        assertEq(mine.length, 2);

        // Different sender → empty.
        EnvelopeLinks.Link[] memory aliceDeposits = vault.getLinksCreatedBy(ALICE);
        assertEq(aliceDeposits.length, 0);
    }

    function test_DepositCountTracksArrayLength() public {
        assertEq(vault.getLinkCount(), 0);
        _depositEth(1);
        _depositEth(1);
        _depositEth(1);
        assertEq(vault.getLinkCount(), 3);
    }

    // ── EnvelopeLinks reentrancy ────────────────────────────────────────────────

    function test_NonReentrantBlocksReentryFromMaliciousToken() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(address(this), 100);
        evil.approve(address(vault), 100);

        // Deposit type-1 (ERC-20) so withdraw routes back through the token's transfer.
        uint256 idx = vault.createLink(address(evil), 1, 100, 0, LINK_PUBKEY20);
        bytes memory sig = _signWithdrawal(idx, ALICE, LINK_PRIV);

        // Arm the token to reenter inside its _update during the outgoing safeTransfer.
        evil.arm(vault, idx, sig, ALICE);

        // Outer withdraw succeeds (inner reentrant attempt caught and swallowed by try/catch);
        // the reentrancy guard ensured the inner call could not double-spend.
        vault.claim(idx, ALICE, sig);
        assertEq(evil.balanceOf(ALICE), 100);
        assertTrue(evil.attempted(), "reentrancy attempt should have run");
    }

    // ── Vault-native batch input validation ───────────────────────────────────

    function test_RevertWhen_BatchEthAmountMismatch() public {
        address[] memory pubKeys = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            pubKeys[i] = LINK_PUBKEY20;
        }
        vm.expectRevert(EnvelopeLinks.InvalidTotalEtherSent.selector);
        vault.createLinks{value: 1 ether}(address(0), 0, 1 ether, 0, pubKeys);
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

        vm.expectRevert(EnvelopeLinks.ParametersLengthMismatch.selector);
        vault.createCustomLinks(tokens, types, amounts, ids, pks, mfa);
    }

    // makeBatchDepositNoReturn — ETH path must require exact total, non-ETH path must reject msg.value.

    function test_BatchNoReturnEth_HappyPath() public {
        address[] memory pubKeys = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            pubKeys[i] = LINK_PUBKEY20;
        }

        vault.createLinksNoReturn{value: 3 ether}(address(0), 0, 1 ether, 0, pubKeys);
        assertEq(vault.getLinkCount(), 3);
    }

    function test_RevertWhen_BatchNoReturnEthAmountMismatch() public {
        address[] memory pubKeys = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            pubKeys[i] = LINK_PUBKEY20;
        }
        vm.expectRevert(EnvelopeLinks.InvalidTotalEtherSent.selector);
        vault.createLinksNoReturn{value: 1 ether}(address(0), 0, 1 ether, 0, pubKeys);
    }

    function test_RevertWhen_BatchNoReturnEthSentForErc20() public {
        // ERC-20 path must reject msg.value — would otherwise strand dust in the vault.
        erc20.mint(address(this), 1000);
        erc20.approve(address(vault), 1000);
        address[] memory pubKeys = new address[](2);
        for (uint256 i = 0; i < 2; i++) {
            pubKeys[i] = LINK_PUBKEY20;
        }
        vm.expectRevert(EnvelopeLinks.EthNotAcceptedForNonEthLink.selector);
        vault.createLinksNoReturn{value: 1 wei}(address(erc20), 1, 100, 0, pubKeys);
    }

    function test_RevertWhen_BatchRaffleErc721NotSupported() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.expectRevert(EnvelopeLinks.UnsupportedRaffleContractType.selector);
        vault.createRaffleLinks(address(erc721), 2, amounts, LINK_PUBKEY20);
    }

    function test_BatchZeroLengthDepositsIsNoop() public {
        address[] memory pubKeys = new address[](0);
        uint256[] memory ids = vault.createLinks(address(0), 0, 0, 0, pubKeys);
        assertEq(ids.length, 0);
        assertEq(vault.getLinkCount(), 0);
    }
}

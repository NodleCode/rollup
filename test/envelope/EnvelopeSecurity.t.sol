// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

// Tests for security hardening findings:
//   H-1 — Balance-delta measurement for fee-on-transfer tokens
//   H-2 — Mutable mfaAuthorizer (key rotation)
//   M-1 — Guard _isMfaSignatureValid against address(0)
//   M-2 — Reject unbound links in claimAsBoundRecipient
//   M-3 — Reject recipientAddress == address(0) in claims
//   M-4 — Fee-authorization replay protection

import {Test} from "forge-std/Test.sol";
import {EnvelopeLinks} from "../../src/envelope/EnvelopeLinks.sol";
import {EnvelopeFeeAuthTestUtils} from "./EnvelopeFeeAuthTestUtils.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {FeeOnTransferERC20Mock} from "./mocks/FeeOnTransferERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract EnvelopeSecurityTest is Test {
    EnvelopeLinks public vault;
    EnvelopeLinks public mfaVault;
    ERC20Mock public feeToken;
    FeeOnTransferERC20Mock public fotToken;

    uint256 constant LINK_PRIV = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    uint256 constant MFA_PRIV = uint256(keccak256("security-test-mfa-signer"));
    address linkPubKey;
    address mfaSigner;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        linkPubKey = vm.addr(LINK_PRIV);
        mfaSigner = vm.addr(MFA_PRIV);

        feeToken = new ERC20Mock();
        fotToken = new FeeOnTransferERC20Mock();

        vault = new EnvelopeLinks(address(0), address(this), address(0));
        mfaVault = new EnvelopeLinks(mfaSigner, address(this), address(feeToken));
    }

    receive() external payable {}

    // ══════════════════════════════════════════════════════════════════════════════
    // H-1: Balance-delta measurement for fee-on-transfer tokens
    // ══════════════════════════════════════════════════════════════════════════════

    function test_H1_feeOnTransferRecordsActualAmount() public {
        fotToken.mint(address(this), 10000);
        fotToken.approve(address(vault), 10000);

        // Deposit 1000 tokens; FOT takes 1% → vault receives 990.
        uint256 idx = vault.createLink(address(fotToken), 1, 1000, 0, linkPubKey);
        EnvelopeLinks.LinkAsset memory asset = vault.getLinkAsset(idx);
        // The stored amount must reflect the actual received amount (990), not requested (1000).
        assertEq(asset.amount, 990, "Should store balance-delta, not requested amount");
    }

    function test_H1_batchFeeOnTransferRecordsActualPerLinkAmount() public {
        fotToken.mint(address(this), 100000);
        fotToken.approve(address(vault), 100000);

        address[] memory keys = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            keys[i] = linkPubKey;
        }

        uint256[] memory indexes = vault.createLinks(address(fotToken), 1, 1000, 0, keys);

        // Each link: requested 1000 * 5 = 5000, received 4950, per-link = 990.
        for (uint256 i = 0; i < indexes.length; i++) {
            EnvelopeLinks.LinkAsset memory asset = vault.getLinkAsset(indexes[i]);
            assertEq(asset.amount, 990, "Batch per-link should use balance delta");
        }
    }

    function test_H1_raffleFeeOnTransferReverts() public {
        fotToken.mint(address(this), 100000);
        fotToken.approve(address(vault), 100000);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000;
        amounts[1] = 2000;
        amounts[2] = 3000;

        // Raffle links with FOT token should revert because received < expected.
        vm.expectRevert(EnvelopeLinks.InsufficientTokensReceived.selector);
        vault.createRaffleLinks(address(fotToken), 1, amounts, linkPubKey);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // H-2: Mutable mfaAuthorizer (key rotation)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_H2_ownerCanRotateMfaAuthorizer() public {
        assertEq(mfaVault.mfaAuthorizer(), mfaSigner);

        address newSigner = address(0x1234);
        mfaVault.setMfaAuthorizer(newSigner);
        assertEq(mfaVault.mfaAuthorizer(), newSigner);
    }

    function test_H2_nonOwnerCannotRotateMfaAuthorizer() public {
        vm.prank(ALICE);
        vm.expectRevert();
        mfaVault.setMfaAuthorizer(address(0x9999));
    }

    function test_H2_rotationInvalidatesOldSignatures() public {
        // Create an MFA-gated link.
        uint256 idx = mfaVault.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);

        // Sign MFA with the old key.
        bytes memory mfaSig = _signMfa(address(mfaVault), idx, ALICE, 0, MFA_PRIV);
        bytes memory claimSig = _signOpen(address(mfaVault), idx, ALICE);

        // Rotate key.
        uint256 newMfaPriv = uint256(keccak256("new-mfa-key"));
        mfaVault.setMfaAuthorizer(vm.addr(newMfaPriv));

        // Old MFA signature should now fail.
        vm.expectRevert(EnvelopeLinks.WrongMfaSignature.selector);
        mfaVault.claimWithMFA(idx, ALICE, claimSig, mfaSig, 0);

        // New signature works.
        bytes memory newMfaSig = _signMfa(address(mfaVault), idx, ALICE, 0, newMfaPriv);
        mfaVault.claimWithMFA(idx, ALICE, claimSig, newMfaSig, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // M-1: Guard against mfaAuthorizer == address(0)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_M1_claimWithMfaRevertsWhenAuthorizerIsZero() public {
        // vault has mfaAuthorizer == address(0).
        uint256 idx = vault.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        bytes memory sig = _signOpen(address(vault), idx, ALICE);

        vm.expectRevert(EnvelopeLinks.MfaAuthorizerIsZero.selector);
        vault.claimWithMFA(idx, ALICE, sig, hex"", 0);
    }

    function test_M1_isValidGaslessOperationReturnsFalseWhenAuthorizerZero() public {
        uint256 idx = vault.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        bytes memory sig = _signOpen(address(vault), idx, ALICE);
        bytes memory mfaSig = hex"00";

        bytes memory callData = abi.encodeCall(EnvelopeLinks.claimWithMFA, (idx, ALICE, sig, mfaSig, 0));

        bool valid = vault.isValidGaslessOperation(ALICE, callData);
        assertFalse(valid, "Should reject when mfaAuthorizer is zero");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // M-2: Reject unbound links in claimAsBoundRecipient
    // ══════════════════════════════════════════════════════════════════════════════

    function test_M2_claimAsBoundRecipientRevertsOnUnboundLink() public {
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        bytes memory sig = _signBound(address(vault), idx, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(EnvelopeLinks.LinkNotRecipientBound.selector);
        vault.claimAsBoundRecipient(idx, ALICE, sig);
    }

    function test_M2_claimAsBoundRecipientWorksOnBoundLink() public {
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, linkPubKey, address(this), false, ALICE, 0
        );
        bytes memory sig = _signBound(address(vault), idx, ALICE);

        vm.prank(ALICE);
        vault.claimAsBoundRecipient(idx, ALICE, sig);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // M-3: Reject recipientAddress == address(0) in claims
    // ══════════════════════════════════════════════════════════════════════════════

    function test_M3_claimRevertsWithZeroRecipient() public {
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        bytes memory sig = _signOpen(address(vault), idx, address(0));

        vm.expectRevert(EnvelopeLinks.ZeroRecipientAddress.selector);
        vault.claim(idx, address(0), sig);
    }

    function test_M3_isValidGaslessReturnsFalseForZeroRecipient() public {
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        bytes memory sig = _signOpen(address(vault), idx, address(0));

        bytes memory callData = abi.encodeCall(EnvelopeLinks.claim, (idx, address(0), sig));
        bool valid = vault.isValidGaslessOperation(address(0), callData);
        assertFalse(valid, "Should reject zero recipient in gasless validation");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // M-4: Fee-authorization replay protection
    // ══════════════════════════════════════════════════════════════════════════════

    function test_M4_feeAuthorizationCannotBeReused() public {
        feeToken.mint(address(this), 1 ether);
        feeToken.approve(address(mfaVault), 1 ether);

        EnvelopeLinks.LinkRequest memory request = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 0.1 ether,
            tokenId: 0,
            claimKey: linkPubKey,
            onBehalfOf: address(this),
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });

        uint256 serviceFee = 100;
        uint256 gaslessFee = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = EnvelopeFeeAuthTestUtils.feeAuthorizationDigest(
            mfaVault.ENVELOPE_SALT(), address(mfaVault), request, address(this), serviceFee, gaslessFee, false, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIV, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        EnvelopeLinks.FeeAuthorization memory feeAuth = EnvelopeLinks.FeeAuthorization({
            serviceFee: serviceFee, gaslessFee: gaslessFee, gaslessSponsored: false, deadline: deadline, signature: sig
        });

        // First use succeeds.
        mfaVault.createLinkWithFees{value: 0.1 ether}(request, feeAuth);

        // Second use with the same authorization reverts.
        vm.expectRevert(EnvelopeLinks.FeeAuthorizationAlreadyUsed.selector);
        mfaVault.createLinkWithFees{value: 0.1 ether}(request, feeAuth);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════════════

    function _signOpen(address vaultAddr, uint256 idx, address recipient) internal view returns (bytes memory) {
        EnvelopeLinks v = EnvelopeLinks(payable(vaultAddr));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(v.ENVELOPE_SALT(), block.chainid, vaultAddr, idx, recipient, v.OPEN_CLAIM_MODE())
            )
        );
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        return abi.encodePacked(r, s, vv);
    }

    function _signBound(address vaultAddr, uint256 idx, address recipient) internal view returns (bytes memory) {
        EnvelopeLinks v = EnvelopeLinks(payable(vaultAddr));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(v.ENVELOPE_SALT(), block.chainid, vaultAddr, idx, recipient, v.BOUND_CLAIM_MODE())
            )
        );
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        return abi.encodePacked(r, s, vv);
    }

    function _signMfa(address vaultAddr, uint256 idx, address recipient, uint256 deadline, uint256 privKey)
        internal
        view
        returns (bytes memory)
    {
        EnvelopeLinks v = EnvelopeLinks(payable(vaultAddr));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(v.ENVELOPE_SALT(), block.chainid, vaultAddr, idx, recipient, deadline))
        );
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, vv);
    }
}

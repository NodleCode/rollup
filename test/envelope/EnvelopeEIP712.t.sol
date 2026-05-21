// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

// Thorough EIP-712 tests for EnvelopeLinks:
//   - Domain separator correctness
//   - Cross-chain replay protection (domain separator includes chainId)
//   - Cross-contract replay protection (domain separator includes verifyingContract)
//   - Typehash verification
//   - Structured data correctness for all three signed message types
//   - eip712Domain() getter (EIP-5267)

import {Test} from "forge-std/Test.sol";
import {EnvelopeLinks} from "../../src/envelope/EnvelopeLinks.sol";
import {EnvelopeEIP712Utils} from "./EnvelopeEIP712Utils.sol";
import {EnvelopeFeeAuthTestUtils} from "./EnvelopeFeeAuthTestUtils.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract EnvelopeEIP712Test is Test {
    EnvelopeLinks public vault;
    EnvelopeLinks public vault2; // second instance for cross-contract tests
    ERC20Mock public feeToken;

    uint256 constant LINK_PRIV = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    uint256 constant MFA_PRIV = uint256(keccak256("eip712-test-mfa-signer"));
    address linkPubKey;
    address mfaSigner;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        linkPubKey = vm.addr(LINK_PRIV);
        mfaSigner = vm.addr(MFA_PRIV);
        feeToken = new ERC20Mock();

        vault = new EnvelopeLinks(mfaSigner, address(this), address(feeToken));
        vault2 = new EnvelopeLinks(mfaSigner, address(this), address(feeToken));
    }

    receive() external payable {}

    // ══════════════════════════════════════════════════════════════════════════════
    // Domain separator correctness
    // ══════════════════════════════════════════════════════════════════════════════

    function test_domainSeparator_matchesExpected() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("EnvelopeLinks"),
                keccak256("5"),
                block.chainid,
                address(vault)
            )
        );
        assertEq(EnvelopeEIP712Utils.domainSeparator(address(vault)), expected);
    }

    function test_domainSeparator_differsBetweenInstances() public view {
        bytes32 ds1 = EnvelopeEIP712Utils.domainSeparator(address(vault));
        bytes32 ds2 = EnvelopeEIP712Utils.domainSeparator(address(vault2));
        assertTrue(ds1 != ds2, "Different contract addresses must have different domain separators");
    }

    function test_domainSeparator_includesChainId() public {
        bytes32 ds1 = EnvelopeEIP712Utils.domainSeparator(address(vault));

        // Fork to a different chain ID
        vm.chainId(999);
        bytes32 ds2 = EnvelopeEIP712Utils.domainSeparator(address(vault));

        assertTrue(ds1 != ds2, "Different chain IDs must produce different domain separators");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // EIP-5267: eip712Domain() getter
    // ══════════════════════════════════════════════════════════════════════════════

    function test_eip712Domain_returnsCorrectValues() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = vault.eip712Domain();

        assertEq(uint8(fields), 0x0f, "Fields should indicate name, version, chainId, verifyingContract");
        assertEq(keccak256(bytes(name)), keccak256("EnvelopeLinks"));
        assertEq(keccak256(bytes(version)), keccak256("5"));
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(vault));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Typehash verification
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimTypehash() public view {
        bytes32 expected = keccak256("Claim(uint256 index,address recipient,bytes32 mode)");
        assertEq(vault.CLAIM_TYPEHASH(), expected);
    }

    function test_mfaApprovalTypehash() public view {
        bytes32 expected = keccak256("MfaApproval(uint256 index,address recipient,uint256 deadline)");
        assertEq(vault.MFA_APPROVAL_TYPEHASH(), expected);
    }

    function test_feeAuthorizationTypehash() public view {
        bytes32 expected = keccak256(
            "FeeAuthorization(address feePayer,address tokenAddress,uint8 contractType,uint256 amount,uint256 tokenId,address claimKey,address onBehalfOf,bool withMFA,address recipient,uint40 reclaimableAfter,uint256 serviceFee,uint256 gaslessFee,bool gaslessSponsored,uint256 deadline)"
        );
        assertEq(vault.FEE_AUTHORIZATION_TYPEHASH(), expected);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Cross-chain replay protection
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimSignature_invalidOnDifferentChain() public {
        // Create a link on the original chain
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);

        // Sign the claim on chain 31337 (default foundry chain id)
        bytes32 digest = EnvelopeEIP712Utils.claimDigest(address(vault), idx, ALICE, vault.OPEN_CLAIM_MODE());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Switch to a different chain and verify the signature fails
        vm.chainId(42161); // Arbitrum chain ID

        vm.expectRevert(EnvelopeLinks.WrongSignature.selector);
        vault.claim(idx, ALICE, sig);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Cross-contract replay protection
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimSignature_invalidOnDifferentContract() public {
        // Create identical links on both vaults
        uint256 idx1 = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        uint256 idx2 = vault2.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        assertEq(idx1, idx2, "Both should be index 0");

        // Sign for vault1
        bytes32 digest = EnvelopeEIP712Utils.claimDigest(address(vault), idx1, ALICE, vault.OPEN_CLAIM_MODE());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Claim on vault1 works
        vault.claim(idx1, ALICE, sig);

        // Same signature on vault2 fails
        vm.expectRevert(EnvelopeLinks.WrongSignature.selector);
        vault2.claim(idx2, ALICE, sig);
    }

    function test_mfaSignature_invalidOnDifferentContract() public {
        // Create MFA links on both vaults
        uint256 idx1 = vault.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);
        uint256 idx2 = vault2.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);

        // Sign MFA for vault1
        bytes32 mfaDigest = EnvelopeEIP712Utils.mfaDigest(address(vault), idx1, ALICE, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIV, mfaDigest);
        bytes memory mfaSig = abi.encodePacked(r, s, v);

        bytes32 claimDigest1 = EnvelopeEIP712Utils.claimDigest(address(vault), idx1, ALICE, vault.OPEN_CLAIM_MODE());
        (v, r, s) = vm.sign(LINK_PRIV, claimDigest1);
        bytes memory claimSig1 = abi.encodePacked(r, s, v);

        // Works on vault1
        vault.claimWithMFA(idx1, ALICE, claimSig1, mfaSig, 0);

        // MFA sig from vault1 fails on vault2
        bytes32 claimDigest2 = EnvelopeEIP712Utils.claimDigest(address(vault2), idx2, ALICE, vault2.OPEN_CLAIM_MODE());
        (v, r, s) = vm.sign(LINK_PRIV, claimDigest2);
        bytes memory claimSig2 = abi.encodePacked(r, s, v);

        vm.expectRevert(EnvelopeLinks.WrongMfaSignature.selector);
        vault2.claimWithMFA(idx2, ALICE, claimSig2, mfaSig, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Fee authorization cross-contract replay
    // ══════════════════════════════════════════════════════════════════════════════

    function test_feeAuthorization_invalidOnDifferentContract() public {
        feeToken.mint(address(this), 10 ether);
        feeToken.approve(address(vault), type(uint256).max);
        feeToken.approve(address(vault2), type(uint256).max);

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
        uint256 deadline = block.timestamp + 1 hours;

        // Sign fee auth for vault1
        bytes32 digest = EnvelopeFeeAuthTestUtils.feeAuthorizationDigest(
            address(vault), request, address(this), serviceFee, 0, false, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIV, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        EnvelopeLinks.FeeAuthorization memory feeAuth = EnvelopeLinks.FeeAuthorization({
            serviceFee: serviceFee,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: deadline,
            signature: sig
        });

        // Works on vault1
        vault.createLinkWithFees{value: 0.1 ether}(request, feeAuth);

        // Fails on vault2 (different verifyingContract in domain separator)
        vm.expectRevert(EnvelopeLinks.WrongFeeAuthorizationSignature.selector);
        vault2.createLinkWithFees{value: 0.1 ether}(request, feeAuth);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Claim mode discrimination
    // ══════════════════════════════════════════════════════════════════════════════

    function test_openClaimSignature_cannotBeUsedAsBound() public {
        // Create an address-bound link
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, linkPubKey, address(this), false, ALICE, 0
        );

        // Sign with OPEN_CLAIM_MODE
        bytes32 digest = EnvelopeEIP712Utils.claimDigest(address(vault), idx, ALICE, vault.OPEN_CLAIM_MODE());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        bytes memory openSig = abi.encodePacked(r, s, v);

        // Using open mode sig in bound recipient claim should fail
        // (claimAsBoundRecipient passes BOUND_CLAIM_MODE as extraData)
        vm.prank(ALICE);
        vm.expectRevert(EnvelopeLinks.WrongSignature.selector);
        vault.claimAsBoundRecipient(idx, ALICE, openSig);
    }

    function test_boundClaimSignature_cannotBeUsedAsOpen() public {
        // Create an open link (recipient = address(0))
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);

        // Sign with BOUND_CLAIM_MODE
        bytes32 digest = EnvelopeEIP712Utils.claimDigest(address(vault), idx, ALICE, vault.BOUND_CLAIM_MODE());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        bytes memory boundSig = abi.encodePacked(r, s, v);

        // Trying to use bound mode sig in an open claim (which uses OPEN_CLAIM_MODE internally)
        vm.expectRevert(EnvelopeLinks.WrongSignature.selector);
        vault.claim(idx, ALICE, boundSig);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Structured data fields completeness
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimDigest_changesWithIndex() public {
        bytes32 d1 = EnvelopeEIP712Utils.claimDigest(address(vault), 0, ALICE, vault.OPEN_CLAIM_MODE());
        bytes32 d2 = EnvelopeEIP712Utils.claimDigest(address(vault), 1, ALICE, vault.OPEN_CLAIM_MODE());
        assertTrue(d1 != d2, "Different index must produce different digest");
    }

    function test_claimDigest_changesWithRecipient() public {
        bytes32 d1 = EnvelopeEIP712Utils.claimDigest(address(vault), 0, ALICE, vault.OPEN_CLAIM_MODE());
        bytes32 d2 = EnvelopeEIP712Utils.claimDigest(address(vault), 0, BOB, vault.OPEN_CLAIM_MODE());
        assertTrue(d1 != d2, "Different recipient must produce different digest");
    }

    function test_claimDigest_changesWithMode() public {
        bytes32 d1 = EnvelopeEIP712Utils.claimDigest(address(vault), 0, ALICE, vault.OPEN_CLAIM_MODE());
        bytes32 d2 = EnvelopeEIP712Utils.claimDigest(address(vault), 0, ALICE, vault.BOUND_CLAIM_MODE());
        assertTrue(d1 != d2, "Different mode must produce different digest");
    }

    function test_mfaDigest_changesWithDeadline() public {
        bytes32 d1 = EnvelopeEIP712Utils.mfaDigest(address(vault), 0, ALICE, 0);
        bytes32 d2 = EnvelopeEIP712Utils.mfaDigest(address(vault), 0, ALICE, 1000);
        assertTrue(d1 != d2, "Different deadline must produce different digest");
    }

    function testFuzz_claimSignature_worksForAnyRecipient(address recipient) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient.code.length == 0); // avoid contracts that reject ETH

        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);

        bytes32 digest = EnvelopeEIP712Utils.claimDigest(address(vault), idx, recipient, vault.OPEN_CLAIM_MODE());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIV, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.deal(recipient, 0); // start at 0 to verify receipt
        vault.claim(idx, recipient, sig);
        assertEq(recipient.balance, 1 ether);
    }

    function testFuzz_mfaSignature_worksWithAnyDeadline(uint256 deadline) public {
        // Ensure deadline is either 0 (no expiry) or in the future
        vm.assume(deadline == 0 || deadline > block.timestamp);

        uint256 idx = vault.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, linkPubKey);

        bytes32 mfaDigest = EnvelopeEIP712Utils.mfaDigest(address(vault), idx, ALICE, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MFA_PRIV, mfaDigest);
        bytes memory mfaSig = abi.encodePacked(r, s, v);

        bytes32 claimDigest_ = EnvelopeEIP712Utils.claimDigest(address(vault), idx, ALICE, vault.OPEN_CLAIM_MODE());
        (v, r, s) = vm.sign(LINK_PRIV, claimDigest_);
        bytes memory claimSig = abi.encodePacked(r, s, v);

        vault.claimWithMFA(idx, ALICE, claimSig, mfaSig, deadline);
    }
}

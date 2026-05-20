// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/EnvelopeLinks.sol";
import {EnvelopeFeeAuthTestUtils} from "./EnvelopeFeeAuthTestUtils.sol";
import "./mocks/ERC20Mock.sol";
import "./mocks/ERC721Mock.sol";
import "./mocks/ERC1155Mock.sol";

/// @dev Tests targeting coverage gaps in EnvelopeLinks and EnvelopePaymaster.
///      Written from the spec/doc perspective, intentionally avoiding reading function bodies.
contract EnvelopeCoverageTest is Test {
    EnvelopeLinks public vault;
    EnvelopeLinks public vaultNoFeeToken;
    ERC20Mock public feeToken;
    ERC20Mock public erc20;
    ERC721Mock public erc721;
    ERC1155Mock public erc1155;

    uint256 public constant LINK_PRIVKEY = uint256(keccak256("coverage-link-key"));
    address public LINK_PUBKEY;
    uint256 public constant LINK_PRIVKEY2 = uint256(keccak256("coverage-link-key-2"));
    address public LINK_PUBKEY2;

    uint256 public constant BACKEND_PRIVKEY = uint256(keccak256("coverage-backend"));
    address public BACKEND_AUTHORIZER;

    address public constant SENDER = address(0xA11CE);
    address public constant RECIPIENT = address(0xB0B);
    address public constant OTHER = address(0xCAFE);

    receive() external payable {}

    function setUp() public {
        LINK_PUBKEY = vm.addr(LINK_PRIVKEY);
        LINK_PUBKEY2 = vm.addr(LINK_PRIVKEY2);
        BACKEND_AUTHORIZER = vm.addr(BACKEND_PRIVKEY);

        feeToken = new ERC20Mock();
        erc20 = new ERC20Mock();
        erc721 = new ERC721Mock();
        erc1155 = new ERC1155Mock();

        vault = new EnvelopeLinks(BACKEND_AUTHORIZER, address(this), address(feeToken));
        vaultNoFeeToken = new EnvelopeLinks(BACKEND_AUTHORIZER, address(this), address(0));

        vm.deal(SENDER, 100 ether);
        vm.deal(RECIPIENT, 1 ether);
        erc20.mint(SENDER, 10_000 ether);
        erc721.mint(SENDER, 1);
        erc721.mint(SENDER, 2);
        erc721.mint(SENDER, 3);
        erc1155.mint(SENDER, 1, 100, "");
        erc1155.mint(SENDER, 2, 50, "");
        feeToken.mint(SENDER, 10_000 ether);

        vm.startPrank(SENDER);
        erc20.approve(address(vault), type(uint256).max);
        erc721.setApprovalForAll(address(vault), true);
        erc1155.setApprovalForAll(address(vault), true);
        feeToken.approve(address(vault), type(uint256).max);
        erc20.approve(address(vaultNoFeeToken), type(uint256).max);
        vm.stopPrank();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    function _signClaim(uint256 linkPrivKey, uint256 index, address recipient, bytes32 mode)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(vault.ENVELOPE_SALT(), block.chainid, address(vault), index, recipient, mode)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(linkPrivKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signMfa(uint256 index, address recipient, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(vault.ENVELOPE_SALT(), block.chainid, address(vault), index, recipient, deadline)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signFeeAuth(
        EnvelopeLinks.LinkRequest memory req,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signFeeAuthForVault(address(vault), req, feePayer, serviceFee, gaslessFee, gaslessSponsored, deadline);
    }

    function _signFeeAuthForVault(
        address vaultAddr,
        EnvelopeLinks.LinkRequest memory req,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = EnvelopeFeeAuthTestUtils.feeAuthorizationDigest(
            vault.ENVELOPE_SALT(), vaultAddr, req, feePayer, serviceFee, gaslessFee, gaslessSponsored, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeEthLink(uint256 amount) internal returns (uint256) {
        vm.prank(SENDER);
        return vault.createLink{value: amount}(address(0), 0, amount, 0, LINK_PUBKEY);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ERC-721 Claim
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimERC721() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink(address(erc721), 2, 1, 1, LINK_PUBKEY);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        vault.claim(idx, RECIPIENT, sig);

        assertEq(erc721.ownerOf(1), RECIPIENT);
        assertTrue(vault.getLinkStatus(idx).redeemed);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ERC-1155 Claim
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimERC1155() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink(address(erc1155), 3, 10, 1, LINK_PUBKEY);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        vault.claim(idx, RECIPIENT, sig);

        assertEq(erc1155.balanceOf(RECIPIENT, 1), 10);
        assertTrue(vault.getLinkStatus(idx).redeemed);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createLinkFor (non-MFA selfless deposit)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createLinkFor_setsOnBehalfOf() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLinkFor{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY, OTHER);

        EnvelopeLinks.LinkParties memory parties = vault.getLinkParties(idx);
        EnvelopeLinks.LinkStatus memory status = vault.getLinkStatus(idx);
        assertEq(parties.creator, OTHER);
        assertFalse(status.requiresMFA);
    }

    function test_createLinkFor_reclaimByOnBehalfOf() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLinkFor{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY, OTHER);

        uint256 balBefore = OTHER.balance;
        vm.deal(OTHER, 0.1 ether);
        vm.prank(OTHER);
        vault.reclaim(idx);
        assertGt(OTHER.balance, balBefore);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createCustomLink with recipient binding
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createCustomLink_recipientBound() public {
        vm.prank(SENDER);
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY, SENDER, false, RECIPIENT, uint40(block.timestamp + 1 days)
        );

        EnvelopeLinks.LinkParties memory parties = vault.getLinkParties(idx);
        assertEq(parties.recipient, RECIPIENT);
        assertEq(parties.reclaimableAfter, uint40(block.timestamp + 1 days));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // claimWithMFA on a recipient-bound link
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimWithMFA_recipientBound() public {
        vm.prank(SENDER);
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY, SENDER, true, RECIPIENT, uint40(block.timestamp + 1 days)
        );

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory mfaSig = _signMfa(idx, RECIPIENT, 0);

        uint256 balBefore = RECIPIENT.balance;
        vault.claimWithMFA(idx, RECIPIENT, sig, mfaSig, 0);
        assertEq(RECIPIENT.balance, balBefore + 1 ether);
    }

    function test_RevertIf_claimWithMFA_wrongRecipient() public {
        vm.prank(SENDER);
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY, SENDER, true, RECIPIENT, uint40(block.timestamp + 1 days)
        );

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, OTHER, vault.OPEN_CLAIM_MODE());
        bytes memory mfaSig = _signMfa(idx, OTHER, 0);

        vm.expectRevert(EnvelopeLinks.WrongRecipient.selector);
        vault.claimWithMFA(idx, OTHER, sig, mfaSig, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // withdrawFees — ETH accumulated fees
    // ══════════════════════════════════════════════════════════════════════════════

    function test_withdrawFees_eth() public {
        // Seed accumulatedFees[address(0)] with ETH balance
        bytes32 slot = keccak256(abi.encode(address(0), uint256(5)));
        vm.store(address(vault), slot, bytes32(uint256(0.5 ether)));
        vm.deal(address(vault), 0.5 ether);

        uint256 ownerBalBefore = address(this).balance;
        vault.withdrawFees(address(0));
        assertEq(address(this).balance, ownerBalBefore + 0.5 ether);
        assertEq(vault.accumulatedFees(address(0)), 0);
    }

    function test_RevertIf_withdrawFees_noFees() public {
        vm.expectRevert(EnvelopeLinks.NoFeesToWithdraw.selector);
        vault.withdrawFees(address(feeToken));
    }

    function test_withdrawFees_erc20() public {
        // Create a link with fees first
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0.1 ether, 0.05 ether, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.1 ether,
            gaslessFee: 0.05 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });

        vm.prank(SENDER);
        vault.createLinkWithFees{value: 1 ether}(req, auth);

        uint256 ownerBalBefore = feeToken.balanceOf(address(this));
        vault.withdrawFees(address(feeToken));
        assertEq(feeToken.balanceOf(address(this)), ownerBalBefore + 0.15 ether);
        assertEq(vault.accumulatedFees(address(feeToken)), 0);
    }

    function test_RevertIf_withdrawFees_nonOwner() public {
        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OTHER));
        vault.withdrawFees(address(feeToken));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // supportsInterface
    // ══════════════════════════════════════════════════════════════════════════════

    function test_supportsInterface_ERC165() public view {
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_ERC721Receiver() public view {
        assertTrue(vault.supportsInterface(type(IERC721Receiver).interfaceId));
    }

    function test_supportsInterface_ERC1155Receiver() public view {
        assertTrue(vault.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function test_supportsInterface_unknownReturnsFalse() public view {
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // isValidGaslessOperation edge cases
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_shortCalldata() public view {
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, hex"aabbcc"));
    }

    function test_isValidGaslessOperation_unknownSelector() public view {
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, hex"deadbeef0000000000000000000000000000000000000000000000000000000000000000"));
    }

    function test_isValidGaslessOperation_reclaim_indexOutOfBounds() public view {
        bytes memory data = abi.encodeCall(EnvelopeLinks.reclaim, (999));
        assertFalse(vault.isValidGaslessOperation(SENDER, data));
    }

    function test_isValidGaslessOperation_reclaim_wrongCreator() public {
        _makeGaslessEthLink(1 ether);
        bytes memory data = abi.encodeCall(EnvelopeLinks.reclaim, (0));
        // OTHER is not the creator
        assertFalse(vault.isValidGaslessOperation(OTHER, data));
    }

    function test_isValidGaslessOperation_reclaim_alreadyRedeemed() public {
        uint256 idx = _makeGaslessEthLink(1 ether);
        // Reclaim to mark redeemed
        vm.prank(SENDER);
        vault.reclaim(idx);

        bytes memory data = abi.encodeCall(EnvelopeLinks.reclaim, (idx));
        assertFalse(vault.isValidGaslessOperation(SENDER, data));
    }

    function test_isValidGaslessOperation_reclaim_recipientBoundBeforeDeadline() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: RECIPIENT,
            reclaimableAfter: uint40(block.timestamp + 1 days)
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0, 0.01 ether, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0.01 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });
        vm.prank(SENDER);
        vault.createLinkWithFees{value: 1 ether}(req, auth);

        bytes memory data = abi.encodeCall(EnvelopeLinks.reclaim, (0));
        // Before reclaimableAfter timestamp
        assertFalse(vault.isValidGaslessOperation(SENDER, data));
    }

    function test_isValidGaslessOperation_claim_callerNotRecipient() public {
        uint256 idx = _makeGaslessEthLink(1 ether);
        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (idx, RECIPIENT, sig));
        // caller != recipient → invalid for gasless
        assertFalse(vault.isValidGaslessOperation(OTHER, data));
    }

    function test_isValidGaslessOperation_claim_noGaslessEligibility() public {
        // Create a link WITHOUT gasless fees
        vm.prank(SENDER);
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (idx, RECIPIENT, sig));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    function test_isValidGaslessOperation_claimWithMFA_expiredMfa() public {
        uint256 idx = _makeGaslessEthLink_mfa(1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory mfaSig = _signMfa(idx, RECIPIENT, deadline);

        // Warp past deadline
        vm.warp(deadline + 1);

        bytes memory data = abi.encodeCall(EnvelopeLinks.claimWithMFA, (idx, RECIPIENT, sig, mfaSig, deadline));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    function test_isValidGaslessOperation_claimAsBoundRecipient_valid() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: RECIPIENT,
            reclaimableAfter: uint40(block.timestamp + 1 days)
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0, 0.01 ether, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0.01 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });
        vm.prank(SENDER);
        uint256 idx = vault.createLinkWithFees{value: 1 ether}(req, auth);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.BOUND_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claimAsBoundRecipient, (idx, RECIPIENT, sig));
        assertTrue(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // onERC721Received / onERC1155Received revert on direct transfer
    // ══════════════════════════════════════════════════════════════════════════════

    function test_RevertIf_directERC721Transfer() public {
        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.DirectTransfersNotAllowed.selector);
        erc721.safeTransferFrom(SENDER, address(vault), 2);
    }

    function test_RevertIf_directERC1155Transfer() public {
        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.DirectTransfersNotAllowed.selector);
        erc1155.safeTransferFrom(SENDER, address(vault), 1, 5, "");
    }

    function test_RevertIf_directERC1155BatchTransfer() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5;
        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.DirectTransfersNotAllowed.selector);
        erc1155.safeBatchTransferFrom(SENDER, address(vault), ids, amounts, "");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createCustomLinks — mixed ETH + ERC20 batch
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createCustomLinks_mixedBatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(erc20);
        uint8[] memory types = new uint8[](2);
        types[0] = 0;
        types[1] = 1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = 100;
        uint256[] memory tokenIds = new uint256[](2);
        address[] memory keys = new address[](2);
        keys[0] = LINK_PUBKEY;
        keys[1] = LINK_PUBKEY2;
        bool[] memory mfas = new bool[](2);

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createCustomLinks{value: 0.5 ether}(tokens, types, amounts, tokenIds, keys, mfas);

        assertEq(indexes.length, 2);
        assertEq(vault.getLinkAsset(indexes[0]).amount, 0.5 ether);
        assertEq(vault.getLinkAsset(indexes[1]).amount, 100);
        assertEq(vault.getLinkAsset(indexes[1]).tokenAddress, address(erc20));
    }

    function test_RevertIf_createCustomLinks_invalidContractType() public {
        address[] memory tokens = new address[](1);
        uint8[] memory types = new uint8[](1);
        types[0] = 5; // invalid
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        uint256[] memory tokenIds = new uint256[](1);
        address[] memory keys = new address[](1);
        keys[0] = LINK_PUBKEY;
        bool[] memory mfas = new bool[](1);

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.InvalidContractType.selector);
        vault.createCustomLinks(tokens, types, amounts, tokenIds, keys, mfas);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createCustomLinksWithFees
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createCustomLinksWithFees_heterogeneousBatch() public {
        EnvelopeLinks.LinkRequest[] memory reqs = new EnvelopeLinks.LinkRequest[](2);
        reqs[0] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        reqs[1] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc20),
            contractType: 1,
            amount: 50,
            tokenId: 0,
            claimKey: LINK_PUBKEY2,
            onBehalfOf: SENDER,
            withMFA: true,
            recipient: RECIPIENT,
            reclaimableAfter: uint40(block.timestamp + 1 days)
        });

        EnvelopeLinks.FeeAuthorization[] memory auths = new EnvelopeLinks.FeeAuthorization[](2);
        auths[0] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.01 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuth(reqs[0], SENDER, 0.01 ether, 0, false, 0)
        });
        auths[1] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.02 ether,
            gaslessFee: 0.01 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuth(reqs[1], SENDER, 0.02 ether, 0.01 ether, false, 0)
        });

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createCustomLinksWithFees{value: 1 ether}(reqs, auths);

        assertEq(indexes.length, 2);
        assertEq(vault.getLinkAsset(indexes[0]).amount, 1 ether);
        assertEq(vault.getLinkAsset(indexes[1]).amount, 50);
        assertEq(vault.getLinkParties(indexes[1]).recipient, RECIPIENT);
        assertEq(vault.accumulatedFees(address(feeToken)), 0.04 ether);
    }

    function test_RevertIf_createCustomLinksWithFees_lengthMismatch() public {
        EnvelopeLinks.LinkRequest[] memory reqs = new EnvelopeLinks.LinkRequest[](2);
        EnvelopeLinks.FeeAuthorization[] memory auths = new EnvelopeLinks.FeeAuthorization[](1);

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.ParametersLengthMismatch.selector);
        vault.createCustomLinksWithFees(reqs, auths);
    }

    function test_RevertIf_createCustomLinksWithFees_invalidContractType() public {
        EnvelopeLinks.LinkRequest[] memory reqs = new EnvelopeLinks.LinkRequest[](1);
        reqs[0] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 7, // invalid
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        EnvelopeLinks.FeeAuthorization[] memory auths = new EnvelopeLinks.FeeAuthorization[](1);
        auths[0] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: ""
        });

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.InvalidContractType.selector);
        vault.createCustomLinksWithFees{value: 1 ether}(reqs, auths);
    }

    function test_RevertIf_createCustomLinksWithFees_wrongEthAmount() public {
        EnvelopeLinks.LinkRequest[] memory reqs = new EnvelopeLinks.LinkRequest[](1);
        reqs[0] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        EnvelopeLinks.FeeAuthorization[] memory auths = new EnvelopeLinks.FeeAuthorization[](1);
        auths[0] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: ""
        });

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.InvalidTotalEtherSent.selector);
        vault.createCustomLinksWithFees{value: 0.5 ether}(reqs, auths); // wrong amount
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createLinks (uniform batch) — ERC-1155
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createLinks_erc1155() public {
        address[] memory keys = new address[](3);
        keys[0] = LINK_PUBKEY;
        keys[1] = LINK_PUBKEY2;
        keys[2] = vm.addr(uint256(keccak256("key3")));

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createLinks(address(erc1155), 3, 10, 1, keys);

        assertEq(indexes.length, 3);
        assertEq(erc1155.balanceOf(address(vault), 1), 30);
    }

    function test_RevertIf_createLinks_erc721() public {
        address[] memory keys = new address[](2);
        keys[0] = LINK_PUBKEY;
        keys[1] = LINK_PUBKEY2;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.Erc721BatchNotSupported.selector);
        vault.createLinks(address(erc721), 2, 1, 1, keys);
    }

    function test_RevertIf_createLinks_invalidContractType() public {
        address[] memory keys = new address[](1);
        keys[0] = LINK_PUBKEY;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.InvalidContractType.selector);
        vault.createLinks(address(0), 4, 1, 0, keys);
    }

    function test_createLinks_ethNoExtraValue() public {
        address[] memory keys = new address[](2);
        keys[0] = LINK_PUBKEY;
        keys[1] = LINK_PUBKEY2;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.InvalidTotalEtherSent.selector);
        vault.createLinks{value: 0.5 ether}(address(0), 0, 1 ether, 0, keys); // need 2 ether
    }

    function test_RevertIf_createLinks_ethSentForErc20() public {
        address[] memory keys = new address[](1);
        keys[0] = LINK_PUBKEY;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.EthNotAcceptedForNonEthLink.selector);
        vault.createLinks{value: 1 ether}(address(erc20), 1, 100, 0, keys);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createLinksNoReturn
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createLinksNoReturn_eth() public {
        address[] memory keys = new address[](2);
        keys[0] = LINK_PUBKEY;
        keys[1] = LINK_PUBKEY2;

        uint256 countBefore = vault.getLinkCount();
        vm.prank(SENDER);
        vault.createLinksNoReturn{value: 2 ether}(address(0), 0, 1 ether, 0, keys);
        assertEq(vault.getLinkCount(), countBefore + 2);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createRaffleLinks edge cases
    // ══════════════════════════════════════════════════════════════════════════════

    function test_RevertIf_createRaffleLinks_erc721NotSupported() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.UnsupportedRaffleContractType.selector);
        vault.createRaffleLinks(address(erc721), 2, amounts, LINK_PUBKEY);
    }

    function test_createRaffleLinks_erc20_ethSentReverts() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 20;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.EthNotAcceptedForNonEthLink.selector);
        vault.createRaffleLinks{value: 1 ether}(address(erc20), 1, amounts, LINK_PUBKEY);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createMFALink
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createMFALink_erc20() public {
        vm.prank(SENDER);
        uint256 idx = vault.createMFALink(address(erc20), 1, 100, 0, LINK_PUBKEY);

        EnvelopeLinks.LinkStatus memory status = vault.getLinkStatus(idx);
        EnvelopeLinks.LinkAsset memory asset = vault.getLinkAsset(idx);
        assertTrue(status.requiresMFA);
        assertEq(asset.amount, 100);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // MFA signature expiry
    // ══════════════════════════════════════════════════════════════════════════════

    function test_RevertIf_claimWithMFA_expiredDeadline() public {
        vm.prank(SENDER);
        uint256 idx = vault.createMFALink{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory mfaSig = _signMfa(idx, RECIPIENT, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(EnvelopeLinks.MfaSignatureExpired.selector);
        vault.claimWithMFA(idx, RECIPIENT, sig, mfaSig, deadline);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Fee authorization expiry
    // ══════════════════════════════════════════════════════════════════════════════

    function test_RevertIf_feeAuthorization_expired() public {
        uint256 deadline = block.timestamp + 1 hours;
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0.01 ether, 0, false, deadline);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.01 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: deadline,
            signature: authSig
        });

        vm.warp(deadline + 1);
        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.FeeAuthorizationExpired.selector);
        vault.createLinkWithFees{value: 1 ether}(req, auth);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Reclaim ERC-721 and ERC-1155
    // ══════════════════════════════════════════════════════════════════════════════

    function test_reclaim_erc721() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink(address(erc721), 2, 1, 1, LINK_PUBKEY);

        vm.prank(SENDER);
        vault.reclaim(idx);
        assertEq(erc721.ownerOf(1), SENDER);
    }

    function test_reclaim_erc1155() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink(address(erc1155), 3, 20, 1, LINK_PUBKEY);

        vm.prank(SENDER);
        vault.reclaim(idx);
        assertEq(erc1155.balanceOf(SENDER, 1), 100); // 100 minted, 20 deposited, 20 reclaimed = 100
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // View functions
    // ══════════════════════════════════════════════════════════════════════════════

    function test_getAllLinkIndexes() public {
        _makeEthLink(1 ether);
        _makeEthLink(2 ether);

        uint256[] memory indexes = vault.getAllLinkIndexes();
        assertEq(indexes.length, 2);
        assertEq(vault.getLinkAsset(indexes[0]).amount, 1 ether);
        assertEq(vault.getLinkAsset(indexes[1]).amount, 2 ether);
    }

    function test_getLinkIndexesCreatedBy() public {
        _makeEthLink(1 ether); // by SENDER
        vm.deal(OTHER, 5 ether);
        vm.prank(OTHER);
        vault.createLink{value: 2 ether}(address(0), 0, 2 ether, 0, LINK_PUBKEY2);

        uint256[] memory senderLinks = vault.getLinkIndexesCreatedBy(SENDER);
        assertEq(senderLinks.length, 1);
        assertEq(vault.getLinkAsset(senderLinks[0]).amount, 1 ether);
    }

    function test_getLinkCount() public {
        assertEq(vault.getLinkCount(), 0);
        _makeEthLink(1 ether);
        assertEq(vault.getLinkCount(), 1);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Claim with empty signature (claimKey == address(0))
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claim_noClaimKey() public {
        // Create a link with claimKey = address(0) — anyone can claim without signature
        vm.prank(SENDER);
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, address(0));

        uint256 balBefore = RECIPIENT.balance;
        vault.claim(idx, RECIPIENT, "");
        assertEq(RECIPIENT.balance, balBefore + 1 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ERC-20 claim
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimERC20() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink(address(erc20), 1, 200, 0, LINK_PUBKEY);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        vault.claim(idx, RECIPIENT, sig);

        assertEq(erc20.balanceOf(RECIPIENT), 200);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createMFARaffleLinks
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createMFARaffleLinks_eth() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0.1 ether;
        amounts[1] = 0.2 ether;
        amounts[2] = 0.3 ether;

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createMFARaffleLinks{value: 0.6 ether}(address(0), 0, amounts, LINK_PUBKEY);

        assertEq(indexes.length, 3);
        assertTrue(vault.getLinkStatus(indexes[0]).requiresMFA);
        assertTrue(vault.getLinkStatus(indexes[2]).requiresMFA);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Claim ETH to contract that rejects ETH
    // ══════════════════════════════════════════════════════════════════════════════

    function test_RevertIf_claimEth_recipientRejects() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY);

        // Deploy a contract that reverts on receive
        EthRejecter rejecter = new EthRejecter();
        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, address(rejecter), vault.OPEN_CLAIM_MODE());

        vm.expectRevert(EnvelopeLinks.EthTransferFailed.selector);
        vault.claim(idx, address(rejecter), sig);
    }

    function test_RevertIf_reclaimEth_creatorRejects() public {
        // Create link on behalf of a contract that rejects ETH
        EthRejecter rejecter = new EthRejecter();
        vm.prank(SENDER);
        uint256 idx = vault.createLinkFor{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY, address(rejecter));

        vm.prank(address(rejecter));
        vm.expectRevert(EnvelopeLinks.EthTransferFailed.selector);
        vault.reclaim(idx);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ERC-20 with 0 amount
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createLink_erc20_zeroAmount() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink(address(erc20), 1, 0, 0, LINK_PUBKEY);
        assertEq(vault.getLinkAsset(idx).amount, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // getSigner (public pure helper)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_getSigner() public view {
        bytes32 hash = keccak256("test");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIVKEY, hash);
        address signer = vault.getSigner(hash, abi.encodePacked(r, s, v));
        assertEq(signer, LINK_PUBKEY);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Reclaim recipient-bound link after deadline
    // ══════════════════════════════════════════════════════════════════════════════

    function test_reclaim_recipientBound_afterDeadline() public {
        uint40 deadline = uint40(block.timestamp + 1 days);
        vm.prank(SENDER);
        uint256 idx = vault.createCustomLink{value: 1 ether}(
            address(0), 0, 1 ether, 0, LINK_PUBKEY, SENDER, false, RECIPIENT, deadline
        );

        vm.warp(deadline + 1);
        uint256 balBefore = SENDER.balance;
        vm.prank(SENDER);
        vault.reclaim(idx);
        assertEq(SENDER.balance, balBefore + 1 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createLinkWithFees on vault without feeToken reverts
    // ══════════════════════════════════════════════════════════════════════════════

    function test_RevertIf_feeTokenNotConfigured() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        // Sign against vaultNoFeeToken
        bytes memory authSig = _signFeeAuthForVault(address(vaultNoFeeToken), req, SENDER, 0.01 ether, 0, false, 0);

        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.01 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.FeeTokenNotConfigured.selector);
        vaultNoFeeToken.createLinkWithFees{value: 1 ether}(req, auth);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ERC-1155 deposit with contractType=3 in createCustomLinks
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createCustomLinks_erc1155() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(erc1155);
        uint8[] memory types = new uint8[](1);
        types[0] = 3;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 2;
        address[] memory keys = new address[](1);
        keys[0] = LINK_PUBKEY;
        bool[] memory mfas = new bool[](1);

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createCustomLinks(tokens, types, amounts, tokenIds, keys, mfas);
        assertEq(indexes.length, 1);
        assertEq(vault.getLinkAsset(indexes[0]).tokenId, 2);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ERC-721 in createCustomLinks
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createCustomLinks_erc721() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(erc721);
        uint8[] memory types = new uint8[](1);
        types[0] = 2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        address[] memory keys = new address[](1);
        keys[0] = LINK_PUBKEY;
        bool[] memory mfas = new bool[](1);

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createCustomLinks(tokens, types, amounts, tokenIds, keys, mfas);
        assertEq(indexes.length, 1);
        assertEq(erc721.ownerOf(3), address(vault));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ══════════════════════════════════════════════════════════════════════════════

    function _makeGaslessEthLink(uint256 amount) internal returns (uint256) {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: amount,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0, 0.01 ether, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0.01 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });
        vm.prank(SENDER);
        return vault.createLinkWithFees{value: amount}(req, auth);
    }

    function _makeGaslessEthLink_mfa(uint256 amount) internal returns (uint256) {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: amount,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: true,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0, 0.01 ether, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0.01 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });
        vm.prank(SENDER);
        return vault.createLinkWithFees{value: amount}(req, auth);
    }

    function _makeGaslessSponsoredEthLink(uint256 amount) internal returns (uint256) {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: amount,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0, 0, true, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0,
            gaslessSponsored: true,
            deadline: 0,
            signature: authSig
        });
        vm.prank(SENDER);
        return vault.createLinkWithFees{value: amount}(req, auth);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // withdrawFees — ETH path where owner contract rejects the transfer
    // Scenario: Owner is a multisig/governance contract that cannot receive ETH
    // ══════════════════════════════════════════════════════════════════════════════

    function test_RevertIf_withdrawFees_ethRejected() public {
        // Deploy a vault owned by a contract that rejects ETH
        EthRejecter rejecter = new EthRejecter();
        EnvelopeLinks rejVault = new EnvelopeLinks(BACKEND_AUTHORIZER, address(rejecter), address(feeToken));

        // Create a link with ETH service fees so that ETH accumulates in the vault
        // Since fees are ERC-20 (feeToken), we need to get ETH into accumulatedFees.
        // withdrawFees(address(0)) withdraws ETH accumulated fees.
        // Seed directly: we can call withdrawFees with ETH balance.
        vm.deal(address(rejVault), 1 ether);
        // Write to the accumulatedFees[address(0)] storage slot
        // accumulatedFees is at storage slot 5 in the contract layout
        bytes32 slot = keccak256(abi.encode(address(0), uint256(5)));
        vm.store(address(rejVault), slot, bytes32(uint256(1 ether)));

        vm.prank(address(rejecter));
        vm.expectRevert(EnvelopeLinks.EthTransferFailed.selector);
        rejVault.withdrawFees(address(0));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Claim ERC-721 and ERC-1155 via createCustomLinksWithFees
    // Scenario: Backend-authorized fee links for NFTs — full lifecycle
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimERC721_createdWithFees() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc721),
            contractType: 2,
            amount: 1,
            tokenId: 2,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0.05 ether, 0, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.05 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });

        vm.prank(SENDER);
        uint256 idx = vault.createLinkWithFees(req, auth);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        vault.claim(idx, RECIPIENT, sig);

        assertEq(erc721.ownerOf(2), RECIPIENT);
        assertTrue(vault.getLinkStatus(idx).redeemed);
    }

    function test_claimERC1155_createdWithFees() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc1155),
            contractType: 3,
            amount: 30,
            tokenId: 1,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0.02 ether, 0, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.02 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });

        vm.prank(SENDER);
        uint256 idx = vault.createLinkWithFees(req, auth);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        vault.claim(idx, RECIPIENT, sig);

        assertEq(erc1155.balanceOf(RECIPIENT, 1), 30);
        assertTrue(vault.getLinkStatus(idx).redeemed);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createCustomLinksWithFees — heterogeneous batch including ERC-721
    // Scenario: A single transaction creates ETH + ERC-20 + ERC-721 links
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createCustomLinksWithFees_withERC721() public {
        EnvelopeLinks.LinkRequest[] memory reqs = new EnvelopeLinks.LinkRequest[](2);
        reqs[0] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 0.5 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        reqs[1] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc721),
            contractType: 2,
            amount: 1,
            tokenId: 3,
            claimKey: LINK_PUBKEY2,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });

        EnvelopeLinks.FeeAuthorization[] memory auths = new EnvelopeLinks.FeeAuthorization[](2);
        auths[0] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuth(reqs[0], SENDER, 0, 0, false, 0)
        });
        auths[1] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuth(reqs[1], SENDER, 0, 0, false, 0)
        });

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createCustomLinksWithFees{value: 0.5 ether}(reqs, auths);

        assertEq(indexes.length, 2);
        assertEq(vault.getLinkAsset(indexes[0]).amount, 0.5 ether);
        assertEq(erc721.ownerOf(3), address(vault));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Reclaim ERC-20 link — creator takes back their deposited ERC-20 tokens
    // Scenario: A sender creates an ERC-20 link, then reclaims before anyone claims
    // ══════════════════════════════════════════════════════════════════════════════

    function test_reclaim_erc20() public {
        vm.prank(SENDER);
        uint256 idx = vault.createLink(address(erc20), 1, 50 ether, 0, LINK_PUBKEY);

        uint256 balBefore = erc20.balanceOf(SENDER);
        vm.prank(SENDER);
        vault.reclaim(idx);

        assertEq(erc20.balanceOf(SENDER), balBefore + 50 ether);
        assertTrue(vault.getLinkStatus(idx).redeemed);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless validation — sponsored link (gaslessSponsored=true, gaslessFee=0)
    // Scenario: Backend pre-approves gas sponsorship without requiring a prepaid fee
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_sponsoredLink_claim() public {
        uint256 idx = _makeGaslessSponsoredEthLink(1 ether);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (idx, RECIPIENT, sig));
        assertTrue(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    function test_isValidGaslessOperation_sponsoredLink_reclaim() public {
        uint256 idx = _makeGaslessSponsoredEthLink(1 ether);

        bytes memory data = abi.encodeCall(EnvelopeLinks.reclaim, (idx));
        assertTrue(vault.isValidGaslessOperation(SENDER, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless validation — MFA link requires authorization but gasless check has none
    // Scenario: A gasless link requires MFA but claimWithMFA is called without valid MFA sig
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_claimWithMFA_invalidMfaSignature() public {
        uint256 idx = _makeGaslessEthLink_mfa(1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory claimSig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        // Use a wrong signature (signed by LINK_PRIVKEY instead of BACKEND)
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(vault.ENVELOPE_SALT(), block.chainid, address(vault), idx, RECIPIENT, deadline))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIVKEY, digest);
        bytes memory wrongMfaSig = abi.encodePacked(r, s, v);

        bytes memory data = abi.encodeCall(EnvelopeLinks.claimWithMFA, (idx, RECIPIENT, claimSig, wrongMfaSig, deadline));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless validation — claim with wrong signature for claimKey
    // Scenario: Someone tries to use the gasless paymaster with an invalid claim signature
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_claim_wrongClaimSignature() public {
        uint256 idx = _makeGaslessEthLink(1 ether);
        // Sign with the wrong private key
        bytes memory wrongSig = _signClaim(LINK_PRIVKEY2, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (idx, RECIPIENT, wrongSig));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless validation — claim for already-redeemed link
    // Scenario: Paymaster is queried for an already-claimed link
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_claim_alreadyRedeemed() public {
        uint256 idx = _makeGaslessEthLink(1 ether);
        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());

        // Claim the link first
        vm.prank(RECIPIENT);
        vault.claim(idx, RECIPIENT, sig);

        // Now check gasless validation — should be false
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (idx, RECIPIENT, sig));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless validation — MFA-gated link checked via plain claim (no MFA auth)
    // Scenario: Link requires MFA but caller uses `claim()` not `claimWithMFA()`
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_claim_mfaRequiredButNotAuthorized() public {
        uint256 idx = _makeGaslessEthLink_mfa(1 ether);
        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (idx, RECIPIENT, sig));
        // claim() sets _authorized=false, but the link requiresMFA → invalid
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless validation — bound recipient claim where caller is wrong
    // Scenario: claimAsBoundRecipient called with a non-matching caller
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_claimAsBoundRecipient_wrongCaller() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: RECIPIENT,
            reclaimableAfter: uint40(block.timestamp + 1 days)
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0, 0.01 ether, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0.01 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });
        vm.prank(SENDER);
        uint256 idx = vault.createLinkWithFees{value: 1 ether}(req, auth);

        bytes memory sig = _signClaim(LINK_PRIVKEY, idx, OTHER, vault.BOUND_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claimAsBoundRecipient, (idx, OTHER, sig));
        // OTHER != RECIPIENT → gasless validation fails at _isValidClaim (recipient mismatch)
        assertFalse(vault.isValidGaslessOperation(OTHER, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createLinksNoReturn — batch deposit without index array allocation
    // Scenario: High-volume distributor uses gas-efficient batch with no return
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createLinksNoReturn_erc20() public {
        address[] memory keys = new address[](3);
        keys[0] = LINK_PUBKEY;
        keys[1] = LINK_PUBKEY2;
        keys[2] = vm.addr(uint256(keccak256("third-key")));

        uint256 balBefore = erc20.balanceOf(SENDER);
        vm.prank(SENDER);
        vault.createLinksNoReturn(address(erc20), 1, 10 ether, 0, keys);

        assertEq(erc20.balanceOf(SENDER), balBefore - 30 ether);
        assertEq(vault.getLinkCount(), 3);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // getLinkIndexesCreatedBy — filtering by creator across multiple creators
    // Scenario: Multiple creators deposit links; query filters correctly
    // ══════════════════════════════════════════════════════════════════════════════

    function test_getLinkIndexesCreatedBy_multipleCreators() public {
        // SENDER creates two links
        vm.startPrank(SENDER);
        vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY);
        vault.createLink{value: 2 ether}(address(0), 0, 2 ether, 0, LINK_PUBKEY2);
        vm.stopPrank();

        // OTHER creates one link
        vm.deal(OTHER, 5 ether);
        vm.prank(OTHER);
        vault.createLink{value: 0.5 ether}(address(0), 0, 0.5 ether, 0, LINK_PUBKEY);

        uint256[] memory senderLinks = vault.getLinkIndexesCreatedBy(SENDER);
        uint256[] memory otherLinks = vault.getLinkIndexesCreatedBy(OTHER);

        assertEq(senderLinks.length, 2);
        assertEq(otherLinks.length, 1);
        assertEq(vault.getLinkAsset(otherLinks[0]).amount, 0.5 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless reclaim — reclaim validation for a recipient-bound sponsored link
    // Scenario: Creator tries to reclaim a recipient-bound link after the deadline
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_reclaim_sponsoredAfterDeadline() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: 1 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: RECIPIENT,
            reclaimableAfter: uint40(block.timestamp + 1 days)
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0, 0, true, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0,
            gaslessSponsored: true,
            deadline: 0,
            signature: authSig
        });
        vm.prank(SENDER);
        uint256 idx = vault.createLinkWithFees{value: 1 ether}(req, auth);

        // Before deadline: reclaim should be invalid
        bytes memory data = abi.encodeCall(EnvelopeLinks.reclaim, (idx));
        assertFalse(vault.isValidGaslessOperation(SENDER, data));

        // After deadline: reclaim should be valid
        vm.warp(block.timestamp + 1 days + 1);
        assertTrue(vault.isValidGaslessOperation(SENDER, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Reclaim via createCustomLinksWithFees — ERC-721 reclaim lifecycle
    // Scenario: Creator deposits an NFT with fees, then reclaims when unclaimed
    // ══════════════════════════════════════════════════════════════════════════════

    function test_reclaim_erc721_createdWithFees() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc721),
            contractType: 2,
            amount: 1,
            tokenId: 2,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0.01 ether, 0, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.01 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });

        vm.prank(SENDER);
        uint256 idx = vault.createLinkWithFees(req, auth);
        assertEq(erc721.ownerOf(2), address(vault));

        vm.prank(SENDER);
        vault.reclaim(idx);
        assertEq(erc721.ownerOf(2), SENDER);
    }

    function test_reclaim_erc1155_createdWithFees() public {
        EnvelopeLinks.LinkRequest memory req = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc1155),
            contractType: 3,
            amount: 25,
            tokenId: 2,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        bytes memory authSig = _signFeeAuth(req, SENDER, 0.01 ether, 0, false, 0);
        EnvelopeLinks.FeeAuthorization memory auth = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.01 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: authSig
        });

        vm.prank(SENDER);
        uint256 idx = vault.createLinkWithFees(req, auth);

        vm.prank(SENDER);
        vault.reclaim(idx);
        assertEq(erc1155.balanceOf(SENDER, 2), 50); // had 50, deposited 25, reclaimed 25
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Reclaim recipient-bound link after deadline
    // Scenario: Creator waits for reclaimableAfter before reclaiming an unclaimed link
    // ══════════════════════════════════════════════════════════════════════════════

    function test_reclaim_recipientBound_erc20_afterDeadline() public {
        vm.prank(SENDER);
        uint256 idx = vault.createCustomLink(
            address(erc20), 1, 100 ether, 0, LINK_PUBKEY, SENDER, false, RECIPIENT, uint40(block.timestamp + 7 days)
        );

        // Before deadline: should revert
        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.TooEarlyToReclaim.selector);
        vault.reclaim(idx);

        // After deadline: should succeed
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(SENDER);
        vault.reclaim(idx);
        assertTrue(vault.getLinkStatus(idx).redeemed);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Claim ERC-20 created via createCustomLinksWithFees batch
    // Scenario: Batch link creation with fees, then individual claims
    // ══════════════════════════════════════════════════════════════════════════════

    function test_claimERC20_fromCustomLinksWithFeesBatch() public {
        EnvelopeLinks.LinkRequest[] memory reqs = new EnvelopeLinks.LinkRequest[](2);
        reqs[0] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc20),
            contractType: 1,
            amount: 100 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });
        reqs[1] = EnvelopeLinks.LinkRequest({
            tokenAddress: address(erc20),
            contractType: 1,
            amount: 50 ether,
            tokenId: 0,
            claimKey: LINK_PUBKEY2,
            onBehalfOf: SENDER,
            withMFA: false,
            recipient: address(0),
            reclaimableAfter: 0
        });

        EnvelopeLinks.FeeAuthorization[] memory auths = new EnvelopeLinks.FeeAuthorization[](2);
        auths[0] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.01 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuth(reqs[0], SENDER, 0.01 ether, 0, false, 0)
        });
        auths[1] = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0.01 ether,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuth(reqs[1], SENDER, 0.01 ether, 0, false, 0)
        });

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createCustomLinksWithFees(reqs, auths);

        // Claim first link
        bytes memory sig = _signClaim(LINK_PRIVKEY, indexes[0], RECIPIENT, vault.OPEN_CLAIM_MODE());
        vault.claim(indexes[0], RECIPIENT, sig);
        assertEq(erc20.balanceOf(RECIPIENT), 100 ether);

        // Claim second link
        bytes memory sig2 = _signClaim(LINK_PRIVKEY2, indexes[1], OTHER, vault.OPEN_CLAIM_MODE());
        vault.claim(indexes[1], OTHER, sig2);
        assertEq(erc20.balanceOf(OTHER), 50 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless validation — claim with out-of-bounds index
    // Scenario: Paymaster is queried for a non-existent link index
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_claim_indexOutOfBounds() public view {
        bytes memory sig = _signClaim(LINK_PRIVKEY, 999, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (999, RECIPIENT, sig));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Gasless reclaim — link is redeemed but has gasless fee (should fail)
    // Scenario: Double-reclaim attempt via paymaster after already reclaimed
    // ══════════════════════════════════════════════════════════════════════════════

    function test_isValidGaslessOperation_reclaim_redeemedGaslessLink() public {
        uint256 idx = _makeGaslessEthLink(1 ether);

        // Reclaim the link
        vm.prank(SENDER);
        vault.reclaim(idx);

        // Now query gasless reclaim validation — should return false (redeemed)
        bytes memory data = abi.encodeCall(EnvelopeLinks.reclaim, (idx));
        assertFalse(vault.isValidGaslessOperation(SENDER, data));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Raffle links — ERC-20 raffle distributing different amounts to one claimKey
    // Scenario: Airdrop with randomized amounts using a single shared claimKey
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createRaffleLinks_erc20() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10 ether;
        amounts[1] = 20 ether;
        amounts[2] = 5 ether;

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createRaffleLinks(address(erc20), 1, amounts, LINK_PUBKEY);

        assertEq(indexes.length, 3);
        assertEq(vault.getLinkAsset(indexes[0]).amount, 10 ether);
        assertEq(vault.getLinkAsset(indexes[1]).amount, 20 ether);
        assertEq(vault.getLinkAsset(indexes[2]).amount, 5 ether);
        // Total 35 ether transferred from sender
        assertEq(erc20.balanceOf(address(vault)), 35 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // createCustomLinks — ERC-1155 in a heterogeneous batch (no fees)
    // Scenario: One-shot batch deposits across ETH and ERC-1155
    // ══════════════════════════════════════════════════════════════════════════════

    function test_createCustomLinks_ethAndErc1155() public {
        address[] memory addrs = new address[](2);
        addrs[0] = address(0);
        addrs[1] = address(erc1155);

        uint8[] memory types = new uint8[](2);
        types[0] = 0;
        types[1] = 3;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = 10;

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;

        address[] memory keys = new address[](2);
        keys[0] = LINK_PUBKEY;
        keys[1] = LINK_PUBKEY2;

        bool[] memory mfas = new bool[](2);
        mfas[0] = false;
        mfas[1] = false;

        vm.prank(SENDER);
        uint256[] memory indexes = vault.createCustomLinks{value: 0.5 ether}(addrs, types, amounts, tokenIds, keys, mfas);

        assertEq(indexes.length, 2);
        assertEq(vault.getLinkAsset(indexes[0]).contractType, 0);
        assertEq(vault.getLinkAsset(indexes[1]).contractType, 3);
        assertEq(erc1155.balanceOf(address(vault), 1), 10);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ERC-1155 batch receive hook — internal batch transfers succeed
    // Scenario: The vault itself performs a batch transfer in (triggered by ERC-1155 deposit)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_onERC1155BatchReceived_internalTransfer() public {
        // The onERC1155BatchReceived success path is only reachable when operator == vault address.
        // We can call it directly to verify the selector is returned.
        bytes4 result = vault.onERC1155BatchReceived(
            address(vault), SENDER, new uint256[](1), new uint256[](1), ""
        );
        assertEq(result, vault.onERC1155BatchReceived.selector);
    }
}

/// @dev Helper contract that rejects ETH transfers
contract EthRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

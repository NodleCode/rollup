// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/EnvelopeLinks.sol";
import {EnvelopeFeeAuthTestUtils} from "./EnvelopeFeeAuthTestUtils.sol";
import {EnvelopeEIP712Utils} from "./EnvelopeEIP712Utils.sol";
import "./mocks/ERC20Mock.sol";

contract EnvelopeLinksGaslessTest is Test {
    EnvelopeLinks public vault;
    ERC20Mock public feeToken;

    uint256 public constant LINK_PRIVKEY = uint256(keccak256("link-key"));
    address public LINK_PUBKEY;

    uint256 public constant BACKEND_PRIVKEY = uint256(keccak256("nodle.vault.backend-authorizer"));
    address public BACKEND_AUTHORIZER;

    address public constant SENDER = address(0xA11CE);
    address public constant RECIPIENT = address(0xB0B);

    function setUp() public {
        LINK_PUBKEY = vm.addr(LINK_PRIVKEY);
        BACKEND_AUTHORIZER = vm.addr(BACKEND_PRIVKEY);

        feeToken = new ERC20Mock();
        vault = new EnvelopeLinks(BACKEND_AUTHORIZER, address(this), address(feeToken));

        vm.deal(SENDER, 10 ether);
        feeToken.mint(SENDER, 1_000 ether);

        vm.prank(SENDER);
        feeToken.approve(address(vault), type(uint256).max);
    }

    function _request(uint256 amount, bool withMFA, address recipient, uint40 reclaimableAfter)
        internal
        view
        returns (EnvelopeLinks.LinkRequest memory)
    {
        return EnvelopeLinks.LinkRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: amount,
            tokenId: 0,
            claimKey: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: withMFA,
            recipient: recipient,
            reclaimableAfter: reclaimableAfter
        });
    }

    function _signFeeAuthorization(
        EnvelopeLinks.LinkRequest memory request,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signFeeAuthorization(request, feePayer, serviceFee, gaslessFee, false, deadline);
    }

    function _signFeeAuthorization(
        EnvelopeLinks.LinkRequest memory request,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = EnvelopeFeeAuthTestUtils.feeAuthorizationDigest(
            address(vault), request, feePayer, serviceFee, gaslessFee, gaslessSponsored, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _feeAuthorization(
        EnvelopeLinks.LinkRequest memory request,
        uint256 serviceFee,
        uint256 gaslessFee,
        uint256 deadline
    ) internal view returns (EnvelopeLinks.FeeAuthorization memory) {
        return _feeAuthorization(request, serviceFee, gaslessFee, false, deadline);
    }

    function _feeAuthorization(
        EnvelopeLinks.LinkRequest memory request,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (EnvelopeLinks.FeeAuthorization memory) {
        return EnvelopeLinks.FeeAuthorization({
            serviceFee: serviceFee,
            gaslessFee: gaslessFee,
            gaslessSponsored: gaslessSponsored,
            deadline: deadline,
            signature: _signFeeAuthorization(request, SENDER, serviceFee, gaslessFee, gaslessSponsored, deadline)
        });
    }

    function _signWithdrawal(uint256 depositIndex, address recipient, bytes32 mode)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = EnvelopeEIP712Utils.claimDigest(address(vault), depositIndex, recipient, mode);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signMfa(uint256 depositIndex, address recipient, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = EnvelopeEIP712Utils.mfaDigest(address(vault), depositIndex, recipient, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeGaslessDeposit(uint256 amount, bool withMFA, address recipient, uint40 reclaimableAfter)
        internal
        returns (uint256)
    {
        EnvelopeLinks.LinkRequest memory request = _request(amount, withMFA, recipient, reclaimableAfter);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0.01 ether, 0.02 ether, 0);

        vm.prank(SENDER);
        return vault.createLinkWithFees{value: amount}(request, authorization);
    }

    function test_MakeCustomDepositWithFeesCollectsFeesAtDeposit() public {
        uint256 amount = 1 ether;
        uint256 serviceFee = 0.01 ether;
        uint256 gaslessFee = 0.02 ether;
        EnvelopeLinks.LinkRequest memory request = _request(amount, true, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, serviceFee, gaslessFee, 0);

        vm.prank(SENDER);
        uint256 index = vault.createLinkWithFees{value: amount}(request, authorization);

        EnvelopeLinks.LinkAsset memory asset = vault.getLinkAsset(index);
        EnvelopeLinks.LinkFees memory fees = vault.getLinkFees(index);
        EnvelopeLinks.LinkStatus memory status = vault.getLinkStatus(index);
        assertEq(asset.amount, amount);
        assertEq(fees.serviceFee, serviceFee);
        assertEq(fees.gaslessFee, gaslessFee);
        assertFalse(status.gaslessSponsored);
        assertEq(feeToken.balanceOf(address(vault)), serviceFee + gaslessFee);
        assertEq(vault.accumulatedFees(), serviceFee + gaslessFee);
    }

    function test_SponsoredGaslessAuthorizationApprovesPaymasterWithoutGaslessFee() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0, true, 0);

        vm.prank(SENDER);
        uint256 index = vault.createLinkWithFees{value: 1 ether}(request, authorization);

        EnvelopeLinks.LinkFees memory fees = vault.getLinkFees(index);
        EnvelopeLinks.LinkStatus memory status = vault.getLinkStatus(index);
        assertEq(fees.gaslessFee, 0);
        assertTrue(status.gaslessSponsored);
        assertEq(feeToken.balanceOf(address(vault)), 0);

        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory callData = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));
        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));
    }

    function test_SponsoredGaslessMfaClaimIsApprovedWithoutCollectedGaslessFee() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, true, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0, true, 0);

        vm.prank(SENDER);
        uint256 index = vault.createLinkWithFees{value: 1 ether}(request, authorization);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory mfaSig = _signMfa(index, RECIPIENT, deadline);
        bytes memory callData =
            abi.encodeCall(EnvelopeLinks.claimWithMFA, (index, RECIPIENT, withdrawalSig, mfaSig, deadline));

        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));
        assertEq(feeToken.balanceOf(address(vault)), 0);
    }

    function test_ZeroFeeAuthorizationWithBackendSignatureIsAccepted() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, true, RECIPIENT, uint40(block.timestamp + 1 days));
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0, 0);

        vm.prank(SENDER);
        uint256 index = vault.createLinkWithFees{value: 1 ether}(request, authorization);

        EnvelopeLinks.LinkFees memory fees = vault.getLinkFees(index);
        EnvelopeLinks.LinkStatus memory status = vault.getLinkStatus(index);
        assertEq(fees.serviceFee, 0);
        assertEq(fees.gaslessFee, 0);
        assertFalse(status.gaslessSponsored);
        assertEq(feeToken.balanceOf(address(vault)), 0);
        assertEq(vault.accumulatedFees(), 0);
    }

    function test_ZeroFeeAuthorizationWithoutSignatureRemainsOpen() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0, gaslessFee: 0, gaslessSponsored: false, deadline: 0, signature: ""
        });

        vm.prank(SENDER);
        uint256 index = vault.createLinkWithFees{value: 1 ether}(request, authorization);

        EnvelopeLinks.LinkFees memory fees = vault.getLinkFees(index);
        assertEq(fees.serviceFee, 0);
        assertEq(fees.gaslessFee, 0);
    }

    function test_RevertIf_ZeroFeeAuthorizationSignatureWrong() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuthorization(request, address(0xBAD), 0, 0, 0)
        });

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.WrongFeeAuthorizationSignature.selector);
        vault.createLinkWithFees{value: 1 ether}(request, authorization);
    }

    function test_RevertIf_SponsoredGaslessFlagTampered() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0, false, 0);
        authorization.gaslessSponsored = true;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.WrongFeeAuthorizationSignature.selector);
        vault.createLinkWithFees{value: 1 ether}(request, authorization);
    }

    function test_RevertIf_FeeTokenNotConfigured() public {
        EnvelopeLinks vaultWithoutFeeToken = new EnvelopeLinks(BACKEND_AUTHORIZER, address(this), address(0));
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0.01 ether, 0);

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.FeeTokenNotConfigured.selector);
        vaultWithoutFeeToken.createLinkWithFees{value: 1 ether}(request, authorization);
    }

    function test_RevertIf_FeeAuthorizationExpired() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        uint256 deadline = block.timestamp + 1 hours;
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0.01 ether, deadline);

        vm.warp(deadline + 1);

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.FeeAuthorizationExpired.selector);
        vault.createLinkWithFees{value: 1 ether}(request, authorization);
    }

    function test_RevertIf_WrongFeeAuthorizationSignature() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0.01 ether, 0);
        authorization.gaslessFee = 0.02 ether;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeLinks.WrongFeeAuthorizationSignature.selector);
        vault.createLinkWithFees{value: 1 ether}(request, authorization);
    }

    function test_IsValidGaslessClaim() public {
        uint256 index = _makeGaslessDeposit(1 ether, false, address(0), 0);
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory callData = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));

        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));
        assertFalse(vault.isValidGaslessOperation(SENDER, callData));
    }

    function test_IsValidGaslessMfaClaim() public {
        uint256 index = _makeGaslessDeposit(1 ether, true, address(0), 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory mfaSig = _signMfa(index, RECIPIENT, deadline);
        bytes memory callData =
            abi.encodeCall(EnvelopeLinks.claimWithMFA, (index, RECIPIENT, withdrawalSig, mfaSig, deadline));

        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));

        vm.warp(deadline + 1);
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, callData));
    }

    function test_IsValidGaslessRecipientBoundClaim() public {
        uint256 index = _makeGaslessDeposit(1 ether, false, RECIPIENT, uint40(block.timestamp + 1 days));
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory callData = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));

        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));
        assertFalse(vault.isValidGaslessOperation(address(0xCAFE), callData));
    }

    function test_IsValidGaslessReclaimAfterDelay() public {
        uint40 reclaimableAfter = uint40(block.timestamp + 1 days);
        uint256 index = _makeGaslessDeposit(1 ether, false, RECIPIENT, reclaimableAfter);
        bytes memory callData = abi.encodeCall(EnvelopeLinks.reclaim, (index));

        assertFalse(vault.isValidGaslessOperation(SENDER, callData));

        vm.warp(reclaimableAfter + 1);
        assertTrue(vault.isValidGaslessOperation(SENDER, callData));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, callData));
    }

    function test_ZeroGaslessFeeDoesNotApprovePaymaster() public {
        EnvelopeLinks.LinkRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeLinks.FeeAuthorization memory authorization = _feeAuthorization(request, 0.01 ether, 0, 0);

        vm.prank(SENDER);
        uint256 index = vault.createLinkWithFees{value: 1 ether}(request, authorization);

        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.OPEN_CLAIM_MODE());
        bytes memory callData = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));

        assertFalse(vault.isValidGaslessOperation(RECIPIENT, callData));
    }
}

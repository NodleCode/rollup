// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/envelope/V4/EnvelopeVault.sol";
import "./mocks/ERC20Mock.sol";

contract EnvelopeVaultGaslessTest is Test {
    EnvelopeVault public vault;
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
        vault = new EnvelopeVault(BACKEND_AUTHORIZER, address(this), address(feeToken));

        vm.deal(SENDER, 10 ether);
        feeToken.mint(SENDER, 1_000 ether);

        vm.prank(SENDER);
        feeToken.approve(address(vault), type(uint256).max);
    }

    function _request(uint256 amount, bool withMFA, address recipient, uint40 reclaimableAfter)
        internal
        view
        returns (EnvelopeVault.DepositRequest memory)
    {
        return EnvelopeVault.DepositRequest({
            tokenAddress: address(0),
            contractType: 0,
            amount: amount,
            tokenId: 0,
            pubKey20: LINK_PUBKEY,
            onBehalfOf: SENDER,
            withMFA: withMFA,
            recipient: recipient,
            reclaimableAfter: reclaimableAfter
        });
    }

    function _signFeeAuthorization(
        EnvelopeVault.DepositRequest memory request,
        address feePayer,
        uint256 serviceFee,
        uint256 gaslessFee,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encode(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    feePayer,
                    request.tokenAddress,
                    request.contractType,
                    request.amount,
                    request.tokenId,
                    request.pubKey20,
                    request.onBehalfOf,
                    request.withMFA,
                    request.recipient,
                    request.reclaimableAfter,
                    serviceFee,
                    gaslessFee,
                    deadline
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _feeAuthorization(
        EnvelopeVault.DepositRequest memory request,
        uint256 serviceFee,
        uint256 gaslessFee,
        uint256 deadline
    ) internal view returns (EnvelopeVault.FeeAuthorization memory) {
        return EnvelopeVault.FeeAuthorization({
            serviceFee: serviceFee,
            gaslessFee: gaslessFee,
            deadline: deadline,
            signature: _signFeeAuthorization(request, SENDER, serviceFee, gaslessFee, deadline)
        });
    }

    function _signWithdrawal(uint256 depositIndex, address recipient, bytes32 mode)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(vault.ENVELOPE_SALT(), block.chainid, address(vault), depositIndex, recipient, mode)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signMfa(uint256 depositIndex, address recipient, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(), block.chainid, address(vault), depositIndex, recipient, deadline
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeGaslessDeposit(uint256 amount, bool withMFA, address recipient, uint40 reclaimableAfter)
        internal
        returns (uint256)
    {
        EnvelopeVault.DepositRequest memory request = _request(amount, withMFA, recipient, reclaimableAfter);
        EnvelopeVault.FeeAuthorization memory authorization = _feeAuthorization(request, 0.01 ether, 0.02 ether, 0);

        vm.prank(SENDER);
        return vault.makeCustomDepositWithFees{value: amount}(request, authorization);
    }

    function test_MakeCustomDepositWithFeesCollectsFeesAtDeposit() public {
        uint256 amount = 1 ether;
        uint256 serviceFee = 0.01 ether;
        uint256 gaslessFee = 0.02 ether;
        EnvelopeVault.DepositRequest memory request = _request(amount, true, address(0), 0);
        EnvelopeVault.FeeAuthorization memory authorization = _feeAuthorization(request, serviceFee, gaslessFee, 0);

        vm.prank(SENDER);
        uint256 index = vault.makeCustomDepositWithFees{value: amount}(request, authorization);

        EnvelopeVault.Deposit memory deposit = vault.getDeposit(index);
        assertEq(deposit.amount, amount);
        assertEq(deposit.serviceFee, serviceFee);
        assertEq(deposit.gaslessFee, gaslessFee);
        assertEq(feeToken.balanceOf(address(vault)), serviceFee + gaslessFee);
        assertEq(vault.accumulatedFees(address(feeToken)), serviceFee + gaslessFee);
    }

    function test_RevertIf_FeeTokenNotConfigured() public {
        EnvelopeVault vaultWithoutFeeToken = new EnvelopeVault(BACKEND_AUTHORIZER, address(this), address(0));
        EnvelopeVault.DepositRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeVault.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0.01 ether, 0);

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeVault.FeeTokenNotConfigured.selector);
        vaultWithoutFeeToken.makeCustomDepositWithFees{value: 1 ether}(request, authorization);
    }

    function test_RevertIf_FeeAuthorizationExpired() public {
        EnvelopeVault.DepositRequest memory request = _request(1 ether, false, address(0), 0);
        uint256 deadline = block.timestamp + 1 hours;
        EnvelopeVault.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0.01 ether, deadline);

        vm.warp(deadline + 1);

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeVault.FeeAuthorizationExpired.selector);
        vault.makeCustomDepositWithFees{value: 1 ether}(request, authorization);
    }

    function test_RevertIf_WrongFeeAuthorizationSignature() public {
        EnvelopeVault.DepositRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeVault.FeeAuthorization memory authorization = _feeAuthorization(request, 0, 0.01 ether, 0);
        authorization.gaslessFee = 0.02 ether;

        vm.prank(SENDER);
        vm.expectRevert(EnvelopeVault.WrongFeeAuthorizationSignature.selector);
        vault.makeCustomDepositWithFees{value: 1 ether}(request, authorization);
    }

    function test_IsValidGaslessClaim() public {
        uint256 index = _makeGaslessDeposit(1 ether, false, address(0), 0);
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.ANYONE_WITHDRAWAL_MODE());
        bytes memory callData = abi.encodeCall(EnvelopeVault.withdrawDeposit, (index, RECIPIENT, withdrawalSig));

        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));
        assertFalse(vault.isValidGaslessOperation(SENDER, callData));
    }

    function test_IsValidGaslessMfaClaim() public {
        uint256 index = _makeGaslessDeposit(1 ether, true, address(0), 0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.ANYONE_WITHDRAWAL_MODE());
        bytes memory mfaSig = _signMfa(index, RECIPIENT, deadline);
        bytes memory callData =
            abi.encodeCall(EnvelopeVault.withdrawMFADeposit, (index, RECIPIENT, withdrawalSig, mfaSig, deadline));

        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));

        vm.warp(deadline + 1);
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, callData));
    }

    function test_IsValidGaslessRecipientBoundClaim() public {
        uint256 index = _makeGaslessDeposit(1 ether, false, RECIPIENT, uint40(block.timestamp + 1 days));
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.ANYONE_WITHDRAWAL_MODE());
        bytes memory callData = abi.encodeCall(EnvelopeVault.withdrawDeposit, (index, RECIPIENT, withdrawalSig));

        assertTrue(vault.isValidGaslessOperation(RECIPIENT, callData));
        assertFalse(vault.isValidGaslessOperation(address(0xCAFE), callData));
    }

    function test_IsValidGaslessReclaimAfterDelay() public {
        uint40 reclaimableAfter = uint40(block.timestamp + 1 days);
        uint256 index = _makeGaslessDeposit(1 ether, false, RECIPIENT, reclaimableAfter);
        bytes memory callData = abi.encodeCall(EnvelopeVault.withdrawDepositSender, (index));

        assertFalse(vault.isValidGaslessOperation(SENDER, callData));

        vm.warp(reclaimableAfter + 1);
        assertTrue(vault.isValidGaslessOperation(SENDER, callData));
        assertFalse(vault.isValidGaslessOperation(RECIPIENT, callData));
    }

    function test_ZeroGaslessFeeDoesNotApprovePaymaster() public {
        EnvelopeVault.DepositRequest memory request = _request(1 ether, false, address(0), 0);
        EnvelopeVault.FeeAuthorization memory authorization = _feeAuthorization(request, 0.01 ether, 0, 0);

        vm.prank(SENDER);
        uint256 index = vault.makeCustomDepositWithFees{value: 1 ether}(request, authorization);

        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT, vault.ANYONE_WITHDRAWAL_MODE());
        bytes memory callData = abi.encodeCall(EnvelopeVault.withdrawDeposit, (index, RECIPIENT, withdrawalSig));

        assertFalse(vault.isValidGaslessOperation(RECIPIENT, callData));
    }
}

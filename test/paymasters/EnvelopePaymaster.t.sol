// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {BasePaymaster, BOOTLOADER_FORMAL_ADDRESS} from "../../src/paymasters/BasePaymaster.sol";
import {EnvelopePaymaster} from "../../src/paymasters/EnvelopePaymaster.sol";
import {EnvelopeLinks} from "../../src/envelope/EnvelopeLinks.sol";
import {ERC20Mock} from "../envelope/mocks/ERC20Mock.sol";
import {EnvelopeFeeAuthTestUtils} from "../envelope/EnvelopeFeeAuthTestUtils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract EnvelopePaymasterTest is Test {
    EnvelopeLinks public vault;
    EnvelopePaymaster public paymaster;
    ERC20Mock public feeToken;

    address public constant ADMIN = address(0xA11CE);
    address public constant WITHDRAWER = address(0xB0B);
    address public constant SENDER = address(0xCAFE);
    address public constant RECIPIENT = address(0xD00D);

    uint256 public constant LINK_PRIVKEY = uint256(keccak256("link-key"));
    address public LINK_PUBKEY;

    uint256 public constant BACKEND_PRIVKEY = uint256(keccak256("nodle.vault.backend-authorizer"));
    address public BACKEND_AUTHORIZER;

    function setUp() public {
        LINK_PUBKEY = vm.addr(LINK_PRIVKEY);
        BACKEND_AUTHORIZER = vm.addr(BACKEND_PRIVKEY);

        feeToken = new ERC20Mock();
        vault = new EnvelopeLinks(BACKEND_AUTHORIZER, address(this), address(feeToken));
        paymaster = new EnvelopePaymaster(ADMIN, WITHDRAWER, address(vault));

        vm.deal(SENDER, 10 ether);
        vm.deal(address(paymaster), 1 ether);
        feeToken.mint(SENDER, 1_000 ether);

        vm.prank(SENDER);
        feeToken.approve(address(vault), type(uint256).max);
    }

    function _request(uint256 amount) internal view returns (EnvelopeLinks.LinkRequest memory) {
        return EnvelopeLinks.LinkRequest({
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
    }

    function _signFeeAuthorization(
        EnvelopeLinks.LinkRequest memory request,
        uint256 serviceFee,
        uint256 gaslessFee,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signFeeAuthorization(request, serviceFee, gaslessFee, false, deadline);
    }

    function _signFeeAuthorization(
        EnvelopeLinks.LinkRequest memory request,
        uint256 serviceFee,
        uint256 gaslessFee,
        bool gaslessSponsored,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = EnvelopeFeeAuthTestUtils.feeAuthorizationDigest(
            vault.ENVELOPE_SALT(),
            address(vault),
            request,
            SENDER,
            serviceFee,
            gaslessFee,
            gaslessSponsored,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BACKEND_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeGaslessDeposit(uint256 amount) internal returns (uint256) {
        EnvelopeLinks.LinkRequest memory request = _request(amount);
        EnvelopeLinks.FeeAuthorization memory authorization = EnvelopeLinks.FeeAuthorization({
            serviceFee: 0,
            gaslessFee: 0.01 ether,
            gaslessSponsored: false,
            deadline: 0,
            signature: _signFeeAuthorization(request, 0, 0.01 ether, 0)
        });

        vm.prank(SENDER);
        return vault.createLinkWithFees{value: amount}(request, authorization);
    }

    function _signWithdrawal(uint256 depositIndex, address recipient) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    vault.ENVELOPE_SALT(),
                    block.chainid,
                    address(vault),
                    depositIndex,
                    recipient,
                    vault.OPEN_CLAIM_MODE()
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LINK_PRIVKEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildTransaction(address from, address to, bytes memory data, uint256 gasLimit, uint256 maxFeePerGas)
        internal
        pure
        returns (Transaction memory)
    {
        Transaction memory txn;
        txn.from = uint256(uint160(from));
        txn.to = uint256(uint160(to));
        txn.gasLimit = gasLimit;
        txn.maxFeePerGas = maxFeePerGas;
        txn.data = data;
        txn.paymasterInput = abi.encodeWithSelector(IPaymasterFlow.general.selector, "");
        return txn;
    }

    function test_ValidateAndPayForGaslessEnvelopeClaim() public {
        uint256 index = _makeGaslessDeposit(1 ether);
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT);
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));

        uint256 gasLimit = 100_000;
        uint256 maxFeePerGas = 1 gwei;
        uint256 requiredETH = gasLimit * maxFeePerGas;
        Transaction memory txn = _buildTransaction(RECIPIENT, address(vault), data, gasLimit, maxFeePerGas);

        uint256 bootloaderBalBefore = BOOTLOADER_FORMAL_ADDRESS.balance;

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        (bytes4 magic,) = paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);

        assertEq(magic, paymaster.validateAndPayForPaymasterTransaction.selector);
        assertEq(BOOTLOADER_FORMAL_ADDRESS.balance, bootloaderBalBefore + requiredETH);
    }

    function test_RevertIf_DestinationIsNotEnvelopeLinks() public {
        uint256 index = _makeGaslessDeposit(1 ether);
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT);
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));
        Transaction memory txn = _buildTransaction(RECIPIENT, address(feeToken), data, 100_000, 1 gwei);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(EnvelopePaymaster.DestinationIsNotEnvelopeLinks.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_EnvelopeOperationNotApproved() public {
        vm.prank(SENDER);
        uint256 index = vault.createLink{value: 1 ether}(address(0), 0, 1 ether, 0, LINK_PUBKEY);

        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT);
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));
        Transaction memory txn = _buildTransaction(RECIPIENT, address(vault), data, 100_000, 1 gwei);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(EnvelopePaymaster.EnvelopeGaslessOperationNotApproved.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_PaymasterBalanceTooLow() public {
        uint256 index = _makeGaslessDeposit(1 ether);
        bytes memory withdrawalSig = _signWithdrawal(index, RECIPIENT);
        bytes memory data = abi.encodeCall(EnvelopeLinks.claim, (index, RECIPIENT, withdrawalSig));
        Transaction memory txn = _buildTransaction(RECIPIENT, address(vault), data, 2 ether, 1);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(EnvelopePaymaster.PaymasterBalanceTooLow.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_ApprovalBasedFlow() public {
        Transaction memory txn;
        txn.from = uint256(uint160(RECIPIENT));
        txn.to = uint256(uint160(address(vault)));
        txn.gasLimit = 100_000;
        txn.maxFeePerGas = 1 gwei;
        txn.paymasterInput = abi.encodeWithSelector(IPaymasterFlow.approvalBased.selector, address(feeToken), 1, "");

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(BasePaymaster.PaymasterFlowNotSupported.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    /// @dev When the vault's isValidGaslessOperation reverts (e.g. malformed calldata
    ///      that causes an ABI decode error), the paymaster catches the revert and
    ///      treats it as "not approved" rather than bubbling up the revert.
    function test_RevertIf_EnvelopeOperationRevertsInternally() public {
        // Build a transaction with a valid selector but truncated calldata
        // that will cause abi.decode inside isValidGaslessOperation to revert
        bytes memory malformedData = abi.encodePacked(EnvelopeLinks.claim.selector, bytes28(0));
        Transaction memory txn = _buildTransaction(RECIPIENT, address(vault), malformedData, 100_000, 1 gwei);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(EnvelopePaymaster.EnvelopeGaslessOperationNotApproved.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }
}

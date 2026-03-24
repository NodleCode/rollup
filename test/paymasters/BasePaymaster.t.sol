// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {
    BasePaymaster,
    BOOTLOADER_FORMAL_ADDRESS
} from "../../src/paymasters/BasePaymaster.sol";
import {IPaymasterFlow} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {ExecutionResult} from "lib/era-contracts/l2-contracts/contracts/interfaces/IPaymaster.sol";

contract MockPaymaster is BasePaymaster {
    event MockPaymasterCalled();

    constructor(address admin, address withdrawer) BasePaymaster(admin, withdrawer) {}

    function _validateAndPayGeneralFlow(address, address, uint256) internal override {
        emit MockPaymasterCalled();
    }

    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        override
    {
        emit MockPaymasterCalled();
    }
}

/// @dev Contract that rejects ETH transfers (used to test FailedToWithdraw).
contract ETHRejecter {
    receive() external payable {
        revert("rejected");
    }
}

contract BasePaymasterTest is Test {
    MockPaymaster private paymaster;

    address internal alice = vm.addr(1); // owner
    address internal bob = vm.addr(2); // withdrawer
    address internal charlie = vm.addr(3); // user

    function setUp() public {
        paymaster = new MockPaymaster(alice, bob);
        vm.deal(address(paymaster), 10 ether);
    }

    // --------------- ACLs ---------------

    function test_defaultACLs() public view {
        assert(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), alice));
        assert(paymaster.hasRole(paymaster.WITHDRAWER_ROLE(), bob));
    }

    // --------------- withdraw ---------------

    function test_withdrawExcessETH() public {
        vm.prank(bob);
        vm.expectEmit();
        emit BasePaymaster.Withdrawn(bob, 1 ether);
        paymaster.withdraw(bob, 1 ether);

        assertEq(address(paymaster).balance, 9 ether);
        assertEq(address(bob).balance, 1 ether);
    }

    function test_RevertIf_withdrawCalledByNonWithdrawer() public {
        vm.prank(charlie);
        vm.expectRevert();
        paymaster.withdraw(charlie, 1 ether);
    }

    function test_RevertIf_withdrawToContractThatRejectsETH() public {
        ETHRejecter rejecter = new ETHRejecter();
        vm.prank(bob);
        vm.expectRevert(BasePaymaster.FailedToWithdraw.selector);
        paymaster.withdraw(address(rejecter), 1 ether);
    }

    // --------------- receive ---------------

    function test_receiveETH() public {
        uint256 balBefore = address(paymaster).balance;
        (bool ok,) = address(paymaster).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(paymaster).balance, balBefore + 1 ether);
    }

    // --------------- validateAndPayForPaymasterTransaction ---------------

    function _buildTransaction(address from, address to, uint256 gasLimit, uint256 maxFeePerGas, bytes memory pmInput)
        internal
        pure
        returns (Transaction memory)
    {
        Transaction memory txn;
        txn.from = uint256(uint160(from));
        txn.to = uint256(uint160(to));
        txn.gasLimit = gasLimit;
        txn.maxFeePerGas = maxFeePerGas;
        txn.paymasterInput = pmInput;
        return txn;
    }

    function test_RevertIf_notCalledByBootloader() public {
        Transaction memory txn =
            _buildTransaction(charlie, alice, 100_000, 1 gwei, abi.encodeWithSelector(IPaymasterFlow.general.selector, ""));

        vm.prank(charlie);
        vm.expectRevert(BasePaymaster.AccessRestrictedToBootloader.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_paymasterInputTooShort() public {
        Transaction memory txn = _buildTransaction(charlie, alice, 100_000, 1 gwei, hex"aabb");

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasePaymaster.InvalidPaymasterInput.selector,
                "The standard paymaster input must be at least 4 bytes long"
            )
        );
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_RevertIf_unsupportedPaymasterFlow() public {
        // Use a random 4-byte selector that is neither general nor approvalBased
        Transaction memory txn = _buildTransaction(charlie, alice, 100_000, 1 gwei, hex"deadbeef");

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(BasePaymaster.PaymasterFlowNotSupported.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    function test_validateAndPay_generalFlow() public {
        bytes memory pmInput = abi.encodeWithSelector(IPaymasterFlow.general.selector, "");
        uint256 gasLimit = 100_000;
        uint256 maxFeePerGas = 1 gwei;
        uint256 requiredETH = gasLimit * maxFeePerGas;
        Transaction memory txn = _buildTransaction(charlie, alice, gasLimit, maxFeePerGas, pmInput);

        // Fund the bootloader address so we can check balance
        uint256 bootloaderBalBefore = BOOTLOADER_FORMAL_ADDRESS.balance;

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        (bytes4 magic,) = paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);

        assertEq(magic, paymaster.validateAndPayForPaymasterTransaction.selector);
        assertEq(BOOTLOADER_FORMAL_ADDRESS.balance, bootloaderBalBefore + requiredETH);
    }

    function test_validateAndPay_approvalBasedFlow() public {
        address token = address(0xBEEF);
        uint256 minAllowance = 1000;
        bytes memory innerData = "";
        bytes memory pmInput =
            abi.encodeWithSelector(IPaymasterFlow.approvalBased.selector, token, minAllowance, innerData);
        uint256 gasLimit = 100_000;
        uint256 maxFeePerGas = 1 gwei;
        uint256 requiredETH = gasLimit * maxFeePerGas;
        Transaction memory txn = _buildTransaction(charlie, alice, gasLimit, maxFeePerGas, pmInput);

        uint256 bootloaderBalBefore = BOOTLOADER_FORMAL_ADDRESS.balance;

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        (bytes4 magic,) = paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);

        assertEq(magic, paymaster.validateAndPayForPaymasterTransaction.selector);
        assertEq(BOOTLOADER_FORMAL_ADDRESS.balance, bootloaderBalBefore + requiredETH);
    }

    function test_RevertIf_notEnoughETHToPay() public {
        // Drain the paymaster balance first
        vm.prank(bob);
        paymaster.withdraw(bob, 10 ether);

        bytes memory pmInput = abi.encodeWithSelector(IPaymasterFlow.general.selector, "");
        uint256 gasLimit = 100_000;
        uint256 maxFeePerGas = 1 gwei;
        Transaction memory txn = _buildTransaction(charlie, alice, gasLimit, maxFeePerGas, pmInput);

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        vm.expectRevert(BasePaymaster.NotEnoughETHInPaymasterToPayForTransaction.selector);
        paymaster.validateAndPayForPaymasterTransaction(bytes32(0), bytes32(0), txn);
    }

    // --------------- postTransaction ---------------

    function test_postTransaction() public {
        Transaction memory txn = _buildTransaction(charlie, alice, 100_000, 1 gwei, "");

        vm.prank(BOOTLOADER_FORMAL_ADDRESS);
        // Should not revert
        paymaster.postTransaction("", txn, bytes32(0), bytes32(0), ExecutionResult.Success, 0);
    }

    function test_RevertIf_postTransactionNotBootloader() public {
        Transaction memory txn = _buildTransaction(charlie, alice, 100_000, 1 gwei, "");

        vm.prank(charlie);
        vm.expectRevert(BasePaymaster.AccessRestrictedToBootloader.selector);
        paymaster.postTransaction("", txn, bytes32(0), bytes32(0), ExecutionResult.Success, 0);
    }
}

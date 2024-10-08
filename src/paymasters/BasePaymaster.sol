// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {
    IPaymaster,
    ExecutionResult,
    PAYMASTER_VALIDATION_SUCCESS_MAGIC
} from "zksync-contracts/l2/system-contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "zksync-contracts/l2/system-contracts/interfaces/IPaymasterFlow.sol";
import {Transaction} from "zksync-contracts/l2/system-contracts/libraries/TransactionHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "zksync-contracts/l2/system-contracts/Constants.sol";

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @notice This smart contract serves as a base for any other paymaster contract.
abstract contract BasePaymaster is IPaymaster, AccessControl {
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    /**
     * @notice Emitted when the paymaster withdraws funds to the specified address.
     * @param amount The amount of funds withdrawn.
     */
    event Withdrawn(address to, uint256 amount);

    error AccessRestrictedToBootloader();
    error PaymasterFlowNotSupported();
    error NotEnoughETHInPaymasterToPayForTransaction();
    error InvalidPaymasterInput(string message);
    error FailedToWithdraw();

    constructor(address admin, address withdrawer) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WITHDRAWER_ROLE, withdrawer);
    }

    function validateAndPayForPaymasterTransaction(bytes32, bytes32, Transaction calldata transaction)
        external
        payable
        returns (bytes4 magic, bytes memory /* context */ )
    {
        _mustBeBootloader();

        // By default we consider the transaction as accepted.
        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;

        if (transaction.paymasterInput.length < 4) {
            revert InvalidPaymasterInput("The standard paymaster input must be at least 4 bytes long");
        }

        bytes4 paymasterInputSelector = bytes4(transaction.paymasterInput[0:4]);

        // Note, that while the minimal amount of ETH needed is tx.gasPrice * tx.gasLimit,
        // neither paymaster nor account are allowed to access this context variable.
        uint256 requiredETH = transaction.gasLimit * transaction.maxFeePerGas;
        address destAddress = address(uint160(transaction.to));
        address userAddress = address(uint160(transaction.from));

        if (paymasterInputSelector == IPaymasterFlow.general.selector) {
            _validateAndPayGeneralFlow(userAddress, destAddress, requiredETH);
        } else if (paymasterInputSelector == IPaymasterFlow.approvalBased.selector) {
            (address token, uint256 minimalAllowance, bytes memory data) =
                abi.decode(transaction.paymasterInput[4:], (address, uint256, bytes));

            _validateAndPayApprovalBasedFlow(userAddress, destAddress, token, minimalAllowance, data, requiredETH);
        } else {
            revert PaymasterFlowNotSupported();
        }

        // The bootloader never returns any data, so it can safely be ignored here.
        (bool success,) = payable(BOOTLOADER_FORMAL_ADDRESS).call{value: requiredETH}("");
        if (!success) {
            revert NotEnoughETHInPaymasterToPayForTransaction();
        }

        return (magic, "");
    }

    function postTransaction(bytes calldata, Transaction calldata, bytes32, bytes32, ExecutionResult, uint256)
        external
        payable
        override
    {
        _mustBeBootloader();

        // Refunds are not supported yet.
    }

    function withdraw(address to, uint256 amount) external {
        _checkRole(WITHDRAWER_ROLE);

        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert FailedToWithdraw();

        emit Withdrawn(to, amount);
    }

    receive() external payable {}

    function _mustBeBootloader() internal view {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert AccessRestrictedToBootloader();
        }
    }

    function _validateAndPayGeneralFlow(address from, address to, uint256 requiredETH) internal virtual;

    function _validateAndPayApprovalBasedFlow(
        address from,
        address to,
        address token,
        uint256 tokenAmount,
        bytes memory data,
        uint256 requiredETH
    ) internal virtual;
}

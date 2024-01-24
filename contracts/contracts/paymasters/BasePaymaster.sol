// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {IPaymaster, ExecutionResult, PAYMASTER_VALIDATION_SUCCESS_MAGIC} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymasterFlow.sol";
import {TransactionHelper, Transaction} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/TransactionHelper.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";

import "@matterlabs/zksync-contracts/l2/system-contracts/Constants.sol";

/// @notice This smart contract serves as a base for any other paymaster contract.
abstract contract BasePaymaster is IPaymaster, AccessControl {
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    error PaymasterFlowNotSupported();
    error NotEnoughETHInPaymasterToPayForTransaction();

    modifier onlyBootloader() {
        require(
            msg.sender == BOOTLOADER_FORMAL_ADDRESS,
            "Only bootloader can call this method"
        );
        // Continue execution if called from the bootloader.
        _;
    }

    modifier onlyWithdrawer() {
        require(
            hasRole(WITHDRAWER_ROLE, msg.sender),
            "Only withdrawer can call this method"
        );
        _;
    }

    constructor(address admin, address withdrawer) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(WITHDRAWER_ROLE, withdrawer);
    }

    function validateAndPayForPaymasterTransaction(
        bytes32,
        bytes32,
        Transaction calldata transaction
    )
        external
        payable
        onlyBootloader
        returns (bytes4 magic, bytes memory context)
    {
        // By default we consider the transaction as accepted.
        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;
        // By default no context will be returned unless the paymaster flow requires a post transaction call.
        context = new bytes(0);

        require(
            transaction.paymasterInput.length >= 4,
            "The standard paymaster input must be at least 4 bytes long"
        );

        bytes4 paymasterInputSelector = bytes4(
            transaction.paymasterInput[0:4]
        );

        // Note, that while the minimal amount of ETH needed is tx.gasPrice * tx.gasLimit,
        // neither paymaster nor account are allowed to access this context variable.
        uint256 requiredETH = transaction.gasLimit * transaction.maxFeePerGas;
        address destAddress = address(uint160(transaction.to));
        address userAddress = address(uint160(transaction.from));

        if (paymasterInputSelector == IPaymasterFlow.general.selector) {
            _validateAndPayGeneralFlow(userAddress, destAddress, requiredETH);
        } else if (
            paymasterInputSelector == IPaymasterFlow.approvalBased.selector
        ) {
            (address token, uint256 amount, bytes memory data) = abi.decode(
                transaction.paymasterInput[4:],
                (address, uint256, bytes)
            );

            _validateAndPayApprovalBasedFlow(
                userAddress,
                destAddress,
                token,
                amount,
                data,
                requiredETH
            );
        } else {
            revert PaymasterFlowNotSupported();
        }

        // The bootloader never returns any data, so it can safely be ignored here.
        (bool success, ) = payable(BOOTLOADER_FORMAL_ADDRESS).call{
            value: requiredETH
        }("");
        if (!success) {
            revert NotEnoughETHInPaymasterToPayForTransaction();
        }
    }

    function _validateAndPayGeneralFlow(
        address from,
        address to,
        uint256 requiredETH
    ) internal virtual;

    function _validateAndPayApprovalBasedFlow(
        address from,
        address to,
        address token,
        uint256 tokenAmount,
        bytes memory data,
        uint256 requiredETH
    ) internal virtual;

    function postTransaction(
        bytes calldata context,
        Transaction calldata transaction,
        bytes32,
        bytes32,
        ExecutionResult txResult,
        uint256 maxRefundedGas
    ) external payable override onlyBootloader {
        // Refunds are not supported yet.
    }

    function withdraw(address to, uint256 amount) external onlyWithdrawer {
        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "Failed to withdraw");
    }

    receive() external payable {}
}

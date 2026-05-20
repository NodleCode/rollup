// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {BasePaymaster} from "./BasePaymaster.sol";
import {IEnvelopeGaslessValidator} from "../envelope/util/IEnvelopeGaslessValidator.sol";

/// @notice ZkSync paymaster that sponsors eligible gasless EnvelopeVault claims and reclaims.
/// @dev The EnvelopeVault remains the source of truth for whether a call is valid and prepaid or sponsored.
///      This paymaster only accepts general-flow transactions targeting that vault.
contract EnvelopePaymaster is BasePaymaster {
    IEnvelopeGaslessValidator public immutable envelopeVault;

    error DestinationIsNotEnvelopeVault();
    error EnvelopeGaslessOperationNotApproved();
    error PaymasterBalanceTooLow();

    constructor(address admin, address withdrawer, address envelopeVault_) BasePaymaster(admin, withdrawer) {
        envelopeVault = IEnvelopeGaslessValidator(envelopeVault_);
    }

    function _validateAndPayGeneralFlow(address from, address to, uint256 requiredETH, bytes memory transactionData)
        internal
        view
        override
    {
        if (to != address(envelopeVault)) revert DestinationIsNotEnvelopeVault();

        bool approved;
        try envelopeVault.isValidGaslessOperation(from, transactionData) returns (bool valid) {
            approved = valid;
        } catch {
            approved = false;
        }
        if (!approved) revert EnvelopeGaslessOperationNotApproved();

        if (address(this).balance < requiredETH) revert PaymasterBalanceTooLow();
    }

    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        pure
        override
    {
        revert PaymasterFlowNotSupported();
    }
}

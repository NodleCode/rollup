// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {BasePaymaster} from "./BasePaymaster.sol";
import {IEnvelopeGaslessValidator} from "../envelope/IEnvelopeGaslessValidator.sol";

/// @notice ZkSync paymaster that sponsors eligible gasless EnvelopeLinks claims and reclaims.
/// @dev The EnvelopeLinks remains the source of truth for whether a call is valid and prepaid or sponsored.
///      This paymaster only accepts general-flow transactions targeting that vault.
contract EnvelopePaymaster is BasePaymaster {
    IEnvelopeGaslessValidator public immutable envelopeLinks;

    error DestinationIsNotEnvelopeLinks();
    error EnvelopeGaslessOperationNotApproved();
    error PaymasterBalanceTooLow();

    constructor(address admin, address withdrawer, address envelopeLinks_) BasePaymaster(admin, withdrawer) {
        envelopeLinks = IEnvelopeGaslessValidator(envelopeLinks_);
    }

    function _validateAndPayGeneralFlow(address from, address to, uint256 requiredETH, bytes memory transactionData)
        internal
        view
        override
    {
        if (to != address(envelopeLinks)) revert DestinationIsNotEnvelopeLinks();

        bool approved;
        try envelopeLinks.isValidGaslessOperation(from, transactionData) returns (bool valid) {
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

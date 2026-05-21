// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {BasePaymaster} from "./BasePaymaster.sol";
import {IEnvelopeGaslessValidator} from "../envelope/IEnvelopeGaslessValidator.sol";

/// @notice ZkSync paymaster that sponsors eligible gasless EnvelopeLinks claims and reclaims.
/// @dev The EnvelopeLinks remains the source of truth for whether a call is valid and prepaid or sponsored.
///      This paymaster only accepts general-flow transactions targeting that vault.
contract EnvelopePaymaster is BasePaymaster {
    uint256 public constant MAX_GASLESS_ATTEMPTS_PER_LINK = 3;

    IEnvelopeGaslessValidator public immutable envelopeLinks;

    mapping(uint256 => uint256) public gaslessAttemptsByLink;

    error DestinationIsNotEnvelopeLinks();
    error EnvelopeGaslessOperationNotApproved();
    error PaymasterBalanceTooLow();
    error GaslessAttemptLimitReached(uint256 index);

    event GaslessAttemptRecorded(uint256 indexed index, uint256 indexed attempts);

    constructor(address admin, address withdrawer, address envelopeLinks_) BasePaymaster(admin, withdrawer) {
        envelopeLinks = IEnvelopeGaslessValidator(envelopeLinks_);
    }

    function _validateAndPayGeneralFlow(address from, address to, uint256 requiredETH, bytes memory transactionData)
        internal
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

        _recordGaslessAttempt(transactionData);
    }

    function _recordGaslessAttempt(bytes memory transactionData) internal {
        uint256 index = _decodeGaslessLinkIndex(transactionData);
        uint256 attempts = gaslessAttemptsByLink[index];
        if (attempts == MAX_GASLESS_ATTEMPTS_PER_LINK) revert GaslessAttemptLimitReached(index);

        unchecked {
            ++attempts;
        }
        gaslessAttemptsByLink[index] = attempts;
        emit GaslessAttemptRecorded(index, attempts);
    }

    function _decodeGaslessLinkIndex(bytes memory transactionData) internal pure returns (uint256 index) {
        if (transactionData.length < 36) revert EnvelopeGaslessOperationNotApproved();

        assembly {
            index := mload(add(transactionData, 36))
        }
    }

    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        pure
        override
    {
        revert PaymasterFlowNotSupported();
    }
}

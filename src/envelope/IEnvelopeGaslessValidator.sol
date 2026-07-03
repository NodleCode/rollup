// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

/// @notice Minimal EnvelopeLinks view used by ZkSync paymasters during validation.
interface IEnvelopeGaslessValidator {
    /// @notice Returns true when `caller` may use a paymaster for the encoded vault call.
    function isValidGaslessOperation(address caller, bytes calldata callData) external view returns (bool);
}

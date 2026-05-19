// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

/// @title IPaymaster
/// @notice Interface that a paymaster/treasury must implement to sponsor gasless
///         claim and reclaim operations on EnvelopeVault.
interface IPaymaster {
    /// @notice Called by EnvelopeVault before a sponsored operation proceeds.
    /// @dev The treasury should validate that `operator` is authorized to perform
    ///      sponsored operations and track/consume any quota. Revert to deny.
    /// @param operator The address submitting the sponsored transaction (msg.sender to vault).
    /// @param fee The gas absorption fee being paid to this treasury.
    function validateSponsoredOperation(address operator, uint256 fee) external;
}

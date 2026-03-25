// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

/// @notice Interface for bond treasuries that sponsor UUID claims.
/// @dev Implemented by contracts that hold NODL and gate sponsored claims
///      via whitelist and quota checks. Called by FleetIdentityUpgradeable
///      during `claimUuidSponsored` before the bond is pulled via `transferFrom`.
interface IBondTreasury {
    /// @notice Validate that `user` is eligible for a sponsored bond and consume quota.
    /// @dev Must revert if the user is not whitelisted or quota is exhausted.
    ///      The actual NODL transfer happens separately via `transferFrom` by the caller.
    /// @param user The address requesting a sponsored claim (the beneficiary).
    /// @param amount The bond amount being consumed.
    function consumeSponsoredBond(address user, uint256 amount) external;
}

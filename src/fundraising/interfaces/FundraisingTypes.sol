// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

/**
 * @title FundraisingTypes
 * @notice Shared enums and structs for the group fundraising system.
 * @dev Solidity interfaces cannot define enums, so shared types live here.
 *      Import this file alongside the fundraising interfaces.
 */

/// @notice Lifecycle of a single fundraise.
/// @dev `Refunding` and `Closed` are terminal. There is no path back to `Funding`,
///      and no admin path that redirects contributor funds to the beneficiary.
enum Status {
    Funding,
    Succeeded,
    Refunding,
    Closed
}

/// @notice What happens when a deadline passes with the target unmet.
/// @dev Deliberately not named `Distribute`: as an on-chain identifier that reads
///      just as easily as "distribute back to the contributors", which is the
///      opposite behavior. Product copy may still say "pay out what we raised".
enum OnMissed {
    /// @notice Every contributor may claim their money back. The default.
    Refund,
    /// @notice The beneficiary receives whatever was raised. Requires a deadline,
    ///         since with no deadline the target is never "missed".
    PayBeneficiary
}

/// @notice Parameters supplied when creating a fundraise.
/// @dev Every field is fixed for the life of the fundraise. `name` is stored on-chain
///      so a fundraise is self-describing at its own address; richer metadata (image,
///      description) stays in the app.
struct FundraiserParams {
    /// @notice Human-readable name, shown in-app.
    string name;
    /// @notice The ERC-20 collected. Must be allow-listed on the factory at creation.
    address token;
    /// @notice Target amount, in the token's smallest unit. Must be non-zero.
    /// @dev Reaching this closes contributions permanently — see the goal latch on
    ///      `IFundraiser.unpledge`. It is a close trigger, not a soft minimum.
    uint128 goal;
    /// @notice Unix timestamp after which the fundraise resolves, or `0` for open-ended.
    /// @dev An open-ended fundraise runs until it reaches its goal or is cancelled. This
    ///      is safe only because `unpledge` stays available for as long as `raised < goal`,
    ///      so contributors to a stalled open-ended fundraise can always leave.
    uint40 deadline;
    /// @notice Outcome when `deadline` passes below `goal`.
    OnMissed onMissed;
    /// @notice Receives the funds if the target is reached. Fixed at creation; only the
    ///         beneficiary itself may later repoint its own payout address.
    address beneficiary;
    /// @notice Smallest accepted contribution, or `0` for none.
    /// @dev Enforced on deposit only, and never on the path that resolves the fundraise.
    ///      A contribution that reaches `goal` is exempt, so a remaining gap smaller than
    ///      this minimum is still fillable.
    uint128 minContribution;
    /// @notice Ceiling on total contributions, or `0` for uncapped. Must be `0` or `>= goal`.
    uint128 maxTotalContributions;
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

// FundraisingTypes
//
// Shared constants, enums and structs for the fundraising system. Solidity
// interfaces cannot declare enums, so these live at file level and are imported
// alongside the fundraising interfaces.

// Longest permitted time from a fundraise's creation to its deadline. Bounds how long a
// contribution can be committed; defense in depth only, since the app offers far shorter
// presets.
uint40 constant MAX_FUNDRAISE_DURATION = 365 days;

// Hard ceiling on the protocol fee, in basis points. A constant, so even a compromised
// admin cannot configure a confiscatory fee.
uint16 constant MAX_FEE_BPS_LIMIT = 500;

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
    /// @notice The only address that may cancel while the fundraise is below target.
    /// @dev Supplied rather than taken from `msg.sender`, so a fundraise can be created
    ///      on someone's behalf — by a service paying the gas, for instance — without
    ///      taking their ability to cancel away from them. It is not a claim about who
    ///      sent the transaction: anyone may name anyone. The only power it carries is
    ///      cancellation, which can move money back to contributors and nowhere else.
    address organizer;
    /// @notice Smallest accepted contribution, or `0` for none.
    /// @dev Enforced on deposit only, and never on the path that resolves the fundraise.
    ///      A contribution that reaches `goal` is exempt, so a remaining gap smaller than
    ///      this minimum is still fillable.
    uint128 minContribution;
    /// @notice Ceiling on total contributions, or `0` for uncapped. Must be `0` or `>= goal`.
    uint128 maxTotalContributions;
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {FundraiserParams, OnMissed, Status} from "./FundraisingTypes.sol";

/**
 * @title IFundraiser
 * @notice Public API for a single fundraise: an escrow that collects one ERC-20
 *         toward a target and resolves to exactly one of two outcomes — the beneficiary
 *         is paid, or every contributor takes their money back.
 * @dev One contract per fundraise, deployed by `IFundraiserFactory`. Configuration is set
 *      by the constructor and never changes. See
 *      `src/fundraising/doc/spec/fundraising-design.md` for the specification.
 *
 *      Two properties the rest of this interface is built to protect:
 *
 *      1. **Nobody can freeze the money.** `finalize` is callable by anyone once the goal
 *         is reached or a deadline has passed, and every exit is pull-based. No role, no
 *         signature, and no cooperation from the organizer or any backend is required to
 *         resolve a fundraise or to retrieve a contribution.
 *      2. **The goal latch.** `unpledge` is available for exactly as long as `raised < goal`.
 *         Once the target is reached the commitment is binding — and anyone may reach it,
 *         including by covering the remaining gap.
 */
interface IFundraiser {
    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a contribution is credited.
    /// @param contributor The address whose balance was credited.
    /// @param credited The amount actually received, which for a fee-on-transfer token is
    ///        less than the amount requested. Indexers must use this, not the call argument.
    /// @param raised Total credited contributions after this deposit.
    event ContributionMade(address indexed contributor, uint256 credited, uint256 raised);

    /// @notice Emitted when a contributor withdraws part or all of their own contribution.
    /// @param raised Total credited contributions after this withdrawal.
    /// @dev `raised` decreases here. Any indexer assuming monotonic growth will disagree
    ///      with the chain.
    event Unpledged(address indexed contributor, uint256 amount, uint256 raised);

    /// @notice Emitted when the fundraise resolves.
    /// @param outcome `Succeeded` or `Refunding`.
    /// @param raised Total credited contributions at resolution.
    /// @param caller Whoever resolved it — frequently not the organizer, by design.
    event Finalized(Status outcome, uint256 raised, address indexed caller);

    /// @notice Emitted when the organizer cancels a fundraise that is still below its goal.
    event Cancelled(address indexed organizer, uint256 raised);

    /// @notice Emitted when the beneficiary collects a successful raise.
    /// @param net Amount paid to the payout address.
    /// @param fee Protocol fee taken, which is zero unless a fee was configured at creation.
    event Withdrawn(address indexed to, uint256 net, uint256 fee);

    /// @notice Emitted when the beneficiary repoints its own payout address.
    event PayoutAddressChanged(address indexed previous, address indexed current);

    /// @notice Emitted when a contributor's money is returned.
    /// @dev Also emitted for `refundFor`, where a third party pays the gas but the funds
    ///      still go to `contributor`.
    event Refunded(address indexed contributor, uint256 amount);

    /// @notice Emitted when tokens that were never part of the escrow are swept out.
    event SurplusRescued(address indexed token, address indexed to, uint256 amount);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when `goal` is zero. A fundraise with no target cannot resolve.
    error ZeroGoal();

    /// @notice Thrown when a deadline is at or before the current block timestamp.
    error DeadlineInPast();

    /// @notice Thrown when a deadline exceeds `MAX_DURATION` from now.
    error DeadlineTooFar(uint40 deadline, uint40 maximum);

    /// @notice Thrown when `OnMissed.PayBeneficiary` is paired with no deadline.
    /// @dev With no deadline there is no moment at which the target is missed, so the
    ///      setting could never fire. Rejected rather than silently stored.
    error PayBeneficiaryRequiresDeadline();

    /// @notice Thrown when a non-zero contribution cap is below the goal, which would make
    ///         success unreachable.
    error CapBelowGoal(uint128 cap, uint128 goal);

    /// @notice Thrown when the configured fee exceeds the factory's hard cap.
    error FeeTooHigh(uint16 feeBps, uint16 maximum);

    /// @notice Thrown when a function is called in the wrong lifecycle state.
    error InvalidState(Status current);

    /// @notice Thrown when a deposit arrives at or after the deadline.
    error DepositAfterDeadline();

    /// @notice Thrown when the credited amount is below `minContribution` and does not
    ///         reach the goal.
    error DepositBelowMinimum(uint256 credited, uint128 minimum);

    /// @notice Thrown when a deposit would push total contributions past the cap.
    error CapExceeded(uint256 credited, uint256 remaining);

    /// @notice Thrown when credited contributions would exceed `type(uint128).max`.
    error RaisedOverflow(uint256 raised, uint256 credited);

    /// @notice Thrown when an amount argument is zero.
    /// @dev Zero-value calls are rejected rather than accepted as no-ops: they emit
    ///      misleading events and, where gas is sponsored, invite dust griefing.
    error ZeroAmount();

    /// @notice Thrown when `unpledge` or `cancel` is attempted at or above the goal.
    /// @dev This is the goal latch. It never reopens, including if the goal is later
    ///      exceeded further.
    error GoalReached();

    /// @notice Thrown when a contributor tries to withdraw more than they put in.
    error InsufficientContribution(uint256 requested, uint256 available);

    /// @notice Thrown when the fundraise can be neither succeeded nor refunded yet —
    ///         below goal, and either open-ended or before its deadline.
    error NotFinalizable();

    /// @notice Thrown when a caller is not the organizer.
    error NotOrganizer(address caller);

    /// @notice Thrown when a caller is not the beneficiary.
    error NotBeneficiary(address caller);

    /// @notice Thrown when a contributor has nothing to reclaim.
    error NothingToRefund(address contributor);

    /// @notice Thrown when a rescue is attempted by an address without the factory's
    ///         admin role.
    error NotFactoryAdmin(address caller);

    /// @notice Thrown when a rescue would reach into escrowed funds.
    error NoSurplus();

    // ──────────────────────────────────────────────
    // Contributing
    // ──────────────────────────────────────────────

    /// @notice Contribute `amount` of the fundraise token.
    /// @dev Permissionless: there is no membership check on-chain. Requires an allowance to
    ///      this contract. Credits the amount actually received, which is what makes
    ///      fee-on-transfer tokens solvent here.
    /// @param amount Amount to transfer in. Must be non-zero.
    function deposit(uint256 amount) external;

    /// @notice Contribute using an EIP-2612 permit, avoiding a separate approval.
    /// @dev Only usable with tokens implementing `permit`. A consumed or front-run permit
    ///      does not fail the deposit if an allowance already covers it.
    function depositWithPermit(uint256 amount, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice Withdraw part or all of your own contribution.
    /// @dev Available only while `raised < goal` — the goal latch. Needs no permission from
    ///      anyone and returns credited units, never more than the caller put in.
    function unpledge(uint256 amount) external;

    // ──────────────────────────────────────────────
    // Resolution
    // ──────────────────────────────────────────────

    /// @notice Resolve the fundraise.
    /// @dev **Callable by anyone**, deliberately: if resolution required a specific party,
    ///      that party's absence would freeze everyone's money. Succeeds once `raised >= goal`;
    ///      after a deadline passes below goal, resolves per `onMissed`. Checks only state,
    ///      deadline and goal — never a deposit-time rule such as `minContribution`.
    function finalize() external;

    /// @notice Cancel a fundraise that is still below its goal, sending it to `Refunding`.
    /// @dev Organizer only, and impossible once the goal is reached. It can only ever move
    ///      money back toward contributors.
    function cancel() external;

    // ──────────────────────────────────────────────
    // Payout and refunds
    // ──────────────────────────────────────────────

    /// @notice Collect a successful raise, less any protocol fee.
    function withdraw() external;

    /// @notice Repoint where a successful raise pays out.
    /// @dev Callable only by the current beneficiary, and only after success. Exists so a
    ///      lost or blocked beneficiary key cannot strand the whole raise. Neither the
    ///      organizer nor any admin can call it.
    function setPayoutAddress(address newBeneficiary) external;

    /// @notice Reclaim your own contribution after the fundraise entered `Refunding`.
    function refund() external;

    /// @notice Reclaim on someone else's behalf; the funds go to `contributor` regardless
    ///         of who calls.
    /// @dev Lets a third party sweep refunds so contributors are refunded rather than asked
    ///      to claim. Carries no custody: the caller cannot redirect the payment.
    function refundFor(address contributor) external;

    /// @notice Sweep tokens that were never part of the escrow — mis-sends and airdrops.
    /// @dev Restricted to the factory's admin and bounded to the surplus above what this
    ///      fundraise owes, so it is structurally incapable of touching contributor funds.
    ///      Unclaimed refunds remain liabilities and stay untouchable forever.
    function rescueSurplus(address token_, address to) external;

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function name() external view returns (string memory);
    function token() external view returns (address);
    function organizer() external view returns (address);
    function beneficiary() external view returns (address);
    function factory() external view returns (address);

    function goal() external view returns (uint128);
    function deadline() external view returns (uint40);
    function onMissed() external view returns (OnMissed);
    function feeBps() external view returns (uint16);
    function minContribution() external view returns (uint128);
    function maxTotalContributions() external view returns (uint128);

    function status() external view returns (Status);
    /// @notice Total credited contributions. Decreases when a contributor unpledges.
    function raised() external view returns (uint128);
    /// @notice Running total withdrawn by contributors before the goal was reached.
    function unpledged() external view returns (uint128);
    /// @notice Running total returned to contributors after entering `Refunding`.
    function refunded() external view returns (uint128);
    function contributions(address contributor) external view returns (uint256);

    /// @notice Amount still needed to reach the goal, or zero once reached.
    function remainingToGoal() external view returns (uint256);

    /// @notice Whether contributors can currently withdraw — `Funding` and below goal.
    function canUnpledge() external view returns (bool);

    /// @notice What this fundraise still owes its contributors and beneficiary.
    /// @dev Anything the contract holds above this, in any token, is surplus.
    function outstandingLiability() external view returns (uint256);
}

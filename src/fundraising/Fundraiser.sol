// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFundraiser} from "./interfaces/IFundraiser.sol";
import {
    FundraiserParams,
    OnMissed,
    Status,
    MAX_FUNDRAISE_DURATION,
    MAX_FEE_BPS_LIMIT
} from "./interfaces/FundraisingTypes.sol";

/**
 * @title Fundraiser
 * @notice Escrow for a single fundraise: collects one ERC-20 toward a target and
 *         resolves to exactly one of two outcomes — the beneficiary is paid, or every
 *         contributor takes their money back.
 * @dev One contract per fundraise, deployed by `FundraiserFactory` with `new`. Not a proxy
 *      and not a clone: EIP-1167 does not work on zkSync Era, and a proxy measured more
 *      expensive there than a direct deployment. Configuration is set by the constructor
 *      and never written again, so there is no initializer and nothing to seize or re-run.
 *
 *      See `src/fundraising/doc/spec/fundraising-design.md`.
 */
contract Fundraiser is IFundraiser, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev `DEFAULT_ADMIN_ROLE` in OpenZeppelin's AccessControl.
    bytes32 private constant _FACTORY_ADMIN_ROLE = 0x00;

    uint256 private constant _BPS_DENOMINATOR = 10_000;

    /// @notice Longest permitted time from creation to deadline.
    uint40 public constant MAX_DURATION = MAX_FUNDRAISE_DURATION;

    /// @notice Hard ceiling on the protocol fee, in basis points.
    uint16 public constant MAX_FEE_BPS = MAX_FEE_BPS_LIMIT;

    // ──────────────────────────────────────────────
    // Configuration — written once by the constructor
    // ──────────────────────────────────────────────
    //
    // Plain storage rather than `immutable`: on EraVM immutables are routed through the
    // ImmutableSimulator system contract and measured more expensive to both write and
    // read than storage. See section 6 of the specification.

    string public override name;
    address public override token;
    address public override organizer;
    address public override beneficiary;
    address public override factory;

    uint128 public override goal;
    uint40 public override deadline;
    OnMissed public override onMissed;
    uint16 public override feeBps;
    uint128 public override minContribution;
    uint128 public override maxTotalContributions;

    // ──────────────────────────────────────────────
    // Lifecycle state
    // ──────────────────────────────────────────────

    Status public override status;

    /// @inheritdoc IFundraiser
    /// @dev Not monotonic: `unpledge` decrements it.
    uint128 public override raised;

    /// @inheritdoc IFundraiser
    uint128 public override unpledged;

    /// @inheritdoc IFundraiser
    uint128 public override refunded;

    /// @inheritdoc IFundraiser
    uint128 public override feeOwed;

    /// @inheritdoc IFundraiser
    mapping(address => uint256) public override contributions;

    /// @param p Fundraise configuration, fixed for the life of the contract.
    /// @param feeBps_ Protocol fee rate, snapshotted by value so a later change to the
    ///        factory's rate cannot skim a fundraise already in flight.
    /// @param factory_ Deploying factory, consulted for the live fee recipient and for the
    ///        admin role that gates surplus rescue.
    /// @dev Validates everything except the token allow-list, which only the factory knows.
    ///      Makes no external calls, so the factory's bookkeeping after deployment cannot be
    ///      re-entered.
    constructor(FundraiserParams memory p, uint16 feeBps_, address factory_) {
        if (p.token == address(0) || p.beneficiary == address(0)) revert ZeroAddress();
        if (p.organizer == address(0) || factory_ == address(0)) revert ZeroAddress();
        if (p.goal == 0) revert ZeroGoal();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);

        if (p.deadline == 0) {
            // With no deadline the target is never "missed", so the policy could never
            // fire. Rejected rather than stored as a setting that does nothing.
            if (p.onMissed == OnMissed.PayBeneficiary) revert PayBeneficiaryRequiresDeadline();
        } else {
            if (p.deadline <= block.timestamp) revert DeadlineInPast();
            uint40 latest = uint40(block.timestamp) + MAX_DURATION;
            if (p.deadline > latest) revert DeadlineTooFar(p.deadline, latest);
        }

        // A cap below the goal would make success unreachable.
        if (p.maxTotalContributions != 0 && p.maxTotalContributions < p.goal) {
            revert CapBelowGoal(p.maxTotalContributions, p.goal);
        }

        name = p.name;
        token = p.token;
        organizer = p.organizer;
        beneficiary = p.beneficiary;
        factory = factory_;

        goal = p.goal;
        deadline = p.deadline;
        onMissed = p.onMissed;
        feeBps = feeBps_;
        minContribution = p.minContribution;
        maxTotalContributions = p.maxTotalContributions;

        status = Status.Funding;
    }

    // ──────────────────────────────────────────────
    // Contributing
    // ──────────────────────────────────────────────

    /// @inheritdoc IFundraiser
    function deposit(uint256 amount) external override nonReentrant {
        _deposit(amount);
    }

    /// @inheritdoc IFundraiser
    function depositWithPermit(uint256 amount, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
        nonReentrant
    {
        // A permit can be consumed by anyone who sees it in the mempool. That is not a
        // reason to fail: if an allowance already covers the deposit it proceeds, and if
        // it does not the transfer below reverts anyway.
        try IERC20Permit(token).permit(msg.sender, address(this), amount, permitDeadline, v, r, s) {} catch {}
        _deposit(amount);
    }

    /// @dev Credits the amount **actually received**, not the amount requested. For a
    ///      fee-on-transfer token those differ, and crediting the request would overstate
    ///      what the contract owes until the last contributor out could not be paid.
    ///      `nonReentrant` is what makes the measured delta attributable to this transfer.
    function _deposit(uint256 amount) private {
        if (status != Status.Funding) revert InvalidState(status);
        if (amount == 0) revert ZeroAmount();
        if (deadline != 0 && block.timestamp >= deadline) revert DepositAfterDeadline();

        IERC20 t = IERC20(token);
        uint256 balanceBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 credited = t.balanceOf(address(this)) - balanceBefore;
        if (credited == 0) revert ZeroAmount();

        uint256 newRaised = uint256(raised) + credited;
        if (newRaised > type(uint128).max) revert RaisedOverflow(raised, credited);

        if (maxTotalContributions != 0 && newRaised > maxTotalContributions) {
            revert CapExceeded(credited, maxTotalContributions - raised);
        }

        // A contribution that reaches the goal is exempt from the minimum. A remaining gap
        // smaller than `minContribution` must still be fillable, or the minimum becomes a
        // rule that stands between a fundraise and its own resolution.
        if (credited < minContribution && newRaised < goal) {
            revert DepositBelowMinimum(credited, minContribution);
        }

        contributions[msg.sender] += credited;
        raised = uint128(newRaised);

        emit ContributionMade(msg.sender, credited, newRaised);
    }

    /// @inheritdoc IFundraiser
    /// @dev Deliberately not gated on the deadline. A fundraise past its deadline but not
    ///      yet finalized is still below goal, and keeping the exit open means nobody is
    ///      stranded in the window before someone calls `finalize`.
    function unpledge(uint256 amount) external override nonReentrant {
        if (status != Status.Funding) revert InvalidState(status);
        if (raised >= goal) revert GoalReached();
        if (amount == 0) revert ZeroAmount();

        uint256 contributed = contributions[msg.sender];
        if (amount > contributed) revert InsufficientContribution(amount, contributed);

        contributions[msg.sender] = contributed - amount;
        raised -= uint128(amount);
        unpledged += uint128(amount);

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Unpledged(msg.sender, amount, raised);
    }

    // ──────────────────────────────────────────────
    // Resolution
    // ──────────────────────────────────────────────

    /// @inheritdoc IFundraiser
    /// @dev Checks only state, goal and deadline. No deposit-time rule is re-evaluated
    ///      here: a minimum-contribution check on this path is what made a well-known
    ///      audited crowdfund impossible to finalize, locking contributor funds until
    ///      expiry.
    function finalize() external override {
        if (status != Status.Funding) revert InvalidState(status);

        Status outcome;
        if (raised >= goal) {
            outcome = Status.Succeeded;
        } else if (deadline != 0 && block.timestamp >= deadline) {
            outcome = onMissed == OnMissed.Refund ? Status.Refunding : Status.Succeeded;
        } else {
            revert NotFinalizable();
        }

        status = outcome;
        emit Finalized(outcome, raised, msg.sender);
    }

    /// @inheritdoc IFundraiser
    function cancel() external override {
        if (status != Status.Funding) revert InvalidState(status);
        if (msg.sender != organizer) revert NotOrganizer(msg.sender);
        if (raised >= goal) revert GoalReached();

        status = Status.Refunding;
        emit Cancelled(msg.sender, raised);
    }

    // ──────────────────────────────────────────────
    // Payout and refunds
    // ──────────────────────────────────────────────

    /// @inheritdoc IFundraiser
    function withdraw() external override nonReentrant {
        if (status != Status.Succeeded) revert InvalidState(status);
        if (msg.sender != beneficiary) revert NotBeneficiary(msg.sender);

        uint256 amount = raised;
        address recipient = IFundraiserFactoryFees(factory).feeRecipient();

        // Rounded down, so any remainder favours the beneficiary rather than the protocol.
        uint256 fee = (recipient == address(0)) ? 0 : (amount * feeBps) / _BPS_DENOMINATOR;
        uint256 net = amount - fee;
        address payTo = beneficiary;

        status = Status.Closed;

        // The fee is ACCRUED here, not transferred. Paying it inline would put the fee
        // recipient on the beneficiary's critical path: a recipient that cannot receive
        // the token — a blocklisting stablecoin, say — would revert the whole call and
        // strand the pot until an admin rotated the recipient. Resolution must never
        // depend on admin cooperation. The recipient pulls separately via `collectFee`.
        feeOwed = uint128(fee);

        if (net != 0) IERC20(token).safeTransfer(payTo, net);

        emit Withdrawn(payTo, net, fee);
    }

    /// @inheritdoc IFundraiser
    function setPayoutAddress(address newBeneficiary) external override {
        if (status != Status.Succeeded) revert InvalidState(status);
        if (msg.sender != beneficiary) revert NotBeneficiary(msg.sender);
        if (newBeneficiary == address(0)) revert ZeroAddress();

        emit PayoutAddressChanged(beneficiary, newBeneficiary);
        beneficiary = newBeneficiary;
    }

    /// @inheritdoc IFundraiser
    /// @dev Callable by anyone; the funds always go to the factory's current recipient,
    ///      so a blocked or lost recipient costs the protocol its fee and nobody else
    ///      anything. The beneficiary has already been paid by this point.
    function collectFee() external override nonReentrant {
        uint256 amount = feeOwed;
        if (amount == 0) revert NoFeeOwed();

        address recipient = IFundraiserFactoryFees(factory).feeRecipient();
        if (recipient == address(0)) revert ZeroAddress();

        feeOwed = 0;
        IERC20(token).safeTransfer(recipient, amount);

        emit FeeCollected(recipient, amount);
    }

    /// @inheritdoc IFundraiser
    function refund() external override nonReentrant {
        _refund(msg.sender);
    }

    /// @inheritdoc IFundraiser
    function refundFor(address contributor) external override nonReentrant {
        _refund(contributor);
    }

    /// @dev Funds always go to `contributor`, never to the caller, so a third party can pay
    ///      the gas to return someone's money without being able to redirect it.
    function _refund(address contributor) private {
        if (status != Status.Refunding) revert InvalidState(status);

        uint256 amount = contributions[contributor];
        if (amount == 0) revert NothingToRefund(contributor);

        contributions[contributor] = 0;
        refunded += uint128(amount);

        IERC20(token).safeTransfer(contributor, amount);

        emit Refunded(contributor, amount);
    }

    /// @inheritdoc IFundraiser
    /// @dev Bounded by arithmetic rather than by trust: for the escrow token only the
    ///      balance above `outstandingLiability()` can move, and unclaimed refunds are part
    ///      of that liability, so they stay untouchable indefinitely.
    function rescueSurplus(address token_, address to) external override nonReentrant {
        if (!IAccessControl(factory).hasRole(_FACTORY_ADMIN_ROLE, msg.sender)) {
            revert NotFactoryAdmin(msg.sender);
        }
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(token_).balanceOf(address(this));
        uint256 surplus;
        if (token_ == token) {
            uint256 liability = outstandingLiability();
            // Guarded rather than relying on checked arithmetic: a shortfall should surface
            // as "there is no surplus", not as an arithmetic panic.
            surplus = balance > liability ? balance - liability : 0;
        } else {
            surplus = balance;
        }
        if (surplus == 0) revert NoSurplus();

        IERC20(token_).safeTransfer(to, surplus);

        emit SurplusRescued(token_, to, surplus);
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc IFundraiser
    function remainingToGoal() external view override returns (uint256) {
        return raised >= goal ? 0 : goal - raised;
    }

    /// @inheritdoc IFundraiser
    function canUnpledge() external view override returns (bool) {
        return status == Status.Funding && raised < goal;
    }

    /// @inheritdoc IFundraiser
    function outstandingLiability() public view override returns (uint256) {
        if (status == Status.Refunding) return raised - refunded;
        // Once closed the only thing still owed is an uncollected fee. Counting it keeps
        // `rescueSurplus` unable to sweep money that belongs to the fee recipient.
        if (status == Status.Closed) return feeOwed;
        return raised;
    }
}

    /// @dev Minimal view of the factory, kept local so the escrow does not depend on the
    ///      factory's full interface for a single call.
    interface IFundraiserFactoryFees {
        function feeRecipient() external view returns (address);
    }

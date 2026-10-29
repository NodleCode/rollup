// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {QuotaControl} from "../QuotaControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ArcadeEscrow
 * @notice Per-wallet NODL balance that pays for Arcade game builds.
 * @dev Design: agent-stack `docs/arcade-artifacts-backend-design.md`, section 9.3.
 *
 *      - A wallet tops up its balance with `deposit` (or anyone with `depositFor`). The balance is
 *        reused across builds, so funding happens rarely.
 *      - The oracle (arcade-forge) `charge`s a balance once per charged build. `ref` is a random
 *        nonce per build, never an artifact id, so the chain cannot link a charge to a game.
 *      - A wallet leaves with `requestWithdraw` → `withdraw` after `withdrawDelay`. The delay covers
 *        builds already running; arcade-forge never starts a build while a request is pending.
 *
 *      Admin timelock: anything that widens what can be charged waits `ADMIN_DELAY`, which is longer
 *      than `MAX_WITHDRAW_DELAY`. That covers granting `ORACLE_ROLE`, raising `maxCharge` or the
 *      quota, and shortening the quota period. A user who disagrees with a scheduled change can
 *      `requestWithdraw` and be out before it applies. Changes that narrow it (revoking the oracle,
 *      lowering limits, pausing) apply immediately, so incident response is never delayed.
 *
 *      Guarantees, which hold even with a compromised oracle key:
 *      - `withdrawFees` reaches `feesAccrued` only, never a user's balance, so
 *        `token.balanceOf(this) >= Σ balanceOf + feesAccrued` always holds.
 *      - `maxCharge` per call and `QuotaControl` per period bound a leaked oracle key, which can
 *        only move NODL into `feesAccrued`, which it cannot withdraw.
 *      - Pausing blocks `deposit` and `charge`, never a withdrawal.
 *      - `withdrawDelay` is capped by `MAX_WITHDRAW_DELAY`, so the admin cannot lock balances.
 *      - Not upgradeable. `token` must be a plain ERC-20 (no fee on transfer, no rebasing): NODL.
 */
contract ArcadeEscrow is QuotaControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Role identifier for the oracle. Accounts with this role can charge balances.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @dev Upper bound on `withdrawDelay`, so a balance can never be locked for long.
    uint64 public constant MAX_WITHDRAW_DELAY = 7 days;

    /// @dev Wait before a scheduled change applies. Longer than any withdrawal delay, so users can exit first.
    uint64 public constant ADMIN_DELAY = MAX_WITHDRAW_DELAY + 1 days;

    /// @dev Admin changes that widen what can be charged, and so must wait `ADMIN_DELAY`.
    enum Change {
        GrantOracle,
        MaxCharge,
        Quota,
        Period
    }

    /// @dev A pending withdrawal. `amount == 0` means none is pending.
    struct Withdrawal {
        uint128 amount;
        uint64 readyAt;
    }

    /// @dev ERC20 token held in escrow (NODL).
    IERC20 public immutable token;

    /// @dev Spendable balance per wallet.
    mapping(address => uint256) public balanceOf;

    /// @dev At most one pending withdrawal per wallet.
    mapping(address => Withdrawal) public withdrawals;

    /// @dev Per charged ref, `keccak256(account, amount)`, for idempotent settlement.
    mapping(bytes32 => bytes32) public chargeOf;

    /// @dev Charged NODL the admin may withdraw.
    uint256 public feesAccrued;

    /// @dev Smallest deposit that may fund an empty balance.
    uint256 public minDeposit;

    /// @dev Largest amount a single `charge` may take.
    uint256 public maxCharge;

    /// @dev Seconds between `requestWithdraw` and `withdraw`.
    uint64 public withdrawDelay;

    /// @dev Per scheduled change, `keccak256(kind, value)`, the time it may be executed.
    mapping(bytes32 => uint256) public scheduledChanges;

    event Deposited(address indexed account, address indexed from, uint256 amount, uint256 balance);
    event WithdrawRequested(address indexed account, uint256 amount, uint64 readyAt);
    event WithdrawCancelled(address indexed account);
    event Withdrawn(address indexed account, uint256 amount);
    event Charged(address indexed account, uint256 amount, bytes32 indexed ref);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event MinDepositSet(uint256 minDeposit);
    event MaxChargeSet(uint256 maxCharge);
    event WithdrawDelaySet(uint64 withdrawDelay);
    event ChangeScheduled(Change indexed kind, uint256 value, uint256 readyAt);
    event ChangeCancelled(Change indexed kind, uint256 value);
    event ChangeExecuted(Change indexed kind, uint256 value);

    error ZeroAddress();
    error ZeroAmount();
    error BelowMinDeposit(uint256 amount, uint256 minDeposit);
    error InsufficientBalance(uint256 balance, uint256 needed);
    error AmountTooLarge(uint256 amount);
    error NoPendingWithdrawal();
    error WithdrawalNotReady(uint64 readyAt);
    error AboveMaxCharge(uint256 amount, uint256 maxCharge);
    error AlreadyCharged(bytes32 ref);
    error ChargeConflict(bytes32 ref);
    error InsufficientFees(uint256 feesAccrued, uint256 needed);
    error WithdrawDelayTooLong(uint64 withdrawDelay);
    error NeedsTimelock();
    error ChangeAlreadyScheduled(Change kind, uint256 value);
    error ChangeNotScheduled(Change kind, uint256 value);
    error ChangeNotReady(uint256 readyAt);

    /**
     * @param _token The ERC20 token held in escrow (NODL).
     * @param oracle The account granted `ORACLE_ROLE` (arcade-forge's settlement key).
     * @param admin The account granted `DEFAULT_ADMIN_ROLE` (a multisig).
     * @param initialQuota Total that may be charged per period, across all wallets.
     * @param initialPeriod Quota period in seconds.
     * @param _minDeposit Smallest deposit that may fund an empty balance.
     * @param _maxCharge Largest amount a single `charge` may take.
     * @param _withdrawDelay Seconds between `requestWithdraw` and `withdraw`, at most `MAX_WITHDRAW_DELAY`.
     */
    constructor(
        address _token,
        address oracle,
        address admin,
        uint256 initialQuota,
        uint256 initialPeriod,
        uint256 _minDeposit,
        uint256 _maxCharge,
        uint64 _withdrawDelay
    ) QuotaControl(initialQuota, initialPeriod, admin) {
        if (_token == address(0) || oracle == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        _mustBeValidWithdrawDelay(_withdrawDelay);

        token = IERC20(_token);
        _grantRole(ORACLE_ROLE, oracle);
        minDeposit = _minDeposit;
        maxCharge = _maxCharge;
        withdrawDelay = _withdrawDelay;
    }

    // ── Users ─────────────────────────────────────────────

    /// @notice Tops up the caller's balance. Requires a prior `approve` of `amount`.
    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        _deposit(msg.sender, amount);
    }

    /// @notice Tops up `account`'s balance from the caller. Only `account` can withdraw it.
    function depositFor(address account, uint256 amount) external whenNotPaused nonReentrant {
        if (account == address(0)) revert ZeroAddress();
        _deposit(account, amount);
    }

    /**
     * @notice Starts a withdrawal of `amount`, payable after `withdrawDelay`.
     * @dev Replaces any pending request and restarts its timer.
     */
    function requestWithdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = balanceOf[msg.sender];
        if (amount > balance) revert InsufficientBalance(balance, amount);
        if (amount > type(uint128).max) revert AmountTooLarge(amount);

        uint64 readyAt = uint64(block.timestamp) + withdrawDelay;
        withdrawals[msg.sender] = Withdrawal({amount: uint128(amount), readyAt: readyAt});
        emit WithdrawRequested(msg.sender, amount, readyAt);
    }

    /// @notice Cancels the caller's pending withdrawal, so builds can start again.
    function cancelWithdraw() external {
        if (withdrawals[msg.sender].amount == 0) revert NoPendingWithdrawal();
        delete withdrawals[msg.sender];
        emit WithdrawCancelled(msg.sender);
    }

    /**
     * @notice Pays out the caller's pending withdrawal once it is ready.
     * @dev Pays `min(requested, balance)`: a charge that landed during the delay is deducted.
     */
    function withdraw() external nonReentrant {
        Withdrawal memory w = withdrawals[msg.sender];
        if (w.amount == 0) revert NoPendingWithdrawal();
        if (block.timestamp < w.readyAt) revert WithdrawalNotReady(w.readyAt);

        uint256 balance = balanceOf[msg.sender];
        uint256 amount = w.amount < balance ? w.amount : balance;

        delete withdrawals[msg.sender];
        balanceOf[msg.sender] = balance - amount;
        emit Withdrawn(msg.sender, amount);

        if (amount != 0) token.safeTransfer(msg.sender, amount);
    }

    // ── Oracle ────────────────────────────────────────────

    /**
     * @notice Charges `amount` from `account`'s balance into `feesAccrued`, once per `ref`.
     * @dev A retry with the same `ref`, account and amount reverts with `AlreadyCharged`, which the
     *      settlement worker reads as "already settled". The same `ref` with a different account or
     *      amount reverts with `ChargeConflict`. Counted against the per-period quota.
     */
    function charge(address account, uint256 amount, bytes32 ref) external whenNotPaused onlyRole(ORACLE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        bytes32 payload = keccak256(abi.encode(account, amount));
        bytes32 previous = chargeOf[ref];
        if (previous != 0) {
            if (previous == payload) revert AlreadyCharged(ref);
            revert ChargeConflict(ref);
        }
        if (amount > maxCharge) revert AboveMaxCharge(amount, maxCharge);
        uint256 balance = balanceOf[account];
        if (amount > balance) revert InsufficientBalance(balance, amount);

        _checkedResetClaimed();
        _checkedUpdateClaimed(amount);

        chargeOf[ref] = payload;
        balanceOf[account] = balance - amount;
        feesAccrued += amount;
        emit Charged(account, amount, ref);
    }

    /// @notice Whether `ref` has been charged.
    function charged(bytes32 ref) external view returns (bool) {
        return chargeOf[ref] != 0;
    }

    // ── Admin ─────────────────────────────────────────────

    /// @notice Withdraws up to `feesAccrued`. Users' balances are never reachable.
    function withdrawFees(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > feesAccrued) revert InsufficientFees(feesAccrued, amount);

        feesAccrued -= amount;
        emit FeesWithdrawn(to, amount);
        token.safeTransfer(to, amount);
    }

    function setMinDeposit(uint256 newMinDeposit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minDeposit = newMinDeposit;
        emit MinDepositSet(newMinDeposit);
    }

    /// @dev Lowers `maxCharge` immediately. Raising it goes through `scheduleChange`.
    function setMaxCharge(uint256 newMaxCharge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxCharge > maxCharge) revert NeedsTimelock();
        _setMaxCharge(newMaxCharge);
    }

    /// @dev Lowers the quota immediately. Raising it goes through `scheduleChange`.
    function setQuota(uint256 newQuota) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newQuota > quota) revert NeedsTimelock();
        _setQuota(newQuota);
    }

    /// @dev Lengthens the period immediately. Shortening it goes through `scheduleChange`.
    function setPeriod(uint256 newPeriod) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newPeriod < period) revert NeedsTimelock();
        _setPeriod(newPeriod);
    }

    /// @dev `ORACLE_ROLE` is granted through `scheduleChange` only. Revoking stays immediate.
    function grantRole(bytes32 role, address account) public override {
        if (role == ORACLE_ROLE) revert NeedsTimelock();
        super.grantRole(role, account);
    }

    /**
     * @notice Schedules a change that widens what can be charged, executable after `ADMIN_DELAY`.
     * @param kind What to change.
     * @param value The new value. For `GrantOracle`, the oracle address as a `uint256`.
     */
    function scheduleChange(Change kind, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (kind == Change.GrantOracle) {
            if (value == 0) revert ZeroAddress();
            if (value > type(uint160).max) revert AmountTooLarge(value);
        }
        if (kind == Change.Period) _mustBeWithinPeriodRange(value);

        bytes32 id = _changeId(kind, value);
        if (scheduledChanges[id] != 0) revert ChangeAlreadyScheduled(kind, value);

        uint256 readyAt = block.timestamp + ADMIN_DELAY;
        scheduledChanges[id] = readyAt;
        emit ChangeScheduled(kind, value, readyAt);
    }

    function cancelChange(Change kind, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 id = _changeId(kind, value);
        if (scheduledChanges[id] == 0) revert ChangeNotScheduled(kind, value);
        delete scheduledChanges[id];
        emit ChangeCancelled(kind, value);
    }

    function executeChange(Change kind, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 id = _changeId(kind, value);
        uint256 readyAt = scheduledChanges[id];
        if (readyAt == 0) revert ChangeNotScheduled(kind, value);
        if (block.timestamp < readyAt) revert ChangeNotReady(readyAt);
        delete scheduledChanges[id];

        if (kind == Change.GrantOracle) _grantRole(ORACLE_ROLE, address(uint160(value)));
        else if (kind == Change.MaxCharge) _setMaxCharge(value);
        else if (kind == Change.Quota) _setQuota(value);
        else _setPeriod(value);
        emit ChangeExecuted(kind, value);
    }

    /// @dev Applies to new requests only: a pending request keeps its `readyAt`.
    function setWithdrawDelay(uint64 newWithdrawDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _mustBeValidWithdrawDelay(newWithdrawDelay);
        withdrawDelay = newWithdrawDelay;
        emit WithdrawDelaySet(newWithdrawDelay);
    }

    /// @notice Blocks `deposit` and `charge`. Withdrawals stay open.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ── Internal ──────────────────────────────────────────

    function _deposit(address account, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = balanceOf[account];
        // The minimum applies to an empty balance only, so small top-ups are never blocked.
        if (balance == 0 && amount < minDeposit) revert BelowMinDeposit(amount, minDeposit);

        uint256 newBalance = balance + amount;
        balanceOf[account] = newBalance;
        emit Deposited(account, msg.sender, amount, newBalance);

        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function _setMaxCharge(uint256 newMaxCharge) internal {
        maxCharge = newMaxCharge;
        emit MaxChargeSet(newMaxCharge);
    }

    function _setQuota(uint256 newQuota) internal {
        quota = newQuota;
        emit QuotaSet(newQuota);
    }

    function _setPeriod(uint256 newPeriod) internal {
        _mustBeWithinPeriodRange(newPeriod);
        period = newPeriod;
        emit PeriodSet(newPeriod);
    }

    function _changeId(Change kind, uint256 value) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind, value));
    }

    function _mustBeValidWithdrawDelay(uint64 delay) internal pure {
        if (delay > MAX_WITHDRAW_DELAY) revert WithdrawDelayTooLong(delay);
    }
}

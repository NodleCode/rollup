// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ArcadeEscrow} from "../../src/arcade/ArcadeEscrow.sol";
import {QuotaControl} from "../../src/QuotaControl.sol";
import {MockERC20} from "../__helpers__/MockERC20.sol";
import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";

contract ArcadeEscrowTest is Test {
    using AccessControlUtils for Vm;

    address admin = makeAddr("admin");
    address oracle = makeAddr("oracle");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant QUOTA = 1_000 ether;
    uint256 constant PERIOD = 1 days;
    uint256 constant MIN_DEPOSIT = 1 ether;
    uint256 constant MAX_CHARGE = 100 ether;
    uint64 constant DELAY = 1 hours;

    MockERC20 token;
    ArcadeEscrow escrow;

    function setUp() public {
        token = new MockERC20("Nodle", "NODL", 18);
        escrow = new ArcadeEscrow(address(token), oracle, admin, QUOTA, PERIOD, MIN_DEPOSIT, MAX_CHARGE, DELAY);
        _fund(alice, 10_000 ether);
        _fund(bob, 10_000 ether);
    }

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(escrow), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        escrow.deposit(amount);
    }

    function _charge(address who, uint256 amount, bytes32 ref) internal {
        vm.prank(oracle);
        escrow.charge(who, amount, ref);
    }

    // ── Constructor ───────────────────────────────────────

    function test_constructorSetsState() public view {
        assertEq(address(escrow.token()), address(token));
        assertTrue(escrow.hasRole(escrow.ORACLE_ROLE(), oracle));
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(escrow.quota(), QUOTA);
        assertEq(escrow.period(), PERIOD);
        assertEq(escrow.minDeposit(), MIN_DEPOSIT);
        assertEq(escrow.maxCharge(), MAX_CHARGE);
        assertEq(escrow.withdrawDelay(), DELAY);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ArcadeEscrow.ZeroAddress.selector);
        new ArcadeEscrow(address(0), oracle, admin, QUOTA, PERIOD, 0, 0, DELAY);
        vm.expectRevert(ArcadeEscrow.ZeroAddress.selector);
        new ArcadeEscrow(address(token), address(0), admin, QUOTA, PERIOD, 0, 0, DELAY);
        vm.expectRevert(ArcadeEscrow.ZeroAddress.selector);
        new ArcadeEscrow(address(token), oracle, address(0), QUOTA, PERIOD, 0, 0, DELAY);
    }

    function test_constructorRejectsLongDelay() public {
        uint64 tooLong = escrow.MAX_WITHDRAW_DELAY() + 1;
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.WithdrawDelayTooLong.selector, tooLong));
        new ArcadeEscrow(address(token), oracle, admin, QUOTA, PERIOD, 0, 0, tooLong);
    }

    // ── Deposit ───────────────────────────────────────────

    function test_depositCreditsCaller() public {
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.Deposited(alice, alice, 5 ether, 5 ether);
        _deposit(alice, 5 ether);

        assertEq(escrow.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(address(escrow)), 5 ether);
    }

    function test_depositForCreditsAccountNotSender() public {
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.Deposited(alice, bob, 5 ether, 5 ether);
        vm.prank(bob);
        escrow.depositFor(alice, 5 ether);

        assertEq(escrow.balanceOf(alice), 5 ether);
        assertEq(escrow.balanceOf(bob), 0);
    }

    function test_depositForRejectsZeroAccount() public {
        vm.prank(bob);
        vm.expectRevert(ArcadeEscrow.ZeroAddress.selector);
        escrow.depositFor(address(0), 5 ether);
    }

    function test_depositRejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(ArcadeEscrow.ZeroAmount.selector);
        escrow.deposit(0);
    }

    function test_minDepositAppliesToEmptyBalanceOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.BelowMinDeposit.selector, 0.5 ether, MIN_DEPOSIT));
        escrow.deposit(0.5 ether);

        _deposit(alice, MIN_DEPOSIT);
        _deposit(alice, 1); // a small top-up is fine once funded
        assertEq(escrow.balanceOf(alice), MIN_DEPOSIT + 1);
    }

    // ── Withdraw ──────────────────────────────────────────

    function test_withdrawAfterDelay() public {
        _deposit(alice, 10 ether);

        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.WithdrawRequested(alice, 4 ether, uint64(block.timestamp) + DELAY);
        vm.prank(alice);
        escrow.requestWithdraw(4 ether);

        (uint128 amount, uint64 readyAt) = escrow.withdrawals(alice);
        assertEq(amount, 4 ether);
        assertEq(readyAt, block.timestamp + DELAY);

        vm.warp(readyAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.WithdrawalNotReady.selector, readyAt));
        escrow.withdraw();

        vm.warp(readyAt);
        uint256 before = token.balanceOf(alice);
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.Withdrawn(alice, 4 ether);
        vm.prank(alice);
        escrow.withdraw();

        assertEq(token.balanceOf(alice) - before, 4 ether);
        assertEq(escrow.balanceOf(alice), 6 ether);
        (amount,) = escrow.withdrawals(alice);
        assertEq(amount, 0);
    }

    function test_withdrawPaysWhatIsLeftAfterACharge() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        escrow.requestWithdraw(10 ether);

        // A build already running settles during the delay.
        _charge(alice, 3 ether, keccak256("build"));

        vm.warp(block.timestamp + DELAY);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        escrow.withdraw();

        assertEq(token.balanceOf(alice) - before, 7 ether);
        assertEq(escrow.balanceOf(alice), 0);
    }

    function test_withdrawPaysNothingWhenBalanceWasCharged() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        escrow.requestWithdraw(10 ether);
        _charge(alice, 10 ether, keccak256("build"));

        vm.warp(block.timestamp + DELAY);
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.Withdrawn(alice, 0);
        vm.prank(alice);
        escrow.withdraw();

        (uint128 amount,) = escrow.withdrawals(alice);
        assertEq(amount, 0);
    }

    function test_requestWithdrawValidates() public {
        vm.startPrank(alice);
        vm.expectRevert(ArcadeEscrow.ZeroAmount.selector);
        escrow.requestWithdraw(0);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.InsufficientBalance.selector, 0, 1 ether));
        escrow.requestWithdraw(1 ether);
        vm.stopPrank();
    }

    function test_requestWithdrawRejectsAmountAboveUint128() public {
        uint256 huge = uint256(type(uint128).max) + 1;
        _fund(alice, huge);
        _deposit(alice, huge);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.AmountTooLarge.selector, huge));
        escrow.requestWithdraw(huge);
    }

    function test_newRequestReplacesAndRestartsTimer() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        escrow.requestWithdraw(2 ether);

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(alice);
        escrow.requestWithdraw(5 ether);

        (uint128 amount, uint64 readyAt) = escrow.withdrawals(alice);
        assertEq(amount, 5 ether);
        assertEq(readyAt, block.timestamp + DELAY);
    }

    function test_cancelWithdraw() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        escrow.requestWithdraw(2 ether);

        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.WithdrawCancelled(alice);
        vm.prank(alice);
        escrow.cancelWithdraw();

        (uint128 amount,) = escrow.withdrawals(alice);
        assertEq(amount, 0);

        vm.warp(block.timestamp + DELAY);
        vm.startPrank(alice);
        vm.expectRevert(ArcadeEscrow.NoPendingWithdrawal.selector);
        escrow.withdraw();
        vm.expectRevert(ArcadeEscrow.NoPendingWithdrawal.selector);
        escrow.cancelWithdraw();
        vm.stopPrank();
    }

    function test_onlyAccountCanWithdrawItsBalance() public {
        vm.prank(bob);
        escrow.depositFor(alice, 10 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.InsufficientBalance.selector, 0, 10 ether));
        escrow.requestWithdraw(10 ether);
    }

    function test_delayChangeDoesNotMovePendingRequest() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        escrow.requestWithdraw(1 ether);
        (, uint64 readyAt) = escrow.withdrawals(alice);

        uint64 maxDelay = escrow.MAX_WITHDRAW_DELAY();
        vm.prank(admin);
        escrow.setWithdrawDelay(maxDelay);

        vm.warp(readyAt);
        vm.prank(alice);
        escrow.withdraw();
        assertEq(escrow.balanceOf(alice), 9 ether);
    }

    // ── Charge ────────────────────────────────────────────

    function test_chargeMovesBalanceToFees() public {
        _deposit(alice, 10 ether);
        bytes32 ref = keccak256("nonce");

        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.Charged(alice, 4 ether, ref);
        _charge(alice, 4 ether, ref);

        assertEq(escrow.balanceOf(alice), 6 ether);
        assertEq(escrow.feesAccrued(), 4 ether);
        assertTrue(escrow.charged(ref));
        assertEq(escrow.claimed(), 4 ether);
        assertEq(token.balanceOf(address(escrow)), 10 ether);
    }

    function test_chargeIsIdempotentByRef() public {
        _deposit(alice, 10 ether);
        bytes32 ref = keccak256("nonce");
        _charge(alice, 1 ether, ref);

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.AlreadyCharged.selector, ref));
        escrow.charge(alice, 1 ether, ref);
        assertEq(escrow.balanceOf(alice), 9 ether);
    }

    function test_chargeRefReusedWithDifferentPayloadConflicts() public {
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);
        bytes32 ref = keccak256("nonce");
        _charge(alice, 1 ether, ref);

        vm.startPrank(oracle);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.ChargeConflict.selector, ref));
        escrow.charge(bob, 1 ether, ref);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.ChargeConflict.selector, ref));
        escrow.charge(alice, 2 ether, ref);
        vm.stopPrank();

        assertEq(escrow.balanceOf(alice), 9 ether);
        assertEq(escrow.balanceOf(bob), 10 ether);
    }

    function test_chargeValidates() public {
        _deposit(alice, 10 ether);
        vm.startPrank(oracle);
        vm.expectRevert(ArcadeEscrow.ZeroAmount.selector);
        escrow.charge(alice, 0, "a");
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.AboveMaxCharge.selector, MAX_CHARGE + 1, MAX_CHARGE));
        escrow.charge(alice, MAX_CHARGE + 1, "b");
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.InsufficientBalance.selector, 10 ether, 11 ether));
        escrow.charge(alice, 11 ether, "c");
        vm.stopPrank();
    }

    function test_chargeIsCappedByQuota() public {
        _deposit(alice, 5_000 ether);
        for (uint256 i = 0; i < QUOTA / MAX_CHARGE; ++i) {
            _charge(alice, MAX_CHARGE, bytes32(i + 1));
        }

        vm.prank(oracle);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        escrow.charge(alice, 1, "over");

        vm.warp(block.timestamp + PERIOD);
        _charge(alice, 1, "next period");
        assertEq(escrow.claimed(), 1);
    }

    function test_onlyOracleCanCharge() public {
        _deposit(alice, 10 ether);
        vm.startPrank(admin);
        vm.expectRevert_AccessControlUnauthorizedAccount(admin, escrow.ORACLE_ROLE());
        escrow.charge(alice, 1 ether, "x");
        vm.stopPrank();
    }

    // ── Fees ──────────────────────────────────────────────

    function test_adminWithdrawsFeesOnly() public {
        _deposit(alice, 10 ether);
        _charge(alice, 4 ether, "x");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.InsufficientFees.selector, 4 ether, 5 ether));
        escrow.withdrawFees(admin, 5 ether);

        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.FeesWithdrawn(bob, 4 ether);
        vm.prank(admin);
        escrow.withdrawFees(bob, 4 ether);

        assertEq(token.balanceOf(bob), 10_000 ether + 4 ether);
        assertEq(escrow.feesAccrued(), 0);
        assertEq(token.balanceOf(address(escrow)), escrow.balanceOf(alice));
    }

    function test_withdrawFeesRejectsZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(ArcadeEscrow.ZeroAddress.selector);
        escrow.withdrawFees(address(0), 0);
    }

    // ── Admin ─────────────────────────────────────────────

    function test_onlyAdminCanConfigure() public {
        bytes32 adminRole = escrow.DEFAULT_ADMIN_ROLE();
        vm.startPrank(oracle);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.setMinDeposit(0);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.setMaxCharge(0);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.setWithdrawDelay(0);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.pause();
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.unpause();
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.withdrawFees(oracle, 0);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.MinDepositSet(2 ether);
        escrow.setMinDeposit(2 ether);
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.MaxChargeSet(50 ether);
        escrow.setMaxCharge(50 ether);
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.WithdrawDelaySet(2 hours);
        escrow.setWithdrawDelay(2 hours);
        vm.stopPrank();

        assertEq(escrow.minDeposit(), 2 ether);
        assertEq(escrow.maxCharge(), 50 ether);
        assertEq(escrow.withdrawDelay(), 2 hours);
    }

    function test_setWithdrawDelayIsCapped() public {
        uint64 tooLong = escrow.MAX_WITHDRAW_DELAY() + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.WithdrawDelayTooLong.selector, tooLong));
        escrow.setWithdrawDelay(tooLong);
    }

    function test_pauseBlocksDepositAndChargeButNeverWithdraw() public {
        _deposit(alice, 10 ether);
        _charge(alice, 1 ether, "x");
        vm.prank(alice);
        escrow.requestWithdraw(9 ether);

        vm.prank(admin);
        escrow.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.deposit(1 ether);
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.depositFor(alice, 1 ether);
        vm.prank(oracle);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.charge(alice, 1 ether, "y");

        vm.warp(block.timestamp + DELAY);
        vm.prank(alice);
        escrow.withdraw();
        assertEq(escrow.balanceOf(alice), 0);

        vm.prank(admin);
        escrow.withdrawFees(admin, 1 ether);

        vm.prank(admin);
        escrow.unpause();
        _deposit(alice, 1 ether);
    }

    // ── Admin timelock ────────────────────────────────────

    function _schedule(ArcadeEscrow.Change kind, uint256 value) internal {
        vm.prank(admin);
        escrow.scheduleChange(kind, value);
    }

    function _execute(ArcadeEscrow.Change kind, uint256 value) internal {
        vm.prank(admin);
        escrow.executeChange(kind, value);
    }

    function test_adminDelayOutlastsAnyWithdrawal() public view {
        assertGt(escrow.ADMIN_DELAY(), escrow.MAX_WITHDRAW_DELAY());
    }

    function test_increasesNeedTimelock() public {
        bytes32 oracleRole = escrow.ORACLE_ROLE();
        vm.startPrank(admin);
        vm.expectRevert(ArcadeEscrow.NeedsTimelock.selector);
        escrow.setMaxCharge(MAX_CHARGE + 1);
        vm.expectRevert(ArcadeEscrow.NeedsTimelock.selector);
        escrow.setQuota(QUOTA + 1);
        vm.expectRevert(ArcadeEscrow.NeedsTimelock.selector);
        escrow.setPeriod(PERIOD - 1);
        vm.expectRevert(ArcadeEscrow.NeedsTimelock.selector);
        escrow.grantRole(oracleRole, bob);
        vm.stopPrank();
    }

    function test_decreasesAndRevokesApplyImmediately() public {
        bytes32 oracleRole = escrow.ORACLE_ROLE();
        vm.startPrank(admin);
        escrow.setMaxCharge(MAX_CHARGE - 1);
        vm.expectEmit(address(escrow));
        emit QuotaControl.QuotaSet(QUOTA - 1);
        escrow.setQuota(QUOTA - 1);
        vm.expectEmit(address(escrow));
        emit QuotaControl.PeriodSet(PERIOD + 1);
        escrow.setPeriod(PERIOD + 1);
        escrow.revokeRole(oracleRole, oracle);
        vm.stopPrank();

        assertEq(escrow.maxCharge(), MAX_CHARGE - 1);
        assertEq(escrow.quota(), QUOTA - 1);
        assertEq(escrow.period(), PERIOD + 1);
        assertFalse(escrow.hasRole(oracleRole, oracle));
    }

    function test_setPeriodStaysWithinRange() public {
        uint256 tooLong = escrow.MAX_PERIOD() + 1;
        vm.prank(admin);
        vm.expectRevert(QuotaControl.TooLongPeriod.selector);
        escrow.setPeriod(tooLong);
    }

    function test_otherRolesGrantImmediately() public {
        bytes32 adminRole = escrow.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        escrow.grantRole(adminRole, bob);
        assertTrue(escrow.hasRole(adminRole, bob));
    }

    function test_scheduledChangesApplyAfterDelay() public {
        uint256 readyAt = block.timestamp + escrow.ADMIN_DELAY();

        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.ChangeScheduled(ArcadeEscrow.Change.MaxCharge, 2 * MAX_CHARGE, readyAt);
        _schedule(ArcadeEscrow.Change.MaxCharge, 2 * MAX_CHARGE);
        _schedule(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        _schedule(ArcadeEscrow.Change.Period, PERIOD / 2);
        _schedule(ArcadeEscrow.Change.GrantOracle, uint160(bob));

        vm.warp(readyAt - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.ChangeNotReady.selector, readyAt));
        escrow.executeChange(ArcadeEscrow.Change.MaxCharge, 2 * MAX_CHARGE);

        vm.warp(readyAt);
        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.ChangeExecuted(ArcadeEscrow.Change.MaxCharge, 2 * MAX_CHARGE);
        _execute(ArcadeEscrow.Change.MaxCharge, 2 * MAX_CHARGE);
        _execute(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        _execute(ArcadeEscrow.Change.Period, PERIOD / 2);
        _execute(ArcadeEscrow.Change.GrantOracle, uint160(bob));

        assertEq(escrow.maxCharge(), 2 * MAX_CHARGE);
        assertEq(escrow.quota(), 2 * QUOTA);
        assertEq(escrow.period(), PERIOD / 2);
        assertTrue(escrow.hasRole(escrow.ORACLE_ROLE(), bob));

        // Executed changes are consumed.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ArcadeEscrow.ChangeNotScheduled.selector, ArcadeEscrow.Change.Quota, 2 * QUOTA)
        );
        escrow.executeChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);
    }

    function test_cancelChange() public {
        _schedule(ArcadeEscrow.Change.Quota, 2 * QUOTA);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ArcadeEscrow.ChangeAlreadyScheduled.selector, ArcadeEscrow.Change.Quota, 2 * QUOTA)
        );
        escrow.scheduleChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);

        vm.expectEmit(address(escrow));
        emit ArcadeEscrow.ChangeCancelled(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        vm.prank(admin);
        escrow.cancelChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);

        vm.warp(block.timestamp + escrow.ADMIN_DELAY());
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ArcadeEscrow.ChangeNotScheduled.selector, ArcadeEscrow.Change.Quota, 2 * QUOTA)
        );
        escrow.executeChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        vm.expectRevert(
            abi.encodeWithSelector(ArcadeEscrow.ChangeNotScheduled.selector, ArcadeEscrow.Change.Quota, 2 * QUOTA)
        );
        escrow.cancelChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        vm.stopPrank();
    }

    function test_scheduleChangeValidates() public {
        vm.startPrank(admin);
        vm.expectRevert(ArcadeEscrow.ZeroAddress.selector);
        escrow.scheduleChange(ArcadeEscrow.Change.GrantOracle, 0);
        uint256 notAnAddress = uint256(type(uint160).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.AmountTooLarge.selector, notAnAddress));
        escrow.scheduleChange(ArcadeEscrow.Change.GrantOracle, notAnAddress);
        vm.expectRevert(QuotaControl.ZeroPeriod.selector);
        escrow.scheduleChange(ArcadeEscrow.Change.Period, 0);
        vm.stopPrank();
    }

    function test_onlyAdminCanUseTimelock() public {
        bytes32 adminRole = escrow.DEFAULT_ADMIN_ROLE();
        vm.startPrank(oracle);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.scheduleChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.cancelChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.executeChange(ArcadeEscrow.Change.Quota, 2 * QUOTA);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.setQuota(0);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, adminRole);
        escrow.setPeriod(PERIOD);
        vm.stopPrank();
    }

    /// @dev The point of the timelock: a user who reacts to a scheduled oracle grant at the slowest
    ///      allowed withdrawal delay still exits with their whole balance before the grant applies.
    function test_userExitsBeforeScheduledOracleCanCharge() public {
        uint64 maxDelay = escrow.MAX_WITHDRAW_DELAY();
        vm.prank(admin);
        escrow.setWithdrawDelay(maxDelay);
        _deposit(alice, 10 ether);

        address rogue = makeAddr("rogue");
        _schedule(ArcadeEscrow.Change.GrantOracle, uint160(rogue));

        vm.prank(alice);
        escrow.requestWithdraw(10 ether);
        vm.warp(block.timestamp + maxDelay);
        vm.prank(alice);
        escrow.withdraw();
        assertEq(escrow.balanceOf(alice), 0);

        vm.warp(block.timestamp + escrow.ADMIN_DELAY() - maxDelay);
        _execute(ArcadeEscrow.Change.GrantOracle, uint160(rogue));
        vm.prank(rogue);
        vm.expectRevert(abi.encodeWithSelector(ArcadeEscrow.InsufficientBalance.selector, 0, 1 ether));
        escrow.charge(alice, 1 ether, "drain");
    }

    // ── Fuzz ──────────────────────────────────────────────

    function testFuzz_depositChargeWithdraw(uint256 deposited, uint256 chargedAmount, uint256 requested) public {
        deposited = bound(deposited, MIN_DEPOSIT, 10_000 ether);
        chargedAmount = bound(chargedAmount, 1, deposited < MAX_CHARGE ? deposited : MAX_CHARGE);
        requested = bound(requested, 1, deposited);

        _deposit(alice, deposited);
        vm.prank(alice);
        escrow.requestWithdraw(requested);
        _charge(alice, chargedAmount, "x");

        vm.warp(block.timestamp + DELAY);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        escrow.withdraw();

        uint256 left = deposited - chargedAmount;
        uint256 paid = requested < left ? requested : left;
        assertEq(token.balanceOf(alice) - before, paid);
        assertEq(escrow.balanceOf(alice), left - paid);
        assertEq(escrow.feesAccrued(), chargedAmount);
        assertEq(token.balanceOf(address(escrow)), escrow.balanceOf(alice) + escrow.feesAccrued());
    }
}

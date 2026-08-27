// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";

/// @notice The goal latch: contributions are reversible below the target and binding at it.
/// @dev The rule is two strict comparisons. These tests exist so an off-by-one in either
///      direction — unwinding a met target, or locking contributors one unit early — fails
///      loudly.
contract GoalLatchTest is FundraisingTestBase {
    function test_belowGoal_unpledgeAllowed() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL - 1);

        assertTrue(f.canUnpledge());
        vm.prank(alice);
        f.unpledge(1);

        assertEq(f.raised(), GOAL - 2);
        assertEq(f.unpledged(), 1);
        assertEq(balanceOf(f, alice), FUNDED - (GOAL - 2));
    }

    function test_atExactlyGoal_latches() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);

        assertFalse(f.canUnpledge());
        vm.prank(alice);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.unpledge(1);
    }

    function test_aboveGoal_latches() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL + 1);

        assertFalse(f.canUnpledge());
        vm.prank(alice);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.unpledge(1);
    }

    /// @dev No flag, no event, no grace period: the crossing deposit latches in its own
    ///      transaction.
    function test_crossingDepositLatchesAtomically() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL - 10);
        assertTrue(f.canUnpledge());

        deposit(f, bob, 10);
        assertFalse(f.canUnpledge());
    }

    function test_cancelAlsoBlockedAtGoal() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);

        vm.prank(organizer);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.cancel();
    }

    /// @dev Contributions are still accepted after the latch, so the invariant is that
    ///      `raised` never re-crosses below `goal` — not that it stops moving.
    function test_depositsStillAcceptedAfterLatch() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        deposit(f, bob, 500e6);

        assertEq(f.raised(), GOAL + 500e6);
        assertFalse(f.canUnpledge());
    }

    /// @dev Topping up and then dropping back must be impossible, or the latch would only
    ///      be advisory.
    function test_latchNeverReopens() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);

        vm.prank(alice);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.unpledge(GOAL);

        // and still not after the deadline passes
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.unpledge(1);
    }

    /// @dev Past the deadline but not yet finalized, the fundraise is still below goal and
    ///      still `Funding`. Keeping the exit open means nobody is stranded in that window.
    function test_pastDeadlineButUnfinalized_exitStaysOpen() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);
        deposit(f, alice, 500e6);

        vm.warp(uint256(p.deadline) + 1 days);
        assertTrue(f.canUnpledge());

        vm.prank(alice);
        f.unpledge(500e6);
        assertEq(balanceOf(f, alice), FUNDED);
    }

    function test_unpledgeOnlyReturnsYourOwn() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);
        deposit(f, bob, 100e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InsufficientContribution.selector, 200e6, 100e6));
        f.unpledge(200e6);

        vm.prank(bob);
        f.unpledge(100e6);
        assertEq(f.contributions(alice), 400e6);
        assertEq(f.raised(), 400e6);
    }

    function test_rejects_zeroAmountUnpledge() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(IFundraiser.ZeroAmount.selector);
        f.unpledge(0);
    }

    function test_unpledgeAfterResolutionRejected() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);
        vm.prank(organizer);
        f.cancel();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Refunding));
        f.unpledge(1);
    }

    // ──────────────────────────────────────────────
    // Fuzz
    // ──────────────────────────────────────────────

    /// @dev After any sequence of deposits and withdrawals, the exit is open exactly when
    ///      the fundraise is below its target. That equivalence is the whole rule.
    function testFuzz_canUnpledgeTracksRaisedBelowGoal(uint96 a, uint96 b, uint96 pull) public {
        uint256 depA = bound(uint256(a), 1, FUNDED / 2);
        uint256 depB = bound(uint256(b), 1, FUNDED / 2);

        Fundraiser f = createDefault();
        deposit(f, alice, depA);
        assertEq(f.canUnpledge(), f.raised() < GOAL);

        if (f.canUnpledge()) {
            uint256 amount = bound(uint256(pull), 1, depA);
            vm.prank(alice);
            f.unpledge(amount);
            assertEq(f.canUnpledge(), f.raised() < GOAL);
        }

        deposit(f, bob, depB);
        assertEq(f.canUnpledge(), f.raised() < GOAL);

        // once reached, it must never reopen
        if (f.raised() >= GOAL) {
            vm.prank(bob);
            vm.expectRevert(IFundraiser.GoalReached.selector);
            f.unpledge(1);
        }
    }

    function testFuzz_boundaryAroundGoal(uint8 offset) public {
        // land anywhere in [goal-128, goal+127] and assert the rule holds exactly at goal
        uint256 target = uint256(GOAL) + offset - 128;
        Fundraiser f = createDefault();
        deposit(f, alice, target);

        if (target < GOAL) {
            assertTrue(f.canUnpledge());
            vm.prank(alice);
            f.unpledge(1);
        } else {
            assertFalse(f.canUnpledge());
            vm.prank(alice);
            vm.expectRevert(IFundraiser.GoalReached.selector);
            f.unpledge(1);
        }
    }
}

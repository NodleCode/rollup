// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";

/// @notice Every journey a fundraise can take, and every edge it must refuse.
contract LifecycleTest is FundraisingTestBase {
    // ──────────────────────────────────────────────
    // The three journeys that end in money moving
    // ──────────────────────────────────────────────

    function test_journey_targetReached_beneficiaryCollects() public {
        Fundraiser f = createDefault();
        assertEq(uint8(f.status()), uint8(Status.Funding));

        deposit(f, alice, 600e6);
        deposit(f, bob, 400e6);
        assertEq(f.raised(), GOAL);
        assertEq(f.remainingToGoal(), 0);

        vm.expectEmit(true, false, false, true, address(f));
        emit IFundraiser.Finalized(Status.Succeeded, GOAL, stranger);
        vm.prank(stranger);
        f.finalize();

        vm.prank(beneficiary);
        f.withdraw();

        assertEq(uint8(f.status()), uint8(Status.Closed));
        assertEq(balanceOf(f, beneficiary), FUNDED + GOAL);
        assertEq(balanceOf(f, address(f)), 0);
    }

    function test_journey_targetMissed_everyoneRefunded() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);

        deposit(f, alice, 300e6);
        deposit(f, bob, 200e6);

        vm.warp(p.deadline);
        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Refunding));

        vm.prank(alice);
        f.refund();
        vm.prank(bob);
        f.refund();

        assertEq(balanceOf(f, alice), FUNDED);
        assertEq(balanceOf(f, bob), FUNDED);
        assertEq(balanceOf(f, address(f)), 0);
        assertEq(f.refunded(), 500e6);
    }

    function test_journey_targetMissed_payBeneficiaryKeepsWhatWasRaised() public {
        FundraiserParams memory p = defaultParams();
        p.onMissed = OnMissed.PayBeneficiary;
        Fundraiser f = create(p);

        deposit(f, alice, 300e6);
        vm.warp(p.deadline);
        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Succeeded));

        vm.prank(beneficiary);
        f.withdraw();
        assertEq(balanceOf(f, beneficiary), FUNDED + 300e6);

        // and the contributor has no way back
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Closed));
        f.refund();
    }

    function test_journey_organizerCancels_beforeGoal() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 400e6);

        vm.expectEmit(true, false, false, true, address(f));
        emit IFundraiser.Cancelled(organizer, 400e6);
        vm.prank(organizer);
        f.cancel();

        vm.prank(alice);
        f.refund();
        assertEq(balanceOf(f, alice), FUNDED);
    }

    function test_journey_openEnded_runsUntilGoalReached() public {
        FundraiserParams memory p = defaultParams();
        p.deadline = 0;
        Fundraiser f = create(p);

        deposit(f, alice, 500e6);
        vm.warp(block.timestamp + 3650 days);

        // never resolves on its own
        vm.expectRevert(IFundraiser.NotFinalizable.selector);
        f.finalize();

        // and the exit is what keeps that safe
        assertTrue(f.canUnpledge());

        deposit(f, bob, 500e6);
        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Succeeded));
    }

    function test_journey_beneficiaryRepointsPayout() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();

        address newPayout = makeAddr("newPayout");
        vm.expectEmit(true, true, false, false, address(f));
        emit IFundraiser.PayoutAddressChanged(beneficiary, newPayout);
        vm.prank(beneficiary);
        f.setPayoutAddress(newPayout);

        vm.prank(newPayout);
        f.withdraw();
        assertEq(balanceOf(f, newPayout), GOAL);
        assertEq(balanceOf(f, beneficiary), FUNDED);
    }

    function test_journey_withFee() public {
        vm.prank(admin);
        factory.setFeeParams(250, feeSink); // 2.5%

        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();
        vm.prank(beneficiary);
        f.withdraw();

        // The fee is accrued, not paid inline — so a recipient that cannot receive the
        // token can never block the beneficiary. Anyone may push it to the recipient.
        assertEq(f.feeOwed(), 25e6);
        f.collectFee();

        assertEq(balanceOf(f, feeSink), 25e6);
        assertEq(balanceOf(f, beneficiary), FUNDED + GOAL - 25e6);
    }

    function test_feeRoundsDownInFavourOfContributors() public {
        vm.prank(admin);
        factory.setFeeParams(1, feeSink); // 0.01%

        FundraiserParams memory p = defaultParams();
        p.goal = 999; // 999 * 1 / 10000 = 0 after flooring
        Fundraiser f = create(p);
        deposit(f, alice, 999);
        f.finalize();
        vm.prank(beneficiary);
        f.withdraw();

        assertEq(balanceOf(f, feeSink), 0);
        assertEq(balanceOf(f, beneficiary), FUNDED + 999);
    }

    // ──────────────────────────────────────────────
    // Deadline boundary
    // ──────────────────────────────────────────────

    function test_atExactDeadline_depositsClosed_finalizeOpen() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);
        deposit(f, alice, 100e6);

        vm.warp(p.deadline);

        vm.startPrank(bob);
        token.approve(address(f), 1e6);
        vm.expectRevert(IFundraiser.DepositAfterDeadline.selector);
        f.deposit(1e6);
        vm.stopPrank();

        f.finalize(); // open at the same instant
        assertEq(uint8(f.status()), uint8(Status.Refunding));
    }

    function test_oneSecondBeforeDeadline_depositOpen_finalizeClosed() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);

        vm.warp(uint256(p.deadline) - 1);
        deposit(f, alice, 100e6);

        vm.expectRevert(IFundraiser.NotFinalizable.selector);
        f.finalize();
    }

    // ──────────────────────────────────────────────
    // Regressions named for the prior art
    // ──────────────────────────────────────────────

    /// @dev Party Protocol, Code4rena October 2023 finding M-06: a minimum-contribution
    ///      check made a crowdfund impossible to finalize, locking contributor funds until
    ///      expiry. A gap smaller than the minimum must still be fillable.
    function test_partyM06_gapSmallerThanMinimumIsStillFillable() public {
        FundraiserParams memory p = defaultParams();
        p.minContribution = 100e6;
        Fundraiser f = create(p);

        deposit(f, alice, 950e6);
        assertEq(f.remainingToGoal(), 50e6);

        // 50 is below the 100 minimum, but it reaches the goal, so it is accepted
        deposit(f, bob, 50e6);
        assertEq(f.raised(), GOAL);

        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Succeeded));
    }

    function test_minimumStillEnforcedWhenItDoesNotReachGoal() public {
        FundraiserParams memory p = defaultParams();
        p.minContribution = 100e6;
        Fundraiser f = create(p);

        vm.startPrank(alice);
        token.approve(address(f), 50e6);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.DepositBelowMinimum.selector, 50e6, uint128(100e6)));
        f.deposit(50e6);
        vm.stopPrank();
    }

    /// @dev An organizer who vanishes must not be able to freeze anyone's money.
    function test_organizerNeverActs_strangerResolvesAndEveryoneRecovers() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);
        deposit(f, alice, 400e6);

        vm.warp(p.deadline);
        vm.prank(stranger);
        f.finalize();

        vm.prank(stranger);
        f.refundFor(alice);
        assertEq(balanceOf(f, alice), FUNDED);
    }

    // ──────────────────────────────────────────────
    // Constructor validation
    // ──────────────────────────────────────────────

    function test_rejects_zeroGoal() public {
        FundraiserParams memory p = defaultParams();
        p.goal = 0;
        vm.expectRevert(IFundraiser.ZeroGoal.selector);
        create(p);
    }

    function test_rejects_zeroBeneficiary() public {
        FundraiserParams memory p = defaultParams();
        p.beneficiary = address(0);
        vm.expectRevert(IFundraiser.ZeroAddress.selector);
        create(p);
    }

    function test_rejects_deadlineInPast() public {
        FundraiserParams memory p = defaultParams();
        p.deadline = uint40(block.timestamp);
        vm.expectRevert(IFundraiser.DeadlineInPast.selector);
        create(p);
    }

    function test_rejects_deadlineBeyondMaxDuration() public {
        FundraiserParams memory p = defaultParams();
        p.deadline = uint40(block.timestamp + 366 days);
        vm.expectRevert();
        create(p);
    }

    function test_accepts_deadlineAtExactlyMaxDuration() public {
        FundraiserParams memory p = defaultParams();
        p.deadline = uint40(block.timestamp) + factory.MAX_DURATION();
        Fundraiser f = create(p);
        assertEq(f.deadline(), p.deadline);
    }

    function test_rejects_openEndedPayBeneficiary() public {
        FundraiserParams memory p = defaultParams();
        p.deadline = 0;
        p.onMissed = OnMissed.PayBeneficiary;
        vm.expectRevert(IFundraiser.PayBeneficiaryRequiresDeadline.selector);
        create(p);
    }

    function test_rejects_capBelowGoal() public {
        FundraiserParams memory p = defaultParams();
        p.maxTotalContributions = GOAL - 1;
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.CapBelowGoal.selector, GOAL - 1, GOAL));
        create(p);
    }

    function test_capIsEnforcedOnDeposit() public {
        FundraiserParams memory p = defaultParams();
        p.maxTotalContributions = GOAL;
        Fundraiser f = create(p);

        deposit(f, alice, 900e6);
        vm.startPrank(bob);
        token.approve(address(f), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.CapExceeded.selector, 200e6, 100e6));
        f.deposit(200e6);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Wrong-state and wrong-caller edges
    // ──────────────────────────────────────────────

    function test_rejects_zeroAmountDeposit() public {
        Fundraiser f = createDefault();
        vm.prank(alice);
        vm.expectRevert(IFundraiser.ZeroAmount.selector);
        f.deposit(0);
    }

    function test_rejects_depositAfterResolution() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();

        vm.startPrank(bob);
        token.approve(address(f), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Succeeded));
        f.deposit(1e6);
        vm.stopPrank();
    }

    function test_rejects_doubleFinalize() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Succeeded));
        f.finalize();
    }

    function test_rejects_withdrawByNonBeneficiary() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();
        vm.prank(organizer);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NotBeneficiary.selector, organizer));
        f.withdraw();
    }

    function test_rejects_withdrawBeforeSuccess() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 100e6);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Funding));
        f.withdraw();
    }

    function test_rejects_cancelByNonOrganizer() public {
        Fundraiser f = createDefault();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NotOrganizer.selector, alice));
        f.cancel();
    }

    function test_rejects_refundWhileFunding() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Funding));
        f.refund();
    }

    function test_rejects_setPayoutAddressByOrganizerOrAdmin() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();

        vm.prank(organizer);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NotBeneficiary.selector, organizer));
        f.setPayoutAddress(organizer);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.NotBeneficiary.selector, admin));
        f.setPayoutAddress(admin);
    }

    function test_rejects_setPayoutAddressToZero() public {
        Fundraiser f = createDefault();
        deposit(f, alice, GOAL);
        f.finalize();
        vm.prank(beneficiary);
        vm.expectRevert(IFundraiser.ZeroAddress.selector);
        f.setPayoutAddress(address(0));
    }
}

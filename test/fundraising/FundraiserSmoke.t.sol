// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ERC20Mock} from "../envelope/mocks/ERC20Mock.sol";
import {Fundraiser} from "../../src/fundraising/Fundraiser.sol";
import {IFundraiser} from "../../src/fundraising/interfaces/IFundraiser.sol";
import {FundraiserParams, OnMissed, Status} from "../../src/fundraising/interfaces/FundraisingTypes.sol";

/// @notice Smoke coverage for the core lifecycle while the full suite is still to come.
///         Not the suite described in the implementation plan.
contract FundraiserSmokeTest is Test {
    ERC20Mock token;
    address organizer = address(0x0A);
    address beneficiary = address(0xBE);
    address alice = address(0xA1);
    address bob = address(0xB0);
    address factory = address(this); // stands in; only feeRecipient()/hasRole() are called

    uint128 constant GOAL = 1_000e6;

    function setUp() public {
        token = new ERC20Mock();
        token.mint(alice, 10_000e6);
        token.mint(bob, 10_000e6);
    }

    // Stand-in for the factory views the escrow consults.
    function feeRecipient() external pure returns (address) {
        return address(0);
    }

    function _params(uint40 deadline, OnMissed onMissed) internal view returns (FundraiserParams memory p) {
        p = FundraiserParams({
            name: "Lisbon trip",
            token: address(token),
            goal: GOAL,
            deadline: deadline,
            onMissed: onMissed,
            beneficiary: beneficiary,
            minContribution: 0,
            maxTotalContributions: 0
        });
    }

    function _new(uint40 deadline, OnMissed onMissed) internal returns (Fundraiser f) {
        f = new Fundraiser(_params(deadline, onMissed), organizer, 0, factory);
    }

    function _deposit(Fundraiser f, address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(f), amount);
        f.deposit(amount);
        vm.stopPrank();
    }

    function test_happyPath_reachGoal_finalize_withdraw() public {
        Fundraiser f = _new(uint40(block.timestamp + 30 days), OnMissed.Refund);

        _deposit(f, alice, 600e6);
        _deposit(f, bob, 400e6);
        assertEq(f.raised(), GOAL);

        // permissionless finalize: a complete stranger closes it
        vm.prank(address(0xDEAD));
        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Succeeded));

        vm.prank(beneficiary);
        f.withdraw();
        assertEq(token.balanceOf(beneficiary), GOAL);
        assertEq(uint8(f.status()), uint8(Status.Closed));
    }

    function test_goalLatch_openBelow_closedAtGoal() public {
        Fundraiser f = _new(uint40(block.timestamp + 30 days), OnMissed.Refund);

        _deposit(f, alice, GOAL - 1);
        assertTrue(f.canUnpledge());

        vm.prank(alice);
        f.unpledge(1); // below goal: allowed
        assertEq(f.raised(), GOAL - 2);

        _deposit(f, alice, 2); // crosses to exactly goal
        assertEq(f.raised(), GOAL);
        assertFalse(f.canUnpledge());

        vm.prank(alice);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.unpledge(1);

        vm.prank(organizer);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.cancel();
    }

    function test_missedDeadline_refundsEveryone() public {
        uint40 deadline = uint40(block.timestamp + 7 days);
        Fundraiser f = _new(deadline, OnMissed.Refund);

        _deposit(f, alice, 300e6);
        _deposit(f, bob, 200e6);

        vm.warp(deadline);
        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Refunding));

        vm.prank(alice);
        f.refund();
        assertEq(token.balanceOf(alice), 10_000e6);

        // anyone may push bob's refund; it still goes to bob
        vm.prank(address(0xDEAD));
        f.refundFor(bob);
        assertEq(token.balanceOf(bob), 10_000e6);
        assertEq(token.balanceOf(address(f)), 0);
    }

    function test_missedDeadline_payBeneficiary() public {
        uint40 deadline = uint40(block.timestamp + 7 days);
        Fundraiser f = _new(deadline, OnMissed.PayBeneficiary);

        _deposit(f, alice, 300e6);
        vm.warp(deadline);
        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Succeeded));

        vm.prank(beneficiary);
        f.withdraw();
        assertEq(token.balanceOf(beneficiary), 300e6);
    }

    function test_openEnded_neverAutoResolves_andExitStaysOpen() public {
        Fundraiser f = _new(0, OnMissed.Refund);
        _deposit(f, alice, 500e6);

        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(IFundraiser.NotFinalizable.selector);
        f.finalize();

        // the exit is what makes open-ended safe
        assertTrue(f.canUnpledge());
        vm.prank(alice);
        f.unpledge(500e6);
        assertEq(token.balanceOf(alice), 10_000e6);
    }

    function test_rejects_openEnded_payBeneficiary() public {
        vm.expectRevert(IFundraiser.PayBeneficiaryRequiresDeadline.selector);
        new Fundraiser(_params(0, OnMissed.PayBeneficiary), organizer, 0, factory);
    }

    function test_anyoneCanContribute() public {
        Fundraiser f = _new(uint40(block.timestamp + 30 days), OnMissed.Refund);
        address stranger = address(0x5555);
        token.mint(stranger, 1_000e6);
        _deposit(f, stranger, 1_000e6);
        assertEq(f.raised(), GOAL);
        assertEq(f.contributions(stranger), GOAL);
    }
}

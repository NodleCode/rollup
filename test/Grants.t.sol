// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/Grants.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("MockToken", "MTK") {
        _mint(msg.sender, 1000000);
    }
}

contract GrantsTest is Test {
    Grants public grants;
    MockToken public token;
    address public alice;
    address public bob;
    address public charlie;

    function setUp() public {
        token = new MockToken();
        grants = new Grants(address(token), 100, 3);
        alice = address(0x1);
        bob = address(0x2);
        charlie = address(0x3);
        token.transfer(alice, 10000);
        token.transfer(charlie, 10000);
    }

    function test_addVestingSchedule() public {
        vm.startPrank(alice);
        token.approve(address(grants), 1000);

        vm.expectEmit();
        emit Grants.VestingScheduleAdded(bob, Grants.VestingSchedule(alice, block.timestamp + 1 days, 2 days, 4, 100));
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, alice);

        grants.addVestingSchedule(bob, block.timestamp + 3 days, 7 days, 3, 200, alice);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(grants), 700);
        grants.addVestingSchedule(bob, block.timestamp + 5 days, 1 days, 2, 350, charlie);
        vm.stopPrank();

        assertEq(token.balanceOf(address(grants)), 1700);

        checkP0Schedule(bob, 0, alice, block.timestamp + 1 days, 2 days, 4, 100);
        checkP0Schedule(bob, 1, alice, block.timestamp + 3 days, 7 days, 3, 200);
        checkP0Schedule(bob, 2, charlie, block.timestamp + 5 days, 1 days, 2, 350);

        emit log("Test Add Vesting Schedule Passed!");
    }

    function test_nothingToClaimBeforeStart() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants.claim(0, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 0);
        checkP0Schedule(bob, 0, alice, block.timestamp + 1 days, 2 days, 4, 100);
        emit log("Test Nothing to Claim Before Start Passed!");
    }

    function test_nothingToClaimBeforeOnePeriod() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.startPrank(bob);
        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants.claim(0, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 0);
        checkP0Schedule(bob, 0, alice, block.timestamp + 1 days, 2 days, 4, 100);
        emit log("Test Nothing to Claim Before One Period!");
    }

    function test_claimAfterOnePeriod() public {
        uint256 start = block.timestamp + 1 days;
        uint256 period = 2 days;
        uint256 nextStart = start + period;
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        grants.addVestingSchedule(bob, start, period, 4, 100, alice);
        vm.stopPrank();

        vm.warp(nextStart + 1 days);

        vm.startPrank(bob);
        vm.expectEmit();
        emit Grants.Claimed(bob, 100, 0, 1);
        grants.claim(0, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100);
        checkP0Schedule(bob, 0, alice, nextStart, 2 days, 3, 100);
        emit log("Test Claim After One Period!");
    }

    function test_claimSeveralGrants() public {
        uint256 start = block.timestamp + 1 days;
        vm.startPrank(alice);
        token.approve(address(grants), 1600);
        grants.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(grants), 1200);
        grants.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, charlie);
        vm.stopPrank();

        vm.warp(start + 10 days);

        vm.startPrank(bob);
        grants.claim(0, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 1400);
        checkP0Schedule(bob, 0, alice, block.timestamp, 2 days, 1, 100);
        checkP0Schedule(bob, 1, alice, block.timestamp, 3 days, 2, 200);
        checkP0Schedule(bob, 2, charlie, block.timestamp - 1 days, 7 days, 3, 300);

        emit log("Test Add Vesting Schedule Passed!");
    }

    function test_claimAllPages() public {
        Grants grants2 = new Grants(address(token), 100, 1);
        uint256 start = block.timestamp + 1 days;
        vm.startPrank(alice);
        token.approve(address(grants2), 1600);
        grants2.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants2.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(grants2), 1200);
        grants2.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, charlie);
        vm.stopPrank();

        vm.warp(start + 10 days);

        vm.startPrank(bob);
        vm.expectEmit();
        emit Grants.Claimed(bob, 1400, 0, 3);
        grants2.claim(0, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 1400);
        emit log("Test Claim All Grants In All Pages Passed!");
    }

    function test_claimLimitedPageRange() public {
        Grants grants2 = new Grants(address(token), 100, 1);
        uint256 start = block.timestamp + 1 days;
        vm.startPrank(alice);
        token.approve(address(grants2), 1600);
        grants2.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants2.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(grants2), 1200);
        grants2.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, charlie);
        vm.stopPrank();

        vm.warp(start + 10 days);

        vm.startPrank(bob);

        vm.expectEmit();
        emit Grants.Claimed(bob, 500, 0, 1);
        grants2.claim(0, 1);
        assertEq(token.balanceOf(bob), 500);

        vm.expectEmit();
        emit Grants.Claimed(bob, 600, 1, 2);
        grants2.claim(1, 2);
        assertEq(token.balanceOf(bob), 1100);

        vm.expectEmit();
        emit Grants.Claimed(bob, 300, 2, 3);
        grants2.claim(2, 3);
        assertEq(token.balanceOf(bob), 1400);

        vm.stopPrank();

        emit log("Test Claim Limited Page Range Passed!");
    }

    function test_claimRemovesFullyVestedSchedules() public {
        uint256 start = block.timestamp + 1 days;
        vm.startPrank(alice);
        token.approve(address(grants), 600);
        grants.addVestingSchedule(bob, start, 2 days, 3, 100, alice);
        grants.addVestingSchedule(bob, start + 10 days, 3 days, 2, 100, alice);
        vm.stopPrank();

        assertEq(grants.getGrantsCount(bob), 2);

        vm.warp(start + 8 days);

        vm.startPrank(bob);
        grants.claim(0, 0);
        vm.stopPrank();

        assertEq(grants.getGrantsCount(bob), 1);

        checkP0Schedule(bob, 0, alice, start + 10 days, 3 days, 2, 100);
        emit log("Test Claim Removes Fully Vested Schedules Passed!");
    }

    function test_claimRemovesAllSchedules() public {
        uint256 start = block.timestamp + 1 days;
        vm.startPrank(alice);
        token.approve(address(grants), 500);
        grants.addVestingSchedule(bob, start, 2 days, 3, 100, alice);
        grants.addVestingSchedule(bob, start + 10 days, 3 days, 2, 100, alice);
        vm.stopPrank();

        assertEq(grants.getGrantsCount(bob), 2);

        vm.warp(start + 20 days);

        vm.startPrank(bob);
        grants.claim(0, 0);
        vm.stopPrank();

        assertEq(grants.getGrantsCount(bob), 0);

        emit log("Test Claim Removes All Schedules Passed!");
    }

    function test_CancelVestingSchedulesRedeemsAllIfNoneVested() public {
        uint256 start = block.timestamp;
        uint256 aliceBalance = token.balanceOf(alice);

        vm.startPrank(alice);

        token.approve(address(grants), 1600);

        grants.addVestingSchedule(bob, start + 2 days, 2 days, 6, 100, alice);
        grants.addVestingSchedule(bob, start + 3 days, 3 days, 5, 200, alice);

        vm.warp(start + 3 days);

        vm.expectEmit();
        emit Grants.VestingSchedulesCanceled(alice, bob, 0, 1);
        grants.cancelVestingSchedules(bob, 0, 0);

        vm.stopPrank();

        assertEq(token.balanceOf(bob), 0);
        assertEq(grants.getGrantsCount(bob), 0);
        assertEq(token.balanceOf(alice), aliceBalance);
        emit log("Test Cancel Vesting Schedules Redeems All Passed!");
    }

    function test_CancelVestingSchedulesRedeemsPartiallyVested() public {
        uint256 start = block.timestamp;
        uint256 aliceBalance = token.balanceOf(alice);

        vm.startPrank(alice);

        token.approve(address(grants), 1600);

        grants.addVestingSchedule(bob, start + 2 days, 2 days, 6, 100, alice);
        grants.addVestingSchedule(bob, start + 3 days, 3 days, 5, 200, alice);

        vm.warp(start + 5 days);

        grants.cancelVestingSchedules(bob, 0, 0);

        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100);
        assertEq(grants.getGrantsCount(bob), 0);
        assertEq(token.balanceOf(alice), aliceBalance - 100);
        emit log("Test Cancel Vesting Schedules Redeems Partially Vested Passed!");
    }

    function test_CancelVestingSchedulesRedeemsZeroIfFullyVested() public {
        uint256 start = block.timestamp;
        uint256 aliceBalance = token.balanceOf(alice);

        vm.startPrank(alice);

        token.approve(address(grants), 1300);

        grants.addVestingSchedule(bob, start + 2 days, 2 days, 3, 100, alice);
        grants.addVestingSchedule(bob, start + 3 days, 3 days, 5, 200, alice);

        vm.warp(start + 20 days);

        grants.cancelVestingSchedules(bob, 0, 0);

        vm.stopPrank();

        assertEq(token.balanceOf(bob), 1300);
        assertEq(grants.getGrantsCount(bob), 0);
        assertEq(token.balanceOf(alice), aliceBalance - 1300);
        emit log("Test Cancel Vesting Schedules Redeems Zero Passed!");
    }

    function test_aliceCanOnlyCancelHerOwnGivenGrants() public {
        vm.startPrank(alice);
        token.approve(address(grants), 1000);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, alice);
        grants.addVestingSchedule(bob, block.timestamp + 3 days, 7 days, 3, 200, alice);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(grants), 700);
        grants.addVestingSchedule(bob, block.timestamp + 5 days, 1 days, 2, 350, charlie);
        vm.stopPrank();

        assertEq(grants.getGrantsCount(bob), 3);

        vm.startPrank(alice);
        grants.cancelVestingSchedules(bob, 0, 0);
        vm.stopPrank();
        assertEq(grants.getGrantsCount(bob), 1);
        checkP0Schedule(bob, 0, charlie, block.timestamp + 5 days, 1 days, 2, 350);
    }

    function test_cancelAllPages() public {
        Grants grants2 = new Grants(address(token), 100, 1);
        uint256 start = block.timestamp + 1 days;

        vm.startPrank(alice);

        token.approve(address(grants2), 2800);
        grants2.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants2.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        grants2.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, alice);
        assertEq(grants2.getGrantsCount(bob), 3);

        vm.expectEmit();
        emit Grants.VestingSchedulesCanceled(alice, bob, 0, 3);
        grants2.cancelVestingSchedules(bob, 0, 0);
        vm.stopPrank();

        assertEq(grants2.getGrantsCount(bob), 0);
        emit log("Test Cancel All Grants In All Pages Passed!");
    }

    function test_cancelLimitedPageRange() public {
        Grants grants2 = new Grants(address(token), 100, 1);
        uint256 start = block.timestamp + 1 days;

        vm.startPrank(alice);

        token.approve(address(grants2), 2800);
        grants2.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants2.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        grants2.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, alice);
        assertEq(grants2.getGrantsCount(bob), 3);

        vm.expectEmit();
        emit Grants.VestingSchedulesCanceled(alice, bob, 1, 2);
        grants2.cancelVestingSchedules(bob, 1, 2);
        assertEq(grants2.getGrantsCount(bob), 2);

        vm.expectEmit();
        emit Grants.VestingSchedulesCanceled(alice, bob, 0, 1);
        grants2.cancelVestingSchedules(bob, 0, 1);
        assertEq(grants2.getGrantsCount(bob), 1);

        vm.expectEmit();
        emit Grants.VestingSchedulesCanceled(alice, bob, 2, 3);
        grants2.cancelVestingSchedules(bob, 2, 3);

        vm.stopPrank();

        assertEq(grants2.getGrantsCount(bob), 0);
        emit log("Test Cancel Grants Limited Page Range Passed!");
    }

    function test_renouncedCannotBeCanceled() public {
        vm.startPrank(alice);
        token.approve(address(grants), 1000);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, alice);
        grants.addVestingSchedule(bob, block.timestamp + 3 days, 7 days, 3, 200, alice);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(grants), 700);
        grants.addVestingSchedule(bob, block.timestamp + 5 days, 1 days, 2, 350, charlie);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectEmit();
        emit Grants.Renounced(alice, bob, 0, 1);
        grants.renounce(bob, 0, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants.cancelVestingSchedules(bob, 0, 0);
        vm.stopPrank();
        assertEq(grants.getGrantsCount(bob), 3);

        vm.startPrank(charlie);
        grants.cancelVestingSchedules(bob, 0, 0);
        vm.stopPrank();
        assertEq(grants.getGrantsCount(bob), 2);
    }

    function test_cancelAuthorityCouldBeDifferentFromGranter() public {
        vm.startPrank(alice);
        token.approve(address(grants), 1000);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, charlie);
        grants.addVestingSchedule(bob, block.timestamp + 3 days, 7 days, 3, 200, charlie);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(grants), 700);
        grants.addVestingSchedule(bob, block.timestamp + 5 days, 1 days, 2, 350, charlie);
        vm.stopPrank();

        assertEq(grants.getGrantsCount(bob), 3);

        vm.startPrank(charlie);
        grants.cancelVestingSchedules(bob, 0, 0);
        vm.stopPrank();
        assertEq(grants.getGrantsCount(bob), 0);
    }

    function test_renounceRevertsIfNoSchedules() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, address(0));
        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants.renounce(bob, 0, 0);
        vm.stopPrank();
    }

    function test_renounceAllPages() public {
        Grants grants2 = new Grants(address(token), 100, 1);
        uint256 start = block.timestamp + 1 days;

        vm.startPrank(alice);

        token.approve(address(grants2), 2800);
        grants2.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants2.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        grants2.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, alice);

        vm.expectEmit();
        emit Grants.Renounced(alice, bob, 0, 3);
        grants2.renounce(bob, 0, 0);

        assertEq(grants2.getGrantsCount(bob), 3);

        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants2.cancelVestingSchedules(bob, 0, 0);

        vm.stopPrank();

        emit log("Test Renounce All Grants In All Pages Passed!");
    }

    function test_renounceLimitedPageRange() public {
        Grants grants2 = new Grants(address(token), 100, 1);
        uint256 start = block.timestamp + 1 days;

        vm.startPrank(alice);

        token.approve(address(grants2), 2800);
        grants2.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants2.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        grants2.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, alice);

        vm.expectEmit();
        emit Grants.Renounced(alice, bob, 1, 2);
        grants2.renounce(bob, 1, 2);

        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants2.cancelVestingSchedules(bob, 1, 2);

        vm.expectEmit();
        emit Grants.Renounced(alice, bob, 0, 1);
        grants2.renounce(bob, 0, 1);

        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants2.cancelVestingSchedules(bob, 0, 2);

        vm.expectEmit();
        emit Grants.Renounced(alice, bob, 2, 3);
        grants2.renounce(bob, 2, 3);

        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants2.cancelVestingSchedules(bob, 0, 0);

        vm.stopPrank();

        emit log("Test Renounce Grants Limited Page Range Passed!");
    }

    function test_nonCancellableSchedule() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, address(0));
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(Grants.NoOpIsFailure.selector);
        grants.cancelVestingSchedules(bob, 0, 0);
        vm.stopPrank();
    }

    function test_vestingToSelfReverts() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        vm.expectRevert(Grants.VestingToSelf.selector);
        grants.addVestingSchedule(alice, block.timestamp + 1 days, 2 days, 4, 100, alice);
        vm.stopPrank();
    }

    function test_zeroVestingPeriodReverts() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        vm.expectRevert(Grants.InvalidZeroParameter.selector);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 0, 4, 100, alice);
        vm.stopPrank();
    }

    function test_zeroCountReverts() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        vm.expectRevert(Grants.InvalidZeroParameter.selector);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 0, 100, alice);
        vm.stopPrank();
    }

    function test_vestingToZeroAddressReverts() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        vm.expectRevert(Grants.InvalidZeroParameter.selector);
        grants.addVestingSchedule(address(0), block.timestamp + 1 days, 2 days, 4, 100, alice);
        vm.stopPrank();
    }

    function test_addingManySchedule() public {
        vm.startPrank(alice);
        token.approve(address(grants), 10100);
        for (uint32 i = 0; i < grants.pageLimit(); i++) {
            grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 1, 100, alice);
        }
        assertEq(grants.currentPage(bob), 0);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, alice);
        assertEq(grants.currentPage(bob), 1);
        vm.stopPrank();
        assertEq(grants.getGrantsCount(bob), grants.pageLimit() + 1);
    }

    function test_addVestingScheduleFailsIfNotEnoughToken() public {
        vm.startPrank(alice);
        token.approve(address(grants), 100);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(grants), 100, 400)
        );
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 100, alice);
        vm.stopPrank();
    }

    function test_addVestingScheduleFailsIfDustVesting() public {
        vm.startPrank(alice);
        token.approve(address(grants), 400);
        vm.expectRevert(Grants.LowVestingAmount.selector);
        grants.addVestingSchedule(bob, block.timestamp + 1 days, 2 days, 4, 1, alice);
        vm.stopPrank();
    }

    function test_invalidPageReverts(uint256 randomInput) public {
        uint256 startPage = bound(randomInput, 2, type(uint256).max);
        uint256 endPage = bound(randomInput, 1, startPage - 1);
        assert(startPage > endPage);

        Grants grants2 = new Grants(address(token), 100, 1);
        uint256 start = block.timestamp + 1 days;

        vm.startPrank(alice);

        token.approve(address(grants2), 2800);
        grants2.addVestingSchedule(bob, start, 2 days, 6, 100, alice);
        grants2.addVestingSchedule(bob, start + 1 days, 3 days, 5, 200, alice);
        grants2.addVestingSchedule(bob, start + 2 days, 7 days, 4, 300, alice);

        uint256 numOfPages = grants2.currentPage(bob) + 1;

        // start > end
        vm.expectRevert(Grants.InvalidPage.selector);
        grants2.cancelVestingSchedules(bob, startPage, endPage);
        vm.expectRevert(Grants.InvalidPage.selector);
        grants2.renounce(bob, startPage, endPage);

        // start > total
        vm.expectRevert(Grants.InvalidPage.selector);
        grants2.cancelVestingSchedules(bob, numOfPages + 1, numOfPages + 2);
        vm.expectRevert(Grants.InvalidPage.selector);
        grants2.renounce(bob, numOfPages + 1, numOfPages + 2);

        vm.stopPrank();

        vm.startPrank(bob);

        // start > end
        vm.expectRevert(Grants.InvalidPage.selector);
        grants2.claim(startPage, endPage);

        // start > total
        vm.expectRevert(Grants.InvalidPage.selector);
        grants2.claim(numOfPages + 1, numOfPages + 2);

        vm.stopPrank();

        emit log("Test Invalid Page Reverts Passed!");
    }

    function checkP0Schedule(
        address beneficiary,
        uint256 index,
        address expectedCancelAuthority,
        uint256 expectedStart,
        uint256 expectedPeriod,
        uint32 expectedPeriodCount,
        uint256 expectedPerPeriodAmount
    ) internal {
        (address cancelAuthority, uint256 start, uint256 period, uint32 periodCount, uint256 perPeriodAmount) =
            grants.vestingSchedules(beneficiary, 0, index);
        assertEq(cancelAuthority, expectedCancelAuthority);
        assertEq(start, expectedStart);
        assertEq(period, expectedPeriod);
        assertEq(periodCount, expectedPeriodCount);
        assertEq(perPeriodAmount, expectedPerPeriodAmount);
    }
}

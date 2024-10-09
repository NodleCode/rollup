// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/QuotaControl.sol";
import "./__helpers__/AccessControlUtils.sol";

contract TestableQuotaControl is QuotaControl {
    constructor(uint256 initialQuota, uint256 initialPeriod, address admin)
        QuotaControl(initialQuota, initialPeriod, admin)
    {}

    function exposeCheckedResetClaimed() external {
        _checkedResetClaimed();
    }

    function exposeCheckedUpdateClaimed(uint256 amount) external {
        _checkedUpdateClaimed(amount);
    }
}

contract QuotaControlTest is Test {
    using AccessControlUtils for Vm;

    address admin;
    TestableQuotaControl quotaControl;

    uint256 constant RENEWAL_PERIOD = 1 days;

    function setUp() public {
        admin = address(1);
        quotaControl = new TestableQuotaControl(1000, RENEWAL_PERIOD, admin);
    }

    function test_setQuota() public {
        assertEq(quotaControl.quota(), 1000);
        vm.prank(admin);
        vm.expectEmit();
        emit QuotaControl.QuotaSet(2000);
        quotaControl.setQuota(2000);
        assertEq(quotaControl.quota(), 2000);
    }

    function test_setPeriod() public {
        assertEq(quotaControl.period(), RENEWAL_PERIOD);
        vm.startPrank(admin);
        vm.expectEmit();
        emit QuotaControl.PeriodSet(2 * RENEWAL_PERIOD);
        quotaControl.setPeriod(2 * RENEWAL_PERIOD);
        assertEq(quotaControl.period(), 2 * RENEWAL_PERIOD);
        quotaControl.setPeriod(RENEWAL_PERIOD);
        vm.stopPrank();
    }

    function test_setPeriodOutOfRange() public {
        vm.startPrank(admin);
        vm.expectRevert(QuotaControl.ZeroPeriod.selector);
        quotaControl.setPeriod(0);
        uint256 tooLongPeriod = quotaControl.MAX_PERIOD() + 1;
        vm.expectRevert(QuotaControl.TooLongPeriod.selector);
        quotaControl.setPeriod(tooLongPeriod);
        vm.stopPrank();
    }

    function test_setPeriodUnauthorized() public {
        address bob = address(3);
        vm.expectRevert_AccessControlUnauthorizedAccount(bob, quotaControl.DEFAULT_ADMIN_ROLE());
        vm.prank(bob);
        quotaControl.setPeriod(2 * RENEWAL_PERIOD);
    }

    function test_setQuotaUnauthorized() public {
        address bob = address(3);
        vm.expectRevert_AccessControlUnauthorizedAccount(bob, quotaControl.DEFAULT_ADMIN_ROLE());
        vm.prank(bob);
        quotaControl.setQuota(2000);
    }

    function test_rewardsClaimedResetsOnNewPeriod() public {
        uint256 upcomingRenewal = quotaControl.quotaRenewalTimestamp();

        vm.warp(upcomingRenewal + 1 seconds);

        quotaControl.exposeCheckedResetClaimed();
        assertEq(quotaControl.claimed(), 0);
        quotaControl.exposeCheckedUpdateClaimed(100);
        assertEq(quotaControl.claimed(), 100);
        uint256 nextRenewal = RENEWAL_PERIOD + upcomingRenewal;
        assertEq(quotaControl.quotaRenewalTimestamp(), nextRenewal);

        vm.warp(nextRenewal + 1 seconds);

        quotaControl.exposeCheckedResetClaimed();
        assertEq(quotaControl.claimed(), 0);
    }

    function test_rewardsClaimedAccumulates() public {
        uint256 renewalTimeStamp = quotaControl.quotaRenewalTimestamp();

        vm.warp(renewalTimeStamp + 1 seconds);

        quotaControl.exposeCheckedResetClaimed();
        assertEq(quotaControl.claimed(), 0);
        quotaControl.exposeCheckedUpdateClaimed(100);
        assertEq(quotaControl.claimed(), 100);
        quotaControl.exposeCheckedUpdateClaimed(50);
        assertEq(quotaControl.claimed(), 150);
    }

    function test_claimFailsToExceedQuota() public {
        uint256 renewalTimeStamp = quotaControl.quotaRenewalTimestamp();

        vm.warp(renewalTimeStamp + 1 seconds);
        quotaControl.exposeCheckedResetClaimed();
        assertEq(quotaControl.claimed(), 0);

        uint256 quota = quotaControl.quota();
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        quotaControl.exposeCheckedUpdateClaimed(quota + 1);
    }
}

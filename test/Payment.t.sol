// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/Payment.sol";
import "../src/QuotaControl.sol";
import "./__helpers__/AccessControlUtils.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("MockToken", "MTK") {
        _mint(msg.sender, 1000000);
    }
}

contract PaymentTest is Test {
    using AccessControlUtils for Vm;

    address admin;
    address oracle;
    address user;
    Payment payment;
    MockToken token;

    function setUp() public {
        admin = address(1);
        oracle = address(2);
        user = address(3);
        token = new MockToken();
        payment = new Payment(oracle, address(token), 1000, 1 days, admin);
    }

    function test_onlyAdminCanControlQuotaAndWithdraw() public {
        uint256 budget = 100;
        token.transfer(address(payment), budget);

        uint256 quota = payment.quota();
        uint256 period = payment.period();

        vm.startPrank(oracle);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, payment.DEFAULT_ADMIN_ROLE());
        payment.setQuota(quota * 2);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, payment.DEFAULT_ADMIN_ROLE());
        payment.setPeriod(period + 1 seconds);
        vm.expectRevert_AccessControlUnauthorizedAccount(oracle, payment.DEFAULT_ADMIN_ROLE());
        payment.withdraw(user, budget);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert_AccessControlUnauthorizedAccount(user, payment.DEFAULT_ADMIN_ROLE());
        payment.setQuota(quota * 2);
        vm.expectRevert_AccessControlUnauthorizedAccount(user, payment.DEFAULT_ADMIN_ROLE());
        payment.setPeriod(period + 1 seconds);
        vm.expectRevert_AccessControlUnauthorizedAccount(user, payment.DEFAULT_ADMIN_ROLE());
        payment.withdraw(user, budget);
        vm.stopPrank();

        vm.startPrank(admin);
        payment.setQuota(quota * 2);
        assertEq(payment.quota(), quota * 2);
        payment.setPeriod(period + 1 seconds);
        assertEq(payment.period(), period + 1 seconds);
        payment.withdraw(user, budget);
        assertEq(token.balanceOf(user), budget);

        // restore the original settings
        payment.setQuota(quota);
        payment.setPeriod(period);
        vm.stopPrank();
    }

    function test_onlyOracleCanPay() public {
        uint256 budget = 100;
        token.transfer(address(payment), budget);

        assertEq(token.balanceOf(user), 0);

        address[] memory payees = new address[](1);
        payees[0] = user;
        vm.startPrank(user);
        vm.expectRevert_AccessControlUnauthorizedAccount(user, payment.ORACLE_ROLE());
        payment.pay(payees, budget);
        vm.stopPrank();

        assertEq(token.balanceOf(user), 0);

        vm.prank(oracle);
        payment.pay(payees, budget);

        assertEq(token.balanceOf(user), budget);
    }

    function test_goingOverBudgetRevertsEarly() public {
        uint256 budget = 150;
        token.transfer(address(payment), budget);

        address[] memory payees = new address[](3);
        payees[0] = user;
        payees[1] = user;
        payees[2] = user;

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Payment.InsufficientBalance.selector, budget, budget * 3));
        payment.pay(payees, budget);
    }

    function test_goingOverQuotaReverts() public {
        uint256 quota = payment.quota();
        uint256 budget = quota * 2;
        token.transfer(address(payment), budget);

        address[] memory payees = new address[](1);
        payees[0] = user;

        vm.prank(oracle);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        payment.pay(payees, quota + 1);
    }

    function test_usedQuotaAccumulates() public {
        uint256 quota = payment.quota();
        uint256 budget = quota * 2;
        token.transfer(address(payment), budget);

        address[] memory payees = new address[](1);
        payees[0] = user;

        assertEq(payment.claimed(), 0);
        vm.startPrank(oracle);
        payment.pay(payees, quota / 2);
        assertEq(payment.claimed(), quota / 2);
        payment.pay(payees, quota / 2);
        assertEq(payment.claimed(), quota);

        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        payment.pay(payees, 1);
        vm.stopPrank();
    }

    function test_quotaIsRenewedAfterEnoughTime() public {
        uint256 quota = payment.quota();
        uint256 budget = quota * 2;
        token.transfer(address(payment), budget);

        address[] memory payees = new address[](1);
        payees[0] = user;

        vm.startPrank(oracle);
        payment.pay(payees, quota);
        assertEq(payment.claimed(), quota);

        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        payment.pay(payees, 1);

        uint256 upcomingRenewal = payment.quotaRenewalTimestamp();
        vm.warp(upcomingRenewal + 1 seconds);

        payment.pay(payees, quota);
        vm.stopPrank();
    }
}

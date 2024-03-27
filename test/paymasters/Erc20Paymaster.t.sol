// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";
import {BasePaymaster} from "../../src/paymasters/BasePaymaster.sol";
import {Erc20Paymaster} from "../../src/paymasters/Erc20Paymaster.sol";

contract MockErc20Paymaster is Erc20Paymaster {
    constructor(
        address admin,
        address priceOracle,
        IERC20 erc20,
        uint256 initialFeePrice
    ) Erc20Paymaster(admin, priceOracle, erc20, initialFeePrice) {}

    function mock_validateAndPayGeneralFlow(
        address from,
        address to,
        uint256 requiredETH
    ) public pure {
        _validateAndPayGeneralFlow(from, to, requiredETH);
    }

    function mock_validateAndPayApprovalBasedFlow(
        address from,
        address to,
        address token,
        uint256 amount,
        bytes memory data,
        uint256 requiredETH
    ) public {
        _validateAndPayApprovalBasedFlow(
            from,
            to,
            token,
            amount,
            data,
            requiredETH
        );
    }
}

contract Erc20PaymasterTest is Test {
    using AccessControlUtils for Vm;

    MockERC20 private token;
    MockErc20Paymaster private paymaster;

    address internal alice = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal charlie = vm.addr(3);

    function setUp() public {
        token = deployMockERC20("Name", "Symbol", 18);
        paymaster = new MockErc20Paymaster(
            alice,
            bob,
            IERC20(address(token)),
            1
        );
    }

    function test_defaultACLs() public view {
        assert(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), alice));
        assert(paymaster.hasRole(paymaster.PRICE_ORACLE_ROLE(), bob));
    }

    function test_updateFeePrice() public {
        assertEq(paymaster.feePrice(), 1);

        vm.prank(bob);
        paymaster.updateFeePrice(2);

        assertEq(paymaster.feePrice(), 2);
    }

    function test_cannotUpdateFeePriceIfNotOracle() public {
        vm.expectRevert_AccessControlUnauthorizedAccount(
            charlie,
            paymaster.PRICE_ORACLE_ROLE()
        );
        vm.prank(charlie);
        paymaster.updateFeePrice(2);
    }

    function test_doesNotSupportGeneralFlow() public {
        vm.expectRevert(BasePaymaster.PaymasterFlowNotSupported.selector);
        paymaster.mock_validateAndPayGeneralFlow(alice, bob, 1);
    }

    function test_refusesNonAllowedToken() public {
        vm.expectRevert(Erc20Paymaster.TokenNotAllowed.selector);
        paymaster.mock_validateAndPayApprovalBasedFlow(
            alice,
            bob,
            vm.addr(4),
            1,
            "",
            1
        );
    }

    function test_refusesPotentialOverflows() public {
        vm.prank(bob);
        paymaster.updateFeePrice(2);

        vm.expectRevert(
            abi.encodeWithSelector(
                Erc20Paymaster.FeeTooHigh.selector,
                2,
                type(uint256).max
            )
        );
        paymaster.mock_validateAndPayApprovalBasedFlow(
            alice,
            bob,
            address(token),
            1,
            "",
            type(uint256).max
        );
    }

    function test_refusesTooLowAllowances() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Erc20Paymaster.AllowanceNotEnough.selector,
                0,
                1
            )
        );
        paymaster.mock_validateAndPayApprovalBasedFlow(
            alice,
            bob,
            address(token),
            1,
            "",
            1
        );
    }

    function test_refusesFailedTransfer() public {
        vm.prank(alice);
        // we approve one unit of tokens, yet have no balance as such any transfer would fail
        token.approve(address(paymaster), 1);

        // MockERC20 reverts on subtraction underflow,
        // if the contract doesn't SafeERC20 will revert anyways
        vm.expectRevert();
        paymaster.mock_validateAndPayApprovalBasedFlow(
            alice,
            bob,
            address(token),
            1,
            "",
            1
        );
    }

    function test_approvalFlow() public {
        deal(address(token), alice, 1, true);
        vm.prank(alice);
        token.approve(address(paymaster), 1);

        paymaster.mock_validateAndPayApprovalBasedFlow(
            alice,
            bob,
            address(token),
            1,
            "",
            1
        );

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(paymaster)), 1);
    }

    function test_withdrawERC20() public {
        deal(address(token), address(paymaster), 1, true);

        vm.prank(alice);
        paymaster.withdrawTokens(alice, 1);

        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(paymaster)), 0);
    }

    function test_withdrawERC20FailsIfNotAdmin() public {
        vm.expectRevert_AccessControlUnauthorizedAccount(
            charlie,
            paymaster.WITHDRAWER_ROLE()
        );
        vm.prank(charlie);
        paymaster.withdrawTokens(alice, 1);
    }
}

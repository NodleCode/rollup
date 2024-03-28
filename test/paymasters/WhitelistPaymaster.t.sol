// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";
import {BasePaymaster} from "../../src/paymasters/BasePaymaster.sol";
import {WhitelistPaymaster} from "../../src/paymasters/WhitelistPaymaster.sol";

contract MockWhitelistPaymaster is WhitelistPaymaster {
    constructor(address withdrawer) WhitelistPaymaster(withdrawer) {}

    function mock_validateAndPayGeneralFlow(address from, address to, uint256 requiredETH) public view {
        _validateAndPayGeneralFlow(from, to, requiredETH);
    }

    function mock_validateAndPayApprovalBasedFlow(
        address from,
        address to,
        address token,
        uint256 amount,
        bytes memory data,
        uint256 requiredETH
    ) public pure {
        _validateAndPayApprovalBasedFlow(from, to, token, amount, data, requiredETH);
    }
}

contract WhitelistPaymasterTest is Test {
    using AccessControlUtils for Vm;

    MockWhitelistPaymaster private paymaster;

    address internal alice = vm.addr(1);
    address internal bob = vm.addr(2);
    address internal charlie = vm.addr(3);

    address[] internal whitelistTargets;

    function setUp() public {
        vm.prank(alice);
        paymaster = new MockWhitelistPaymaster(bob);

        whitelistTargets = new address[](1);
        whitelistTargets[0] = charlie;
    }

    function test_defaultACLs() public view {
        assert(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), alice));
        assert(paymaster.hasRole(paymaster.WHITELIST_ADMIN_ROLE(), alice));
        assert(paymaster.hasRole(paymaster.WITHDRAWER_ROLE(), bob));
    }

    function test_whitelistAdminUpdatesWhitelists() public {
        vm.startPrank(alice);

        assert(!paymaster.isWhitelistedUser(charlie));
        assert(!paymaster.isWhitelistedContract(charlie));

        paymaster.addWhitelistedUsers(whitelistTargets);
        paymaster.addWhitelistedContracts(whitelistTargets);

        assert(paymaster.isWhitelistedUser(charlie));
        assert(paymaster.isWhitelistedContract(charlie));

        paymaster.removeWhitelistedUsers(whitelistTargets);
        paymaster.removeWhitelistedContracts(whitelistTargets);

        assert(!paymaster.isWhitelistedUser(charlie));
        assert(!paymaster.isWhitelistedContract(charlie));

        vm.stopPrank();
    }

    function test_nonWhitelistAdminCannotUpdateWhitelists() public {
        vm.startPrank(bob);

        vm.expectRevert_AccessControlUnauthorizedAccount(bob, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.addWhitelistedUsers(whitelistTargets);

        vm.expectRevert_AccessControlUnauthorizedAccount(bob, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.addWhitelistedContracts(whitelistTargets);

        vm.expectRevert_AccessControlUnauthorizedAccount(bob, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.removeWhitelistedUsers(whitelistTargets);

        vm.expectRevert_AccessControlUnauthorizedAccount(bob, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.removeWhitelistedContracts(whitelistTargets);

        vm.stopPrank();
    }

    function test_doesNotSupportApprovalBasedFlow() public {
        vm.expectRevert(BasePaymaster.PaymasterFlowNotSupported.selector);
        paymaster.mock_validateAndPayApprovalBasedFlow(alice, bob, bob, 1, "0x", 0);
    }

    function test_allowsGeneralFlowOnlyIfWhitelistingPasses() public {
        vm.startPrank(alice);

        vm.expectRevert(WhitelistPaymaster.DestIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(charlie, charlie, 0);

        paymaster.addWhitelistedContracts(whitelistTargets);

        vm.expectRevert(WhitelistPaymaster.UserIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(charlie, charlie, 0);

        paymaster.addWhitelistedUsers(whitelistTargets);

        paymaster.mock_validateAndPayGeneralFlow(charlie, charlie, 0);

        vm.stopPrank();
    }
}

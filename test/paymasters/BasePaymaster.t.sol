// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BasePaymaster} from "../../src/paymasters/BasePaymaster.sol";

contract MockPaymaster is BasePaymaster {
    event MockPaymasterCalled();

    constructor(address admin, address withdrawer) BasePaymaster(admin, withdrawer) {}

    function _validateAndPayGeneralFlow(address, address, uint256) internal override {
        // this is a mock, do nothing
        emit MockPaymasterCalled();
    }

    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        override
    {
        // this is a mock, do nothing
        emit MockPaymasterCalled();
    }
}

contract BasePaymasterTest is Test {
    MockPaymaster private paymaster;

    address internal alice = vm.addr(1); // owner
    address internal bob = vm.addr(2); // withdrawer
    address internal charlie = vm.addr(3); // user

    function setUp() public {
        paymaster = new MockPaymaster(alice, bob);
        vm.deal(address(paymaster), 1 ether);
    }

    function test_defaultACLs() public view {
        assert(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), alice));
        assert(paymaster.hasRole(paymaster.WITHDRAWER_ROLE(), bob));
    }

    function test_withdrawExcessETH() public {
        vm.prank(bob);
        paymaster.withdraw(bob, 1 ether);

        assertEq(address(paymaster).balance, 0);
        assertEq(address(bob).balance, 1 ether);
    }

    // TODO: test for sample paymaster txs
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {L1Nodl} from "src/L1Nodl.sol";

contract L1NodlTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant MINTER = address(0xBEEF);

    function test_constructor_setsRoles() public {
        L1Nodl token = new L1Nodl(ADMIN, MINTER);

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), ADMIN), "admin role assigned");
        assertTrue(token.hasRole(keccak256("MINTER_ROLE"), MINTER), "minter role assigned");
    }

    function test_constructor_revert_adminZero() public {
        vm.expectRevert(abi.encodeWithSelector(L1Nodl.ZeroAddress.selector));
        new L1Nodl(address(0), MINTER);
    }

    function test_constructor_revert_minterZero() public {
        vm.expectRevert(abi.encodeWithSelector(L1Nodl.ZeroAddress.selector));
        new L1Nodl(ADMIN, address(0));
    }
}

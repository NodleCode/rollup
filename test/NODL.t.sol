// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {NODL} from "../src/NODL.sol";
import {ERC20Capped} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Capped.sol";

contract NODLTest is Test {
    NODL private nodl;

    address internal alice = vm.addr(1);
    address internal bob = vm.addr(2);

    function setUp() public {
        nodl = new NODL(alice, alice);
    }

    function test_defaultACLs() public view {
        assert(nodl.hasRole(nodl.DEFAULT_ADMIN_ROLE(), alice));
        assert(nodl.hasRole(nodl.MINTER_ROLE(), alice));
    }

    function test_shouldDeployWithNoSupply() public {
        assertEq(nodl.totalSupply(), 0);
    }

    function test_capIs21Billion() public {
        assertEq(nodl.cap(), 21_000_000_000 * 10 ** nodl.decimals());
    }

    function test_isMintable() public {
        assertEq(nodl.balanceOf(bob), 0);

        vm.prank(alice);
        nodl.mint(bob, 1);

        assertEq(nodl.balanceOf(bob), 1);
    }

    function test_isBurnable() public {
        vm.prank(alice);
        nodl.mint(bob, 1);

        assertEq(nodl.balanceOf(bob), 1);

        vm.prank(bob);
        nodl.burn(1);

        assertEq(nodl.balanceOf(bob), 0);
    }

    function test_cannotMintAboveSupplyCap() public {
        vm.startPrank(alice);

        nodl.mint(bob, nodl.cap());

        assertEq(nodl.balanceOf(bob), nodl.cap());

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Capped.ERC20ExceededCap.selector,
                nodl.cap() + 1,
                nodl.cap()
            )
        );
        nodl.mint(bob, 1);

        vm.stopPrank();
    }
}

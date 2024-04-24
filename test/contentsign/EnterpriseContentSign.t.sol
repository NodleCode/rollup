// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BaseContentSign} from "../../src/contentsign/BaseContentSign.sol";
import {EnterpriseContentSign} from "../../src/contentsign/EnterpriseContentSign.sol";

contract EnterpriseContentSignTest is Test {
    EnterpriseContentSign private nft;

    address internal alice = vm.addr(1);
    address internal bob = vm.addr(2);

    function setUp() public {
        vm.startPrank(alice);
        nft = new EnterpriseContentSign("Name", "Symbol");
        nft.grantRole(nft.WHITELISTED_ROLE(), bob);
        vm.stopPrank();
    }

    function sets_adminRole() public {
        assertEq(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), alice), true);
    }

    function test_whitelistedUserCanMint() public {
        assertEq(nft.hasRole(nft.WHITELISTED_ROLE(), bob), true);

        vm.prank(bob);
        nft.safeMint(bob, "uri");

        assertEq(nft.ownerOf(0), bob);
        assertEq(nft.tokenURI(0), "uri");
    }

    function test_nonWhitelistedCannotMint() public {
        address charlie = vm.addr(3);

        vm.expectRevert(abi.encodeWithSelector(BaseContentSign.UserIsNotWhitelisted.selector, charlie));
        vm.prank(charlie);
        nft.safeMint(charlie, "uri");
    }
}

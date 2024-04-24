// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BaseContentSign} from "../../src/contentsign/BaseContentSign.sol";
import {ClickContentSign} from "../../src/contentsign/ClickContentSign.sol";
import {WhitelistPaymaster} from "../../src/paymasters/WhitelistPaymaster.sol";

contract ClickContentSignTest is Test {
    WhitelistPaymaster private paymaster;
    ClickContentSign private nft;

    address internal alice = vm.addr(1);
    address internal bob = vm.addr(2);

    function setUp() public {
        vm.prank(alice);
        paymaster = new WhitelistPaymaster(alice);
        nft = new ClickContentSign("Name", "Symbol", paymaster);

        address[] memory contracts = new address[](1);
        contracts[0] = address(nft);

        address[] memory users = new address[](1);
        users[0] = bob;

        vm.startPrank(alice);
        paymaster.addWhitelistedContracts(contracts);
        paymaster.addWhitelistedUsers(users);
        vm.stopPrank();
    }

    function test_whitelistedUserCanMint() public {
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

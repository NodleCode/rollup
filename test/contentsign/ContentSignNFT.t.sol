// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ContentSignNFT} from "../../src/contentsign/ContentSignNFT.sol";
import {WhitelistPaymaster} from "../../src/paymasters/WhitelistPaymaster.sol";

contract ContentSignNFTTest is Test {
    WhitelistPaymaster private paymaster;
    ContentSignNFT private nft;

    address internal alice = vm.addr(1);
    address internal bob = vm.addr(2);

    function setUp() public {
        address[] memory admins = new address[](0);
        paymaster = new WhitelistPaymaster(alice, alice, alice, admins);
        nft = new ContentSignNFT("Name", "Symbol", paymaster);

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

        vm.expectRevert(ContentSignNFT.UserIsNotWhitelisted.selector);
        vm.prank(charlie);
        nft.safeMint(charlie, "uri");
    }
}

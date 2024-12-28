// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BaseContentSign} from "../../src/contentsign/BaseContentSign.sol";

contract MockContentSign is BaseContentSign {
    bool public whitelisted = false;

    constructor() BaseContentSign("Mock", "MOCK") {}

    function setWhitelisted(bool _whitelisted) public {
        whitelisted = _whitelisted;
    }

    function _userIsWhitelisted(address) internal view override returns (bool) {
        return whitelisted;
    }
}

contract BaseContentSignTest is Test {
    MockContentSign private contentSign;

    address internal alice = vm.addr(1);

    function setUp() public {
        contentSign = new MockContentSign();
    }

    function test_setsMetadata() public view {
        assertEq(contentSign.name(), "Mock");
        assertEq(contentSign.symbol(), "MOCK");
    }

    function test_whitelistedCanMint() public {
        contentSign.setWhitelisted(true);
        contentSign.safeMint(alice, "uri");

        assertEq(contentSign.ownerOf(0), alice);
        assertEq(contentSign.tokenURI(0), "uri");
    }

    function test_nonWhitelistedCannotMint() public {
        contentSign.setWhitelisted(false);

        vm.expectRevert(abi.encodeWithSelector(BaseContentSign.UserIsNotWhitelisted.selector, alice));
        vm.prank(alice);
        contentSign.safeMint(alice, "uri");
    }
}

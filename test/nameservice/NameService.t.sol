// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {NameService} from "../../src/nameservice/NameService.sol";

contract NameServiceTest is Test {
    NameService public nameService;
    address public admin;
    address public registrar;
    address public user;
    string public constant TEST_NAME = "test";
    string public constant AVATAR_KEY = "avatar";
    string public constant AVATAR_VALUE = "https://example.com/avatar.png";

    function setUp() public {
        admin = makeAddr("admin");
        registrar = makeAddr("registrar");
        user = makeAddr("user");
        nameService = new NameService(admin, registrar, "Name", "Symbol");
    }

    function test_RegisterAndSetTextRecord() public {
        // Register a name
        vm.prank(registrar);
        nameService.register(user, TEST_NAME);

        // Set text record
        vm.prank(user);
        nameService.setTextRecord(TEST_NAME, AVATAR_KEY, AVATAR_VALUE);

        // Verify text record
        string memory value = nameService.getTextRecord(TEST_NAME, AVATAR_KEY);
        assertEq(value, AVATAR_VALUE);
    }

    function test_OnlyOwnerCanSetTextRecord() public {
        // Register a name
        vm.prank(registrar);
        nameService.register(user, TEST_NAME);

        // Try to set text record as non-owner
        vm.prank(admin);
        vm.expectRevert(NameService.NotAuthorized.selector);
        nameService.setTextRecord(TEST_NAME, AVATAR_KEY, AVATAR_VALUE);
    }

    function test_CannotSetTextRecordForExpiredName() public {
        // Register a name
        vm.prank(registrar);
        nameService.register(user, TEST_NAME);

        // Fast forward time to after expiration
        vm.warp(block.timestamp + 366 days);

        // Try to set text record
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(NameService.NameExpired.selector, user, block.timestamp - 1 days));
        nameService.setTextRecord(TEST_NAME, AVATAR_KEY, AVATAR_VALUE);
    }

    function test_GetTextRecordForNonExistentName() public {
        // Try to get text record for non-existent name
        vm.expectRevert(abi.encodeWithSelector(NameService.NameExpired.selector, address(0), 0));
        nameService.getTextRecord("nonexistent", AVATAR_KEY);
    }

    function test_GetTextRecordForExpiredName() public {
        // Register a name
        vm.prank(registrar);
        nameService.register(user, TEST_NAME);

        // Fast forward time to after expiration
        vm.warp(block.timestamp + 366 days);

        // Try to get text record
        vm.expectRevert(abi.encodeWithSelector(NameService.NameExpired.selector, user, block.timestamp - 1 days));
        nameService.getTextRecord(TEST_NAME, AVATAR_KEY);
    }
} 
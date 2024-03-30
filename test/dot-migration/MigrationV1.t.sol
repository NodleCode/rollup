// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MigrationV1} from "../../src/dot-migration/MigrationV1.sol";
import {NODL} from "../../src/NODL.sol";

contract MigrationV1Test is Test {
    MigrationV1 migration;
    NODL nodl;

    address[] oracles = [vm.addr(1), vm.addr(2), vm.addr(3)];
    address user = vm.addr(4);

    function setUp() public {
        nodl = new NODL();
        migration = new MigrationV1(oracles, nodl);

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_oraclesAreRegisteredProperly() public view {
        for (uint256 i = 0; i < oracles.length; i++) {
            assert(migration.oracles(oracles[i]));
        }
    }

    function test_configuredProperToken() public {
        assertEq(address(migration.nodl()), address(nodl));
    }

    function test_nonOracleMayNotBridgeTokens() public {
        vm.expectRevert(abi.encodeWithSelector(MigrationV1.NotAnOracle.selector, user));
        vm.prank(user);
        migration.bridge(vm.addr(42), 100);
    }

    function test_revertsIfBridgedTotalWouldBeReduced() public {
        vm.startPrank(oracles[0]);

        migration.bridge(vm.addr(2), 10);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.MayOnlyIncrease.selector));
        migration.bridge(vm.addr(2), 1);

        vm.stopPrank();
    }

    function test_revertsIfNoNewTokensToMint() public {
        vm.startPrank(oracles[0]);

        migration.bridge(vm.addr(2), 100);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.MayOnlyIncrease.selector));
        migration.bridge(vm.addr(2), 100);

        vm.stopPrank();
    }

    function test_increaseAmountWorksIfCallerIsOracle() public {
        vm.startPrank(oracles[0]);

        vm.expectEmit();
        emit MigrationV1.Bridged(vm.addr(2), 100);
        migration.bridge(vm.addr(2), 100);

        uint256 totalBridged = migration.bridged(vm.addr(2));
        assertEq(totalBridged, 100);

        vm.expectEmit();
        emit MigrationV1.Bridged(vm.addr(2), 100);
        migration.bridge(vm.addr(2), 200);

        totalBridged = migration.bridged(vm.addr(2));
        assertEq(totalBridged, 200);

        vm.stopPrank();
    }
}

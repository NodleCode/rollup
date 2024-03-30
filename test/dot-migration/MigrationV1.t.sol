// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MigrationV1} from "../../src/dot-migration/MigrationV1.sol";
import {NODL} from "../../src/NODL.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract MigrationV1Test is Test {
    MigrationV1 migration;
    NODL nodl;

    address oracle = vm.addr(1);
    address user = vm.addr(2);

    function setUp() public {
        nodl = new NODL();
        migration = new MigrationV1(oracle, nodl);

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_setsOracleAsOwner() public {
        assertEq(migration.owner(), oracle);
    }

    function test_configuredProperToken() public {
        assertEq(address(migration.nodl()), address(nodl));
    }

    function test_nonOracleMayNotBridgeTokens() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        migration.bridge(vm.addr(42), 100);
    }

    function test_revertsInCaseOfUnderflowOrIfTriesToReduceTotalBurnt() public {
        vm.startPrank(oracle);

        migration.bridge(vm.addr(2), 10);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.Underflowed.selector));
        migration.bridge(vm.addr(2), 1);

        vm.stopPrank();
    }

    function test_revertsIfNoNewTokensToMint() public {
        vm.startPrank(oracle);

        migration.bridge(vm.addr(2), 100);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.ZeroValueTransfer.selector));
        migration.bridge(vm.addr(2), 100);

        vm.stopPrank();
    }

    function test_increaseAmountWorksIfCallerIsOracle() public {
        vm.startPrank(oracle);

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

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MigrationV1} from "../../src/dot-migration/MigrationV1.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract MigrationV1Test is Test {
    MigrationV1 migration;

    address oracle = vm.addr(1);
    address user = vm.addr(2);

    function setUp() public {
        migration = new MigrationV1(oracle);
    }

    function test_setsOracleAsOwner() public {
        assertEq(migration.owner(), oracle);
    }

    function test_nonOracleMayNotUpdateClaims() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        migration.increaseAmount(vm.addr(42), 100);
    }

    function test_errorsInCaseOfOverflows() public {
        vm.startPrank(oracle);

        migration.increaseAmount(vm.addr(2), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.Overflowed.selector));
        migration.increaseAmount(vm.addr(2), type(uint256).max);

        vm.stopPrank();
    }

    function test_increaseAmountWorksIfCallerIsOracle() public {
        vm.startPrank(oracle);

        vm.expectEmit();
        emit MigrationV1.ClaimableAmountIncreased(vm.addr(2), 100);
        migration.increaseAmount(vm.addr(2), 100);

        (uint256 amount, uint256 claimed) = migration.claims(vm.addr(2));
        assertEq(amount, 100);
        assertEq(claimed, 0);

        vm.expectEmit();
        emit MigrationV1.ClaimableAmountIncreased(vm.addr(2), 200);
        migration.increaseAmount(vm.addr(2), 100);

        (amount, claimed) = migration.claims(vm.addr(2));
        assertEq(amount, 200);
        assertEq(claimed, 0);

        vm.stopPrank();
    }
}

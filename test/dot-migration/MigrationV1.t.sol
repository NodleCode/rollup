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
        migration = new MigrationV1(oracles, nodl, 2);

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_oraclesAreRegisteredProperly() public {
        for (uint256 i = 0; i < oracles.length; i++) {
            assertEq(migration.isOracle(oracles[i]), true);
        }
        assertEq(migration.threshold(), 2);
    }

    function test_configuredProperToken() public {
        assertEq(address(migration.nodl()), address(nodl));
    }

    function test_nonOracleMayNotBridgeTokens() public {
        vm.expectRevert(abi.encodeWithSelector(MigrationV1.NotAnOracle.selector, user));
        vm.prank(user);
        migration.bridge(0x0, user, 100);
    }

    function test_mayNotVoteTwice() public {
        vm.startPrank(oracles[0]);

        migration.bridge(0x0, user, 100);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.AlreadyVoted.selector, 0x0, oracles[0]));
        migration.bridge(0x0, user, 100);

        vm.stopPrank();
    }

    function test_mayNotVoteOnceExecuted() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 100);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.AlreadyExecuted.selector, 0x0));
        vm.prank(oracles[2]);
        migration.bridge(0x0, user, 100);
    }

    function test_mayNotVoteIfParametersChanged() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.ParametersChanged.selector, 0x0));
        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 200);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.ParametersChanged.selector, 0x0));
        vm.prank(oracles[1]);
        migration.bridge(0x0, oracles[1], 100);
    }

    function test_recordsVotesAndMintTokens() public {
        vm.expectEmit();
        emit MigrationV1.VoteStarted(0x0, oracles[0], user, 100);
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.expectEmit();
        emit MigrationV1.Voted(0x0, oracles[1]);
        emit MigrationV1.Bridged(0x0, user, 100);
        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 100);

        assertEq(nodl.balanceOf(user), 100);
    }
}

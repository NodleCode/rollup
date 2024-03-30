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

    function test_oraclesAreRegisteredProperly() public {
        for (uint256 i = 0; i < oracles.length; i++) {
            assertEq(migration.oracles(i), oracles[i]);
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
        migration.bridge(user, 100);
    }

    function test_revertsIfBridgedTotalWouldBeReduced() public {
        vm.startPrank(oracles[0]);

        migration.bridge(user, 10);

        vm.expectRevert(MigrationV1.MayOnlyIncrease.selector);
        migration.bridge(user, 1);

        vm.stopPrank();
    }

    function test_revertsIfNoNewTokensToMint() public {
        vm.prank(oracles[0]);
        migration.bridge(user, 100);
        vm.prank(oracles[1]);
        migration.bridge(user, 100);

        assertEq(migration.bridged(user), 100);

        vm.expectRevert(MigrationV1.MayOnlyIncrease.selector);
        vm.prank(oracles[0]);
        migration.bridge(user, 100);
    }

    function test_mayNotSubmitLowerVotes() public {
        vm.startPrank(oracles[0]);

        migration.bridge(user, 100);

        vm.expectRevert(MigrationV1.MayOnlyIncrease.selector);
        migration.bridge(user, 99);

        vm.stopPrank();
    }

    function test_mayNotVoteTwice() public {
        vm.startPrank(oracles[0]);

        migration.bridge(user, 100);

        vm.expectRevert(abi.encodeWithSelector(MigrationV1.AlreadyVoted.selector, oracles[0], user));
        migration.bridge(user, 100);

        vm.stopPrank();
    }

    function test_increasingCurrentVotesResetVotes() public {
        vm.startPrank(oracles[0]);

        vm.expectEmit();
        emit MigrationV1.VoteStarted(oracles[0], user, 100);
        migration.bridge(user, 100);
        assertEq(migration.didVote(user, oracles[0]), true);

        vm.startPrank(oracles[1]);

        vm.expectEmit();
        emit MigrationV1.VoteStarted(oracles[1], user, 200);
        migration.bridge(user, 200);
        (uint256 newAmount, uint256 totalVotes) = migration.currentVotes(user);
        assertEq(newAmount, 200);
        assertEq(totalVotes, 1); // not 2
        assertEq(migration.didVote(user, oracles[0]), false); // not true
        assertEq(migration.didVote(user, oracles[1]), true);

        vm.stopPrank();
    }

    function test_recordsVotesAndBridgeIfConsensusIsReached() public {
        // 1 - Register vote but do not bridge yet

        vm.prank(oracles[0]);

        vm.expectEmit();
        emit MigrationV1.VoteStarted(oracles[0], user, 100);
        migration.bridge(user, 100);

        assertEq(migration.bridged(user), 0);
        assertEq(migration.didVote(user, oracles[0]), true);
        (uint256 newAmount, uint256 totalVotes) = migration.currentVotes(user);
        assertEq(newAmount, 100);
        assertEq(totalVotes, 1);

        // 2 - Register vote and bridge since threshold was reached

        vm.prank(oracles[1]);

        vm.expectEmit();
        emit MigrationV1.Voted(oracles[1], user);
        emit MigrationV1.Bridged(user, 100);
        migration.bridge(user, 100);

        assertEq(migration.bridged(user), 100);
        assertEq(nodl.balanceOf(user), 100);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {NODLMigration} from "../../src/bridge/NODLMigration.sol";
import {BridgeBase} from "../../src/bridge/BridgeBase.sol";
import {NODL} from "../../src/NODL.sol";

contract NODLMigrationTest is Test {
    NODLMigration migration;
    NODL nodl;

    uint256 delay = 100;
    address[] oracles = [vm.addr(1), vm.addr(2), vm.addr(3)];
    address user = vm.addr(4);

    function setUp() public {
        nodl = new NODL();
        migration = new NODLMigration(oracles, nodl, 2, delay);

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_oraclesAreRegisteredProperly() public {
        for (uint256 i = 0; i < oracles.length; i++) {
            assertEq(migration.isOracle(oracles[i]), true);
        }
        assertEq(migration.threshold(), 2);
        assertEq(migration.delay(), delay);
    }

    function test_configuredProperToken() public {
        assertEq(address(migration.nodl()), address(nodl));
    }

    function test_nonOracleMayNotBridgeTokens() public {
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.NotAnOracle.selector, user));
        vm.prank(user);
        migration.bridge(0x0, user, 100);
    }

    function test_mayNotVoteTwice() public {
        vm.startPrank(oracles[0]);

        migration.bridge(0x0, user, 100);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AlreadyVoted.selector, 0x0, oracles[0]));
        migration.bridge(0x0, user, 100);

        vm.stopPrank();
    }

    function test_mayNotVoteOnceExecuted() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 100);

        vm.roll(block.number + delay + 1);
        migration.withdraw(0x0);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AlreadyExecuted.selector, 0x0));
        vm.prank(oracles[2]);
        migration.bridge(0x0, user, 100);
    }

    function test_mayNotVoteIfParametersChanged() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, 0x0));
        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 200);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, 0x0));
        vm.prank(oracles[1]);
        migration.bridge(0x0, oracles[1], 100);
    }

    function test_recordsVotes() public {
        vm.expectEmit();
        emit BridgeBase.VoteStarted(0x0, oracles[0], user, 100);
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        (address target, uint256 amount, uint256 lastVote, uint256 totalVotes, bool executed) = migration.proposals(0x0);
        assertEq(target, user);
        assertEq(amount, 100);
        assertEq(lastVote, block.number);
        assertEq(totalVotes, 1);
        assertEq(executed, false);

        vm.expectEmit();
        emit BridgeBase.Voted(0x0, oracles[1]);
        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 100);

        (target, amount, lastVote, totalVotes, executed) = migration.proposals(0x0);
        assertEq(target, user);
        assertEq(amount, 100);
        assertEq(lastVote, block.number);
        assertEq(totalVotes, 2);
        assertEq(executed, false);
    }

    function test_mayNotWithdrawIfNotEnoughVotes() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.NotEnoughVotes.selector, 0x0));
        migration.withdraw(0x0);
    }

    function test_mayNotWithdrawBeforeDelay() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 100);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.NotYetWithdrawable.selector, 0x0));
        migration.withdraw(0x0);
    }

    function test_mayNotWithdrawTwice() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 100);

        vm.roll(block.number + delay + 1);

        migration.withdraw(0x0);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AlreadyExecuted.selector, 0x0));
        migration.withdraw(0x0);
    }

    function test_mayWithdrawAfterDelay() public {
        vm.prank(oracles[0]);
        migration.bridge(0x0, user, 100);

        vm.prank(oracles[1]);
        migration.bridge(0x0, user, 100);

        vm.roll(block.number + delay + 1);

        vm.expectEmit();
        emit NODLMigration.Withdrawn(0x0, user, 100);
        vm.prank(user); // anybody can call withdraw
        migration.withdraw(0x0);

        (,,,, bool executed) = migration.proposals(0x0);
        assertEq(executed, true);

        assertEq(nodl.balanceOf(user), 100);
    }
}

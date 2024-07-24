// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {GrantsMigration} from "../../src/bridge/GrantsMigration.sol";
import {BridgeBase} from "../../src/bridge/BridgeBase.sol";
import {Grants} from "../../src/Grants.sol";
import {NODL} from "../../src/NODL.sol";

contract GrantsMigrationTest is Test {
    GrantsMigration migration;
    Grants grants;
    NODL nodl;

    uint256 delay = 100;
    address[] oracles = [vm.addr(1), vm.addr(2), vm.addr(3)];
    address user = vm.addr(4);
    Grants.VestingSchedule[] schedules;
    uint256 amount = 0;

    function setUp() public {
        nodl = new NODL();
        grants = new Grants(address(nodl));
        migration = new GrantsMigration(oracles, nodl, grants, 2, delay);

        schedules.push(
            Grants.VestingSchedule({
                start: block.timestamp + 1 days,
                period: 1 days,
                periodCount: 5,
                perPeriodAmount: 20,
                cancelAuthority: user
            })
        );
        schedules.push(
            Grants.VestingSchedule({
                start: block.timestamp + 2 days,
                period: 3 days,
                periodCount: 7,
                perPeriodAmount: 19,
                cancelAuthority: oracles[0]
            })
        );
        schedules.push(
            Grants.VestingSchedule({
                start: block.timestamp + 7 days,
                period: 11 days,
                periodCount: 13,
                perPeriodAmount: 37,
                cancelAuthority: address(0)
            })
        );

        for (uint256 i = 0; i < schedules.length; i++) {
            amount += schedules[i].perPeriodAmount * schedules[i].periodCount;
        }

        nodl.grantRole(nodl.MINTER_ROLE(), address(migration));
    }

    function test_oraclesAreRegisteredProperly() public {
        for (uint256 i = 0; i < oracles.length; i++) {
            assertEq(migration.isOracle(oracles[i]), true);
        }
        assertEq(migration.threshold(), 2);
        assertEq(migration.delay(), delay);
    }

    function test_proposalCreationAndVoting() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx1"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);

        (uint256 lastVote, uint8 totalVotes, bool executed) = migration.proposalStatus(paraTxHash);
        assertEq(totalVotes, 2);
        assertEq(executed, false);
        assertEq(lastVote, block.timestamp);
    }

    function test_executionOfProposals() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx2"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.roll(block.number + delay + 1);

        vm.prank(oracles[0]);
        migration.grant(paraTxHash);

        (,, bool executed) = migration.proposalStatus(paraTxHash);
        assertEq(executed, true);
    }

    function test_proposalParameterChangesPreventVoting() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx3"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount + 1, schedules);
    }

    function test_rejectionOfDuplicateVotes() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx4"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, 100, schedules);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AlreadyVoted.selector, paraTxHash, oracles[0]));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, 100, schedules);
    }

    // Additional tests for execution without sufficient votes, attempting to execute too early, etc.
}

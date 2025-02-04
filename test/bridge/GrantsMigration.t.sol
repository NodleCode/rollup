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
        nodl = new NODL(address(this));
        grants = new Grants(address(nodl), 19, 100);
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

    function test_oraclesAreRegisteredProperly() public view {
        for (uint256 i = 0; i < oracles.length; i++) {
            assertEq(migration.isOracle(oracles[i]), true);
        }
        assertEq(migration.threshold(), 2);
        assertEq(migration.delay(), delay);
    }

    function test_proposalCreationAndVoting() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx1"));
        vm.prank(oracles[0]);
        vm.expectEmit();
        emit BridgeBase.VoteStarted(paraTxHash, oracles[0], user, amount);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.prank(oracles[1]);
        vm.expectEmit();
        emit BridgeBase.Voted(paraTxHash, oracles[1]);
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
        vm.expectEmit();
        emit GrantsMigration.Granted(paraTxHash, user, amount, schedules.length);
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

        // Change the target address
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, oracles[1], amount, schedules);

        schedules[0].start += 1 days;
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);
        schedules[0].start -= 1 days;

        schedules[1].period += 1 days;
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);
        schedules[1].period -= 1 days;

        schedules[2].periodCount += 1;
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);
        schedules[2].periodCount -= 1;

        schedules[0].perPeriodAmount += 1;
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);
        schedules[0].perPeriodAmount -= 1;

        schedules[1].cancelAuthority = oracles[2];
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);
        schedules[1].cancelAuthority = oracles[0];

        Grants.VestingSchedule[] memory newSchedules = new Grants.VestingSchedule[](schedules.length - 1);
        newSchedules[0] = schedules[0];
        newSchedules[1] = schedules[1];
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.ParametersChanged.selector, paraTxHash));
        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, newSchedules);

        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);
    }

    function test_rejectionOfDuplicateVotes() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx4"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AlreadyVoted.selector, paraTxHash, oracles[0]));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);
    }

    function test_rejectionOfVoteOnAlreadyExecuted() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx5"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.roll(block.number + delay + 1);
        migration.grant(paraTxHash);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.AlreadyExecuted.selector, paraTxHash));
        vm.prank(oracles[2]);
        migration.bridge(paraTxHash, user, amount, schedules);
    }

    function test_executionFailsIfInsufficientVotes() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx6"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.roll(block.number + delay + 1);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.NotEnoughVotes.selector, paraTxHash));
        migration.grant(paraTxHash);
    }

    function test_executionFailsIfTooEarly() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx7"));
        vm.prank(oracles[0]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.prank(oracles[1]);
        migration.bridge(paraTxHash, user, amount, schedules);

        vm.expectRevert(abi.encodeWithSelector(BridgeBase.NotYetWithdrawable.selector, paraTxHash));
        migration.grant(paraTxHash);
    }

    function test_registeringTooManyOraclesFails() public {
        uint8 max_oracles = migration.MAX_ORACLES();
        address[] memory manyOracles = new address[](max_oracles + 1);
        for (uint256 i = 0; i < manyOracles.length; i++) {
            manyOracles[i] = vm.addr(i + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(BridgeBase.MaxOraclesExceeded.selector));
        new GrantsMigration(manyOracles, nodl, grants, uint8(manyOracles.length / 2 + 1), delay);
    }

    function test_createProposalFailsWithEmptySchedules() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx8"));
        Grants.VestingSchedule[] memory emptySchedules;
        vm.prank(oracles[0]);
        vm.expectRevert(GrantsMigration.EmptySchedules.selector);
        migration.bridge(paraTxHash, user, amount, emptySchedules);
    }

    function test_createProposalFailIfTooManySchedules() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx9"));
        Grants.VestingSchedule[] memory manySchedules = new Grants.VestingSchedule[](migration.MAX_SCHEDULES() + 1);
        for (uint256 i = 0; i < manySchedules.length; i++) {
            manySchedules[i] = schedules[0];
        }
        vm.prank(oracles[0]);
        vm.expectRevert(GrantsMigration.TooManySchedules.selector);
        migration.bridge(paraTxHash, user, amount, manySchedules);
    }

    function test_createProposalFailsIfAmountMismatch() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx10"));
        vm.prank(oracles[0]);
        vm.expectRevert(GrantsMigration.AmountMismatch.selector);
        migration.bridge(paraTxHash, user, amount + 1, schedules);
    }

    function test_createProposalFailsIfVestingScheduleInvalid() public {
        bytes32 paraTxHash = keccak256(abi.encodePacked("tx11"));
        Grants.VestingSchedule[] memory invalidSchedules = new Grants.VestingSchedule[](1);
        invalidSchedules[0] = Grants.VestingSchedule({
            start: block.timestamp + 1 days,
            period: 1 days,
            periodCount: 5,
            perPeriodAmount: 0,
            cancelAuthority: user
        });
        schedules[0].perPeriodAmount = 0;
        vm.prank(oracles[0]);
        vm.expectRevert(abi.encodeWithSelector(Grants.LowVestingAmount.selector));
        migration.bridge(paraTxHash, user, amount, invalidSchedules);
    }
}

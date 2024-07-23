// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";

import {NODLMigration} from "../src/bridge/NODLMigration.sol";
import {BridgeBase} from "../src/bridge/BridgeBase.sol";

contract CheckBridge is Script {
    NODLMigration internal bridge;
    bytes32 internal proposalId;

    function setUp() public {
        bridge = NODLMigration(vm.envAddress("N_BRIDGE"));
        proposalId = vm.envBytes32("N_PROPOSAL_ID");
    }

    function run() public view {
        (address target, uint256 amount, BridgeBase.ProposalStatus memory status) = bridge.proposals(proposalId);

        console.log("Proposal targets %s with %d NODL", address(target), amount);
        console.log("Proposal has %d votes", status.totalVotes);

        if (status.executed) {
            console.log("Proposal has already been executed");
        } else {
            console.log("Proposal has not been executed");

            if (status.totalVotes >= bridge.threshold()) {
                uint256 blocksPassed = block.number - status.lastVote;
                if (block.number - status.lastVote >= bridge.delay()) {
                    console.log("Proposal has enough votes to execute and should be executed soon");
                } else {
                    console.log("Proposal has enough votes but needs to wait %d blocks", bridge.delay() - blocksPassed);
                }
            } else {
                console.log("Proposal does not have enough votes to execute");
            }
        }
    }
}

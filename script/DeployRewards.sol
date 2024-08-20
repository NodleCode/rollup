// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";

import {NODL} from "../src/NODL.sol";
import {Rewards} from "../src/Rewards.sol";

contract DeployRewards is Script {
    address internal nodlAddress;
    address internal oracleAddress;
    uint256 internal rewardQuotaPerPeriod;
    uint256 internal rewardPeriod;
    uint8 internal batchSubmitterIncentive; // in percentage of total rewards in a batch. 1 = 1%

    function setUp() public {
        nodlAddress = vm.envOr("N_TOKEN_ADDR", address(0));
        oracleAddress = vm.envAddress("N_REWARDS_ORACLE_ADDR");
        rewardQuotaPerPeriod = vm.envUint("N_REWARDS_QUOTA");
        rewardPeriod = vm.envUint("N_REWARDS_PERIOD");
        batchSubmitterIncentive = uint8(vm.envUint("N_REWARDS_SUBMITTER_INCENTIVE"));
    }

    function run() public {
        vm.startBroadcast();
        if (nodlAddress == address(0)) {
            NODL token = new NODL();
            nodlAddress = address(token);
            console.log("Deployed NODL at %s", nodlAddress);
        }

        NODL nodl = NODL(nodlAddress);
        Rewards rewards = new Rewards(nodl, rewardQuotaPerPeriod, rewardPeriod, oracleAddress, batchSubmitterIncentive);
        address rewardsAddress = address(rewards);
        nodl.grantRole(nodl.MINTER_ROLE(), rewardsAddress);

        vm.stopBroadcast();

        console.log("Deployed Rewards at %s", rewardsAddress);
    }
}

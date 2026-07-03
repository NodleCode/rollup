// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {Rewards} from "../src/Rewards.sol";

contract RewardsSig is Script {
    uint256 internal sk;
    address internal tgtAddr;
    uint256 internal tgtAmount;
    address internal rewardsAddr;

    function setUp() public {
        sk = vm.envUint("N_REWARDS_SIGNER");
        tgtAddr = vm.envAddress("N_REWARDS_TGT_ADDR");
        tgtAmount = vm.envUint("N_REWARDS_TGT_AMOUNT");
        rewardsAddr = vm.envAddress("N_REWARDS_ADDR");
    }

    function run() public {
        Rewards rewards = Rewards(rewardsAddr);

        uint256 tgtSequence = rewards.sequences(tgtAddr);
        console.log("=== Target sequence ===");
        console.logUint(tgtSequence);

        Rewards.Reward memory reward = Rewards.Reward({recipient: tgtAddr, amount: tgtAmount, sequence: tgtSequence});

        bytes32 digest = rewards.digestReward(reward);

        console.log("=== Rewards digest ===");
        console.logBytes32(digest);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        console.log("=== Signature ===");
        console.logBytes(sig);

        vm.startBroadcast();
        rewards.mintReward(reward, sig);
    }
}

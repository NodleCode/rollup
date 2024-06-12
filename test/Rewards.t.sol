// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/NODL.sol";
import "../src/Rewards.sol";
import "openzeppelin-contracts/contracts/access/IAccessControl.sol";

contract RewardsTest is Test {
    NODL nodlToken;
    Rewards rewards;
    address recipient;
    uint256 oraclePrivateKey;

    function setUp() public {
        recipient = address(1);
        oraclePrivateKey = 0xBEEF;
        address oracle = vm.addr(oraclePrivateKey);

        nodlToken = new NODL();
        rewards = new Rewards(address(nodlToken), 1000, 1 days, oracle);
        // Grant MINTER_ROLE to the Rewards contract
        nodlToken.grantRole(nodlToken.MINTER_ROLE(), address(rewards));
    }

    function testSetQuota() public {
        // Check initial quota
        assertEq(rewards.rewardQuota(), 1000);

        // Try to set the quota without the role
        vm.expectRevert();
        rewards.setRewardQuota(2000);

        // Assign QUOTA_SETTER_ROLE to the test contract
        rewards.grantRole(rewards.QUOTA_SETTER_ROLE(), address(this));

        // Set the new quota
        rewards.setRewardQuota(2000);

        // Check new quota
        assertEq(rewards.rewardQuota(), 2000);
    }

    function testMintReward() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes32 digest = rewards.digestReward(reward);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Mint reward
        rewards.mintReward(reward, signature);

        // Check balances and counters
        assertEq(nodlToken.balanceOf(recipient), 100);
        assertEq(rewards.rewardsClaimed(), 100);
        assertEq(rewards.rewardCounters(recipient), 1);
    }

    function testMintRewardQuotaExceeded() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 1100, 0);
        bytes32 digest = rewards.digestReward(reward);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Expect the quota to be exceeded
        vm.expectRevert(Rewards.RewardQuotaExceeded.selector);
        rewards.mintReward(reward, signature);
    }

    function testMintRewardUnauthorizedOracle() public {
        // Prepare the reward and signature with an unauthorized oracle
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes32 digest = rewards.digestReward(reward);
        uint256 unauthorizedOraclePrivateKey = 0xDEAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(unauthorizedOraclePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Expect unauthorized oracle error
        vm.expectRevert(Rewards.UnauthorizedOracle.selector);
        rewards.mintReward(reward, signature);
    }

    function testMintRewardInvalidCounter() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 1); // Invalid counter
        bytes32 digest = rewards.digestReward(reward);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Expect invalid recipient counter error
        vm.expectRevert(Rewards.InvalidRecipientCounter.selector);
        rewards.mintReward(reward, signature);
    }
}

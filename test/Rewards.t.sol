// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/NODL.sol";
import "../src/Rewards.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import "./__helpers__/AccessControlUtils.sol";

contract RewardsTest is Test {
    using AccessControlUtils for Vm;

    NODL nodlToken;
    Rewards rewards;
    address recipient;
    uint256 oraclePrivateKey;

    uint256 constant RENEWAL_PERIOD = 1 days;

    function setUp() public {
        recipient = address(1);
        oraclePrivateKey = 0xBEEF;
        address oracle = vm.addr(oraclePrivateKey);

        nodlToken = new NODL();
        rewards = new Rewards(address(nodlToken), 1000, RENEWAL_PERIOD, oracle);
        // Grant MINTER_ROLE to the Rewards contract
        nodlToken.grantRole(nodlToken.MINTER_ROLE(), address(rewards));
    }

    function testSetQuota() public {
        // Check initial quota
        assertEq(rewards.rewardQuota(), 1000);

        // Assign QUOTA_SETTER_ROLE to the test contract
        rewards.grantRole(rewards.QUOTA_SETTER_ROLE(), address(this));

        // Set the new quota
        rewards.setRewardQuota(2000);

        // Check new quota
        assertEq(rewards.rewardQuota(), 2000);
    }

    function testSetQuotaUnauthorized() public {
        vm.expectRevert_AccessControlUnauthorizedAccount(address(this), rewards.QUOTA_SETTER_ROLE());
        rewards.setRewardQuota(2000);
    }

    function testMintReward() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes memory signature = createSignature(reward, oraclePrivateKey);

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
        bytes memory signature = createSignature(reward, oraclePrivateKey);

        // Expect the quota to be exceeded
        vm.expectRevert(Rewards.RewardQuotaExceeded.selector);
        rewards.mintReward(reward, signature);
    }

    function testMintRewardUnauthorizedOracle() public {
        // Prepare the reward and signature with an unauthorized oracle
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes memory signature = createSignature(reward, 0xDEAD);

        // Expect unauthorized oracle error
        vm.expectRevert(Rewards.UnauthorizedOracle.selector);
        rewards.mintReward(reward, signature);
    }

    function testMintRewardInvalidCounter() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 1); // Invalid counter
        bytes memory signature = createSignature(reward, oraclePrivateKey);

        // Expect invalid recipient counter error
        vm.expectRevert(Rewards.InvalidRecipientCounter.selector);
        rewards.mintReward(reward, signature);
    }

    function testDigestReward() public {
        bytes32 hashedEIP712DomainType =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 hashedName = keccak256(bytes("rewards.depin.nodle"));
        bytes32 hashedVersion = keccak256(bytes("1"));
        bytes32 domainSeparator =
            keccak256(abi.encode(hashedEIP712DomainType, hashedName, hashedVersion, block.chainid, address(rewards)));

        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes32 hashedType = keccak256(rewards.REWARD_TYPE());
        bytes32 structHash = keccak256(abi.encode(hashedType, reward.recipient, reward.amount, reward.counter));

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        assertEq(rewards.digestReward(reward), digest);
    }

    function testMintRewardInvalidDigest() public {
        bytes32 hashedEIP712DomainType =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 hashedName = keccak256(bytes("rewards.depin.nodle"));
        bytes32 hashedVersion = keccak256(bytes("2")); // Wrong version
        bytes32 domainSeparator =
            keccak256(abi.encode(hashedEIP712DomainType, hashedName, hashedVersion, block.chainid, address(rewards)));

        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes32 hashedType = keccak256(rewards.REWARD_TYPE());
        bytes32 structHash = keccak256(abi.encode(hashedType, reward.recipient, reward.amount, reward.counter));

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert();
        rewards.mintReward(reward, signature);
    }

    function testRewardsClaimedResetsOnNewPeriod() public {
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes memory signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        uint256 firstRenewal = block.timestamp + RENEWAL_PERIOD;
        uint256 fourthRenewal = firstRenewal + 3 * RENEWAL_PERIOD;
        uint256 fifthRenewal = firstRenewal + 4 * RENEWAL_PERIOD;

        assertEq(rewards.rewardsClaimed(), 100);
        assertEq(rewards.quotaRenewalTimestamp(), firstRenewal);

        vm.warp(fourthRenewal + 1 seconds);

        reward = Rewards.Reward(recipient, 50, 1);
        signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        assertEq(rewards.rewardsClaimed(), 50);
        assertEq(rewards.quotaRenewalTimestamp(), fifthRenewal);
    }

    function testRewardsClaimedAccumulates() public {
        address user1 = address(11);
        address user2 = address(22);

        Rewards.Reward memory reward = Rewards.Reward(user1, 3, 0);
        bytes memory signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        reward = Rewards.Reward(user2, 5, 0);
        signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        reward = Rewards.Reward(user1, 7, 1);
        signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        reward = Rewards.Reward(user2, 11, 1);
        signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        assertEq(rewards.rewardsClaimed(), 26);
    }

    function createSignature(Rewards.Reward memory reward, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 digest = rewards.digestReward(reward);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}

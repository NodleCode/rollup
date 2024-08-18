// SPDX-License-Identifier: BSD-3-Clause-Clear
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
        rewards = new Rewards(nodlToken, 1000, RENEWAL_PERIOD, oracle, 2);
        // Grant MINTER_ROLE to the Rewards contract
        nodlToken.grantRole(nodlToken.MINTER_ROLE(), address(rewards));
    }

    function test_setQuota() public {
        // Check initial quota
        assertEq(rewards.quota(), 1000);

        address alice = address(2);

        // Assign QUOTA_SETTER_ROLE to the test contract
        rewards.grantRole(rewards.DEFAULT_ADMIN_ROLE(), alice);

        // Set the new quota
        vm.prank(alice);
        rewards.setQuota(2000);

        // Check new quota
        assertEq(rewards.quota(), 2000);
    }

    function test_setQuotaUnauthorized() public {
        address bob = address(3);
        vm.expectRevert_AccessControlUnauthorizedAccount(bob, rewards.DEFAULT_ADMIN_ROLE());
        vm.prank(bob);
        rewards.setQuota(2000);
    }

    function test_mintReward() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes memory signature = createSignature(reward, oraclePrivateKey);

        // Mint reward
        rewards.mintReward(reward, signature);

        // Check balances and sequences
        assertEq(nodlToken.balanceOf(recipient), 100);
        assertEq(rewards.claimed(), 100);
        assertEq(rewards.sequences(recipient), 1);
    }

    function test_mintRewardQuotaExceeded() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 1100, 0);
        bytes memory signature = createSignature(reward, oraclePrivateKey);

        // Expect the quota to be exceeded
        vm.expectRevert(Rewards.QuotaExceeded.selector);
        rewards.mintReward(reward, signature);
    }

    function test_mintRewardUnauthorizedOracle() public {
        // Prepare the reward and signature with an unauthorized oracle
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes memory signature = createSignature(reward, 0xDEAD);

        // Expect unauthorized oracle error
        vm.expectRevert(Rewards.UnauthorizedOracle.selector);
        rewards.mintReward(reward, signature);
    }

    function test_mintRewardInvalidsequence() public {
        // Prepare the reward and signature
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 1); // Invalid sequence
        bytes memory signature = createSignature(reward, oraclePrivateKey);

        // Expect invalid recipient sequence error
        vm.expectRevert(Rewards.InvalidRecipientSequence.selector);
        rewards.mintReward(reward, signature);
    }

    function test_mintBatchReward() public {
        address submitter = address(44);
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 100;
        amounts[1] = 200;
        uint256 submitterReward = (amounts[0] + amounts[1]) * rewards.batchSubmitterRewardPercentage() / 100;

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);

        bytes memory signature = createBatchSignature(rewardsBatch, oraclePrivateKey);

        vm.prank(submitter);
        rewards.mintBatchReward(rewardsBatch, signature);

        assertEq(nodlToken.balanceOf(recipients[0]), amounts[0]);
        assertEq(nodlToken.balanceOf(recipients[1]), amounts[1]);
        assertEq(nodlToken.balanceOf(submitter), submitterReward);
        assertEq(rewards.claimed(), amounts[0] + amounts[1] + submitterReward);
        assertEq(rewards.sequences(recipients[0]), 0);
        assertEq(rewards.sequences(recipients[1]), 0);
        assertEq(rewards.batchSequence(), 1);
    }

    function test_gasUsed() public {
        address[] memory recipients = new address[](500);
        uint256[] memory amounts = new uint256[](500);

        for (uint256 i = 0; i < 500; i++) {
            recipients[i] = address(uint160(i + 1));
            amounts[i] = 1;
        }

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);

        bytes memory signature = createBatchSignature(rewardsBatch, oraclePrivateKey);

        uint256 gasBefore = gasleft();
        rewards.mintBatchReward(rewardsBatch, signature);
        uint256 gasAfter = gasleft();

        uint256 gasUsedPerRecipient = (gasBefore - gasAfter) / 500;
        console.log("Gas used per recipient in a batch: %d", gasUsedPerRecipient);

        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes memory signature2 = createSignature(reward, oraclePrivateKey);

        gasBefore = gasleft();
        rewards.mintReward(reward, signature2);
        gasAfter = gasleft();
        console.log("Gas used per recipient in a solo:  %d", gasBefore - gasAfter);
        uint256 ratio = (gasBefore - gasAfter) / gasUsedPerRecipient;
        console.log("Batch efficieny >= %dX", ratio);

        assertTrue(ratio >= 1, "Batch efficiency must be at least 1X to be worth it.");
    }

    function test_mintBatchRewardQuotaExceeded() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 500;
        amounts[1] = 600;

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);

        bytes memory signature = createBatchSignature(rewardsBatch, oraclePrivateKey);

        vm.expectRevert(Rewards.QuotaExceeded.selector);
        rewards.mintBatchReward(rewardsBatch, signature);
    }

    function test_mintBatchRewardUnauthorizedOracle() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 100;
        amounts[1] = 200;

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);

        bytes memory signature = createBatchSignature(rewardsBatch, 0xDEAD);

        vm.expectRevert(Rewards.UnauthorizedOracle.selector);
        rewards.mintBatchReward(rewardsBatch, signature);
    }

    function test_mintBatchRewardInvalidSequence() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 100;
        amounts[1] = 200;

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 1);

        bytes memory signature = createBatchSignature(rewardsBatch, oraclePrivateKey);

        vm.expectRevert(Rewards.InvalidBatchSequence.selector);
        rewards.mintBatchReward(rewardsBatch, signature);
    }

    function test_mintBatchRewardInvalidStruct() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](1);

        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 100;

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);

        bytes memory signature = createBatchSignature(rewardsBatch, oraclePrivateKey);

        vm.expectRevert(Rewards.InvalidBatchStructure.selector);
        rewards.mintBatchReward(rewardsBatch, signature);
    }

    function test_digestReward() public {
        bytes32 hashedEIP712DomainType =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 hashedName = keccak256(bytes("rewards.depin.nodle"));
        bytes32 hashedVersion = keccak256(bytes("1"));
        bytes32 domainSeparator =
            keccak256(abi.encode(hashedEIP712DomainType, hashedName, hashedVersion, block.chainid, address(rewards)));

        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes32 structHash =
            keccak256(abi.encode(rewards.REWARD_TYPE_HASH(), reward.recipient, reward.amount, reward.sequence));

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        assertEq(rewards.digestReward(reward), digest);
    }

    function test_mintRewardInvalidDigest() public {
        bytes32 hashedEIP712DomainType =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 hashedName = keccak256(bytes("rewards.depin.nodle"));
        bytes32 hashedVersion = keccak256(bytes("2")); // Wrong version
        bytes32 domainSeparator =
            keccak256(abi.encode(hashedEIP712DomainType, hashedName, hashedVersion, block.chainid, address(rewards)));

        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes32 structHash =
            keccak256(abi.encode(rewards.REWARD_TYPE_HASH(), reward.recipient, reward.amount, reward.sequence));

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert();
        rewards.mintReward(reward, signature);
    }

    function test_mintBatchRewardInvalidDigest() public {
        bytes32 hashedEIP712DomainType =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 hashedName = keccak256(bytes("rewards.depin.nodle"));
        bytes32 hashedVersion = keccak256(bytes("2")); // Wrong version
        bytes32 domainSeparator =
            keccak256(abi.encode(hashedEIP712DomainType, hashedName, hashedVersion, block.chainid, address(rewards)));

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 100;
        amounts[1] = 200;

        bytes32 receipentsHash = keccak256(abi.encodePacked(recipients));
        bytes32 amountsHash = keccak256(abi.encodePacked(amounts));
        bytes32 structHash = keccak256(abi.encode(rewards.BATCH_REWARD_TYPE_HASH(), receipentsHash, amountsHash, 0));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert();
        rewards.mintBatchReward(Rewards.BatchReward(recipients, amounts, 0), signature);
    }

    function test_rewardsClaimedResetsOnNewPeriod() public {
        Rewards.Reward memory reward = Rewards.Reward(recipient, 100, 0);
        bytes memory signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        uint256 firstRenewal = RENEWAL_PERIOD + 1; // `+ 1` comes from the expected initial value of block.timestamp
        uint256 fourthRenewal = firstRenewal + 3 * RENEWAL_PERIOD;
        uint256 fifthRenewal = firstRenewal + 4 * RENEWAL_PERIOD;
        uint256 sixthRenewal = firstRenewal + 5 * RENEWAL_PERIOD;

        assertEq(rewards.claimed(), 100);
        assertEq(rewards.quotaRenewalTimestamp(), firstRenewal);

        vm.warp(fourthRenewal + 1 seconds);

        reward = Rewards.Reward(recipient, 50, 1);
        signature = createSignature(reward, oraclePrivateKey);
        rewards.mintReward(reward, signature);

        assertEq(rewards.claimed(), 50);
        assertEq(rewards.quotaRenewalTimestamp(), fifthRenewal);

        vm.warp(fifthRenewal + 1 seconds);

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 100;
        amounts[1] = 200;
        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);
        bytes memory batchSignature = createBatchSignature(rewardsBatch, oraclePrivateKey);
        rewards.mintBatchReward(rewardsBatch, batchSignature);
        assertEq(rewards.claimed(), 300 + 300 * rewards.batchSubmitterRewardPercentage() / 100);

        assertEq(rewards.quotaRenewalTimestamp(), sixthRenewal);
    }

    function test_rewardsClaimedAccumulates() public {
        address user1 = address(11);
        address user2 = address(22);
        address user3 = address(33);

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

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = user3;
        recipients[1] = user1;
        amounts[0] = 3;
        amounts[1] = 1;
        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);
        bytes memory batchSignature = createBatchSignature(rewardsBatch, oraclePrivateKey);
        rewards.mintBatchReward(rewardsBatch, batchSignature);

        assertEq(rewards.claimed(), 30);
    }

    function test_setBatchSubmitterRewardPercentage() public {
        address alice = address(2);
        rewards.grantRole(rewards.DEFAULT_ADMIN_ROLE(), alice);

        assertEq(rewards.batchSubmitterRewardPercentage(), 2);

        vm.prank(alice);
        rewards.setBatchSubmitterRewardPercentage(10);

        assertEq(rewards.batchSubmitterRewardPercentage(), 10);
    }

    function test_setBatchSubmitterRewardPercentageUnauthorized() public {
        address bob = address(3);
        vm.expectRevert_AccessControlUnauthorizedAccount(bob, rewards.DEFAULT_ADMIN_ROLE());
        vm.prank(bob);
        rewards.setBatchSubmitterRewardPercentage(10);
    }

    function test_setBatchSubmitterRewardPercentageOutOfRange() public {
        address alice = address(2);
        rewards.grantRole(rewards.DEFAULT_ADMIN_ROLE(), alice);

        vm.expectRevert(Rewards.OutOfRangeValue.selector);
        vm.prank(alice);
        rewards.setBatchSubmitterRewardPercentage(101);
    }

    function test_deployRewardsWithInvalidSubmitterRewardPercentage() public {
        vm.expectRevert(Rewards.OutOfRangeValue.selector);
        new Rewards(nodlToken, 1000, RENEWAL_PERIOD, vm.addr(1), 101);
    }

    function test_changingSubmitterRewardPercentageIsEffective() public {
        address alice = address(2);
        rewards.grantRole(rewards.DEFAULT_ADMIN_ROLE(), alice);

        assertEq(rewards.batchSubmitterRewardPercentage(), 2);

        vm.prank(alice);
        rewards.setBatchSubmitterRewardPercentage(100);

        assertEq(rewards.batchSubmitterRewardPercentage(), 100);

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = 100;
        amounts[1] = 200;
        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);
        bytes memory batchSignature = createBatchSignature(rewardsBatch, oraclePrivateKey);
        vm.prank(alice);
        rewards.mintBatchReward(rewardsBatch, batchSignature);

        assertEq(rewards.claimed(), 2 * 300); // expected value for 100% submitter reward
        assertEq(nodlToken.balanceOf(alice), 300);
    }

    function test_mintBatchRewardOverflowsOnBatchSum() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        recipients[0] = address(11);
        recipients[1] = address(22);
        amounts[0] = type(uint256).max;
        amounts[1] = 1;

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);

        bytes memory signature = createBatchSignature(rewardsBatch, oraclePrivateKey);
        vm.expectRevert(stdError.arithmeticError);
        rewards.mintBatchReward(rewardsBatch, signature);
    }

    function test_mintBatchRewardOverflowsOnSubmitterReward() public {
        address alice = address(2);
        rewards.grantRole(rewards.DEFAULT_ADMIN_ROLE(), alice);

        // Ensure the quota is high enough
        vm.prank(alice);
        rewards.setQuota(type(uint256).max);

        // Check initial submitter reward percentage
        assertEq(rewards.batchSubmitterRewardPercentage(), 2);

        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        recipients[0] = address(11);
        // This amount, even though high, should not cause an overflow
        amounts[0] = type(uint256).max / (2 * rewards.batchSubmitterRewardPercentage());

        Rewards.BatchReward memory rewardsBatch = Rewards.BatchReward(recipients, amounts, 0);
        bytes memory signature = createBatchSignature(rewardsBatch, oraclePrivateKey);
        rewards.mintBatchReward(rewardsBatch, signature);

        vm.prank(alice);
        // Same batch sum should now cause an overflow in the submitter reward calculation
        rewards.setBatchSubmitterRewardPercentage(100);

        Rewards.BatchReward memory rewardsBatch2 = Rewards.BatchReward(recipients, amounts, 1);
        bytes memory signature2 = createBatchSignature(rewardsBatch2, oraclePrivateKey);
        vm.expectRevert(stdError.arithmeticError);
        rewards.mintBatchReward(rewardsBatch2, signature2);
    }

    function createSignature(Rewards.Reward memory reward, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 digest = rewards.digestReward(reward);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function createBatchSignature(Rewards.BatchReward memory rewardsBatch, uint256 privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = rewards.digestBatchReward(rewardsBatch);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}

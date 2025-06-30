// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {NODL} from "../src/NODL.sol";
import {Staking} from "../src/Staking.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract StakingTest is Test {
    NODL public token;
    Staking public staking;
    
    address public admin = address(1);
    address public user1 = address(2);
    address public user2 = address(3);
    address public user3 = address(4);
    
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_MANAGER_ROLE = keccak256("EMERGENCY_MANAGER_ROLE");
    
    uint256 public constant REWARD_RATE = 10; // 10%
    uint256 public constant MIN_STAKE = 100 * 1e18; // 100 tokens
    uint256 public constant MAX_TOTAL_STAKE = 1000 * 1e18; // 1000 tokens
    uint256 public constant DURATION = 30 days; // 30 days
    uint256 public constant REQUIRED_HOLDING_TOKEN = 200 * 1e18; // 200 tokens
    
    function setUp() public {
        vm.startPrank(admin);
        token = new NODL(admin);
        staking = new Staking(
            address(token),
            REQUIRED_HOLDING_TOKEN,
            REWARD_RATE,
            MIN_STAKE,
            MAX_TOTAL_STAKE,
            DURATION,
            admin
        );
        
        // Mint tokens to users for testing
        token.mint(user1, 1000 ether);
        token.mint(user2, 1000 ether);
        token.mint(admin, 1000000 ether); // Increased admin balance significantly
        token.mint(user3, 100 ether);
        vm.stopPrank();
    }
    
    // Helper function to move time forward
    function _skipTime(uint256 days_) internal {
        vm.warp(block.timestamp + days_ * 1 days);
    }

    // Helper function to calculate reward like the contract
    function _calculateReward(uint256 amount) internal view returns (uint256) {
        uint256 PRECISION = 1e18;
        return (amount * REWARD_RATE * PRECISION) / (100 * PRECISION);
    }

    // Test roles
    function testRoles() public {
        assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(staking.hasRole(REWARDS_MANAGER_ROLE, admin));
        assertTrue(staking.hasRole(EMERGENCY_MANAGER_ROLE, admin));
        
        assertFalse(staking.hasRole(REWARDS_MANAGER_ROLE, user1));
        assertFalse(staking.hasRole(EMERGENCY_MANAGER_ROLE, user1));
    }

    function testGrantAndRevokeRoles() public {
        vm.startPrank(admin);
        
        // Grant roles
        staking.grantRole(REWARDS_MANAGER_ROLE, user1);
        staking.grantRole(EMERGENCY_MANAGER_ROLE, user1);
        assertTrue(staking.hasRole(REWARDS_MANAGER_ROLE, user1));
        assertTrue(staking.hasRole(EMERGENCY_MANAGER_ROLE, user1));
        
        // Revoke roles
        staking.revokeRole(REWARDS_MANAGER_ROLE, user1);
        staking.revokeRole(EMERGENCY_MANAGER_ROLE, user1);
        assertFalse(staking.hasRole(REWARDS_MANAGER_ROLE, user1));
        assertFalse(staking.hasRole(EMERGENCY_MANAGER_ROLE, user1));
        
        vm.stopPrank();
    }

    function testFailNonAdminGrantRole() public {
        vm.startPrank(user1);
        staking.grantRole(REWARDS_MANAGER_ROLE, user2);
        vm.stopPrank();
    }

    // Test fundRewards with roles
    function testFundRewards() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(admin);
        token.approve(address(staking), amount);
        staking.fundRewards(amount);
        vm.stopPrank();
        
        assertEq(staking.availableRewards(), amount);
    }

    function testFailNonRewardsManagerFundRewards() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(user1);
        token.approve(address(staking), amount);
        staking.fundRewards(amount);
        vm.stopPrank();
    }

    // Test pause/unpause with roles
    function testPauseUnpause() public {
        vm.startPrank(admin);
        staking.pause();
        assertTrue(staking.paused());
        
        staking.unpause();
        assertFalse(staking.paused());
        vm.stopPrank();
    }

    function testFailNonAdminPause() public {
        vm.startPrank(user1);
        staking.pause();
        vm.stopPrank();
    }

    // Test stake function
    function testStake() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        (uint256 amount, uint256 start, bool claimed, bool unstaked, uint256 timeLeft, uint256 potentialReward) = staking.getStakeInfo(user1, 0);
        assertEq(amount, stakeAmount);
        assertEq(start, block.timestamp);
        assertEq(claimed, false);
        assertEq(unstaked, false);
        assertEq(timeLeft, DURATION);
        assertEq(potentialReward, _calculateReward(stakeAmount));
    }

    function testFailStakeBelowMinimum() public {
        uint256 stakeAmount = (MIN_STAKE - (1 ether));
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testFailStakeAboveMaximum() public {
        uint256 stakeAmount = (MAX_TOTAL_STAKE + (1 ether));
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testFailStakeInsufficientBalance() public {
        uint256 stakeAmount = MIN_STAKE + (1000 ether);
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testFailStakeUnmetRequiredHoldingToken() public {
        uint256 stakeAmount = MIN_STAKE;

        vm.startPrank(user3);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testStakeInsufficientRewardsReverts() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Ensure no rewards are funded
        assertEq(staking.availableRewards(), 0);
        
        // Calculate expected reward
        uint256 expectedReward = _calculateReward(stakeAmount);
        assertGt(expectedReward, 0, "Expected reward should be greater than 0");
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        vm.expectRevert(Staking.InsufficientRewardBalance.selector);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    // Additional test to verify the logic
    function testStakeFailsWithoutRewards() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Verify no rewards are available
        assertEq(staking.availableRewards(), 0);
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        
        // This should fail because no rewards are available
        vm.expectRevert();
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    // Test multiple stakes
    function testMultipleStakes() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        (uint256 amount1, , , , , ) = staking.getStakeInfo(user1, 0);
        assertEq(amount1, stakeAmount);
        
        // Second stake
        staking.stake(stakeAmount);
        (uint256 amount2, , , , , ) = staking.getStakeInfo(user1, 1);
        assertEq(amount2, stakeAmount);
        
        vm.stopPrank();
    }

    function testClaim() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        uint256 balanceBefore = token.balanceOf(user1);
        staking.claim(0);
        uint256 balanceAfter = token.balanceOf(user1);
        
        uint256 expectedReward = _calculateReward(stakeAmount);
        assertEq(balanceAfter - balanceBefore, stakeAmount + expectedReward);
        vm.stopPrank();
    }

    function testFailClaimTooEarly() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        staking.claim(0);
        vm.stopPrank();
    }

    function testFailClaimAlreadyUnstaked() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Enable unstake and unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnstakeAllowed(true);
        vm.stopPrank();
        
        vm.startPrank(user1);
        staking.unstake(0);
        
        // Try to claim unstaked stake
        staking.claim(0);
        vm.stopPrank();
    }

    function testUnstake() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnstakeAllowed(true);
        vm.stopPrank();
        
        // Unstake
        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        staking.unstake(0);
        uint256 balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, stakeAmount);
        
        // Verify stake is marked as unstaked
        (uint256 amount, , bool claimed, bool unstaked, , ) = staking.getStakeInfo(user1, 0);
        assertEq(amount, 0);
        assertEq(claimed, false);
        assertEq(unstaked, true);
        vm.stopPrank();
    }

    function testFailUnstakeNotAllowed() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        staking.unstake(0);
        vm.stopPrank();
    }

    function testFailUnstakeNonExistentStake() public {
        vm.startPrank(user1);
        staking.unstake(0);
        vm.stopPrank();
    }

    function testGetStakeInfoForNonExistentStake() public {
        // This test should expect a revert since getStakeInfo now reverts for non-existent stakes
        vm.expectRevert(Staking.NoStake.selector);
        staking.getStakeInfo(user1, 0);
    }

    // Rewards
    function testRewardCalculation() public {
        uint256 stakeAmount = 1000 ether;
        uint256 expectedReward = _calculateReward(stakeAmount);
        
        // Fund rewards first
        vm.startPrank(admin);
        token.approve(address(staking), expectedReward);
        staking.fundRewards(expectedReward);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        uint256 balanceBefore = token.balanceOf(user1);
        staking.claim(0);
        uint256 balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, stakeAmount + expectedReward);
        vm.stopPrank();
    }

    function testFailClaimInsufficientRewards() public {
        uint256 stakeAmount = 1000 ether;
        uint256 rewardAmount = _calculateReward(stakeAmount);
        
        // Fund rewards for stake but not enough for claim
        vm.startPrank(admin);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Move time forward and try to claim
        _skipTime(DURATION + 1);
        
        vm.expectRevert(Staking.InsufficientRewardBalance.selector);
        staking.claim(0);
        vm.stopPrank();
    }

    function testMultipleRewardsFundings() public {
        uint256 stakeAmount = 1000 ether;
        uint256 rewardAmount = _calculateReward(stakeAmount);
        
        // Fund rewards first
        vm.startPrank(admin);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Fund rewards multiple times
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), rewardAmount * 2);
        staking.fundRewards(rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        staking.claim(0);
        uint256 balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, stakeAmount + rewardAmount);
        vm.stopPrank();
    }

    // Time validations
    function testClaimExactlyAtDuration() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Move time forward exactly to duration
        _skipTime(DURATION);
        
        staking.claim(0);
        vm.stopPrank();
    }

    function testClaimAfterDuration() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Move time forward past duration
        _skipTime(DURATION + 1 days);
        
        staking.claim(0);
        vm.stopPrank();
    }

    function testFailClaimBeforeDuration() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Try to claim before duration
        _skipTime(DURATION - 1);
        
        vm.expectRevert(Staking.TooEarly.selector);
        staking.claim(0);
        vm.stopPrank();
    }

    // Multiple operations
    function testMultipleStakesAndClaims() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Second stake
        staking.stake(stakeAmount);
        
        // Move time forward
        _skipTime(DURATION + 1);
        
        // Claim both stakes
        staking.claim(0);
        staking.claim(1);
        vm.stopPrank();
    }

    function testMultipleStakesAndUnstakes() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Second stake
        staking.stake(stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnstakeAllowed(true);
        vm.stopPrank();
        
        // Unstake both
        vm.startPrank(user1);
        staking.unstake(0);
        staking.unstake(1);
        vm.stopPrank();
    }

    function testStakeAfterClaim() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        staking.claim(0);
        
        // New stake after claim
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testStakeAfterUnstake() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnstakeAllowed(true);
        vm.stopPrank();
        
        // Unstake
        vm.startPrank(user1);
        staking.unstake(0);
        
        // New stake after unstake
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    // Pool limits
    function testFailStakeExceedsMaxPoolStake() public {
        uint256 stakeAmount = staking.MAX_POOL_STAKE() + 1 ether;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testStakeAtMaxPoolStake() public {
        // First update MAX_POOL_STAKE to respect MAX_TOTAL_STAKE
        vm.startPrank(admin);
        staking.updateMaxPoolStake(MAX_TOTAL_STAKE);
        vm.stopPrank();
        
        uint256 stakeAmount = MAX_TOTAL_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        assertEq(staking.totalStakedInPool(), stakeAmount);
        assertEq(staking.totalStakedByUser(user1), stakeAmount);
        vm.stopPrank();
    }

    // Test pool limit with multiple users
    function testMultipleUsersAtMaxPoolStake() public {
        uint256 stakeAmount = MAX_TOTAL_STAKE;
        uint256 numUsers = 5; // 5 users making maximum stake
        
        // Mint tokens to multiple users
        vm.startPrank(admin);
        for(uint i = 0; i < numUsers; i++) {
            address user = address(uint160(uint(keccak256(abi.encodePacked(i)))));
            token.mint(user, stakeAmount);
        }
        vm.stopPrank();
        
        // Fund rewards for all users
        vm.startPrank(admin);
        uint256 totalRewardAmount = _calculateReward(stakeAmount * numUsers);
        token.approve(address(staking), totalRewardAmount);
        staking.fundRewards(totalRewardAmount);
        vm.stopPrank();
        
        // Each user makes a stake
        for(uint i = 0; i < numUsers; i++) {
            address user = address(uint160(uint(keccak256(abi.encodePacked(i)))));
            vm.startPrank(user);
            token.approve(address(staking), stakeAmount);
            staking.stake(stakeAmount);
            vm.stopPrank();
        }
        
        assertEq(staking.totalStakedInPool(), stakeAmount * numUsers);
    }

    // Test precision in reward calculation
    function testPrecisionInRewardCalculation() public {
        uint256 stakeAmount = 999 ether; // Just below MAX_TOTAL_STAKE (1000 ether)
        uint256 expectedReward = _calculateReward(stakeAmount);
        
        // Fund rewards first
        vm.startPrank(admin);
        token.approve(address(staking), expectedReward);
        staking.fundRewards(expectedReward);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Check potential reward calculation
        (uint256 amount, , , , , uint256 potentialReward) = staking.getStakeInfo(user1, 0);
        assertEq(amount, stakeAmount);
        assertEq(potentialReward, expectedReward);
        vm.stopPrank();
    }

    // Test unstake state tracking
    function testUnstakeStateTracking() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = (stakeAmount * REWARD_RATE) / 100;
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Check initial state
        (uint256 amount1, , bool claimed1, bool unstaked1, , ) = staking.getStakeInfo(user1, 0);
        assertEq(amount1, stakeAmount);
        assertEq(claimed1, false);
        assertEq(unstaked1, false);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnstakeAllowed(true);
        vm.stopPrank();
        
        // Unstake
        vm.startPrank(user1);
        staking.unstake(0);
        
        // Check unstaked state
        (uint256 amount2, , bool claimed2, bool unstaked2, , ) = staking.getStakeInfo(user1, 0);
        assertEq(amount2, 0);
        assertEq(claimed2, false);
        assertEq(unstaked2, true);
        vm.stopPrank();
    }

    // Test claim state tracking
    function testClaimStateTracking() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Check initial state
        (uint256 amount1, , bool claimed1, bool unstaked1, , ) = staking.getStakeInfo(user1, 0);
        assertEq(amount1, stakeAmount);
        assertEq(claimed1, false);
        assertEq(unstaked1, false);
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        vm.startPrank(user1);
        staking.claim(0);
        
        // Check claimed state
        (uint256 amount2, , bool claimed2, bool unstaked2, , ) = staking.getStakeInfo(user1, 0);
        assertEq(amount2, 0);
        assertEq(claimed2, true);
        assertEq(unstaked2, false);
        vm.stopPrank();
    }

    // Test emergency withdraw
    function testEmergencyWithdraw() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
        
        vm.startPrank(admin);
        uint256 balanceBefore = token.balanceOf(admin);
        staking.emergencyWithdraw();
        uint256 balanceAfter = token.balanceOf(admin);
        
        assertEq(balanceAfter - balanceBefore, stakeAmount + rewardAmount);
        assertEq(staking.availableRewards(), 0);
        vm.stopPrank();
    }

    function testFailNonEmergencyManagerEmergencyWithdraw() public {
        vm.startPrank(user1);
        staking.emergencyWithdraw();
        vm.stopPrank();
    }

    // Test updateMaxPoolStake function
    function testUpdateMaxPoolStake() public {
        uint256 newMaxPoolStake = 10_000_000 ether;
        
        vm.startPrank(admin);
        uint256 oldValue = staking.MAX_POOL_STAKE();
        staking.updateMaxPoolStake(newMaxPoolStake);
        assertEq(staking.MAX_POOL_STAKE(), newMaxPoolStake);
        vm.stopPrank();
    }

    function testFailNonAdminUpdateMaxPoolStake() public {
        uint256 newMaxPoolStake = 10_000_000 ether;
        
        vm.startPrank(user1);
        staking.updateMaxPoolStake(newMaxPoolStake);
        vm.stopPrank();
    }

    function testFailUpdateMaxPoolStakeToZero() public {
        vm.startPrank(admin);
        staking.updateMaxPoolStake(0);
        vm.stopPrank();
    }

    function testFailUpdateMaxPoolStakeBelowCurrentStake() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
        
        // Try to update max pool stake below current stake
        vm.startPrank(admin);
        staking.updateMaxPoolStake(stakeAmount - 1);
        vm.stopPrank();
    }

    function testFailUpdateMaxPoolStakeWhenPaused() public {
        vm.startPrank(admin);
        staking.pause();
        staking.updateMaxPoolStake(10_000_000 ether);
        vm.stopPrank();
    }

    // User limits
    function testStakeAtMaxTotalStake() public {
        uint256 stakeAmount = MAX_TOTAL_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        assertEq(staking.totalStakedByUser(user1), stakeAmount);
        vm.stopPrank();
    }

    function testFailStakeAboveMaxTotalStake() public {
        uint256 stakeAmount = MAX_TOTAL_STAKE + 1 ether;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testStakeAfterPartialUnstake() public {
        uint256 stakeAmount = MAX_TOTAL_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        assertEq(staking.totalStakedByUser(user1), stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnstakeAllowed(true);
        vm.stopPrank();
        
        // Partial unstake
        vm.startPrank(user1);
        staking.unstake(0);
        assertEq(staking.totalStakedByUser(user1), 0);
        
        // New stake after unstake
        staking.stake(stakeAmount);
        assertEq(staking.totalStakedByUser(user1), stakeAmount);
        vm.stopPrank();
    }

    // Contract state
    function testTotalStakedInPool() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        assertEq(staking.totalStakedInPool(), stakeAmount);
        
        // Second user stakes
        vm.stopPrank();
        vm.startPrank(user2);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        assertEq(staking.totalStakedInPool(), stakeAmount * 2);
        vm.stopPrank();
    }

    function testTotalStakedByUser() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Fund rewards first
        vm.startPrank(admin);
        uint256 rewardAmount = _calculateReward(stakeAmount * 2);
        token.approve(address(staking), rewardAmount);
        staking.fundRewards(rewardAmount);
        vm.stopPrank();
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        assertEq(staking.totalStakedByUser(user1), stakeAmount);
        
        // Second stake
        staking.stake(stakeAmount);
        assertEq(staking.totalStakedByUser(user1), stakeAmount * 2);
        vm.stopPrank();
    }
}

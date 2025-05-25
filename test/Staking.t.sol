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
    
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    uint256 public constant REWARD_RATE = 10; // 10%
    uint256 public constant MIN_STAKE = 100 * 1e18; // 100 tokens
    uint256 public constant MAX_TOTAL_STAKE = 1000 * 1e18; // 1000 tokens
    uint256 public constant DURATION = 30 days; // 1/2 hour
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
        
        // Setup roles
        staking.grantRole(FUNDER_ROLE, admin);
        staking.grantRole(PAUSER_ROLE, admin);
        
        // Mint tokens to users for testing
        token.mint(user1, 1000 ether);
        token.mint(user2, 1000 ether);
        token.mint(admin, 1000 ether);
        token.mint(user3, 100 ether);
        vm.stopPrank();
    }
    
    // Helper function to move time forward
    function _skipTime(uint256 days_) internal {
        vm.warp(block.timestamp + days_ * 1 days);
    }

    // Test roles
    function testRoles() public {
        assertTrue(staking.hasRole(staking.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(staking.hasRole(FUNDER_ROLE, admin));
        assertTrue(staking.hasRole(PAUSER_ROLE, admin));
        
        assertFalse(staking.hasRole(FUNDER_ROLE, user1));
        assertFalse(staking.hasRole(PAUSER_ROLE, user1));
    }

    function testGrantAndRevokeRoles() public {
        vm.startPrank(admin);
        
        // Grant roles
        staking.grantRole(FUNDER_ROLE, user1);
        staking.grantRole(PAUSER_ROLE, user1);
        assertTrue(staking.hasRole(FUNDER_ROLE, user1));
        assertTrue(staking.hasRole(PAUSER_ROLE, user1));
        
        // Revoke roles
        staking.revokeRole(FUNDER_ROLE, user1);
        staking.revokeRole(PAUSER_ROLE, user1);
        assertFalse(staking.hasRole(FUNDER_ROLE, user1));
        assertFalse(staking.hasRole(PAUSER_ROLE, user1));
        
        vm.stopPrank();
    }

    function testFailNonAdminGrantRole() public {
        vm.startPrank(user1);
        staking.grantRole(FUNDER_ROLE, user2);
        vm.stopPrank();
    }

    // Test fundRewards with roles
    function testFundRewards() public {
        uint256 amount = 1000 ether;
        
        vm.startPrank(admin);
        token.approve(address(staking), amount);
        staking.fundRewards(amount);
        vm.stopPrank();
        
        assertEq(token.balanceOf(address(staking)), amount);
    }

    function testFailNonFunderFundRewards() public {
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

    function testFailNonPauserPause() public {
        vm.startPrank(user1);
        staking.pause();
        vm.stopPrank();
    }

    // Test stake function
    function testStake() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        (uint256 amount, uint256 start, bool claimed, uint256 timeLeft, uint256 potentialReward) = staking.getStakeInfo(user1, 0);
        assertEq(amount, stakeAmount);
        assertEq(start, block.timestamp);
        assertEq(claimed, false);
        assertEq(timeLeft, DURATION);
        assertEq(potentialReward, (stakeAmount * REWARD_RATE) / 100);
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

    // Test multiple stakes
    function testMultipleStakes() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        (uint256 amount1, , , , ) = staking.getStakeInfo(user1, 0);
        assertEq(amount1, stakeAmount);
        
        // Second stake
        staking.stake(stakeAmount);
        (uint256 amount2, , , , ) = staking.getStakeInfo(user1, 1);
        assertEq(amount2, stakeAmount);
        
        vm.stopPrank();
    }

    function testClaim() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Fund rewards
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), stakeAmount * 2);
        staking.fundRewards(stakeAmount * 2);
        vm.stopPrank();
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        staking.claim(0); // Added index parameter
        uint256 balanceAfter = token.balanceOf(user1);
        
        uint256 expectedReward = (stakeAmount * REWARD_RATE) / 100;
        assertEq(balanceAfter - balanceBefore, stakeAmount + expectedReward);
        vm.stopPrank();
    }

    function testFailClaimTooEarly() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        staking.claim(0); // Added index parameter
        vm.stopPrank();
    }

    function testUnstake() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Setup stake
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnestakeAllowed(true);
        vm.stopPrank();
        
        // Unstake
        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        staking.unstake(0); // Added index parameter
        uint256 balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, stakeAmount);
        vm.stopPrank();
    }

    function testFailUnstakeNotAllowed() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        staking.unstake(0); // Added index parameter
        vm.stopPrank();
    }

    function testFailUnstakeNonExistentStake() public {
        vm.startPrank(user1);
        staking.unstake(0); // Added index parameter
        vm.stopPrank();
    }

    // Test emergency withdraw
    function testEmergencyWithdraw() public {
        uint256 stakeAmount = MIN_STAKE;
        
        // Setup stake and fund rewards
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
        
        vm.startPrank(admin);
        token.approve(address(staking), stakeAmount);
        staking.fundRewards(stakeAmount);
        
        uint256 balanceBefore = token.balanceOf(admin);
        staking.emergencyWithdraw();
        uint256 balanceAfter = token.balanceOf(admin);
        
        assertEq(balanceAfter - balanceBefore, stakeAmount * 2);
        vm.stopPrank();
    }

    function testFailNonAdminEmergencyWithdraw() public {
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

    // Límites de Usuario
    function testStakeAtMaxTotalStake() public {
        uint256 stakeAmount = MAX_TOTAL_STAKE;
        
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
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        assertEq(staking.totalStakedByUser(user1), stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnestakeAllowed(true);
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

    // Estado del Contrato
    function testTotalStakedInPool() public {
        uint256 stakeAmount = MIN_STAKE;
        
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

    function testGetStakeInfoForNonExistentStake() public {
        (uint256 amount, uint256 start, bool claimed, uint256 timeLeft, uint256 potentialReward) = staking.getStakeInfo(user1, 0);
        assertEq(amount, 0);
        assertEq(start, 0);
        assertEq(claimed, false);
        assertEq(timeLeft, 0);
        assertEq(potentialReward, 0);
    }

    // Recompensas
    function testRewardCalculation() public {
        uint256 stakeAmount = 1000 ether;
        uint256 expectedReward = (stakeAmount * REWARD_RATE) / 100;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Fund rewards
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), expectedReward);
        staking.fundRewards(expectedReward);
        vm.stopPrank();
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        vm.startPrank(user1);
        uint256 balanceBefore = token.balanceOf(user1);
        staking.claim(0);
        uint256 balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, stakeAmount + expectedReward);
        vm.stopPrank();
    }

    function testFailClaimInsufficientRewards() public {
        uint256 stakeAmount = 1000 ether;
        uint256 rewardAmount = (stakeAmount * REWARD_RATE) / 100;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Fund less rewards than needed
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), rewardAmount - 1);
        staking.fundRewards(rewardAmount - 1);
        vm.stopPrank();
        
        // Move time forward and try to claim
        _skipTime(DURATION + 1);
        
        vm.startPrank(user1);
        staking.claim(0);
        vm.stopPrank();
    }

    function testMultipleRewardsFundings() public {
        uint256 stakeAmount = 1000 ether;
        uint256 rewardAmount = (stakeAmount * REWARD_RATE) / 100;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Fund rewards multiple times
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), rewardAmount * 3);
        staking.fundRewards(rewardAmount);
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

    // Validaciones de Tiempo
    function testClaimExactlyAtDuration() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Fund rewards
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), stakeAmount);
        staking.fundRewards(stakeAmount);
        vm.stopPrank();
        
        // Move time forward exactly to duration
        _skipTime(DURATION);
        
        vm.startPrank(user1);
        staking.claim(0);
        vm.stopPrank();
    }

    function testClaimAfterDuration() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Fund rewards
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), stakeAmount);
        staking.fundRewards(stakeAmount);
        vm.stopPrank();
        
        // Move time forward past duration
        _skipTime(DURATION + 1 days);
        
        vm.startPrank(user1);
        staking.claim(0);
        vm.stopPrank();
    }

    function testFailClaimBeforeDuration() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        
        // Try to claim before duration
        _skipTime(DURATION - 1);
        
        staking.claim(0);
        vm.stopPrank();
    }

    // Múltiples Operaciones
    function testMultipleStakesAndClaims() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Second stake
        staking.stake(stakeAmount);
        
        // Fund rewards
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), stakeAmount * 2);
        staking.fundRewards(stakeAmount * 2);
        vm.stopPrank();
        
        // Move time forward
        _skipTime(DURATION + 1);
        
        // Claim both stakes
        vm.startPrank(user1);
        staking.claim(0);
        staking.claim(1);
        vm.stopPrank();
    }

    function testMultipleStakesAndUnstakes() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Second stake
        staking.stake(stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnestakeAllowed(true);
        vm.stopPrank();
        
        // Unstake both
        vm.startPrank(user1);
        staking.unstake(0);
        staking.unstake(1);
        vm.stopPrank();
    }

    function testStakeAfterClaim() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Fund rewards
        vm.stopPrank();
        vm.startPrank(admin);
        token.approve(address(staking), stakeAmount);
        staking.fundRewards(stakeAmount);
        vm.stopPrank();
        
        // Move time forward and claim
        _skipTime(DURATION + 1);
        
        vm.startPrank(user1);
        staking.claim(0);
        
        // New stake after claim
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testStakeAfterUnstake() public {
        uint256 stakeAmount = MIN_STAKE;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        
        // First stake
        staking.stake(stakeAmount);
        
        // Enable unstake
        vm.stopPrank();
        vm.startPrank(admin);
        staking.updateUnestakeAllowed(true);
        vm.stopPrank();
        
        // Unstake
        vm.startPrank(user1);
        staking.unstake(0);
        
        // New stake after unstake
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    // Límites del Pool
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
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {NODL} from "../src/NODL.sol";
import {NODLStaking} from "../src/NodlStaking.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract NodlStakingTest is Test {
    NODL public token;
    NODLStaking public staking;
    
    address public admin = address(1);
    address public user1 = address(2);
    address public user2 = address(3);
    
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    uint256 public constant REWARD_RATE = 10; // 10%
    uint256 public constant MIN_STAKE = 100; // 100 tokens
    uint256 public constant MAX_TOTAL_STAKE = 1000; // 1000 tokens
    uint256 public constant DURATION = 30; // 30 days
    
    function setUp() public {
        vm.startPrank(admin);
        token = new NODL(admin);
        staking = new NODLStaking(
            address(token),
            REWARD_RATE,
            MIN_STAKE,
            MAX_TOTAL_STAKE,
            DURATION
        );
        
        // Setup roles
        staking.grantRole(FUNDER_ROLE, admin);
        staking.grantRole(PAUSER_ROLE, admin);
        
        // Mint tokens to users for testing
        token.mint(user1, 1000 ether);
        token.mint(user2, 1000 ether);
        token.mint(admin, 1000 ether);
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
        uint256 stakeAmount = MIN_STAKE * 1e18;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        (uint256 amount, uint256 start, bool claimed, uint256 timeLeft, uint256 potentialReward) = staking.getStakeInfo(user1);
        assertEq(amount, stakeAmount);
        assertEq(start, block.timestamp);
        assertEq(claimed, false);
        assertEq(timeLeft, DURATION * 1 days);
        assertEq(potentialReward, (stakeAmount * REWARD_RATE) / 100);
    }

    function testFailStakeBelowMinimum() public {
        uint256 stakeAmount = (MIN_STAKE - 1) * 1e18;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testFailStakeAboveMaximum() public {
        uint256 stakeAmount = (MAX_TOTAL_STAKE + 1) * 1e18;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();
    }

    // Test claim function
    function testClaim() public {
        uint256 stakeAmount = MIN_STAKE * 1e18;
        
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
        staking.claim();
        uint256 balanceAfter = token.balanceOf(user1);
        
        uint256 expectedReward = (stakeAmount * REWARD_RATE) / 100;
        assertEq(balanceAfter - balanceBefore, stakeAmount + expectedReward);
        vm.stopPrank();
    }

    function testFailClaimTooEarly() public {
        uint256 stakeAmount = MIN_STAKE * 1e18;
        
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        staking.claim();
        vm.stopPrank();
    }

    // Test emergency withdraw
    function testEmergencyWithdraw() public {
        uint256 stakeAmount = MIN_STAKE * 1e18;
        
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
}

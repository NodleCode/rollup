// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {NODL} from "./NODL.sol";

contract NODLStaking is Ownable, ReentrancyGuard, Pausable {
    NODL public immutable token;

    uint256 public immutable MIN_STAKE;
    uint256 public immutable MAX_TOTAL_STAKE;
    uint256 public immutable DURATION;
    uint256 public immutable rewardRate;
    bool public unstakeAllowed = false;

    uint256 public totalStaked;

    struct StakeInfo {
        uint256 amount;
        uint256 start;
        bool claimed;
    }

    mapping(address => StakeInfo) public stakes;

    error ZeroAddress();
    error InvalidRewardRate();
    error InvalidMinStake();
    error InvalidMaxTotalStake();
    error InvalidDuration();
    error MinStakeNotMet();
    error ExceedsMaxTotalStake();
    error AlreadyStaked();
    error NoStakeFound();
    error AlreadyClaimed();
    error TooEarly();
    error NoStake();
    error UnstakeNotAllowed();
    error InsufficientRewardBalance();
    error InsufficientAllowance();
    error InsufficientTotalStaked();

    event Staked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount, uint256 reward);
    event EmergencyWithdrawn(address indexed owner, uint256 amount);
    event UnstakeAllowedUpdated(bool allowed);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsFunded(uint256 amount);
    event Paused(address account);
    event Unpaused(address account);

    /* 
    @dev Constructor
    @param nodlToken The address of the NODL token
    @param _rewardRate The reward rate, represented in percentage
    @param _minStake The minimum stake, represented in Eth
    @param _maxTotalStake The maximum total stake, represented in Eth
    @param _duration The duration of the stake, represented in days
    */
    constructor(address nodlToken, uint256 _rewardRate, uint256 _minStake, uint256 _maxTotalStake, uint256 _duration) {
        if (nodlToken == address(0)) revert ZeroAddress();
        if (_rewardRate <= 0) revert InvalidRewardRate();
        if (_minStake == 0) revert InvalidMinStake();
        if (_maxTotalStake * 1e18 <= _minStake * 1e18) revert InvalidMaxTotalStake();
        if (_duration == 0) revert InvalidDuration();

        token = NODL(nodlToken);
        rewardRate = _rewardRate;
        MIN_STAKE = _minStake * 1e18;
        MAX_TOTAL_STAKE = _maxTotalStake * 1e18;
        DURATION = _duration * 1 days;
    }

    /* 
    @dev Stake
    @param amount The amount of tokens to stake
    @notice The stake can only be staked if the amount is greater than the minimum stake
    @notice The stake can only be staked if the total staked amount is less than the maximum total stake
    @notice The stake can only be staked if the user has not already staked
    */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount < MIN_STAKE) revert MinStakeNotMet();
        if (totalStaked + amount > MAX_TOTAL_STAKE) revert ExceedsMaxTotalStake();
        if (stakes[msg.sender].amount != 0) revert AlreadyStaked();

        token.transferFrom(msg.sender, address(this), amount);

        stakes[msg.sender] = StakeInfo({amount: amount, start: block.timestamp, claimed: false});

        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    /* 
    @dev Fund rewards
    @param amount The amount of tokens to fund rewards
    @notice Only owner can fund rewards
    @notice Requires sufficient allowance from owner to contract
    */
    function fundRewards(uint256 amount) external onlyOwner whenNotPaused {
        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < amount) revert InsufficientAllowance();
        
        token.transferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(amount);
    }

    /* 
    @dev Claim
    @notice The stake can only be claimed if the stake has not been claimed
    @notice The stake can only be claimed if the stake has not been unstaked
    @notice The stake can only be claimed if the stake has not been claimed
    @notice The contract must have enough balance for both stake and reward
    */
    function claim() external nonReentrant whenNotPaused {
        StakeInfo storage s = stakes[msg.sender];
        if (s.amount == 0) revert NoStakeFound();
        if (s.claimed) revert AlreadyClaimed();
        if (block.timestamp < s.start + DURATION) revert TooEarly();

        uint256 reward = (s.amount * rewardRate) / 100;
        uint256 totalToTransfer = s.amount + reward;
        uint256 contractBalance = token.balanceOf(address(this));
        if (totalToTransfer > contractBalance) revert InsufficientRewardBalance();

        s.claimed = true;
        token.transfer(msg.sender, totalToTransfer);

        emit Claimed(msg.sender, s.amount, reward);
    }

    /* 
    @dev Emergency withdraw
    @notice The owner can withdraw the tokens in case of emergency
    */
    function emergencyWithdraw() external onlyOwner {
        token.transfer(owner(), token.balanceOf(address(this)));

        emit EmergencyWithdrawn(owner(), token.balanceOf(address(this)));
    }

    /* 
    @dev Update the unstake allowed status
    @param allowed The new unstake allowed status
    */
    function updateUnestakeAllowed(bool allowed) external onlyOwner whenNotPaused {
        unstakeAllowed = allowed;
        emit UnstakeAllowedUpdated(allowed);
    }

    /* 
    @dev Unstake
    @notice The stake can only be unstaked if the unstake is allowed
    @notice The stake can only be unstaked if the user has a stake
    @notice The stake can only be unstaked if the stake has not been claimed
    */
    function unstake() external nonReentrant whenNotPaused {
        StakeInfo storage s = stakes[msg.sender];
        if (!unstakeAllowed) revert UnstakeNotAllowed();
        if (s.amount == 0) revert NoStake();
        if (s.claimed) revert AlreadyClaimed();

        uint256 returnAmount = s.amount;
        totalStaked -= returnAmount;
        s.amount = 0;
        s.claimed = true;

        token.transfer(msg.sender, returnAmount);

        emit Unstaked(msg.sender, returnAmount);
    }

    /* 
    @dev Get stake info
    @param user The address of the user to get the stake info for
    @return amount The amount of the stake
    @return start The start time of the stake
    @return claimed Whether the stake has been claimed
    @return timeLeft The remaining time of the stake in seconds
    @return potentialReward The potential reward of the stake
    */
    function getStakeInfo(address user)
        external
        view
        returns (
            uint256 amount,
            uint256 start,
            bool claimed,
            uint256 timeLeft,
            uint256 potentialReward
        )
    {
        StakeInfo storage s = stakes[user];
        amount = s.amount;
        start = s.start;
        claimed = s.claimed;
        timeLeft = 0;
        potentialReward = 0;

        // remaining time in seconds
        if (s.amount > 0 && !s.claimed) {
            if (block.timestamp < s.start + DURATION) {
                timeLeft = s.start + DURATION - block.timestamp;
            }
        }

        // potential reward
        if (s.amount > 0 && !s.claimed) {
            potentialReward = (s.amount * rewardRate) / 100;
        }

        return (amount, start, claimed, timeLeft, potentialReward);
    }

    /* 
    @dev Pause the contract
    @notice Only owner can pause the contract
    */
    function pause() external onlyOwner {
        _pause();
    }

    /* 
    @dev Unpause the contract
    @notice Only owner can unpause the contract
    */
    function unpause() external onlyOwner {
        _unpause();
    }
}

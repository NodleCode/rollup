// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract Staking is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_MANAGER_ROLE = keccak256("EMERGENCY_MANAGER_ROLE");

    IERC20 public immutable token;

    uint256 public immutable MIN_STAKE;
    uint256 public immutable MAX_TOTAL_STAKE;
    uint256 public MAX_POOL_STAKE = 5_000_000 ether;
    uint256 public immutable DURATION;
    uint256 public immutable REWARD_RATE;
    uint256 public immutable REQUIRED_HOLDING_TOKEN;
    bool public unstakeAllowed = false;

    uint256 public totalStakedInPool;
    uint256 public availableRewards;

    struct StakeInfo {
        uint256 amount;
        uint256 start;
        bool claimed;
        bool unstaked;
    }

    mapping(address => StakeInfo[]) public stakes;
    mapping(address => uint256) public totalStakedByUser;

    error ZeroAddress();
    error InvalidRewardRate();
    error InvalidMinStake();
    error InvalidMaxTotalStake();
    error InvalidDuration();
    error MinStakeNotMet();
    error ExceedsMaxTotalStake();
    error ExceedsMaxPoolStake();
    error AlreadyClaimed();
    error TooEarly();
    error NoStake();
    error UnstakeNotAllowed();
    error InsufficientRewardBalance();
    error InsufficientBalance();
    error UnmetRequiredHoldingToken();
    error InvalidMaxPoolStake();
    error AlreadyUnstaked();

    event Staked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount, uint256 reward);
    event EmergencyWithdrawn(address indexed owner, uint256 amount);
    event UnstakeAllowedUpdated(bool allowed);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsFunded(uint256 amount);
    event MaxPoolStakeUpdated(uint256 oldValue, uint256 newValue);

    /* 
    @dev Constructor
    @param nodlToken The address of the NODL token
    @param _requiredHoldingToken The required holding of token, represented in Wei
    @param _rewardRate The reward rate, represented in percentage
    @param _minStake The minimum stake per user, represented in Wei
    @param _maxTotalStake The maximum total stake per user, represented in Wei
    @param _duration The duration of the stake, represented in seconds
    @param _admin The address of the admin
    */
    constructor(address nodlToken, uint256 _requiredHoldingToken, uint256 _rewardRate, uint256 _minStake, uint256 _maxTotalStake, uint256 _duration, address _admin) {
        if (nodlToken == address(0)) revert ZeroAddress();
        if (_rewardRate == 0) revert InvalidRewardRate();
        if (_minStake == 0) revert InvalidMinStake();
        if (_maxTotalStake <= _minStake) revert InvalidMaxTotalStake();
        if (_duration == 0) revert InvalidDuration();
        if (_admin == address(0)) revert ZeroAddress();

        token = IERC20(nodlToken);
        REWARD_RATE = _rewardRate;
        MIN_STAKE = _minStake;
        MAX_TOTAL_STAKE = _maxTotalStake;
        DURATION = _duration;
        REQUIRED_HOLDING_TOKEN = _requiredHoldingToken;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REWARDS_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_MANAGER_ROLE, _admin);
    }

    /*
    @dev Calculate reward
    @param amount The staked amount
    @return reward The calculated reward
    */
    function _calculateReward(uint256 amount) private view returns (uint256) {
        return (amount * REWARD_RATE) / 100;
    }

    /* 
    @dev Stake
    @param amount The amount of tokens to stake
    @notice The stake can only be staked if the amount is greater than the minimum stake
    @notice The stake can only be staked if the total staked amount is less than the maximum total stake
    @notice The stake's future reward is reserved from availableRewards so every accepted stake is claimable
    */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount < MIN_STAKE) revert MinStakeNotMet();
        if (totalStakedInPool + amount > MAX_POOL_STAKE) revert ExceedsMaxPoolStake();

        // reserve the reward so concurrent stakes cannot oversubscribe the pool
        uint256 reward = _calculateReward(amount);

        if (availableRewards < reward) {
            revert InsufficientRewardBalance();
        }
        availableRewards -= reward;

        // check if the user do not exceed the max total stake per user
        uint256 newTotal = totalStakedByUser[msg.sender] + amount;
        if (newTotal > MAX_TOTAL_STAKE) revert ExceedsMaxTotalStake();

        // check if the user has enough holding token
        uint256 balance = token.balanceOf(msg.sender);
        if (balance < REQUIRED_HOLDING_TOKEN) revert UnmetRequiredHoldingToken();

        // check if the user has enough balance
        if (balance < amount) revert InsufficientBalance();

        token.safeTransferFrom(msg.sender, address(this), amount);

        stakes[msg.sender].push(StakeInfo({amount: amount, start: block.timestamp, claimed: false, unstaked: false}));

        totalStakedInPool += amount;
        totalStakedByUser[msg.sender] = newTotal;

        emit Staked(msg.sender, amount);
    }

    /* 
    @dev Fund rewards
    @param amount The amount of tokens to fund rewards
    @notice Only owner can fund rewards
    @notice Requires sufficient allowance from owner to contract
    */
    function fundRewards(uint256 amount) external onlyRole(REWARDS_MANAGER_ROLE) whenNotPaused {
        token.safeTransferFrom(msg.sender, address(this), amount);
        availableRewards += amount;
        emit RewardsFunded(amount);
    }

    /* 
    @dev Claim
    @notice The stake can only be claimed if the stake has not been claimed
    @notice The stake can only be claimed if the stake has not been unstaked
    @notice The reward was reserved at stake time, so a matured stake is always claimable
    */
    function claim(uint256 index) external nonReentrant whenNotPaused {
        StakeInfo[] storage userStakes = stakes[msg.sender];
        if (index >= userStakes.length) revert NoStake();

        StakeInfo storage s = userStakes[index];
        if (s.claimed) revert AlreadyClaimed();
        if (s.unstaked) revert AlreadyUnstaked();
        if (block.timestamp < s.start + DURATION) revert TooEarly();

        uint256 reward = _calculateReward(s.amount);

        uint256 amountToTransfer = s.amount;
        s.amount = 0;
        s.claimed = true;
        totalStakedInPool -= amountToTransfer;
        totalStakedByUser[msg.sender] -= amountToTransfer;
        token.safeTransfer(msg.sender, amountToTransfer + reward);

        emit Claimed(msg.sender, amountToTransfer, reward);
    }

    /* 
    @dev Emergency withdraw
    @notice The owner can withdraw the tokens in case of emergency
    */
    function emergencyWithdraw() external onlyRole(EMERGENCY_MANAGER_ROLE) whenPaused {
        uint256 balance = token.balanceOf(address(this));
        availableRewards = 0;

        token.safeTransfer(msg.sender, balance);
        emit EmergencyWithdrawn(msg.sender, balance);
    }

    /* 
    @dev Update the unstake allowed status
    @param allowed The new unstake allowed status
    */
    function updateUnstakeAllowed(bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        unstakeAllowed = allowed;
        emit UnstakeAllowedUpdated(allowed);
    }

    /* 
    @dev Unstake
    @notice The stake can only be unstaked if the unstake is allowed
    @notice The stake can only be unstaked if the user has a stake
    @notice The stake can only be unstaked if the stake has not been claimed
    */
    function unstake(uint256 index) external nonReentrant whenNotPaused {
        StakeInfo[] storage userStakes = stakes[msg.sender];
        // check if the user has stake at the index
        if (index >= userStakes.length) revert NoStake();

        StakeInfo storage s = userStakes[index];
        if (!unstakeAllowed) revert UnstakeNotAllowed();
        if (s.claimed) revert AlreadyClaimed();
        if (s.unstaked) revert AlreadyUnstaked();

        uint256 returnAmount = s.amount;
        totalStakedInPool -= returnAmount;
        totalStakedByUser[msg.sender] -= returnAmount;
        s.amount = 0;
        s.unstaked = true;

        // the reward reserved at stake time is forfeited back to the pool
        availableRewards += _calculateReward(returnAmount);

        token.safeTransfer(msg.sender, returnAmount);

        emit Unstaked(msg.sender, returnAmount);
    }

    /* 
    @dev Get stake info
    @param user The address of the user to get the stake info for
    @return amount The amount of the stake
    @return start The start time of the stake
    @return claimed Whether the stake has been claimed
    @return unstaked Whether the stake has been unstaked
    @return timeLeft The remaining time of the stake in seconds
    @return potentialReward The potential reward of the stake
    */
    function getStakeInfo(address user, uint256 index)
        external
        view
        returns (
            uint256 amount,
            uint256 start,
            bool claimed,
            bool unstaked,
            uint256 timeLeft,
            uint256 potentialReward
        )
    {
        if (index >= stakes[user].length) revert NoStake();

        StakeInfo storage s = stakes[user][index];
        amount = s.amount;
        start = s.start;
        claimed = s.claimed;
        unstaked = s.unstaked;

        if (s.amount > 0 && !s.claimed && !s.unstaked) {
            if (block.timestamp < s.start + DURATION) {
                timeLeft = s.start + DURATION - block.timestamp;
            }
            potentialReward = _calculateReward(s.amount);
        }

        return (amount, start, claimed, unstaked, timeLeft, potentialReward);
    }

    /*
    @dev Number of stakes recorded for a user (including claimed/unstaked entries)
    @param user The address to query
    @return The length of the user's stakes array
    */
    function stakesCount(address user) external view returns (uint256) {
        return stakes[user].length;
    }

    /* 
    @dev Pause the contract
    @notice Only owner can pause the contract
    */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /* 
    @dev Unpause the contract
    @notice Only owner can unpause the contract
    */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* 
    @dev Update the maximum pool stake
    @param newMaxPoolStake The new maximum pool stake value
    @notice Only admin can update the maximum pool stake
    @notice The new value must be greater than 0
    @notice The new value must be greater than or equal to the current total staked
    */
    function updateMaxPoolStake(uint256 newMaxPoolStake) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newMaxPoolStake == 0) revert InvalidMaxPoolStake();
        if (newMaxPoolStake < totalStakedInPool) revert InvalidMaxPoolStake();
        
        uint256 oldValue = MAX_POOL_STAKE;
        MAX_POOL_STAKE = newMaxPoolStake;
        
        emit MaxPoolStakeUpdated(oldValue, newMaxPoolStake);
    }
}

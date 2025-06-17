// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {NODL} from "./NODL.sol";

contract Staking is AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant REWARDS_MANAGER_ROLE = keccak256("REWARDS_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_MANAGER_ROLE = keccak256("EMERGENCY_MANAGER_ROLE");
    uint256 private constant PRECISION = 1e18;

    NODL public immutable token;

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
    error AlreadyStaked();
    error NoStakeFound();
    error AlreadyClaimed();
    error TooEarly();
    error NoStake();
    error UnstakeNotAllowed();
    error InsufficientRewardBalance();
    error InsufficientAllowance();
    error InsufficientTotalStaked();
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
    @param _duration The duration of the stake, represented in days
    @param _admin The address of the admin
    */
    constructor(address nodlToken, uint256 _requiredHoldingToken, uint256 _rewardRate, uint256 _minStake, uint256 _maxTotalStake, uint256 _duration, address _admin) {
        if (nodlToken == address(0)) revert ZeroAddress();
        if (_rewardRate <= 0) revert InvalidRewardRate();
        if (_minStake == 0) revert InvalidMinStake();
        if (_maxTotalStake <= _minStake) revert InvalidMaxTotalStake();
        if (_duration == 0) revert InvalidDuration();
        if (_admin == address(0)) revert ZeroAddress();

        token = NODL(nodlToken);
        REWARD_RATE = _rewardRate;
        MIN_STAKE = _minStake;
        MAX_TOTAL_STAKE = _maxTotalStake;
        DURATION = _duration * 1 seconds;
        REQUIRED_HOLDING_TOKEN = _requiredHoldingToken;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REWARDS_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_MANAGER_ROLE, _admin);
    }

    /* 
    @dev Calculate reward with high precision
    @param amount The staked amount
    @return reward The calculated reward
    */
    function _calculateReward(uint256 amount) private view returns (uint256) {
        return (amount * REWARD_RATE * PRECISION) / (100 * PRECISION);
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
        if (totalStakedInPool + amount > MAX_POOL_STAKE) revert ExceedsMaxPoolStake();

        // check if the contract has enough balance to give rewards 
        uint256 reward = _calculateReward(amount);

        if (availableRewards < reward) {
            revert InsufficientRewardBalance();
        }

        // check if the user do not exceed the max total stake per user
        uint256 newTotal = totalStakedByUser[msg.sender] + amount;
        if (newTotal > MAX_TOTAL_STAKE) revert ExceedsMaxTotalStake();

        // check if the user has enough holding token
        uint256 balance = token.balanceOf(msg.sender);
        if (balance < REQUIRED_HOLDING_TOKEN) revert UnmetRequiredHoldingToken();

        // check if the user has enough balance
        if (balance < amount) revert InsufficientBalance();

        token.transferFrom(msg.sender, address(this), amount);

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
        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < amount) revert InsufficientAllowance();
        
        token.transferFrom(msg.sender, address(this), amount);
        availableRewards += amount;
        emit RewardsFunded(amount);
    }

    /* 
    @dev Claim
    @notice The stake can only be claimed if the stake has not been claimed
    @notice The stake can only be claimed if the stake has not been unstaked
    @notice The contract must have enough balance for both stake and reward
    */
    function claim(uint256 index) external nonReentrant whenNotPaused {
        StakeInfo[] storage userStakes = stakes[msg.sender];
        if (index >= userStakes.length) revert NoStake();

        StakeInfo storage s = userStakes[index];
        if (s.amount == 0) revert NoStakeFound();
        if (s.claimed) revert AlreadyClaimed();
        if (s.unstaked) revert AlreadyUnstaked();
        if (block.timestamp < s.start + DURATION) revert TooEarly();

        uint256 reward = _calculateReward(s.amount);
        if (availableRewards < reward) revert InsufficientRewardBalance();

        uint256 amountToTransfer = s.amount;
        s.amount = 0;
        s.claimed = true;
        totalStakedInPool -= amountToTransfer;
        totalStakedByUser[msg.sender] -= amountToTransfer;
        availableRewards -= reward;
        token.transfer(msg.sender, amountToTransfer + reward);

        emit Claimed(msg.sender, amountToTransfer, reward);
    }

    /* 
    @dev Emergency withdraw
    @notice The owner can withdraw the tokens in case of emergency
    */
    function emergencyWithdraw() external onlyRole(EMERGENCY_MANAGER_ROLE) {
        uint256 balance = token.balanceOf(address(this));
        availableRewards = 0;
        
        token.transfer(msg.sender, balance);
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
        if (s.amount == 0) revert NoStake();
        if (s.claimed) revert AlreadyClaimed();

        uint256 returnAmount = s.amount;
        totalStakedInPool -= returnAmount;
        totalStakedByUser[msg.sender] -= returnAmount;
        s.amount = 0;
        s.unstaked = true;

        token.transfer(msg.sender, returnAmount);

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
        StakeInfo[] memory userStakes = stakes[user];
        if (index >= userStakes.length) revert NoStake();

        StakeInfo memory s = userStakes[index];
        amount = s.amount;
        start = s.start;
        claimed = s.claimed;
        unstaked = s.unstaked;

        // remaining time in seconds
        if (s.amount > 0 && !s.claimed && !s.unstaked) {
            if (block.timestamp < s.start + DURATION) {
                timeLeft = s.start + DURATION - block.timestamp;
            }
        }

        // potential reward
        if (s.amount > 0 && !s.claimed && !s.unstaked) {
            potentialReward = _calculateReward(s.amount);
        }

        return (amount, start, claimed, unstaked, timeLeft, potentialReward);
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
        if (newMaxPoolStake <= 0) revert InvalidMaxPoolStake();
        if (newMaxPoolStake < totalStakedInPool) revert InvalidMaxPoolStake();
        
        uint256 oldValue = MAX_POOL_STAKE;
        MAX_POOL_STAKE = newMaxPoolStake;
        
        emit MaxPoolStakeUpdated(oldValue, newMaxPoolStake);
    }
}

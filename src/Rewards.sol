// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {NODL} from "./NODL.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title Nodle DePIN Rewards
 * @dev This contract allows an authorized oracle to issue off-chain signed rewards to recipients.
 * This contract must have the MINTER_ROLE in the NODL token contract.
 */
contract Rewards is AccessControl, EIP712 {
    using Math for uint256;

    /**
     * @dev The signing domain used for generating signatures.
     */
    string public constant SIGNING_DOMAIN = "rewards.depin.nodle";

    /**
     * @dev The version of the signature scheme used.
     */
    string public constant SIGNATURE_VERSION = "1";

    /**
     * @dev This constant defines the reward type.
     * This should be kept consistent with the Reward struct.
     */
    bytes32 public constant REWARD_TYPE_HASH = keccak256("Reward(address recipient,uint256 amount,uint256 sequence)");

    /**
     * @dev The maximum period for reward quota renewal. This is to prevent overflows while avoiding the ongoing overhead of safe math operations.
     */
    uint256 public constant MAX_PERIOD = 30 days;

    /**
     * @dev Reference to the NODL token contract.
     */
    NODL public nodlToken;

    /**
     * @dev Maximum amount of rewards that can be distributed in a period.
     */
    uint256 public rewardQuota;

    /**
     * @dev Duration of each reward period.
     */
    uint256 public rewardPeriod;

    /**
     * @dev Timestamp indicating when the reward quota is due to be renewed.
     */
    uint256 public quotaRenewalTimestamp;

    /**
     * @dev Amount of rewards claimed in the current period.
     */
    uint256 public rewardsClaimed;

    /**
     * @dev Address of the authorized oracle.
     */
    address public authorizedOracle;

    /**
     * @dev Mapping to store reward sequences for each recipient to prevent replay attacks.
     */
    mapping(address => uint256) public rewardSequences;

    /**
     * @dev Struct on which basis an individual reward must be issued.
     */
    struct Reward {
        address recipient;
        uint256 amount;
        uint256 sequence;
    }

    /**
     * @dev Error when the reward quota is exceeded.
     */
    error RewardQuotaExceeded();

    /**
     * @dev Error indicating the reward renewal period is set to zero which is not acceptable.
     */
    error ZeroPeriod();

    /**
     * @dev Error indicating that scheduling the reward quota renewal has failed most likley due to the period being too long.
     */
    error TooLongPeriod();

    /**
     * @dev Error when the reward is not from the authorized oracle.
     */
    error UnauthorizedOracle();

    /**
     * @dev Error when the recipient's reward sequence does not match.
     */
    error InvalidRecipientSequence();

    /**
     * @dev Event emitted when the reward quota is set.
     */
    event RewardQuotaSet(uint256 quota);

    /**
     * @dev Event emitted when a reward is minted.
     */
    event RewardMinted(address indexed recipient, uint256 amount, uint256 totalRewardsClaimed);

    /**
     * @dev Initializes the contract with the specified parameters.
     * @param token Address of the NODL token contract.
     * @param initialQuota Initial reward quota.
     * @param initialPeriod Initial reward period.
     * @param oracleAddress Address of the authorized oracle.
     */
    constructor(NODL token, uint256 initialQuota, uint256 initialPeriod, address oracleAddress)
        EIP712(SIGNING_DOMAIN, SIGNATURE_VERSION)
    {
        // This is to avoid the ongoinb overhead of safe math operations
        if (initialPeriod == 0) {
            revert ZeroPeriod();
        }
        // This is to prevent overflows while avoiding the ongoing overhead of safe math operations
        if (initialPeriod > MAX_PERIOD) {
            revert TooLongPeriod();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        nodlToken = token;
        rewardQuota = initialQuota;
        rewardPeriod = initialPeriod;
        quotaRenewalTimestamp = block.timestamp + rewardPeriod;
        authorizedOracle = oracleAddress;
    }

    /**
     * @dev Sets the reward quota. Only accounts with the QUOTA_SETTER_ROLE can call this function.
     * @param newQuota The new reward quota.
     */
    function setRewardQuota(uint256 newQuota) external {
        _checkRole(DEFAULT_ADMIN_ROLE);
        rewardQuota = newQuota;
        emit RewardQuotaSet(newQuota);
    }

    /**
     * @dev Mints rewards to the recipient if the signature is valid and quota is not exceeded.
     * @param reward The reward details.
     * @param signature The signature from the authorized oracle.
     */
    function mintReward(Reward memory reward, bytes memory signature) external {
        _mustBeFromAuthorizedOracle(digestReward(reward), signature);

        _mustBeExpectedSequence(reward.recipient, reward.sequence);

        if (block.timestamp >= quotaRenewalTimestamp) {
            rewardsClaimed = 0;

            // The following operations are safe based on the constructor's requirements for longer than the age of universe :)
            uint256 timeAhead = block.timestamp - quotaRenewalTimestamp;
            quotaRenewalTimestamp = block.timestamp + rewardPeriod - (timeAhead % rewardPeriod);
        }

        (bool sucess, uint256 newRewardsClaimed) = rewardsClaimed.tryAdd(reward.amount);
        if (!sucess || newRewardsClaimed > rewardQuota) {
            revert RewardQuotaExceeded();
        }
        rewardsClaimed = newRewardsClaimed;

        // Safe to increment the sequence after checking this is the expected number (no overflow for the age of universe even with 1000 reward claims per second)
        rewardSequences[reward.recipient] = reward.sequence + 1;

        nodlToken.mint(reward.recipient, reward.amount);

        emit RewardMinted(reward.recipient, reward.amount, rewardsClaimed);
    }

    /**
     * @dev Internal check to ensure the `sequence` value is expected for `receipent`.
     * @param receipent The address of the receipent to check.
     * @param sequence The sequence value.
     */
    function _mustBeExpectedSequence(address receipent, uint256 sequence) internal view {
        if (rewardSequences[receipent] != sequence) {
            revert InvalidRecipientSequence();
        }
    }

    /**
     * @dev Checks if the provided signature is valid for the given hash and authorized oracle address.
     * @param hash The hash to be verified.
     * @param signature The signature to be checked.
     * @dev Throws an `UnauthorizedOracle` exception if the signature is not valid.
     */
    function _mustBeFromAuthorizedOracle(bytes32 hash, bytes memory signature) internal view {
        if (!SignatureChecker.isValidSignatureNow(authorizedOracle, hash, signature)) {
            revert UnauthorizedOracle();
        }
    }

    /**
     * @dev Helper function to get the digest of the typed data to be signed.
     * @param reward detailing recipient, amount, and sequence.
     * @return The hash of the typed data.
     */
    function digestReward(Reward memory reward) public view returns (bytes32) {
        return
            _hashTypedDataV4(keccak256(abi.encode(REWARD_TYPE_HASH, reward.recipient, reward.amount, reward.sequence)));
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {NODL} from "./NODL.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
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
     * @dev The hash of the reward type structure.
     * It is calculated using the keccak256 hash function.
     * The structure consists of the recipient's address, the amount of the reward, and the sequence number for that receipent.
     */
    bytes32 public constant REWARD_TYPE_HASH = keccak256("Reward(address recipient,uint256 amount,uint256 sequence)");
    /**
     * @dev The hash of the batch reward type.
     * It is calculated by taking the keccak256 hash of the string representation of the batch reward type.
     * The batch reward type consists of the recipients, amounts, and sequence of that batch.
     */
    bytes32 public constant BATCH_REWARD_TYPE_HASH =
        keccak256("BatchReward(bytes32 recipientsHash,bytes32 amountsHash,uint256 sequence)");
    /**
     * @dev The maximum period for reward quota renewal. This is to prevent overflows while avoiding the ongoing overhead of safe math operations.
     */
    uint256 public constant MAX_PERIOD = 30 days;

    /**
     * @dev Struct on which basis an individual reward must be issued.
     */
    struct Reward {
        address recipient;
        uint256 amount;
        uint256 sequence;
    }

    /**
     * @dev Represents a batch reward distribution.
     * Each batch reward consists of an array of recipients, an array of corresponding amounts,
     * and a sequence number to avoid replay attacks.
     */
    struct BatchReward {
        address[] recipients;
        uint256[] amounts;
        uint256 sequence;
    }

    /**
     * @dev Reference to the NODL token contract.
     */
    NODL public immutable nodl;
    /**
     * @dev Address of the authorized oracle.
     */
    address public immutable authorizedOracle;
    /**
     * @dev Reward quota renewal period.
     */
    uint256 public immutable period;

    /**
     * @dev Maximum amount of rewards that can be distributed in a period.
     */
    uint256 public quota;
    /**
     * @dev Timestamp indicating when the reward quota is due to be renewed.
     */
    uint256 public quotaRenewalTimestamp;
    /**
     * @dev Amount of rewards claimed in the current period.
     */
    uint256 public claimed;
    /**
     * @dev Mapping to store reward sequences for each recipient to prevent replay attacks.
     */
    mapping(address => uint256) public sequences;
    /**
     * @dev The sequence number of the batch reward.
     */
    uint256 public batchSequence;
    /**
     * @dev Represents the latest batch reward digest.
     */
    bytes32 public latestBatchRewardDigest;
    /**
     * @dev Determines the amount of rewards to be minted for the submitter of batch as a percentage of total rewards in that batch.
     * This value indicates the cost overhead of minting rewards that the network is happy to take. Though it is set to 2% by default,
     * the governance can change it to ensure the network is sustainable.
     */
    uint8 public batchSubmitterRewardPercentage;

    /**
     * @dev Error when the reward quota is exceeded.
     */
    error QuotaExceeded();
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
     * @dev Error thrown when an invalid batch sequence is encountered.
     */
    error InvalidBatchSequence();
    /**
     * @dev Throws an error if the batch structure is invalid.
     * The recipient and amounts arrays must have the same length.
     */
    error InvalidBatchStructure();
    /**
     * @dev Error thrown when the value is out of range. For example for Percentage values should be less than 100.
     */
    error OutOfRangeValue();

    /**
     * @dev Event emitted when the reward quota is set.
     */
    event QuotaSet(uint256 quota);
    /**
     * @dev Event emitted when a reward is minted.
     */
    event Minted(address indexed recipient, uint256 amount, uint256 totalRewardsClaimed);
    /**
     * @dev Emitted when a batch reward is minted.
     * @param batchSum The sum of rewards in the batch.
     * @param totalRewardsClaimed The total number of rewards claimed so far.
     */
    event BatchMinted(uint256 batchSum, uint256 totalRewardsClaimed, bytes32 digest);

    /**
     * @dev Initializes the contract with the specified parameters.
     * @param token Address of the NODL token contract.
     * @param initialQuota Initial reward quota.
     * @param initialPeriod Initial reward period.
     * @param oracleAddress Address of the authorized oracle.
     */
    constructor(NODL token, uint256 initialQuota, uint256 initialPeriod, address oracleAddress, uint8 rewardPercentage)
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

        _mustBeLessThan100(rewardPercentage);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        nodl = token;
        quota = initialQuota;
        period = initialPeriod;
        quotaRenewalTimestamp = block.timestamp + period;
        authorizedOracle = oracleAddress;
        batchSubmitterRewardPercentage = rewardPercentage;
    }

    /**
     * @dev Sets the reward quota. Only accounts with the DEFAULT_ADMIN_ROLE can call this function.
     * @param newQuota The new reward quota.
     */
    function setQuota(uint256 newQuota) external {
        _checkRole(DEFAULT_ADMIN_ROLE);
        quota = newQuota;
        emit QuotaSet(newQuota);
    }

    /**
     * @dev Mints rewards to the recipient if the signature is valid and quota is not exceeded.
     * @param reward The reward details.
     * @param signature The signature from the authorized oracle.
     */
    function mintReward(Reward memory reward, bytes memory signature) external {
        _mustBeExpectedSequence(reward.recipient, reward.sequence);
        _mustBeFromAuthorizedOracle(digestReward(reward), signature);

        _checkedUpdateQuota();
        _checkedUpdateClaimed(reward.amount);

        // Safe to increment the sequence after checking this is the expected number (no overflow for the age of universe even with 1000 reward claims per second)
        sequences[reward.recipient] = reward.sequence + 1;
        nodl.mint(reward.recipient, reward.amount);

        emit Minted(reward.recipient, reward.amount, claimed);
    }

    /**
     * @dev Mints batch rewards to multiple recipients.
     * @param batch The BatchReward struct containing the recipients and amounts of rewards to be minted.
     * @param signature The signature to verify the authenticity of the batch reward.
     */
    function mintBatchReward(BatchReward memory batch, bytes memory signature) external {
        _mustBeValidBatchStructure(batch);
        _mustBeExpectedBatchSequence(batch.sequence);

        bytes32 digest = digestBatchReward(batch);

        _mustBeFromAuthorizedOracle(digest, signature);

        _checkedUpdateQuota();

        uint256 batchSum = _batchSum(batch);
        uint256 submitterRewardAmount = (batchSum * batchSubmitterRewardPercentage) / 100;

        _checkedUpdateClaimed(batchSum + submitterRewardAmount);

        // Safe to increment the sequence after checking this is the expected number (no overflow for the age of universe even with 1000 reward claims per second)
        batchSequence = batch.sequence + 1;

        latestBatchRewardDigest = digest;

        for (uint256 i = 0; i < batch.recipients.length; i++) {
            nodl.mint(batch.recipients[i], batch.amounts[i]);
        }
        nodl.mint(msg.sender, submitterRewardAmount);

        emit BatchMinted(batchSum, claimed, digest);
    }

    /**
     * @dev Sets the reward percentage for the batch submitter.
     * @param newPercentage The new reward percentage to be set.
     * Requirements:
     * - Caller must have the DEFAULT_ADMIN_ROLE.
     * - The new reward percentage must be less than 100.
     */
    function setBatchSubmitterRewardPercentage(uint8 newPercentage) external {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _mustBeLessThan100(newPercentage);
        batchSubmitterRewardPercentage = newPercentage;
    }

    /**
     * @dev Internal function to update the rewards quota if the current block timestamp is greater than or equal to the quota renewal timestamp.
     * @notice This function resets the rewards claimed to 0 and updates the quota renewal timestamp based on the reward period.
     * @notice The following operations are safe based on the constructor's requirements for longer than the age of the universe.
     */
    function _checkedUpdateQuota() internal {
        if (block.timestamp >= quotaRenewalTimestamp) {
            claimed = 0;

            // The following operations are safe based on the constructor's requirements for longer than the age of universe :)
            uint256 timeAhead = block.timestamp - quotaRenewalTimestamp;
            quotaRenewalTimestamp = block.timestamp + period - (timeAhead % period);
        }
    }

    /**
     * @dev Internal function to update the rewards claimed by a given amount.
     * @param amount The amount of rewards to be added.
     * @notice This function is used to update the rewards claimed by a user. It checks if the new rewards claimed
     * exceeds the reward quota and reverts the transaction if it does. Otherwise, it updates the rewards claimed
     * by adding the specified amount.
     */
    function _checkedUpdateClaimed(uint256 amount) internal {
        (bool success, uint256 newClaimed) = claimed.tryAdd(amount);
        if (!success || newClaimed > quota) {
            revert QuotaExceeded();
        }
        claimed = newClaimed;
    }

    /**
     * @dev Checks if the given percentage value is less than or equal to 100.
     * @param percent The percentage value to check.
     * @dev Throws an exception if the value is greater than 100.
     */
    function _mustBeLessThan100(uint8 percent) internal pure {
        if (percent > 100) {
            revert OutOfRangeValue();
        }
    }

    /**
     * @dev Internal check to ensure the `sequence` value is expected for `receipent`.
     * @param receipent The address of the receipent to check.
     * @param sequence The sequence value.
     */
    function _mustBeExpectedSequence(address receipent, uint256 sequence) internal view {
        if (sequences[receipent] != sequence) {
            revert InvalidRecipientSequence();
        }
    }

    /**
     * @dev Internal checks to ensure the given sequence is expected for the batch.
     * @param sequence The sequence to be checked.
     */
    function _mustBeExpectedBatchSequence(uint256 sequence) internal view {
        if (batchSequence != sequence) {
            revert InvalidBatchSequence();
        }
    }

    /**
     * @dev Internal check to ensure the given batch reward structure is valid, meaning same number of recipients and amounts.
     * @param batch The batch reward structure to be validated.
     */
    function _mustBeValidBatchStructure(BatchReward memory batch) internal pure {
        if (batch.recipients.length != batch.amounts.length) {
            revert InvalidBatchStructure();
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
     * @dev Calculates the sum of amounts in a BatchReward struct.
     * @param batch The BatchReward struct containing the amounts to be summed.
     * @return The sum of all amounts in the batch.
     */
    function _batchSum(BatchReward memory batch) internal pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < batch.amounts.length; i++) {
            sum += batch.amounts[i];
        }
        return sum;
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

    /**
     * @dev Calculates the digest of a BatchReward struct.
     * @param batch The BatchReward struct containing the recipients, amounts, and sequence.
     * @return The digest of the BatchReward struct.
     */
    function digestBatchReward(BatchReward memory batch) public view returns (bytes32) {
        bytes32 receipentsHash = keccak256(abi.encodePacked(batch.recipients));
        bytes32 amountsHash = keccak256(abi.encodePacked(batch.amounts));
        return
            _hashTypedDataV4(keccak256(abi.encode(BATCH_REWARD_TYPE_HASH, receipentsHash, amountsHash, batch.sequence)));
    }

    /**
     * @dev Returns the latest batch details.
     * @return The next batch sequence and the latest digest of a successfully submitted batch which must have been for batchSequence - 1.
     */
    function latestBatchDetails() external view returns (uint256, bytes32) {
        return (batchSequence, latestBatchRewardDigest);
    }
}

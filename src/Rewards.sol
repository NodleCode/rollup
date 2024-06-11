// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {NODL} from "./NODL.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title Nodle DePIN Rewards
 * @dev This contract allows an authorized oracle to issue off-chain signed rewards to recipients.
 * This contract must have the MINTER_ROLE in the NODL token contract.
 */
contract Rewards is AccessControl, EIP712 {
    /**
     * @dev Role required to set the reward quota.
     */
    bytes32 public constant QUOTA_SETTER_ROLE = keccak256("QUOTA_SETTER_ROLE");

    /**
     * @dev The signing domain used for generating signatures.
     */
    string private constant SIGNING_DOMAIN = "rewards.depin.nodle";

    /**
     * @dev The version of the signature scheme used.
     */
    string private constant SIGNATURE_VERSION = "1";

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
     * @dev Mapping to store reward counters for each recipient to prevent replay attacks.
     */
    mapping(address => uint256) public rewardCounters;

    /**
     * @dev Struct on which basis an individual reward must be issued.
     */
    struct Reward {
        address recipient;
        uint256 amount;
        uint256 counter;
    }

    /**
     * @dev Error when the reward quota is exceeded.
     */
    error RewardQuotaExceeded();

    /**
     * @dev Error when the reward is not from the authorized oracle.
     */
    error UnauthorizedOracle();

    /**
     * @dev Error when the recipient's counter does not match.
     */
    error InvalidRecipientCounter();

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
     * @param nodlTokenAddress Address of the NODL token contract.
     * @param initialQuota Initial reward quota.
     * @param initialPeriod Initial reward period.
     * @param oracleAddress Address of the authorized oracle.
     */
    constructor(address nodlTokenAddress, uint256 initialQuota, uint256 initialPeriod, address oracleAddress)
        EIP712(SIGNING_DOMAIN, SIGNATURE_VERSION)
    {
        nodlToken = NODL(nodlTokenAddress);
        rewardQuota = initialQuota;
        rewardPeriod = initialPeriod;
        rewardsClaimed = 0;
        quotaRenewalTimestamp = block.timestamp + rewardPeriod;
        authorizedOracle = oracleAddress;
    }

    /**
     * @dev Sets the reward quota. Only accounts with the QUOTA_SETTER_ROLE can call this function.
     * @param newQuota The new reward quota.
     */
    function setRewardQuota(uint256 newQuota) external {
        _checkRole(QUOTA_SETTER_ROLE);
        rewardQuota = newQuota;
        emit RewardQuotaSet(newQuota);
    }

    /**
     * @dev Mints rewards to the recipient if the signature is valid and quota is not exceeded.
     * @param reward The reward details.
     * @param signature The signature from the authorized oracle.
     */
    function mintReward(Reward memory reward, bytes memory signature) external {
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    keccak256("Reward(address recipient,uint256 amount,uint256 counter)"),
                    reward.recipient,
                    reward.amount,
                    reward.counter
                )
            )
        );
        address signer = ECDSA.recover(digest, signature);

        if (signer != authorizedOracle) {
            revert UnauthorizedOracle();
        }

        if (rewardCounters[reward.recipient] != reward.counter) {
            revert InvalidRecipientCounter();
        }

        if (block.timestamp > quotaRenewalTimestamp) {
            rewardsClaimed = 0;
            quotaRenewalTimestamp = block.timestamp + rewardPeriod;
        }

        if (rewardsClaimed + reward.amount > rewardQuota) {
            revert RewardQuotaExceeded();
        }

        nodlToken.mint(reward.recipient, reward.amount);

        rewardsClaimed += reward.amount;
        rewardCounters[reward.recipient] = reward.counter + 1;

        emit RewardMinted(reward.recipient, reward.amount, rewardsClaimed);
    }
}

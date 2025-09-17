// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {L1Nodl} from "../L1Nodl.sol";
// Use local submodule paths instead of unavailable @zksync package imports
import {IMailbox} from "lib/era-contracts/l1-contracts/contracts/state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "lib/era-contracts/l1-contracts/contracts/common/Messaging.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {UnsafeBytes} from "lib/era-contracts/l1-contracts/contracts/common/libraries/UnsafeBytes.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IL1Bridge} from "./interfaces/IL1Bridge.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IWithdrawalMessage} from "./interfaces/IWithdrawalMessage.sol";

/**
 * @title L1Bridge
 * @notice L1 endpoint of the NODL token bridge for zkSync Era.
 * @dev Responsibilities:
 *  - Initiate deposits by enqueuing an L2 call to the counterpart L2 bridge through the Mailbox.
 *  - Track deposit tx hashes to enable refunds if an L2 transaction fails.
 *  - Finalize L2→L1 withdrawals by verifying message inclusion and minting on L1.
 *  - Secured with Ownable (admin), Pausable (circuit breaker).
 */
contract L1Bridge is Ownable2Step, Pausable, IL1Bridge {
    // =============================
    // State
    // =============================

    /// @notice The zkSync Era Mailbox contract on L1 (Diamond proxy).
    IMailbox public immutable L1_MAILBOX;

    /// @notice The L1 NODL token instance.
    L1Nodl public immutable L1_NODL;

    /// @notice The counterpart bridge address deployed on L2.
    address public immutable L2_BRIDGE_ADDR;

    /// @notice Per-account mapping of deposit L2 tx hash to deposited amount.
    mapping(address account => mapping(bytes32 depositL2TxHash => uint256 amount)) public depositAmount;

    /// @notice Tracks whether an L2→L1 message was already finalized to prevent replays.
    mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)) public
        isWithdrawalFinalized;

    // =============================
    // Errors
    // =============================

    /// @dev Zero address supplied where non-zero is required.
    error ZeroAddress();
    /// @dev Amount must be greater than zero.
    error ZeroAmount();
    /// @dev Unknown deposit tx hash for the provided sender.
    error UnknownTxHash();
    /// @dev Proving a failed L2 tx status did not succeed.
    error L2FailureProofFailed();
    /// @dev Proving inclusion of an L2→L1 message did not succeed.
    error InvalidProof();
    /// @dev Withdrawal message length is invalid.
    error L2WithdrawalMessageWrongLength(uint256 length);
    /// @dev Function selector inside the L2 message is invalid.
    error InvalidSelector(bytes4 sel);
    /// @dev Withdrawal for the given (batch, index) has already been finalized.
    error WithdrawalAlreadyFinalized();

    // =============================
    // Constructor
    // =============================

    /**
     * @notice Initializes the bridge with the system Mailbox, token, and L2 bridge addresses.
     * @param _owner The admin address for Ownable controls.
     * @param _l1Mailbox The L1 Mailbox (zkSync Era) proxy address.
     * @param _l1Token The L1 NODL token address.
     * @param _l2Bridge The L2 bridge contract address.
     */
    constructor(address _owner, address _l1Mailbox, address _l1Token, address _l2Bridge) Ownable(_owner) {
        if (_l1Mailbox == address(0) || _l1Token == address(0) || _l2Bridge == address(0)) {
            revert ZeroAddress();
        }
        L1_MAILBOX = IMailbox(_l1Mailbox);
        L1_NODL = L1Nodl(_l1Token);
        L2_BRIDGE_ADDR = _l2Bridge;
    }

    // =============================
    // Admin
    // =============================

    /// @notice Pause state-changing entrypoints guarded by whenNotPaused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract to resume normal operations.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =============================
    // View helpers
    // =============================

    /**
     * @notice Quotes the ETH required to cover the L2 execution cost for a deposit at the current tx.gasprice.
     * @dev This is a convenience helper; the actual base cost is a function of the L1 gas price at inclusion time.
     *      Frontends may prefer {quoteL2BaseCostAtGasPrice} for deterministic quoting.
     * @param _l2TxGasLimit Maximum L2 gas the enqueued call can consume.
     * @param _l2TxGasPerPubdataByte Gas per pubdata byte limit for the enqueued call.
     * @return baseCost The ETH amount that needs to be supplied alongside {deposit}.
     */
    function quoteL2BaseCost(uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte)
        external
        view
        returns (uint256 baseCost)
    {
        baseCost = L1_MAILBOX.l2TransactionBaseCost(tx.gasprice, _l2TxGasLimit, _l2TxGasPerPubdataByte);
    }

    /**
     * @notice Quotes the ETH required to cover the L2 execution cost for a deposit at a specified L1 gas price.
     * @param _l1GasPrice The L1 gas price (wei) to use for the quote.
     * @param _l2TxGasLimit Maximum L2 gas the enqueued call can consume.
     * @param _l2TxGasPerPubdataByte Gas per pubdata byte limit for the enqueued call.
     * @return baseCost The ETH amount that needs to be supplied alongside {deposit}.
     */
    function quoteL2BaseCostAtGasPrice(uint256 _l1GasPrice, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte)
        external
        view
        returns (uint256 baseCost)
    {
        baseCost = L1_MAILBOX.l2TransactionBaseCost(_l1GasPrice, _l2TxGasLimit, _l2TxGasPerPubdataByte);
    }

    // =============================
    // External entrypoints
    // =============================

    /**
     * @notice Initiates a deposit by burning on L1 and enqueuing an L2 finalizeDeposit call.
     * @dev Caller must approve/burnable rights on the NODL token and provide msg.value to cover Mailbox costs.
     * @param _l2Receiver The L2 address to receive the bridged tokens.
     * @param _amount The amount of tokens to bridge.
     * @param _l2TxGasLimit Gas limit for the L2 call.
     * @param _l2TxGasPerPubdataByte Gas per pubdata byte for the L2 call.
     * @param _refundRecipient Address receiving any ETH refund from the Mailbox.
     * @return txHash The L2 transaction hash of the enqueued call.
     */
    function deposit(
        address _l2Receiver,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable override whenNotPaused returns (bytes32 txHash) {
        if (_amount == 0) {
            revert ZeroAmount();
        }

        L1_NODL.burnFrom(msg.sender, _amount);

        bytes memory l2Calldata = abi.encodeCall(IL2Bridge.finalizeDeposit, (msg.sender, _l2Receiver, _amount));
        address refundRecipient = _refundRecipient != address(0) ? _refundRecipient : msg.sender;

        txHash = L1_MAILBOX.requestL2Transaction{value: msg.value}(
            L2_BRIDGE_ADDR, 0, l2Calldata, _l2TxGasLimit, _l2TxGasPerPubdataByte, new bytes[](0), refundRecipient
        );

        depositAmount[msg.sender][txHash] = _amount;

        emit DepositInitiated(txHash, msg.sender, _l2Receiver, _amount);
    }

    /**
     * @notice Convenience overload of {deposit} with refund recipient defaulting to msg.sender.
     */
    function deposit(address _l2Receiver, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte)
        external
        payable
        override
        returns (bytes32 txHash)
    {
        return deposit(_l2Receiver, _amount, _l2TxGasLimit, _l2TxGasPerPubdataByte, msg.sender);
    }

    /**
     * @notice Refunds a failed deposit after proving the L2 tx failure via the Mailbox.
     * @dev Clears the recorded deposit amount for the given sender and tx hash, then mints back on L1.
     * @param _l1Sender The original depositor on L1.
     * @param _l2TxHash The L2 tx hash of the failed deposit request.
     * @param _l2BatchNumber The batch number containing the failed tx.
     * @param _l2MessageIndex The index of the message within the batch.
     * @param _l2TxNumberInBatch The transaction number in the batch.
     * @param _merkleProof The Merkle proof proving Failure status.
     */
    function claimFailedDeposit(
        address _l1Sender,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override whenNotPaused {
        uint256 amount = depositAmount[_l1Sender][_l2TxHash];
        if (amount == 0) {
            revert UnknownTxHash();
        }
        bool success = L1_MAILBOX.proveL1ToL2TransactionStatus(
            _l2TxHash, _l2BatchNumber, _l2MessageIndex, _l2TxNumberInBatch, _merkleProof, TxStatus.Failure
        );
        if (!success) {
            revert L2FailureProofFailed();
        }
        delete depositAmount[_l1Sender][_l2TxHash];
        L1_NODL.mint(_l1Sender, amount);
        emit ClaimedFailedDeposit(_l1Sender, amount);
    }

    /**
     * @notice Finalizes a withdrawal from L2 after proving message inclusion.
     * @dev Parses the message payload, verifies inclusion via Mailbox and mints on L1.
     * @param _l2BatchNumber The L2 batch number containing the message.
     * @param _l2MessageIndex The index of the message within the batch.
     * @param _l2TxNumberInBatch The transaction number in the batch.
     * @param _message ABI-encoded call data expected by the L1 bridge (finalizeWithdrawal).
     * @param _merkleProof The Merkle proof for message inclusion.
     */
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override whenNotPaused {
        if (isWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex]) {
            revert WithdrawalAlreadyFinalized();
        }
        isWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex] = true;

        (address l1Receiver, uint256 amount) = _parseL2WithdrawalMessage(_message);
        L2Message memory l2ToL1Message =
            L2Message({txNumberInBatch: _l2TxNumberInBatch, sender: L2_BRIDGE_ADDR, data: _message});

        bool success = L1_MAILBOX.proveL2MessageInclusion({
            _batchNumber: _l2BatchNumber,
            _index: _l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _merkleProof
        });
        if (!success) {
            revert InvalidProof();
        }
        L1_NODL.mint(l1Receiver, amount);
        emit WithdrawalFinalized(l1Receiver, _l2BatchNumber, _l2MessageIndex, _l2TxNumberInBatch, amount);
    }

    // =============================
    // Internal helpers
    // =============================

    /**
     * @notice Parses and validates the L2→L1 message payload for finalizeWithdrawal.
     * @dev Ensures selector matches IWithdrawalMessage.finalizeWithdrawal and reads (receiver, amount).
     * @param _l2ToL1message The raw message bytes.
     * @return l1Receiver The L1 receiver extracted from the message.
     * @return amount The token amount extracted from the message.
     */
    function _parseL2WithdrawalMessage(bytes memory _l2ToL1message)
        internal
        pure
        returns (address l1Receiver, uint256 amount)
    {
        // Require exactly 56 bytes: selector (4) + address (20) + uint256 (32)
        if (_l2ToL1message.length != 56) {
            revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
        }

        // Decode first 56 bytes only; ignore any trailing data
        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) != IWithdrawalMessage.finalizeWithdrawal.selector) {
            revert InvalidSelector(bytes4(functionSignature));
        }
        (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
    }
}

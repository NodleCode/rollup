// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

/**
 * @title IL1Bridge
 * @notice Interface for the L1 side of the custom token bridge.
 * @dev Declares events and entrypoints used by clients and off-chain relayers
 *      to initiate deposits to L2, claim failed deposits, and finalize L2→L1 withdrawals.
 */
interface IL1Bridge {
    /**
     * @notice Emitted when a deposit to L2 is initiated via the zkSync Mailbox.
     * @param l2DepositTxHash The L2 transaction hash returned by the Mailbox for the enqueued L2 call.
     * @param from The L1 sender who initiated the deposit.
     * @param to The L2 receiver that will receive/mint tokens on L2.
     * @param amount The token amount bridged.
     */
    event DepositInitiated(bytes32 indexed l2DepositTxHash, address indexed from, address indexed to, uint256 amount);

    /**
     * @notice Emitted when an L2 withdrawal is proven and finalized on L1.
     * @param to The L1 receiver of the tokens.
     * @param batchNumber The L2 batch number containing the withdrawal message.
     * @param messageIndex The index of the message within the batch.
     * @param txNumberInBatch The tx number in batch (for proof construction).
     * @param amount The amount released/minted on L1.
     */
    event WithdrawalFinalized(
        address indexed to,
        uint256 indexed batchNumber,
        uint256 indexed messageIndex,
        uint16 txNumberInBatch,
        uint256 amount
    );

    /**
     * @notice Emitted when a failed deposit is proven and refunded on L1.
     * @param to The L1 account that receives the refund.
     * @param amount The amount refunded on L1.
     */
    event ClaimedFailedDeposit(address indexed to, uint256 indexed amount);

    /**
     * @notice Returns whether a particular L2→L1 message (by batch and message index) has been finalized.
     * @param _l2BatchNumber The L2 batch number containing the message.
     * @param _l2MessageIndex The index of the message within the batch.
     */
    function isWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool);

    /**
     * @notice Initiates a token deposit to L2 by enqueuing a call to the L2 bridge.
     * @dev The caller must send sufficient ETH in msg.value to cover the Mailbox base cost.
     *      Any excess will be refunded to `_refundRecipient`.
     * @param _l2Receiver The L2 address that will receive the bridged tokens.
     * @param _amount The token amount to bridge.
     * @param _l2TxGasLimit The L2 gas limit for the enqueued transaction.
     * @param _l2TxGasPerPubdataByte The gas per pubdata byte parameter for the L2 tx.
     * @param _refundRecipient The L1 address to receive any ETH refund from the Mailbox.
     * @return txHash The L2 transaction hash returned by the Mailbox.
     */
    function deposit(
        address _l2Receiver,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 txHash);

    /**
     * @notice Convenience overload of {deposit} that defaults the refund recipient to msg.sender.
     */
    function deposit(address _l2Receiver, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte)
        external
        payable
        returns (bytes32 txHash);

    /**
     * @notice Claims a failed deposit after proving the L2 transaction failed.
     * @dev On success, the original depositor is refunded on L1 and the deposit accounting entry is cleared.
     * @param _l1Sender The original L1 depositor.
     * @param _l2TxHash The L2 tx hash that was enqueued for the deposit.
     * @param _l2BatchNumber The batch number where the L2 tx was executed.
     * @param _l2MessageIndex The index of the corresponding message in the batch.
     * @param _l2TxNumberInBatch The tx number in batch (for proof construction).
     * @param _merkleProof The Merkle proof for the L2 status.
     */
    function claimFailedDeposit(
        address _l1Sender,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external;

    /**
     * @notice Finalizes an L2→L1 withdrawal after proving message inclusion in a finalized L2 batch.
     * @param _l2BatchNumber The L2 batch number containing the message.
     * @param _l2MessageIndex The index of the message within the batch.
     * @param _l2TxNumberInBatch The tx number in the batch for the message struct.
     * @param _message The ABI-encoded L2 message payload expected by the L1 bridge.
     * @param _merkleProof The Merkle proof for message inclusion.
     */
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;
}

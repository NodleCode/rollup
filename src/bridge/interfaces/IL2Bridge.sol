// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

/**
 * @title IL2Bridge
 * @notice Interface for the L2 side of the NODL token bridge.
 * @dev The L2 bridge mints on finalized deposits from L1 and burns on withdrawals to L1.
 */
interface IL2Bridge {
    /**
     * @notice Emitted when a deposit from L1 is finalized on L2.
     * @param l1Sender The original L1 address that initiated the deposit.
     * @param l2Receiver The L2 address that received minted tokens.
     * @param amount The amount minted on L2.
     */
    event DepositFinalized(address indexed l1Sender, address indexed l2Receiver, uint256 amount);

    /**
     * @notice Emitted when a withdrawal from L2 to L1 is initiated.
     * @param l2Sender The L2 address that burned tokens to withdraw.
     * @param l1Receiver The L1 address that will receive tokens upon finalization.
     * @param amount The amount withdrawn.
     */
    event WithdrawalInitiated(address indexed l2Sender, address indexed l1Receiver, uint256 amount);

    /**
     * @notice Finalizes a deposit initiated on L1.
     * @dev Called by the system through the Mailbox-enqueued transaction.
     * @param _l1Sender The original L1 sender who deposited tokens.
     * @param _l2Receiver The L2 recipient of the bridged tokens.
     * @param _amount The token amount to credit on L2.
     */
    function finalizeDeposit(address _l1Sender, address _l2Receiver, uint256 _amount) external;

    /**
     * @notice Initiates a withdrawal from L2 to L1 by burning tokens and sending a message to L1.
     * @param _l1Receiver The L1 address that will receive tokens upon finalization on L1.
     * @param _amount The token amount to withdraw.
     */
    function withdraw(address _l1Receiver, uint256 _amount) external;
}

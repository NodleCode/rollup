// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

/**
 * @title IWithdrawalMessage
 * @notice Canonical L2→L1 message schema used by the bridge for withdrawals.
 * @dev The selector of this function and its ABI-encoded packed arguments
 *      are used as the payload sent from L2 and verified/decoded on L1.
 *      The message is encoded as:
 *        abi.encodePacked(finalizeWithdrawal.selector, _l1Receiver, _amount)
 *      which yields 56 bytes: 4 (selector) + 20 (address) + 32 (uint256).
 */
interface IWithdrawalMessage {
    /**
     * @notice Template function solely used for its selector and ABI schema.
     * @param _l1Receiver The L1 recipient of withdrawn tokens.
     * @param _amount The amount withdrawn.
     */
    function finalizeWithdrawal(address _l1Receiver, uint256 _amount) external;
}

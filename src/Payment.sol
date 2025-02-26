// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {QuotaControl} from "./QuotaControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Payment Contract
 * @dev A contract that enables secure payments and withdrawals using ERC20 tokens.
 *      The contract is controlled by an Oracle role and incorporates quota control
 *      to manage payments within a specified limit.
 *
 * Inherits from `QuotaControl` to manage payment quotas.
 */
contract Payment is QuotaControl {
    using SafeERC20 for IERC20;

    /// @dev Role identifier for the Oracle. Accounts with this role can trigger payments.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @dev ERC20 token used for payments in this contract.
    IERC20 public immutable token;

    /**
     * @dev Error emitted when an attempt to pay fails due to insufficient contract balance.
     * @param balance The current token balance of the contract.
     * @param needed The minimum token amount required to execute the payment.
     */
    error InsufficientBalance(uint256 balance, uint256 needed);

    /**
     * @dev Constructor that initializes the contract with the provided parameters.
     * @param oracle The address of the account assigned the `ORACLE_ROLE` to manage payments.
     * @param _token The address of the ERC20 token contract used for payments.
     * @param initialQuota The initial quota limit for payments.
     * @param initialPeriod The initial time period for which the quota is valid.
     * @param admin The address assigned the `DEFAULT_ADMIN_ROLE` for administrative privileges.
     */
    constructor(address oracle, address _token, uint256 initialQuota, uint256 initialPeriod, address admin)
        QuotaControl(initialQuota, initialPeriod, admin)
    {
        _grantRole(ORACLE_ROLE, oracle); // Grant ORACLE_ROLE to the specified oracle address.
        token = IERC20(_token); // Set the ERC20 token used for payments.
    }

    /**
     * @notice Pays a specified amount to a list of recipients.
     * @dev Can only be called by accounts with the `ORACLE_ROLE`.
     *      The total required amount is calculated by multiplying the number of recipients by the specified amount.
     *      If the contract's token balance is insufficient, the transaction reverts with `InsufficientBalance`.
     *
     * @param recipients An array of addresses to receive the payments.
     * @param amount The amount of tokens to be paid to each recipient.
     *
     * Emits a `Transfer` event from the token for each recipient.
     */
    function pay(address[] calldata recipients, uint256 amount) external onlyRole(ORACLE_ROLE) {
        uint256 needed = recipients.length * amount; // Calculate the total tokens required.
        uint256 balance = token.balanceOf(address(this)); // Get the current balance of the contract.

        if (balance < needed) {
            revert InsufficientBalance(balance, needed);
        }

        _checkedResetClaimed();
        _checkedUpdateClaimed(needed);

        for (uint256 i = 0; i < recipients.length; i++) {
            token.safeTransfer(recipients[i], amount);
        }
    }

    /**
     * @notice Withdraws a specified amount of tokens to the provided recipient address.
     * @dev Can only be called by accounts with the `DEFAULT_ADMIN_ROLE`.
     *
     * @param recipient The address to receive the withdrawn tokens.
     * @param amount The amount of tokens to be transferred to the recipient.
     *
     * Emits a `Transfer` event from the token to the recipient.
     */
    function withdraw(address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        token.safeTransfer(recipient, amount);
    }
}

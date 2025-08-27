// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title QuotaControl
 * @dev A contract designed to manage and control periodic quotas, such as token distributions or other `uint256`-based allowances.
 * It ensures that the total claims or usage within a given period do not exceed the predefined quota, thus regulating the flow of resources.
 *
 * The contract employs a time-based system where the quota is automatically reset at the start of each period.
 * An administrator, holding the `DEFAULT_ADMIN_ROLE`, has the authority to set and modify both the quota and the renewal period.
 *
 * Key Features:
 * - Prevents claims that exceed the current quota.
 * - Allows the admin to update the quota and renewal period.
 * - Automatically resets the claimed amount when a new period begins.
 */
contract QuotaControl is AccessControl {
    using Math for uint256;

    /**
     * @dev The maximum allowable period for reward quota renewal. This limit prevents potential overflows and reduces the need for safe math checks.
     */
    uint256 public constant MAX_PERIOD = 30 days;

    /**
     * @dev The current period for reward quota renewal, specified in seconds.
     */
    uint256 public period;

    /**
     * @dev The maximum amount of rewards that can be distributed in the current period.
     */
    uint256 public quota;

    /**
     * @dev The timestamp when the reward quota will be renewed next.
     */
    uint256 public quotaRenewalTimestamp;

    /**
     * @dev The total amount of rewards claimed within the current period.
     */
    uint256 public claimed;

    /**
     * @dev Error triggered when the claim amount exceeds the current reward quota.
     */
    error QuotaExceeded();

    /**
     * @dev Error triggered when the period for reward renewal is set to zero.
     */
    error ZeroPeriod();

    /**
     * @dev Error triggered when the set period exceeds the maximum allowable period.
     */
    error TooLongPeriod();

    /**
     * @dev Emitted when the reward quota is updated.
     * @param quota The new reward quota.
     */
    event QuotaSet(uint256 quota);

    /**
     * @dev Emitted when the reward period is updated.
     * @param period The new reward period in seconds.
     */
    event PeriodSet(uint256 period);

    /**
     * @dev Initializes the contract with an initial reward quota, reward period, and admin.
     * @param initialQuota The initial maximum amount of rewards distributable in each period.
     * @param initialPeriod The initial duration of the reward period in seconds.
     * @param admin The address granted the `DEFAULT_ADMIN_ROLE`, responsible for updating contract settings.
     *
     * Requirements:
     * - `initialPeriod` must be within the acceptable range (greater than 0 and less than or equal to `MAX_PERIOD`).
     */
    constructor(uint256 initialQuota, uint256 initialPeriod, address admin) {
        _mustBeWithinPeriodRange(initialPeriod);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        quota = initialQuota;
        period = initialPeriod;
        quotaRenewalTimestamp = block.timestamp + period;
    }

    /**
     * @dev Sets a new reward quota. Can only be called by an account with the `DEFAULT_ADMIN_ROLE`.
     * @param newQuota The new maximum amount of rewards distributable in each period.
     */
    function setQuota(uint256 newQuota) external onlyRole(DEFAULT_ADMIN_ROLE) {
        quota = newQuota;
        emit QuotaSet(newQuota);
    }

    /**
     * @dev Sets a new reward period. Can only be called by an account with the `DEFAULT_ADMIN_ROLE`.
     * @param newPeriod The new duration of the reward period in seconds.
     *
     * Requirements:
     * - `newPeriod` must be greater than 0 and less than or equal to `MAX_PERIOD`.
     */
    function setPeriod(uint256 newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _mustBeWithinPeriodRange(newPeriod);
        period = newPeriod;
        emit PeriodSet(newPeriod);
    }

    /**
     * @dev Internal function that resets the claimed rewards to 0 and updates the next quota renewal timestamp.
     * If the current timestamp is beyond the quota renewal timestamp, a new period begins.
     *
     * The reset calculation ensures that the renewal timestamp will always be aligned with the period's duration, even if time has passed beyond the expected renewal time.
     */
    function _checkedResetClaimed() internal {
        if (block.timestamp >= quotaRenewalTimestamp) {
            claimed = 0;

            // Align the quota renewal timestamp to the next period start
            uint256 timeAhead = block.timestamp - quotaRenewalTimestamp;
            quotaRenewalTimestamp = block.timestamp + period - (timeAhead % period);
        }
    }

    /**
     * @dev Internal function to update the claimed rewards by a specified amount.
     *
     * If the total claimed amount exceeds the quota, the transaction is reverted.
     * @param amount The amount of rewards being claimed.
     *
     * Requirements:
     * - The updated `claimed` amount must not exceed the current reward quota.
     */
    function _checkedUpdateClaimed(uint256 amount) internal {
        (bool success, uint256 newClaimed) = claimed.tryAdd(amount);
        if (!success || newClaimed > quota) {
            revert QuotaExceeded();
        }
        claimed = newClaimed;
    }

    /**
     * @dev Internal function to validate that the provided reward period is within the allowed range.
     * @param newPeriod The period to validate.
     *
     * Requirements:
     * - The `newPeriod` must be greater than 0.
     * - The `newPeriod` must not exceed `MAX_PERIOD`.
     */
    function _mustBeWithinPeriodRange(uint256 newPeriod) internal pure {
        if (newPeriod == 0) {
            revert ZeroPeriod();
        }
        if (newPeriod > MAX_PERIOD) {
            revert TooLongPeriod();
        }
    }
}

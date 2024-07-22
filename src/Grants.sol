// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Grants
 * @notice Manages time-based token vesting schedules for ERC-20 tokens, allowing for the creation,
 *         claiming, and cancellation of vesting schedules.
 * @dev Uses the SafeERC20 library to interact with ERC20 tokens securely.
 */
contract Grants {
    using SafeERC20 for IERC20;

    // Maximum number of vesting schedules per address. This is a safety bound to limit the max gas cost of operations.
    uint32 public constant MAX_SCHEDULES = 100;

    // Token used for vesting.
    IERC20 public token;

    // Mapping from recipient address to array of vesting schedules.
    mapping(address => VestingSchedule[]) public vestingSchedules;

    struct VestingSchedule {
        address cancelAuthority; // Address authorized to cancel the vesting.
        uint256 start; // Timestamp when vesting starts.
        uint256 period; // Duration of each period.
        uint32 periodCount; // Total number of periods.
        uint256 perPeriodAmount; // Amount of tokens distributed each period.
    }

    // Events
    event VestingScheduleAdded(address indexed to, VestingSchedule schedule);
    event Claimed(address indexed who, uint256 amount);
    event VestingSchedulesCanceled(address indexed from, address indexed to);
    event Renounced(address indexed from, address indexed to);

    // Errors
    error InvalidZeroParameter(); // Parameters such as some addresses and periods, periodCounts must be non-zero.
    error VestingToSelf(); // Thrown when the creator attempts to vest tokens to themselves.
    error MaxSchedulesReached(); // Thrown when the addition of a new schedule would exceed the maximum allowed.
    error NoOpIsFailure(); // Thrown when an operation that should change state does not.

    constructor(address _token) {
        token = IERC20(_token);
    }

    /**
     * @notice Adds a vesting schedule to an account.
     * @param to Recipient of the tokens under the vesting schedule.
     * @param start Start time of the vesting schedule as a Unix timestamp.
     * @param period Duration of each period in seconds.
     * @param periodCount Number of periods in the vesting schedule.
     * @param perPeriodAmount Amount of tokens to be released each period.
     * @param cancelAuthority Address that has the authority to cancel the vesting. If set to address(0), no one can cancel.
     */
    function addVestingSchedule(
        address to,
        uint256 start,
        uint256 period,
        uint32 periodCount,
        uint256 perPeriodAmount,
        address cancelAuthority
    ) external {
        _mustBeNonZeroAddress(to);
        _mustNotBeSelf(to);
        _mustBeNonZero(period);
        _mustBeNonZero(periodCount);
        _mustNotExceedMaxSchedules(to);

        token.safeTransferFrom(msg.sender, address(this), perPeriodAmount * periodCount);

        VestingSchedule memory schedule = VestingSchedule(cancelAuthority, start, period, periodCount, perPeriodAmount);
        vestingSchedules[to].push(schedule);

        emit VestingScheduleAdded(to, schedule);
    }

    /**
     * @notice Claims all vested tokens available for msg.sender up to the current block timestamp.
     */
    function claim() external {
        uint256 totalClaimable = 0;
        uint256 currentTime = block.timestamp;

        uint256 i = 0;
        VestingSchedule[] storage schedules = vestingSchedules[msg.sender];
        while (i < schedules.length) {
            VestingSchedule storage schedule = schedules[i];
            if (currentTime > schedule.start) {
                uint256 periodsElapsed = (currentTime - schedule.start) / schedule.period;
                uint256 effectivePeriods = periodsElapsed > schedule.periodCount ? schedule.periodCount : periodsElapsed;
                uint256 claimable = effectivePeriods * schedule.perPeriodAmount;
                schedule.periodCount -= uint32(effectivePeriods);
                schedule.start += periodsElapsed * schedule.period;
                totalClaimable += claimable;
                if (schedule.periodCount == 0) {
                    schedules[i] = schedules[schedules.length - 1];
                    schedules.pop();
                    continue;
                }
            }
            i++;
        }

        if (totalClaimable > 0) {
            token.safeTransfer(msg.sender, totalClaimable);
            emit Claimed(msg.sender, totalClaimable);
        } else {
            revert NoOpIsFailure();
        }
    }

    /**
     * @notice Renounces the cancel authority for all of the msg.sender's vesting schedules directed to a specific recipient.
     * @param to Recipient of the vesting whose schedules are affected.
     */
    function renounce(address to) external {
        bool anySchedulesFound = false;
        VestingSchedule[] storage schedules = vestingSchedules[to];
        for (uint256 i = 0; i < schedules.length; i++) {
            if (schedules[i].cancelAuthority == msg.sender) {
                schedules[i].cancelAuthority = address(0);
                anySchedulesFound = true;
            }
        }
        if (!anySchedulesFound) {
            revert NoOpIsFailure();
        } else {
            emit Renounced(msg.sender, to);
        }
    }

    /**
     * @notice Cancels all vesting schedules of a specific recipient, initiated by the cancel authority.
     * @param to Recipient whose schedules will be canceled.
     */
    function cancelVestingSchedules(address to) external {
        uint256 totalClaimable = 0;
        uint256 totalRedeemable = 0;
        uint256 currentTime = block.timestamp;

        uint256 i = 0;
        VestingSchedule[] storage schedules = vestingSchedules[to];
        while (i < schedules.length) {
            VestingSchedule storage schedule = schedules[i];
            if (schedule.cancelAuthority == msg.sender) {
                uint256 periodsElapsed =
                    currentTime > schedule.start ? (currentTime - schedule.start) / schedule.period : 0;
                uint256 effectivePeriods = periodsElapsed > schedule.periodCount ? schedule.periodCount : periodsElapsed;
                uint256 claimable = effectivePeriods * schedule.perPeriodAmount;
                uint256 redeemable = (schedule.periodCount - effectivePeriods) * schedule.perPeriodAmount;
                totalClaimable += claimable;
                totalRedeemable += redeemable;
                schedules[i] = schedules[schedules.length - 1];
                schedules.pop();
                continue;
            }
            i++;
        }

        if (totalClaimable == 0 && totalRedeemable == 0) {
            revert NoOpIsFailure();
        }

        if (totalClaimable > 0) {
            token.safeTransfer(to, totalClaimable);
        }

        if (totalRedeemable > 0) {
            token.safeTransfer(msg.sender, totalRedeemable);
        }

        emit VestingSchedulesCanceled(msg.sender, to);
    }

    /**
     * @notice Returns the number of vesting schedules associated with a given address.
     * @param to The address whose schedule count is to be queried.
     * @return The number of vesting schedules associated with the address.
     */
    function getGrantsCount(address to) external view returns (uint256) {
        return vestingSchedules[to].length;
    }

    // Private helper functions

    function _mustBeNonZero(uint256 value) private pure {
        if (value == 0) {
            revert InvalidZeroParameter();
        }
    }

    function _mustBeNonZeroAddress(address value) private pure {
        if (value == address(0)) {
            revert InvalidZeroParameter();
        }
    }

    function _mustNotBeSelf(address to) private view {
        if (msg.sender == to) {
            revert VestingToSelf();
        }
    }

    function _mustNotExceedMaxSchedules(address to) private view {
        if (vestingSchedules[to].length >= MAX_SCHEDULES) {
            revert MaxSchedulesReached();
        }
    }
}

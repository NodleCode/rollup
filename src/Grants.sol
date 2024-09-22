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

    // Token used for vesting.
    IERC20 public immutable token;

    // Minimum amount of tokens that can be vested per period. This is a safety bound to prevent dusting attacks.
    uint256 public immutable perPeriodMinAmount;

    // Maximum number of vesting schedules per address per page.
    uint8 public immutable pageLimit;

    // Mapping of addresses to the current page of their vesting schedules.
    // The current page is the last page that has been used to store a vesting schedule.
    mapping(address => uint256) public currentPage;

    // Mapping of addresses to their vesting schedules split into pages.
    mapping(address => mapping(uint256 => VestingSchedule[])) public vestingSchedules;

    struct VestingSchedule {
        address cancelAuthority; // Address authorized to cancel the vesting.
        uint256 start; // Timestamp when vesting starts.
        uint256 period; // Duration of each period.
        uint32 periodCount; // Total number of periods.
        uint256 perPeriodAmount; // Amount of tokens distributed each period.
    }

    // Events
    event VestingScheduleAdded(address indexed to, VestingSchedule schedule);
    // start and end indicate the range of the grant pages that are iterated over for claiming.
    event Claimed(address indexed who, uint256 amount, uint256 start, uint256 end);
    // start and end indicate the range of the grant pages that are iterated over for cancelling.
    event VestingSchedulesCanceled(address indexed from, address indexed to, uint256 start, uint256 end);
    // start and end indicate the range of the grant pages that are iterated over for renouncing.
    event Renounced(address indexed from, address indexed to, uint256 start, uint256 end);

    // Errors
    error InvalidZeroParameter(); // Parameters such as some addresses and periods, periodCounts must be non-zero.
    error VestingToSelf(); // Thrown when the creator attempts to vest tokens to themselves.
    error NoOpIsFailure(); // Thrown when an operation that should change state does not.
    error LowVestingAmount(); // Thrown when the amount to be vested is below the minimum allowed.
    error InvalidPage(); // Thrown when the page is invalid.

    constructor(address _token, uint256 _perPeriodMinAmount, uint8 _pageLimit) {
        if (_pageLimit == 0) {
            revert InvalidZeroParameter();
        }

        token = IERC20(_token);
        perPeriodMinAmount = _perPeriodMinAmount;
        pageLimit = _pageLimit;
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
        validateVestingSchedule(to, period, periodCount, perPeriodAmount);

        VestingSchedule memory schedule = VestingSchedule(cancelAuthority, start, period, periodCount, perPeriodAmount);

        uint256 page = currentPage[to];
        if (vestingSchedules[to][page].length == pageLimit) {
            page += 1;
            currentPage[to] = page;
        }
        vestingSchedules[to][page].push(schedule);

        emit VestingScheduleAdded(to, schedule);

        token.safeTransferFrom(msg.sender, address(this), perPeriodAmount * periodCount);
    }

    /**
     * @notice Checks if the vesting schedule parameters are valid.
     * @param to Recipient of the tokens under the vesting schedule.
     * @param period Duration of each period in seconds.
     * @param periodCount Number of periods in the vesting schedule.
     * @param perPeriodAmount Amount of tokens to be released each period.
     */
    function validateVestingSchedule(address to, uint256 period, uint32 periodCount, uint256 perPeriodAmount)
        public
        view
    {
        _mustBeNonZeroAddress(to);
        _mustNotBeSelf(to);
        _mustBeNonZero(period);
        _mustBeNonZero(periodCount);
        _mustBeEqualOrExceedMinAmount(perPeriodAmount);
    }

    /**
     * @notice Claims all vested tokens available for msg.sender up to the current block timestamp.
     * @param start Start page of the vesting schedules to claim from.
     * @param end the page after the last page of the vesting schedules to claim from.
     * @dev if start == end == 0, all pages will be used for claim.
     */
    function claim(uint256 start, uint256 end) external {
        uint256 totalClaimable = 0;
        uint256 currentTime = block.timestamp;

        (start, end) = _sanitizePageRange(msg.sender, start, end);

        for (uint256 page = start; page < end; page++) {
            uint256 i = 0;
            VestingSchedule[] storage schedules = vestingSchedules[msg.sender][page];
            while (i < schedules.length) {
                VestingSchedule storage schedule = schedules[i];
                if (currentTime > schedule.start) {
                    uint256 periodsElapsed = (currentTime - schedule.start) / schedule.period;
                    uint256 effectivePeriods =
                        periodsElapsed > schedule.periodCount ? schedule.periodCount : periodsElapsed;
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
        }

        if (totalClaimable > 0) {
            token.safeTransfer(msg.sender, totalClaimable);
            emit Claimed(msg.sender, totalClaimable, start, end);
        } else {
            revert NoOpIsFailure();
        }
    }

    /**
     * @notice Renounces the cancel authority for all of the msg.sender's vesting schedules directed to a specific recipient.
     * @param to Recipient of the vesting whose schedules are affected.
     * @param start Start page of the vesting schedules to renounce from.
     * @param end the page after the last page of the vesting schedules to renounce from.
     * @dev if start == end == 0, all pages will be used for renounce.
     */
    function renounce(address to, uint256 start, uint256 end) external {
        bool anySchedulesFound = false;

        (start, end) = _sanitizePageRange(to, start, end);
        for (uint256 page = start; page < end; page++) {
            VestingSchedule[] storage schedules = vestingSchedules[to][page];
            for (uint256 i = 0; i < schedules.length; i++) {
                if (schedules[i].cancelAuthority == msg.sender) {
                    schedules[i].cancelAuthority = address(0);
                    anySchedulesFound = true;
                }
            }
        }

        if (!anySchedulesFound) {
            revert NoOpIsFailure();
        } else {
            emit Renounced(msg.sender, to, start, end);
        }
    }

    /**
     * @notice Cancels all vesting schedules of a specific recipient, initiated by the cancel authority.
     * @param to Recipient whose schedules will be canceled.
     * @param start Start page of the vesting schedules to cancel.
     * @param end the page after the last page of the vesting schedules to cancel.
     * @dev if start == end == 0, all pages will be used for cancel.
     */
    function cancelVestingSchedules(address to, uint256 start, uint256 end) external {
        uint256 totalClaimable = 0;
        uint256 totalRedeemable = 0;
        uint256 currentTime = block.timestamp;

        (start, end) = _sanitizePageRange(to, start, end);
        for (uint256 page = start; page < end; page++) {
            uint256 i = 0;
            VestingSchedule[] storage schedules = vestingSchedules[to][page];
            while (i < schedules.length) {
                VestingSchedule storage schedule = schedules[i];
                if (schedule.cancelAuthority == msg.sender) {
                    uint256 periodsElapsed =
                        currentTime > schedule.start ? (currentTime - schedule.start) / schedule.period : 0;
                    uint256 effectivePeriods =
                        periodsElapsed > schedule.periodCount ? schedule.periodCount : periodsElapsed;
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

        emit VestingSchedulesCanceled(msg.sender, to, start, end);
    }

    /**
     * @notice Returns the number of vesting schedules associated with a given address.
     * @param to The address whose schedule count is to be queried.
     * @return The number of vesting schedules associated with the address.
     */
    function getGrantsCount(address to) external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i <= currentPage[to]; i++) {
            count += vestingSchedules[to][i].length;
        }
        return count;
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

    function _mustBeEqualOrExceedMinAmount(uint256 amount) private view {
        if (amount < perPeriodMinAmount) {
            revert LowVestingAmount();
        }
    }

    function _sanitizePageRange(address grantee, uint256 start, uint256 end) private view returns (uint256, uint256) {
        uint256 endPage = currentPage[grantee] + 1;
        if (start > end || start >= endPage) {
            revert InvalidPage();
        }
        if (end > endPage || end == 0) {
            end = endPage;
        }
        return (start, end);
    }
}

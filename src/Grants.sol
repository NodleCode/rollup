// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract VestingContract {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        address from;
        uint256 start;
        uint256 period;
        uint32 periodCount;
        uint256 perPeriodAmount;
    }

    uint32 public constant MAX_SCHEDULES = 100;

    IERC20 public token;
    mapping(address => VestingSchedule[]) public vestingSchedules;
    mapping(address => mapping(address => bool)) public renounces;

    event VestingScheduleAdded(address indexed to, VestingSchedule schedule);
    event Claimed(address indexed who, uint256 amount);
    event VestingSchedulesCanceled(address indexed from, address indexed to);
    event Renounced(address indexed from, address indexed to);

    error InvalidZeroParameter();
    error InsufficientBalanceToLock();
    error EmptyVestingSchedules();
    error VestingToSelf();
    error MaxSchedulesReached();
    error RenouncedCancel();

    constructor(address _token) {
        token = IERC20(_token);
    }

    function addVestingSchedule(address to, uint256 start, uint256 period, uint32 periodCount, uint256 perPeriodAmount)
        external
    {
        _mustBeNonZero(period);
        _mustBeNonZero(periodCount);
        _mustNotCrossMaxSchedules(to);

        token.safeTransferFrom(msg.sender, address(this), perPeriodAmount * periodCount);

        VestingSchedule memory schedule = VestingSchedule(msg.sender, start, period, periodCount, perPeriodAmount);
        vestingSchedules[to].push(schedule);

        emit VestingScheduleAdded(to, schedule);
    }

    function claim() external {
        uint256 totalClaimable = 0;
        uint256 currentTime = block.timestamp;

        VestingSchedule[] storage schedules = vestingSchedules[msg.sender];
        for (uint256 i = 0; i < schedules.length; i++) {
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
                    i--;
                }
            }
        }

        if (totalClaimable > 0) {
            token.safeTransferFrom(address(this), msg.sender, totalClaimable);
        }
        emit Claimed(msg.sender, totalClaimable);
    }

    function renounce(address to) external {
        renounces[to][msg.sender] = true;
        emit Renounced(msg.sender, to);
    }

    function cancelVestingSchedules(address to) external {
        _mustNotBeRenounced(msg.sender, to);

        uint256 totalClaimable = 0;
        uint256 totalRedeemable = 0;
        uint256 currentTime = block.timestamp;

        VestingSchedule[] storage schedules = vestingSchedules[to];
        for (uint256 i = 0; i < schedules.length; i++) {
            VestingSchedule storage schedule = schedules[i];
            if (schedule.from == msg.sender) {
                uint256 periodsElapsed = (currentTime - schedule.start) / schedule.period;
                uint256 effectivePeriods = periodsElapsed > schedule.periodCount ? schedule.periodCount : periodsElapsed;
                uint256 claimable = effectivePeriods * schedule.perPeriodAmount;
                uint256 redeemable = (schedule.periodCount - effectivePeriods) * schedule.perPeriodAmount;
                totalClaimable += claimable;
                totalRedeemable += redeemable;
                schedules[i] = schedules[schedules.length - 1];
                schedules.pop();
                i--;
            }
        }

        if (totalClaimable > 0) {
            token.safeTransferFrom(address(this), to, totalClaimable);
        }

        if (totalRedeemable > 0) {
            token.safeTransferFrom(address(this), msg.sender, totalRedeemable);
        }

        emit VestingSchedulesCanceled(msg.sender, to);
    }

    function _mustBeNonZero(uint256 value) private pure {
        if (value == 0) {
            revert InvalidZeroParameter();
        }
    }

    function _mustNotCrossMaxSchedules(address to) private view {
        if (vestingSchedules[to].length >= MAX_SCHEDULES) {
            revert MaxSchedulesReached();
        }
    }

    function _mustNotBeRenounced(address from, address to) private view {
        if (renounces[to][from]) {
            revert RenouncedCancel();
        }
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {Grants} from "../Grants.sol";
import {NODL} from "../NODL.sol";
import {BridgeBase} from "./BridgeBase.sol";

contract GrantsMigration is BridgeBase {
    /// @notice Maximum number of vesting schedules allowed per proposal. The 100 limit is coming from the Eden parachain.
    uint8 public constant MAX_SCHEDULES = 100;

    /// @dev Represents the vesting details of a proposal.
    struct Proposal {
        address target; // Address of the grant recipient.
        uint256 amount; // Total amount of tokens to be vested.
        Grants.VestingSchedule[] schedules; // Array of vesting schedules.
    }

    /// @dev Tracks voting and execution status of a proposal.
    struct ProposalStatus {
        uint256 lastVote; // Timestamp of the last vote.
        uint8 totalVotes; // Total number of votes cast.
        bool executed; // Whether the proposal has been executed.
    }

    // State variables
    Grants public immutable grants; // Grants contract.
    mapping(bytes32 => Proposal) public proposals; // Proposals identified by a hash.
    mapping(bytes32 => ProposalStatus) public proposalStatus; // Status of each proposal.

    // Events
    event Granted(bytes32 indexed proposal, address indexed user, uint256 amount, uint256 numOfSchedules);

    /**
     * @notice Error to indicate that the schedule array is empty.
     */
    error EmptySchedules();

    /**
     * @notice Error to indicate that the schedule array is too large.
     */
    error TooManySchedules();

    /**
     * @notice Error to indicate that the schedules do not add up to the total amount.
     */
    error AmountMismatch();

    /**
     * @param bridgeOracles Array of addresses authorized to initiate and vote on proposals.
     * @param token Address of the NODL token used for grants.
     * @param _grants Address of the Grants contract managing vesting schedules.
     * @param minVotes Minimum number of votes required to execute a proposal.
     * @param minDelay Minimum delay before a proposal can be executed.
     */
    constructor(address[] memory bridgeOracles, NODL token, Grants _grants, uint8 minVotes, uint256 minDelay)
        BridgeBase(bridgeOracles, token, minVotes, minDelay)
    {
        grants = _grants;
    }

    /**
     * @notice Bridges a proposal for grant distribution across chains or domains.
     * @param paraTxHash Hash of the cross-chain transaction or parameter.
     * @param user Recipient of the grant.
     * @param amount Total token amount for the grant.
     * @param schedules Array of VestingSchedule, detailing the vesting mechanics.
     */
    function bridge(bytes32 paraTxHash, address user, uint256 amount, Grants.VestingSchedule[] memory schedules)
        external
    {
        _mustBeAnOracle(msg.sender);
        _mustNotHaveExecutedYet(paraTxHash);

        if (_proposalExists(paraTxHash)) {
            _mustNotBeChangingParameters(paraTxHash, user, amount, schedules);
            _recordVote(paraTxHash, msg.sender);
        } else {
            _createProposal(paraTxHash, msg.sender, user, amount, schedules);
        }
    }

    /**
     * @notice Executes the grant proposal, transferring vested tokens according to the schedules.
     * @param paraTxHash Hash of the proposal to be executed.
     */
    function grant(bytes32 paraTxHash) external {
        _execute(paraTxHash);
        Proposal storage p = proposals[paraTxHash];
        nodl.mint(address(this), proposals[paraTxHash].amount);
        nodl.approve(address(grants), proposals[paraTxHash].amount);
        for (uint256 i = 0; i < p.schedules.length; i++) {
            grants.addVestingSchedule(
                p.target,
                p.schedules[i].start,
                p.schedules[i].period,
                p.schedules[i].periodCount,
                p.schedules[i].perPeriodAmount,
                p.schedules[i].cancelAuthority
            );
        }
        emit Granted(paraTxHash, p.target, p.amount, p.schedules.length);
    }

    // Internal helper functions below

    function _mustNotBeChangingParameters(
        bytes32 proposal,
        address user,
        uint256 amount,
        Grants.VestingSchedule[] memory schedules
    ) internal view {
        Proposal storage storedProposal = proposals[proposal];

        if (storedProposal.amount != amount || storedProposal.target != user) {
            revert ParametersChanged(proposal);
        }

        uint256 len = storedProposal.schedules.length;
        if (len != schedules.length) {
            revert ParametersChanged(proposal);
        }

        for (uint256 i = 0; i < len; i++) {
            if (
                storedProposal.schedules[i].start != schedules[i].start
                    || storedProposal.schedules[i].period != schedules[i].period
                    || storedProposal.schedules[i].periodCount != schedules[i].periodCount
                    || storedProposal.schedules[i].perPeriodAmount != schedules[i].perPeriodAmount
                    || storedProposal.schedules[i].cancelAuthority != schedules[i].cancelAuthority
            ) {
                revert ParametersChanged(proposal);
            }
        }
    }

    function _createProposal(
        bytes32 proposal,
        address oracle,
        address user,
        uint256 amount,
        Grants.VestingSchedule[] memory schedules
    ) internal {
        if (schedules.length == 0) {
            revert EmptySchedules();
        }
        if (schedules.length > MAX_SCHEDULES) {
            revert TooManySchedules();
        }
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < schedules.length; i++) {
            grants.validateVestingSchedule(
                user, schedules[i].period, schedules[i].periodCount, schedules[i].perPeriodAmount
            );
            totalAmount += schedules[i].perPeriodAmount * schedules[i].periodCount;
        }
        if (totalAmount != amount) {
            revert AmountMismatch();
        }
        proposals[proposal] = Proposal({target: user, amount: amount, schedules: schedules});
        super._createVote(proposal, oracle, user, amount);
    }

    function _proposalExists(bytes32 proposal) internal view returns (bool) {
        return proposalStatus[proposal].totalVotes > 0;
    }

    function _flagAsExecuted(bytes32 proposal) internal override {
        proposalStatus[proposal].executed = true;
    }

    function _incTotalVotes(bytes32 proposal) internal override {
        proposalStatus[proposal].totalVotes++;
    }

    function _updateLastVote(bytes32 proposal, uint256 value) internal override {
        proposalStatus[proposal].lastVote = value;
    }

    function _totalVotes(bytes32 proposal) internal view override returns (uint8) {
        return proposalStatus[proposal].totalVotes;
    }

    function _lastVote(bytes32 proposal) internal view override returns (uint256) {
        return proposalStatus[proposal].lastVote;
    }

    function _executed(bytes32 proposal) internal view override returns (bool) {
        return proposalStatus[proposal].executed;
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {NODL} from "../NODL.sol";

/// @title BridgeBase
/// @notice Abstract contract for bridging free or vested tokens with the help of oracles.
/// @dev This contract provides basic functionalities for voting on proposals
/// to bridge tokens and ensuring certain constraints such as voting thresholds and delays.
abstract contract BridgeBase {
    /// @notice Token contract address for the NODL token.
    NODL public immutable nodl;

    /// @notice Mapping to track whether an address is an oracle.
    mapping(address => bool) public isOracle;

    /// @notice Minimum number of votes needed to execute a proposal.
    uint8 public threshold;

    /// @notice Number of blocks to delay before a proposal can be executed after reaching the voting threshold.
    uint256 public delay;

    /// @notice Maximum number of oracles allowed.
    uint8 public constant MAX_ORACLES = 10;

    /// @notice Mapping of proposals to oracles votes on them.
    mapping(bytes32 => mapping(address => bool)) public voted;

    /// @notice Emitted when the first vote a proposal has been cast.
    event VoteStarted(bytes32 indexed proposal, address oracle, address indexed user, uint256 amount);

    /// @notice Emitted when an oracle votes on a proposal which is already created.
    event Voted(bytes32 indexed proposal, address oracle);

    /// @notice Error to indicate an oracle has already voted on a proposal.
    error AlreadyVoted(bytes32 proposal, address oracle);

    /// @notice Error to indicate a proposal has already been executed.
    error AlreadyExecuted(bytes32 proposal);

    /// @notice Error to indicate parameters of a proposal have been changed after initiation.
    error ParametersChanged(bytes32 proposal);

    /// @notice Error to indicate an address is not recognized as an oracle.
    error NotAnOracle(address user);

    /// @notice Error to indicate it's too soon to execute a proposal.
    /// Please note `withdraw` here refers to a function for free tokens where they are minted for the user.
    /// We have kept the name for API compatibility.
    error NotYetWithdrawable(bytes32 proposal);

    /// @notice Error to indicate insufficient votes to execute a proposal.
    error NotEnoughVotes(bytes32 proposal);

    /// @notice Error to indicate that the number of oracles exceeds the allowed maximum.
    error MaxOraclesExceeded();

    /// @notice Error to indicate that the number of oracles is less than the minimum required.
    error NotEnoughOracles();

    /// @notice Error to indicate an invalid value for the minimum votes.
    error InvalidZeroForMinVotes();

    /// @notice Initializes the contract with specified parameters.
    /// @param bridgeOracles Array of oracle accounts.
    /// @param token Contract address of the NODL token.
    /// @param minVotes Minimum required votes to consider a proposal valid.
    /// @param minDelay Blocks to wait before a passed proposal can be executed.
    constructor(address[] memory bridgeOracles, NODL token, uint8 minVotes, uint256 minDelay) {
        _mustNotBeZeroMinVotes(minVotes);
        _mustHaveEnoughOracles(bridgeOracles.length, minVotes);
        _mustNotExceedMaxOracles(bridgeOracles.length);

        for (uint256 i = 0; i < bridgeOracles.length; i++) {
            isOracle[bridgeOracles[i]] = true;
        }

        nodl = token;
        threshold = minVotes;
        delay = minDelay;
    }

    /// @notice Creates a new vote on a proposal.
    /// @dev Sets initial values and emits a VoteStarted event.
    /// @param proposal The hash identifier of the proposal.
    /// @param oracle The oracle address initiating the vote.
    /// @param user The user address associated with the vote.
    /// @param amount The amount of tokens being bridged.
    function _createVote(bytes32 proposal, address oracle, address user, uint256 amount) internal virtual {
        _mustNotHaveVotedYet(proposal, oracle);

        voted[proposal][oracle] = true;
        _incTotalVotes(proposal);
        _updateLastVote(proposal, block.number);
        emit VoteStarted(proposal, oracle, user, amount);
    }

    /// @notice Records a vote for a proposal by an oracle.
    /// @param proposal The hash identifier of the proposal.
    /// @param oracle The oracle casting the vote.
    function _recordVote(bytes32 proposal, address oracle) internal virtual {
        _mustNotHaveVotedYet(proposal, oracle);

        voted[proposal][oracle] = true;
        _incTotalVotes(proposal);
        _updateLastVote(proposal, block.number);
        emit Voted(proposal, oracle);
    }

    /// @notice Executes a proposal after all conditions are met.
    /// @param proposal The hash identifier of the proposal.
    function _execute(bytes32 proposal) internal {
        _mustNotHaveExecutedYet(proposal);
        _mustHaveEnoughVotes(proposal);
        _mustBePastSafetyDelay(proposal);

        _flagAsExecuted(proposal);
    }

    /**
     * @dev Updates the last vote value for a given proposal.
     * @param proposal The identifier of the proposal.
     * @param value The new value for the last vote.
     */
    function _updateLastVote(bytes32 proposal, uint256 value) internal virtual;

    /**
     * @dev Increments the total votes count for a given proposal.
     * @param proposal The identifier of the proposal.
     */
    function _incTotalVotes(bytes32 proposal) internal virtual;

    /**
     * @dev Flags a proposal as executed.
     * @param proposal The identifier of the proposal.
     */
    function _flagAsExecuted(bytes32 proposal) internal virtual;

    /**
     * @dev Retrieves the last vote value for a given proposal.
     * @param proposal The identifier of the proposal.
     * @return The last vote value.
     */
    function _lastVote(bytes32 proposal) internal view virtual returns (uint256);

    /**
     * @dev Retrieves the total votes count for a given proposal.
     * @param proposal The identifier of the proposal.
     * @return The total votes count.
     */
    function _totalVotes(bytes32 proposal) internal view virtual returns (uint8);

    /**
     * @dev Checks if a proposal has been executed.
     * @param proposal The identifier of the proposal.
     * @return A boolean indicating if the proposal has been executed.
     */
    function _executed(bytes32 proposal) internal view virtual returns (bool);

    function _mustNotHaveExecutedYet(bytes32 proposal) internal view {
        if (_executed(proposal)) {
            revert AlreadyExecuted(proposal);
        }
    }

    function _mustBePastSafetyDelay(bytes32 proposal) internal view {
        if (block.number - _lastVote(proposal) < delay) {
            revert NotYetWithdrawable(proposal);
        }
    }

    function _mustHaveEnoughVotes(bytes32 proposal) internal view {
        if (_totalVotes(proposal) < threshold) {
            revert NotEnoughVotes(proposal);
        }
    }

    function _mustHaveEnoughOracles(uint256 length, uint256 minOracles) internal pure {
        if (length < minOracles) {
            revert NotEnoughOracles();
        }
    }

    function _mustBeAnOracle(address maybeOracle) internal view {
        if (!isOracle[maybeOracle]) {
            revert NotAnOracle(maybeOracle);
        }
    }

    function _mustNotExceedMaxOracles(uint256 length) internal pure {
        if (length > MAX_ORACLES) {
            revert MaxOraclesExceeded();
        }
    }

    function _mustNotBeZeroMinVotes(uint8 value) internal pure {
        if (value == 0) {
            revert InvalidZeroForMinVotes();
        }
    }

    function _mustNotHaveVotedYet(bytes32 proposal, address oracle) internal view {
        if (voted[proposal][oracle]) {
            revert AlreadyVoted(proposal, oracle);
        }
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {NODL} from "../NODL.sol";

/// @title BridgeBase
/// @notice Abstract contract for bridging free or vested tokens with the help of oracles.
/// @dev This contract provides basic functionalities for voting on proposals
/// to bridge tokens and ensuring certain constraints such as voting thresholds and delays.
abstract contract BridgeBase {
    /// @notice Struct to store the status of a proposal.
    /// @dev Tracks the last block number when a vote was cast, the total number of votes,
    /// and whether the proposal has been executed.
    struct ProposalStatus {
        uint256 lastVote;
        uint8 totalVotes;
        bool executed;
    }

    /// @notice Token contract address for the NODL token.
    NODL public nodl;

    /// @notice Mapping to track whether an address is an oracle.
    mapping(address => bool) public isOracle;

    /// @notice Minimum number of votes needed to execute a proposal.
    uint8 public threshold;

    /// @notice Number of blocks to delay before a proposal can be executed after reaching the voting threshold.
    uint256 public delay;

    /// @notice Maximum number of oracles allowed.
    uint8 public constant MAX_ORACLES = 10;

    /// @notice Mapping of oracles to proposals to track which oracle has voted on which proposal.
    mapping(address => mapping(bytes32 => bool)) public voted;

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

    /// @notice Initializes the contract with specified parameters.
    /// @param bridgeOracles Array of oracle accounts.
    /// @param token Contract address of the NODL token.
    /// @param minVotes Minimum required votes to consider a proposal valid.
    /// @param minDelay Blocks to wait before a passed proposal can be executed.
    constructor(address[] memory bridgeOracles, NODL token, uint8 minVotes, uint256 minDelay) {
        require(bridgeOracles.length >= minVotes, "Not enough oracles");
        require(minVotes > 0, "Votes must be more than zero");

        _mustNotExceedMaxOracles(bridgeOracles.length);

        for (uint256 i = 0; i < bridgeOracles.length; i++) {
            isOracle[bridgeOracles[i]] = true;
        }

        nodl = token;
        threshold = minVotes;
        delay = minDelay;
    }

    /// @notice Returns the current status of a proposal.
    /// @dev Must be implemented by inheriting contracts.
    /// @param proposal The hash identifier of the proposal.
    /// @return The storage pointer to the status of the proposal.
    function _proposalStatus(bytes32 proposal) internal view virtual returns (ProposalStatus storage);

    /// @notice Checks if a proposal already exists.
    /// @param proposal The hash identifier of the proposal.
    /// @return True if the proposal exists and has votes.
    function _proposalExists(bytes32 proposal) internal view returns (bool) {
        ProposalStatus storage status = _proposalStatus(proposal);
        return status.totalVotes > 0;
    }

    /// @notice Creates a new vote on a proposal.
    /// @dev Sets initial values and emits a VoteStarted event.
    /// @param proposal The hash identifier of the proposal.
    /// @param oracle The oracle address initiating the vote.
    /// @param user The user address associated with the vote.
    /// @param amount The amount of tokens being bridged.
    function _createVote(bytes32 proposal, address oracle, address user, uint256 amount) internal virtual {
        _mustNotHaveVotedYet(proposal, oracle);
        voted[oracle][proposal] = true;
        ProposalStatus storage status = _proposalStatus(proposal);
        status.totalVotes = 1;
        status.lastVote = block.number;
        emit VoteStarted(proposal, oracle, user, amount);
    }

    /// @notice Records a vote for a proposal by an oracle.
    /// @param proposal The hash identifier of the proposal.
    /// @param oracle The oracle casting the vote.
    function _recordVote(bytes32 proposal, address oracle) internal virtual {
        _mustNotHaveVotedYet(proposal, oracle);
        voted[oracle][proposal] = true;
        ProposalStatus storage status = _proposalStatus(proposal);
        status.totalVotes += 1;
        status.lastVote = block.number;
        emit Voted(proposal, oracle);
    }

    /// @notice Executes a proposal after all conditions are met.
    /// @param proposal The hash identifier of the proposal.
    function _execute(bytes32 proposal) internal {
        _mustNotHaveExecutedYet(proposal);
        _mustHaveEnoughVotes(proposal);
        _mustBePastSafetyDelay(proposal);

        ProposalStatus storage status = _proposalStatus(proposal);
        status.executed = true;
    }

    function _mustNotHaveExecutedYet(bytes32 proposal) internal view {
        if (_proposalStatus(proposal).executed) {
            revert AlreadyExecuted(proposal);
        }
    }

    function _mustBePastSafetyDelay(bytes32 proposal) internal view {
        if (block.number - _proposalStatus(proposal).lastVote < delay) {
            revert NotYetWithdrawable(proposal);
        }
    }

    function _mustHaveEnoughVotes(bytes32 proposal) internal view {
        if (_proposalStatus(proposal).totalVotes < threshold) {
            revert NotEnoughVotes(proposal);
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

    function _mustNotHaveVotedYet(bytes32 proposal, address oracle) internal view {
        if (voted[oracle][proposal]) {
            revert AlreadyVoted(proposal, oracle);
        }
    }
}

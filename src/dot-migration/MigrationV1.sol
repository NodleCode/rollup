// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {NODL} from "../NODL.sol";

/// @title MigrationV1
/// @notice This contract is used to help migrating the NODL assets from the Nodle Parachain
/// to the ZkSync contracts.
contract MigrationV1 {
    struct Proposal {
        address target;
        uint256 amount;
        uint8 totalVotes;
        bool executed;
    }

    NODL public nodl;
    mapping(address => bool) public isOracle;
    uint8 public threshold;

    // We track votes in a seperate mapping to avoid having to write helper functions to
    // expose the votes for each proposal.
    mapping(bytes32 => Proposal) public proposals;
    mapping(address => mapping(bytes32 => bool)) public voted;

    error AlreadyVoted(bytes32 proposal, address oracle);
    error AlreadyExecuted(bytes32 proposal);
    error ParametersChanged(bytes32 proposal);
    error NotAnOracle(address user);

    event VoteStarted(bytes32 indexed proposal, address oracle, address indexed user, uint256 amount);
    event Voted(bytes32 indexed proposal, address oracle);
    event Bridged(bytes32 indexed proposal, address indexed user, uint256 amount);

    /// @param bridgeOracles Array of oracle accounts that will be able to bridge the tokens.
    /// @param token Contract address of the NODL token.
    /// @param minVotes Minimum number of votes required to bridge the tokens.
    constructor(address[] memory bridgeOracles, NODL token, uint8 minVotes) {
        for (uint256 i = 0; i < bridgeOracles.length; i++) {
            isOracle[bridgeOracles[i]] = true;
        }
        nodl = token;
        threshold = minVotes;
    }

    /// @notice Bridge some tokens from the Nodle Parachain to the ZkSync contracts. This
    /// tracks "votes" from each oracle and only bridges the tokens if the threshold is met.
    /// @param paraTxHash The transaction hash on the Parachain for this transfer.
    /// @param user The user address.
    /// @param amount The amount of NODL tokens that the user has burnt on the Parachain.
    function bridge(bytes32 paraTxHash, address user, uint256 amount) external {
        _mustBeAnOracle(msg.sender);
        _mustNotHaveExecutedYet(paraTxHash);

        if (_proposalExists(paraTxHash)) {
            _mustNotHaveVotedYet(paraTxHash, msg.sender);
            _mustNotBeChangingParameters(paraTxHash, user, amount);
            _recordVote(paraTxHash, msg.sender);
        } else {
            _createVote(paraTxHash, msg.sender, user, amount);
        }

        if (_enoughVotes(paraTxHash)) {
            _mintTokens(paraTxHash, user, amount);
        }
    }

    function _mustBeAnOracle(address maybeOracle) internal view {
        if (!isOracle[maybeOracle]) {
            revert NotAnOracle(maybeOracle);
        }
    }

    function _mustNotHaveVotedYet(bytes32 proposal, address oracle) internal view {
        if (voted[oracle][proposal]) {
            revert AlreadyVoted(proposal, oracle);
        }
    }

    function _mustNotHaveExecutedYet(bytes32 proposal) internal view {
        if (proposals[proposal].executed) {
            revert AlreadyExecuted(proposal);
        }
    }

    function _mustNotBeChangingParameters(bytes32 proposal, address user, uint256 amount) internal view {
        if (proposals[proposal].amount != amount || proposals[proposal].target != user) {
            revert ParametersChanged(proposal);
        }
    }

    function _proposalExists(bytes32 proposal) internal view returns (bool) {
        return proposals[proposal].totalVotes > 0 && proposals[proposal].amount > 0;
    }

    function _createVote(bytes32 proposal, address oracle, address user, uint256 amount) internal {
        voted[oracle][proposal] = true;
        proposals[proposal].target = user;
        proposals[proposal].amount = amount;
        proposals[proposal].totalVotes = 1;

        emit VoteStarted(proposal, oracle, user, amount);
    }

    function _recordVote(bytes32 proposal, address oracle) internal {
        voted[oracle][proposal] = true;
        // this is safe since we are unlikely to have maxUint8 oracles to manage
        proposals[proposal].totalVotes += 1;

        emit Voted(proposal, oracle);
    }

    function _enoughVotes(bytes32 proposal) internal view returns (bool) {
        return proposals[proposal].totalVotes >= threshold;
    }

    function _mintTokens(bytes32 proposal, address user, uint256 amount) internal {
        proposals[proposal].executed = true;
        nodl.mint(user, amount);

        emit Bridged(proposal, user, amount);
    }
}

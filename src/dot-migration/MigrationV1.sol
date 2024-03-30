// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {NODL} from "../NODL.sol";

/// @title MigrationV1
/// @notice This contract is used to help migrating the NODL assets from the Nodle Parachain
/// to the ZkSync contracts.
contract MigrationV1 {
    struct Vote {
        uint256 newAmount;
        mapping(address => bool) voted;
        uint256 totalVotes;
    }

    NODL public nodl;
    mapping(address => uint256) public bridged;
    address[] public oracles;
    mapping(address => bool) public isOracle;
    mapping(address => Vote) public votes;
    uint256 public threshold;

    error MayOnlyIncrease();
    error AlreadyVoted(address oracle, address user);
    error NotAnOracle(address user);

    event VoteStarted(address indexed oracle, address indexed user, uint256 newAmount);
    event Voted(address indexed oracle, address indexed user);
    event Bridged(address indexed user, uint256 amount);

    modifier onlyOracle() {
        if (!isOracle[msg.sender]) {
            revert NotAnOracle(msg.sender);
        }
        _;
    }

    constructor(address[] memory bridgeOracles, NODL token) {
        for (uint256 i = 0; i < bridgeOracles.length; i++) {
            isOracle[bridgeOracles[i]] = true;
        }
        oracles = bridgeOracles;
        nodl = token;
        threshold = bridgeOracles.length / 2 + 1;
    }

    /// @notice Bridge some tokens from the Nodle Parachain to the ZkSync contracts. This
    /// tracks "votes" from each oracle and only bridges the tokens if the threshold is met.
    /// @param user The user address.
    /// @param totalBurnt The **total** amount of NODL tokens that the user has burnt
    /// on the Parachain.
    function bridge(address user, uint256 totalBurnt) external onlyOracle {
        uint256 alreadyBridged = bridged[user];
        if (totalBurnt <= alreadyBridged) {
            revert MayOnlyIncrease();
        }

        uint256 currentVote = votes[user].newAmount;
        if (totalBurnt < currentVote) {
            revert MayOnlyIncrease();
        } else if (totalBurnt > currentVote) {
            _startNewVote(user, totalBurnt);
            return;
        }

        _castVote(user);

        if (votes[user].totalVotes >= threshold) {
            // this is safe since we are subtracting a smaller number from a larger one
            _bridgeAndMint(user, totalBurnt, totalBurnt - alreadyBridged);
        }
    }

    function currentVotes(address user) external view returns (uint256, uint256) {
        return (votes[user].newAmount, votes[user].totalVotes);
    }

    function didVote(address user, address oracle) external view returns (bool) {
        return votes[user].voted[oracle];
    }

    function _startNewVote(address user, uint256 totalBurnt) internal {
        votes[user].newAmount = totalBurnt;
        votes[user].totalVotes = 1;
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == msg.sender) {
                votes[user].voted[oracles[i]] = true;
            } else {
                votes[user].voted[oracles[i]] = false;
            }
        }

        emit VoteStarted(msg.sender, user, totalBurnt);
    }

    function _castVote(address user) internal {
        if (votes[user].voted[msg.sender]) {
            revert AlreadyVoted(msg.sender, user);
        }

        votes[user].voted[msg.sender] = true;
        // this is safe since we are unlikely to have maxUint256 oracles to manage
        votes[user].totalVotes += 1;

        emit Voted(msg.sender, user);
    }

    function _bridgeAndMint(address user, uint256 totalBurnt, uint256 needToMint) internal {
        bridged[user] = totalBurnt;
        nodl.mint(user, needToMint);

        emit Bridged(user, needToMint);
    }
}

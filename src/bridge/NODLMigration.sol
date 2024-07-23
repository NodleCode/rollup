// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {NODL} from "../NODL.sol";
import {BridgeBase} from "./BridgeBase.sol";

/// @title NODLMigration
/// @notice This contract is used to help migrating the NODL assets from the Nodle Parachain
/// to the ZkSync contracts.
contract NODLMigration is BridgeBase {
    struct Proposal {
        address target;
        uint256 amount;
        ProposalStatus status;
    }

    // We track votes in a seperate mapping to avoid having to write helper functions to
    // expose the votes for each proposal.
    mapping(bytes32 => Proposal) public proposals;

    event Withdrawn(bytes32 indexed proposal, address indexed user, uint256 amount);

    constructor(address[] memory bridgeOracles, NODL token, uint8 minVotes, uint256 minDelay)
        BridgeBase(bridgeOracles, token, minVotes, minDelay)
    {}

    /// @notice Bridge some tokens from the Nodle Parachain to the ZkSync contracts. This
    /// tracks "votes" from each oracle and unlocks execution after a withdrawal delay.
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
    }

    /// @notice Withdraw the NODL tokens from the contract to the user's address if the
    /// proposal has enough votes and has passed the safety delay.
    /// @param paraTxHash The transaction hash on the Parachain for this transfer.
    function withdraw(bytes32 paraTxHash) external {
        _execute(paraTxHash);
        _withdraw(paraTxHash, proposals[paraTxHash].target, proposals[paraTxHash].amount);
    }

    function _mustNotBeChangingParameters(bytes32 proposal, address user, uint256 amount) internal view {
        if (proposals[proposal].amount != amount || proposals[proposal].target != user) {
            revert ParametersChanged(proposal);
        }
    }

    function _proposalStatus(bytes32 proposal) internal view override returns (ProposalStatus storage) {
        return proposals[proposal].status;
    }

    function _createVote(bytes32 proposal, address oracle, address user, uint256 amount) internal override {
        proposals[proposal].target = user;
        proposals[proposal].amount = amount;
        super._createVote(proposal, oracle, user, amount);
    }

    function _withdraw(bytes32 proposal, address user, uint256 amount) internal {
        nodl.mint(user, amount);
        emit Withdrawn(proposal, user, amount);
    }
}

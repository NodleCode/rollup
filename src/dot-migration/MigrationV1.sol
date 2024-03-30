// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title MigrationV1
/// @notice This contract is used to help migrating the NODL assets from the Nodle Parachain
/// to the ZkSync contracts.
contract MigrationV1 is Ownable {
    using Math for uint256;

    struct ClaimRecord {
        uint256 amount;
        uint256 claimed;
    }

    mapping(address => ClaimRecord) public claims;

    error Overflowed();

    event ClaimableAmountIncreased(address indexed user, uint256 amount);

    constructor(address oracle) Ownable(oracle) {}

    /// @notice Increases the amount of NODL tokens that the user can claim.
    /// @param user The user address.
    /// @param amount The amount of NODL tokens to increase.
    function increaseAmount(address user, uint256 amount) external onlyOwner {
        (bool success, uint256 newAmount) = claims[user].amount.tryAdd(amount);
        if (!success) {
            revert Overflowed();
        }

        claims[user].amount = newAmount;

        emit ClaimableAmountIncreased(user, newAmount);
    }
}

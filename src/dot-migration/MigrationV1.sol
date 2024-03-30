// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {NODL} from "../NODL.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title MigrationV1
/// @notice This contract is used to help migrating the NODL assets from the Nodle Parachain
/// to the ZkSync contracts.
contract MigrationV1 is Ownable {
    using Math for uint256;

    NODL public nodl;
    mapping(address => uint256) public bridged;

    error Underflowed();
    error ZeroValueTransfer();

    event Bridged(address indexed user, uint256 amount);

    constructor(address oracle, NODL token) Ownable(oracle) {
        nodl = token;
    }

    /// @notice Bridge some tokens from the Nodle Parachain to the ZkSync contracts. This
    /// mint any tokens that the user has not already bridged while keeping track of the
    /// total amount of tokens that the user has burnt on the Parachain side.
    /// @param user The user address.
    /// @param totalBurnt The **total** amount of NODL tokens that the user has burnt
    /// on the Parachain.
    function bridge(address user, uint256 totalBurnt) external onlyOwner {
        uint256 alreadyBridged = bridged[user];
        (bool success, uint256 needToMint) = totalBurnt.trySub(alreadyBridged);
        if (!success) {
            revert Underflowed();
        }
        if (needToMint == 0) {
            revert ZeroValueTransfer();
        }

        bridged[user] = totalBurnt;
        nodl.mint(user, needToMint);

        emit Bridged(user, needToMint);
    }
}

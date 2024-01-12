// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

/// @notice a simple mock contract to be called into and mark it a tx as having actually happened on-chain
contract MockFlag {
    string public flag;

    function setFlag(string memory value) external {
        flag = value;
    }
}

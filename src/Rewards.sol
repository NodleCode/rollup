// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {NODL} from "./NODL.sol";

contract Rewards {
    NODL public token;

    constructor(address mintableTokenAddress) {
        token = NODL(mintableTokenAddress);
    }

    function batchMint(address[] calldata addresses, uint256[] calldata balances) external {
        require(addresses.length == balances.length, "Addresses and balances length mismatch");

        for (uint256 i = 0; i < addresses.length; i++) {
            token.mint(addresses[i], balances[i]);
        }
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/// @notice A simple contract to re-expose Multicall and make it easy to deploy.
contract MulticallBatcher is Multicall {
    constructor() Multicall() {}
}

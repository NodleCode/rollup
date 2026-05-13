// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal L2ECO-shaped mock — standard ERC20 plus a configurable
/// `linearInflationMultiplier()` so the test can exercise PeanutV4's
/// `contractType == 4` rebasing-token paths.
contract L2ECOMock is ERC20 {
    uint256 private _multiplier;

    constructor(uint256 initialMultiplier) ERC20("L2ECOMock", "ECO") {
        _multiplier = initialMultiplier;
    }

    function linearInflationMultiplier() external view returns (uint256) {
        return _multiplier;
    }

    function setMultiplier(uint256 m) external {
        _multiplier = m;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

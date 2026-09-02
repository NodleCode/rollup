// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Refuses transfers touching a blocked address, as USDC and USDT can.
contract BlocklistERC20 is ERC20 {
    mapping(address => bool) public blocked;

    error Blocked(address account);

    constructor() ERC20("Blocklist", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}

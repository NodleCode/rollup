// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 mock that takes a 1% fee on every transfer (simulates fee-on-transfer tokens).
contract FeeOnTransferERC20Mock is ERC20 {
    constructor() ERC20("FeeOnTransfer", "FOT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            // Burn 1% as a fee
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

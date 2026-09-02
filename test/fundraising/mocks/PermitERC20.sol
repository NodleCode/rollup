// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice ERC-2612 token, for the single-transaction deposit path.
contract PermitERC20 is ERC20, ERC20Permit {
    constructor() ERC20("Permit", "PRM") ERC20Permit("Permit") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Calls back into a target contract on every outbound transfer.
/// @dev Stands in for ERC-777 and other hook-bearing tokens. Fires once per armed run so a
///      failed reentry does not loop forever; the guard, not the mock, is what must stop it.
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    /// @notice Set when a reentrant call was attempted, whether it succeeded, and the
    ///         revert data it came back with. Tests assert on the revert data: a refused
    ///         reentry proves nothing unless it was the guard that refused it.
    bool public attempted;
    bool public succeeded;
    bytes public revertData;

    constructor() ERC20("Reentrant", "REE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
        attempted = false;
        succeeded = false;
        delete revertData;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && target != address(0)) {
            armed = false; // one shot
            attempted = true;
            (bool ok, bytes memory data) = target.call(payload);
            succeeded = ok;
            revertData = data;
        }
    }
}

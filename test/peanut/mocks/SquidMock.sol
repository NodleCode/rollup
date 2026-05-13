// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test mock for the Squid router. PeanutRouter forwards an opaque calldata blob
///      to Squid; this mock just records that the blob was delivered.
contract SquidMock {
    using SafeERC20 for IERC20;

    event SquidMockBridged();

    function superPowerfulBridge(address bridgedToken, uint256 bridgedAmount) public payable {
        if (bridgedToken == address(0)) {
            require(msg.value == bridgedAmount, "msg.value DOES NOT MATCH bridgedAmount");
        } else {
            IERC20(bridgedToken).safeTransferFrom(msg.sender, address(this), bridgedAmount);
        }

        emit SquidMockBridged();
    }
}

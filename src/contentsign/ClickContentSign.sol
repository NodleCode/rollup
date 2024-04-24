// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {BaseContentSign} from "./BaseContentSign.sol";
import {WhitelistPaymaster} from "../paymasters/WhitelistPaymaster.sol";

/// @notice the content sign contract variant for Click. Only users whitelisted on the paymaster can mint tokens
contract ClickContentSign is BaseContentSign {
    WhitelistPaymaster public whitelistPaymaster;

    constructor(string memory name, string memory symbol, WhitelistPaymaster whitelist) BaseContentSign(name, symbol) {
        whitelistPaymaster = whitelist;
    }

    function _userIsWhitelisted(address user) internal view override returns (bool) {
        return whitelistPaymaster.isWhitelistedUser(user);
    }
}

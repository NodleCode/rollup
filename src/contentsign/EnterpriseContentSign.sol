// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {BaseContentSign} from "./BaseContentSign.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice the content sign contract variant for enterprises. Only users whitelisted on this contract can mint
contract EnterpriseContentSign is BaseContentSign, AccessControl {
    bytes32 public constant WHITELISTED_ROLE = keccak256("WHITELISTED_ROLE");

    constructor(string memory name, string memory symbol, address admin) BaseContentSign(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(BaseContentSign, AccessControl)
        returns (bool)
    {
        return BaseContentSign.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }

    function _userIsWhitelisted(address user) internal view override returns (bool) {
        return hasRole(WHITELISTED_ROLE, user);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import "./BasePaymaster.sol";

/// @notice a paymaster that allow whitelisted users to do free txs to restricted contracts
contract WhitelistPaymaster is BasePaymaster {
    // We could build our own whitelist feature, however we already have access control built in
    // via BasePaymaster and OZ's AccessControl contract. So we can just use that and grant a dedicated
    // role to whitelisted users.
    // This allows us to avoid reinventing the wheel and to piggy back on existing code and methods
    // that are already audited and tested.
    bytes32 public constant WHITELISTED_USER_ROLE = keccak256("WHITELISTED_USER_ROLE");

    mapping(address => bool) public isWhitelistedContract;

    error UserIsNotWhitelisted();
    error DestIsNotWhitelisted();

    constructor(
        address _admin,
        address _withdrawer,
        address[] memory _whitelistedContracts
    ) BasePaymaster(_admin, _withdrawer) {
        _setContractWhitelist(_whitelistedContracts);
    }

    function addWhitelistedContracts(
        address[] memory _whitelistedContracts
    ) external onlyAdmin {
        _setContractWhitelist(_whitelistedContracts);
    }

    function removeWhitelistedContracts(
        address[] memory _whitelistedContracts
    ) external onlyAdmin {
        for (uint256 i = 0; i < _whitelistedContracts.length; i++) {
            isWhitelistedContract[_whitelistedContracts[i]] = false;
        }
    }

    function isWhitelistedUser(address user) public view returns (bool) {
        return hasRole(WHITELISTED_USER_ROLE, user);
    }

    function _setContractWhitelist(address[] memory _whitelistedContracts)
        internal
    {
        for (uint256 i = 0; i < _whitelistedContracts.length; i++) {
            isWhitelistedContract[_whitelistedContracts[i]] = true;
        }
    }

    function _validateAndPayGeneralFlow(
        address from,
        address to,
        uint256 /* requiredETH */
    ) internal override {
        if (!isWhitelistedContract[to]) {
            revert DestIsNotWhitelisted();
        }

        if (!isWhitelistedUser(from)) {
            revert UserIsNotWhitelisted();
        }

        // TODO: shall we rate limit gas consumption?
    }

    function _validateAndPayApprovalBasedFlow(
        address,
        address,
        address,
        uint256,
        bytes memory,
        uint256
    ) internal pure override {
        revert PaymasterFlowNotSupported();
    }
}

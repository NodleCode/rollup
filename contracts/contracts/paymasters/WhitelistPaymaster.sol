// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {BasePaymaster} from "./BasePaymaster.sol";

/// @notice a paymaster that allow whitelisted users to do free txs to restricted contracts
contract WhitelistPaymaster is BasePaymaster {
    bytes32 public constant WHITELIST_ADMIN_ROLE =
        keccak256("WHITELIST_ADMIN_ROLE");

    mapping(address => bool) public isWhitelistedUser;
    mapping(address => bool) public isWhitelistedContract;

    error UserIsNotWhitelisted();
    error DestIsNotWhitelisted();

    constructor(
        address admin,
        address withdrawer,
        address whitelistAdmin,
        address[] memory whitelistedContracts
    ) BasePaymaster(admin, withdrawer) {
        _grantRole(WHITELIST_ADMIN_ROLE, whitelistAdmin);
        _setContractWhitelist(whitelistedContracts);
    }

    function addWhitelistedContracts(
        address[] calldata whitelistedContracts
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        _setContractWhitelist(whitelistedContracts);
    }

    function removeWhitelistedContracts(
        address[] calldata whitelistedContracts
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        for (uint256 i = 0; i < whitelistedContracts.length; i++) {
            isWhitelistedContract[whitelistedContracts[i]] = false;
        }
    }

    function addWhitelistedUsers(
        address[] calldata users
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        for (uint256 i = 0; i < users.length; i++) {
            isWhitelistedUser[users[i]] = true;
        }
    }

    function removeWhitelistedUsers(
        address[] calldata users
    ) external onlyRole(WHITELIST_ADMIN_ROLE) {
        for (uint256 i = 0; i < users.length; i++) {
            isWhitelistedUser[users[i]] = false;
        }
    }

    function _setContractWhitelist(
        address[] memory whitelistedContracts
    ) internal {
        for (uint256 i = 0; i < whitelistedContracts.length; i++) {
            isWhitelistedContract[whitelistedContracts[i]] = true;
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

        if (!isWhitelistedUser[from]) {
            revert UserIsNotWhitelisted();
        }
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

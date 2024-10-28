// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {BasePaymaster} from "./BasePaymaster.sol";

/// @notice a paymaster that allow whitelisted users to do free txs to restricted contracts
contract WhitelistPaymaster is BasePaymaster {
    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    mapping(address => bool) public isWhitelistedUser;
    mapping(address => bool) public isWhitelistedContract;

    event WhitelistedContractsAdded(address[] contracts);
    event WhitelistedContractsRemoved(address[] contracts);
    event WhitelistedUsersAdded(address[] users);
    event WhitelistedUsersRemoved(address[] users);

    error UserIsNotWhitelisted();
    error DestIsNotWhitelisted();

    constructor(address admin, address withdrawer) BasePaymaster(admin, withdrawer) {
        _grantRole(WHITELIST_ADMIN_ROLE, admin);
    }

    function addWhitelistedContracts(address[] calldata whitelistedContracts) external {
        _checkRole(WHITELIST_ADMIN_ROLE);

        for (uint256 i = 0; i < whitelistedContracts.length; i++) {
            isWhitelistedContract[whitelistedContracts[i]] = true;
        }

        emit WhitelistedContractsAdded(whitelistedContracts);
    }

    function removeWhitelistedContracts(address[] calldata whitelistedContracts) external {
        _checkRole(WHITELIST_ADMIN_ROLE);

        for (uint256 i = 0; i < whitelistedContracts.length; i++) {
            isWhitelistedContract[whitelistedContracts[i]] = false;
        }

        emit WhitelistedContractsRemoved(whitelistedContracts);
    }

    function addWhitelistedUsers(address[] calldata users) external {
        _checkRole(WHITELIST_ADMIN_ROLE);

        for (uint256 i = 0; i < users.length; i++) {
            isWhitelistedUser[users[i]] = true;
        }

        emit WhitelistedUsersAdded(users);
    }

    function removeWhitelistedUsers(address[] calldata users) external {
        _checkRole(WHITELIST_ADMIN_ROLE);

        for (uint256 i = 0; i < users.length; i++) {
            isWhitelistedUser[users[i]] = false;
        }

        emit WhitelistedUsersRemoved(users);
    }

    function _validateAndPayGeneralFlow(address from, address to, uint256 /* requiredETH */ ) internal view override {
        if (!isWhitelistedContract[to]) {
            revert DestIsNotWhitelisted();
        }

        if (!isWhitelistedUser[from]) {
            revert UserIsNotWhitelisted();
        }
    }

    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        pure
        override
    {
        revert PaymasterFlowNotSupported();
    }
}

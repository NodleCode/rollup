// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BasePaymaster} from "./BasePaymaster.sol";
import {QuotaControl} from "../QuotaControl.sol";

/// @notice Combined paymaster + bond treasury for FleetIdentity operations.
/// @dev Holds ETH (to sponsor gas) and NODL (to sponsor bonds). Whitelisted
///      users call FleetIdentityUpgradeable.claimUuidSponsored(), which calls
///      this contract's `consumeSponsoredBond` to validate + consume quota,
///      then pulls the NODL bond via `transferFrom`.
///      The ZkSync paymaster validation ensures only whitelisted users calling
///      FleetIdentity get gas-sponsored.
contract FleetTreasuryPaymaster is BasePaymaster, QuotaControl {
    using SafeERC20 for IERC20;

    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    address public immutable fleetIdentity;
    IERC20 public immutable bondToken;

    mapping(address => bool) public isWhitelistedUser;

    event WhitelistedUsersAdded(address[] users);
    event WhitelistedUsersRemoved(address[] users);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

    error UserIsNotWhitelisted();
    error DestinationNotAllowed();
    error PaymasterBalanceTooLow();
    error NotFleetIdentity();
    error InsufficientBondBalance();

    constructor(
        address admin,
        address withdrawer,
        address fleetIdentity_,
        address bondToken_,
        uint256 initialQuota,
        uint256 initialPeriod
    ) BasePaymaster(admin, withdrawer) QuotaControl(initialQuota, initialPeriod, admin) {
        _grantRole(WHITELIST_ADMIN_ROLE, admin);
        fleetIdentity = fleetIdentity_;
        bondToken = IERC20(bondToken_);
    }

    // ──────────────────────────────────────────────
    // Bond Treasury (called by FleetIdentity)
    // ──────────────────────────────────────────────

    /// @notice Validate whitelist + consume quota for a sponsored bond.
    /// @dev Only callable by the FleetIdentity contract during claimUuidSponsored.
    ///      The actual NODL transfer is done separately by FleetIdentity via transferFrom.
    function consumeSponsoredBond(address user, uint256 amount) external {
        if (msg.sender != fleetIdentity) revert NotFleetIdentity();
        if (!isWhitelistedUser[user]) revert UserIsNotWhitelisted();
        if (bondToken.balanceOf(address(this)) < amount) revert InsufficientBondBalance();

        _checkedResetClaimed();
        _checkedUpdateClaimed(amount);

        // Approve only the exact amount needed for this claim
        bondToken.forceApprove(fleetIdentity, amount);
    }

    // ──────────────────────────────────────────────
    // Whitelist Management
    // ──────────────────────────────────────────────

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

    // ──────────────────────────────────────────────
    // ERC-20 Withdrawal
    // ──────────────────────────────────────────────

    /// @notice Withdraw ERC-20 tokens (e.g. excess NODL) from this contract.
    function withdrawTokens(address token, address to, uint256 amount) external {
        _checkRole(WITHDRAWER_ROLE);
        IERC20(token).safeTransfer(to, amount);
        emit TokensWithdrawn(token, to, amount);
    }

    // ──────────────────────────────────────────────
    // Paymaster Validation
    // ──────────────────────────────────────────────

    function _validateAndPayGeneralFlow(address from, address to, uint256 requiredETH) internal view override {
        if (to != fleetIdentity) revert DestinationNotAllowed();
        if (!isWhitelistedUser[from]) revert UserIsNotWhitelisted();
        if (address(this).balance < requiredETH) revert PaymasterBalanceTooLow();
    }

    function _validateAndPayApprovalBasedFlow(address, address, address, uint256, bytes memory, uint256)
        internal
        pure
        override
    {
        revert PaymasterFlowNotSupported();
    }
}

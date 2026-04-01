// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BasePaymaster} from "./BasePaymaster.sol";
import {QuotaControl} from "../QuotaControl.sol";

/// @notice ZkSync paymaster plus ERC-20 bond treasury for whitelisted contracts (e.g. `IBondTreasury` implementers).
/// @dev Holds ETH (sponsored gas) and bond token balance. Whitelisted users interact with `isWhitelistedContract`
///      destinations; bond consumers call `consumeSponsoredBond`, which checks caller + user whitelist, quota, balance,
///      then `forceApprove(msg.sender, amount)` for `transferFrom`.
///      Gas: `isWhitelistedContract[to] && isWhitelistedUser[from]`. Constructor seeds `address(this)` so management
///      txs can be sponsored once those EOAs are user-whitelisted. On-chain mutators use `WHITELIST_ADMIN_ROLE` /
///      `WITHDRAWER_ROLE` / `DEFAULT_ADMIN_ROLE`.
contract BondTreasuryPaymaster is BasePaymaster, QuotaControl {
    using SafeERC20 for IERC20;

    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    IERC20 public immutable bondToken;

    mapping(address => bool) public isWhitelistedUser;
    /// @notice Sponsored tx destinations and allowed `consumeSponsoredBond` callers.
    mapping(address => bool) public isWhitelistedContract;

    event WhitelistedUsersAdded(address[] users);
    event WhitelistedUsersRemoved(address[] users);
    event WhitelistedContractsAdded(address[] contracts);
    event WhitelistedContractsRemoved(address[] contracts);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

    error UserIsNotWhitelisted();
    error DestIsNotWhitelisted();
    error PaymasterBalanceTooLow();
    error CallerNotWhitelistedContract();
    error InsufficientBondBalance();
    error ZeroAddress();

    constructor(
        address admin,
        address withdrawer,
        address[] memory initialWhitelistedContracts,
        address bondToken_,
        uint256 initialQuota,
        uint256 initialPeriod
    ) BasePaymaster(admin, withdrawer) QuotaControl(initialQuota, initialPeriod, admin) {
        if (admin == address(0) || withdrawer == address(0)) revert ZeroAddress();
        if (bondToken_ == address(0)) revert ZeroAddress();

        _grantRole(WHITELIST_ADMIN_ROLE, admin);
        bondToken = IERC20(bondToken_);
        uint256 n = initialWhitelistedContracts.length;
        for (uint256 i = 0; i < n; i++) {
            if (initialWhitelistedContracts[i] == address(0)) revert ZeroAddress();
            isWhitelistedContract[initialWhitelistedContracts[i]] = true;
        }
        if (n > 0) {
            emit WhitelistedContractsAdded(initialWhitelistedContracts);
        }
        if (!isWhitelistedContract[address(this)]) {
            isWhitelistedContract[address(this)] = true;
            address[] memory selfDest = new address[](1);
            selfDest[0] = address(this);
            emit WhitelistedContractsAdded(selfDest);
        }
    }

    // ──────────────────────────────────────────────
    // Bond Treasury (whitelisted contracts)
    // ──────────────────────────────────────────────

    /// @notice Validate whitelist + consume quota for a sponsored bond.
    /// @dev Callable only by `isWhitelistedContract`. Caller pulls via `transferFrom`.
    function consumeSponsoredBond(address user, uint256 amount) external {
        if (!isWhitelistedContract[msg.sender]) revert CallerNotWhitelistedContract();
        if (!isWhitelistedUser[user]) revert UserIsNotWhitelisted();
        if (bondToken.balanceOf(address(this)) < amount) revert InsufficientBondBalance();

        _checkedResetClaimed();
        _checkedUpdateClaimed(amount);

        bondToken.forceApprove(msg.sender, amount);
    }

    // ──────────────────────────────────────────────
    // Whitelist Management
    // ──────────────────────────────────────────────

    function addWhitelistedUsers(address[] calldata users) external {
        _checkRole(WHITELIST_ADMIN_ROLE);
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert ZeroAddress();
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

    function addWhitelistedContracts(address[] calldata contracts_) external {
        _checkRole(WHITELIST_ADMIN_ROLE);
        for (uint256 i = 0; i < contracts_.length; i++) {
            if (contracts_[i] == address(0)) revert ZeroAddress();
            isWhitelistedContract[contracts_[i]] = true;
        }
        emit WhitelistedContractsAdded(contracts_);
    }

    function removeWhitelistedContracts(address[] calldata contracts_) external {
        _checkRole(WHITELIST_ADMIN_ROLE);
        for (uint256 i = 0; i < contracts_.length; i++) {
            isWhitelistedContract[contracts_[i]] = false;
        }
        emit WhitelistedContractsRemoved(contracts_);
    }

    // ──────────────────────────────────────────────
    // ERC-20 Withdrawal
    // ──────────────────────────────────────────────

    /// @notice Withdraw ERC-20 tokens (e.g. excess bond token) from this contract.
    function withdrawTokens(address token, address to, uint256 amount) external {
        _checkRole(WITHDRAWER_ROLE);
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensWithdrawn(token, to, amount);
    }

    // ──────────────────────────────────────────────
    // Paymaster Validation
    // ──────────────────────────────────────────────

    function _validateAndPayGeneralFlow(address from, address to, uint256 requiredETH) internal view override {
        if (!isWhitelistedContract[to]) revert DestIsNotWhitelisted();
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

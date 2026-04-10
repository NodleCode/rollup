// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuotaControl} from "../QuotaControl.sol";
import {WhitelistPaymaster} from "./WhitelistPaymaster.sol";

/// @notice ZkSync paymaster plus ERC-20 bond treasury for whitelisted contracts (e.g. `IBondTreasury` implementers).
/// @dev Extends `WhitelistPaymaster` (user + destination whitelist, gas sponsorship). Adds bond token balance,
///      `consumeSponsoredBond` with `QuotaControl`, per-user token allowance, and ERC-20 withdrawal.
///      Constructor seeds `address(this)` as a whitelisted destination so management txs can be sponsored
///      once those EOAs are user-whitelisted.
contract BondTreasuryPaymaster is WhitelistPaymaster, QuotaControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable bondToken;

    /// @notice Per-user remaining token allowance for sponsored bonds.
    mapping(address => uint256) public userBondAllowance;

    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);
    event UserBondAllowanceSet(address indexed user, uint256 newAllowance);
    event UserBondAllowanceIncreased(address indexed user, uint256 addedAmount, uint256 newAllowance);

    error CallerNotWhitelistedContract();
    error InsufficientBondBalance();
    error UserBondAllowanceExceeded();

    constructor(
        address admin,
        address whitelistAdmin,
        address withdrawer,
        address[] memory initialWhitelistedContracts,
        address[] memory initialWhitelistedUsers,
        address bondToken_,
        uint256 initialQuota,
        uint256 initialPeriod
    ) WhitelistPaymaster(admin, withdrawer) QuotaControl(initialQuota, initialPeriod, admin) {
        if (whitelistAdmin != admin) {
            _grantRole(WHITELIST_ADMIN_ROLE, whitelistAdmin);
        }
        bondToken = IERC20(bondToken_);

        uint256 n = initialWhitelistedContracts.length;
        for (uint256 i = 0; i < n; ++i) {
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

        uint256 m = initialWhitelistedUsers.length;
        for (uint256 j = 0; j < m; ++j) {
            isWhitelistedUser[initialWhitelistedUsers[j]] = true;
        }
        if (m > 0) {
            emit WhitelistedUsersAdded(initialWhitelistedUsers);
        }
    }

    /// @notice Validate whitelist + consume quota + decrement per-user allowance for a sponsored bond.
    /// @dev Callable only by `isWhitelistedContract`. Caller pulls via `transferFrom`.
    function consumeSponsoredBond(address user, uint256 amount) external {
        if (!isWhitelistedContract[msg.sender]) revert CallerNotWhitelistedContract();
        if (!isWhitelistedUser[user]) revert UserIsNotWhitelisted();
        if (bondToken.balanceOf(address(this)) < amount) revert InsufficientBondBalance();

        uint256 remaining = userBondAllowance[user];
        if (remaining < amount) revert UserBondAllowanceExceeded();
        unchecked {
            userBondAllowance[user] = remaining - amount;
        }

        _checkedResetClaimed();
        _checkedUpdateClaimed(amount);

        bondToken.forceApprove(msg.sender, amount);
    }

    /// @notice Set the total bond allowance for a user (overwrites previous value).
    function setUserBondAllowance(address user, uint256 allowance) external {
        _checkRole(WHITELIST_ADMIN_ROLE);
        userBondAllowance[user] = allowance;
        emit UserBondAllowanceSet(user, allowance);
    }

    /// @notice Add to a user's existing bond allowance.
    function increaseUserBondAllowance(address user, uint256 amount) external {
        _checkRole(WHITELIST_ADMIN_ROLE);
        uint256 newAllowance = userBondAllowance[user] + amount;
        userBondAllowance[user] = newAllowance;
        emit UserBondAllowanceIncreased(user, amount, newAllowance);
    }

    /// @notice Withdraw ERC-20 tokens (e.g. excess bond token) from this contract.
    function withdrawTokens(address token, address to, uint256 amount) external {
        _checkRole(WITHDRAWER_ROLE);
        IERC20(token).safeTransfer(to, amount);
        emit TokensWithdrawn(token, to, amount);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {BaseContentSign} from "./BaseContentSign.sol";

/**
 * @title ClickBounty
 * @notice This contract facilitates bounty rewards for specific token IDs. An Oracle triggers
 *         the payments (bounties), and a small top-N list of highest bounties is maintained on-chain.
 *
 * @dev
 * - Utilizes an ERC20 token both for bounty payouts and fee collection.
 * - Only addresses with the ORACLE_ROLE can call `pay()`.
 * - Only addresses with the DEFAULT_ADMIN_ROLE can call administrative functions such as `withdraw()`
 *   and `setEntryFee()`.
 * - Maintains a leaderboard (top-N) of the highest bounties paid. The size of the leaderboard is fixed
 *   at `LEADERBOARD_SIZE`.
 */
contract ClickBounty is AccessControl {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /**
     * @dev Holds a token’s URI and the associated bounty amount.
     */
    struct URIBounty {
        string uri;
        uint256 bounty;
    }

    // -------------------------------------------------------------------------
    // Constants and Roles
    // -------------------------------------------------------------------------

    /// @dev Role identifier for the Oracle. Accounts with this role can trigger payments via `pay()`.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @notice Maximum number of tracked top winners (token IDs).
    /// @dev The leaderboard cannot exceed this size.
    uint256 public constant LEADERBOARD_SIZE = 5;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /**
     * @notice Mapping from tokenId to the bounty amount awarded.
     * @dev If a tokenId’s bounty is zero, it means no bounty has been paid yet.
     */
    mapping(uint256 => uint256) public bounties;

    /**
     * @dev An array of token IDs that currently have the highest bounties.
     *      This is not strictly sorted, but each entry is among the largest
     *      bounties recorded so far.
     */
    uint256[] private _leaderboard;

    /**
     * @notice The entry fee (in ERC20 tokens) that partially or fully covers the bounty payment.
     * @dev If `pay()` is called with an `amount` less than `entryFee`, the shortfall is collected
     *      from the token’s owner. If `amount` exceeds `entryFee`, the surplus is paid out to
     *      the token’s owner.
     */
    uint256 public entryFee = 100;

    /// @notice The ERC20 token used for payments (bounties), fees, and withdrawals.
    IERC20 public immutable token;

    /**
     * @notice A reference to a BaseContentSign contract, which manages ownership and URIs for the tokens.
     */
    BaseContentSign public immutable contentSign;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a token is added to or updated in the leaderboard.
     * @param tokenId The token ID that entered or replaced an entry in the leaderboard.
     * @param bounty  The bounty amount awarded to that token ID.
     */
    event NewLeaderboardEntry(uint256 indexed tokenId, uint256 bounty);

    /**
     * @notice Emitted when a bounty is successfully paid to a token ID.
     * @param tokenId The token ID receiving the bounty.
     * @param amount  The total bounty amount in `token`.
     */
    event BountyIssued(uint256 indexed tokenId, uint256 amount);

    /**
     * @dev Emitted when the entry fee is updated.
     * @param entryFee The new entry fee value.
     */
    event EntryFeeUpdated(uint256 entryFee);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /**
     * @notice Thrown when attempting to pay a bounty to a token ID that has already received one.
     */
    error BountyAlreadyPaid(uint256 tokenId);

    /**
     * @dev Error indicating that the bounty amount is zero.
     * @param tokenId The ID of the token associated with the zero bounty.
     */
    error ZeroBounty(uint256 tokenId);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Initializes the contract with the given roles, token address, contentSign reference, and admin address.
     * @param oracle The address granted the ORACLE_ROLE.
     * @param _token The ERC20 token address used for payments.
     * @param _contentSign The address of the BaseContentSign contract that handles token ownership and URIs.
     * @param admin The address granted DEFAULT_ADMIN_ROLE.
     *
     * Emits:
     * - RoleGranted events for assigning ORACLE_ROLE and DEFAULT_ADMIN_ROLE.
     */
    constructor(address oracle, address _token, address _contentSign, address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ROLE, oracle);
        token = IERC20(_token);
        contentSign = BaseContentSign(_contentSign);
    }

    // -------------------------------------------------------------------------
    // Admin Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Sets the entry fee for bounties.
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE.
     * @param _entryFee The new entry fee in units of `token`.
     */
    function setEntryFee(uint256 _entryFee) external {
        _checkRole(DEFAULT_ADMIN_ROLE);
        entryFee = _entryFee;
        emit EntryFeeUpdated(_entryFee);
    }

    /**
     * @notice Withdraws a specified amount of tokens to a given recipient address.
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE.
     * @param recipient The address that will receive the tokens.
     * @param amount    The amount of tokens to withdraw.
     *
     * Emits:
     * - A transfer event from the ERC20 token contract to `recipient`.
     */
    function withdraw(address recipient, uint256 amount) external {
        _checkRole(DEFAULT_ADMIN_ROLE);
        token.safeTransfer(recipient, amount);
    }

    // -------------------------------------------------------------------------
    // Oracle Function
    // -------------------------------------------------------------------------

    /**
     * @notice Pays a bounty for a given token ID.
     *         - If `amount < entryFee`, the difference is collected from the token’s owner.
     *         - If `amount > entryFee`, the surplus is paid out to the owner.
     *
     * @dev Only callable by addresses with ORACLE_ROLE.
     *
     * Requirements:
     * - The token must not have been paid before (`bounties[tokenId] == 0`).
     *
     * @param tokenId The token ID to which the bounty is awarded.
     * @param amount  The bounty amount in `token`.
     *
     * Emits:
     * - A transfer event from the token’s owner to this contract (if `amount < entryFee`).
     * - A transfer event from this contract to the token’s owner (if `amount > entryFee`).
     * - A {BountyIssued} event upon successful bounty payment.
     *
     * Reverts:
     * - If `bounties[tokenId] != 0` (bounty already paid).
     */
    function awardBounty(uint256 tokenId, uint256 amount) external {
        _checkRole(ORACLE_ROLE);
        // Ensure the bounty is non-zero
        if (amount == 0) {
            revert ZeroBounty(tokenId);
        }
        // Ensure this token ID hasn't been paid yet
        if (bounties[tokenId] != 0) {
            revert BountyAlreadyPaid(tokenId);
        }

        // Identify the token owner via the contentSign contract
        address owner = contentSign.ownerOf(tokenId);

        // If the bounty is smaller than the entry fee, collect the shortfall from the owner
        if (amount < entryFee) {
            token.safeTransferFrom(owner, address(this), entryFee - amount);
        }

        // Record the bounty
        bounties[tokenId] = amount;

        // If the bounty is larger than the entry fee, pay out the surplus to the owner
        if (amount > entryFee) {
            token.safeTransfer(owner, amount - entryFee);
        }

        emit BountyIssued(tokenId, amount);

        // Update the on-chain leaderboard
        _updateLeaderboard(tokenId, amount);
    }

    // -------------------------------------------------------------------------
    // View Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Retrieves an array of `(URI, bountyAmount)` for each token in the top winners list.
     * @dev The size of the returned array is up to `LEADERBOARD_SIZE`, but might be smaller if
     *      fewer than `LEADERBOARD_SIZE` bounties have been paid.
     * @return uriBounties A dynamic array of `URIBounty` structs, each with `uri` and `bounty`.
     */
    function getLeaderboard() external view returns (URIBounty[] memory uriBounties) {
        uriBounties = new URIBounty[](_leaderboard.length);
        for (uint256 i = 0; i < _leaderboard.length; i++) {
            uriBounties[i] = URIBounty({uri: contentSign.tokenURI(_leaderboard[i]), bounty: bounties[_leaderboard[i]]});
        }
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    /**
     * @dev Updates the leaderboard (`_leaderboard`) if `tokenId` is among the top bounties.
     *      - If the leaderboard is not full, we simply append the new entry.
     *      - Otherwise, we find the smallest bounty in `_leaderboard`; if `amount` exceeds that,
     *        we replace it.
     *
     * @param tokenId The token ID that may enter the leaderboard.
     * @param amount  The bounty amount to compare.
     *
     * Emits:
     * - A {NewLeaderboardEntry} event if a replacement or addition occurs.
     */
    function _updateLeaderboard(uint256 tokenId, uint256 amount) private {
        // If the leaderboard is not at capacity, just add the new entry
        if (_leaderboard.length < LEADERBOARD_SIZE) {
            _leaderboard.push(tokenId);
            emit NewLeaderboardEntry(tokenId, amount);
            return;
        }

        // Find the smallest bounty in the current leaderboard
        uint256 smallestIndex = 0;
        uint256 smallestAmount = bounties[_leaderboard[0]];
        for (uint256 i = 1; i < _leaderboard.length; i++) {
            uint256 currentAmount = bounties[_leaderboard[i]];
            if (currentAmount < smallestAmount) {
                smallestAmount = currentAmount;
                smallestIndex = i;
            }
        }

        // If the new amount is bigger than the smallest in the leaderboard, replace it
        if (amount > smallestAmount) {
            _leaderboard[smallestIndex] = tokenId;
            emit NewLeaderboardEntry(tokenId, amount);
        }
    }
}

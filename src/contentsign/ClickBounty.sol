// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {BaseContentSign} from "./BaseContentSign.sol";

/**
 * @title ClickBounty
 * @notice This contract facilitates bounty rewards for specific token IDs (managed by a BaseContentSign contract).
 *         The bounty mechanism involves an optional entry fee that must be paid by the token owner prior to
 *         receiving a bounty. Only addresses with the ORACLE_ROLE can award a bounty, and only addresses
 *         with the DEFAULT_ADMIN_ROLE can modify administrative parameters or withdraw funds.
 *
 * @dev
 * - Each token can only receive one bounty. Once a token's bounty is set, further calls to award it will revert.
 * - The contract maintains a simple on-chain leaderboard of the top bounties (up to LEADERBOARD_SIZE).
 */
contract ClickBounty is AccessControl {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /**
     * @dev Holds a token URI and the associated bounty amount for leaderboard queries.
     */
    struct URIBounty {
        string uri;
        uint256 bounty;
    }

    /**
     * @dev Represents the overall status of a token's fee payment and awarded bounty amount.
     * @param feePaid Indicates whether the token’s entry fee has been paid.
     * @param amount  The bounty amount awarded to the token. Zero if not yet awarded.
     */
    struct BountyStatus {
        bool feePaid;
        uint256 amount;
    }

    // -------------------------------------------------------------------------
    // Constants and Roles
    // -------------------------------------------------------------------------

    /// @dev Role identifier for the Oracle. Accounts with this role can trigger bounty awards via `awardBounty()`.
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    /// @notice Maximum number of tracked top winners (token IDs).
    /// @dev The leaderboard cannot exceed this size.
    uint256 public constant LEADERBOARD_SIZE = 5;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /**
     * @notice A mapping from token ID to its BountyStatus.
     * @dev `bounties[tokenId].feePaid` must be true for the token to be eligible for awarding.
     *      Once `bounties[tokenId].amount` is set, that token is considered to have a bounty.
     */
    mapping(uint256 => BountyStatus) public bounties;

    /**
     * @dev An array of token IDs that currently have the highest bounties.
     *      Not strictly sorted. Each entry is among the largest bounties recorded so far.
     *      The size will never exceed LEADERBOARD_SIZE.
     */
    uint256[] private _leaderboard;

    /**
     * @notice The entry fee (in ERC20 tokens) that a token owner must pay to be eligible for a bounty.
     */
    uint256 public entryFee;

    /// @notice The ERC20 token used for fee collection, awarding bounties, and withdrawals.
    IERC20 public immutable token;

    /**
     * @notice A reference to a BaseContentSign contract, which manages ownership and URIs for the tokens.
     * @dev The contract calls `contentSign.ownerOf(tokenId)` to identify token owners and
     *      `contentSign.tokenURI(tokenId)` to retrieve URIs for leaderboard queries.
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
     * @notice Emitted when a bounty is successfully awarded to a token ID.
     * @param tokenId The token ID receiving the bounty.
     * @param amount  The total bounty amount in `token`.
     */
    event BountyIssued(uint256 indexed tokenId, uint256 amount);

    /**
     * @notice Emitted when the entry fee is updated.
     * @param entryFee The new entry fee value.
     */
    event EntryFeeUpdated(uint256 entryFee);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /**
     * @notice Thrown when attempting to award a bounty to a token ID that has already received one.
     */
    error BountyAlreadyPaid(uint256 tokenId);

    /**
     * @notice Thrown when trying to award a bounty with a zero amount, which is not allowed.
     */
    error ZeroBounty(uint256 tokenId);

    /**
     * @notice Thrown when the Oracle attempts to award a bounty to a token that hasn't paid the entry fee yet.
     */
    error FeeNotPaid(uint256 tokenId);

    /**
     * @notice Thrown if the token's entry fee has already been paid.
     */
    error FeeAlreadyPaid(uint256 tokenId);

    /**
     * @notice Thrown when a non-owner tries to pay the entry fee for a token.
     */
    error OnlyOwnerCanPayEntryFee(uint256 tokenId);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Initializes the contract, setting up roles and key parameters.
     * @param _oracle     The address granted the ORACLE_ROLE, authorized to call `awardBounty()`.
     * @param _token      The address of the ERC20 token used for fees and bounties.
     * @param _contentSign The address of a BaseContentSign contract for verifying token ownership and retrieving URIs.
     * @param _entryFee   The initial fee required to be paid by a token’s owner before it can receive a bounty.
     * @param _admin      The address granted DEFAULT_ADMIN_ROLE, authorized for administrative calls.
     *
     * Emits:
     * - RoleGranted(DEFAULT_ADMIN_ROLE, _admin)
     * - RoleGranted(ORACLE_ROLE, _oracle)
     */
    constructor(address _oracle, address _token, address _contentSign, uint256 _entryFee, address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORACLE_ROLE, _oracle);

        token = IERC20(_token);
        contentSign = BaseContentSign(_contentSign);
        entryFee = _entryFee;
    }

    // -------------------------------------------------------------------------
    // Public / External Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Allows the owner of a given token to pay the entry fee, making that token eligible for a bounty.
     * @dev If the fee is already paid, this reverts with `FeeAlreadyPaid`.
     *      If called by someone other than the token's owner, this reverts with `OnlyOwnerCanPayEntryFee`.
     *
     * @param tokenId The token ID whose fee is being paid.
     *
     * Emits:
     * - A transfer event from the token’s owner to this contract for `entryFee` tokens.
     */
    function payEntryFee(uint256 tokenId) external {
        BountyStatus storage status = bounties[tokenId];

        if (status.feePaid) {
            revert FeeAlreadyPaid(tokenId);
        }

        address owner = contentSign.ownerOf(tokenId);
        if (msg.sender != owner) {
            revert OnlyOwnerCanPayEntryFee(tokenId);
        }

        token.safeTransferFrom(owner, address(this), entryFee);
        status.feePaid = true;
    }

    // -------------------------------------------------------------------------
    // Admin Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Sets the entry fee for future bounties.
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE.
     * @param _entryFee The new entry fee in units of `token`.
     *
     * Emits:
     * - `EntryFeeUpdated(_entryFee)` event.
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
     * @notice Awards a bounty for a given token ID.
     *         - The token’s entry fee must have been paid beforehand.
     *         - The token must not have received a bounty already.
     *         - The bounty must be greater than zero.
     *
     * @dev Only callable by addresses with ORACLE_ROLE.
     *
     * @param tokenId The token ID to which the bounty is awarded.
     * @param amount  The bounty amount in `token`. Must be non-zero.
     *
     * Emits:
     * - `BountyIssued(tokenId, amount)` upon successful bounty payment.
     * - A transfer event from this contract to the token’s owner for `amount` tokens.
     * - `NewLeaderboardEntry(tokenId, amount)` if the leaderboard is updated.
     *
     * Reverts:
     * - `ZeroBounty(tokenId)` if `amount == 0`.
     * - `FeeNotPaid(tokenId)` if the token’s entry fee was not yet paid.
     * - `BountyAlreadyPaid(tokenId)` if a bounty is already set for the token.
     */
    function awardBounty(uint256 tokenId, uint256 amount) external {
        _checkRole(ORACLE_ROLE);

        if (amount == 0) {
            revert ZeroBounty(tokenId);
        }
        BountyStatus storage status = bounties[tokenId];

        if (!status.feePaid) {
            revert FeeNotPaid(tokenId);
        }
        if (status.amount != 0) {
            revert BountyAlreadyPaid(tokenId);
        }

        address owner = contentSign.ownerOf(tokenId);

        // Record the bounty
        status.amount = amount;

        // Transfer bounty to the owner
        token.safeTransfer(owner, amount);

        emit BountyIssued(tokenId, amount);

        // Update the on-chain leaderboard
        _updateLeaderboard(tokenId, amount);
    }

    // -------------------------------------------------------------------------
    // View Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Retrieves an array of `(URI, bountyAmount)` for each token in the top winners list.
     * @dev The size of the returned array is at most `LEADERBOARD_SIZE`. It may be smaller if fewer
     *      tokens have received bounties. The order is not guaranteed to be sorted.
     *
     * @return uriBounties A dynamic array of `URIBounty` structs, each containing a token URI and its bounty amount.
     */
    function getLeaderboard() external view returns (URIBounty[] memory uriBounties) {
        uriBounties = new URIBounty[](_leaderboard.length);
        for (uint256 i = 0; i < _leaderboard.length; i++) {
            uint256 tid = _leaderboard[i];
            uriBounties[i] = URIBounty({uri: contentSign.tokenURI(tid), bounty: bounties[tid].amount});
        }
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    /**
     * @dev Updates the leaderboard (`_leaderboard`) if `tokenId` is among the top bounties.
     *      1. If the leaderboard is not full, push the new token ID.
     *      2. Otherwise, find the smallest bounty in `_leaderboard`. If the new bounty is larger, replace it.
     *
     * @param tokenId The token ID that may enter the leaderboard.
     * @param amount  The bounty amount to compare.
     *
     * Emits:
     * - `NewLeaderboardEntry(tokenId, amount)` if a replacement or addition occurs.
     */
    function _updateLeaderboard(uint256 tokenId, uint256 amount) private {
        // If the leaderboard is not at capacity, add the new entry
        if (_leaderboard.length < LEADERBOARD_SIZE) {
            _leaderboard.push(tokenId);
            emit NewLeaderboardEntry(tokenId, amount);
            return;
        }

        // If it's at capacity, find the smallest bounty
        uint256 smallestIndex = 0;
        uint256 smallestAmount = bounties[_leaderboard[0]].amount;
        for (uint256 i = 1; i < _leaderboard.length; i++) {
            uint256 currentAmount = bounties[_leaderboard[i]].amount;
            if (currentAmount < smallestAmount) {
                smallestAmount = currentAmount;
                smallestIndex = i;
            }
        }

        // Replace the smallest if the new amount is bigger
        if (amount > smallestAmount) {
            _leaderboard[smallestIndex] = tokenId;
            emit NewLeaderboardEntry(tokenId, amount);
        }
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {ITipping} from "./ITipping.sol";

/// @dev ERC-1155 supply extension (OpenZeppelin ERC1155Supply); optional on the collection.
interface IERC1155SupplyLike {
    function totalSupply(uint256 id) external view returns (uint256);
}

/**
 * @title Tipping
 * @notice Immutable, agnostic tipping (nft-feed-indexer design §6.2, v2 of 2026-10-28). No proxy,
 *         no upgrade path, no pause, no backend signature: an allowance granted to this address
 *         can only ever be spent by the approver's own `tip`/`tipAccount` calls, because
 *         `transferFrom` is only called with `from == msg.sender`. The contract holds no funds.
 *
 * Post tips resolve the recipient from the NFT: `ownerOf(tokenId)` for ERC-721, the ERC-2981
 * royalty receiver for ERC-1155 (an edition has many holders; its royalty receiver is where the
 * creator is paid). The caller states the standard; a wrong standard simply fails to resolve.
 * The lookups are `view` calls (STATICCALL), so a hostile collection can only make the tip
 * revert or burn the tipper's own gas. Account tips name their recipient directly.
 *
 * Roles: DEFAULT_ADMIN_ROLE (fee ≤ 10 %, fee recipient).
 */
contract Tipping is ITipping, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;

    uint16 public feeBps;
    address public feeRecipient;

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        feeRecipient = admin;
        emit FeeUpdated(0);
        emit FeeRecipientUpdated(admin);
    }

    // ───────── Tipping ─────────

    /// @inheritdoc ITipping
    function tip(address collection, Standard standard, uint256 tokenId, address token, uint256 amount)
        external
        nonReentrant
    {
        address recipient = _resolve(collection, standard, tokenId);
        uint256 fee = _pay(token, recipient, amount);
        emit Tipped(msg.sender, collection, tokenId, token, recipient, amount, fee);
    }

    /// @inheritdoc ITipping
    function tipAccount(address token, address to, uint256 amount) external nonReentrant {
        uint256 fee = _pay(token, to, amount);
        emit AccountTipped(msg.sender, to, token, amount, fee);
    }

    /// @inheritdoc ITipping
    function recipientOf(address collection, Standard standard, uint256 tokenId) external view returns (address) {
        return _resolve(collection, standard, tokenId);
    }

    /// @dev ERC-721: the current owner. ERC-1155: the ERC-2981 receiver for the id, after
    ///      rejecting ids whose tracked supply is zero (when the collection exposes totalSupply(id)).
    function _resolve(address collection, Standard standard, uint256 tokenId) internal view returns (address) {
        if (collection.code.length == 0) revert NotAContract(collection);
        if (standard == Standard.ERC721) {
            try IERC721(collection).ownerOf(tokenId) returns (address owner) {
                if (owner == address(0)) revert NoRecipient(collection, tokenId);
                return owner;
            } catch {
                revert InvalidToken(collection, tokenId);
            }
        }
        try IERC1155SupplyLike(collection).totalSupply(tokenId) returns (uint256 supply) {
            if (supply == 0) revert InvalidToken(collection, tokenId);
        } catch {
            // No supply extension: the royalty lookup below is the only check available.
        }
        try IERC2981(collection).royaltyInfo(tokenId, BPS) returns (address receiver, uint256) {
            if (receiver == address(0)) revert NoRecipient(collection, tokenId);
            return receiver;
        } catch {
            revert NoRecipient(collection, tokenId);
        }
    }

    /// @dev Shared guards and transfers. Only ever pulls from msg.sender: the property the
    ///      immutability argument rests on. Returns the fee taken.
    function _pay(address token, address to, uint256 amount) internal returns (uint256 fee) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to == msg.sender) revert SelfTip();
        fee = (amount * feeBps) / BPS;
        IERC20(token).safeTransferFrom(msg.sender, to, amount - fee);
        if (fee > 0) IERC20(token).safeTransferFrom(msg.sender, feeRecipient, fee);
    }

    // ───────── Admin ─────────

    function setFee(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        feeBps = bps;
        emit FeeUpdated(bps);
    }

    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        // No rescue path exists in an immutable contract: fees sent to this address are lost.
        if (recipient == address(this)) revert InvalidFeeRecipient(recipient);
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }
}

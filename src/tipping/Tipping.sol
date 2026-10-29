// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {ITipping} from "./ITipping.sol";

/// @dev Optional surfaces an ERC-1155 collection may expose; each is probed behind try/catch.
interface IERC1155SupplyLike {
    function totalSupply(uint256 id) external view returns (uint256);
}

interface IRoleLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IOwnableLike {
    function owner() external view returns (address);
}

/**
 * @title Nodle Tipping v2
 * @author Nodle
 * @notice Lets anyone tip an NFT post or an account with any ERC-20, on zkSync Era.
 *
 * @dev How a post tip works
 *      The caller passes the collection, its standard (ERC-721 or ERC-1155), the token id, the
 *      recipient, the ERC-20 and the amount. The contract does not decide who gets paid; it
 *      checks that the caller's recipient is legitimate for that NFT:
 *        - ERC-721: `recipient` must be `ownerOf(tokenId)`.
 *        - ERC-1155: the id must exist (non-zero tracked supply, when the collection exposes
 *          `totalSupply(id)`) and `recipient` must hold the collection's `OWNER_ROLE` (Nodle
 *          user collections grant it to their creator), or be its Ownable `owner()`, or be its
 *          ERC-2981 royalty receiver for the id.
 *      Nothing is enumerated from the NFT, only verified, so any collection works without a
 *      registry or a backend signature. The checks are `view` calls (STATICCALL) behind
 *      try/catch: a hostile collection can only make the tip revert or burn the caller's gas.
 *      Account tips (`tipAccount`) name their recipient with no check.
 *
 *      Money
 *      Tokens move with `transferFrom(msg.sender, …)` only: an allowance granted to this
 *      contract can be spent solely by the approver's own calls. The optional protocol fee
 *      (at most 10 %, 0 at launch) stays in the contract and `withdrawFees(token)`, callable by
 *      anyone, sends the contract's whole balance of that token to the fee recipient. Fees are
 *      the only balance the contract ever holds; a token sent here by mistake is recovered the
 *      same way. Self-tips and zero amounts revert.
 *
 *      Governance
 *      Immutable: no proxy, no upgrade, no pause. `DEFAULT_ADMIN_ROLE` (a multisig) can only
 *      change the fee and the fee recipient. Events `Tipped`, `AccountTipped`, `FeeUpdated`,
 *      `FeeRecipientUpdated` and `FeesWithdrawn` are the surface the Nodle feed indexer reads.
 */
contract Tipping is ITipping, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    /// @dev Role Nodle user collections grant to their creator (keccak256("OWNER_ROLE")).
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

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
    function tip(
        address collection,
        NFTStandard standard,
        uint256 tokenId,
        address recipient,
        address token,
        uint256 amount
    ) external nonReentrant {
        if (!isValidTipRecipient(collection, standard, tokenId, recipient)) {
            revert NotRecipient(collection, tokenId, recipient);
        }
        uint256 fee = _transferTipWithFee(token, recipient, amount);
        emit Tipped(msg.sender, collection, tokenId, token, recipient, amount, fee);
    }

    /// @inheritdoc ITipping
    function tipAccount(address token, address to, uint256 amount) external nonReentrant {
        uint256 fee = _transferTipWithFee(token, to, amount);
        emit AccountTipped(msg.sender, to, token, amount, fee);
    }

    /// @inheritdoc ITipping
    /// @dev ERC-721: `recipient` must be the current owner. ERC-1155: the id must exist (tracked
    ///      supply, when exposed, must be non-zero) and `recipient` must hold OWNER_ROLE, be the
    ///      Ownable owner, or be the ERC-2981 receiver for the id. Reverts for non-contracts and
    ///      invalid tokens; returns false for a wrong recipient.
    function isValidTipRecipient(address collection, NFTStandard standard, uint256 tokenId, address recipient)
        public
        view
        returns (bool)
    {
        if (collection.code.length == 0) revert NotAContract(collection);
        if (recipient == address(0)) return false;
        if (standard == NFTStandard.ERC721) {
            try IERC721(collection).ownerOf(tokenId) returns (address owner) {
                return owner == recipient;
            } catch {
                revert InvalidToken(collection, tokenId);
            }
        }
        try IERC1155SupplyLike(collection).totalSupply(tokenId) returns (uint256 supply) {
            if (supply == 0) revert InvalidToken(collection, tokenId);
        } catch {
            // No supply extension: nothing to check here.
        }
        try IRoleLike(collection).hasRole(OWNER_ROLE, recipient) returns (bool held) {
            if (held) return true;
        } catch {}
        try IOwnableLike(collection).owner() returns (address owner) {
            if (owner == recipient) return true;
        } catch {}
        try IERC2981(collection).royaltyInfo(tokenId, BPS) returns (address receiver, uint256) {
            if (receiver == recipient) return true;
        } catch {}
        return false;
    }

    /// @dev Shared guards and transfers. Only ever pulls from msg.sender: the property the
    ///      immutability argument rests on. Returns the fee taken.
    function _transferTipWithFee(address token, address to, uint256 amount) internal returns (uint256 fee) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to == msg.sender) revert SelfTip();
        fee = (amount * feeBps) / BPS;
        IERC20(token).safeTransferFrom(msg.sender, to, amount - fee);
        if (fee > 0) IERC20(token).safeTransferFrom(msg.sender, address(this), fee);
    }

    /// @inheritdoc ITipping
    function withdrawFees(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        address to = feeRecipient;
        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(token, to, amount);
    }

    // ───────── Admin ─────────

    function setFee(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        feeBps = bps;
        emit FeeUpdated(bps);
    }

    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        // Withdrawing to itself would be a no-op: fees could never leave the contract.
        if (recipient == address(this)) revert InvalidFeeRecipient(recipient);
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }
}

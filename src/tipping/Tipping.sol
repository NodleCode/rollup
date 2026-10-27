// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ITipping} from "./ITipping.sol";

/// @dev The subset of ERC1155Supply the resolver reads.
interface IERC1155Supply {
    function totalSupply(uint256 id) external view returns (uint256);
}

/**
 * @title Tipping
 * @notice Immutable NODL tipping for Nodle NFTs (nft-feed-indexer design §6.2). No proxy and
 *         no upgrade path on purpose: an allowance granted to this address can only ever be
 *         spent by the approver's own `tip` calls, because `transferFrom` is only called with
 *         `from == msg.sender`. Everything that may change lives in storage behind roles.
 *
 * Recipient resolution (never caller-supplied):
 *   1. `contentSignAllowed[collection]`  → `ownerOf(tokenId)`.
 *   2. `creatorOf[collection] != 0`      → ERC-2981 receiver for the token if non-zero,
 *                                           else the registered creator. ERC-1155 ids with
 *                                           `totalSupply == 0` revert.
 *   3. otherwise                         → `UnknownCollection`.
 *
 * Roles: DEFAULT_ADMIN_ROLE (fee, fee recipient, minimum, pause), REGISTRY_ROLE (allowlist,
 * creator registry). `registerCollection` is permissionless for a collection's OWNER_ROLE.
 */
contract Tipping is ITipping, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    /// @dev OWNER_ROLE of the factory collections (UserCollection721/1155).
    bytes32 public constant COLLECTION_OWNER_ROLE = keccak256("OWNER_ROLE");
    uint16 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    /// @dev Gas cap for every static lookup into a collection. Checked on EraVM (zkSync Era
    ///      mainnet, 2026-10-27) through the real contracts with `eth_call` gas limits: a trivial
    ///      call needs ~59k including the node's call overhead, and the heaviest lookup
    ///      (`royaltyInfo` through The Turtle's ERC1967 proxy) ~70k, so each lookup itself is
    ///      well under 12k. See test/tipping/TippingZkSyncFork.t.sol.
    uint256 public constant LOOKUP_GAS = 100_000;

    IERC20 private immutable _nodl;

    uint256 public minTipAmount;
    uint16 public feeBps;
    address public feeRecipient;
    mapping(address collection => bool) public contentSignAllowed;
    mapping(address collection => address creator) public creatorOf;

    constructor(address nodlToken, address admin, address registry, uint256 initialMinTip) {
        if (nodlToken == address(0) || admin == address(0) || registry == address(0)) revert ZeroAddress();
        _nodl = IERC20(nodlToken);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_ROLE, registry);
        minTipAmount = initialMinTip;
        feeRecipient = admin;
        emit MinTipUpdated(initialMinTip);
        emit FeeUpdated(0);
        emit FeeRecipientUpdated(admin);
    }

    // ───────── Tipping ─────────

    /// @inheritdoc ITipping
    function tip(address collection, uint256 tokenId, uint256 amount) external whenNotPaused nonReentrant {
        // Zero tips are never meaningful, even when the admin sets the minimum to zero.
        if (amount == 0 || amount < minTipAmount) revert BelowMinimum(amount, minTipAmount);
        address recipient = _resolve(collection, tokenId);
        if (recipient == msg.sender) revert SelfTip();

        uint256 fee = (amount * feeBps) / BPS;
        // Only ever pulls from msg.sender: the property the immutability argument rests on.
        _nodl.safeTransferFrom(msg.sender, recipient, amount - fee);
        if (fee > 0) _nodl.safeTransferFrom(msg.sender, feeRecipient, fee);

        emit Tipped(msg.sender, collection, tokenId, recipient, amount, fee);
    }

    /// @inheritdoc ITipping
    function resolveRecipient(address collection, uint256 tokenId) external view returns (address) {
        return _resolve(collection, tokenId);
    }

    function _resolve(address collection, uint256 tokenId) internal view returns (address recipient) {
        if (contentSignAllowed[collection]) {
            (bool ok, bytes memory data) =
                collection.staticcall{gas: LOOKUP_GAS}(abi.encodeCall(IERC721.ownerOf, (tokenId)));
            if (!ok || data.length < 32) revert UnknownToken(collection, tokenId);
            recipient = abi.decode(data, (address));
            if (recipient == address(0)) revert NoRecipient(collection, tokenId);
            return recipient;
        }

        address creator = creatorOf[collection];
        if (creator == address(0)) revert UnknownCollection(collection);

        if (_supports(collection, type(IERC1155).interfaceId)) {
            (bool ok, bytes memory data) =
                collection.staticcall{gas: LOOKUP_GAS}(abi.encodeCall(IERC1155Supply.totalSupply, (tokenId)));
            if (!ok || data.length < 32 || abi.decode(data, (uint256)) == 0) revert UnknownToken(collection, tokenId);
        }

        (bool rOk, bytes memory rData) =
            collection.staticcall{gas: LOOKUP_GAS}(abi.encodeCall(IERC2981.royaltyInfo, (tokenId, 1e18)));
        if (rOk && rData.length >= 64) {
            (address receiver,) = abi.decode(rData, (address, uint256));
            if (receiver != address(0)) return receiver;
        }
        return creator;
    }

    function _supports(address target, bytes4 interfaceId) internal view returns (bool) {
        (bool ok, bytes memory data) =
            target.staticcall{gas: LOOKUP_GAS}(abi.encodeCall(IERC165.supportsInterface, (interfaceId)));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    // ───────── Registry ─────────

    /// @inheritdoc ITipping
    /// @dev Permissionless: succeeds only for an account holding the collection's OWNER_ROLE,
    ///      and only once. An entry set by REGISTRY_ROLE wins; changes go through the operator.
    ///      Any contract that attests OWNER_ROLE for the caller can be registered, not only
    ///      factory collections; the indexer records such collections as UNKNOWN.
    function registerCollection(address collection) external {
        if (collection == address(0)) revert ZeroAddress();
        if (creatorOf[collection] != address(0)) revert AlreadyRegistered(collection);
        (bool ok, bytes memory data) = collection.staticcall{gas: LOOKUP_GAS}(
            abi.encodeCall(IAccessControl.hasRole, (COLLECTION_OWNER_ROLE, msg.sender))
        );
        if (!ok || data.length < 32 || !abi.decode(data, (bool))) revert NotCollectionOwner(collection, msg.sender);
        creatorOf[collection] = msg.sender;
        emit CreatorSet(collection, msg.sender);
    }

    function setCreator(address collection, address creator) external onlyRole(REGISTRY_ROLE) {
        if (collection == address(0)) revert ZeroAddress();
        creatorOf[collection] = creator;
        emit CreatorSet(collection, creator);
    }

    function setCollectionAllowed(address collection, bool allowed) external onlyRole(REGISTRY_ROLE) {
        if (collection == address(0)) revert ZeroAddress();
        contentSignAllowed[collection] = allowed;
        emit CollectionAllowed(collection, allowed);
    }

    // ───────── Admin ─────────

    function setMinTipAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minTipAmount = amount;
        emit MinTipUpdated(amount);
    }

    function setFee(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh(bps);
        feeBps = bps;
        emit FeeUpdated(bps);
    }

    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        // No rescue path exists in an immutable contract: fees sent here or to the token are lost.
        if (recipient == address(this) || recipient == address(_nodl)) revert InvalidFeeRecipient(recipient);
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @inheritdoc ITipping
    function nodl() external view returns (address) {
        return address(_nodl);
    }
}

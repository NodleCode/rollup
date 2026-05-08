// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Standard, CreateParams721, CreateParams1155} from "./CollectionTypes.sol";

/**
 * @title ICollectionFactory
 * @notice Public API for the operator-triggered NFT collection factory.
 * @dev See `src/collections/doc/spec/user-collections-specification.md` for the
 *      full architectural specification.
 */
interface ICollectionFactory {
    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a new per-collection `ERC1967Proxy` is deployed and initialized.
    /// @param creator The address that received `OWNER_ROLE` on the new collection.
    /// @param collection The address of the newly-deployed per-collection proxy.
    /// @param standard The token standard (ERC721 or ERC1155).
    /// @param externalId The off-chain reconciliation identifier supplied by the operator.
    event CollectionCreated(
        address indexed creator,
        address indexed collection,
        Standard standard,
        bytes32 indexed externalId
    );

    /// @notice Emitted when admin updates an implementation pointer for future per-collection proxies.
    event ImplementationUpdated(Standard standard, address newImpl);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    /// @notice Thrown when an `externalId` has already been consumed by a prior creation.
    error ExternalIdAlreadyUsed(bytes32 externalId);

    /// @notice Thrown when `externalId == bytes32(0)`.
    error InvalidExternalId();

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when an implementation argument has no contract bytecode.
    error NotAContract(address impl);

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    function initialize(
        address admin,
        address operator,
        address impl721,
        address impl1155
    ) external;

    // ──────────────────────────────────────────────
    // Creation
    // ──────────────────────────────────────────────

    function createCollection721(CreateParams721 calldata p, bytes32 externalId)
        external
        returns (address collection);

    function createCollection1155(CreateParams1155 calldata p, bytes32 externalId)
        external
        returns (address collection);

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function setImplementation721(address impl) external;

    function setImplementation1155(address impl) external;

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function collectionByExternalId(bytes32 externalId) external view returns (address);

    function erc721Implementation() external view returns (address);

    function erc1155Implementation() external view returns (address);
}

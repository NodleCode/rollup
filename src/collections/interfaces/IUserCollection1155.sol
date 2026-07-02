// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {CreateParams1155} from "./CollectionTypes.sol";

/**
 * @title IUserCollection1155
 * @notice Public API for the ERC-1155 implementation deployed behind a per-collection `ERC1967Proxy`.
 * @dev See `src/collections/doc/spec/user-collections-specification.md` (§3.6).
 */
interface IUserCollection1155 {
    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event MetadataLocked();
    event RoyaltiesLocked();
    event ContractURIUpdated(string newURI);
    event URIUpdated(string newURI);

    /// @notice Emitted whenever the default royalty is set, updated, or cleared
    ///         via `setDefaultRoyalty`. ERC-2981 itself emits no event, so this
    ///         is the only on-chain signal indexers can use to track royalty
    ///         changes for buyer due-diligence. A `bps == 0` emission means the
    ///         royalty was cleared.
    event DefaultRoyaltyUpdated(address recipient, uint96 bps);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error MetadataIsLocked();
    error RoyaltiesAreLocked();
    error BatchTooLarge(uint256 length, uint256 max);
    error LengthMismatch();
    error ZeroAddress();

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    function initialize(CreateParams1155 calldata p, address operatorMinter) external;

    // ──────────────────────────────────────────────
    // Minting
    // ──────────────────────────────────────────────

    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external;

    function mintBatch(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;

    // ──────────────────────────────────────────────
    // Owner-mutable settings
    // ──────────────────────────────────────────────

    function setURI(string calldata newURI) external;

    function setContractURI(string calldata newURI) external;

    function setDefaultRoyalty(address recipient, uint96 bps) external;

    function lockMetadata() external;

    function lockRoyalties() external;

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function contractURI() external view returns (string memory);

    function metadataLocked() external view returns (bool);

    function royaltiesLocked() external view returns (bool);
}

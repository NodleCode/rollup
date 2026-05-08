// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {CreateParams721} from "./CollectionTypes.sol";

/**
 * @title IUserCollection721
 * @notice Public API for the ERC-721 implementation deployed behind a per-collection `ERC1967Proxy`.
 * @dev See `src/collections/doc/spec/user-collections-specification.md` (§3.5).
 */
interface IUserCollection721 {
    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event MetadataLocked();
    event RoyaltiesLocked();
    event ContractURIUpdated(string newURI);
    event BaseURIUpdated(string newBase);

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

    function initialize(CreateParams721 calldata p, address operatorMinter) external;

    // ──────────────────────────────────────────────
    // Minting
    // ──────────────────────────────────────────────

    function mint(address to, string calldata tokenURI_) external returns (uint256 tokenId);

    function mintBatch(address[] calldata to, string[] calldata uris)
        external
        returns (uint256[] memory tokenIds);

    // ──────────────────────────────────────────────
    // Owner-mutable settings
    // ──────────────────────────────────────────────

    function setBaseURI(string calldata newBase) external;

    function setContractURI(string calldata newURI) external;

    function setDefaultRoyalty(address recipient, uint96 bps) external;

    function lockMetadata() external;

    function lockRoyalties() external;

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function contractURI() external view returns (string memory);

    function nextTokenId() external view returns (uint256);

    function metadataLocked() external view returns (bool);

    function royaltiesLocked() external view returns (bool);
}

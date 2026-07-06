// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

/**
 * @title CollectionTypes
 * @notice Shared enums and structs for the User Collections system.
 * @dev Solidity interfaces cannot define enums, so shared types live here.
 *      Import this file alongside the collection interfaces.
 */

/// @notice Token standard selected per-collection at creation time.
enum Standard {
    ERC721,
    ERC1155
}

/// @notice Parameters supplied by the operator when creating an ERC-721 collection.
/// @dev `additionalMinters` is orthogonal to the operator auto-grant: the calling
///      operator (`msg.sender` on the factory) is auto-granted `MINTER_ROLE` by the
///      collection's `initialize` regardless of this list. Use `additionalMinters`
///      for creator-seeded extras (e.g. a co-creator wallet).
struct CreateParams721 {
    address owner;
    string name;
    string symbol;
    string baseURI;
    string contractURI;
    address royaltyRecipient;
    uint96 royaltyBps;
    address[] additionalMinters;
}

/// @notice Parameters supplied by the operator when creating an ERC-1155 collection.
/// @dev ERC-1155 has no on-chain `name`/`symbol` convention; the collection display
///      name lives in `contractURI` JSON metadata.
struct CreateParams1155 {
    address owner;
    string uri;
    string contractURI;
    address royaltyRecipient;
    uint96 royaltyBps;
    address[] additionalMinters;
}

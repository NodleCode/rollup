// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

/**
 * @title IServiceProvider
 * @notice Interface for ServiceProvider — an ERC-721 representing ownership of a service endpoint URL.
 * @dev This interface defines the public contract surface that all ServiceProvider
 *      implementations must uphold across upgrades (UUPS pattern).
 *
 *      TokenID = keccak256(url), guaranteeing one owner per URL.
 */
interface IServiceProvider {
    // ══════════════════════════════════════════════
    // Events
    // ══════════════════════════════════════════════

    /// @notice Emitted when a new service provider URL is registered.
    /// @param owner The address that registered the provider.
    /// @param url The service endpoint URL.
    /// @param tokenId The minted NFT token ID (derived from URL hash).
    event ProviderRegistered(address indexed owner, string url, uint256 indexed tokenId);

    /// @notice Emitted when a provider NFT is burned.
    /// @param owner The former owner of the token.
    /// @param tokenId The burned token ID.
    event ProviderBurned(address indexed owner, uint256 indexed tokenId);

    // ══════════════════════════════════════════════
    // Core Functions
    // ══════════════════════════════════════════════

    /// @notice Mints a new provider NFT for the given URL.
    /// @param url The backend service URL (must be unique, non-empty).
    /// @return tokenId The deterministic token ID derived from `url`.
    function registerProvider(string calldata url) external returns (uint256 tokenId);

    /// @notice Burns the provider NFT. Caller must be the token owner.
    /// @param tokenId The provider token ID to burn.
    function burn(uint256 tokenId) external;

    // ══════════════════════════════════════════════
    // View Functions
    // ══════════════════════════════════════════════

    /// @notice Maps TokenID -> Provider URL.
    /// @param tokenId The token to query.
    /// @return The provider URL string.
    function providerUrls(uint256 tokenId) external view returns (string memory);

    /// @notice Returns the owner of the specified token ID (ERC-721).
    /// @param tokenId The token ID to query.
    /// @return The address of the token owner.
    function ownerOf(uint256 tokenId) external view returns (address);
}

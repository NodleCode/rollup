// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title ServiceProvider
 * @notice Permissionless ERC-721 representing ownership of a service endpoint URL.
 * @dev TokenID = keccak256(url), guaranteeing one owner per URL.
 */
contract ServiceProvider is ERC721 {
    error EmptyURL();
    error NotTokenOwner();

    // Maps TokenID -> Provider URL
    mapping(uint256 => string) public providerUrls;

    event ProviderRegistered(address indexed owner, string url, uint256 indexed tokenId);
    event ProviderBurned(address indexed owner, uint256 indexed tokenId);

    constructor() ERC721("Swarm Service Provider", "SSV") {}

    /// @notice Mints a new provider NFT for the given URL.
    /// @param url The backend service URL (must be unique).
    /// @return tokenId The deterministic token ID derived from `url`.
    function registerProvider(string calldata url) external returns (uint256 tokenId) {
        if (bytes(url).length == 0) {
            revert EmptyURL();
        }

        tokenId = uint256(keccak256(bytes(url)));

        providerUrls[tokenId] = url;

        _mint(msg.sender, tokenId);

        emit ProviderRegistered(msg.sender, url, tokenId);
    }

    /// @notice Burns the provider NFT. Caller must be the token owner.
    /// @param tokenId The provider token ID to burn.
    function burn(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner();
        }

        delete providerUrls[tokenId];

        _burn(tokenId);

        emit ProviderBurned(msg.sender, tokenId);
    }
}

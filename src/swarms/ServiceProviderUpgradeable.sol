// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title ServiceProviderUpgradeable
 * @notice UUPS-upgradeable ERC-721 representing ownership of a service endpoint URL.
 * @dev TokenID = keccak256(url), guaranteeing one owner per URL.
 *
 *      **Upgrade Pattern:**
 *      - Uses OpenZeppelin UUPS proxy pattern for upgradeability.
 *      - Only the contract owner can authorize upgrades.
 *      - Storage layout must be preserved across upgrades (append-only).
 *
 *      **Storage Migration:**
 *      - V1 storage is automatically preserved in the proxy.
 *      - Future versions can add new storage variables at the end.
 *      - Use `reinitializer(n)` for version-specific initialization.
 */
contract ServiceProviderUpgradeable is Initializable, ERC721Upgradeable, Ownable2StepUpgradeable, UUPSUpgradeable {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────
    error EmptyURL();
    error NotTokenOwner();

    // ──────────────────────────────────────────────
    // Storage (V1)
    // ──────────────────────────────────────────────

    /// @notice Maps TokenID -> Provider URL
    mapping(uint256 => string) public providerUrls;

    // ──────────────────────────────────────────────
    // Storage Gap (for future upgrades)
    // ──────────────────────────────────────────────

    /// @dev Reserved storage slots for future upgrades.
    ///      When adding new storage in V2+, reduce this gap accordingly.
    ///      Example: Adding 1 new storage variable → change to __gap[48]
    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event ProviderRegistered(address indexed owner, string url, uint256 indexed tokenId);
    event ProviderBurned(address indexed owner, uint256 indexed tokenId);

    // ──────────────────────────────────────────────
    // Constructor (disables initializers on implementation)
    // ──────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────
    // Initializer (replaces constructor)
    // ──────────────────────────────────────────────

    /// @notice Initializes the contract. Must be called once via proxy.
    /// @param owner_ The address that will own this contract and can authorize upgrades.
    function initialize(address owner_) external initializer {
        __ERC721_init("Swarm Service Provider", "SSV");
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

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

    // ──────────────────────────────────────────────
    // UUPS Authorization
    // ──────────────────────────────────────────────

    /// @dev Only the owner can authorize an upgrade.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

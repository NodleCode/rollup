// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {ERC721Upgradeable} from "openzeppelin-contracts-upgradeable-v4/contracts/token/ERC721/ERC721Upgradeable.sol";
import {ERC721URIStorageUpgradeable} from "openzeppelin-contracts-upgradeable-v4/contracts/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {ERC721BurnableUpgradeable} from "openzeppelin-contracts-upgradeable-v4/contracts/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import {AccessControlUpgradeable} from "openzeppelin-contracts-upgradeable-v4/contracts/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable-v4/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @notice An upgradeable ERC-721 contract that allows public batch minting
/// @dev Uses AccessControl for administrative functions and UUPS for upgradeability
/// @dev Unlike BaseContentSign which uses whitelist-based minting, this contract allows
///      anyone to mint tokens publicly. AccessControl is only used for upgrade authorization.
contract BatchMintNFT is
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    ERC721BurnableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /// @notice The next token ID to be minted
    uint256 public nextTokenId;

    /// @notice Maximum batch size to prevent DoS attacks
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice Whether minting is currently enabled
    bool public mintingEnabled;

    /// @notice Role identifier for minters (reserved for future use if minting restrictions are needed)
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Error thrown when arrays length mismatch in batch operations
    error UnequalLengths();
    /// @notice Error thrown when zero address is provided
    error ZeroAddress();
    /// @notice Error thrown when URI is empty
    error EmptyURI();
    /// @notice Error thrown when batch size exceeds maximum
    error BatchTooLarge();
    /// @notice Error thrown when minting is disabled
    error MintingDisabled();

    /// @notice Emitted when multiple tokens are minted in a batch
    /// @param recipients Array of addresses that received tokens
    /// @param tokenIds Array of token IDs that were minted
    event BatchMinted(address[] recipients, uint256[] tokenIds);

    /// @notice Emitted when minting is enabled or disabled
    /// @param enabled Whether minting is enabled
    event MintingEnabledChanged(bool indexed enabled);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param name The name of the NFT collection
    /// @param symbol The symbol of the NFT collection
    /// @param admin The address that will have DEFAULT_ADMIN_ROLE
    function initialize(string memory name, string memory symbol, address admin) public initializer {
        if (admin == address(0)) {
            revert ZeroAddress();
        }

        __ERC721_init(name, symbol);
        __ERC721URIStorage_init();
        __ERC721Burnable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        mintingEnabled = true;
    }

    /// @notice Mint a single NFT to an address
    /// @param to The address to mint the NFT to
    /// @param uri The URI for the token metadata
    function safeMint(address to, string memory uri) public {
        if (!mintingEnabled) {
            revert MintingDisabled();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (bytes(uri).length == 0) {
            revert EmptyURI();
        }

        uint256 tokenId = nextTokenId;
        unchecked {
            ++nextTokenId;
        }
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    /// @notice Batch mint NFTs to multiple addresses
    /// @param recipients Array of addresses to mint NFTs to
    /// @param uris Array of URIs for token metadata (must match recipients length)
    function batchSafeMint(address[] calldata recipients, string[] calldata uris) public {
        if (!mintingEnabled) {
            revert MintingDisabled();
        }
        if (recipients.length != uris.length) {
            revert UnequalLengths();
        }
        if (recipients.length > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }

        uint256 currentTokenId = nextTokenId;
        uint256 length = recipients.length;

        // Pre-allocate arrays for event emission
        uint256[] memory tokenIds = new uint256[](length);

        for (uint256 i = 0; i < length; ) {
            if (recipients[i] == address(0)) {
                revert ZeroAddress();
            }
            if (bytes(uris[i]).length == 0) {
                revert EmptyURI();
            }

            _safeMint(recipients[i], currentTokenId);
            _setTokenURI(currentTokenId, uris[i]);
            tokenIds[i] = currentTokenId;
            unchecked {
                ++currentTokenId;
                ++i;
            }
        }

        nextTokenId = currentTokenId;

        // Emit batch event
        emit BatchMinted(recipients, tokenIds);
    }

    /// @notice Get the URI for a specific token
    /// @param tokenId The token ID to query
    /// @return The URI string for the token metadata
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    /// @notice Check interface support
    /// @param interfaceId The interface identifier to check
    /// @return Whether the contract supports the interface
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return
            ERC721Upgradeable.supportsInterface(interfaceId) ||
            ERC721URIStorageUpgradeable.supportsInterface(interfaceId) ||
            AccessControlUpgradeable.supportsInterface(interfaceId);
    }

    /// @notice Enable or disable minting (only admin can change)
    /// @param enabled Whether to enable minting
    function setMintingEnabled(bool enabled) public onlyRole(DEFAULT_ADMIN_ROLE) {
        mintingEnabled = enabled;
        emit MintingEnabledChanged(enabled);
    }

    /// @notice Authorize upgrades (only admin can upgrade)
    /// @param newImplementation The address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Access control is handled by the onlyRole modifier
        // This function intentionally left empty as the authorization is done via modifier
        newImplementation; // Silence unused parameter warning
    }

    /// @notice Burn a token (only owner or approved operator can burn)
    /// @param tokenId The token ID to burn
    /// @dev The caller must own the token or be an approved operator
    function burn(uint256 tokenId) public override(ERC721BurnableUpgradeable) {
        super.burn(tokenId);
    }

    /// @notice Internal burn function (required override for ERC721URIStorage)
    /// @param tokenId The token ID to burn
    function _burn(uint256 tokenId) internal override(ERC721Upgradeable, ERC721URIStorageUpgradeable) {
        super._burn(tokenId);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     * Note: Reduced by 1 slot to account for mintingEnabled (bool)
     */
    uint256[49] private __gap;
}

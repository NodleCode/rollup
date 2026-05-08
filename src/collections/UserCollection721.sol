// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721URIStorageUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {ERC721BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IUserCollection721} from "./interfaces/IUserCollection721.sol";
import {CreateParams721} from "./interfaces/CollectionTypes.sol";

/**
 * @title UserCollection721
 * @notice ERC-721 implementation deployed behind a per-collection `ERC1967Proxy` by `CollectionFactory`.
 * @dev See `src/collections/doc/spec/user-collections-specification.md` (§3.5).
 *
 *      Bytecode-permanence invariants (load-bearing for the §1.3 immutability
 *      guarantee — see §7.2 row 15 and the §8.2 unit test):
 *      - This contract contains no `selfdestruct`.
 *      - This contract performs no `delegatecall` to caller-provided addresses.
 *      - Implementation must be deployed via `CREATE`, not `CREATE2`.
 */
contract UserCollection721 is
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    ERC721BurnableUpgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    IUserCollection721
{
    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @notice Maximum number of items per `mintBatch` call.
    uint256 public constant MAX_BATCH = 100;

    // ──────────────────────────────────────────────
    // Storage (V1) — order matters; see §6.2 of the spec.
    // The two booleans are declared adjacent so Solidity packs them into a
    // single slot (bytes 0 and 1, 30 bytes free for future appended sub-word
    // fields). Saves one __gap slot.
    // ──────────────────────────────────────────────

    string private _baseTokenURI;
    string private _contractURI;
    uint256 private _nextTokenId;
    bool private _metadataLocked;
    bool private _royaltiesLocked;

    /// @dev Reserved storage slots for future appended fields.
    uint256[46] private __gap;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    /// @dev Disables initializers on the implementation so it cannot be
    ///      initialized directly. Each per-collection proxy calls `initialize`
    ///      exactly once via the factory's atomic constructor-frame deploy+init
    ///      flow.
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    /// @inheritdoc IUserCollection721
    function initialize(CreateParams721 calldata p, address operatorMinter) external initializer {
        if (p.owner == address(0) || operatorMinter == address(0)) revert ZeroAddress();

        // Only the inits with non-empty bodies in OZ v5.6.1 are called. The
        // remaining `__<Mixin>_init` functions for ERC721URIStorage, Burnable,
        // ERC2981, and AccessControl are empty in this version (kept by OZ as
        // forward-compat shims). Re-add them if upgrading OZ.
        __ERC721_init(p.name, p.symbol);

        _baseTokenURI = p.baseURI;
        _contractURI = p.contractURI;

        if (p.royaltyBps > 0) {
            _setDefaultRoyalty(p.royaltyRecipient, p.royaltyBps);
        }

        _setRoleAdmin(MINTER_ROLE, OWNER_ROLE);

        _grantRole(OWNER_ROLE, p.owner);
        _grantRole(MINTER_ROLE, p.owner);
        _grantRole(MINTER_ROLE, operatorMinter);

        uint256 len = p.additionalMinters.length;
        for (uint256 i = 0; i < len; ++i) {
            _grantRole(MINTER_ROLE, p.additionalMinters[i]);
        }
    }

    // ──────────────────────────────────────────────
    // Minting
    // ──────────────────────────────────────────────

    /// @inheritdoc IUserCollection721
    function mint(address to, string calldata tokenURI_)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 tokenId)
    {
        tokenId = _nextTokenId;
        ++_nextTokenId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI_);
    }

    /// @inheritdoc IUserCollection721
    function mintBatch(address[] calldata to, string[] calldata uris)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256[] memory tokenIds)
    {
        uint256 len = to.length;
        if (len != uris.length) revert LengthMismatch();
        if (len > MAX_BATCH) revert BatchTooLarge(len, MAX_BATCH);

        tokenIds = new uint256[](len);
        uint256 startId = _nextTokenId;
        for (uint256 i = 0; i < len; ++i) {
            uint256 id = startId + i;
            tokenIds[i] = id;
            _safeMint(to[i], id);
            _setTokenURI(id, uris[i]);
        }
        _nextTokenId = startId + len;
    }

    // ──────────────────────────────────────────────
    // Owner-mutable settings
    // ──────────────────────────────────────────────

    /// @inheritdoc IUserCollection721
    function setBaseURI(string calldata newBase) external onlyRole(OWNER_ROLE) {
        if (_metadataLocked) revert MetadataIsLocked();
        _baseTokenURI = newBase;
        emit BaseURIUpdated(newBase);
    }

    /// @inheritdoc IUserCollection721
    function setContractURI(string calldata newURI) external onlyRole(OWNER_ROLE) {
        if (_metadataLocked) revert MetadataIsLocked();
        _contractURI = newURI;
        emit ContractURIUpdated(newURI);
    }

    /// @inheritdoc IUserCollection721
    function setDefaultRoyalty(address recipient, uint96 bps) external onlyRole(OWNER_ROLE) {
        if (_royaltiesLocked) revert RoyaltiesAreLocked();
        if (bps == 0) {
            _deleteDefaultRoyalty();
        } else {
            _setDefaultRoyalty(recipient, bps);
        }
    }

    /// @inheritdoc IUserCollection721
    function lockMetadata() external onlyRole(OWNER_ROLE) {
        _metadataLocked = true;
        emit MetadataLocked();
    }

    /// @inheritdoc IUserCollection721
    function lockRoyalties() external onlyRole(OWNER_ROLE) {
        _royaltiesLocked = true;
        emit RoyaltiesLocked();
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc IUserCollection721
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @inheritdoc IUserCollection721
    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    /// @inheritdoc IUserCollection721
    function metadataLocked() external view returns (bool) {
        return _metadataLocked;
    }

    /// @inheritdoc IUserCollection721
    function royaltiesLocked() external view returns (bool) {
        return _royaltiesLocked;
    }

    // ──────────────────────────────────────────────
    // Required overrides
    // ──────────────────────────────────────────────

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /// @dev `tokenURI` resolution lives in `ERC721URIStorageUpgradeable`; the
    ///      override here exists only to disambiguate the inheritance chain.
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable, ERC2981Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

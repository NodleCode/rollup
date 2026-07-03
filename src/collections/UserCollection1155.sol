// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC1155SupplyUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {ERC1155BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IUserCollection1155} from "./interfaces/IUserCollection1155.sol";
import {CreateParams1155} from "./interfaces/CollectionTypes.sol";

/**
 * @title UserCollection1155
 * @notice ERC-1155 implementation deployed behind a per-collection `ERC1967Proxy` by `CollectionFactory`.
 * @dev See `src/collections/doc/spec/user-collections-specification.md` (§3.6).
 *
 *      Bytecode-permanence invariants apply identically to UserCollection721
 *      (see §7.2 row 15 and the §8.3 unit test): no `selfdestruct`, no
 *      caller-controlled `delegatecall`, deployment via `CREATE` only.
 *
 *      Metadata convention (see spec §7.2 row 7): `uri` is mutable until
 *      `lockMetadata`; a shared `setURI` re-points the resolved URI for all IDs.
 *      Buyers get a freeze guarantee only from `metadataLocked`.
 *
 *      Role finality (see spec §2.4): collections are deliberately created with
 *      NO `DEFAULT_ADMIN_ROLE` holder. `OWNER_ROLE` is its own non-transferable
 *      anchor (it admins `MINTER_ROLE`, but nothing admins `OWNER_ROLE`). Owner
 *      key loss permanently freezes owner-only functions; token transfers and
 *      existing minters are unaffected.
 */
contract UserCollection1155 is
    Initializable,
    ERC1155Upgradeable,
    ERC1155SupplyUpgradeable,
    ERC1155BurnableUpgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    IUserCollection1155
{
    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @notice Maximum number of (id, amount) pairs per `mintBatch` call.
    uint256 public constant MAX_BATCH = 100;

    // ──────────────────────────────────────────────
    // Storage (V1) — order matters; see §6.2 of the spec.
    // The two booleans are declared adjacent so Solidity packs them into a
    // single slot (bytes 0 and 1, 30 bytes free for future appended sub-word
    // fields). 1155 omits `nextTokenId` (caller-chosen IDs).
    // ──────────────────────────────────────────────

    string private _contractURI;
    bool private _metadataLocked;
    bool private _royaltiesLocked;

    /// @dev Reserved storage slots for future appended fields.
    uint256[47] private __gap;

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    /// @inheritdoc IUserCollection1155
    function initialize(CreateParams1155 calldata p, address operatorMinter) external initializer {
        if (p.owner == address(0) || operatorMinter == address(0)) revert ZeroAddress();

        // Only the inits with non-empty bodies in OZ v5.6.1 are called. The
        // remaining `__<Mixin>_init` functions for ERC1155Supply, Burnable,
        // ERC2981, and AccessControl are empty in this version (kept by OZ as
        // forward-compat shims). Re-add them if upgrading OZ.
        __ERC1155_init(p.uri);

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

    /// @inheritdoc IUserCollection1155
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        onlyRole(MINTER_ROLE)
    {
        _mint(to, id, amount, data);
    }

    /// @inheritdoc IUserCollection1155
    function mintBatch(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external onlyRole(MINTER_ROLE) {
        uint256 len = ids.length;
        if (len != amounts.length) revert LengthMismatch();
        if (len > MAX_BATCH) revert BatchTooLarge(len, MAX_BATCH);
        _mintBatch(to, ids, amounts, data);
    }

    // ──────────────────────────────────────────────
    // Owner-mutable settings
    // ──────────────────────────────────────────────

    /// @inheritdoc IUserCollection1155
    function setURI(string calldata newURI) external onlyRole(OWNER_ROLE) {
        if (_metadataLocked) revert MetadataIsLocked();
        _setURI(newURI);
        emit URIUpdated(newURI);
    }

    /// @inheritdoc IUserCollection1155
    function setContractURI(string calldata newURI) external onlyRole(OWNER_ROLE) {
        if (_metadataLocked) revert MetadataIsLocked();
        _contractURI = newURI;
        emit ContractURIUpdated(newURI);
    }

    /// @inheritdoc IUserCollection1155
    function setDefaultRoyalty(address recipient, uint96 bps) external onlyRole(OWNER_ROLE) {
        if (_royaltiesLocked) revert RoyaltiesAreLocked();
        if (bps == 0) {
            _deleteDefaultRoyalty();
        } else {
            _setDefaultRoyalty(recipient, bps);
        }
        emit DefaultRoyaltyUpdated(recipient, bps);
    }

    /// @inheritdoc IUserCollection1155
    function lockMetadata() external onlyRole(OWNER_ROLE) {
        _metadataLocked = true;
        emit MetadataLocked();
    }

    /// @inheritdoc IUserCollection1155
    function lockRoyalties() external onlyRole(OWNER_ROLE) {
        _royaltiesLocked = true;
        emit RoyaltiesLocked();
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc IUserCollection1155
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @inheritdoc IUserCollection1155
    function metadataLocked() external view returns (bool) {
        return _metadataLocked;
    }

    /// @inheritdoc IUserCollection1155
    function royaltiesLocked() external view returns (bool) {
        return _royaltiesLocked;
    }

    // ──────────────────────────────────────────────
    // Required overrides
    // ──────────────────────────────────────────────

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155Upgradeable, ERC1155SupplyUpgradeable)
    {
        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, ERC2981Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

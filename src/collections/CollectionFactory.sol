// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ICollectionFactory} from "./interfaces/ICollectionFactory.sol";
import {IUserCollection721} from "./interfaces/IUserCollection721.sol";
import {IUserCollection1155} from "./interfaces/IUserCollection1155.sol";
import {Standard, CreateParams721, CreateParams1155} from "./interfaces/CollectionTypes.sol";

/**
 * @title CollectionFactory
 * @notice UUPS-upgradeable, operator-triggered factory that deploys per-collection
 *         `ERC1967Proxy` instances of `UserCollection721` / `UserCollection1155`.
 * @dev See `src/collections/doc/spec/user-collections-specification.md`.
 *
 *      The factory atomically deploys a per-collection `ERC1967Proxy`
 *      pointing at the standard's implementation, with an `abi.encodeCall`
 *      to `initialize(p, msg.sender)` baked into the constructor so init
 *      runs in the proxy's storage in the same frame. `msg.sender` is
 *      auto-granted `MINTER_ROLE` (see §2.3). Records the
 *      `externalId → collection` mapping and emits `CollectionCreated`.
 *      Reverts on reused or zero `externalId`.
 *
 *      Already-deployed collections are immutable (impls do not inherit
 *      `UUPSUpgradeable`; the EIP-1967 implementation slot is constructor-
 *      fixed). Admin can swap implementation pointers via `setImplementation*`,
 *      which only affects future collections.
 */
contract CollectionFactory is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ICollectionFactory
{
    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ──────────────────────────────────────────────
    // Storage (V1) — order matters; see §6.1 of the spec.
    // ──────────────────────────────────────────────

    address private _erc721Implementation;
    address private _erc1155Implementation;
    mapping(bytes32 => address) private _collectionByExternalId;

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

    /// @notice One-time proxy initializer (not part of the `ICollectionFactory`
    ///         consumer API — it is the `Initializable` deployment hook, invoked
    ///         once via the proxy constructor at deploy time).
    /// @param admin Receives `DEFAULT_ADMIN_ROLE` (factory upgrades, role admin).
    /// @param operator Receives `OPERATOR_ROLE` (may call `createCollection*`).
    /// @param impl721 `UserCollection721` implementation; must be a contract.
    /// @param impl1155 `UserCollection1155` implementation; must be a contract.
    function initialize(
        address admin,
        address operator,
        address impl721,
        address impl1155
    ) external initializer {
        if (admin == address(0) || operator == address(0) || impl721 == address(0) || impl1155 == address(0)) {
            revert ZeroAddress();
        }
        if (impl721.code.length == 0) revert NotAContract(impl721);
        if (impl1155.code.length == 0) revert NotAContract(impl1155);

        // `__AccessControl_init` body is empty in OZ v5.6.1; the role grants
        // below initialize all the state we need.

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);

        _erc721Implementation = impl721;
        _erc1155Implementation = impl1155;
    }

    // ──────────────────────────────────────────────
    // Creation
    // ──────────────────────────────────────────────

    /// @inheritdoc ICollectionFactory
    function createCollection721(CreateParams721 calldata p, bytes32 externalId)
        external
        onlyRole(OPERATOR_ROLE)
        returns (address collection)
    {
        _checkExternalId(externalId);

        bytes memory initData = abi.encodeCall(
            IUserCollection721.initialize,
            (p, msg.sender)
        );
        // SECURITY INVARIANT: the `_collectionByExternalId` write below lands
        // AFTER the proxy deploy+init. This is reentrancy-safe ONLY because the
        // implementation's `initialize` makes no calls to attacker-controlled
        // addresses (it only grants roles and sets ERC-2981 royalty, none of
        // which call out). Any future implementation MUST preserve that — if
        // `initialize` ever performs an external call, reorder so the registry
        // write precedes the deploy, or add a reentrancy guard here.
        collection = address(
            new ERC1967Proxy{salt: externalId}(_erc721Implementation, initData)
        );

        _collectionByExternalId[externalId] = collection;
        emit CollectionCreated(p.owner, collection, Standard.ERC721, externalId);
    }

    /// @inheritdoc ICollectionFactory
    function createCollection1155(CreateParams1155 calldata p, bytes32 externalId)
        external
        onlyRole(OPERATOR_ROLE)
        returns (address collection)
    {
        _checkExternalId(externalId);

        bytes memory initData = abi.encodeCall(
            IUserCollection1155.initialize,
            (p, msg.sender)
        );
        // SECURITY INVARIANT: see `createCollection721` — the registry write
        // trails the deploy+init and is safe only while `initialize` makes no
        // external calls. Preserve that property in any future implementation.
        collection = address(
            new ERC1967Proxy{salt: externalId}(_erc1155Implementation, initData)
        );

        _collectionByExternalId[externalId] = collection;
        emit CollectionCreated(p.owner, collection, Standard.ERC1155, externalId);
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    /// @inheritdoc ICollectionFactory
    function setImplementation721(address impl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateImplementation(impl);
        _erc721Implementation = impl;
        emit ImplementationUpdated(Standard.ERC721, impl);
    }

    /// @inheritdoc ICollectionFactory
    function setImplementation1155(address impl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateImplementation(impl);
        _erc1155Implementation = impl;
        emit ImplementationUpdated(Standard.ERC1155, impl);
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @inheritdoc ICollectionFactory
    function collectionByExternalId(bytes32 externalId) external view returns (address) {
        return _collectionByExternalId[externalId];
    }

    /// @inheritdoc ICollectionFactory
    function erc721Implementation() external view returns (address) {
        return _erc721Implementation;
    }

    /// @inheritdoc ICollectionFactory
    function erc1155Implementation() external view returns (address) {
        return _erc1155Implementation;
    }

    // ──────────────────────────────────────────────
    // Internals
    // ──────────────────────────────────────────────

    function _checkExternalId(bytes32 externalId) private view {
        if (externalId == bytes32(0)) revert InvalidExternalId();
        if (_collectionByExternalId[externalId] != address(0)) {
            revert ExternalIdAlreadyUsed(externalId);
        }
    }

    function _validateImplementation(address impl) private view {
        if (impl == address(0)) revert ZeroAddress();
        if (impl.code.length == 0) revert NotAContract(impl);
    }

    // ──────────────────────────────────────────────
    // UUPS authorization
    // ──────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

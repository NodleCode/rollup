// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {INameService} from "./INameService.sol";

/**
 * @title NameService based on ClaveNameService which is authored by https://getclave.io
 * @notice L2 name service contract that is built compatible to resolved as ENS subdomains by L2 resolver
 * @dev Names can only be registered by authorized accounts
 * @dev Addresses can only have one name at a time
 * @dev Subdomains are stored as ERC-721 assets, cannot be transferred
 * @dev If renewals are enabled, non-renewed names can be burnt after expiration timeline
 */
contract NameService is INameService, ERC721Burnable, AccessControl {
    using Strings for uint256;

    struct NameOwner {
        address owner;
        string name;
    }

    // Role to be authorized as default minter
    bytes32 public constant REGISTERER_ROLE = keccak256("REGISTERER_ROLE");
    // Default expiration duration
    uint256 public expiryDuration = 365 days;

    // token id to expires timestamp
    mapping(uint256 => uint256) public expires;
    // token id to text records
    mapping(uint256 => mapping(string => string)) public textRecords;
    // token id to text record keys
    mapping(uint256 => string[]) private _textRecordKeys;

    event NameRegistered(string indexed name, address indexed owner, uint256 expires);
    event TextRecordSet(uint256 indexed tokenId, string key, string value);
    event NameDeleted(uint256 indexed tokenId);

    /// @notice Thrown when attempting to resolve a name that has expired
    /// @param oldOwner The address of the previous owner of the name
    /// @param expiredAt The timestamp when the name expired
    error NameExpired(address oldOwner, uint256 expiredAt);

    /// @notice Thrown when attempting to register a name that is not alphanumeric
    error NameMustBeAlphanumeric();

    /// @notice Thrown when attempting to register a name that is empty
    error NameCannotBeEmpty();

    /// @notice Thrown when attempting to change attributes of a name that is not found in the registry
    error NameNotFound();

    /// @notice Thrown when attempting to register a name that already exists
    /// @param owner The address of the current owner of the name
    /// @param expiresAt The timestamp when the name expires
    error NameAlreadyExists(address owner, uint256 expiresAt);

    /// @notice Thrown when attempting to remove a name that has not yet expired
    /// @param expiresAt The timestamp when the name expires
    error NameNotExpired(uint256 expiresAt);

    /// @notice Thrown when an unauthorized address attempts to perform a permissioned action
    error NotAuthorized();

    /**
     * @notice Initialize the contract
     * @param admin The address of the admin
     * @param registrar The address of the registrar
     * @param tokenName The name of the token
     * @param tokenSymbol The symbol of the token
     */
    constructor(address admin, address registrar, string memory tokenName, string memory tokenSymbol)
        ERC721(tokenName, tokenSymbol)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTERER_ROLE, registrar);
    }

    /// @inheritdoc INameService
    function resolve(string memory name) external view returns (address) {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        address owner = ownerOf(tokenId);
        if (expires[tokenId] <= block.timestamp) {
            revert NameExpired(owner, expires[tokenId]);
        }
        return owner;
    }

    /**
     * @notice Register multiple names at once
     */
    function batchRegister(NameOwner[] memory nameOwners) external {
        if (!_isAuthorized()) {
            revert NotAuthorized();
        }

        for (uint256 i = 0; i < nameOwners.length; i++) {
            register(nameOwners[i].owner, nameOwners[i].name);
        }
    }

    /**
     * @notice Set default expiration duration
     * @dev Only admin can change the time
     */
    function setDefaultExpiry(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        expiryDuration = duration;
    }

    /// @inheritdoc INameService
    function register(address to, string memory name) public {
        registerWithExpiry(to, name, expiryDuration);
    }

    /// @inheritdoc INameService
    function registerWithExpiry(address to, string memory name, uint256 duration) public {
        if (!_isAuthorized()) {
            revert NotAuthorized();
        }

        uint256 tokenId = _register(to, name);
        uint256 expireTimestamp = block.timestamp + duration;
        expires[tokenId] = expireTimestamp;
        emit NameRegistered(name, to, expireTimestamp);
    }

    function _register(address to, string memory name) private returns (uint256) {
        if (bytes(name).length == 0) {
            revert NameCannotBeEmpty();
        }
        if (!_isAlphanumeric(name)) {
            revert NameMustBeAlphanumeric();
        }

        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) {
            _safeMint(to, tokenId);
        } else {
            if (expires[tokenId] > block.timestamp) {
                revert NameAlreadyExists(owner, expires[tokenId]);
            }
            _safeTransfer(owner, to, tokenId);
        }

        return tokenId;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return type(INameService).interfaceId == interfaceId || ERC721.supportsInterface(interfaceId)
            || AccessControl.supportsInterface(interfaceId);
    }

    /**
     * @inheritdoc ERC721Burnable
     * @dev Asset data is cleaned
     */
    function burn(uint256 tokenId) public override(ERC721Burnable) {
        delete expires[tokenId];

        string[] storage keys = _textRecordKeys[tokenId];
        for (uint256 i = 0; i < keys.length; i++) {
            delete textRecords[tokenId][keys[i]];
        }
        delete _textRecordKeys[tokenId];

        emit NameDeleted(tokenId);
        super.burn(tokenId);
    }

    /**
     * @notice Remove expired names
     * @dev Anyone can call this function to remove expired names
     */
    function removeExpired(string memory name) public {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        if (expires[tokenId] > block.timestamp) {
            revert NameNotExpired(expires[tokenId]);
        }
        delete expires[tokenId];
        _burn(tokenId);
    }

    /**
     * @notice Extend expiry of a name
     * @dev Only authorized accounts can extend expiry
     */
    function extendExpiry(uint256 tokenId, uint256 duration) public {
        if (!_isAuthorized()) {
            revert NotAuthorized();
        }
        if (_ownerOf(tokenId) == address(0)) {
            revert NameNotFound();
        }

        if (expires[tokenId] > block.timestamp) {
            expires[tokenId] += duration;
        } else {
            expires[tokenId] = block.timestamp + duration;
        }
    }

    // Check if string is alphanumeric
    function _isAlphanumeric(string memory str) private pure returns (bool) {
        bytes memory b = bytes(str);
        for (uint256 i; i < b.length; i++) {
            bytes1 char = b[i];
            if (!(char > 0x2F && char < 0x3A) && !(char > 0x60 && char < 0x7B)) return false;
        }
        return true;
    }

    // Check if caller is authorized for privileged operations
    function _isAuthorized() private view returns (bool) {
        return (hasRole(REGISTERER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender));
    }

    /// @notice Set a text record for a name
    /// @param name The name to set the text record for
    /// @param key The key of the text record
    /// @param value The value of the text record
    function setTextRecord(string memory name, string memory key, string memory value) external {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));

        bool isOwner = _ownerOf(tokenId) == msg.sender;
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        bool isRegistrar = hasRole(REGISTERER_ROLE, msg.sender);

        if (!isOwner && !isAdmin && !isRegistrar) {
            revert NotAuthorized();
        }
        if (expires[tokenId] <= block.timestamp) {
            revert NameExpired(_ownerOf(tokenId), expires[tokenId]);
        }
        textRecords[tokenId][key] = value;
        emit TextRecordSet(tokenId, key, value);
    }

    /// @notice Get a text record for a name
    /// @param name The name to get the text record for
    /// @param key The key of the text record
    /// @return The value of the text record
    function getTextRecord(string memory name, string memory key) external view returns (string memory) {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        if (expires[tokenId] <= block.timestamp) {
            revert NameExpired(_ownerOf(tokenId), expires[tokenId]);
        }
        return textRecords[tokenId][key];
    }
}

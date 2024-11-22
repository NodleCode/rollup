// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.23;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IClickNameService} from "./IClickNameService.sol";

/**
 * @title ClickNameService based on ClaveNameService which is authored by https://getclave.io
 * @notice L2 name service contract that is built compatible to resolved as ENS subdomains by L2 resolver
 * @dev Names can only be registered by authorized accounts
 * @dev Addresses can only have one name at a time
 * @dev Subdomains are stored as ERC-721 assets, cannot be transferred
 * @dev If renewals are enabled, non-renewed names can be burnt after expiration timeline
 */
contract ClickNameService is IClickNameService, ERC721Burnable, AccessControl {
    using Strings for uint256;

    struct NameOwner {
        address owner;
        string name;
    }

    // Role to be authorized as default minter
    bytes32 public constant REGISTERER_ROLE = keccak256("REGISTERER_ROLE");
    // Defualt expiration duration
    uint256 public expiryDuration = 365 days;

    // token id to expires timestamp
    mapping(uint256 => uint256) public expires;

    event NameRegistered(string indexed name, address indexed owner, uint256 expires);

    constructor(address admin, address registrar) ERC721("ClickNameService", "CLK") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTERER_ROLE, registrar);
    }

    /// @inheritdoc IClickNameService
    function resolve(string memory name) external view returns (address) {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        address owner = ownerOf(tokenId);
        require(expires[tokenId] > block.timestamp, "Name expired.");
        return owner;
    }

    /**
     * @notice Register multiple names at once
     */
    function batchRegister(NameOwner[] memory nameOwners) external isAuthorized {
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

    /// @inheritdoc IClickNameService
    function register(address to, string memory name) public isAuthorized {
        uint256 tokenId = _register(to, name);
        uint256 expireTimestamp = block.timestamp + expiryDuration;
        expires[tokenId] = expireTimestamp;
        emit NameRegistered(name, to, expireTimestamp);
    }

    /// @inheritdoc IClickNameService
    function registerWithExpiry(address to, string memory name, uint256 duration) public isAuthorized {
        uint256 tokenId = _register(to, name);
        uint256 expireTimestamp = block.timestamp + duration;
        expires[tokenId] = expireTimestamp;
        emit NameRegistered(name, to, expireTimestamp);
    }

    function _register(address to, string memory name) private returns (uint256) {
        require(bytes(name).length != 0, "Name cannot be empty.");
        require(_isAlphanumeric(name), "Name must be alphanumeric.");

        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) {
            _safeMint(to, tokenId);
        } else {
            require(expires[tokenId] < block.timestamp, "Name already exists and is not expired.");
            _safeTransfer(owner, to, tokenId);
        }

        return tokenId;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return type(IClickNameService).interfaceId == interfaceId || ERC721.supportsInterface(interfaceId)
            || AccessControl.supportsInterface(interfaceId);
    }

    /**
     * @inheritdoc ERC721Burnable
     * @dev Asset data is cleaned
     */
    function burn(uint256 tokenId) public override(ERC721Burnable) {
        delete expires[tokenId];
        super.burn(tokenId);
    }

    /**
     * @notice Remove expired names
     * @dev Anyone can call this function to remove expired names
     */
    function removeExpired(string memory name) public {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        require(expires[tokenId] < block.timestamp, "Name not expired.");
        delete expires[tokenId];
        _burn(tokenId);
    }

    /**
     * @notice Extend expiry of a name
     * @dev Only authorized accounts can extend expiry
     */
    function extendExpiry(uint256 tokenId, uint256 duration) public isAuthorized {
        require(_ownerOf(tokenId) != address(0), "Name not found.");
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

    // Modifier to check if caller is authorized for mints and registries
    modifier isAuthorized() {
        require(hasRole(REGISTERER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "[]  Not authorized.");
        _;
    }
}
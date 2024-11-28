// SPDX-License-Identifier: BSD-3-Clause-Clear

/**
 * @title ClickResolver for resolving ens subdomains based on names registered on L2
 * @dev This contract is based on ClaveResolver that can be found in this repository:
 * https://github.com/getclave/zksync-storage-proofs
 */
pragma solidity ^0.8.23;

import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    StorageProof,
    StorageProofVerifier
} from "zksync-storage-proofs/packages/zksync-storage-contracts/src/StorageProofVerifier.sol";

/// @title IOffchainResolver
/// @dev Expected interface for offchain resolvers which are contacted after an OffchainLookup revert
interface IOffchainResolver {
    function resolve(bytes calldata name, bytes calldata data)
        external
        view
        returns (StorageProof memory proof, bytes32 fallbackValue);
}

/// @title IExtendedResolver
/// @notice ENSIP-10: Wildcard Resolution
interface IExtendedResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

contract ClickResolver is IExtendedResolver, IERC165, Ownable {
    bytes4 private constant EXTENDED_INTERFACE_ID = 0x9061b923; // ENSIP-10

    bytes4 constant ADDR_SELECTOR = 0x3b3b57de; // addr(bytes32)
    bytes4 constant ADDR_MULTICHAIN_SELECTOR = 0xf1cb7e06; // addr(bytes32,uint)
    uint256 constant ZKSYNC_MAINNET_COIN_TYPE = 2147483972; // (0x80000000 | 0x144) >>> 0 as per ENSIP11

    error OffchainLookup(address sender, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData);
    error UnsupportedCoinType(uint256 coinType);
    error UnsupportedSelector(bytes4 selector);
    error UnsupportedChain(uint256 coinType);
    error InvalidStorageProof();
    error InvalidSignature();
    error InvalidDnsDomain();

    /// @notice Storage proof verifier contract
    StorageProofVerifier public storageProofVerifier;

    /// @notice URL of the resolver
    string public url;

    /// @notice Address of the registry contract on L2
    address public registry;

    /// @notice Storage slot for the mapping index, specific to Registry contract
    uint256 public mappingSlot;

    /// @notice Address of the domain owner
    address public domainOwner;

    /// @notice If true, proofs will be validated to make sure they are correct
    bool public validateProofs = true;

    constructor(string memory _url, address _domainOwner, address _registry, StorageProofVerifier _storageProofVerifier)
        Ownable(msg.sender)
    {
        url = _url;
        domainOwner = _domainOwner;
        registry = _registry;
        storageProofVerifier = _storageProofVerifier;

        // With the current storage layout of ClickNameResolver, the mapping slot of _owners storage is 2
        mappingSlot = 2;
    }

    function setValidate(bool _validate) external onlyOwner {
        validateProofs = _validate;
    }

    function setUrl(string memory _url) external onlyOwner {
        url = _url;
    }

    function setRegistry(address _registry, uint256 _mappingSlot) external onlyOwner {
        registry = _registry;
        mappingSlot = _mappingSlot;
    }

    /**
     * @notice Sets the mapping slot of the corresponding registry contract that could be enquired for a proof.
     * @dev This should be set based on the position of the `_owners` storage of ClickNameResolver coming from its ERC721 base.
     *      The storage-layout of that contract should be consulted to determine the correct slot.
     * @param _mappingSlot The slot to be set for the mapping.
     */
    function setMappingSlot(uint256 _mappingSlot) external onlyOwner {
        mappingSlot = _mappingSlot;
    }

    function setStorageProofVerifier(StorageProofVerifier _storageProofVerifier) external onlyOwner {
        storageProofVerifier = _storageProofVerifier;
    }

    /// @notice Extract namehash from calldata
    function extractNamehash(bytes calldata data) public pure returns (bytes32 namehash) {
        // Cast last 32 bytes of data to bytes32
        namehash = bytes32(data[data.length - 32:]);
    }

    /// @notice Parses DNS encoded domain name
    /// @param name DNS encoded domain name
    /// @return sub Subdomain
    /// @return dom Domain
    /// @return top Top level domain
    /// @dev e.g example.clave.eth is encoded as b"\x07example\x05clave\x03eth"
    ///      sub = "example"
    ///      dom = "clave"
    ///      top = "eth"
    /// @dev It's possible that the name is just a top level domain, in which case sub and dom will be empty
    /// @dev It's possible that the name is just a domain, in which case sub will be empty
    function parseDnsDomain(bytes calldata name)
        internal
        pure
        returns (string memory sub, string memory dom, string memory top)
    {
        uint256 length = name.length;

        uint8 firstLen = uint8(name[0]);
        string memory first = string(name[1:1 + firstLen]);

        // If there's only one segment, it's a top level domain
        // {top_length}.{top}.{0x00}
        if (length == firstLen + 2) return ("", "", first);

        uint8 secondLen = uint8(name[firstLen + 1]);
        string memory second = string(name[firstLen + 2:firstLen + 2 + secondLen]);

        // If there's only two segments, it's a domain
        // {dom_length}.{dom}.{top_length}.{top}.{0x00}
        if (length == firstLen + secondLen + 3) return ("", first, second);

        uint8 thirdLen = uint8(name[firstLen + secondLen + 2]);
        string memory third = string(name[firstLen + secondLen + 3:firstLen + secondLen + 3 + thirdLen]);

        return (first, second, third);
    }

    /// @notice Calculates storage slot of the key in the L2 registry
    /// @dev Names are stored in the L2 registry, in a mapping with slot `mappingSlot`
    function getDomainSlot(bytes32 _key) public view returns (bytes32) {
        return keccak256(abi.encode(_key, mappingSlot));
    }

    /// @notice Helper function to convert a string to lowercase
    function toLower(string memory str) private pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            // Uppercase character...
            if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
                // So we add 32 to make it lowercase
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        return string(bLower);
    }

    /// @notice Calculates storage slot of the key in the L2 registry
    /// @dev Names are stored in the L2 registry, in a mapping with slot `mappingSlot`
    function getDomainSlot(string memory _key) public view returns (bytes32) {
        string memory domain = toLower(_key);
        uint256 tokenId = uint256(keccak256(abi.encodePacked(domain)));
        return keccak256(abi.encode(tokenId, mappingSlot));
    }

    /// @notice Resolves a name to a value
    /// @param _name The name to resolve, DNS encoded
    /// @param _data The ABI encoded data for the underlying resolution function (Eg, addr(bytes32), text(bytes32,string), etc).
    function resolve(bytes calldata _name, bytes calldata _data) external view returns (bytes memory) {
        bytes memory callData = abi.encodeWithSelector(IOffchainResolver.resolve.selector, _name, _data);

        // Fill URLs
        string[] memory urls = new string[](1);
        urls[0] = url;

        (string memory sub, string memory dom, string memory top) = parseDnsDomain(_name);

        // If there's no domain or top level domain, throw
        if (bytes(dom).length == 0 || bytes(top).length == 0) {
            revert InvalidDnsDomain();
        }

        if (bytes(sub).length == 0) {
            // If there's no subdomain, return the domain owner
            return abi.encodePacked(domainOwner);
        }

        bytes32 registrySlot = getDomainSlot(sub);

        bytes4 functionSelector = bytes4(_data[:4]);
        if (functionSelector == ADDR_SELECTOR) {
            revert OffchainLookup(
                address(this),
                urls,
                callData,
                ClickResolver.resolveWithProof.selector,
                abi.encode(registry, registrySlot)
            );
        } else if (functionSelector == ADDR_MULTICHAIN_SELECTOR) {
            (, uint256 coinType) = abi.decode(_data[4:], (bytes32, uint256));
            if (coinType != ZKSYNC_MAINNET_COIN_TYPE) {
                // TODO: Handle other chains when this is supported
                revert UnsupportedCoinType(coinType);
            }
            revert OffchainLookup(
                address(this),
                urls,
                callData,
                ClickResolver.resolveWithProof.selector,
                abi.encode(registry, registrySlot)
            );
        } else {
            revert UnsupportedSelector(functionSelector);
        }
    }

    /// @notice Callback used by CCIP read compatible clients to verify and parse the response.
    /// @param _response ABI encoded StorageProof struct
    /// @return ABI encoded value of the storage key
    function resolveWithProof(bytes memory _response, bytes memory _extraData) external view returns (bytes memory) {
        (StorageProof memory proof, bytes32 fallbackValue) = abi.decode(_response, (StorageProof, bytes32));
        (address account, uint256 key) = abi.decode(_extraData, (address, uint256));

        if (validateProofs) {
            // Override account and key of the proof to make sure it is correct address and key
            proof.account = account;
            proof.key = key;
        }

        bool verified = storageProofVerifier.verify(proof);

        // If there's an address for the name, this should be an address
        // But example implementation is returning bytes and we're doing the same
        if (verified && proof.value != bytes32(0)) {
            return abi.encodePacked(proof.value);
        } else {
            // After username is set on L2, there'll be a time period where
            // the username is not yet set on L1. During this time, the username
            // will be set to 0x00. In this case, return the fallback value.
            return abi.encodePacked(fallbackValue);
        }
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165) returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == EXTENDED_INTERFACE_ID;
    }
}

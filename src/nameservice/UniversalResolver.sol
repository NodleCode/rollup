// SPDX-License-Identifier: BSD-3-Clause-Clear

/**
 * @title UniversalResolver for resolving ens subdomains based on names registered on L2
 * @dev This contract is based on ClaveResolver that can be found in this repository:
 * https://github.com/getclave/zksync-storage-proofs
 */
pragma solidity ^0.8.23;

import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    StorageProof,
    StorageProofVerifier
} from "zksync-storage-proofs/packages/zksync-storage-contracts/src/StorageProofVerifier.sol";

/// @title IExtendedResolver
/// @notice ENSIP-10: Wildcard Resolution
interface IExtendedResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

contract UniversalResolver is IExtendedResolver, IERC165, Ownable {
    bytes4 private constant _EXTENDED_INTERFACE_ID = 0x9061b923; // ENSIP-10

    bytes4 private constant _ADDR_SELECTOR = 0x3b3b57de; // addr(bytes32)
    bytes4 private constant _ADDR_MULTICHAIN_SELECTOR = 0xf1cb7e06; // addr(bytes32,uint)
    bytes4 private constant _TEXT_SELECTOR = 0x59d1d43c; // text(bytes32,string)
    uint256 private constant _ZKSYNC_MAINNET_COIN_TYPE = 2147483972; // (0x80000000 | 0x144) >>> 0 as per ENSIP11

    error OffchainLookup(address sender, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData);
    error UnsupportedCoinType(uint256 coinType);
    error UnsupportedSelector(bytes4 selector);
    error UnsupportedChain(uint256 coinType);
    error InvalidStorageProof();

    /// @notice Storage proof verifier contract
    StorageProofVerifier public storageProofVerifier;

    /// @notice URL of the resolver
    string public url;

    /// @notice Address of the register contract on L2
    address public immutable registry;

    /// @notice Storage slot for the mapping index, specific to registry contract
    uint256 public immutable addrsSlot;
    uint256 public immutable textRecordsSlot;

    /// @notice Address of the domain owner
    address public domainOwner;

    constructor(string memory _url, address _domainOwner, address _registry, StorageProofVerifier _storageProofVerifier)
        Ownable(_domainOwner)
    {
        url = _url;
        domainOwner = _domainOwner;
        registry = _registry;
        storageProofVerifier = _storageProofVerifier;

        // With the current storage layout of ClickNameResolver, the mapping slot of _owners storage is 2 and the mapping slot of _textRecords storage is 9
        addrsSlot = 2;
        textRecordsSlot = 9;
    }

    function setUrl(string memory _url) external onlyOwner {
        url = _url;
    }

    /// @notice Parses DNS encoded domain name
    /// @param name DNS encoded domain name
    /// @return _sub Subdomain
    /// @return _dom Domain
    /// @return _top Top level domain
    /// @dev e.g example.clave.eth is encoded as b"\x07example\x05clave\x03eth"
    ///      sub = "example"
    ///      dom = "clave"
    ///      top = "eth"
    /// @dev It's possible that the name is just a top level domain, in which case sub and dom will be empty
    /// @dev It's possible that the name is just a domain, in which case sub will be empty
    function _parseDnsDomain(bytes calldata name)
        internal
        pure
        returns (string memory _sub, string memory _dom, string memory _top)
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

    /// @notice Calculates the key for the given subdomain name in the L2 registry
    /// @dev Names are stored in the registry, in a mapping with slot `addrsSlot`
    function getStorageKey(string memory subDomain) public view returns (bytes32) {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(subDomain)));
        return keccak256(abi.encode(tokenId, addrsSlot));
    }

    /// @notice Calculates the storage key for a specific text record
    /// @param subDomain The subdomain to get the record for
    /// @param key The text record key (e.g. "avatar")
    /// @return The final storage key for the text value: mapping (string => string)
    function getTextRecordStorageKey(string memory subDomain, string memory key) public view returns (bytes32) {
        uint256 tokenId = uint256(keccak256(abi.encodePacked(subDomain)));
        bytes32 firstLevel = keccak256(abi.encode(tokenId, textRecordsSlot));
        return keccak256(abi.encodePacked(key, firstLevel));
    }

    /// @notice Resolves a name based on its subdomain part regardless of the given domain and top level
    /// @param _name The name to resolve which must be a pack of length prefixed names for subdomain, domain and top.
    /// example: b"\x07example\x05clave\x03eth"
    ///
    /// @param _data The ABI encoded data for the underlying resolution function (Eg, addr(bytes32), text(bytes32,string), etc).
    function resolve(bytes calldata _name, bytes calldata _data) external view returns (bytes memory) {
        (string memory sub,string memory dom,) = _parseDnsDomain(_name);

        if (bytes(sub).length == 0) {
            return abi.encodePacked(domainOwner);
        }

        bytes4 functionSelector = bytes4(_data[:4]);
        bytes32 storageKey;

        if (functionSelector == _TEXT_SELECTOR) {
            (, string memory key) = abi.decode(_data[4:], (bytes32, string));
            storageKey = getTextRecordStorageKey(sub, key);
        } else if (functionSelector == _ADDR_SELECTOR || functionSelector == _ADDR_MULTICHAIN_SELECTOR) {
            storageKey = getStorageKey(sub);
            if (functionSelector == _ADDR_MULTICHAIN_SELECTOR) {
                (, uint256 coinType) = abi.decode(_data[4:], (bytes32, uint256));
                if (coinType != _ZKSYNC_MAINNET_COIN_TYPE) {
                    revert UnsupportedCoinType(coinType);
                }
            }
        } else {
            revert UnsupportedSelector(functionSelector);
        }

        bytes memory callData = abi.encode(storageKey, dom);
        bytes memory extraData = abi.encode(storageKey, functionSelector);

        string[] memory urls = new string[](1);
        urls[0] = url;

        revert OffchainLookup(address(this), urls, callData, UniversalResolver.resolveWithProof.selector, extraData);
    }

    /// @notice Callback used by CCIP read compatible clients to verify and parse the response.
    /// @param _response ABI encoded StorageProof struct
    /// @return ABI encoded value of the storage key
    function resolveWithProof(bytes memory _response, bytes memory _extraData) external view returns (bytes memory) {
        (StorageProof memory proof, string memory stringValue) = abi.decode(_response, (StorageProof, string));
        (uint256 storageKey, bytes4 functionSelector) = abi.decode(_extraData, (uint256, bytes4));

        // Replace the account in the proof with the known address of the registry
        proof.account = registry;
        // Replace the key in the proof with the caller's specified key. It's because the caller may obtain the response/proof from an untrusted offchain source.
        proof.key = storageKey;

        bool verified = storageProofVerifier.verify(proof);

        if (!verified) {
            revert InvalidStorageProof();
        }

        if (functionSelector == _TEXT_SELECTOR) {
            return abi.encode(stringValue);
        } else if (functionSelector == _ADDR_SELECTOR || functionSelector == _ADDR_MULTICHAIN_SELECTOR) {
            return abi.encodePacked(proof.value);
        } else {
            revert UnsupportedSelector(functionSelector);
        }
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165) returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == _EXTENDED_INTERFACE_ID
            || interfaceId == type(IExtendedResolver).interfaceId;
    }
}

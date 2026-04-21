// SPDX-License-Identifier: BSD-3-Clause-Clear

/**
 * @title SignedUniversalResolver
 * @notice ENS-compatible L1 resolver for names registered on L2 (zkSync Era).
 * @dev Uses the CCIP-Read (ERC-3668) pattern with a trusted-gateway signature
 *      model. The off-chain gateway queries the L2 NameService directly and
 *      returns an EIP-712 signed response. This contract recovers the signer
 *      and accepts the response only if it matches a registered trusted signer.
 *
 *      This replaces the earlier zkSync storage-proof design which depended on
 *      per-batch state roots being committed to L1 — that path was broken when
 *      zkSync Era migrated settlement to ZK Gateway (~July 30, 2025).
 */
pragma solidity ^0.8.26;

import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title IExtendedResolver
/// @notice ENSIP-10: Wildcard Resolution
interface IExtendedResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

contract SignedUniversalResolver is IExtendedResolver, IERC165, Ownable2Step, EIP712 {
    bytes4 private constant _EXTENDED_INTERFACE_ID = 0x9061b923; // ENSIP-10

    bytes4 private constant _ADDR_SELECTOR = 0x3b3b57de; // addr(bytes32)
    bytes4 private constant _ADDR_MULTICHAIN_SELECTOR = 0xf1cb7e06; // addr(bytes32,uint)
    bytes4 private constant _TEXT_SELECTOR = 0x59d1d43c; // text(bytes32,string)
    uint256 private constant _ZKSYNC_MAINNET_COIN_TYPE = 2147483972; // (0x80000000 | 0x144) per ENSIP-11

    /// @notice EIP-712 typehash for the payload signed by the trusted gateway.
    /// @dev Keccak of "Resolution(bytes name,bytes data,bytes result,uint64 expiresAt)"
    bytes32 private constant _RESOLUTION_TYPEHASH =
        keccak256("Resolution(bytes name,bytes data,bytes result,uint64 expiresAt)");

    /// @notice Hard cap on how far into the future a gateway signature may claim to be valid.
    /// @dev Bounds the replay window if a signer key is compromised: even a maliciously
    ///      long `expiresAt` is clamped to this value on-chain. 5 minutes is comfortably
    ///      above L1 clock skew while keeping blast radius small.
    uint64 private constant _MAX_SIGNATURE_TTL = 5 minutes;

    error OffchainLookup(address sender, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData);
    error UnsupportedCoinType(uint256 coinType);
    error UnsupportedSelector(bytes4 selector);
    error CallDataTooShort(uint256 length);
    error OwnershipCannotBeRenounced();
    error ZeroSignerAddress();
    error EmptyUrl();
    error CannotDisableLastTrustedSigner();
    error SignatureExpired(uint64 expiresAt);
    error SignatureTtlTooLong(uint64 expiresAt);
    error InvalidSigner(address recovered);

    /// @notice URL of the CCIP-Read gateway.
    string public url;

    /// @notice Address of the L2 NameService contract. Read by the off-chain gateway
    ///         to choose which L2 contract to query. Not consulted on-chain — the trust
    ///         anchor for resolution is the EIP-712 signer, not this field.
    address public immutable registry;

    /// @notice Trusted signers whose EIP-712 signatures this resolver will accept.
    ///         Mapping (rather than a single address) to allow zero-downtime key rotation.
    mapping(address => bool) public isTrustedSigner;

    /// @notice Number of addresses currently marked as trusted signers.
    /// @dev Kept in sync with `isTrustedSigner` and used to prevent dropping to zero.
    ///      If this ever hits zero, all resolution breaks and can only be restored
    ///      by the owner. The contract enforces a floor of 1 in `setTrustedSigner`.
    uint256 public trustedSignerCount;

    event UrlUpdated(string oldUrl, string newUrl);
    event TrustedSignerUpdated(address indexed signer, bool trusted);

    constructor(string memory _url, address _owner, address _registry, address _initialSigner)
        Ownable(_owner)
        EIP712("NodleUniversalResolver", "1")
    {
        if (_initialSigner == address(0)) revert ZeroSignerAddress();
        if (bytes(_url).length == 0) revert EmptyUrl();

        url = _url;
        registry = _registry;

        isTrustedSigner[_initialSigner] = true;
        trustedSignerCount = 1;
        emit TrustedSignerUpdated(_initialSigner, true);
    }

    /// @notice Update the CCIP-Read gateway URL.
    function setUrl(string memory _url) external onlyOwner {
        emit UrlUpdated(url, _url);
        url = _url;
    }

    /// @notice Enable or disable a trusted gateway signer.
    /// @dev Keeps `trustedSignerCount` in sync and enforces a floor of 1 so the
    ///      owner cannot brick resolution by disabling the last signer.
    function setTrustedSigner(address signer, bool trusted) external onlyOwner {
        if (signer == address(0)) revert ZeroSignerAddress();

        bool current = isTrustedSigner[signer];
        if (current == trusted) {
            // Idempotent: nothing to do, no event, no count change.
            return;
        }

        if (trusted) {
            isTrustedSigner[signer] = true;
            trustedSignerCount++;
        } else {
            if (trustedSignerCount == 1) revert CannotDisableLastTrustedSigner();
            isTrustedSigner[signer] = false;
            trustedSignerCount--;
        }

        emit TrustedSignerUpdated(signer, trusted);
    }

    /// @notice Ownership cannot be renounced: losing the owner bricks setUrl and
    ///         setTrustedSigner, which would permanently break gateway rotation and
    ///         signer revocation. Transfer to a new owner instead.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
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

    /// @notice ENSIP-10 entry point. Triggers CCIP-Read lookup via OffchainLookup revert.
    /// @param _name DNS-encoded name (e.g. b"\x07example\x05clave\x03eth")
    /// @param _data ABI-encoded ENS resolution call (addr / addr-multichain / text)
    function resolve(bytes calldata _name, bytes calldata _data) external view returns (bytes memory) {
        (string memory sub,,) = _parseDnsDomain(_name);

        // Explicit length check so short calldata reverts with a controlled error
        // instead of a panic on the slice below.
        if (_data.length < 4) {
            revert CallDataTooShort(_data.length);
        }

        // Dispatch only on supported selectors so the gateway is never asked for nonsense.
        bytes4 functionSelector = bytes4(_data[:4]);
        if (
            functionSelector != _TEXT_SELECTOR && functionSelector != _ADDR_SELECTOR
                && functionSelector != _ADDR_MULTICHAIN_SELECTOR
        ) {
            revert UnsupportedSelector(functionSelector);
        }
        if (functionSelector == _ADDR_MULTICHAIN_SELECTOR) {
            (, uint256 coinType) = abi.decode(_data[4:], (bytes32, uint256));
            if (coinType != _ZKSYNC_MAINNET_COIN_TYPE) {
                revert UnsupportedCoinType(coinType);
            }
        }

        // Bare-domain queries (nodl.eth itself, no subdomain) are answered on L1 with
        // the ENS "no record" convention: zero address for addr queries, empty string
        // for text queries. The resolver only exists to answer subdomain lookups — it
        // holds no state about the parent name. If a specific address needs to be
        // associated with the bare domain, set it via a different resolver at the
        // ENS registry level.
        if (bytes(sub).length == 0) {
            if (functionSelector == _TEXT_SELECTOR) {
                return abi.encode("");
            }
            if (functionSelector == _ADDR_MULTICHAIN_SELECTOR) {
                // ENSIP-11: addr(bytes32,uint256) returns `bytes`. "No record"
                // is an empty bytes value, not a zero address.
                return abi.encode(bytes(""));
            }
            return abi.encode(address(0));
        }

        // Pass the raw (name, data) to the gateway. It will query the L2 NameService,
        // build the ABI-encoded result, and return it along with an EIP-712 signature.
        bytes memory callData = abi.encode(_name, _data);
        bytes memory extraData = abi.encode(_name, _data);

        string[] memory urls = new string[](1);
        urls[0] = url;

        revert OffchainLookup(address(this), urls, callData, SignedUniversalResolver.resolveWithSig.selector, extraData);
    }

    /// @notice CCIP-Read callback. Verifies the gateway's EIP-712 signature and returns the result.
    /// @param _response ABI-encoded (bytes result, uint64 expiresAt, bytes signature)
    /// @param _extraData ABI-encoded (bytes name, bytes data) — echoed from the original resolve() call
    /// @return The ABI-encoded resolution result, ready to be returned to the ENS caller.
    function resolveWithSig(bytes calldata _response, bytes calldata _extraData)
        external
        view
        returns (bytes memory)
    {
        (bytes memory result, uint64 expiresAt, bytes memory signature) =
            abi.decode(_response, (bytes, uint64, bytes));
        (bytes memory name, bytes memory data) = abi.decode(_extraData, (bytes, bytes));

        if (block.timestamp > expiresAt) {
            revert SignatureExpired(expiresAt);
        }
        if (expiresAt > block.timestamp + _MAX_SIGNATURE_TTL) {
            revert SignatureTtlTooLong(expiresAt);
        }

        bytes32 structHash = keccak256(
            abi.encode(_RESOLUTION_TYPEHASH, keccak256(name), keccak256(data), keccak256(result), expiresAt)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);

        if (!isTrustedSigner[recovered]) {
            revert InvalidSigner(recovered);
        }

        return result;
    }

    /// @notice Expose the EIP-712 domain separator so off-chain signers can verify their setup.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165) returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == _EXTENDED_INTERFACE_ID
            || interfaceId == type(IExtendedResolver).interfaceId;
    }
}

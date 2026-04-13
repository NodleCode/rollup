// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniversalResolver, IExtendedResolver} from "../../src/nameservice/UniversalResolver.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract UniversalResolverTest is Test {
    UniversalResolver public resolver;

    address public owner;
    address public registry;
    address public signer;
    uint256 public signerPk;
    address public backupSigner;
    uint256 public backupSignerPk;

    string public constant GATEWAY_URL = "https://gateway.nodle.com/resolve";

    // ENS selectors
    bytes4 private constant ADDR_SELECTOR = 0x3b3b57de;
    bytes4 private constant ADDR_MULTICHAIN_SELECTOR = 0xf1cb7e06;
    bytes4 private constant TEXT_SELECTOR = 0x59d1d43c;
    uint256 private constant ZKSYNC_MAINNET_COIN_TYPE = 2147483972;

    bytes32 private constant RESOLUTION_TYPEHASH =
        keccak256("Resolution(bytes name,bytes data,bytes result,uint64 expiresAt)");

    // b"\x07example\x05clave\x03eth\x00" DNS encoding of example.clave.eth
    bytes private constant DNS_FULL = hex"076578616d706c6505636c6176650365746800";
    // b"\x05clave\x03eth\x00" bare domain
    bytes private constant DNS_BARE = hex"05636c6176650365746800";

    event TrustedSignerUpdated(address indexed signer, bool trusted);

    function setUp() public {
        owner = makeAddr("owner");
        registry = makeAddr("registry");
        (signer, signerPk) = makeAddrAndKey("signer");
        (backupSigner, backupSignerPk) = makeAddrAndKey("backup");

        resolver = new UniversalResolver(GATEWAY_URL, owner, registry, signer);
    }

    // --- helpers ---

    function _signResolution(
        uint256 pk,
        bytes memory name,
        bytes memory data,
        bytes memory result,
        uint64 expiresAt
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                RESOLUTION_TYPEHASH,
                keccak256(name),
                keccak256(data),
                keccak256(result),
                expiresAt
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(resolver.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _addrCallData(string memory ensName) internal pure returns (bytes memory) {
        bytes32 node = keccak256(bytes(ensName)); // value doesn't matter for tests
        return abi.encodeWithSelector(ADDR_SELECTOR, node);
    }

    function _textCallData(string memory ensName, string memory key) internal pure returns (bytes memory) {
        bytes32 node = keccak256(bytes(ensName));
        return abi.encodeWithSelector(TEXT_SELECTOR, node, key);
    }

    function _addrMultichainCallData(string memory ensName, uint256 coinType) internal pure returns (bytes memory) {
        bytes32 node = keccak256(bytes(ensName));
        return abi.encodeWithSelector(ADDR_MULTICHAIN_SELECTOR, node, coinType);
    }

    // --- resolve() — triggers OffchainLookup ---

    function test_Resolve_BareDomain_Addr_ReturnsZeroAddress() public view {
        bytes memory out = resolver.resolve(DNS_BARE, _addrCallData("clave.eth"));
        // abi.encode(address) is 32 bytes (left-padded) so ENS clients can decode it.
        assertEq(out.length, 32);
        assertEq(abi.decode(out, (address)), address(0));
    }

    function test_Resolve_BareDomain_Text_ReturnsEmptyString() public view {
        bytes memory out = resolver.resolve(DNS_BARE, _textCallData("clave.eth", "com.twitter"));
        assertEq(abi.decode(out, (string)), "");
    }

    function test_Resolve_BareDomain_AddrMultichain_ReturnsEmptyBytes() public view {
        // ENSIP-11: addr(bytes32,uint256) returns `bytes`. "No record" is empty bytes.
        bytes memory out = resolver.resolve(DNS_BARE, _addrMultichainCallData("clave.eth", ZKSYNC_MAINNET_COIN_TYPE));
        bytes memory decoded = abi.decode(out, (bytes));
        assertEq(decoded.length, 0);
    }

    function test_Resolve_RevertsOffchainLookup_Addr() public {
        bytes memory data = _addrCallData("example.clave.eth");
        vm.expectRevert(); // OffchainLookup is a custom error; just assert it reverts
        resolver.resolve(DNS_FULL, data);
    }

    function test_Resolve_ShortCallData_Reverts() public {
        bytes memory shortData = hex"deadbe"; // only 3 bytes
        vm.expectRevert(abi.encodeWithSelector(UniversalResolver.CallDataTooShort.selector, uint256(3)));
        resolver.resolve(DNS_FULL, shortData);
    }

    function test_Resolve_UnsupportedSelector_Reverts() public {
        bytes memory bogus = abi.encodeWithSelector(bytes4(0xdeadbeef), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(UniversalResolver.UnsupportedSelector.selector, bytes4(0xdeadbeef)));
        resolver.resolve(DNS_FULL, bogus);
    }

    function test_Resolve_AddrMultichain_WrongCoinType_Reverts() public {
        bytes memory data = _addrMultichainCallData("example.clave.eth", 60); // ETH mainnet coin type
        vm.expectRevert(abi.encodeWithSelector(UniversalResolver.UnsupportedCoinType.selector, uint256(60)));
        resolver.resolve(DNS_FULL, data);
    }

    function test_Resolve_AddrMultichain_ZkSyncCoinType_Reverts_OffchainLookup() public {
        bytes memory data = _addrMultichainCallData("example.clave.eth", ZKSYNC_MAINNET_COIN_TYPE);
        vm.expectRevert(); // accepted → OffchainLookup
        resolver.resolve(DNS_FULL, data);
    }

    // --- resolveWithSig() — happy paths ---

    function test_ResolveWithSig_Addr_HappyPath() public {
        address expectedOwner = makeAddr("owner");
        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(expectedOwner);
        uint64 expiresAt = uint64(block.timestamp + 60);

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        bytes memory out = resolver.resolveWithSig(response, extraData);
        assertEq(keccak256(out), keccak256(result));
        assertEq(abi.decode(out, (address)), expectedOwner);
    }

    function test_ResolveWithSig_AddrMultichain_HappyPath() public {
        // ENSIP-11 return type is `bytes`: raw 20-byte address for EVM chains.
        bytes memory expectedAddr = abi.encodePacked(makeAddr("owner"));
        bytes memory data = _addrMultichainCallData("example.clave.eth", ZKSYNC_MAINNET_COIN_TYPE);
        bytes memory result = abi.encode(expectedAddr);
        uint64 expiresAt = uint64(block.timestamp + 60);

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        bytes memory out = resolver.resolveWithSig(response, extraData);
        bytes memory decoded = abi.decode(out, (bytes));
        assertEq(keccak256(decoded), keccak256(expectedAddr));
        assertEq(decoded.length, 20);
    }

    function test_ResolveWithSig_Text_HappyPath() public {
        string memory textValue = "@nodle_network";
        bytes memory data = _textCallData("example.clave.eth", "com.twitter");
        bytes memory result = abi.encode(textValue);
        uint64 expiresAt = uint64(block.timestamp + 60);

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        bytes memory out = resolver.resolveWithSig(response, extraData);
        assertEq(abi.decode(out, (string)), textValue);
    }

    // --- resolveWithSig() — failure modes ---

    function test_ResolveWithSig_ExpiredSignature_Reverts() public {
        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        uint64 expiresAt = uint64(block.timestamp + 60);

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        vm.warp(uint256(expiresAt) + 1);
        vm.expectRevert(abi.encodeWithSelector(UniversalResolver.SignatureExpired.selector, expiresAt));
        resolver.resolveWithSig(response, extraData);
    }

    function test_ResolveWithSig_TtlTooLong_Reverts() public {
        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        // 10 minutes > 5 minute max cap
        uint64 expiresAt = uint64(block.timestamp + 10 minutes);

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        vm.expectRevert(abi.encodeWithSelector(UniversalResolver.SignatureTtlTooLong.selector, expiresAt));
        resolver.resolveWithSig(response, extraData);
    }

    function test_ResolveWithSig_UntrustedSigner_Reverts() public {
        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        uint64 expiresAt = uint64(block.timestamp + 60);

        // Sign with backup key which is NOT yet trusted.
        bytes memory sig = _signResolution(backupSignerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        vm.expectRevert(abi.encodeWithSelector(UniversalResolver.InvalidSigner.selector, backupSigner));
        resolver.resolveWithSig(response, extraData);
    }

    function test_ResolveWithSig_TamperedResult_Reverts() public {
        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory signedResult = abi.encode(makeAddr("owner"));
        bytes memory tamperedResult = abi.encode(makeAddr("attacker"));
        uint64 expiresAt = uint64(block.timestamp + 60);

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, signedResult, expiresAt);
        // swap in a different result while keeping the signature
        bytes memory response = abi.encode(tamperedResult, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        // Signature will recover to some random address that isn't trusted.
        vm.expectRevert(); // InvalidSigner with unpredictable recovered addr
        resolver.resolveWithSig(response, extraData);
    }

    // --- signer rotation ---

    function test_SignerRotation_AddBackup_RevokeOriginal() public {
        // Enable backup signer
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(resolver));
        emit TrustedSignerUpdated(backupSigner, true);
        resolver.setTrustedSigner(backupSigner, true);

        // Backup signature now works
        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        uint64 expiresAt = uint64(block.timestamp + 60);
        bytes memory backupSig = _signResolution(backupSignerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, backupSig);
        bytes memory extraData = abi.encode(DNS_FULL, data);
        resolver.resolveWithSig(response, extraData);

        // Revoke original signer
        vm.prank(owner);
        resolver.setTrustedSigner(signer, false);

        // Original signer's signatures are now rejected
        bytes memory oldSig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory oldResponse = abi.encode(result, expiresAt, oldSig);
        vm.expectRevert(abi.encodeWithSelector(UniversalResolver.InvalidSigner.selector, signer));
        resolver.resolveWithSig(oldResponse, extraData);
    }

    function test_SetTrustedSigner_OnlyOwner() public {
        vm.expectRevert();
        resolver.setTrustedSigner(backupSigner, true);
    }

    function test_RenounceOwnership_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(UniversalResolver.OwnershipCannotBeRenounced.selector);
        resolver.renounceOwnership();
    }

    // --- url setter ---

    function test_SetUrl_OnlyOwner() public {
        vm.expectRevert();
        resolver.setUrl("https://evil.example");

        vm.prank(owner);
        resolver.setUrl("https://new.example");
        assertEq(resolver.url(), "https://new.example");
    }

    // --- EIP-712 domain binding ---

    function test_DomainSeparator_IsNonZero() public view {
        assertTrue(resolver.domainSeparator() != bytes32(0));
    }

    function test_ResolveWithSig_SignatureFromDifferentDomainSeparator_Reverts() public {
        // Simulate a signature built with a wrong domain separator (e.g. another
        // resolver deployment). It should fail to recover the trusted signer.
        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        uint64 expiresAt = uint64(block.timestamp + 60);

        bytes32 structHash = keccak256(
            abi.encode(RESOLUTION_TYPEHASH, keccak256(DNS_FULL), keccak256(data), keccak256(result), expiresAt)
        );
        // Use a bogus domain separator
        bytes32 badDomainSep = keccak256("wrong-domain");
        bytes32 digest = MessageHashUtils.toTypedDataHash(badDomainSep, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        vm.expectRevert(); // recovers some non-trusted address
        resolver.resolveWithSig(response, extraData);
    }

    // --- interface support ---

    function test_SupportsInterface() public view {
        // IERC165
        assertTrue(resolver.supportsInterface(0x01ffc9a7));
        // ENSIP-10 extended resolver
        assertTrue(resolver.supportsInterface(0x9061b923));
        // IExtendedResolver
        assertTrue(resolver.supportsInterface(type(IExtendedResolver).interfaceId));
        // bogus
        assertFalse(resolver.supportsInterface(0xdeadbeef));
    }

    // --- sanity: initial signer was set ---

    function test_InitialSignerIsTrusted() public view {
        assertTrue(resolver.isTrustedSigner(signer));
        assertFalse(resolver.isTrustedSigner(backupSigner));
    }
}

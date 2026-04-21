// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignedUniversalResolver, IExtendedResolver} from "../../src/nameservice/SignedUniversalResolver.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract SignedUniversalResolverTest is Test {
    SignedUniversalResolver public resolver;

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

    event SignerTrusted(address indexed signer);
    event SignerRevoked(address indexed signer);

    string public constant INITIAL_DOMAIN = "clave";

    function _initialDomains() internal pure returns (string[] memory) {
        string[] memory domains = new string[](1);
        domains[0] = INITIAL_DOMAIN;
        return domains;
    }

    function setUp() public {
        owner = makeAddr("owner");
        registry = makeAddr("registry");
        (signer, signerPk) = makeAddrAndKey("signer");
        (backupSigner, backupSignerPk) = makeAddrAndKey("backup");

        resolver = new SignedUniversalResolver(GATEWAY_URL, owner, registry, signer, _initialDomains());
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
        bytes memory shortData = hex"112233"; // only 3 bytes, below 4-byte selector
        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.CallDataTooShort.selector, uint256(3)));
        resolver.resolve(DNS_FULL, shortData);
    }

    function test_Resolve_UnsupportedSelector_Reverts() public {
        bytes memory bogus = abi.encodeWithSelector(bytes4(0xdeadbeef), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.UnsupportedSelector.selector, bytes4(0xdeadbeef)));
        resolver.resolve(DNS_FULL, bogus);
    }

    function test_Resolve_AddrMultichain_WrongCoinType_Reverts() public {
        bytes memory data = _addrMultichainCallData("example.clave.eth", 60); // ETH mainnet coin type
        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.UnsupportedCoinType.selector, uint256(60)));
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

    function test_ResolveWithSig_AddrMultichain_EmptyRecord_HappyPath() public {
        // "No record" for addr(bytes32,uint256) is empty bytes per ENSIP-11.
        bytes memory expectedAddr = bytes("");
        bytes memory data = _addrMultichainCallData("example.clave.eth", ZKSYNC_MAINNET_COIN_TYPE);
        bytes memory result = abi.encode(expectedAddr);
        uint64 expiresAt = uint64(block.timestamp + 60);

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        bytes memory out = resolver.resolveWithSig(response, extraData);
        bytes memory decoded = abi.decode(out, (bytes));
        assertEq(decoded.length, 0);
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
        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.SignatureExpired.selector, expiresAt));
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

        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.SignatureTtlTooLong.selector, expiresAt));
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

        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.InvalidSigner.selector, backupSigner));
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
        emit SignerTrusted(backupSigner);
        resolver.trustSigner(backupSigner);

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
        vm.expectEmit(true, false, false, true, address(resolver));
        emit SignerRevoked(signer);
        resolver.revokeSigner(signer);

        // Original signer's signatures are now rejected
        bytes memory oldSig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory oldResponse = abi.encode(result, expiresAt, oldSig);
        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.InvalidSigner.selector, signer));
        resolver.resolveWithSig(oldResponse, extraData);
    }

    function test_TrustSigner_OnlyOwner() public {
        vm.expectRevert();
        resolver.trustSigner(backupSigner);
    }

    function test_RevokeSigner_OnlyOwner() public {
        vm.expectRevert();
        resolver.revokeSigner(signer);
    }

    function test_Constructor_RevertsOnZeroSigner() public {
        vm.expectRevert(SignedUniversalResolver.ZeroSignerAddress.selector);
        new SignedUniversalResolver(GATEWAY_URL, owner, registry, address(0), _initialDomains());
    }

    function test_Constructor_RevertsOnEmptyUrl() public {
        vm.expectRevert(SignedUniversalResolver.EmptyUrl.selector);
        new SignedUniversalResolver("", owner, registry, signer, _initialDomains());
    }

    function test_Constructor_RevertsOnNoInitialDomains() public {
        string[] memory empty = new string[](0);
        vm.expectRevert(SignedUniversalResolver.NoInitialDomains.selector);
        new SignedUniversalResolver(GATEWAY_URL, owner, registry, signer, empty);
    }

    function test_Constructor_RevertsOnEmptyDomainInArray() public {
        string[] memory domains = new string[](2);
        domains[0] = "nodl";
        domains[1] = "";
        vm.expectRevert(SignedUniversalResolver.EmptyDomain.selector);
        new SignedUniversalResolver(GATEWAY_URL, owner, registry, signer, domains);
    }

    function test_Constructor_SetsInitialDomain() public view {
        assertTrue(resolver.isAllowedDomain(keccak256(bytes(INITIAL_DOMAIN))));
    }

    function test_Constructor_SetsMultipleInitialDomains() public {
        string[] memory domains = new string[](2);
        domains[0] = "nodl";
        domains[1] = "clk";
        SignedUniversalResolver multi = new SignedUniversalResolver(GATEWAY_URL, owner, registry, signer, domains);
        assertTrue(multi.isAllowedDomain(keccak256(bytes("nodl"))));
        assertTrue(multi.isAllowedDomain(keccak256(bytes("clk"))));
        assertFalse(multi.isAllowedDomain(keccak256(bytes("other"))));
    }

    function test_TrustSigner_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SignedUniversalResolver.ZeroSignerAddress.selector);
        resolver.trustSigner(address(0));
    }

    function test_RevokeSigner_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SignedUniversalResolver.ZeroSignerAddress.selector);
        resolver.revokeSigner(address(0));
    }

    function test_RevokeSigner_CannotDisableLastSigner() public {
        vm.prank(owner);
        vm.expectRevert(SignedUniversalResolver.CannotDisableLastTrustedSigner.selector);
        resolver.revokeSigner(signer);
    }

    function test_TrustSigner_IsIdempotent() public {
        assertEq(resolver.trustedSignerCount(), 1);
        // Re-trusting an already-trusted signer is a no-op.
        vm.prank(owner);
        resolver.trustSigner(signer);
        assertEq(resolver.trustedSignerCount(), 1);
    }

    function test_RevokeSigner_IsIdempotent() public {
        // Revoking an already-untrusted signer is a no-op.
        vm.prank(owner);
        resolver.revokeSigner(backupSigner);
        assertEq(resolver.trustedSignerCount(), 1);
    }

    function test_TrustedSignerCount_TracksChanges() public {
        assertEq(resolver.trustedSignerCount(), 1);

        vm.prank(owner);
        resolver.trustSigner(backupSigner);
        assertEq(resolver.trustedSignerCount(), 2);

        vm.prank(owner);
        resolver.revokeSigner(signer);
        assertEq(resolver.trustedSignerCount(), 1);
    }

    function test_RenounceOwnership_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(SignedUniversalResolver.OwnershipCannotBeRenounced.selector);
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

    function test_SetUrl_RevertsOnEmptyUrl() public {
        vm.prank(owner);
        vm.expectRevert(SignedUniversalResolver.EmptyUrl.selector);
        resolver.setUrl("");
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

    // --- domain allowlist ---

    function test_AddDomain_OnlyOwner() public {
        vm.expectRevert();
        resolver.addDomain("nodl");
    }

    function test_AddDomain_Success() public {
        vm.prank(owner);
        resolver.addDomain("nodl");
        assertTrue(resolver.isAllowedDomain(keccak256(bytes("nodl"))));
    }

    function test_AddDomain_IsIdempotent() public {
        vm.prank(owner);
        resolver.addDomain("nodl");
        // Second add is a no-op
        vm.prank(owner);
        resolver.addDomain("nodl");
        assertTrue(resolver.isAllowedDomain(keccak256(bytes("nodl"))));
    }

    function test_AddDomain_RevertsOnEmptyDomain() public {
        vm.prank(owner);
        vm.expectRevert(SignedUniversalResolver.EmptyDomain.selector);
        resolver.addDomain("");
    }

    function test_RemoveDomain_OnlyOwner() public {
        vm.expectRevert();
        resolver.removeDomain(INITIAL_DOMAIN);
    }

    function test_RemoveDomain_Success() public {
        vm.prank(owner);
        resolver.removeDomain(INITIAL_DOMAIN);
        assertFalse(resolver.isAllowedDomain(keccak256(bytes(INITIAL_DOMAIN))));
    }

    function test_RemoveDomain_IsIdempotent() public {
        // Removing an already-disallowed domain is a no-op
        vm.prank(owner);
        resolver.removeDomain("nonexistent");
    }

    function test_RemoveDomain_RevertsOnEmptyDomain() public {
        vm.prank(owner);
        vm.expectRevert(SignedUniversalResolver.EmptyDomain.selector);
        resolver.removeDomain("");
    }

    function test_Resolve_UnknownDomain_Reverts() public {
        // DNS-encoded "example.unknown.eth" — domain is "unknown", not in allowlist
        bytes memory dnsUnknown = hex"076578616d706c6507756e6b6e6f776e0365746800";
        bytes memory data = _addrCallData("example.unknown.eth");

        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.UnknownDomain.selector, "unknown"));
        resolver.resolve(dnsUnknown, data);
    }

    function test_Resolve_AllowedDomain_TriggersOffchainLookup() public {
        // DNS_FULL uses "clave" domain which is in the allowlist
        bytes memory data = _addrCallData("example.clave.eth");
        vm.expectRevert(); // OffchainLookup
        resolver.resolve(DNS_FULL, data);
    }

    function test_Resolve_NewlyAddedDomain_Works() public {
        // Add "nodl" domain
        vm.prank(owner);
        resolver.addDomain("nodl");

        // DNS-encoded "example.nodl.eth"
        bytes memory dnsNodl = hex"076578616d706c65046e6f646c0365746800";
        bytes memory data = _addrCallData("example.nodl.eth");
        vm.expectRevert(); // OffchainLookup
        resolver.resolve(dnsNodl, data);
    }

    function test_Resolve_RemovedDomain_Reverts() public {
        // Remove the initial "clave" domain
        vm.prank(owner);
        resolver.removeDomain(INITIAL_DOMAIN);

        bytes memory data = _addrCallData("example.clave.eth");
        vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.UnknownDomain.selector, "clave"));
        resolver.resolve(DNS_FULL, data);
    }

    // --- sanity: initial signer was set ---

    function test_InitialSignerIsTrusted() public view {
        assertTrue(resolver.isTrustedSigner(signer));
        assertFalse(resolver.isTrustedSigner(backupSigner));
    }

    // --- fuzz: TTL / expiry boundaries ---

    /// @notice Fuzz expiresAt across the full uint64 range.
    ///         Partitions: expired (past), valid window, TTL too long.
    function testFuzz_ResolveWithSig_ExpiresAt(uint64 expiresAt) public {
        // Fix block.timestamp to a known value so the three zones are deterministic.
        uint256 ts = 1_700_000_000;
        vm.warp(ts);

        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        if (expiresAt < ts) {
            // Zone 1: expired — block.timestamp > expiresAt
            vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.SignatureExpired.selector, expiresAt));
            resolver.resolveWithSig(response, extraData);
        } else if (expiresAt > ts + 5 minutes) {
            // Zone 3: TTL too long — expiresAt > block.timestamp + _MAX_SIGNATURE_TTL
            vm.expectRevert(abi.encodeWithSelector(SignedUniversalResolver.SignatureTtlTooLong.selector, expiresAt));
            resolver.resolveWithSig(response, extraData);
        } else {
            // Zone 2: valid window — ts <= expiresAt <= ts + 300
            bytes memory out = resolver.resolveWithSig(response, extraData);
            assertEq(keccak256(out), keccak256(result));
        }
    }

    /// @notice Fuzz block.timestamp while keeping expiresAt fixed at a known valid offset.
    ///         Ensures the expiry check works regardless of when the chain is.
    function testFuzz_ResolveWithSig_Timestamp(uint64 timestamp) public {
        // Bound timestamp to avoid overflow when adding 5 minutes
        vm.assume(timestamp > 0 && timestamp < type(uint64).max - 5 minutes);
        vm.warp(timestamp);

        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        uint64 expiresAt = uint64(timestamp + 60); // 60s into valid window

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        // Should always succeed: expiresAt = now + 60 is within [now, now + 300]
        bytes memory out = resolver.resolveWithSig(response, extraData);
        assertEq(keccak256(out), keccak256(result));
    }

    /// @notice Fuzz the exact boundary: expiresAt == block.timestamp (not expired, edge).
    function testFuzz_ResolveWithSig_ExpiresAtExactlyNow(uint64 timestamp) public {
        vm.assume(timestamp > 0 && timestamp < type(uint64).max - 5 minutes);
        vm.warp(timestamp);

        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        uint64 expiresAt = uint64(timestamp); // exactly now

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        // block.timestamp > expiresAt is false when equal → should succeed
        bytes memory out = resolver.resolveWithSig(response, extraData);
        assertEq(keccak256(out), keccak256(result));
    }

    /// @notice Fuzz the upper boundary: expiresAt == block.timestamp + 5 minutes (max allowed).
    function testFuzz_ResolveWithSig_ExpiresAtMaxTtl(uint64 timestamp) public {
        vm.assume(timestamp > 0 && timestamp < type(uint64).max - 5 minutes);
        vm.warp(timestamp);

        bytes memory data = _addrCallData("example.clave.eth");
        bytes memory result = abi.encode(makeAddr("owner"));
        uint64 expiresAt = uint64(timestamp + 5 minutes); // exactly at cap

        bytes memory sig = _signResolution(signerPk, DNS_FULL, data, result, expiresAt);
        bytes memory response = abi.encode(result, expiresAt, sig);
        bytes memory extraData = abi.encode(DNS_FULL, data);

        // expiresAt == block.timestamp + _MAX_SIGNATURE_TTL → not strictly greater → should succeed
        bytes memory out = resolver.resolveWithSig(response, extraData);
        assertEq(keccak256(out), keccak256(result));
    }

    /// @notice Fuzz DNS-encoded names with variable-length segments.
    ///         Verifies resolve() doesn't panic on arbitrary well-formed DNS names.
    function testFuzz_Resolve_DnsName(uint8 subLen, uint8 domLen, uint8 tldLen) public {
        // Bound lengths to [1,63] per DNS label rules
        subLen = uint8(bound(subLen, 1, 63));
        domLen = uint8(bound(domLen, 1, 63));
        tldLen = uint8(bound(tldLen, 1, 63));

        // Build DNS-encoded name: <subLen><sub><domLen><dom><tldLen><tld><0x00>
        bytes memory name = new bytes(uint256(subLen) + uint256(domLen) + uint256(tldLen) + 4);
        name[0] = bytes1(subLen);
        // Fill sub with 'a'
        for (uint256 i = 0; i < subLen; i++) {
            name[1 + i] = "a";
        }
        name[1 + subLen] = bytes1(domLen);
        // Fill dom with 'b'
        for (uint256 i = 0; i < domLen; i++) {
            name[2 + subLen + i] = "b";
        }
        name[2 + subLen + domLen] = bytes1(tldLen);
        // Fill tld with 'c'
        for (uint256 i = 0; i < tldLen; i++) {
            name[3 + subLen + domLen + i] = "c";
        }
        name[name.length - 1] = 0x00;

        bytes memory data = _addrCallData("test");

        // Has a subdomain → should revert (UnknownDomain for non-allowlisted
        // domains, OffchainLookup for allowlisted ones). Either way, no panic.
        vm.expectRevert();
        resolver.resolve(name, data);
    }
}

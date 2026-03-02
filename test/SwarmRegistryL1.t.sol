// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "../src/swarms/SwarmRegistryL1.sol";
import {FleetIdentity} from "../src/swarms/FleetIdentity.sol";
import {ServiceProvider} from "../src/swarms/ServiceProvider.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockBondTokenL1 is ERC20 {
    constructor() ERC20("Mock Bond", "MBOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SwarmRegistryL1Test is Test {
    SwarmRegistryL1 swarmRegistry;
    FleetIdentity fleetContract;
    ServiceProvider providerContract;
    MockBondTokenL1 bondToken;

    address fleetOwner = address(0x1);
    address providerOwner = address(0x2);
    address caller = address(0x3);

    uint256 constant FLEET_BOND = 100 ether;

    // Region constants for fleet registration
    uint16 constant US = 840;
    uint16 constant ADMIN_CA = 6; // California

    event SwarmRegistered(uint256 indexed swarmId, bytes16 indexed fleetUuid, uint256 indexed providerId, address owner);
    event SwarmStatusChanged(uint256 indexed swarmId, SwarmRegistryL1.SwarmStatus status);
    event SwarmFilterUpdated(uint256 indexed swarmId, address indexed owner, uint32 filterSize);
    event SwarmProviderUpdated(uint256 indexed swarmId, uint256 indexed oldProvider, uint256 indexed newProvider);
    event SwarmDeleted(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed owner);
    event SwarmPurged(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed purgedBy);

    function setUp() public {
        bondToken = new MockBondTokenL1();
        fleetContract = new FleetIdentity(address(bondToken), FLEET_BOND);
        providerContract = new ServiceProvider();
        swarmRegistry = new SwarmRegistryL1(address(fleetContract), address(providerContract));

        // Fund fleet owner and approve
        bondToken.mint(fleetOwner, 1_000_000 ether);
        vm.prank(fleetOwner);
        bondToken.approve(address(fleetContract), type(uint256).max);
    }

    // ==============================
    // Helpers
    // ==============================

    function _registerFleet(address owner, bytes memory seed) internal returns (uint256) {
        vm.prank(owner);
        return fleetContract.registerFleetLocal(bytes16(keccak256(seed)), US, ADMIN_CA, 0);
    }

    function _getFleetUuid(uint256 fleetId) internal pure returns (bytes16) {
        return bytes16(uint128(fleetId));
    }

    function _registerProvider(address owner, string memory url) internal returns (uint256) {
        vm.prank(owner);
        return providerContract.registerProvider(url);
    }

    function _registerSwarm(
        address owner,
        uint256 fleetId,
        uint256 providerId,
        bytes memory filter,
        uint8 fpSize,
        SwarmRegistryL1.TagType tagType
    ) internal returns (uint256) {
        bytes16 fleetUuid = _getFleetUuid(fleetId);
        vm.prank(owner);
        return swarmRegistry.registerSwarm(fleetUuid, providerId, filter, fpSize, tagType);
    }

    function getExpectedValues(bytes memory tagId, uint256 m, uint8 fpSize)
        public
        pure
        returns (uint32 h1, uint32 h2, uint32 h3, uint256 fp)
    {
        bytes32 h = keccak256(tagId);
        h1 = uint32(uint256(h)) % uint32(m);
        h2 = uint32(uint256(h) >> 32) % uint32(m);
        h3 = uint32(uint256(h) >> 64) % uint32(m);
        uint256 fpMask = (uint256(1) << fpSize) - 1;
        fp = (uint256(h) >> 96) & fpMask;
    }

    function _write16Bit(bytes memory data, uint256 slotIndex, uint16 value) internal pure {
        uint256 bitOffset = slotIndex * 16;
        uint256 byteOffset = bitOffset / 8;
        data[byteOffset] = bytes1(uint8(value >> 8));
        data[byteOffset + 1] = bytes1(uint8(value));
    }

    function _write8Bit(bytes memory data, uint256 slotIndex, uint8 value) internal pure {
        data[slotIndex] = bytes1(value);
    }

    // ==============================
    // Constructor
    // ==============================

    function test_constructor_setsImmutables() public view {
        assertEq(address(swarmRegistry.FLEET_CONTRACT()), address(fleetContract));
        assertEq(address(swarmRegistry.PROVIDER_CONTRACT()), address(providerContract));
    }

    function test_RevertIf_constructor_zeroFleetAddress() public {
        vm.expectRevert(SwarmRegistryL1.InvalidSwarmData.selector);
        new SwarmRegistryL1(address(0), address(providerContract));
    }

    function test_RevertIf_constructor_zeroProviderAddress() public {
        vm.expectRevert(SwarmRegistryL1.InvalidSwarmData.selector);
        new SwarmRegistryL1(address(fleetContract), address(0));
    }

    function test_RevertIf_constructor_bothZero() public {
        vm.expectRevert(SwarmRegistryL1.InvalidSwarmData.selector);
        new SwarmRegistryL1(address(0), address(0));
    }

    // ==============================
    // registerSwarm — happy path
    // ==============================

    function test_registerSwarm_basicFlow() public {
        uint256 fleetId = _registerFleet(fleetOwner, "my-fleet");
        uint256 providerId = _registerProvider(providerOwner, "https://api.example.com");

        uint256 swarmId = _registerSwarm(
            fleetOwner, fleetId, providerId, new bytes(100), 16, SwarmRegistryL1.TagType.IBEACON_INCLUDES_MAC
        );

        // Swarm ID is deterministic hash of (fleetUuid, providerId, filter)
        uint256 expectedId = swarmRegistry.computeSwarmId(_getFleetUuid(fleetId), providerId, new bytes(100));
        assertEq(swarmId, expectedId);
    }

    function test_registerSwarm_storesMetadataCorrectly() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.VENDOR_ID);

        (
            bytes16 storedFleetUuid,
            uint256 storedProviderId,
            address filterPointer,
            uint8 storedFpSize,
            SwarmRegistryL1.TagType storedTagType,
            SwarmRegistryL1.SwarmStatus storedStatus
        ) = swarmRegistry.swarms(swarmId);

        assertEq(storedFleetUuid, _getFleetUuid(fleetId));
        assertEq(storedProviderId, providerId);
        assertTrue(filterPointer != address(0));
        assertEq(storedFpSize, 8);
        assertEq(uint8(storedTagType), uint8(SwarmRegistryL1.TagType.VENDOR_ID));
        assertEq(uint8(storedStatus), uint8(SwarmRegistryL1.SwarmStatus.REGISTERED));
    }

    function test_registerSwarm_deterministicId() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        bytes memory filter = new bytes(32);

        uint256 expectedId = swarmRegistry.computeSwarmId(_getFleetUuid(fleetId), providerId, filter);

        uint256 swarmId = _registerSwarm(fleetOwner, fleetId, providerId, filter, 8, SwarmRegistryL1.TagType.GENERIC);
        assertEq(swarmId, expectedId);
    }

    function test_RevertIf_registerSwarm_duplicateSwarm() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        _registerSwarm(fleetOwner, fleetId, providerId, new bytes(32), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmAlreadyExists.selector);
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), providerId, new bytes(32), 8, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_registerSwarm_emitsSwarmRegistered() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        bytes memory filter = new bytes(50);
        uint256 expectedId = swarmRegistry.computeSwarmId(_getFleetUuid(fleetId), providerId, filter);

        vm.expectEmit(true, true, true, true);
        emit SwarmRegistered(expectedId, _getFleetUuid(fleetId), providerId, fleetOwner);

        _registerSwarm(fleetOwner, fleetId, providerId, filter, 16, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_registerSwarm_linksUuidSwarms() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId1 = _registerProvider(providerOwner, "url1");
        uint256 providerId2 = _registerProvider(providerOwner, "url2");

        uint256 swarmId1 =
            _registerSwarm(fleetOwner, fleetId, providerId1, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 swarmId2 =
            _registerSwarm(fleetOwner, fleetId, providerId2, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 0), swarmId1);
        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 1), swarmId2);
    }

    function test_registerSwarm_allTagTypes() public {
        uint256 fleetId1 = _registerFleet(fleetOwner, "f1");
        uint256 fleetId2 = _registerFleet(fleetOwner, "f2");
        uint256 fleetId3 = _registerFleet(fleetOwner, "f3");
        uint256 fleetId4 = _registerFleet(fleetOwner, "f4");
        uint256 providerId = _registerProvider(providerOwner, "url");

        uint256 s1 = _registerSwarm(
            fleetOwner, fleetId1, providerId, new bytes(32), 8, SwarmRegistryL1.TagType.IBEACON_PAYLOAD_ONLY
        );
        uint256 s2 = _registerSwarm(
            fleetOwner, fleetId2, providerId, new bytes(32), 8, SwarmRegistryL1.TagType.IBEACON_INCLUDES_MAC
        );
        uint256 s3 =
            _registerSwarm(fleetOwner, fleetId3, providerId, new bytes(32), 8, SwarmRegistryL1.TagType.VENDOR_ID);
        uint256 s4 = _registerSwarm(fleetOwner, fleetId4, providerId, new bytes(32), 8, SwarmRegistryL1.TagType.GENERIC);

        (,,,, SwarmRegistryL1.TagType t1,) = swarmRegistry.swarms(s1);
        (,,,, SwarmRegistryL1.TagType t2,) = swarmRegistry.swarms(s2);
        (,,,, SwarmRegistryL1.TagType t3,) = swarmRegistry.swarms(s3);
        (,,,, SwarmRegistryL1.TagType t4,) = swarmRegistry.swarms(s4);

        assertEq(uint8(t1), uint8(SwarmRegistryL1.TagType.IBEACON_PAYLOAD_ONLY));
        assertEq(uint8(t2), uint8(SwarmRegistryL1.TagType.IBEACON_INCLUDES_MAC));
        assertEq(uint8(t3), uint8(SwarmRegistryL1.TagType.VENDOR_ID));
        assertEq(uint8(t4), uint8(SwarmRegistryL1.TagType.GENERIC));
    }

    // ==============================
    // registerSwarm — reverts
    // ==============================

    function test_RevertIf_registerSwarm_notUuidOwner() public {
        uint256 fleetId = _registerFleet(fleetOwner, "my-fleet");

        vm.prank(caller);
        vm.expectRevert(SwarmRegistryL1.NotUuidOwner.selector);
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), 1, new bytes(10), 16, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_RevertIf_registerSwarm_zeroUuid() public {
        uint256 providerId = _registerProvider(providerOwner, "url1");

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidUuid.selector);
        swarmRegistry.registerSwarm(bytes16(0), providerId, new bytes(32), 8, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_RevertIf_registerSwarm_providerDoesNotExist() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 nonExistentProvider = 12345;

        vm.prank(fleetOwner);
        // ERC721.ownerOf reverts for non-existent tokens before our ProviderDoesNotExist check
        vm.expectRevert();
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), nonExistentProvider, new bytes(32), 8, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_RevertIf_registerSwarm_fingerprintSizeZero() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidFingerprintSize.selector);
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), providerId, new bytes(32), 0, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_RevertIf_registerSwarm_fingerprintSizeExceedsMax() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidFingerprintSize.selector);
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), providerId, new bytes(32), 17, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_RevertIf_registerSwarm_emptyFilter() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidFilterSize.selector);
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), providerId, new bytes(0), 8, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_RevertIf_registerSwarm_filterTooLarge() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidFilterSize.selector);
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), providerId, new bytes(24577), 8, SwarmRegistryL1.TagType.GENERIC);
    }

    function test_registerSwarm_maxFingerprintSize() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        // fpSize=16 is MAX_FINGERPRINT_SIZE, should succeed
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(100), 16, SwarmRegistryL1.TagType.GENERIC);
        assertTrue(swarmId != 0);
    }

    function test_registerSwarm_maxFilterSize() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        // Exactly 24576 bytes should succeed
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(24576), 8, SwarmRegistryL1.TagType.GENERIC);
        assertTrue(swarmId != 0);
    }

    // ==============================
    // acceptSwarm / rejectSwarm
    // ==============================

    function test_acceptSwarm_setsStatusAndEmits() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.expectEmit(true, true, true, true);
        emit SwarmStatusChanged(swarmId, SwarmRegistryL1.SwarmStatus.ACCEPTED);

        vm.prank(providerOwner);
        swarmRegistry.acceptSwarm(swarmId);

        (,,,,, SwarmRegistryL1.SwarmStatus status) = swarmRegistry.swarms(swarmId);
        assertEq(uint8(status), uint8(SwarmRegistryL1.SwarmStatus.ACCEPTED));
    }

    function test_rejectSwarm_setsStatusAndEmits() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.expectEmit(true, true, true, true);
        emit SwarmStatusChanged(swarmId, SwarmRegistryL1.SwarmStatus.REJECTED);

        vm.prank(providerOwner);
        swarmRegistry.rejectSwarm(swarmId);

        (,,,,, SwarmRegistryL1.SwarmStatus status) = swarmRegistry.swarms(swarmId);
        assertEq(uint8(status), uint8(SwarmRegistryL1.SwarmStatus.REJECTED));
    }

    function test_RevertIf_acceptSwarm_notProviderOwner() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(caller);
        vm.expectRevert(SwarmRegistryL1.NotProviderOwner.selector);
        swarmRegistry.acceptSwarm(swarmId);
    }

    function test_RevertIf_rejectSwarm_notProviderOwner() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(fleetOwner); // fleet owner != provider owner
        vm.expectRevert(SwarmRegistryL1.NotProviderOwner.selector);
        swarmRegistry.rejectSwarm(swarmId);
    }

    function test_acceptSwarm_afterReject() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(providerOwner);
        swarmRegistry.rejectSwarm(swarmId);

        // Provider changes mind
        vm.prank(providerOwner);
        swarmRegistry.acceptSwarm(swarmId);

        (,,,,, SwarmRegistryL1.SwarmStatus status) = swarmRegistry.swarms(swarmId);
        assertEq(uint8(status), uint8(SwarmRegistryL1.SwarmStatus.ACCEPTED));
    }

    // ==============================
    // checkMembership — XOR logic
    // ==============================

    function test_checkMembership_XORLogic16Bit() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "u1");

        bytes memory tagId = hex"1122334455";
        uint8 fpSize = 16;
        uint256 dataLen = 100;
        uint256 m = (dataLen * 8) / fpSize; // 50 slots

        (uint32 h1, uint32 h2, uint32 h3, uint256 expectedFp) = getExpectedValues(tagId, m, fpSize);

        // Skip if collision (extremely unlikely with 50 slots)
        if (h1 == h2 || h1 == h3 || h2 == h3) {
            return;
        }

        bytes memory filter = new bytes(dataLen);
        _write16Bit(filter, h1, uint16(expectedFp));

        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, filter, fpSize, SwarmRegistryL1.TagType.GENERIC);

        // Positive check
        assertTrue(swarmRegistry.checkMembership(swarmId, keccak256(tagId)), "Valid tag should pass");

        // Negative check
        assertFalse(swarmRegistry.checkMembership(swarmId, keccak256(hex"999999")), "Invalid tag should fail");
    }

    function test_checkMembership_XORLogic8Bit() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "u1");

        bytes memory tagId = hex"AABBCCDD";
        uint8 fpSize = 8;
        // SSTORE2 prepends 0x00 STOP byte, so on-chain:
        //   extcodesize = rawLen + 1, dataLen = extcodesize - 1 = rawLen
        // But SSTORE2.read offsets reads by +1 (skips STOP byte), so
        // the data bytes read on-chain map 1:1 to the bytes we pass in.
        // Therefore m = (rawLen * 8) / fpSize and slot indices match directly.
        uint256 rawLen = 80;
        uint256 m = (rawLen * 8) / fpSize; // 80

        (uint32 h1, uint32 h2, uint32 h3, uint256 expectedFp) = getExpectedValues(tagId, m, fpSize);

        if (h1 == h2 || h1 == h3 || h2 == h3) {
            return;
        }

        bytes memory filter = new bytes(rawLen);
        _write8Bit(filter, h1, uint8(expectedFp));

        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, filter, fpSize, SwarmRegistryL1.TagType.GENERIC);

        assertTrue(swarmRegistry.checkMembership(swarmId, keccak256(tagId)), "8-bit valid tag should pass");
        assertFalse(swarmRegistry.checkMembership(swarmId, keccak256(hex"FFFFFF")), "8-bit invalid tag should fail");
    }

    function test_RevertIf_checkMembership_swarmNotFound() public {
        vm.expectRevert(SwarmRegistryL1.SwarmNotFound.selector);
        swarmRegistry.checkMembership(999, keccak256("anything"));
    }

    function test_checkMembership_allZeroFilter_returnsConsistent() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "u1");

        // All-zero filter: f1^f2^f3 = 0^0^0 = 0
        // Only matches if expectedFp is also 0
        bytes memory filter = new bytes(64);
        uint256 swarmId = _registerSwarm(fleetOwner, fleetId, providerId, filter, 16, SwarmRegistryL1.TagType.GENERIC);

        // Some tags will match (those with expectedFp=0), most won't
        // The point is it doesn't revert
        swarmRegistry.checkMembership(swarmId, keccak256("test1"));
        swarmRegistry.checkMembership(swarmId, keccak256("test2"));
    }

    function test_checkMembership_tinyFilter_returnsFalse() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "u1");

        // 1-byte filter with 16-bit fingerprint: m = (1*8)/16 = 0, returns false immediately
        bytes memory filter = new bytes(1);
        uint256 swarmId = _registerSwarm(fleetOwner, fleetId, providerId, filter, 16, SwarmRegistryL1.TagType.GENERIC);

        // Should return false (not revert) because m == 0
        assertFalse(swarmRegistry.checkMembership(swarmId, keccak256("test")), "m=0 should return false");
    }

    // ==============================
    // Multiple swarms per fleet
    // ==============================

    function test_multipleSwarms_sameFleet() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId1 = _registerProvider(providerOwner, "url1");
        uint256 providerId2 = _registerProvider(providerOwner, "url2");
        uint256 providerId3 = _registerProvider(providerOwner, "url3");

        uint256 s1 = _registerSwarm(fleetOwner, fleetId, providerId1, new bytes(32), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 s2 =
            _registerSwarm(fleetOwner, fleetId, providerId2, new bytes(64), 16, SwarmRegistryL1.TagType.VENDOR_ID);
        uint256 s3 = _registerSwarm(
            fleetOwner, fleetId, providerId3, new bytes(50), 12, SwarmRegistryL1.TagType.IBEACON_PAYLOAD_ONLY
        );

        // IDs are distinct hashes
        assertTrue(s1 != s2 && s2 != s3 && s1 != s3);

        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 0), s1);
        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 1), s2);
        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 2), s3);
    }

    // ==============================
    // Constants
    // ==============================

    function test_constants() public view {
        assertEq(swarmRegistry.MAX_FINGERPRINT_SIZE(), 16);
    }

    // ==============================
    // Fuzz
    // ==============================

    function testFuzz_registerSwarm_validFingerprintSizes(uint8 fpSize) public {
        fpSize = uint8(bound(fpSize, 1, 16));

        uint256 fleetId = _registerFleet(fleetOwner, abi.encodePacked("fleet-", fpSize));
        uint256 providerId = _registerProvider(providerOwner, string(abi.encodePacked("url-", fpSize)));

        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(64), fpSize, SwarmRegistryL1.TagType.GENERIC);

        (,,, uint8 storedFp,,) = swarmRegistry.swarms(swarmId);
        assertEq(storedFp, fpSize);
    }

    function testFuzz_registerSwarm_invalidFingerprintSizes(uint8 fpSize) public {
        vm.assume(fpSize == 0 || fpSize > 16);

        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidFingerprintSize.selector);
        swarmRegistry.registerSwarm(_getFleetUuid(fleetId), providerId, new bytes(32), fpSize, SwarmRegistryL1.TagType.GENERIC);
    }

    // ==============================
    // updateSwarmFilter
    // ==============================

    function test_updateSwarmFilter_updatesFilterAndResetsStatus() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Provider accepts
        vm.prank(providerOwner);
        swarmRegistry.acceptSwarm(swarmId);

        // Fleet owner updates filter
        bytes memory newFilter = new bytes(100);
        vm.expectEmit(true, true, true, true);
        emit SwarmFilterUpdated(swarmId, fleetOwner, 100);

        vm.prank(fleetOwner);
        swarmRegistry.updateSwarmFilter(swarmId, newFilter);

        // Status should be reset to REGISTERED
        (,,,,, SwarmRegistryL1.SwarmStatus status) = swarmRegistry.swarms(swarmId);
        assertEq(uint8(status), uint8(SwarmRegistryL1.SwarmStatus.REGISTERED));
    }

    function test_updateSwarmFilter_changesFilterPointer() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        (,, address oldPointer,,,) = swarmRegistry.swarms(swarmId);

        bytes memory newFilter = new bytes(100);
        vm.prank(fleetOwner);
        swarmRegistry.updateSwarmFilter(swarmId, newFilter);

        (,, address newPointer,,,) = swarmRegistry.swarms(swarmId);
        assertTrue(newPointer != oldPointer);
        assertTrue(newPointer != address(0));
    }

    function test_RevertIf_updateSwarmFilter_swarmNotFound() public {
        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmNotFound.selector);
        swarmRegistry.updateSwarmFilter(999, new bytes(50));
    }

    function test_RevertIf_updateSwarmFilter_notFleetOwner() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(caller);
        vm.expectRevert(SwarmRegistryL1.NotUuidOwner.selector);
        swarmRegistry.updateSwarmFilter(swarmId, new bytes(100));
    }

    function test_RevertIf_updateSwarmFilter_emptyFilter() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidFilterSize.selector);
        swarmRegistry.updateSwarmFilter(swarmId, new bytes(0));
    }

    function test_RevertIf_updateSwarmFilter_filterTooLarge() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.InvalidFilterSize.selector);
        swarmRegistry.updateSwarmFilter(swarmId, new bytes(24577));
    }

    // ==============================
    // updateSwarmProvider
    // ==============================

    function test_updateSwarmProvider_updatesProviderAndResetsStatus() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId1 = _registerProvider(providerOwner, "url1");
        uint256 providerId2 = _registerProvider(providerOwner, "url2");

        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId1, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Provider accepts
        vm.prank(providerOwner);
        swarmRegistry.acceptSwarm(swarmId);

        // Fleet owner updates provider
        vm.expectEmit(true, true, true, true);
        emit SwarmProviderUpdated(swarmId, providerId1, providerId2);

        vm.prank(fleetOwner);
        swarmRegistry.updateSwarmProvider(swarmId, providerId2);

        // Check new provider and status reset
        (, uint256 newProviderId,,,, SwarmRegistryL1.SwarmStatus status) = swarmRegistry.swarms(swarmId);
        assertEq(newProviderId, providerId2);
        assertEq(uint8(status), uint8(SwarmRegistryL1.SwarmStatus.REGISTERED));
    }

    function test_RevertIf_updateSwarmProvider_swarmNotFound() public {
        uint256 providerId = _registerProvider(providerOwner, "url1");

        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmNotFound.selector);
        swarmRegistry.updateSwarmProvider(999, providerId);
    }

    function test_RevertIf_updateSwarmProvider_notFleetOwner() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId1 = _registerProvider(providerOwner, "url1");
        uint256 providerId2 = _registerProvider(providerOwner, "url2");

        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId1, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(caller);
        vm.expectRevert(SwarmRegistryL1.NotUuidOwner.selector);
        swarmRegistry.updateSwarmProvider(swarmId, providerId2);
    }

    function test_RevertIf_updateSwarmProvider_providerDoesNotExist() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");

        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(fleetOwner);
        // ERC721 reverts before our custom error is reached
        vm.expectRevert();
        swarmRegistry.updateSwarmProvider(swarmId, 99999);
    }

    // ==============================
    // deleteSwarm
    // ==============================

    function test_deleteSwarm_removesSwarmAndEmits() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.expectEmit(true, true, true, true);
        emit SwarmDeleted(swarmId, _getFleetUuid(fleetId), fleetOwner);

        vm.prank(fleetOwner);
        swarmRegistry.deleteSwarm(swarmId);

        // Swarm should be zeroed
        (,, address pointer,,,) = swarmRegistry.swarms(swarmId);
        assertEq(pointer, address(0));
    }

    function test_deleteSwarm_removesFromUuidSwarms() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId1 = _registerProvider(providerOwner, "url1");
        uint256 providerId2 = _registerProvider(providerOwner, "url2");

        uint256 swarm1 =
            _registerSwarm(fleetOwner, fleetId, providerId1, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 swarm2 =
            _registerSwarm(fleetOwner, fleetId, providerId2, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Delete first swarm
        vm.prank(fleetOwner);
        swarmRegistry.deleteSwarm(swarm1);

        // Only swarm2 should remain in fleetSwarms
        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 0), swarm2);
        vm.expectRevert();
        swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 1); // Should be out of bounds
    }

    function test_deleteSwarm_swapAndPop() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId1 = _registerProvider(providerOwner, "url1");
        uint256 providerId2 = _registerProvider(providerOwner, "url2");
        uint256 providerId3 = _registerProvider(providerOwner, "url3");

        uint256 swarm1 =
            _registerSwarm(fleetOwner, fleetId, providerId1, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 swarm2 =
            _registerSwarm(fleetOwner, fleetId, providerId2, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 swarm3 =
            _registerSwarm(fleetOwner, fleetId, providerId3, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Delete middle swarm
        vm.prank(fleetOwner);
        swarmRegistry.deleteSwarm(swarm2);

        // swarm3 should be swapped to index 1
        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 0), swarm1);
        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 1), swarm3);
        vm.expectRevert();
        swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 2); // Should be out of bounds
    }

    function test_RevertIf_deleteSwarm_swarmNotFound() public {
        vm.prank(fleetOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmNotFound.selector);
        swarmRegistry.deleteSwarm(999);
    }

    function test_RevertIf_deleteSwarm_notFleetOwner() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(caller);
        vm.expectRevert(SwarmRegistryL1.NotUuidOwner.selector);
        swarmRegistry.deleteSwarm(swarmId);
    }

    function test_deleteSwarm_afterUpdate() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Update then delete
        vm.prank(fleetOwner);
        swarmRegistry.updateSwarmFilter(swarmId, new bytes(100));

        vm.prank(fleetOwner);
        swarmRegistry.deleteSwarm(swarmId);

        (,, address pointer,,,) = swarmRegistry.swarms(swarmId);
        assertEq(pointer, address(0));
    }

    function test_deleteSwarm_updatesSwarmIndexInUuid() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 p1 = _registerProvider(providerOwner, "url1");
        uint256 p2 = _registerProvider(providerOwner, "url2");
        uint256 p3 = _registerProvider(providerOwner, "url3");

        uint256 s1 = _registerSwarm(fleetOwner, fleetId, p1, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 s2 = _registerSwarm(fleetOwner, fleetId, p2, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 s3 = _registerSwarm(fleetOwner, fleetId, p3, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Verify initial indices
        assertEq(swarmRegistry.swarmIndexInUuid(s1), 0);
        assertEq(swarmRegistry.swarmIndexInUuid(s2), 1);
        assertEq(swarmRegistry.swarmIndexInUuid(s3), 2);

        // Delete s1 — s3 should be swapped to index 0
        vm.prank(fleetOwner);
        swarmRegistry.deleteSwarm(s1);

        assertEq(swarmRegistry.swarmIndexInUuid(s3), 0);
        assertEq(swarmRegistry.swarmIndexInUuid(s2), 1);
        assertEq(swarmRegistry.swarmIndexInUuid(s1), 0); // deleted, reset to 0
    }

    // ==============================
    // isSwarmValid
    // ==============================

    function test_isSwarmValid_bothValid() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        (bool fleetValid, bool providerValid) = swarmRegistry.isSwarmValid(swarmId);
        assertTrue(fleetValid);
        assertTrue(providerValid);
    }

    function test_isSwarmValid_providerBurned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn provider
        vm.prank(providerOwner);
        providerContract.burn(providerId);

        (bool fleetValid, bool providerValid) = swarmRegistry.isSwarmValid(swarmId);
        assertTrue(fleetValid);
        assertFalse(providerValid);
    }

    function test_isSwarmValid_fleetBurned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn registered fleet token (operator = owner for fresh registration)
        // This mints an owned-only token back to the owner
        vm.prank(fleetOwner);
        fleetContract.burn(fleetId);

        // After burning registered token, UUID transitions to Owned state
        // Need to burn the owned-only token to fully release
        bytes16 uuid = _getFleetUuid(fleetId);
        uint256 ownedTokenId = uint256(uint128(uuid)); // owned token has regionKey=0
        vm.prank(fleetOwner);
        fleetContract.burn(ownedTokenId);

        (bool fleetValid, bool providerValid) = swarmRegistry.isSwarmValid(swarmId);
        assertFalse(fleetValid);
        assertTrue(providerValid);
    }

    function test_isSwarmValid_bothBurned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn registered fleet token → mints owned-only token
        vm.prank(fleetOwner);
        fleetContract.burn(fleetId);

        // Burn owned-only token to fully release UUID
        bytes16 uuid = _getFleetUuid(fleetId);
        uint256 ownedTokenId = uint256(uint128(uuid));
        vm.prank(fleetOwner);
        fleetContract.burn(ownedTokenId);

        vm.prank(providerOwner);
        providerContract.burn(providerId);

        (bool fleetValid, bool providerValid) = swarmRegistry.isSwarmValid(swarmId);
        assertFalse(fleetValid);
        assertFalse(providerValid);
    }

    function test_RevertIf_isSwarmValid_swarmNotFound() public {
        vm.expectRevert(SwarmRegistryL1.SwarmNotFound.selector);
        swarmRegistry.isSwarmValid(999);
    }

    // ==============================
    // purgeOrphanedSwarm
    // ==============================

    function test_purgeOrphanedSwarm_providerBurned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn provider
        vm.prank(providerOwner);
        providerContract.burn(providerId);

        // Anyone can purge
        vm.expectEmit(true, true, true, true);
        emit SwarmPurged(swarmId, _getFleetUuid(fleetId), caller);

        vm.prank(caller);
        swarmRegistry.purgeOrphanedSwarm(swarmId);

        // Swarm should be zeroed
        (,, address pointer,,,) = swarmRegistry.swarms(swarmId);
        assertEq(pointer, address(0));
    }

    function test_purgeOrphanedSwarm_fleetBurned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn registered fleet token → mints owned-only token
        vm.prank(fleetOwner);
        fleetContract.burn(fleetId);

        // Burn owned-only token to fully release UUID
        bytes16 uuid = _getFleetUuid(fleetId);
        uint256 ownedTokenId = uint256(uint128(uuid));
        vm.prank(fleetOwner);
        fleetContract.burn(ownedTokenId);

        vm.prank(caller);
        swarmRegistry.purgeOrphanedSwarm(swarmId);

        (,, address pointer,,,) = swarmRegistry.swarms(swarmId);
        assertEq(pointer, address(0));
    }

    function test_purgeOrphanedSwarm_removesFromUuidSwarms() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 p1 = _registerProvider(providerOwner, "url1");
        uint256 p2 = _registerProvider(providerOwner, "url2");

        uint256 s1 = _registerSwarm(fleetOwner, fleetId, p1, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);
        uint256 s2 = _registerSwarm(fleetOwner, fleetId, p2, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn provider of s1
        vm.prank(providerOwner);
        providerContract.burn(p1);

        vm.prank(caller);
        swarmRegistry.purgeOrphanedSwarm(s1);

        // s2 should be swapped to index 0
        assertEq(swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 0), s2);
        vm.expectRevert();
        swarmRegistry.uuidSwarms(_getFleetUuid(fleetId), 1);
    }

    function test_RevertIf_purgeOrphanedSwarm_swarmNotFound() public {
        vm.expectRevert(SwarmRegistryL1.SwarmNotFound.selector);
        swarmRegistry.purgeOrphanedSwarm(999);
    }

    function test_RevertIf_purgeOrphanedSwarm_swarmNotOrphaned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.expectRevert(SwarmRegistryL1.SwarmNotOrphaned.selector);
        swarmRegistry.purgeOrphanedSwarm(swarmId);
    }

    // ==============================
    // Orphan guards on accept/reject/checkMembership
    // ==============================

    function test_RevertIf_acceptSwarm_orphaned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn provider
        vm.prank(providerOwner);
        providerContract.burn(providerId);

        vm.prank(providerOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmOrphaned.selector);
        swarmRegistry.acceptSwarm(swarmId);
    }

    function test_RevertIf_rejectSwarm_orphaned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn registered fleet token → mints owned-only token
        vm.prank(fleetOwner);
        fleetContract.burn(fleetId);

        // Burn owned-only token to fully release UUID
        bytes16 uuid = _getFleetUuid(fleetId);
        uint256 ownedTokenId = uint256(uint128(uuid));
        vm.prank(fleetOwner);
        fleetContract.burn(ownedTokenId);

        vm.prank(providerOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmOrphaned.selector);
        swarmRegistry.rejectSwarm(swarmId);
    }

    function test_RevertIf_checkMembership_orphaned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn provider
        vm.prank(providerOwner);
        providerContract.burn(providerId);

        vm.expectRevert(SwarmRegistryL1.SwarmOrphaned.selector);
        swarmRegistry.checkMembership(swarmId, keccak256("test"));
    }

    function test_RevertIf_acceptSwarm_fleetBurned() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        // Burn registered fleet token → mints owned-only token
        vm.prank(fleetOwner);
        fleetContract.burn(fleetId);

        // Burn owned-only token to fully release UUID
        bytes16 uuid = _getFleetUuid(fleetId);
        uint256 ownedTokenId = uint256(uint128(uuid));
        vm.prank(fleetOwner);
        fleetContract.burn(ownedTokenId);

        vm.prank(providerOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmOrphaned.selector);
        swarmRegistry.acceptSwarm(swarmId);
    }

    function test_purge_thenAcceptReverts() public {
        uint256 fleetId = _registerFleet(fleetOwner, "f1");
        uint256 providerId = _registerProvider(providerOwner, "url1");
        uint256 swarmId =
            _registerSwarm(fleetOwner, fleetId, providerId, new bytes(50), 8, SwarmRegistryL1.TagType.GENERIC);

        vm.prank(providerOwner);
        providerContract.burn(providerId);

        vm.prank(caller);
        swarmRegistry.purgeOrphanedSwarm(swarmId);

        // After purge, swarm no longer exists
        vm.prank(providerOwner);
        vm.expectRevert(SwarmRegistryL1.SwarmNotFound.selector);
        swarmRegistry.acceptSwarm(swarmId);
    }
}

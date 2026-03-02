// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FleetIdentity} from "./FleetIdentity.sol";
import {ServiceProvider} from "./ServiceProvider.sol";

/**
 * @title SwarmRegistryUniversal
 * @notice Permissionless BLE swarm registry compatible with all EVM chains (including ZkSync Era).
 * @dev Uses native `bytes` storage for cross-chain compatibility.
 *
 *      Swarms are defined for a **fleet UUID** (not a token ID), allowing swarms to be
 *      registered for any UUID that has been claimed/registered in FleetIdentity,
 *      regardless of whether it's assigned to a region or is in "owned-only" mode.
 *      This decouples swarm management from geographic tier placement.
 */
contract SwarmRegistryUniversal is ReentrancyGuard {
    error InvalidFingerprintSize();
    error InvalidFilterSize();
    error InvalidUuid();
    error NotUuidOwner();
    error ProviderDoesNotExist();
    error NotProviderOwner();
    error SwarmNotFound();
    error InvalidSwarmData();
    error FilterTooLarge();
    error SwarmAlreadyExists();
    error SwarmNotOrphaned();
    error SwarmOrphaned();

    enum SwarmStatus {
        REGISTERED,
        ACCEPTED,
        REJECTED
    }

    enum TagType {
        IBEACON_PAYLOAD_ONLY, // 0x00: proxUUID || major || minor
        IBEACON_INCLUDES_MAC, // 0x01: proxUUID || major || minor || MAC (Normalized)
        VENDOR_ID, // 0x02: companyID || hash(vendorBytes)
        GENERIC // 0x03

    }

    struct Swarm {
        bytes16 fleetUuid; // Fleet UUID (not token ID) - allows swarms for any registered UUID
        uint256 providerId;
        uint32 filterLength; // Length of filter in bytes (max ~4GB, practically limited)
        uint8 fingerprintSize;
        TagType tagType;
        SwarmStatus status;
    }

    uint8 public constant MAX_FINGERPRINT_SIZE = 16;

    /// @notice Maximum filter size per swarm (24KB - fits in ~15M gas on cold write)
    uint32 public constant MAX_FILTER_SIZE = 24576;

    FleetIdentity public immutable FLEET_CONTRACT;

    ServiceProvider public immutable PROVIDER_CONTRACT;

    /// @notice SwarmID -> Swarm metadata
    mapping(uint256 => Swarm) public swarms;

    /// @notice SwarmID -> XOR filter data (stored as bytes)
    mapping(uint256 => bytes) internal filterData;

    /// @notice UUID -> List of SwarmIDs (keyed by fleet UUID, not token ID)
    mapping(bytes16 => uint256[]) public uuidSwarms;

    /// @notice SwarmID -> index in uuidSwarms[fleetUuid] (for O(1) removal)
    mapping(uint256 => uint256) public swarmIndexInUuid;

    event SwarmRegistered(
        uint256 indexed swarmId, bytes16 indexed fleetUuid, uint256 indexed providerId, address owner, uint32 filterSize
    );

    event SwarmStatusChanged(uint256 indexed swarmId, SwarmStatus status);
    event SwarmFilterUpdated(uint256 indexed swarmId, address indexed owner, uint32 filterSize);
    event SwarmProviderUpdated(uint256 indexed swarmId, uint256 indexed oldProvider, uint256 indexed newProvider);
    event SwarmDeleted(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed owner);
    event SwarmPurged(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed purgedBy);

    /// @notice Derives a deterministic swarm ID. Callable off-chain to predict IDs before registration.
    /// @return swarmId keccak256(fleetUuid, providerId, filter)
    function computeSwarmId(bytes16 fleetUuid, uint256 providerId, bytes calldata filter) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(fleetUuid, providerId, filter)));
    }

    constructor(address _fleetContract, address _providerContract) {
        if (_fleetContract == address(0) || _providerContract == address(0)) {
            revert InvalidSwarmData();
        }
        FLEET_CONTRACT = FleetIdentity(_fleetContract);
        PROVIDER_CONTRACT = ServiceProvider(_providerContract);
    }

    /// @notice Registers a new swarm. Caller must own the fleet UUID (via FleetIdentity.uuidOwner).
    /// @param fleetUuid Fleet UUID (bytes16) - the UUID must be registered in FleetIdentity.
    /// @param providerId Service provider token ID.
    /// @param filter XOR filter blob (1–24 576 bytes).
    /// @param fingerprintSize Fingerprint width in bits (1–16).
    /// @param tagType Tag identity schema.
    /// @return swarmId Deterministic ID for this swarm.
    function registerSwarm(
        bytes16 fleetUuid,
        uint256 providerId,
        bytes calldata filter,
        uint8 fingerprintSize,
        TagType tagType
    ) external nonReentrant returns (uint256 swarmId) {
        if (fleetUuid == bytes16(0)) {
            revert InvalidUuid();
        }
        if (fingerprintSize == 0 || fingerprintSize > MAX_FINGERPRINT_SIZE) {
            revert InvalidFingerprintSize();
        }
        if (filter.length == 0) {
            revert InvalidFilterSize();
        }
        if (filter.length > MAX_FILTER_SIZE) {
            revert FilterTooLarge();
        }

        // Check UUID ownership - works for any registered UUID regardless of region
        if (FLEET_CONTRACT.uuidOwner(fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }
        if (PROVIDER_CONTRACT.ownerOf(providerId) == address(0)) {
            revert ProviderDoesNotExist();
        }

        swarmId = computeSwarmId(fleetUuid, providerId, filter);

        if (swarms[swarmId].filterLength != 0) {
            revert SwarmAlreadyExists();
        }

        Swarm storage s = swarms[swarmId];
        s.fleetUuid = fleetUuid;
        s.providerId = providerId;
        s.filterLength = uint32(filter.length);
        s.fingerprintSize = fingerprintSize;
        s.tagType = tagType;
        s.status = SwarmStatus.REGISTERED;

        filterData[swarmId] = filter;

        uuidSwarms[fleetUuid].push(swarmId);
        swarmIndexInUuid[swarmId] = uuidSwarms[fleetUuid].length - 1;

        emit SwarmRegistered(swarmId, fleetUuid, providerId, msg.sender, uint32(filter.length));
    }

    /// @notice Approves a swarm. Caller must own the provider NFT.
    /// @param swarmId The swarm to accept.
    function acceptSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) revert SwarmNotFound();

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (!fleetValid || !providerValid) revert SwarmOrphaned();

        if (PROVIDER_CONTRACT.ownerOf(s.providerId) != msg.sender) {
            revert NotProviderOwner();
        }
        s.status = SwarmStatus.ACCEPTED;
        emit SwarmStatusChanged(swarmId, SwarmStatus.ACCEPTED);
    }

    /// @notice Rejects a swarm. Caller must own the provider NFT.
    /// @param swarmId The swarm to reject.
    function rejectSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) revert SwarmNotFound();

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (!fleetValid || !providerValid) revert SwarmOrphaned();

        if (PROVIDER_CONTRACT.ownerOf(s.providerId) != msg.sender) {
            revert NotProviderOwner();
        }
        s.status = SwarmStatus.REJECTED;
        emit SwarmStatusChanged(swarmId, SwarmStatus.REJECTED);
    }

    /// @notice Replaces the XOR filter. Resets status to REGISTERED. Caller must own the fleet UUID.
    /// @param swarmId The swarm to update.
    /// @param newFilterData Replacement filter blob.
    function updateSwarmFilter(uint256 swarmId, bytes calldata newFilterData) external nonReentrant {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) {
            revert SwarmNotFound();
        }
        if (FLEET_CONTRACT.uuidOwner(s.fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }
        if (newFilterData.length == 0) {
            revert InvalidFilterSize();
        }
        if (newFilterData.length > MAX_FILTER_SIZE) {
            revert FilterTooLarge();
        }

        s.filterLength = uint32(newFilterData.length);
        s.status = SwarmStatus.REGISTERED;
        filterData[swarmId] = newFilterData;

        emit SwarmFilterUpdated(swarmId, msg.sender, uint32(newFilterData.length));
    }

    /// @notice Reassigns the service provider. Resets status to REGISTERED. Caller must own the fleet UUID.
    /// @param swarmId The swarm to update.
    /// @param newProviderId New provider token ID.
    function updateSwarmProvider(uint256 swarmId, uint256 newProviderId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) {
            revert SwarmNotFound();
        }
        if (FLEET_CONTRACT.uuidOwner(s.fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }
        if (PROVIDER_CONTRACT.ownerOf(newProviderId) == address(0)) {
            revert ProviderDoesNotExist();
        }

        uint256 oldProvider = s.providerId;

        // Effects — update provider and reset status
        s.providerId = newProviderId;
        s.status = SwarmStatus.REGISTERED;

        emit SwarmProviderUpdated(swarmId, oldProvider, newProviderId);
    }

    /// @notice Permanently deletes a swarm. Caller must own the fleet UUID.
    /// @param swarmId The swarm to delete.
    function deleteSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) {
            revert SwarmNotFound();
        }
        if (FLEET_CONTRACT.uuidOwner(s.fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }

        bytes16 fleetUuid = s.fleetUuid;

        _removeFromUuidSwarms(fleetUuid, swarmId);

        delete swarms[swarmId];
        delete filterData[swarmId];

        emit SwarmDeleted(swarmId, fleetUuid, msg.sender);
    }

    /// @notice Returns whether the swarm's fleet UUID and provider NFT are still valid.
    /// @param swarmId The swarm to check.
    /// @return fleetValid True if the fleet UUID is still owned (uuidOwner != address(0)).
    /// @return providerValid True if the provider NFT exists.
    function isSwarmValid(uint256 swarmId) public view returns (bool fleetValid, bool providerValid) {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) revert SwarmNotFound();

        // Fleet is valid if UUID is still owned (not released)
        fleetValid = FLEET_CONTRACT.uuidOwner(s.fleetUuid) != address(0);

        try PROVIDER_CONTRACT.ownerOf(s.providerId) returns (address) {
            providerValid = true;
        } catch {
            providerValid = false;
        }
    }

    /// @notice Permissionless-ly removes a swarm whose fleet UUID has been released or provider NFT has been burned.
    /// @param swarmId The orphaned swarm to purge.
    function purgeOrphanedSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) revert SwarmNotFound();

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (fleetValid && providerValid) revert SwarmNotOrphaned();

        bytes16 fleetUuid = s.fleetUuid;

        _removeFromUuidSwarms(fleetUuid, swarmId);

        delete swarms[swarmId];
        delete filterData[swarmId];

        emit SwarmPurged(swarmId, fleetUuid, msg.sender);
    }

    /// @notice Tests tag membership against the swarm's XOR filter.
    /// @param swarmId The swarm to query.
    /// @param tagHash keccak256 of the tag identity bytes (caller must pre-normalize per tagType).
    /// @return isValid True if the tag passes the XOR filter check.
    function checkMembership(uint256 swarmId, bytes32 tagHash) external view returns (bool isValid) {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) {
            revert SwarmNotFound();
        }

        // Reject queries against orphaned swarms
        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (!fleetValid || !providerValid) revert SwarmOrphaned();

        bytes storage filter = filterData[swarmId];
        uint256 dataLen = s.filterLength;

        // Calculate M (number of fingerprint slots)
        uint256 m = (dataLen * 8) / s.fingerprintSize;
        if (m == 0) return false;

        // Derive 3 indices and expected fingerprint from hash
        uint32 h1 = uint32(uint256(tagHash)) % uint32(m);
        uint32 h2 = uint32(uint256(tagHash) >> 32) % uint32(m);
        uint32 h3 = uint32(uint256(tagHash) >> 64) % uint32(m);

        uint256 fpMask = (uint256(1) << s.fingerprintSize) - 1;
        uint256 expectedFp = (uint256(tagHash) >> 96) & fpMask;

        // Read and XOR fingerprints
        uint256 f1 = _readFingerprint(filter, h1, s.fingerprintSize);
        uint256 f2 = _readFingerprint(filter, h2, s.fingerprintSize);
        uint256 f3 = _readFingerprint(filter, h3, s.fingerprintSize);

        return (f1 ^ f2 ^ f3) == expectedFp;
    }

    /// @notice Returns the raw XOR filter bytes for a swarm.
    /// @param swarmId The swarm to query.
    /// @return filter The XOR filter blob.
    function getFilterData(uint256 swarmId) external view returns (bytes memory filter) {
        if (swarms[swarmId].filterLength == 0) {
            revert SwarmNotFound();
        }
        return filterData[swarmId];
    }

    /**
     * @dev O(1) removal of a swarm from its UUID's swarm list using index tracking.
     */
    function _removeFromUuidSwarms(bytes16 fleetUuid, uint256 swarmId) internal {
        uint256[] storage arr = uuidSwarms[fleetUuid];
        uint256 index = swarmIndexInUuid[swarmId];
        uint256 lastId = arr[arr.length - 1];

        arr[index] = lastId;
        swarmIndexInUuid[lastId] = index;
        arr.pop();
        delete swarmIndexInUuid[swarmId];
    }

    /**
     * @dev Reads a packed fingerprint from storage bytes.
     * @param filter The filter bytes in storage.
     * @param index The fingerprint slot index.
     * @param bits The fingerprint size in bits.
     */
    function _readFingerprint(bytes storage filter, uint256 index, uint8 bits) internal view returns (uint256) {
        uint256 bitOffset = index * bits;
        uint256 startByte = bitOffset / 8;
        uint256 endByte = (bitOffset + bits - 1) / 8;

        // Read bytes and assemble into uint256
        uint256 raw;
        for (uint256 i = startByte; i <= endByte;) {
            raw = (raw << 8) | uint8(filter[i]);
            unchecked {
                ++i;
            }
        }

        // Extract the fingerprint bits
        uint256 totalBitsRead = (endByte - startByte + 1) * 8;
        uint256 localStart = bitOffset % 8;
        uint256 shiftRight = totalBitsRead - (localStart + bits);

        return (raw >> shiftRight) & ((uint256(1) << bits) - 1);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {IFleetIdentity} from "./IFleetIdentity.sol";
import {IServiceProvider} from "./IServiceProvider.sol";
import {SwarmStatus, TagType, FingerprintSize} from "./SwarmTypes.sol";

/**
 * @title ISwarmRegistry
 * @notice Interface for SwarmRegistry — a permissionless BLE swarm registry.
 * @dev This interface defines the public contract surface that all SwarmRegistry
 *      implementations must uphold across upgrades (UUPS pattern).
 *
 *      There are two implementations:
 *      - SwarmRegistryL1Upgradeable: Uses SSTORE2 for filter storage (L1 only, not ZkSync compatible)
 *      - SwarmRegistryUniversalUpgradeable: Uses native bytes storage (cross-chain compatible)
 *
 *      Both implementations share the same public interface defined here.
 *      The `swarms()` mapping getter returns implementation-specific struct layouts
 *      and is NOT included in this interface.
 */
interface ISwarmRegistry {
    // ══════════════════════════════════════════════
    // Events
    // ══════════════════════════════════════════════

    /// @notice Emitted when a new swarm is registered.
    /// @param swarmId The unique swarm identifier.
    /// @param fleetUuid The fleet UUID this swarm belongs to.
    /// @param providerId The service provider NFT ID.
    /// @param owner The address that registered the swarm.
    /// @dev Note: SwarmRegistryUniversal also emits filterSize as a 4th non-indexed param.
    event SwarmRegistered(uint256 indexed swarmId, bytes16 indexed fleetUuid, uint256 indexed providerId, address owner);

    /// @notice Emitted when a swarm's status changes.
    /// @param swarmId The swarm identifier.
    /// @param status The new status (REGISTERED, ACCEPTED, REJECTED).
    event SwarmStatusChanged(uint256 indexed swarmId, SwarmStatus status);

    /// @notice Emitted when a swarm's provider is updated.
    /// @param swarmId The swarm identifier.
    /// @param oldProvider The previous provider ID.
    /// @param newProvider The new provider ID.
    event SwarmProviderUpdated(uint256 indexed swarmId, uint256 indexed oldProvider, uint256 indexed newProvider);

    /// @notice Emitted when a swarm is deleted by its owner.
    /// @param swarmId The deleted swarm identifier.
    /// @param fleetUuid The fleet UUID the swarm belonged to.
    /// @param owner The address that deleted the swarm.
    event SwarmDeleted(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed owner);

    /// @notice Emitted when an orphaned swarm is purged.
    /// @param swarmId The purged swarm identifier.
    /// @param fleetUuid The fleet UUID the swarm belonged to.
    /// @param purgedBy The address that called purge.
    event SwarmPurged(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed purgedBy);

    // ══════════════════════════════════════════════
    // Pure Functions
    // ══════════════════════════════════════════════

    /// @notice Derives a deterministic swarm ID.
    /// @param fleetUuid The fleet UUID.
    /// @param filter The XOR filter data.
    /// @param fpSize Fingerprint size (BITS_8 or BITS_16).
    /// @param tagType The tag type classification.
    /// @return The computed swarm ID.
    function computeSwarmId(bytes16 fleetUuid, bytes calldata filter, FingerprintSize fpSize, TagType tagType)
        external
        pure
        returns (uint256);

    // ══════════════════════════════════════════════
    // Core Functions
    // ══════════════════════════════════════════════

    /// @notice Registers a new swarm. Caller must own the fleet UUID.
    /// @param fleetUuid The fleet UUID (must be owned by caller).
    /// @param providerId The service provider NFT ID.
    /// @param filter The XOR filter data.
    /// @param fpSize Fingerprint size (BITS_8 or BITS_16).
    /// @param tagType The tag type for this swarm.
    /// @return swarmId The registered swarm's unique identifier.
    function registerSwarm(
        bytes16 fleetUuid,
        uint256 providerId,
        bytes calldata filter,
        FingerprintSize fpSize,
        TagType tagType
    ) external returns (uint256 swarmId);

    /// @notice Approves a swarm. Caller must own the provider NFT.
    /// @param swarmId The swarm to accept.
    function acceptSwarm(uint256 swarmId) external;

    /// @notice Rejects a swarm. Caller must own the provider NFT.
    /// @param swarmId The swarm to reject.
    function rejectSwarm(uint256 swarmId) external;

    /// @notice Reassigns the service provider. Resets status to REGISTERED.
    /// @param swarmId The swarm to update.
    /// @param newProviderId The new service provider NFT ID.
    function updateSwarmProvider(uint256 swarmId, uint256 newProviderId) external;

    /// @notice Permanently deletes a swarm. Caller must own the fleet UUID.
    /// @param swarmId The swarm to delete.
    function deleteSwarm(uint256 swarmId) external;

    /// @notice Permissionless-ly removes an orphaned swarm.
    /// @dev A swarm is orphaned if its fleet UUID or provider NFT no longer exists.
    /// @param swarmId The orphaned swarm to purge.
    function purgeOrphanedSwarm(uint256 swarmId) external;

    // ══════════════════════════════════════════════
    // View Functions
    // ══════════════════════════════════════════════

    /// @notice Returns the FleetIdentity contract address.
    function FLEET_CONTRACT() external view returns (IFleetIdentity);

    /// @notice Returns the ServiceProvider contract address.
    function PROVIDER_CONTRACT() external view returns (IServiceProvider);

    /// @notice Returns whether the swarm's fleet UUID and provider NFT are still valid.
    /// @param swarmId The swarm to check.
    /// @return fleetValid True if the fleet UUID owner exists.
    /// @return providerValid True if the provider NFT exists.
    function isSwarmValid(uint256 swarmId) external view returns (bool fleetValid, bool providerValid);

    /// @notice Returns the raw XOR filter bytes for a swarm.
    /// @param swarmId The swarm to query.
    /// @return The filter data bytes.
    function getFilterData(uint256 swarmId) external view returns (bytes memory);

    /// @notice Tests tag membership against the swarm's XOR filter.
    /// @param swarmId The swarm to query.
    /// @param tagHash The keccak256 hash of the tag to test.
    /// @return isValid True if the tag is probably a member of the filter.
    function checkMembership(uint256 swarmId, bytes32 tagHash) external view returns (bool isValid);

    /// @notice UUID -> List of SwarmIDs at a given index.
    /// @param fleetUuid The fleet UUID.
    /// @param index The array index.
    /// @return The swarm ID at that index.
    function uuidSwarms(bytes16 fleetUuid, uint256 index) external view returns (uint256);

    /// @notice SwarmID -> index in uuidSwarms[fleetUuid] (for O(1) removal).
    /// @param swarmId The swarm ID.
    /// @return The index in the UUID's swarm array.
    function swarmIndexInUuid(uint256 swarmId) external view returns (uint256);

    /// @notice Returns true if a fleet-wide (UUID_ONLY) swarm is registered for this UUID.
    /// @param fleetUuid The fleet UUID.
    /// @return True if a fleet-wide swarm exists.
    function hasFleetWideSwarm(bytes16 fleetUuid) external view returns (bool);
}

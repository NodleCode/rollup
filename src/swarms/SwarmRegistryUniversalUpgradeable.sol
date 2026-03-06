// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

// Import interfaces only - the registry stores proxy addresses
interface IFleetIdentity {
    function uuidOwner(bytes16 uuid) external view returns (address);
}

interface IServiceProvider {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title SwarmRegistryUniversalUpgradeable
 * @notice UUPS-upgradeable permissionless BLE swarm registry compatible with all EVM chains (including ZkSync Era).
 * @dev Uses native `bytes` storage for cross-chain compatibility.
 *
 *      **Upgrade Pattern:**
 *      - Uses OpenZeppelin UUPS proxy pattern for upgradeability.
 *      - Only the contract owner can authorize upgrades.
 *      - Storage layout must be preserved across upgrades (append-only).
 *
 *      **Important:** The FleetIdentity and ServiceProvider addresses should point to
 *      **proxy addresses** (stable), not implementation addresses.
 *
 *      **Storage Migration Example (V1 → V2):**
 *      ```solidity
 *      function initializeV2(uint256 newParam) external reinitializer(2) {
 *          _newParamIntroducedInV2 = newParam;
 *      }
 *      ```
 */
contract SwarmRegistryUniversalUpgradeable is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────
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

    // ──────────────────────────────────────────────
    // Enums & Structs
    // ──────────────────────────────────────────────
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

    /// @notice Fingerprint size for XOR filter (8-bit or 16-bit only for gas efficiency)
    enum FingerprintSize {
        BITS_8, // 8-bit fingerprints (1 byte each)
        BITS_16 // 16-bit fingerprints (2 bytes each)
    }

    struct Swarm {
        bytes16 fleetUuid;
        uint256 providerId;
        uint32 filterLength;
        FingerprintSize fpSize;
        TagType tagType;
        SwarmStatus status;
    }

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @notice Maximum filter size per swarm (24KB)
    uint32 public constant MAX_FILTER_SIZE = 24576;

    // ──────────────────────────────────────────────
    // Storage (V1) - Order matters for upgrades!
    // ──────────────────────────────────────────────

    /// @notice The FleetIdentity contract (proxy address).
    /// @dev In non-upgradeable version this was immutable.
    IFleetIdentity private _fleetContract;

    /// @notice The ServiceProvider contract (proxy address).
    /// @dev In non-upgradeable version this was immutable.
    IServiceProvider private _providerContract;

    /// @notice SwarmID -> Swarm metadata
    mapping(uint256 => Swarm) public swarms;

    /// @notice SwarmID -> XOR filter data (stored as bytes)
    mapping(uint256 => bytes) internal filterData;

    /// @notice UUID -> List of SwarmIDs
    mapping(bytes16 => uint256[]) public uuidSwarms;

    /// @notice SwarmID -> index in uuidSwarms[fleetUuid] (for O(1) removal)
    mapping(uint256 => uint256) public swarmIndexInUuid;

    // ──────────────────────────────────────────────
    // Storage Gap (for future upgrades)
    // ──────────────────────────────────────────────

    /// @dev Reserved storage slots for future upgrades.
    // solhint-disable-next-line var-name-mixedcase
    uint256[44] private __gap;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────
    event SwarmRegistered(
        uint256 indexed swarmId, bytes16 indexed fleetUuid, uint256 indexed providerId, address owner, uint32 filterSize
    );
    event SwarmStatusChanged(uint256 indexed swarmId, SwarmStatus status);
    event SwarmProviderUpdated(uint256 indexed swarmId, uint256 indexed oldProvider, uint256 indexed newProvider);
    event SwarmDeleted(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed owner);
    event SwarmPurged(uint256 indexed swarmId, bytes16 indexed fleetUuid, address indexed purgedBy);

    // ──────────────────────────────────────────────
    // Constructor (disables initializers on implementation)
    // ──────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────
    // Initializer
    // ──────────────────────────────────────────────

    /// @notice Initializes the contract. Must be called once via proxy.
    /// @param fleetContract_ Address of the FleetIdentity proxy contract.
    /// @param providerContract_ Address of the ServiceProvider proxy contract.
    /// @param owner_ The address that will own this contract and can authorize upgrades.
    function initialize(address fleetContract_, address providerContract_, address owner_) external initializer {
        if (fleetContract_ == address(0) || providerContract_ == address(0)) {
            revert InvalidSwarmData();
        }

        __Ownable_init(owner_);
        __Ownable2Step_init();

        _fleetContract = IFleetIdentity(fleetContract_);
        _providerContract = IServiceProvider(providerContract_);
    }

    // ──────────────────────────────────────────────
    // Public Getters for former immutables
    // ──────────────────────────────────────────────

    /// @notice Returns the FleetIdentity contract address.
    function FLEET_CONTRACT() external view returns (IFleetIdentity) {
        return _fleetContract;
    }

    /// @notice Returns the ServiceProvider contract address.
    function PROVIDER_CONTRACT() external view returns (IServiceProvider) {
        return _providerContract;
    }

    // ──────────────────────────────────────────────
    // Pure Functions
    // ──────────────────────────────────────────────

    /// @notice Derives a deterministic swarm ID.
    function computeSwarmId(bytes16 fleetUuid, bytes calldata filter, FingerprintSize fpSize, TagType tagType)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(fleetUuid, filter, fpSize, tagType)));
    }

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    /// @notice Registers a new swarm. Caller must own the fleet UUID.
    /// @param fleetUuid The fleet UUID (must be owned by caller)
    /// @param providerId The service provider NFT ID
    /// @param filter The XOR filter data
    /// @param fpSize Fingerprint size (BITS_8 or BITS_16)
    /// @param tagType The tag type for this swarm
    function registerSwarm(
        bytes16 fleetUuid,
        uint256 providerId,
        bytes calldata filter,
        FingerprintSize fpSize,
        TagType tagType
    ) external nonReentrant returns (uint256 swarmId) {
        if (fleetUuid == bytes16(0)) {
            revert InvalidUuid();
        }
        if (filter.length == 0) {
            revert InvalidFilterSize();
        }
        if (filter.length > MAX_FILTER_SIZE) {
            revert FilterTooLarge();
        }

        if (_fleetContract.uuidOwner(fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }
        try _providerContract.ownerOf(providerId) returns (address) {}
        catch {
            revert ProviderDoesNotExist();
        }

        swarmId = computeSwarmId(fleetUuid, filter, fpSize, tagType);

        if (swarms[swarmId].filterLength != 0) {
            revert SwarmAlreadyExists();
        }

        Swarm storage s = swarms[swarmId];
        s.fleetUuid = fleetUuid;
        s.providerId = providerId;
        s.filterLength = uint32(filter.length);
        s.fpSize = fpSize;
        s.tagType = tagType;
        s.status = SwarmStatus.REGISTERED;

        filterData[swarmId] = filter;

        uuidSwarms[fleetUuid].push(swarmId);
        swarmIndexInUuid[swarmId] = uuidSwarms[fleetUuid].length - 1;

        emit SwarmRegistered(swarmId, fleetUuid, providerId, msg.sender, uint32(filter.length));
    }

    /// @notice Approves a swarm. Caller must own the provider NFT.
    function acceptSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) revert SwarmNotFound();

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (!fleetValid || !providerValid) revert SwarmOrphaned();

        if (_providerContract.ownerOf(s.providerId) != msg.sender) {
            revert NotProviderOwner();
        }
        s.status = SwarmStatus.ACCEPTED;
        emit SwarmStatusChanged(swarmId, SwarmStatus.ACCEPTED);
    }

    /// @notice Rejects a swarm. Caller must own the provider NFT.
    function rejectSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) revert SwarmNotFound();

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (!fleetValid || !providerValid) revert SwarmOrphaned();

        if (_providerContract.ownerOf(s.providerId) != msg.sender) {
            revert NotProviderOwner();
        }
        s.status = SwarmStatus.REJECTED;
        emit SwarmStatusChanged(swarmId, SwarmStatus.REJECTED);
    }

    /// @notice Reassigns the service provider. Resets status to REGISTERED.
    function updateSwarmProvider(uint256 swarmId, uint256 newProviderId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) {
            revert SwarmNotFound();
        }
        if (_fleetContract.uuidOwner(s.fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }
        try _providerContract.ownerOf(newProviderId) returns (address) {}
        catch {
            revert ProviderDoesNotExist();
        }

        uint256 oldProvider = s.providerId;

        s.providerId = newProviderId;
        s.status = SwarmStatus.REGISTERED;

        emit SwarmProviderUpdated(swarmId, oldProvider, newProviderId);
    }

    /// @notice Permanently deletes a swarm. Caller must own the fleet UUID.
    function deleteSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) {
            revert SwarmNotFound();
        }
        if (_fleetContract.uuidOwner(s.fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }

        bytes16 fleetUuid = s.fleetUuid;

        _removeFromUuidSwarms(fleetUuid, swarmId);

        delete swarms[swarmId];
        delete filterData[swarmId];

        emit SwarmDeleted(swarmId, fleetUuid, msg.sender);
    }

    /// @notice Returns whether the swarm's fleet UUID and provider NFT are still valid.
    function isSwarmValid(uint256 swarmId) public view returns (bool fleetValid, bool providerValid) {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) revert SwarmNotFound();

        fleetValid = _fleetContract.uuidOwner(s.fleetUuid) != address(0);

        try _providerContract.ownerOf(s.providerId) returns (address) {
            providerValid = true;
        } catch {
            providerValid = false;
        }
    }

    /// @notice Permissionless-ly removes an orphaned swarm.
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
    function checkMembership(uint256 swarmId, bytes32 tagHash) external view returns (bool isValid) {
        Swarm storage s = swarms[swarmId];
        if (s.filterLength == 0) {
            revert SwarmNotFound();
        }

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (!fleetValid || !providerValid) revert SwarmOrphaned();

        bytes storage filter = filterData[swarmId];
        uint256 dataLen = s.filterLength;

        // For BITS_8: m = dataLen (each byte is one fingerprint)
        // For BITS_16: m = dataLen / 2 (each 2 bytes is one fingerprint)
        uint256 m = s.fpSize == FingerprintSize.BITS_8 ? dataLen : dataLen >> 1;
        if (m == 0) return false;

        uint32 h1 = uint32(uint256(tagHash)) % uint32(m);
        uint32 h2 = uint32(uint256(tagHash) >> 32) % uint32(m);
        uint32 h3 = uint32(uint256(tagHash) >> 64) % uint32(m);

        // fpMask: 0xFF for BITS_8, 0xFFFF for BITS_16
        uint256 fpMask = s.fpSize == FingerprintSize.BITS_8 ? 0xFF : 0xFFFF;
        uint256 expectedFp = (uint256(tagHash) >> 96) & fpMask;

        uint256 f1 = _readFingerprint(filter, h1, s.fpSize);
        uint256 f2 = _readFingerprint(filter, h2, s.fpSize);
        uint256 f3 = _readFingerprint(filter, h3, s.fpSize);

        return (f1 ^ f2 ^ f3) == expectedFp;
    }

    /// @notice Returns the raw XOR filter bytes for a swarm.
    function getFilterData(uint256 swarmId) external view returns (bytes memory filter) {
        if (swarms[swarmId].filterLength == 0) {
            revert SwarmNotFound();
        }
        return filterData[swarmId];
    }

    // ──────────────────────────────────────────────
    // UUPS Authorization
    // ──────────────────────────────────────────────

    /// @dev Only the owner can authorize an upgrade.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ──────────────────────────────────────────────
    // Internal Functions
    // ──────────────────────────────────────────────

    function _removeFromUuidSwarms(bytes16 fleetUuid, uint256 swarmId) internal {
        uint256[] storage arr = uuidSwarms[fleetUuid];
        uint256 index = swarmIndexInUuid[swarmId];
        uint256 lastId = arr[arr.length - 1];

        arr[index] = lastId;
        swarmIndexInUuid[lastId] = index;
        arr.pop();
        delete swarmIndexInUuid[swarmId];
    }

    /// @dev Reads a fingerprint from the filter at the given index.
    ///      Optimized for 8-bit and 16-bit fingerprints (no loops, no variable shifts).
    function _readFingerprint(bytes storage filter, uint256 index, FingerprintSize fpSize)
        internal
        view
        returns (uint256)
    {
        if (fpSize == FingerprintSize.BITS_8) {
            // 8-bit: direct byte access
            return uint256(uint8(filter[index]));
        } else {
            // 16-bit: two consecutive bytes
            uint256 byteIndex = index << 1; // index * 2
            return (uint256(uint8(filter[byteIndex])) << 8) | uint256(uint8(filter[byteIndex + 1]));
        }
    }
}

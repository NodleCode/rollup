// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

// NOTE: SSTORE2 is not compatible with ZkSync Era due to EXTCODECOPY limitation.
// For ZkSync deployment, use SwarmRegistryUniversalUpgradeable instead.
import {SSTORE2} from "solady/utils/SSTORE2.sol";
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
 * @title SwarmRegistryL1Upgradeable
 * @notice UUPS-upgradeable permissionless BLE swarm registry optimized for Ethereum L1 (uses SSTORE2 for filter storage).
 * @dev Not compatible with ZkSync Era — use SwarmRegistryUniversalUpgradeable instead.
 *
 *      **Upgrade Pattern:**
 *      - Uses OpenZeppelin UUPS proxy pattern for upgradeability.
 *      - Only the contract owner can authorize upgrades.
 *      - Storage layout must be preserved across upgrades (append-only).
 *
 *      **Important:** The FleetIdentity and ServiceProvider addresses should point to
 *      **proxy addresses** (stable), not implementation addresses.
 *
 *      **L1-Only:** This contract uses SSTORE2 which relies on EXTCODECOPY.
 *      Build/test WITHOUT --zksync flag:
 *      ```bash
 *      forge build --match-path src/swarms/SwarmRegistryL1Upgradeable.sol
 *      forge test --match-path test/SwarmRegistryL1Upgradeable.t.sol
 *      ```
 */
contract SwarmRegistryL1Upgradeable is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────
    error InvalidFingerprintSize();
    error InvalidFilterSize();
    error InvalidUuid();
    error NotUuidOwner();
    error ProviderDoesNotExist();
    error NotProviderOwner();
    error SwarmNotFound();
    error InvalidSwarmData();
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

    struct Swarm {
        bytes16 fleetUuid;
        uint256 providerId;
        address filterPointer; // SSTORE2 pointer
        uint8 fingerprintSize;
        TagType tagType;
        SwarmStatus status;
    }

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────
    uint8 public constant MAX_FINGERPRINT_SIZE = 16;

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

    /// @notice UUID -> List of SwarmIDs
    mapping(bytes16 => uint256[]) public uuidSwarms;

    /// @notice SwarmID -> index in uuidSwarms[fleetUuid] (for O(1) removal)
    mapping(uint256 => uint256) public swarmIndexInUuid;

    // ──────────────────────────────────────────────
    // Storage Gap (for future upgrades)
    // ──────────────────────────────────────────────

    /// @dev Reserved storage slots for future upgrades.
    // solhint-disable-next-line var-name-mixedcase
    uint256[45] private __gap;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────
    event SwarmRegistered(uint256 indexed swarmId, bytes16 indexed fleetUuid, uint256 indexed providerId, address owner);
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
    function computeSwarmId(bytes16 fleetUuid, bytes calldata filterData_, uint8 fingerprintSize, TagType tagType)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(fleetUuid, filterData_, fingerprintSize, tagType)));
    }

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    /// @notice Registers a new swarm. Caller must own the fleet UUID.
    function registerSwarm(
        bytes16 fleetUuid,
        uint256 providerId,
        bytes calldata filterData_,
        uint8 fingerprintSize,
        TagType tagType
    ) external nonReentrant returns (uint256 swarmId) {
        if (fleetUuid == bytes16(0)) {
            revert InvalidUuid();
        }
        if (fingerprintSize == 0 || fingerprintSize > MAX_FINGERPRINT_SIZE) {
            revert InvalidFingerprintSize();
        }
        if (filterData_.length == 0 || filterData_.length > 24576) {
            revert InvalidFilterSize();
        }

        if (_fleetContract.uuidOwner(fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }
        try _providerContract.ownerOf(providerId) returns (address) {}
        catch {
            revert ProviderDoesNotExist();
        }

        swarmId = computeSwarmId(fleetUuid, filterData_, fingerprintSize, tagType);

        if (swarms[swarmId].filterPointer != address(0)) {
            revert SwarmAlreadyExists();
        }

        Swarm storage s = swarms[swarmId];
        s.fleetUuid = fleetUuid;
        s.providerId = providerId;
        s.fingerprintSize = fingerprintSize;
        s.tagType = tagType;
        s.status = SwarmStatus.REGISTERED;

        uuidSwarms[fleetUuid].push(swarmId);
        swarmIndexInUuid[swarmId] = uuidSwarms[fleetUuid].length - 1;

        s.filterPointer = SSTORE2.write(filterData_);

        emit SwarmRegistered(swarmId, fleetUuid, providerId, msg.sender);
    }

    /// @notice Approves a swarm. Caller must own the provider NFT.
    function acceptSwarm(uint256 swarmId) external {
        Swarm storage s = swarms[swarmId];
        if (s.filterPointer == address(0)) revert SwarmNotFound();

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
        if (s.filterPointer == address(0)) revert SwarmNotFound();

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
        if (s.filterPointer == address(0)) {
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
        if (s.filterPointer == address(0)) {
            revert SwarmNotFound();
        }
        if (_fleetContract.uuidOwner(s.fleetUuid) != msg.sender) {
            revert NotUuidOwner();
        }

        bytes16 fleetUuid = s.fleetUuid;

        _removeFromUuidSwarms(fleetUuid, swarmId);

        delete swarms[swarmId];

        emit SwarmDeleted(swarmId, fleetUuid, msg.sender);
    }

    /// @notice Returns whether the swarm's fleet UUID and provider NFT are still valid.
    function isSwarmValid(uint256 swarmId) public view returns (bool fleetValid, bool providerValid) {
        Swarm storage s = swarms[swarmId];
        if (s.filterPointer == address(0)) revert SwarmNotFound();

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
        if (s.filterPointer == address(0)) revert SwarmNotFound();

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (fleetValid && providerValid) revert SwarmNotOrphaned();

        bytes16 fleetUuid = s.fleetUuid;

        _removeFromUuidSwarms(fleetUuid, swarmId);

        delete swarms[swarmId];

        emit SwarmPurged(swarmId, fleetUuid, msg.sender);
    }

    /// @notice Tests tag membership against the swarm's XOR filter.
    function checkMembership(uint256 swarmId, bytes32 tagHash) external view returns (bool isValid) {
        Swarm storage s = swarms[swarmId];
        if (s.filterPointer == address(0)) {
            revert SwarmNotFound();
        }

        (bool fleetValid, bool providerValid) = isSwarmValid(swarmId);
        if (!fleetValid || !providerValid) revert SwarmOrphaned();

        uint256 dataLen;
        address pointer = s.filterPointer;
        assembly {
            dataLen := extcodesize(pointer)
        }

        // SSTORE2 adds 1 byte overhead (0x00)
        if (dataLen > 0) {
            unchecked {
                --dataLen;
            }
        }

        uint256 m = (dataLen * 8) / s.fingerprintSize;
        if (m == 0) return false;

        bytes32 h = tagHash;

        uint32 h1 = uint32(uint256(h)) % uint32(m);
        uint32 h2 = uint32(uint256(h) >> 32) % uint32(m);
        uint32 h3 = uint32(uint256(h) >> 64) % uint32(m);

        uint256 fpMask = (uint256(1) << s.fingerprintSize) - 1;
        uint256 expectedFp = (uint256(h) >> 96) & fpMask;

        uint256 f1 = _readFingerprint(pointer, h1, s.fingerprintSize);
        uint256 f2 = _readFingerprint(pointer, h2, s.fingerprintSize);
        uint256 f3 = _readFingerprint(pointer, h3, s.fingerprintSize);

        return (f1 ^ f2 ^ f3) == expectedFp;
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

    function _readFingerprint(address pointer, uint256 index, uint8 bits) internal view returns (uint256) {
        uint256 bitOffset = index * bits;
        uint256 startByte = bitOffset / 8;
        uint256 endByte = (bitOffset + bits - 1) / 8;

        bytes memory chunk = SSTORE2.read(pointer, startByte, endByte + 1);

        uint256 raw;
        for (uint256 i = 0; i < chunk.length;) {
            raw = (raw << 8) | uint8(chunk[i]);
            unchecked {
                ++i;
            }
        }

        uint256 totalBitsRead = chunk.length * 8;
        uint256 localStart = bitOffset % 8;
        uint256 shiftRight = totalBitsRead - (localStart + bits);

        return (raw >> shiftRight) & ((uint256(1) << bits) - 1);
    }
}

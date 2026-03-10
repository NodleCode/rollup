# Data Model & Contract Interfaces

## Interface Files

Public interfaces for external integrators and cross-contract calls:

| Interface                         | Description                                                                    |
| :-------------------------------- | :----------------------------------------------------------------------------- |
| `interfaces/IFleetIdentity.sol`   | FleetIdentity public API (ERC721Enumerable)                                    |
| `interfaces/IServiceProvider.sol` | ServiceProvider public API (ERC721)                                            |
| `interfaces/ISwarmRegistry.sol`   | Common registry interface (L1 & Universal)                                     |
| `interfaces/SwarmTypes.sol`       | Shared enums: `RegistrationLevel`, `SwarmStatus`, `TagType`, `FingerprintSize` |

These interfaces define the expected API surface for UUPS upgradeable contracts.

## Contract Classes

```mermaid
classDiagram
    class FleetIdentity {
        +IERC20 BOND_TOKEN
        +uint256 BASE_BOND
        +uint256 TIER_CAPACITY = 10
        +uint256 MAX_TIERS = 24
        +uint256 COUNTRY_BOND_MULTIPLIER = 16
        +uint256 MAX_BONDED_UUID_BUNDLE_SIZE = 20
        +mapping uuidOwner : bytes16 → address
        +mapping uuidOperator : bytes16 → address
        +mapping uuidLevel : bytes16 → RegistrationLevel
        +mapping uuidTokenCount : bytes16 → uint256
        +mapping uuidTotalTierBonds : bytes16 → uint256
        +mapping regionTierCount : uint32 → uint256
        +mapping fleetTier : uint256 → uint256
        --
        +claimUuid(uuid, operator) → tokenId
        +registerFleetLocal(uuid, cc, admin, tier) → tokenId
        +registerFleetCountry(uuid, cc, tier) → tokenId
        +promote(tokenId)
        +reassignTier(tokenId, targetTier)
        +burn(tokenId)
        +setOperator(uuid, newOperator)
        +operatorOf(uuid) → address
        --
        +localInclusionHint(cc, admin) → tier, bond
        +countryInclusionHint(cc) → tier, bond
        +buildHighestBondedUuidBundle(cc, admin) → uuids[], count
        +buildCountryOnlyBundle(cc) → uuids[], count
        +getActiveCountries() → uint16[]
        +getActiveAdminAreas() → uint32[]
        +tokenUuid(tokenId) → bytes16
        +tokenRegion(tokenId) → uint32
        +computeTokenId(uuid, region) → uint256
        +tierBond(tier, isCountry) → uint256
    }

    class ServiceProvider {
        +mapping providerUrls : uint256 → string
        --
        +registerProvider(url) → tokenId
        +burn(tokenId)
    }

    class SwarmRegistry {
        +mapping swarms : uint256 → Swarm
        +mapping uuidSwarms : bytes16 → uint256[]
        +mapping swarmIndexInUuid : uint256 → uint256
        --
        +computeSwarmId(fleetUuid, filter, fpSize, tagType) → swarmId
        +registerSwarm(fleetUuid, providerId, filter, fpSize, tagType) → swarmId
        +acceptSwarm(swarmId)
        +rejectSwarm(swarmId)
        +updateSwarmProvider(swarmId, newProviderId)
        +deleteSwarm(swarmId)
        +isSwarmValid(swarmId) → fleetValid, providerValid
        +purgeOrphanedSwarm(swarmId)
        +checkMembership(swarmId, tagHash) → bool
    }
```

## Struct: Swarm

```solidity
struct Swarm {
    bytes16 fleetUuid;      // UUID that owns this swarm
    uint256 providerId;     // ServiceProvider token ID
    uint32 filterLength;    // XOR filter byte length
    uint8 fingerprintSize;  // Fingerprint bits (1-16)
    SwarmStatus status;     // Registration state
    TagType tagType;        // Tag identity scheme
}
```

## Enumerations

### SwarmStatus

| Value        | Description                |
| :----------- | :------------------------- |
| `REGISTERED` | Awaiting provider approval |
| `ACCEPTED`   | Provider approved; active  |
| `REJECTED`   | Provider rejected          |

### TagType

| Value                  | Tag Hash Format                      | UUID Encoding                      | Use Case              |
| :--------------------- | :----------------------------------- | :--------------------------------- | :-------------------- |
| `IBEACON_PAYLOAD_ONLY` | UUID ∥ Major ∥ Minor (20B)           | Proximity UUID (16B)               | iBeacon / AltBeacon   |
| `IBEACON_INCLUDES_MAC` | UUID ∥ Major ∥ Minor ∥ MAC (26B)     | Proximity UUID (16B)               | Anti-spoofing iBeacon |
| `VENDOR_ID`            | CompanyID ∥ FullVendorData           | Len ∥ CompanyID ∥ FleetID (16B)    | Manufacturer-specific |
| `EDDYSTONE_UID`        | Namespace ∥ Instance (16B)           | Namespace ∥ Instance (16B)         | Eddystone-UID         |
| `SERVICE_DATA`         | ExpandedServiceUUID128 ∥ ServiceData | Bluetooth Base UUID expanded (16B) | GATT Service Data     |

### UUID Encoding for Different BLE Tag Types

The `bytes16` UUID field stores the **fleet-level identifier** derived from BLE advertisement data. It serves two critical roles:

1. **Background scan registration**: Edge scanners (e.g. iOS, Android) must pre-register UUIDs with the OS to receive BLE advertisements while backgrounded. The UUID must be reconstructable from observed BLE data so scanners can build the correct OS-level filter.
2. **Swarm lookup scoping**: Each UUID maps to one or more swarms on-chain. Swarm resolution iterates all swarms under a UUID, so UUID specificity directly affects lookup performance.

The UUID deliberately excludes tag-specific fields (e.g. iBeacon Major/Minor, individual sensor IDs). Those fields appear only in the **tag hash** used for XOR filter membership verification.

#### UUID Design Trade-offs

Fleet owners should consider these trade-offs when encoding their UUID:

| Concern          | More specific UUID (uses more bytes)        | Less specific UUID (uses fewer bytes)                         |
| :--------------- | :------------------------------------------ | :------------------------------------------------------------ |
| **Lookup speed** | Fewer swarms per UUID → faster resolution   | Many swarms per UUID → linear search overhead                 |
| **Uniqueness**   | Low collision risk when claiming on-chain   | Higher collision risk — another owner may claim the same UUID |
| **Privacy**      | More fleet metadata publicly visible        | Less exposed, more private                                    |
| **Scan filter**  | Tighter OS-level filter → fewer false wakes | Broader filter → more false wakes                             |

**Recommendation**: Use as much of the 16-byte UUID capacity as is acceptable for public exposure. Under-utilizing the UUID is permitted but incurs the trade-offs above.

#### iBeacon / AltBeacon

For iBeacon advertisements, the UUID stores the standard **16-byte Proximity UUID** defined by Apple's iBeacon specification. Major (2B) and Minor (2B) are excluded from the UUID and used only in tag hash construction.

AltBeacon uses a structurally identical 20-byte Beacon ID (16B ID + 2B major + 2B minor) and is categorized under `IBEACON_PAYLOAD_ONLY` or `IBEACON_INCLUDES_MAC`.

```
UUID = Proximity UUID (16B)
Tag Hash = keccak256(UUID ∥ Major ∥ Minor)                // IBEACON_PAYLOAD_ONLY
Tag Hash = keccak256(UUID ∥ Major ∥ Minor ∥ NormMAC)      // IBEACON_INCLUDES_MAC
```

#### Eddystone-UID

Eddystone-UID frames broadcast a **10-byte Namespace ID** and a **6-byte Instance ID**, totaling exactly 16 bytes. Both fields are static and map directly into the UUID:

```
UUID = Namespace (10B) ∥ Instance (6B)
Tag Hash = keccak256(Namespace ∥ Instance)
```

#### Eddystone-EID (Informational — Not a Supported TagType)

Eddystone-EID broadcasts a **rotating 8-byte ephemeral identifier** derived from a static 16-byte Identity Key and a time counter. Because the EID changes periodically (configurable from seconds to hours) and the Identity Key is never transmitted over the air, edge scanners cannot filter EID beacons by fleet — all EID observations would need to be forwarded to a backend resolver. This makes EID incompatible with edge-filtered swarm membership, and it is therefore not assigned a `TagType`.

#### VENDOR_ID (Manufacturer Specific Data, AD Type 0xFF)

BLE Manufacturer Specific Data contains a **2-byte Company ID** (assigned by Bluetooth SIG) followed by vendor-defined payload. Since Company ID alone typically identifies the manufacturer — not the fleet owner — additional fleet-identifying bytes from the vendor data should be included when possible.

**UUID encoding** — length-prefixed for unambiguous decoding by scanners:

```
UUID (16 bytes):
┌───────┬───────────┬───────────────────────────────────┐
│ Len   │ CompanyID │ FleetIdentifier + zero-padding    │
│ (1B)  │ (2B, BE)  │ (13B)                             │
└───────┴───────────┴───────────────────────────────────┘

Len = total meaningful bytes after the Len byte
    = 2 (CompanyID) + N (FleetIdentifier bytes)
    Range: 2 (company-only) to 15 (2 + 13B fleet ID)
```

**Scanner decode logic:**

```
CompanyID  = UUID[1:3]
FleetIdLen = UUID[0] - 2
FleetId    = UUID[3 : 3 + FleetIdLen]
→ Register BLE filter: AD Type 0xFF, CompanyID, data prefix = FleetId
```

**Tag hash** uses the full vendor data (not truncated):

```
Tag Hash = keccak256(CompanyID ∥ FullVendorData)
```

**Examples:**

| Company       | Company ID | Fleet Identifier        | Len | UUID (hex)                            |
| :------------ | :--------- | :---------------------- | --: | :------------------------------------ |
| Estimote      | `015D`     | OrgID `AABBCCDD` (4B)   |   6 | `06 015D AABBCCDD 000000000000000000` |
| Tile          | `0113`     | (company only)          |   2 | `02 0113 00000000000000000000000000`  |
| Custom vendor | `1234`     | `0102030405060708` (8B) |  10 | `0A 1234 0102030405060708 0000000000` |

#### SERVICE_DATA (GATT Service Data, AD Types 0x16 / 0x20 / 0x21)

BLE Service Data advertisements carry a Service UUID plus associated data. The AD type determines the UUID size:

| AD Type | Service UUID Size | Example             |
| :------ | :---------------- | :------------------ |
| `0x16`  | 16-bit            | Heart Rate (0x180D) |
| `0x20`  | 32-bit            | Custom (0x12345678) |
| `0x21`  | 128-bit           | Vendor-specific     |

**UUID encoding** — canonical expansion using the Bluetooth Base UUID:

```
Bluetooth Base UUID: 00000000-0000-1000-8000-00805F9B34FB

16-bit  → 0000XXXX-0000-1000-8000-00805F9B34FB
32-bit  → XXXXXXXX-0000-1000-8000-00805F9B34FB
128-bit → stored as-is
```

The expansion is lossless and reversible: the scanner determines the original UUID size from the AD type in the BLE advertisement. No length byte is needed because the Bluetooth Base UUID suffix pattern unambiguously identifies 16-bit and 32-bit origins.

```
UUID = Expand(ServiceUUID) → bytes16
Tag Hash = keccak256(ExpandedServiceUUID128 ∥ ServiceData)
```

### RegistrationLevel

| Value         | Region Key | Description        |
| :------------ | :--------- | :----------------- |
| `None` (0)    | —          | Not registered     |
| `Owned` (1)   | 0          | Claimed, no region |
| `Local` (2)   | ≥1024      | Admin area         |
| `Country` (3) | 1-999      | Country-wide       |

## Region Key Encoding

```
Country:    regionKey = countryCode                    (1-999)
Admin Area: regionKey = (countryCode << 10) | adminCode  (≥1024)
```

**Token ID:**

```
tokenId = (regionKey << 128) | uint256(uint128(uuid))
```

**Helper functions:**

```solidity
bytes16 uuid = fleetIdentity.tokenUuid(tokenId);
uint32 region = fleetIdentity.tokenRegion(tokenId);
uint256 tokenId = fleetIdentity.computeTokenId(uuid, regionKey);
uint32 adminRegion = fleetIdentity.makeAdminRegion(countryCode, adminCode);
```

## Swarm ID Derivation

Deterministic and collision-free:

```solidity
swarmId = uint256(keccak256(abi.encode(fleetUuid, filterData, fingerprintSize, tagType)))
```

Swarm identity is based on fleet, filter, fingerprintSize, and tagType. ProviderId is mutable and not part of identity. Duplicate registration reverts with `SwarmAlreadyExists()`.

## XOR Filter Membership

3-hash XOR verification:

```
Input: h = keccak256(tagId)
M = filterLength * 8 / fingerprintSize  // slots

h1 = uint32(h) % M
h2 = uint32(h >> 32) % M
h3 = uint32(h >> 64) % M
fp = (h >> 96) & ((1 << fingerprintSize) - 1)

Valid if: Filter[h1] ^ Filter[h2] ^ Filter[h3] == fp
```

## Storage Notes

### SwarmRegistryL1

- Filter stored as **contract bytecode** via SSTORE2
- Gas-efficient reads (EXTCODECOPY)
- Bytecode persists after deletion (immutable)

### SwarmRegistryUniversal

- Filter stored in `mapping(uint256 => bytes)`
- Full deletion reclaims storage
- `getFilterData(swarmId)` for off-chain retrieval

### Deletion Performance

O(1) swap-and-pop via `swarmIndexInUuid` mapping.

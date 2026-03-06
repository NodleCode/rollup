# Data Model & Contract Interfaces

## Interface Files

Public interfaces for external integrators and cross-contract calls:

| Interface                                       | Description                                    |
| :---------------------------------------------- | :--------------------------------------------- |
| `interfaces/IFleetIdentity.sol`                 | FleetIdentity public API (ERC721Enumerable)    |
| `interfaces/IServiceProvider.sol`               | ServiceProvider public API (ERC721)            |
| `interfaces/ISwarmRegistry.sol`                 | Common registry interface (L1 & Universal)    |
| `interfaces/SwarmTypes.sol`                     | Shared enums: `RegistrationLevel`, `SwarmStatus`, `TagType`, `FingerprintSize` |

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

| Value                  | Format                           | Use Case         |
| :--------------------- | :------------------------------- | :--------------- |
| `IBEACON_PAYLOAD_ONLY` | UUID ∥ Major ∥ Minor (20B)       | Standard iBeacon |
| `IBEACON_INCLUDES_MAC` | UUID ∥ Major ∥ Minor ∥ MAC (26B) | Anti-spoofing    |
| `VENDOR_ID`            | companyID ∥ hash(vendorBytes)    | Non-iBeacon BLE  |
| `GENERIC`              | Custom                           | Extensible       |

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

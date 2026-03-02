# Client Discovery

## Overview

Clients (mobile apps, gateways) discover BLE tags and resolve them to backend services entirely on-chain.

```
BLE Signal → UUID Match → Swarm Lookup → Membership Check → Service URL
```

## Geographic Bundle Discovery (Recommended)

Use location-based priority bundles for efficient discovery.

```mermaid
sequenceDiagram
    actor Client as EdgeBeaconScanner
    participant FI as FleetIdentity
    participant SR as SwarmRegistry
    participant SP as ServiceProvider

    Note over Client: Location: US-California (840, 5)<br/>Detected: UUID, Major, Minor, MAC

    Client->>+FI: buildHighestBondedUuidBundle(840, 5)
    FI-->>-Client: (uuids[], count) — up to 20 UUIDs

    Note over Client: Check if detectedUUID in bundle

    Client->>+SR: uuidSwarms(uuid, 0)
    SR-->>-Client: swarmId
    Note over Client: Iterate until revert

    Note over Client: Build tagHash per TagType
    Client->>+SR: checkMembership(swarmId, tagHash)
    SR-->>-Client: true

    Client->>+SR: swarms(swarmId)
    SR-->>-Client: {providerId, status: ACCEPTED, ...}

    Client->>+SP: providerUrls(providerId)
    SP-->>-Client: "https://api.example.com"

    Note over Client: Connect to service
```

### Bundle Priority

1. **Tier**: Higher tier first
2. **Level**: Local before country (same tier)
3. **Time**: Earlier registration (same tier+level)

## Direct UUID Lookup

When UUID is known but location isn't:

```solidity
// Try regions
uint32 localRegion = (840 << 10) | 5;
uint256 tokenId = fleetIdentity.computeTokenId(uuid, localRegion);
try fleetIdentity.ownerOf(tokenId) { /* found */ }
catch { /* try country: computeTokenId(uuid, 840) */ }

// Enumerate swarms
for (uint i = 0; ; i++) {
    try swarmRegistry.uuidSwarms(uuid, i) returns (uint256 swarmId) {
        // process swarmId
    } catch { break; }
}
```

## Tag Hash Construction

```mermaid
flowchart TD
    A[Read swarm.tagType] --> B{TagType?}

    B -->|IBEACON_PAYLOAD_ONLY| C["UUID ∥ Major ∥ Minor (20B)"]
    B -->|IBEACON_INCLUDES_MAC| D{MAC type?}
    B -->|VENDOR_ID| E["companyID ∥ hash(vendorBytes)"]
    B -->|GENERIC| F["custom scheme"]

    D -->|Public| G["UUID ∥ Major ∥ Minor ∥ realMAC (26B)"]
    D -->|Random| H["UUID ∥ Major ∥ Minor ∥ FF:FF:FF:FF:FF:FF"]

    C --> I["tagHash = keccak256(tagId)"]
    G --> I
    H --> I
    E --> I
    F --> I

    I --> J["checkMembership(swarmId, tagHash)"]

    style I fill:#4a9eff,color:#fff
    style J fill:#2ecc71,color:#fff
```

### MAC Address Types

| Address Type Bits | MAC Type       | Action                  |
| :---------------- | :------------- | :---------------------- |
| `00`              | Public         | Use real MAC            |
| `01`, `11`        | Random/Private | Use `FF:FF:FF:FF:FF:FF` |

## Region Enumeration (Indexers)

```solidity
// Active countries
uint16[] memory countries = fleetIdentity.getActiveCountries();
// [840, 276, 392, ...]

// Active admin areas
uint32[] memory adminAreas = fleetIdentity.getActiveAdminAreas();
// [860165, 282629, ...] → (cc << 10) | admin

// Tier data
uint256 tierCount = fleetIdentity.regionTierCount(regionKey);
uint256[] memory tokenIds = fleetIdentity.getTierMembers(regionKey, tier);
bytes16[] memory uuids = fleetIdentity.getTierUuids(regionKey, tier);
```

## Complete Discovery Example

```solidity
function discoverService(
    bytes16 uuid,
    uint16 major,
    uint16 minor,
    bytes6 mac,
    uint16 countryCode,
    uint8 adminCode
) external view returns (string memory serviceUrl, bool found) {
    // 1. Check bundle
    (bytes16[] memory uuids, uint256 count) =
        fleetIdentity.buildHighestBondedUuidBundle(countryCode, adminCode);

    for (uint i = 0; i < count; i++) {
        if (uuids[i] != uuid) continue;

        // 2. Find swarms
        for (uint j = 0; ; j++) {
            uint256 swarmId;
            try swarmRegistry.uuidSwarms(uuid, j) returns (uint256 id) {
                swarmId = id;
            } catch { break; }

            // 3. Get swarm data
            (,uint256 providerId,,,SwarmStatus status, TagType tagType) =
                swarmRegistry.swarms(swarmId);

            if (status != SwarmStatus.ACCEPTED) continue;

            // 4. Build tagId
            bytes memory tagId;
            if (tagType == TagType.IBEACON_PAYLOAD_ONLY) {
                tagId = abi.encodePacked(uuid, major, minor);
            } else if (tagType == TagType.IBEACON_INCLUDES_MAC) {
                tagId = abi.encodePacked(uuid, major, minor, mac);
            }

            // 5. Check membership
            if (swarmRegistry.checkMembership(swarmId, keccak256(tagId))) {
                return (serviceProvider.providerUrls(providerId), true);
            }
        }
    }

    return ("", false);
}
```

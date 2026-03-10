# Swarm System Architecture & Implementation Guide

> **Context for AI Agents**: This document outlines the architecture, constraints, and operational logic of the Swarm Smart Contract system. Use this context when modifying contracts, writing SDKs, or debugging verifiers.

## 1. System Overview

The Swarm System is a **non-enumerating** registry for **BLE (Bluetooth Low Energy)** tag swarms. It allows Fleet Owners to manage large sets of tags (~10k-20k) and link them to Service Providers (Backend URLs) using cryptographic membership proofs—individual tags are never listed on-chain.

Two registry variants exist for different deployment targets:

- **`SwarmRegistryL1`** — Ethereum L1, uses SSTORE2 (contract bytecode) for gas-efficient filter storage. Not compatible with ZkSync Era.
- **`SwarmRegistryUniversal`** — All EVM chains including ZkSync Era, uses native `bytes` storage.

### Core Components

| Contract                     | Role                                | Key Identity                                    | Token |
| :--------------------------- | :---------------------------------- | :---------------------------------------------- | :---- |
| **`FleetIdentity`**          | Fleet Registry (ERC-721 Enumerable) | `(regionKey << 128) \| uint128(uuid)`           | SFID  |
| **`ServiceProvider`**        | Service Registry (ERC-721)          | `keccak256(url)`                                | SSV   |
| **`SwarmRegistryL1`**        | Swarm Registry (L1)                 | `keccak256(fleetUuid, filter, fpSize, tagType)` | —     |
| **`SwarmRegistryUniversal`** | Swarm Registry (Universal)          | `keccak256(fleetUuid, filter, fpSize, tagType)` | —     |

All contracts are **permissionless** — access control is enforced through NFT ownership rather than admin roles. `FleetIdentity` additionally requires an ERC-20 bond (e.g. NODL) to register a fleet, acting as an anti-spam / anti-abuse mechanism.

Both NFT contracts support **burning**. For `FleetIdentity`, owned-only tokens can be burned by the owner (refunds BASE_BOND), while registered tokens can only be burned by the operator (refunds tier bond). Burning a `ServiceProvider` token requires owner rights. Burning either NFT makes any swarms referencing that token \_orphaned\*.

### FleetIdentity: Two-Level Geographic Registration

`FleetIdentity` implements a **two-level geographic registration** system:

- **Country Level** — `regionKey = countryCode` (ISO 3166-1 numeric, 1-999)
- **Admin Area (Local) Level** — `regionKey = (countryCode << 10) | adminCode` (>= 1024)

Each region has its own independent tier namespace. The first fleet in any region always pays the level-appropriate base bond.

**TokenID Encoding:**

```
tokenId = (regionKey << 128) | uint256(uint128(uuid))
```

- Bits 0-127: UUID (Proximity UUID as bytes16)
- Bits 128-159: Region key (country or admin-area code)

This allows the same UUID to be registered in multiple regions, each with a distinct token.

### Economic Model (Tier System)

| Parameter           | Value                                                      |
| :------------------ | :--------------------------------------------------------- |
| **Tier Capacity**   | 10 members per tier                                        |
| **Max Tiers**       | 24 per region                                              |
| **Local Bond**      | `BASE_BOND * 2^tier`                                       |
| **Country Bond**    | `BASE_BOND * COUNTRY_BOND_MULTIPLIER * 2^tier` (16× local) |
| **Max Bundle Size** | 20 UUIDs                                                   |

Country fleets pay 16× more but appear in all admin-area bundles within their country. This economic difference provides locals a significant advantage: a local can reach tier 4 for the same cost a country player pays for tier 0.

### Runtime Bond Parameter Configuration

The contract owner can adjust bond parameters at runtime:

```solidity
// Update base bond for future registrations
fleetIdentity.setBaseBond(newBaseBond);

// Update country multiplier for future registrations
fleetIdentity.setCountryBondMultiplier(newMultiplier);

// Update both parameters atomically
fleetIdentity.setBondParameters(newBaseBond, newMultiplier);
```

**Tier-0 Bond Tracking:**

To ensure fair refunds when parameters change, each token stores its "tier-0 equivalent bond" at registration time:

- **For local tokens**: `tokenTier0Bond[tokenId] = baseBond`
- **For country tokens**: `tokenTier0Bond[tokenId] = baseBond * countryBondMultiplier()`
- **Bond at tier K**: `tokenTier0Bond[tokenId] << K` (bitshift = multiply by 2^K)

This simplified approach:

- Stores a single uint256 per token (not a struct)
- No need to track country/local distinction or multiplier separately
- O(1) operations for promote/demote/burn with accurate refunds

For UUID ownership bonds, `uuidOwnershipBondPaid[uuid]` tracks what was paid at claim/first-registration.

### UUID Ownership Model

UUIDs have an ownership model with registration levels:

| Level     | Value | Description                              |
| :-------- | :---- | :--------------------------------------- |
| `None`    | 0     | Not registered (default)                 |
| `Owned`   | 1     | Claimed but not registered in any region |
| `Local`   | 2     | Registered at admin area level           |
| `Country` | 3     | Registered at country level              |

- **UUID Owner**: The address that first registered a token for a UUID. All subsequent registrations must come from this address.
- **Multi-Region**: The same UUID can have multiple tokens in different regions (all at the same level, all by the same owner).
- **Transfer**: Owned-only tokens transfer `uuidOwner` when the NFT is transferred.

---

## 2. Operational Workflows

### A. Provider Setup (One-Time)

**Service Provider** calls `ServiceProvider.registerProvider("https://cms.example.com")`. Receives `providerTokenId` (= `keccak256(url)`).

### B. Fleet Registration Options

Fleet Owners have multiple paths to register fleets:

#### B1. Direct Registration (Country Level)

```solidity
// 1. Approve bond token
NODL.approve(fleetIdentityAddress, requiredBond);

// 2. Get inclusion hint (off-chain call - free)
(uint256 tier, uint256 bond) = fleetIdentity.countryInclusionHint(840); // US = 840

// 3. Register at the recommended tier
uint256 tokenId = fleetIdentity.registerFleetCountry(uuid, 840, tier);
// Returns tokenId = (840 << 128) | uint128(uuid)
```

#### B2. Direct Registration (Local/Admin Area Level)

```solidity
// 1. Approve bond token
NODL.approve(fleetIdentityAddress, requiredBond);

// 2. Get inclusion hint (off-chain call - free)
(uint256 tier, uint256 bond) = fleetIdentity.localInclusionHint(840, 5); // US, California

// 3. Register at the recommended tier
uint256 tokenId = fleetIdentity.registerFleetLocal(uuid, 840, 5, tier);
// Returns tokenId = ((840 << 10 | 5) << 128) | uint128(uuid)
```

#### B3. Claim-First Flow (Reserve UUID, Register Later)

```solidity
// 1. Claim UUID ownership (costs BASE_BOND), optionally designate operator
NODL.approve(fleetIdentityAddress, BASE_BOND);
uint256 ownedTokenId = fleetIdentity.claimUuid(uuid, operatorAddress);
// Returns tokenId = uint128(uuid) (regionKey = 0)
// If operatorAddress is address(0), caller becomes the operator

// 2. Later: Operator registers from owned state (burns owned token, mints regional token to owner)
// Operator pays tier bond only (BASE_BOND already paid by owner via claimUuid)
NODL.approve(fleetIdentityAddress, tierBond); // as operator
uint256 tokenId = fleetIdentity.registerFleetLocal(uuid, 840, 5, targetTier);
```

### C. Fleet Tier Management

Fleets can promote or demote within their region:

```solidity
// Promote to next tier (pulls additional bond)
fleetIdentity.promote(tokenId);

// Reassign to any tier (promotes or demotes)
fleetIdentity.reassignTier(tokenId, targetTier);
// If targetTier > current: pulls additional bond
// If targetTier < current: refunds bond difference
```

### D. Operator Delegation

UUID owners can delegate tier management to an operator wallet:

```solidity
// Set operator at claim time (owner pays BASE_BOND, operator manages tiers later)
uint256 ownedTokenId = fleetIdentity.claimUuid(uuid, operatorAddress);

// Or set/change operator after registration (transfers tier bonds atomically)
fleetIdentity.setOperator(uuid, operatorAddress);
// Pulls total tier bonds from new operator, refunds old operator

// Check current operator (returns owner if none set)
address manager = fleetIdentity.operatorOf(uuid);

// Clear operator (reverts to owner-managed)
fleetIdentity.setOperator(uuid, address(0));
// Pulls tier bonds from owner, refunds old operator
```

**Key Points:**

- Operator handles `promote()`, `reassignTier()`, and registration calls for owned UUIDs
- Operator can burn registered tokens (refunds tier bond to operator)
- Owner retains `setOperator()` control and can burn owned-only tokens
- `setOperator` transfers all tier bonds atomically (O(1) via `uuidTotalTierBonds`)
- Can set operator for both owned-only and registered UUIDs

### E. Burn Fleet Token

**Owned-Only Tokens (Owner Burns):**

```solidity
// Only owner can burn owned-only tokens
fleetIdentity.burn(ownedTokenId);
// Refunds BASE_BOND to owner, clears UUID ownership
```

**Registered Tokens (Operator Burns):**

```solidity
// Only operator can burn registered tokens
fleetIdentity.burn(tokenId);
// Refunds tier bond to operator
// If last token: mints owned-only token to owner (preserves ownership)
// Owner must burn owned-only token separately to fully release UUID
```

### F. Swarm Registration (Per Batch of Tags)

A Fleet Owner groups tags into a "Swarm" (chunk of ~10k-20k tags) and registers them.

1.  **Construct `TagID`s**: Generate the unique ID for every tag in the swarm (see "Tag Schemas" below).
2.  **Build XOR Filter**: Create a binary XOR filter (Peeling Algorithm) containing the hashes of all `TagID`s.
3.  **(Optional) Predict Swarm ID**: Call `computeSwarmId(fleetUuid, providerId, filterData)` off-chain to obtain the deterministic ID before submitting the transaction.
4.  **Register**:
    ```solidity
    swarmRegistry.registerSwarm(
        fleetUuid,
        providerId,
        filterData,
        16, // Fingerprint size in bits (1–16)
        TagType.IBEACON_INCLUDES_MAC // or PAYLOAD_ONLY, VENDOR_ID, EDDYSTONE_UID, SERVICE_DATA
    );
    // Returns the deterministic swarmId
    ```

### G. Swarm Approval Flow

After registration a swarm starts in `REGISTERED` status and requires provider approval:

1.  **Provider approves**: `swarmRegistry.acceptSwarm(swarmId)` → status becomes `ACCEPTED`.
2.  **Provider rejects**: `swarmRegistry.rejectSwarm(swarmId)` → status becomes `REJECTED`.

Only the owner of the provider NFT (`providerId`) can accept or reject.

### H. Swarm Updates

The fleet owner can change the service provider. This resets status to `REGISTERED`, requiring fresh provider approval:

- **Change service provider**: `swarmRegistry.updateSwarmProvider(swarmId, newProviderId)`

**Note:** The XOR filter is immutable and part of swarm identity. To change the filter, delete the swarm and create a new one.

### I. Swarm Deletion

The fleet owner can permanently remove a swarm:

```solidity
swarmRegistry.deleteSwarm(swarmId);
```

### J. Orphan Detection & Cleanup

When a fleet or provider NFT is burned, swarms referencing it become _orphaned_:

- **Check validity**: `swarmRegistry.isSwarmValid(swarmId)` returns `(fleetValid, providerValid)`.
- **Purge**: Anyone can call `swarmRegistry.purgeOrphanedSwarm(swarmId)` to remove stale state. The caller receives the SSTORE gas refund as an incentive.
- **Guards**: `acceptSwarm`, `rejectSwarm`, and `checkMembership` all revert with `SwarmOrphaned()` if the swarm's NFTs have been burned.

---

## 3. Off-Chain Logic: Filter & Tag Construction

### Tag Schemas (`TagType`)

The system supports different ways of constructing the unique `TagID` based on the hardware capabilities.

**Enum: `TagType`** (defined in `interfaces/SwarmTypes.sol`)

- **`0x00`: IBEACON_PAYLOAD_ONLY**
  - **Format**: `UUID (16b) || Major (2b) || Minor (2b)`
  - **Use Case**: When Major/Minor pairs are globally unique (standard iBeacon).
- **`0x01`: IBEACON_INCLUDES_MAC**
  - **Format**: `UUID (16b) || Major (2b) || Minor (2b) || MAC (6b)`
  - **Use Case**: Anti-spoofing logic or Shared Major/Minor fleets.
  - **CRITICAL: MAC Normalization Rule**:
    - If MAC is **Public/Static** (Address Type bits `00`): Use the **Real MAC Address**.
    - If MAC is **Random/Private** (Address Type bits `01` or `11`): Replace with `FF:FF:FF:FF:FF:FF`.
    - _Why?_ To support rotating privacy MACs while still validating "It's a privacy tag".
- **`0x02`: VENDOR_ID**
  - **UUID**: `[Len (1B)] [CompanyID (2B, BE)] [FleetIdentifier (≤13B, zero-padded)]`
  - **Tag Hash**: `keccak256(CompanyID || FullVendorData)`
  - **Use Case**: Manufacturer-specific BLE advertisements (AD Type 0xFF). Len = 2 + FleetIdLen.
- **`0x03`: EDDYSTONE_UID**
  - **UUID**: `Namespace (10B) || Instance (6B)` — exactly 16 bytes, stored directly.
  - **Tag Hash**: `keccak256(Namespace || Instance)`
  - **Use Case**: Eddystone-UID beacon frames.
- **`0x04`: SERVICE_DATA**
  - **UUID**: Service UUID expanded to 128-bit using Bluetooth Base UUID (`00000000-0000-1000-8000-00805F9B34FB`).
  - **Tag Hash**: `keccak256(ExpandedServiceUUID128 || ServiceData)`
  - **Use Case**: GATT Service Data advertisements (AD Types 0x16 / 0x20 / 0x21).

### Filter Construction (The Math)

To verify membership on-chain, the contract uses **3-hash XOR logic**.

1.  **Input**: `h = keccak256(TagID)` (where TagID is constructed via schema above).
2.  **Indices** (M = number of fingerprint slots = `filterLength * 8 / fingerprintSize`):
    - `h1 = uint32(h) % M`
    - `h2 = uint32(h >> 32) % M`
    - `h3 = uint32(h >> 64) % M`
3.  **Fingerprint**: `fp = (h >> 96) & ((1 << fingerprintSize) - 1)`
4.  **Verification**: `Filter[h1] ^ Filter[h2] ^ Filter[h3] == fp`

### Swarm ID Derivation

Swarm IDs are **deterministic** — derived from the swarm's core identity:

```
swarmId = uint256(keccak256(abi.encode(fleetUuid, filterData, fingerprintSize, tagType)))
```

Swarm identity is based on fleet, filter, fingerprintSize, and tagType. ProviderId is mutable and not part of identity. The same (UUID, filter, fpSize, tagType) tuple always produces the same ID, and duplicate registrations revert with `SwarmAlreadyExists()`. The `computeSwarmId` function is `public pure`, so it can be called off-chain at zero cost via `eth_call`.

---

## 4. Client Discovery Flow (The "EdgeBeaconScanner" Perspective)

A client (mobile phone or gateway) scans a BLE beacon and wants to find its owner and backend service.

### Discovery Option A: Geographic Bundle Discovery (Recommended)

Use the priority-ordered bundle based on EdgeBeaconScanner location.

#### Step 1: Get Priority Bundle

```solidity
// EdgeBeaconScanner knows its location: US, California (country=840, admin=5)
(bytes16[] memory uuids, uint256 count) = fleetIdentity.buildHighestBondedUuidBundle(840, 5);
// Returns up to 20 UUIDs, priority-ordered:
// 1. Higher tier first
// 2. Local (admin area) before country within same tier
// 3. Earlier registration within same tier+level
```

#### Step 2: Match Detected Beacon UUID

```solidity
bytes16 detectedUUID = ...; // From iBeacon advertisement

for (uint256 i = 0; i < count; i++) {
    if (uuids[i] == detectedUUID) {
        // Found! Now find the token ID
        // Try local region first, then country
        uint32 localRegion = (840 << 10) | 5;
        uint256 tokenId = fleetIdentity.computeTokenId(detectedUUID, localRegion);
        if (fleetIdentity.ownerOf(tokenId) exists) { ... }
        // else try country region
        uint256 tokenId = fleetIdentity.computeTokenId(detectedUUID, 840);
    }
}
```

#### Step 3: Enumerate Swarms & Check Membership

Same as Option B Steps 3-5.

### Discovery Option B: Direct Fleet Lookup

For when you know the UUID and want to find its fleet directly.

#### Step 1: Enumerate Active Regions

```solidity
// Get all countries with active fleets
uint16[] memory countries = fleetIdentity.getActiveCountries();

// Get all admin areas with active fleets
uint32[] memory adminAreas = fleetIdentity.getActiveAdminAreas();
```

#### Step 2: Find Fleet Token

```solidity
bytes16 uuid = ...; // From iBeacon

// Try each potential region (start with user's location)
uint32 region = (840 << 10) | 5; // US-CA
uint256 tokenId = fleetIdentity.computeTokenId(uuid, region);

try fleetIdentity.ownerOf(tokenId) returns (address owner) {
    // Found the fleet!
} catch {
    // Try country-level
    tokenId = fleetIdentity.computeTokenId(uuid, 840);
}
```

#### Step 3: Find Swarms

```solidity
// Enumerate swarms for this UUID
uint256[] memory swarmIds = new uint256[](100); // estimate
for (uint256 i = 0; ; i++) {
    try swarmRegistry.uuidSwarms(detectedUUID, i) returns (uint256 swarmId) {
        swarmIds[i] = swarmId;
    } catch {
        break; // End of array
    }
}
```

#### Step 4: Membership Check

```solidity
// Construct tagHash based on swarm's tagType
(bytes16 fleetUuid, uint256 providerId, uint32 filterLen, uint8 fpSize,
 TagType tagType, SwarmStatus status) = swarmRegistry.swarms(swarmId);

// Build tagId per schema (see Section 3)
bytes memory tagId;
if (tagType == TagType.IBEACON_PAYLOAD_ONLY) {
    tagId = abi.encodePacked(uuid, major, minor);
} else if (tagType == TagType.IBEACON_INCLUDES_MAC) {
    bytes6 normalizedMac = isRandomMac ? bytes6(0xFFFFFFFFFFFF) : realMac;
    tagId = abi.encodePacked(uuid, major, minor, normalizedMac);
}

bytes32 tagHash = keccak256(tagId);
bool isMember = swarmRegistry.checkMembership(swarmId, tagHash);
```

#### Step 5: Service Discovery

```solidity
if (isMember && status == SwarmStatus.ACCEPTED) {
    string memory url = serviceProvider.providerUrls(providerId);
    // Connect to url
}
```

---

## 5. Storage & Deletion Notes

### SwarmRegistryL1 (SSTORE2)

- Filter data is stored as **immutable contract bytecode** via SSTORE2.
- On `deleteSwarm` / `purgeOrphanedSwarm`, the struct is cleared but the deployed bytecode **cannot be erased** (accepted trade-off of the SSTORE2 pattern).

### SwarmRegistryUniversal (native bytes)

- Filter data is stored in a `mapping(uint256 => bytes)`.
- On `deleteSwarm` / `purgeOrphanedSwarm`, both the struct and the filter bytes are fully deleted (`delete filterData[swarmId]`), reclaiming storage.
- Exposes `getFilterData(swarmId)` for off-chain filter retrieval.

### Deletion Performance

Both registries use an **O(1) swap-and-pop** strategy for removing swarms from the `uuidSwarms` array, tracked via the `swarmIndexInUuid` mapping.

---

**Note**: This architecture ensures that an EdgeBeaconScanner can go from **Raw Signal** → **Verified Service URL** entirely on-chain (data-wise), without a centralized indexer, while privacy of the 10,000 other tags in the swarm is preserved.

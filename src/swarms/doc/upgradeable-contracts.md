# Upgradeable Swarm Contracts

This document covers the UUPS-upgradeable versions of the swarm registry contracts.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Storage Migration](#storage-migration)
4. [Deployment](#deployment)
5. [Interacting with Proxies](#interacting-with-proxies)
6. [Upgrade Process](#upgrade-process)
7. [Emergency Procedures](#emergency-procedures)
8. [Security Considerations](#security-considerations)

---

## Overview

The following contracts have been converted to UUPS-upgradeable versions:

| Contract                            | File                                               | Description                                  |
| ----------------------------------- | -------------------------------------------------- | -------------------------------------------- |
| `ServiceProviderUpgradeable`        | `src/swarms/ServiceProviderUpgradeable.sol`        | ERC721 for service endpoint URLs             |
| `FleetIdentityUpgradeable`          | `src/swarms/FleetIdentityUpgradeable.sol`          | ERC721Enumerable with tier-based bond system |
| `SwarmRegistryUniversalUpgradeable` | `src/swarms/SwarmRegistryUniversalUpgradeable.sol` | ZkSync-compatible swarm registry             |
| `SwarmRegistryL1Upgradeable`        | `src/swarms/SwarmRegistryL1Upgradeable.sol`        | L1-only registry with SSTORE2                |

---

## Architecture

### Proxy Pattern

Each contract is deployed as a pair:

- **Proxy (ERC1967Proxy)**: Immutable, stores state, forwards calls
- **Implementation**: Contains logic, can be replaced

```
┌──────────────────────────┐
│    ERC1967Proxy          │
│  ┌──────────────────┐    │
│  │ Implementation   │────┼──> FleetIdentityUpgradeable
│  │ Slot             │    │    (logic contract)
│  └──────────────────┘    │
│  ┌──────────────────┐    │
│  │ Storage          │    │    ← bondToken, baseBond,
│  │ (lives here)     │    │      fleets, bonds, etc.
│  └──────────────────┘    │
└──────────────────────────┘
```

### Storage Layout (ERC-7201)

All upgradeable contracts use namespaced storage with gaps for future expansion:

```solidity
// Storage variables (inherited from OpenZeppelin)
// + Custom storage at contract-specific slots
// + Storage gap at the end

uint256[40] private __gap;  // FleetIdentity: 40 slots
uint256[49] private __gap;  // ServiceProvider: 49 slots
uint256[44] private __gap;  // SwarmRegistryUniversal: 44 slots
uint256[45] private __gap;  // SwarmRegistryL1: 45 slots
```

**Storage Gap Cost**: The `__gap` costs **zero gas** at runtime. Uninitialized storage slots are not written to chain, and the gap is never read or written. It's purely a compile-time placeholder that reserves slot numbers for safe future upgrades.

---

## Storage Migration

### How Storage Persists Through Upgrades

When you upgrade a UUPS proxy, **only the logic contract address changes**. All storage remains in the proxy at exactly the same slots.

**Example: Adding a reputation score to ServiceProvider**

**Version 1 storage:**

```
Slot 0-10:   ERC721 state (name, symbol, balances...)
Slot 11:     Ownable state (owner)
Slot 12-14:  UUPSUpgradeable (empty, stateless)
Slot 15:     providerUrls mapping
Slot 16-64:  __gap (49 empty slots)
```

**Version 2 storage (adding 1 new mapping):**

```
Slot 0-10:   ERC721 state           ← UNCHANGED
Slot 11:     Ownable state           ← UNCHANGED
Slot 12-14:  UUPSUpgradeable         ← UNCHANGED
Slot 15:     providerUrls mapping    ← UNCHANGED
Slot 16:     providerScores mapping  ← NEW (from gap)
Slot 17-64:  __gap (48 empty slots)  ← REDUCED BY 1
```

**Key rule**: Existing slot offsets must NEVER change.

### Safe Upgrade Rules

1. ✅ **Append new variables** at the end (consume from `__gap`)
2. ✅ **Add new functions**
3. ✅ **Modify function logic**
4. ❌ **Never delete existing variables**
5. ❌ **Never reorder existing variables**
6. ❌ **Never change variable types** (e.g., `uint256` → `uint128`)
7. ❌ **Never insert variables between existing ones**

### Reinitializer Pattern for V2+

When adding new storage that needs initialization:

```solidity
// In V2 implementation
function initializeV2(uint256 newParam) external reinitializer(2) {
    _newParamIntroducedInV2 = newParam;
}
```

The `reinitializer(N)` modifier:

- Ensures this can only run once
- Must be called with N > previous version
- Prevents re-initialization attacks

### Upgrade with Reinitializer

```bash
# Generate reinitializer calldata
cast calldata "initializeV2(uint256)" 12345
# Output: 0x...

# Execute upgrade with initialization
REINIT_DATA=0x... CONTRACT_TYPE=ServiceProvider PROXY_ADDRESS=0x... \
  forge script script/UpgradeSwarm.s.sol --rpc-url $RPC_URL --broadcast
```

---

## Deployment

### Fresh Deployment

Use the deployment script:

```bash
# Set environment variables
export DEPLOYER_PRIVATE_KEY=0x...
export OWNER=0x...                    # Contract owner address
export BOND_TOKEN=0x...               # ERC20 token for bonds
export BASE_BOND=1000000000000000000  # 1 token (18 decimals)
export DEPLOY_L1_REGISTRY=false       # true for L1, false for ZkSync

# Deploy
forge script script/DeploySwarmUpgradeable.s.sol \
  --rpc-url $RPC_URL \
  --broadcast
```

The script deploys in order:

1. ServiceProviderUpgradeable + proxy
2. FleetIdentityUpgradeable + proxy
3. SwarmRegistry (L1 or Universal) + proxy

### Output

Save these addresses:

```
ServiceProvider Proxy: 0x...     ← Use this address for interactions
FleetIdentity Proxy: 0x...       ← Use this address for interactions
SwarmRegistry Proxy: 0x...       ← Use this address for interactions
```

---

## Interacting with Proxies

### Important: Always Use the Proxy Address

When interacting with upgradeable contracts, **always use the proxy address**, never the implementation address. The proxy contains all the state (storage) and forwards calls to the current implementation.

### TypeScript/Backend Integration

#### Setup with ethers.js v6

```typescript
import { ethers } from "ethers";
import { Contract, Provider, Wallet } from "ethers";

// Import ABIs from your compilation artifacts
import ServiceProviderABI from "./artifacts/ServiceProviderUpgradeable.json";
import FleetIdentityABI from "./artifacts/FleetIdentityUpgradeable.json";
import SwarmRegistryABI from "./artifacts/SwarmRegistryUniversalUpgradeable.json";

// Proxy addresses (saved from deployment)
const PROXY_ADDRESSES = {
  serviceProvider: "0x...", // From deployment output
  fleetIdentity: "0x...",
  swarmRegistry: "0x...",
};

// Setup provider
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

// Connect to contracts via proxies
const serviceProvider = new ethers.Contract(
  PROXY_ADDRESSES.serviceProvider,
  ServiceProviderABI.abi,
  wallet,
);

const fleetIdentity = new ethers.Contract(
  PROXY_ADDRESSES.fleetIdentity,
  FleetIdentityABI.abi,
  wallet,
);

const swarmRegistry = new ethers.Contract(
  PROXY_ADDRESSES.swarmRegistry,
  SwarmRegistryABI.abi,
  wallet,
);
```

#### Read-Only Operations

```typescript
// Query provider endpoint
async function getProviderUrl(tokenId: bigint): Promise<string> {
  return await serviceProvider.providerUrls(tokenId);
}

// Check fleet bond
async function getFleetBond(tokenId: bigint): Promise<bigint> {
  return await fleetIdentity.bonds(tokenId);
}

// Get swarm details
async function getSwarmInfo(swarmId: bigint) {
  const swarm = await swarmRegistry.swarms(swarmId);
  return {
    fleetUuid: swarm.fleetUuid,
    providerId: swarm.providerId,
    status: swarm.status, // 0: REGISTERED, 1: ACCEPTED, 2: REJECTED
    tagType: swarm.tagType,
  };
}

// Check tag membership
async function checkMembership(
  swarmId: bigint,
  tagHash: string,
): Promise<boolean> {
  return await swarmRegistry.checkMembership(swarmId, tagHash);
}

// Get highest bonded UUIDs for a region
async function discoverFleets(
  countryCode: number,
  adminCode: number,
): Promise<{ uuids: string[]; count: bigint }> {
  const [uuids, count] = await fleetIdentity.buildHighestBondedUuidBundle(
    countryCode,
    adminCode,
  );
  return { uuids, count };
}
```

#### Write Operations

```typescript
// Register a service provider
async function registerProvider(url: string): Promise<bigint> {
  const tx = await serviceProvider.registerProvider(url);
  const receipt = await tx.wait();

  // Extract tokenId from event
  const event = receipt.logs
    .map((log) => serviceProvider.interface.parseLog(log))
    .find((e) => e?.name === "ProviderRegistered");

  return event.args.tokenId;
}

// Claim a UUID
async function claimUuid(
  uuid: string, // bytes16 as hex string
  operator: string,
): Promise<bigint> {
  // Approve bond token first
  const bondToken = new ethers.Contract(
    await fleetIdentity.BOND_TOKEN(),
    ["function approve(address,uint256)"],
    wallet,
  );

  const baseBond = await fleetIdentity.BASE_BOND();
  await (await bondToken.approve(fleetIdentity.target, baseBond)).wait();

  // Claim UUID
  const tx = await fleetIdentity.claimUuid(uuid, operator);
  const receipt = await tx.wait();

  const event = receipt.logs
    .map((log) => fleetIdentity.interface.parseLog(log))
    .find((e) => e?.name === "UuidClaimed");

  return event.args.tokenId;
}

// Register a swarm
async function registerSwarm(
  fleetUuid: string,
  providerId: bigint,
  filterData: Uint8Array,
  fingerprintSize: number,
  tagType: number, // 0: IBEACON_PAYLOAD_ONLY, 1: IBEACON_INCLUDES_MAC, 2: VENDOR_ID, 3: EDDYSTONE_UID, 4: SERVICE_DATA
): Promise<bigint> {
  const tx = await swarmRegistry.registerSwarm(
    fleetUuid,
    providerId,
    filterData,
    fingerprintSize,
    tagType,
  );
  const receipt = await tx.wait();

  const event = receipt.logs
    .map((log) => swarmRegistry.interface.parseLog(log))
    .find((e) => e?.name === "SwarmRegistered");

  return event.args.swarmId;
}

// Accept swarm (provider)
async function acceptSwarm(swarmId: bigint): Promise<void> {
  const tx = await swarmRegistry.acceptSwarm(swarmId);
  await tx.wait();
}
```

#### Error Handling

```typescript
import { ErrorFragment } from "ethers";

try {
  await fleetIdentity.claimUuid(uuid, operator);
} catch (error: any) {
  // Parse custom errors
  if (error.data) {
    const iface = fleetIdentity.interface;
    const decodedError = iface.parseError(error.data);

    if (decodedError?.name === "UuidAlreadyOwned") {
      console.error("UUID is already claimed");
    } else if (decodedError?.name === "InvalidUUID") {
      console.error("Invalid UUID format");
    }
  }

  // Handle revert reasons
  if (error.reason) {
    console.error("Revert reason:", error.reason);
  }

  throw error;
}
```

#### Environment Configuration

```typescript
// .env
RPC_URL=https://mainnet.era.zksync.io
PRIVATE_KEY=0x...
SERVICE_PROVIDER_PROXY=0x...
FLEET_IDENTITY_PROXY=0x...
SWARM_REGISTRY_PROXY=0x...

// config.ts
export const CONTRACTS = {
  serviceProvider: process.env.SERVICE_PROVIDER_PROXY!,
  fleetIdentity: process.env.FLEET_IDENTITY_PROXY!,
  swarmRegistry: process.env.SWARM_REGISTRY_PROXY!
};
```

---

### Developer/Maintainer Tools

#### Using Cast (Foundry)

**Read Operations:**

```bash
# Set proxy addresses as environment variables
export SERVICE_PROVIDER=0x...
export FLEET_IDENTITY=0x...
export SWARM_REGISTRY=0x...
export RPC_URL=https://mainnet.era.zksync.io

# Query provider URL
cast call $SERVICE_PROVIDER "providerUrls(uint256)(string)" 12345 --rpc-url $RPC_URL

# Get fleet bond
cast call $FLEET_IDENTITY "bonds(uint256)(uint256)" 67890 --rpc-url $RPC_URL

# Get contract owner
cast call $FLEET_IDENTITY "owner()(address)" --rpc-url $RPC_URL

# Get base bond amount
cast call $FLEET_IDENTITY "BASE_BOND()(uint256)" --rpc-url $RPC_URL

# Check swarm status
cast call $SWARM_REGISTRY "swarms(uint256)" 101 --rpc-url $RPC_URL

# Check membership
cast call $SWARM_REGISTRY \
  "checkMembership(uint256,bytes32)(bool)" \
  101 \
  0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef \
  --rpc-url $RPC_URL

# Decode hex output to decimal
cast --to-dec $(cast call $FLEET_IDENTITY "BASE_BOND()(uint256)" --rpc-url $RPC_URL)
```

**Write Operations:**

```bash
# Register a provider
cast send $SERVICE_PROVIDER \
  "registerProvider(string)(uint256)" \
  "https://api.example.com" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# Approve bond token (first get bond token address)
BOND_TOKEN=$(cast call $FLEET_IDENTITY "BOND_TOKEN()(address)" --rpc-url $RPC_URL)
BASE_BOND=$(cast call $FLEET_IDENTITY "BASE_BOND()(uint256)" --rpc-url $RPC_URL)

cast send $BOND_TOKEN \
  "approve(address,uint256)" \
  $FLEET_IDENTITY \
  $BASE_BOND \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# Claim UUID
cast send $FLEET_IDENTITY \
  "claimUuid(bytes16,address)(uint256)" \
  0x12345678901234567890123456789012 \
  0x0000000000000000000000000000000000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# Accept swarm (as provider)
cast send $SWARM_REGISTRY \
  "acceptSwarm(uint256)" \
  101 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

**Get Transaction Receipt:**

```bash
# Send transaction and save hash
TX_HASH=$(cast send $SERVICE_PROVIDER \
  "registerProvider(string)" \
  "https://api.example.com" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --json | jq -r .transactionHash)

# Get receipt
cast receipt $TX_HASH --rpc-url $RPC_URL

# Parse logs
cast receipt $TX_HASH --rpc-url $RPC_URL --json | jq .logs
```

#### Using Block Explorers (Etherscan/Blockscout)

**Verifying Proxy Contracts:**

1. **Navigate to proxy address** on block explorer
2. **Read Contract tab**:

   - Shows current implementation address
   - All read functions are available
   - Use "Read as Proxy" mode to see implementation ABI

3. **Write Contract tab**:
   - Connect wallet (MetaMask, WalletConnect)
   - "Write as Proxy" mode essential for upgradeable contracts
   - All write functions visible with implementation ABI

**Common Operations via GUI:**

```
1. Register Provider:
   Contract: ServiceProvider Proxy
   Function: registerProvider
   Parameters:
     - url: "https://api.example.com"

2. Claim UUID:
   Contract: FleetIdentity Proxy
   Function: claimUuid
   Parameters:
     - uuid: 0x12345678901234567890123456789012
     - operator: 0x0000000000000000000000000000000000000000

   IMPORTANT: Approve bond token first!
   Contract: Bond Token (get address from BOND_TOKEN() view)
   Function: approve
   Parameters:
     - spender: [FleetIdentity Proxy Address]
     - amount: [Get from BASE_BOND() view]

3. Register Swarm:
   Contract: SwarmRegistry Proxy
   Function: registerSwarm
   Parameters:
     - fleetUuid: 0x12345678901234567890123456789012
     - providerId: 12345
     - filter: 0x0102030405...
     - fingerprintSize: 16
     - tagType: 0

4. Accept Swarm:
   Contract: SwarmRegistry Proxy
   Function: acceptSwarm
   Parameters:
     - swarmId: 101
```

**Checking Implementation:**

```bash
# Via cast
cast implementation $PROXY_ADDRESS --rpc-url $RPC_URL

# Or read the slot directly (EIP-1967)
cast storage $PROXY_ADDRESS \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $RPC_URL
```

**Reading Events:**

```bash
# Get all ProviderRegistered events
cast logs \
  --address $SERVICE_PROVIDER \
  "ProviderRegistered(address,string,uint256)" \
  --from-block 1000000 \
  --to-block latest \
  --rpc-url $RPC_URL

# Get specific swarm events
cast logs \
  --address $SWARM_REGISTRY \
  "SwarmRegistered(address,uint256,bytes16,uint256)" \
  --from-block 1000000 \
  --rpc-url $RPC_URL
```

#### Upgrading via Cast (Owner Only)

```bash
# Deploy new implementation
NEW_IMPL=$(forge create src/swarms/ServiceProviderUpgradeable.sol:ServiceProviderUpgradeable \
  --rpc-url $RPC_URL \
  --private-key $OWNER_KEY \
  --json | jq -r .deployedTo)

# Upgrade proxy
cast send $SERVICE_PROVIDER \
  "upgradeToAndCall(address,bytes)" \
  $NEW_IMPL \
  0x \ # ← No init code, just upgrade \
  --rpc-url $RPC_URL \
  --private-key $OWNER_KEY

# Verify implementation changed
cast implementation $SERVICE_PROVIDER --rpc-url $RPC_URL
```

---

## Upgrade Process

### Pre-Upgrade Checklist

1. **Verify storage compatibility**:

   ```bash
   forge inspect ServiceProviderUpgradeable storageLayout > v1-layout.json
   forge inspect ServiceProviderV2 storageLayout > v2-layout.json
   # Manually compare: ensure all V1 variables are in same slots in V2
   ```

2. **Run all tests**:

   ```bash
   forge test
   ```

3. **Test on fork**:
   ```bash
   forge script script/UpgradeSwarm.s.sol \
     --fork-url $RPC_URL \
     --sender $OWNER
   ```

### Execute Upgrade

```bash
# Without reinitializer
CONTRACT_TYPE=ServiceProvider PROXY_ADDRESS=0x... \
  forge script script/UpgradeSwarm.s.sol --rpc-url $RPC_URL --broadcast

# With reinitializer
REINIT_DATA=$(cast calldata "initializeV2()") \
CONTRACT_TYPE=ServiceProvider PROXY_ADDRESS=0x... \
  forge script script/UpgradeSwarm.s.sol --rpc-url $RPC_URL --broadcast
```

### Post-Upgrade Verification

```bash
# Verify implementation changed
cast implementation $PROXY_ADDRESS --rpc-url $RPC_URL

# Verify owner unchanged
cast call $PROXY_ADDRESS "owner()" --rpc-url $RPC_URL

# If V2 has version() function
cast call $PROXY_ADDRESS "version()" --rpc-url $RPC_URL

# Test a core function
cast call $PROXY_ADDRESS "totalSupply()" --rpc-url $RPC_URL
```

---

### Rollback

If a bug is found after upgrade:

1. **Deploy the previous (or fixed) implementation**:

   ```bash
   forge create ServiceProviderUpgradeable \
     --rpc-url $RPC_URL \
     --private-key $DEPLOYER_PRIVATE_KEY
   ```

2. **Upgrade proxy to point back**:

   ```bash
   # Get proxy admin (owner)
   cast call $PROXY_ADDRESS "owner()" --rpc-url $RPC_URL

   # Upgrade to previous/fixed implementation
   cast send $PROXY_ADDRESS \
     "upgradeToAndCall(address,bytes)" \
     $PREVIOUS_IMPL_ADDRESS \
     0x \
     --rpc-url $RPC_URL \
     --private-key $OWNER_PRIVATE_KEY
   ```

### Emergency Access Recovery

If owner key is compromised or lost:

**Prevention** (recommended during deployment):

```bash
# Use a multisig or Ownable2Step for ownership
# Ownable2Step is already included in all upgradeable contracts
```

**Recovery**:

1. If using `Ownable2Step`, the pending owner can accept ownership
2. If owner is a multisig, execute recovery through governance
3. If neither: contract is effectively immutable (by design)

---

## Security Considerations

### Constructor Disable

All upgradeable contracts disable their constructors:

```solidity
constructor() {
    _disableInitializers();
}
```

This prevents anyone from initializing the implementation contract directly (only proxies can be initialized).

### Authorization

- Upgrades require `onlyOwner` access via `_authorizeUpgrade()`
- Use `Ownable2Step` for safe ownership transfers
- Consider timelock governance for production upgrades

### Storage Collision Prevention

- OpenZeppelin's `Initializable` uses ERC-7201 namespaced storage
- Custom upgradeable contracts follow same pattern
- Storage gaps prevent child contract collisions
- Use `forge inspect storageLayout` to verify before upgrades

### Audit Recommendations

Before production deployment:

1. **Storage layout audit**: Verify all upgradeable contracts' storage compatibility
2. **Upgrade simulation**: Test full upgrade path on testnet
3. **Access control audit**: Verify only authorized addresses can upgrade
4. **Initialization audit**: Ensure all initializers are protected
5. **Reinitializer audit**: Verify V2+ initializers cannot be called multiple times

### Testing Checklist

- [ ] Deploy proxy + implementation V1
- [ ] Initialize V1
- [ ] Verify V1 cannot be reinitialized
- [ ] Register/use core functionality
- [ ] Deploy implementation V2
- [ ] Upgrade proxy to V2
- [ ] Verify V1 data persists
- [ ] Test V2 new functionality
- [ ] Verify only owner can upgrade
- [ ] Test ownership transfer (2-step)

---

## ZkSync Compatibility

### Universal vs L1 Registry

| Feature             | SwarmRegistryUniversalUpgradeable | SwarmRegistryL1Upgradeable   |
| :------------------ | :-------------------------------- | :--------------------------- |
| ZkSync Era          | ✅ Compatible                     | ❌ Not compatible            |
| Storage             | Native `bytes`                    | SSTORE2 (external contracts) |
| Gas efficiency (L1) | Medium                            | High                         |
| Deployment          | Standard proxy                    | Standard proxy               |

**Important**: `SwarmRegistryL1Upgradeable` uses `SSTORE2` which relies on `EXTCODECOPY` (unsupported on ZkSync). Always deploy `SwarmRegistryUniversalUpgradeable` on ZkSync Era.

### Build Commands

```bash
# ZkSync-compatible contracts
forge build --zksync

# L1-only contracts (SwarmRegistryL1)
forge build --match-path src/swarms/SwarmRegistryL1Upgradeable.sol

# Test ZkSync contracts
forge test --zksync

# Test L1-only contracts
forge test --match-path test/upgradeable/SwarmRegistryL1Upgradeable.t.sol
```

---

## Version History Example

Track versions in documentation:

| Version | Date       | Contract        | Changes                    |
| :------ | :--------- | :-------------- | :------------------------- |
| 1.0.0   | 2026-03-04 | All             | Initial UUPS deployment    |
| 1.1.0   | TBD        | ServiceProvider | Added reputation system    |
| 1.2.0   | TBD        | FleetIdentity   | Added staking requirements |

---

## References

- [OpenZeppelin UUPS Upgradeable](https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable)
- [EIP-1967: Proxy Storage Slots](https://eips.ethereum.org/EIPS/eip-1967)
- [ERC-7201: Namespaced Storage Layout](https://eips.ethereum.org/EIPS/eip-7201)
- [Foundry Book: Testing](https://book.getfoundry.sh/forge/tests)

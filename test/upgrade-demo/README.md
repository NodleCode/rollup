# Upgrade Demo

This folder contains a self-contained script demonstrating the UUPS upgrade process for the Swarm contracts on a local chain.

## Contents

| File                       | Description                                                                                    |
| -------------------------- | ---------------------------------------------------------------------------------------------- |
| `TestUpgradeOnAnvil.s.sol` | Forge script with inline V2 mocks that deploys V1, creates state, upgrades to V2, and verifies |

The V2 contracts (`FleetIdentityUpgradeableV2`, `ServiceProviderUpgradeableV2`, `SwarmRegistryL1UpgradeableV2`) are defined **inline** in the script file for simplicity. They inherit from their V1 counterparts and add a `version()` function.

## Prerequisites

1. **anvil-zksync** installed (comes with foundry-zksync)
2. Contracts compiled with optimizer enabled (see `foundry.toml`)

---

## Managing Anvil Instances

### Check if Anvil is Running

```bash
# Quick health check - returns chain ID if running
cast chain-id --rpc-url http://127.0.0.1:8545

# Check what process is using port 8545
lsof -i :8545
```

### Stop Existing Anvil

```bash
# Kill any process on port 8545
lsof -ti:8545 | xargs kill -9

# Or find and kill by process name
pkill -f anvil-zksync
pkill -f anvil
```

### Verify Node is Healthy

```bash
# Get current block number
cast block-number --rpc-url http://127.0.0.1:8545

# Get gas price (confirms RPC responding)
cast gas-price --rpc-url http://127.0.0.1:8545

# Check test account balance (should be 10000 ETH)
cast balance 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545
```

---

## Running the Upgrade Test

### Option A: L1 Mode (Ethereum Mainnet Simulation)

Use this for testing `SwarmRegistryL1Upgradeable` which uses SSTORE2.

```bash
# 1. Stop any existing anvil
lsof -ti:8545 | xargs kill -9 2>/dev/null || true

# 2. Start anvil-zksync in L1 mode
~/.foundry/bin/anvil-zksync --host 127.0.0.1 --port 8545

# 3. Verify it's running
cast chain-id --rpc-url http://127.0.0.1:8545

# 4. Run the test (in another terminal)
forge script test/upgrade-demo/TestUpgradeOnAnvil.s.sol:TestUpgradeOnAnvil \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast

# 5. Stop anvil when done
lsof -ti:8545 | xargs kill -9
```

### Option B: ZkSync Mode (ZkSync Era Simulation)

Use this for testing with full ZkSync system contracts.

```bash
# 1. Stop any existing anvil
lsof -ti:8545 | xargs kill -9 2>/dev/null || true

# 2. Start anvil-zksync with ZkSync OS enabled
~/.foundry/bin/anvil-zksync --host 127.0.0.1 --port 8545 --zksync

# 3. Verify it's running (chain ID will be 260 for ZkSync)
cast chain-id --rpc-url http://127.0.0.1:8545

# 4. Run the test with --zksync flag (in another terminal)
forge script test/upgrade-demo/TestUpgradeOnAnvil.s.sol:TestUpgradeOnAnvil \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --zksync

# 5. Stop anvil when done
lsof -ti:8545 | xargs kill -9
```

### Option C: Full L1 + L2 Mode (Bridge Testing)

Use this for testing L1↔L2 interactions (not needed for basic upgrade demo).

```bash
# Start with both L1 and ZkSync
~/.foundry/bin/anvil-zksync --host 127.0.0.1 --port 8545 --l1 --zksync
```

---

## Quick Reference

| Task              | Command                                                             |
| ----------------- | ------------------------------------------------------------------- |
| Check if running  | `cast chain-id --rpc-url http://127.0.0.1:8545`                     |
| Check port usage  | `lsof -i :8545`                                                     |
| Kill on port 8545 | `lsof -ti:8545 \| xargs kill -9`                                    |
| Kill all anvil    | `pkill -f anvil`                                                    |
| Start L1 mode     | `~/.foundry/bin/anvil-zksync --host 127.0.0.1 --port 8545`          |
| Start ZkSync mode | `~/.foundry/bin/anvil-zksync --host 127.0.0.1 --port 8545 --zksync` |
| Health check      | `cast block-number --rpc-url http://127.0.0.1:8545`                 |

---

## Expected Output

The script will:

1. **Deploy V1 contracts** - ServiceProvider, FleetIdentity, SwarmRegistryL1 (all via ERC1967 proxies)
2. **Create state** - Register a provider URL and a fleet with bond
3. **Upgrade to V2** - Deploy V2 implementations and call `upgradeToAndCall()`
4. **Verify success** - Check `version()` returns "2.0.0" and all state is preserved

```
=== PHASE 1: Deploy V1 Contracts ===
  Bond Token: 0x...
  ServiceProvider Proxy: 0x...
  FleetIdentity Proxy: 0x...
  SwarmRegistry Proxy: 0x...

=== PHASE 2: Create State ===
  Registered Provider: Token ID: ...
  Registered Fleet: Token ID: ...

=== PHASE 3: Upgrade to V2 ===
  Upgraded! (x3)

=== PHASE 4: Verify Upgrade Success ===
  ServiceProvider version: 2.0.0
  FleetIdentity version: 2.0.0
  SwarmRegistry version: 2.0.0
  Provider URL still valid: true
  Fleet bond preserved: true

  UPGRADE TEST COMPLETED SUCCESSFULLY
```

---

## Contract Size Consideration

`FleetIdentityUpgradeable` is a large contract. Ensure optimizer is enabled in `foundry.toml`:

```toml
via_ir = true
optimizer = true
optimizer_runs = 200
```

Without the optimizer, the contract exceeds the EIP-170 size limit (24,576 bytes) and cannot deploy to L1 Ethereum.

---

## Troubleshooting

| Issue                          | Cause                       | Solution                              |
| ------------------------------ | --------------------------- | ------------------------------------- |
| `failed to connect to network` | Anvil not running           | Start anvil first                     |
| `address already in use`       | Port 8545 occupied          | `lsof -ti:8545 \| xargs kill -9`      |
| `contract size limit exceeded` | Optimizer disabled          | Enable in `foundry.toml`              |
| `EXTCODECOPY not supported`    | Using L1 contract on ZkSync | Use L1 mode or SwarmRegistryUniversal |
| Script hangs                   | Previous anvil state        | Restart anvil fresh                   |

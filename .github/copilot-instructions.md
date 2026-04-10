# Solidity & ZkSync Development Standards

## Toolchain & Environment

- **Primary Tool**: `forge` (ZkSync fork). Use for compilation, testing, and generic scripting.
- **Secondary Tool**: `hardhat`. Use only when `forge` encounters compatibility issues (e.g., complex deployments, specific plugin needs).
- **Network Target**: ZkSync Era (Layer 2).
- **Solidity Version**: `^0.8.20` (or `0.8.24` if strictly supported by the zk-compiler).

## Modern Solidity Best Practices

- **Safety First**:
  - **Checks-Effects-Interactions (CEI)** pattern must be strictly followed.
  - When a contract requires an owner (e.g., admin-configurable parameters), prefer `Ownable2Step` over `Ownable`. Do **not** add ownership to contracts that don't need it — many contracts are fully permissionless by design.
  - Prefer `ReentrancyGuard` for external calls where appropriate.
- **Gas & Efficiency**:
  - Use **Custom Errors** (`error MyError();`) instead of `require` strings.
  - Use `mapping` over arrays for membership checks where possible.
  - Minimize on-chain storage; use events for off-chain indexing.

## Testing Standards

- **Framework**: Foundry (Forge).
- **Methodology**:
  - **Unit Tests**: Comprehensive coverage for all functions.
  - **Fuzz Testing**: Required for arithmetic and purely functional logic.
  - **Invariant Testing**: Define invariants for stateful system properties.
- **Naming Convention**:
  - `test_Description`
  - `testFuzz_Description`
  - `test_RevertIf_Condition`

## ZkSync Specifics

- **System Contracts**: Be aware of ZkSync system contracts (e.g., `ContractDeployer`, `L2EthToken`) when interacting with low-level features.
- **Gas Model**: Account for ZkSync's different gas metering if performing low-level optimization.
- **Compiler Differences**: Be mindful of differences between `solc` and `zksolc` (e.g., `create2` address derivation).

## L1-Only Contracts (No --zksync flag)

The following contracts use opcodes/patterns incompatible with ZkSync Era and must be built/tested **without** the `--zksync` flag:

- **SwarmRegistryL1**: Uses `SSTORE2` (relies on `EXTCODECOPY` which is unsupported on ZkSync).

For these contracts, use:

```bash
forge build --match-path src/swarms/SwarmRegistryL1.sol
forge test --match-path test/SwarmRegistryL1.t.sol
```

## ZkSync Source Code Verification

**IMPORTANT**: Do NOT use `forge script --verify` or `forge verify-contract` directly for ZkSync contracts. Both fail to achieve full verification due to path handling issues with the ZkSync block explorer verifier.

### The Problem (three broken paths)

1. `forge script --verify` sends **absolute file paths** (`/Users/me/project/src/...`) → verifier rejects.
2. `forge verify-contract` (standard JSON) sends OpenZeppelin sources containing `../` relative imports → verifier rejects "import with absolute or traversal path".
3. `forge verify-contract --flatten` or manual flattening eliminates imports but changes the source file path in the metadata hash → **"partially verified"** (metadata mismatch).

### The Solution

Use `ops/verify_zksync_contracts.py` which:

1. Generates standard JSON via `forge verify-contract --show-standard-json-input`
2. Rewrites all `../` relative imports in OpenZeppelin source content to resolved project-absolute paths (e.g., `../../utils/Foo.sol` → `lib/openzeppelin-contracts/contracts/utils/Foo.sol`)
3. Submits directly to the ZkSync verification API via HTTP

### Full vs Partial Verification

- **`bytecode_hash = "none"`** is set in `foundry.toml` (both `[profile.default]` and `[profile.zksync]`). This omits the CBOR metadata hash from bytecode. Contracts deployed with this setting achieve **full verification**.
- Contracts deployed **before** this setting was added (pre 2026-04-10) will always show "partially verified" — this is cosmetic only. The source code is correct and auditable.

### Usage

```bash
# After deployment — verify all contracts from broadcast:
python3 ops/verify_zksync_contracts.py \
  --broadcast broadcast/DeploySwarmUpgradeableZkSync.s.sol/324/run-latest.json \
  --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification

# Verify a single contract:
python3 ops/verify_zksync_contracts.py \
  --address 0x1234... \
  --contract src/swarms/FleetIdentityUpgradeable.sol:FleetIdentityUpgradeable \
  --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification

# With constructor args:
python3 ops/verify_zksync_contracts.py \
  --address 0x1234... \
  --contract lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args 0xabcdef...
```

### Adding New Contract Types

When deploying a new contract type, add its mapping to `CONTRACT_SOURCE_MAP` in `ops/verify_zksync_contracts.py` so `--broadcast` mode can auto-detect it.

### Automated (via deploy script)

`ops/deploy_swarm_contracts_zksync.sh` calls `verify_zksync_contracts.py` automatically after deployment. No manual steps needed for the standard swarm contracts.

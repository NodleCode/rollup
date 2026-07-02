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

## Hardhat-Based Deployment & Verification (Envelope Contracts)

### When to Use Hardhat Instead of Forge

Use Hardhat when a contract triggers `stack-too-deep` without `viaIR`, because:

- The ZkSync verifier with zksolc ≤1.5.1 does **not** pass `viaIR` through to solc.
- The ZkSync verifier with zksolc ≥1.5.13 passes `viaIR` but **crashes** on complex contracts ("internal error").
- Hardhat with zksolc v1.5.1 (no viaIR) is the only path that produces verifiable bytecode.

### Avoiding stack-too-deep Without viaIR

If a function has too many local variables or parameters in a single `abi.encode` call, split it:

```solidity
// BEFORE (15 params — triggers stack-too-deep without viaIR):
keccak256(abi.encode(TYPEHASH, a, b, c, d, e, f, g, h, i, j, k, l, m, n))

// AFTER (split into 8+7 — compiles without viaIR):
keccak256(abi.encodePacked(
    abi.encode(TYPEHASH, a, b, c, d, e, f, g),
    abi.encode(h, i, j, k, l, m, n)
))
```

This works because `abi.encode` pads each value to 32 bytes, so `abi.encodePacked(abi.encode(a,b), abi.encode(c,d))` produces identical output to `abi.encode(a,b,c,d)`.

### Verification for Hardhat-Compiled Contracts

The Hardhat verification plugin (`@matterlabs/hardhat-zksync-verify`) has a bug (HH700 artifact not found). Use `ops/verify_hardhat_zksync.py` instead:

1. Reads `artifacts-zk/build-info/*.json` (Hardhat's compilation output).
2. Performs BFS from the contract source to find all transitive imports.
3. Builds a **filtered** standard JSON containing only needed sources (avoids unrelated compilation errors in the verifier).
4. Submits to the ZkSync verification API and polls for result.

```bash
# Verify after Hardhat deployment:
python3 ops/verify_hardhat_zksync.py \
  --address 0xff735c70f33ca4eF1768F527B5f230b76A61A89b \
  --contract src/envelope/EnvelopeLinks.sol:EnvelopeLinks \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address)' 0xMFA 0xOwner 0xFeeToken)" \
  --address 0x5396e4F349D863C0AD577bd9E752293524460C36 \
  --contract src/paymasters/EnvelopePaymaster.sol:EnvelopePaymaster \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address)' 0xAdmin 0xWithdrawer 0xVault)"
```

### Envelope Deployment (Full Workflow)

```bash
# One-command deploy + verify:
./ops/deploy_envelope_zksync.sh mainnet

# Or verify-only (if deploy already succeeded):
./ops/deploy_envelope_zksync.sh mainnet --verify-only \
  --vault 0xVaultAddr --paymaster 0xPaymasterAddr
```

Key facts:

- Deployed via `hardhat-deploy/DeployEnvelope.ts` (auto-selects `.env-prod` on mainnet).
- `EnvelopePaymaster.envelopeLinks` is **immutable** — if vault address changes, paymaster must be redeployed.
- The `FEE_AUTHORIZATION_TYPEHASH` digest uses a split `abi.encode` (see `_feeAuthorizationDigest`) — this is intentional to avoid viaIR.

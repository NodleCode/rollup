# Solidity & ZkSync Development Standards

## Toolchain & Environment

- **Primary Tool**: `forge` (ZkSync fork). Use for compilation, testing, and generic scripting.
- **Secondary Tool**: `hardhat`. Use only when `forge` encounters compatibility issues (e.g., complex deployments, specific plugin needs).
- **Network Target**: ZkSync Era (Layer 2).
- **Solidity Version**: `^0.8.20` (or `0.8.24` if strictly supported by the zk-compiler).

## Modern Solidity Best Practices

- **Safety First**:
  - **Checks-Effects-Interactions (CEI)** pattern must be strictly followed.
  - Use `Ownable2Step` over `Ownable` for privileged access.
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

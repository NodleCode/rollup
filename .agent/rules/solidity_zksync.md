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

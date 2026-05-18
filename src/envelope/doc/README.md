# Envelope contracts

The Envelope flow on Nodle is built on top of the vendored **Peanut Protocol V4.4**
contracts. Senders deposit assets (ETH / ERC-20 / ERC-721 / ERC-1155) against a
per-link public key; recipients claim with the matching private key.

## Layout

| Contract | Source | Spec |
|---|---|---|
| `EnvelopeVault` (vault) | `src/envelope/V4/EnvelopeVault.sol` | [EnvelopeVault.md](./EnvelopeVault.md) |
| `EnvelopeBatcher` (batched deposits) | `src/envelope/V4/EnvelopeBatcher.sol` | [EnvelopeBatcher.md](./EnvelopeBatcher.md) |

Interfaces (vendored, unmodified):

| Interface | Source | Used by |
|---|---|---|
| `IEIP3009` | `src/envelope/util/IEIP3009.sol` | `EnvelopeVault` for gasless USDC-style deposits |
| `IL2ECO` | `src/envelope/util/IL2ECO.sol` | `EnvelopeVault` for rebasing-ERC20 deposits (`contractType==4`) |

## License notice

This subtree mixes licenses; the repo-root `LICENSE` (Clear BSD) doesn't apply uniformly here.

| Files | License | Notes |
|---|---|---|
| `src/envelope/V4/EnvelopeVault.sol`, `EnvelopeBatcher.sol` | **GPL-3.0-or-later** | Modified copies of upstream Peanut Protocol V4.4. Full GPL v3 text bundled at `src/envelope/V4/LICENSE-GPL`. Each file carries a top-of-file modification notice per GPL §5(a). |
| `src/envelope/util/IEIP3009.sol`, `IL2ECO.sol` | **MIT** | Vendored interfaces, unchanged from upstream |
| `test/envelope/**/*.t.sol` (files that import the vault/batcher sources) | **GPL-3.0-or-later** | Test files that `import` GPL-licensed contracts are derivative works under a strict reading of the GPL; relicensed for compliance |
| `test/envelope/mocks/**/*.sol` | **MIT / UNLICENSED** | Vendored test mocks, original SPDX retained |
| All other repo files | unchanged | Whatever they were |

The GPL is "viral" only across `import` boundaries; non-importing files in the same repository remain under their own licenses (per the OSI's "mere aggregation" interpretation).

## Naming convention

- **Source files** carry the Envelope brand (`EnvelopeVault.sol`, `EnvelopeBatcher.sol`); the audit lineage to upstream `peanutprotocol/peanut-contracts@main` is preserved via the `// Modified by Nodle` top-of-file notice, the `// @author Squirrel Labs` attribution, the bundled `LICENSE-GPL`, and the git rename history.
- **Contract symbols** (the names visible on the explorer / in the SDK / in the EIP-712 domain) use the Envelope brand: `EnvelopeVault`, `EnvelopeBatcher`. This avoids any trademark confusion with upstream Peanut Protocol brand.
- **On-chain hashed constants** (e.g. `ENVELOPE_SALT`) keep upstream values — changing them would change every signature digest and break compatibility. Those values are internal and never user-visible.

## Deployed on ZkSync Sepolia (chain 300)

| | Address |
|---|---|
| `EnvelopeVault` | [`0x5cf96a5db415801E52a63f216AEE601FAB6B8b11`](https://sepolia.explorer.zksync.io/address/0x5cf96a5db415801E52a63f216AEE601FAB6B8b11#contract) |
| `EnvelopeBatcher` | [`0xe8c0aEC0F90f99968B2bf517ECa2BBd41A4926c1`](https://sepolia.explorer.zksync.io/address/0xe8c0aEC0F90f99968B2bf517ECa2BBd41A4926c1#contract) |

## Three deposit paths

The vault itself supports three ways a sender can fund a link:

| Path | Trigger | Approval |
|---|---|---|
| **A** — ETH | `msg.value` directly into `makeDeposit` / `makeCustomDeposit` | n/a |
| **B** — EIP-3009 token (USDC-style) | `makeDepositWithAuthorization` | embedded in signature |
| **C** — anything else (ERC-20, ERC-721, ERC-1155) | `makeCustomDeposit` after `token.approve` / `setApprovalForAll` | separate approval tx |

User pays for both the approve and the deposit themselves.

## Deploy

| Script | Purpose |
|---|---|
| `hardhat-deploy/DeployEnvelope.ts` | vault + batcher |

Hardhat-zksync script. See the vault spec for env vars.

## Test coverage

| Suite | Tests |
|---|---|
| Envelope core (`test/envelope/`) | **90** (56 vendored + 11 hardening + 23 edge cases) |
| Other paymasters (unchanged) | 102 |
| Rest of repo | 747 |
| **Total** | **939** |

# Envelope (Peanut) contracts

The Envelope flow on Nodle is built on top of the vendored **Peanut Protocol V4.4**
contracts. Operators issue link-based asset transfers (ETH / ERC-20 / ERC-721 /
ERC-1155) that recipients claim with a per-link private key. A dedicated paymaster
sponsors the user-side approval txs so the UX is gasless from the holder's POV.

## Layout

| Contract | Source | Spec |
|---|---|---|
| `PeanutV4` (vault) | `src/peanut/V4/PeanutV4.4.sol` | [PeanutV4.md](./PeanutV4.md) |
| `PeanutBatcherV4` (batched deposits) | `src/peanut/V4/PeanutBatcherV4.4.sol` | [PeanutBatcherV4.md](./PeanutBatcherV4.md) |
| `EnvelopeApprovalPaymaster` (Path-C gas sponsor + operator gas pool) | `src/paymasters/EnvelopeApprovalPaymaster.sol` | [EnvelopeApprovalPaymaster.md](./EnvelopeApprovalPaymaster.md) |

Interfaces (vendored, unmodified):

| Interface | Source | Used by |
|---|---|---|
| `IEIP3009` | `src/peanut/util/IEIP3009.sol` | `PeanutV4` for gasless USDC-style deposits |
| `IL2ECO` | `src/peanut/util/IL2ECO.sol` | `PeanutV4` for rebasing-ERC20 deposits (`contractType==4`) |

## License notice

This subtree mixes licenses; the repo-root `LICENSE` (Clear BSD) doesn't apply uniformly here.

| Files | License | Notes |
|---|---|---|
| `src/peanut/V4/PeanutV4.4.sol`, `PeanutBatcherV4.4.sol` | **GPL-3.0-or-later** | Modified copies of upstream Peanut Protocol V4.4. Full GPL v3 text bundled at `src/peanut/V4/LICENSE-GPL`. Each file carries a top-of-file modification notice per GPL §5(a). |
| `src/peanut/util/IEIP3009.sol`, `IL2ECO.sol` | **MIT** | Vendored interfaces, unchanged from upstream |
| `src/paymasters/EnvelopeApprovalPaymaster.sol` | **BSD-3-Clause-Clear** | Our own code; doesn't `import` any GPL source so it isn't a derivative work |
| `test/peanut/**/*.t.sol` (files that import Peanut sources) | **GPL-3.0-or-later** | Test files that `import` GPL-licensed contracts are derivative works under a strict reading of the GPL; relicensed for compliance |
| `test/peanut/mocks/**/*.sol` | **MIT / UNLICENSED** | Vendored test mocks, original SPDX retained |
| All other repo files | unchanged | Whatever they were |

The GPL is "viral" only across `import` boundaries; non-importing files in the same repository remain under their own licenses (per the OSI's "mere aggregation" interpretation).

## Naming convention

- **Peanut** — the vendored open-source primitive (`peanutprotocol/peanut-contracts@main`). The vault and batcher keep upstream names so audits + diffs against upstream stay easy.
- **Envelope** — Nodle's product wrapper on top. The paymaster is named for this layer (operates against the Peanut vault, sponsored on Nodle's terms).

## Deployed on ZkSync Sepolia (chain 300)

| | Address |
|---|---|
| `PeanutV4` | [`0xC241FE8Af12Cf35Eb346eA8eC3AECFCF6F6c2C44`](https://sepolia.explorer.zksync.io/address/0xC241FE8Af12Cf35Eb346eA8eC3AECFCF6F6c2C44#contract) |
| `PeanutBatcherV4` | [`0x1676cD8B90e2E4388C032ae5Eb4BA50166Bb3426`](https://sepolia.explorer.zksync.io/address/0x1676cD8B90e2E4388C032ae5Eb4BA50166Bb3426#contract) |
| `EnvelopeApprovalPaymaster` | [`0x80EA078d599Bc63BB921Cf96CC6861731446e268`](https://sepolia.explorer.zksync.io/address/0x80EA078d599Bc63BB921Cf96CC6861731446e268#contract) |

## Three deposit paths

The vault itself supports three ways a sender can fund a link:

| Path | Trigger | Approval | Gas sponsor needed |
|---|---|---|---|
| **A** — ETH | `msg.value` directly | n/a | no |
| **B** — EIP-2612 / EIP-3009 token | `makeDepositWithAuthorization` (EIP-3009) | embedded in signature | no |
| **C** — anything else (ERC-20 w/o permit, ERC-721, ERC-1155) | `makeCustomDeposit` after user calls `token.approve` / `setApprovalForAll` | separate approval tx | **yes** — see [EnvelopeApprovalPaymaster](./EnvelopeApprovalPaymaster.md) |

## Deploy

| Script | Purpose |
|---|---|
| `hardhat-deploy/DeployPeanut.ts` | vault + batcher |
| `hardhat-deploy/DeployEnvelopePaymaster.ts` | paymaster |

Both are Hardhat-zksync scripts. See each spec for env vars.

## Test coverage

| Suite | Tests |
|---|---|
| Peanut core (`test/peanut/`) | **90** (56 vendored + 11 hardening + 23 edge cases) |
| `EnvelopeApprovalPaymaster` (`test/paymasters/EnvelopeApprovalPaymaster.t.sol`) | **27** (19 Mode A + 7 Mode B + 1 EIP-1271 contract signer) |
| Other paymasters (unchanged) | 102 |
| Rest of repo | 747 |
| **Total** | **966** |

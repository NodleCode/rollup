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
| `PeanutV4Router` (cross-chain via Squid) | `src/peanut/V4/PeanutRouter.sol` | [PeanutRouter.md](./PeanutRouter.md) |
| `EnvelopeApprovalPaymaster` (Path-C gas sponsor + operator gas pool) | `src/paymasters/EnvelopeApprovalPaymaster.sol` | [EnvelopeApprovalPaymaster.md](./EnvelopeApprovalPaymaster.md) |

Interfaces (vendored, unmodified):

| Interface | Source | Used by |
|---|---|---|
| `IEIP3009` | `src/peanut/util/IEIP3009.sol` | `PeanutV4` for gasless USDC-style deposits |
| `IL2ECO` | `src/peanut/util/IL2ECO.sol` | `PeanutV4` for rebasing-ERC20 deposits (`contractType==4`) |

## Naming convention

- **Peanut** — the vendored open-source primitive (`peanutprotocol/peanut-contracts@main`). The vault, batcher, and router keep upstream names so audits + diffs against upstream stay easy.
- **Envelope** — Nodle's product wrapper on top. The paymaster is named for this layer (operates against the Peanut vault, sponsored on Nodle's terms).

## Deployed on ZkSync Sepolia (chain 300)

| | Address |
|---|---|
| `PeanutV4` | [`0xC241FE8Af12Cf35Eb346eA8eC3AECFCF6F6c2C44`](https://sepolia.explorer.zksync.io/address/0xC241FE8Af12Cf35Eb346eA8eC3AECFCF6F6c2C44#contract) |
| `PeanutBatcherV4` | [`0x1676cD8B90e2E4388C032ae5Eb4BA50166Bb3426`](https://sepolia.explorer.zksync.io/address/0x1676cD8B90e2E4388C032ae5Eb4BA50166Bb3426#contract) |
| `EnvelopeApprovalPaymaster` | [`0x80EA078d599Bc63BB921Cf96CC6861731446e268`](https://sepolia.explorer.zksync.io/address/0x80EA078d599Bc63BB921Cf96CC6861731446e268#contract) |
| `PeanutV4Router` | not deployed (deploy when cross-chain is needed) |

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
| `hardhat-deploy/DeployPeanut.ts` | vault + batcher (+ optional router) |
| `hardhat-deploy/DeployEnvelopePaymaster.ts` | paymaster |

Both are Hardhat-zksync scripts. See each spec for env vars.

## Test coverage

| Suite | Tests |
|---|---|
| Peanut core (`test/peanut/`) | **96** (60 vendored + 13 hardening + 23 edge cases) |
| `EnvelopeApprovalPaymaster` (`test/paymasters/EnvelopeApprovalPaymaster.t.sol`) | **27** (19 Mode A + 7 Mode B + 1 EIP-1271 contract signer) |
| Other paymasters (unchanged) | 102 |
| Rest of repo | 747 |
| **Total** | **972** |

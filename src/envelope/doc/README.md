# Envelope contracts

The Envelope flow on Nodle is built on top of modified Peanut Protocol V4.4 contracts. Senders deposit assets against a per-link public key; recipients claim with the matching private key. Nodle-specific additions include address-bound links, backend MFA, deposit-time service fees, and ZkSync paymaster support for prepaid gasless claims and reclaims.

## Layout

| Contract | Source | Spec |
|---|---|---|
| `EnvelopeVault` | `src/envelope/V4/EnvelopeVault.sol` | [EnvelopeVault.md](./EnvelopeVault.md) |
| `EnvelopeBatcher` | `src/envelope/V4/EnvelopeBatcher.sol` | [EnvelopeBatcher.md](./EnvelopeBatcher.md) |
| `EnvelopePaymaster` | `src/paymasters/EnvelopePaymaster.sol` | [EnvelopePaymaster.md](./EnvelopePaymaster.md) |

Interfaces:

| Interface | Source | Used by |
|---|---|---|
| `IEnvelopeGaslessValidator` | `src/envelope/util/IEnvelopeGaslessValidator.sol` | `EnvelopePaymaster` queries `EnvelopeVault.isValidGaslessOperation` before sponsoring gas. |

## License notice

This subtree mixes licenses; the repo-root `LICENSE` (Clear BSD) does not apply uniformly here.

| Files | License | Notes |
|---|---|---|
| `src/envelope/V4/EnvelopeVault.sol`, `EnvelopeBatcher.sol` | **GPL-3.0-or-later** | Modified copies of upstream Peanut Protocol V4.4. Full GPL v3 text is bundled at `src/envelope/V4/LICENSE-GPL`. Each file carries a top-of-file modification notice per GPL §5(a). |
| `src/envelope/util/IEnvelopeGaslessValidator.sol` | **GPL-3.0-or-later** | Minimal interface for the GPL vault validation surface. |
| `test/envelope/**/*.t.sol` | **GPL-3.0-or-later** | Test files that import GPL-licensed contracts are relicensed for compatibility. |
| `test/envelope/mocks/**/*.sol` | **MIT / UNLICENSED** | Vendored test mocks, original SPDX retained. |
| All other repo files | unchanged | Whatever they were. |

The GPL is "viral" only across `import` boundaries; non-importing files in the same repository remain under their own licenses under the OSI's "mere aggregation" interpretation.

## Naming convention

- **Source files** carry the Envelope brand (`EnvelopeVault.sol`, `EnvelopeBatcher.sol`); upstream audit lineage is preserved via the `// Modified by Nodle` notice, `// @author Squirrel Labs` attribution, bundled `LICENSE-GPL`, and git history.
- **Contract symbols** use the Envelope brand: `EnvelopeVault`, `EnvelopeBatcher`, `EnvelopePaymaster`.
- **On-chain hashed constants** keep upstream-compatible values where changing them would alter signature digests.

## Main flows

| Flow | Entry point | Summary |
|---|---|---|
| Basic deposit | `EnvelopeVault.makeDeposit` / `makeCustomDeposit` | Sender transfers ETH/ERC-20/ERC-721/ERC-1155 into the vault and receives a link key off-chain. |
| Paid or gasless-ready deposit | `EnvelopeVault.makeCustomDepositWithFees` | Sender supplies a backend-signed `FeeAuthorization`; the vault collects `serviceFee` and/or `gaslessFee` in `feeToken` at deposit creation. |
| Open claim | `EnvelopeVault.withdrawDeposit` | Link key signs the claim. Any transaction sender can submit it, but paymaster-sponsored submissions require `caller == recipient`. |
| MFA claim | `EnvelopeVault.withdrawMFADeposit` | Link key signs the claim and backend signs `(vault, index, recipient, deadline)`. Claim-time fees are not collected. |
| Recipient-bound claim | `EnvelopeVault.withdrawDepositAsRecipient` | Only the bound recipient can submit the transaction. |
| Sender reclaim | `EnvelopeVault.withdrawDepositSender` | Original sender reclaims unclaimed deposits; recipient-bound deposits also enforce `reclaimableAfter`. |
| Gasless validation | `EnvelopeVault.isValidGaslessOperation` | View helper used by `EnvelopePaymaster` to validate prepaid claim/reclaim calldata before the paymaster pays gas. |

## ZkSync gasless model

Gasless operations are paymaster-native:

1. Backend prices optional `serviceFee` and `gaslessFee` off-chain and signs the full deposit intent.
2. Sender creates the envelope with `makeCustomDepositWithFees` and prepays those fees in `feeToken`.
3. A recipient or sender submits a supported claim/reclaim call through `EnvelopePaymaster`.
4. Before execution, the paymaster checks the destination and calls `isValidGaslessOperation` on the vault.
5. If the vault approves and the paymaster has enough ETH, the paymaster pays the ZkSync bootloader and the vault call executes normally.

The vault no longer contains an internal paymaster callback, and the EIP-3009 gasless deposit/reclaim path has been removed.

## Deploy

| Script | Purpose |
|---|---|
| `hardhat-deploy/DeployEnvelope.ts` | Deploys `EnvelopeVault`, `EnvelopeBatcher`, and optionally `EnvelopePaymaster`. |

Important environment variables:

| Variable | Purpose |
|---|---|
| `ENVELOPE_MFA_AUTHORIZER` | Required backend signer for MFA and fee authorizations. |
| `ENVELOPE_OWNER` | Optional vault owner; defaults to deployer. |
| `ENVELOPE_FEE_TOKEN` | Optional fee token; defaults to zero address for fee-disabled deployments. |
| `ENVELOPE_DEPLOY_PAYMASTER` | Set to `true` to deploy `EnvelopePaymaster`. |
| `ENVELOPE_PAYMASTER_ADMIN` | Optional paymaster admin; defaults to deployer. |
| `ENVELOPE_PAYMASTER_WITHDRAWER` | Optional paymaster ETH withdrawer; defaults to deployer. |

## Test coverage

Relevant suites:

| Suite | Focus |
|---|---|
| `test/envelope/` | Vault deposits, claims, MFA, recipient binding, reclaim, fee collection, and gasless eligibility. |
| `test/paymasters/EnvelopePaymaster.t.sol` | ZkSync paymaster validation and rejection paths for Envelope gasless operations. |
| `test/paymasters/` | Shared base, whitelist, bond treasury, and Envelope paymaster behavior. |

Latest focused validation: `forge test --match-path 'test/{envelope/*,paymasters/*}'` passed 194 tests across 18 suites.

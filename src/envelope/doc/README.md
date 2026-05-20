# Envelope contracts

The Envelope flow on Nodle is built on top of modified Peanut Protocol V4.4 contracts. Senders create claimable links by escrowing assets against a per-link claim key; recipients claim with the matching private key. Nodle-specific additions include address-bound links, backend MFA, link-creation-time service fees, app-wallet batching on ZkSync smart accounts, and ZkSync paymaster support for prepaid or backend-sponsored gasless claims and reclaims.

## Layout

| Contract            | Source                                 | Spec                                           |
| ------------------- | -------------------------------------- | ---------------------------------------------- |
| `EnvelopeVault`     | `src/envelope/EnvelopeVault.sol`       | [EnvelopeVault.md](./EnvelopeVault.md)         |
| `EnvelopePaymaster` | `src/paymasters/EnvelopePaymaster.sol` | [EnvelopePaymaster.md](./EnvelopePaymaster.md) |

Interfaces:

| Interface                   | Source                                       | Used by                                                                                    |
| --------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `IEnvelopeGaslessValidator` | `src/envelope/IEnvelopeGaslessValidator.sol` | `EnvelopePaymaster` queries `EnvelopeVault.isValidGaslessOperation` before sponsoring gas. |

## License notice

This subtree mixes licenses; the repo-root `LICENSE` (Clear BSD) does not apply uniformly here.

| Files                                        | License              | Notes                                                                                                      |
| -------------------------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------- |
| `src/envelope/EnvelopeVault.sol`             | **GPL-3.0-or-later** | Modified copy of upstream Peanut Protocol V4.4. Full GPL v3 text is bundled at `src/envelope/LICENSE-GPL`. |
| `src/envelope/IEnvelopeGaslessValidator.sol` | **GPL-3.0-or-later** | Minimal interface for the GPL vault validation surface.                                                    |
| `test/envelope/**/*.t.sol`                   | **GPL-3.0-or-later** | Test files that import GPL-licensed contracts are relicensed for compatibility.                            |
| `test/envelope/mocks/**/*.sol`               | **MIT / UNLICENSED** | Vendored test mocks, original SPDX retained.                                                               |
| All other repo files                         | unchanged            | Whatever they were.                                                                                        |

The GPL is "viral" only across `import` boundaries; non-importing files in the same repository remain under their own licenses under the OSI's "mere aggregation" interpretation.

## Naming convention

- **Source files** carry the Envelope brand (`EnvelopeVault.sol`); upstream lineage is preserved via a one-line attribution comment, bundled `LICENSE-GPL`, and git history.
- **Contract symbols** use the Envelope brand: `EnvelopeVault`, `EnvelopePaymaster`.
- **On-chain hashed constants** keep upstream-compatible values where changing them would alter signature digests.

## Main flows

| Flow                          | Entry point                                                                                    | Summary                                                                                                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Basic deposit                 | `EnvelopeVault.makeDeposit` / `makeCustomDeposit`                                              | Sender transfers ETH/ERC-20/ERC-721/ERC-1155 into the vault and receives a link key off-chain.                                                                              |
| Paid or gasless-ready deposit | `EnvelopeVault.makeCustomDepositWithFees`                                                      | Sender supplies a backend-signed `FeeAuthorization`; the vault collects `serviceFee` and/or `gaslessFee` in `feeToken` and records optional `gaslessSponsored` eligibility. |
| Batch deposit                 | `EnvelopeVault.makeBatchDeposit` / `makeBatchCustomDeposit` / `makeBatchCustomDepositWithFees` | Sender creates many deposits in one transaction without a separate batcher contract. Fee signatures are signed for the actual caller.                                       |
| Open claim                    | `EnvelopeVault.withdrawDeposit`                                                                | Link key signs the claim. Any transaction sender can submit it, but paymaster-sponsored submissions require `caller == recipient`.                                          |
| MFA claim                     | `EnvelopeVault.withdrawMFADeposit`                                                             | Link key signs the claim and backend signs `(vault, index, recipient, deadline)`. Claim-time fees are not collected.                                                        |
| Recipient-bound claim         | `EnvelopeVault.withdrawDepositAsRecipient`                                                     | Only the bound recipient can submit the transaction.                                                                                                                        |
| Sender reclaim                | `EnvelopeVault.withdrawDepositSender`                                                          | Original sender reclaims unclaimed deposits; recipient-bound deposits also enforce `reclaimableAfter`.                                                                      |
| Gasless validation            | `EnvelopeVault.isValidGaslessOperation`                                                        | View helper used by `EnvelopePaymaster` to validate prepaid or backend-sponsored claim/reclaim calldata before the paymaster pays gas.                                      |

## ZkSync gasless model

Gasless operations are paymaster-native:

1. Backend prices optional `serviceFee`, `gaslessFee`, and `gaslessSponsored` off-chain and signs the full deposit intent for the app-wallet address that will call the vault.
2. Sender creates the envelope with `makeCustomDepositWithFees`; the app wallet can batch gift approval, NODL fee approval, and the vault call into one ZkSync smart-account transaction.
3. A recipient or sender submits a supported claim/reclaim call through `EnvelopePaymaster`.
4. Before execution, the paymaster checks the destination and calls `isValidGaslessOperation` on the vault.
5. If the vault approves and the paymaster has enough ETH, the paymaster pays the ZkSync bootloader and the vault call executes normally.

The vault no longer contains an internal paymaster callback, and the EIP-3009 gasless deposit/reclaim path has been removed.

## Deploy

| Script                             | Purpose                                                     |
| ---------------------------------- | ----------------------------------------------------------- |
| `hardhat-deploy/DeployEnvelope.ts` | Deploys `EnvelopeVault` and optionally `EnvelopePaymaster`. |

Important environment variables:

| Variable                        | Purpose                                                                    |
| ------------------------------- | -------------------------------------------------------------------------- |
| `ENVELOPE_MFA_AUTHORIZER`       | Required backend signer for MFA and fee authorizations.                    |
| `ENVELOPE_OWNER`                | Optional vault owner; defaults to deployer.                                |
| `ENVELOPE_FEE_TOKEN`            | Optional fee token; defaults to zero address for fee-disabled deployments. |
| `ENVELOPE_DEPLOY_PAYMASTER`     | Set to `true` to deploy `EnvelopePaymaster`.                               |
| `ENVELOPE_PAYMASTER_ADMIN`      | Optional paymaster admin; defaults to deployer.                            |
| `ENVELOPE_PAYMASTER_WITHDRAWER` | Optional paymaster ETH withdrawer; defaults to deployer.                   |

## Test coverage

Relevant suites:

| Suite                                     | Focus                                                                                                 |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `test/envelope/`                          | Vault deposits, claims, MFA, recipient binding, reclaim, fee collection, and gasless eligibility.     |
| `test/envelope/EnvelopeBatching.t.sol`    | Vault-native batching, raffle batches, ERC-721 heterogeneous batches, and batched fee authorizations. |
| `test/paymasters/EnvelopePaymaster.t.sol` | ZkSync paymaster validation and rejection paths for Envelope gasless operations.                      |
| `test/paymasters/`                        | Shared base, whitelist, bond treasury, and Envelope paymaster behavior.                               |

Latest focused validation: `forge test --match-path 'test/{envelope/*,paymasters/*}'` passed 207 tests across 18 suites.

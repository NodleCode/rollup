# EnvelopeVault

`src/envelope/V4/EnvelopeVault.sol`

## Purpose

`EnvelopeVault` is a link-based asset vault for ETH, ERC-20, ERC-721, and ERC-1155 gifts. A sender deposits an asset against a per-link `pubKey20`; the recipient claims by presenting a signature from the matching private key. The vault supports open links, address-bound links, optional backend MFA, sender reclaim, deposit-time service fees, and prepaid gasless claim/reclaim eligibility for ZkSync paymasters.

## Constructor

```solidity
constructor(address mfaAuthorizer, address owner, address feeToken)
```

| Param | Purpose |
|---|---|
| `mfaAuthorizer` | Backend signer for MFA claim approvals and deposit-time fee authorizations. `address(0)` disables non-zero fee authorizations and makes MFA withdrawals fail. |
| `owner` | Owns the vault and can withdraw accumulated fees. |
| `feeToken` | ERC-20 used for Nodle service and gasless sponsorship fees, for example NODL. `address(0)` permits only zero-fee deposits. |

The constructor also sets the EIP-712 domain separator used by the vault-side validation helpers.

## Deposit Model

All deposits store a `Deposit` record:

```solidity
struct Deposit {
    address pubKey20;
    uint256 amount;
    address tokenAddress;
    uint8 contractType;      // 0=ETH, 1=ERC20, 2=ERC721, 3=ERC1155
    bool claimed;
    bool requiresMFA;
    uint40 timestamp;
    uint256 tokenId;
    address senderAddress;
    address recipient;
    uint40 reclaimableAfter;
    uint256 serviceFee;      // feeToken amount collected at deposit creation
    uint256 gaslessFee;      // feeToken amount prepaid for paymaster sponsorship
}
```

`serviceFee` and `gaslessFee` are not deducted from the gift amount. They are separate `feeToken` transfers from the depositor to the vault and are accounted in `accumulatedFees[address(feeToken)]`.

## Main Deposit Functions

| Function | Flow |
|---|---|
| `makeDeposit(token, type, amount, tokenId, pubKey20)` | Basic open link. No MFA, no fees, no gasless sponsorship. |
| `makeMFADeposit(...)` | Basic open link that requires backend MFA at claim time. No deposit-time fees unless using `makeCustomDepositWithFees`. |
| `makeSelflessDeposit(..., onBehalfOf)` | Creates a link whose reclaim rights belong to `onBehalfOf`. Used by batch flows. |
| `makeSelflessMFADeposit(..., onBehalfOf)` | Selfless deposit plus MFA requirement. |
| `makeCustomDeposit(...)` | Canonical no-fee entry point with MFA flag, optional recipient binding, and optional reclaim delay. |
| `makeCustomDepositWithFees(request, feeAuthorization)` | Canonical paid-service entry point. Pulls the gift asset, verifies backend-signed fees, collects `feeToken`, and records gasless eligibility when `gaslessFee > 0`. |
| `makeBatchDeposit(...)` | Creates many same-shape no-fee deposits in one transaction. ETH, ERC-20, and ERC-1155 are supported; ERC-721 uses the heterogeneous batch path. |
| `makeBatchDepositNoReturn(...)` | Same as `makeBatchDeposit` but skips allocating/returning the deposit indexes array. |
| `makeBatchCustomDeposit(...)` | Creates a heterogeneous no-fee batch and supports ETH, ERC-20, ERC-721, and ERC-1155. |
| `makeBatchCustomDepositWithFees(requests, feeAuthorizations)` | Creates a heterogeneous paid/gasless-ready batch using the same `DepositRequest` and `FeeAuthorization` structs as the single-deposit flow. |
| `makeBatchDepositRaffle(...)` | Creates ETH or ERC-20 raffle-style deposits with different amounts and one shared `pubKey20`. |
| `makeBatchMFADepositRaffle(...)` | Same as raffle batching, but every deposit requires MFA at claim time. |

`FeeAuthorization` covers the full deposit intent, the fee payer (`msg.sender`), the two fee amounts, and a backend-selected deadline. `deadline == 0` means no expiry. If either fee is non-zero, the signature must recover to `mfaAuthorizer`.

## Vault-Native Batching

Batching is implemented directly in `EnvelopeVault` rather than a separate companion contract. This keeps the real sender as `msg.sender`, so reclaim rights and backend fee signatures use the same identity as single deposits. It also removes the extra custody hop where a batcher temporarily holds tokens before forwarding them to the vault.

The batching functions share the same storage and events as single deposits. Same-shape batches aggregate ERC-20/ERC-1155 pulls for efficiency; heterogeneous batches pull each asset separately and can include ERC-721 token IDs. Batched fee authorizations are signed for the caller of the vault, not an intermediate contract.

## Withdraw And Claim Functions

| Function | Caller | Authorization |
|---|---|---|
| `withdrawDeposit(index, recipient, signature)` | Anyone, or a recipient using a paymaster | Link key signs `(salt, chainId, vault, index, recipient, ANYONE_WITHDRAWAL_MODE)`. |
| `withdrawMFADeposit(index, recipient, signature, mfaSignature, deadline)` | Anyone, or a recipient using a paymaster | Link signature plus backend MFA signature over `(salt, chainId, vault, index, recipient, deadline)`. |
| `withdrawDepositAsRecipient(index, recipient, signature)` | Must be `recipient` | Link key signs using `RECIPIENT_WITHDRAWAL_MODE`. |
| `withdrawDepositSender(index)` | Original `senderAddress` | Sender reclaim. If the deposit is recipient-bound, `block.timestamp` must be greater than `reclaimableAfter`. |

All withdrawal paths set `claimed = true` before transferring assets. Claim-time fee collection was intentionally removed: fees are now collected when the envelope is created.

## Gasless Paymaster Flow

Gasless operation is handled by ZkSync paymasters, not by an internal vault callback. The vault is only the source of truth for whether a paymaster should sponsor a call.

1. Sender creates a deposit through `makeCustomDepositWithFees` with `gaslessFee > 0`.
2. The vault collects the gasless sponsorship fee immediately in `feeToken` and records it on the deposit.
3. A receiver submits a ZkSync transaction to `withdrawDeposit`, `withdrawMFADeposit`, or `withdrawDepositAsRecipient` using `EnvelopePaymaster`.
4. ZkSync calls the paymaster before execution. The paymaster checks the transaction targets this vault and calls `isValidGaslessOperation(from, transaction.data)`.
5. The vault re-checks the deposit state, gasless fee, recipient/sender identity, signatures, MFA deadline, and reclaim delay.
6. If validation passes, the paymaster pays ETH to the bootloader. The vault function then executes normally.

Sender reclaim can also be gasless: the sender submits `withdrawDepositSender(index)` through the paymaster. This is allowed only for deposits with `gaslessFee > 0` and the same reclaim timing rules as the regular reclaim path.

## Paymaster Validation Helper

```solidity
function isValidGaslessOperation(address caller, bytes calldata callData) external view returns (bool);
```

This function is intended for paymaster validation. It accepts only these selectors:

- `withdrawDeposit`
- `withdrawMFADeposit`
- `withdrawDepositAsRecipient`
- `withdrawDepositSender`

For claim calls, `caller` must be the recipient. For reclaim calls, `caller` must be the stored sender. The helper returns false for non-prepaid deposits, claimed deposits, unsupported selectors, wrong callers, invalid signatures, expired MFA approvals, or early reclaims.

## Fees

| Fee | Collected | Meaning |
|---|---|---|
| `serviceFee` | Deposit creation | Paid backend service fee for optional security/MFA/compliance checks. |
| `gaslessFee` | Deposit creation | Prepaid compensation for paymaster-sponsored claim or reclaim. |

Both fees are backend-priced off-chain and backend-signed on-chain. The vault does not encode pricing policy; it enforces the signed amounts and deadline. The owner withdraws accumulated fees through `withdrawFees(token)`.

## Removed EIP-3009 Path

The previous EIP-3009 deposit and gasless reclaim paths were removed. ERC-20 deposits now use standard allowance-based transfers, and ZkSync gasless UX is provided by the paymaster flow above.

## Events

```solidity
event DepositEvent(uint256 indexed index, uint8 indexed contractType, uint256 amount, address indexed senderAddress);
event WithdrawEvent(uint256 indexed index, uint8 indexed contractType, uint256 amount, address indexed recipientAddress);
event FeeCollected(uint256 indexed index, address indexed tokenAddress, uint256 serviceFee, uint256 gaslessFee);
event FeesWithdrawn(address indexed tokenAddress, uint256 amount);
```

## Test Coverage

Core coverage lives in `test/envelope/`. Gasless fee and vault-side paymaster eligibility tests live in `test/envelope/Gasless.t.sol`; ZkSync paymaster validation tests live in `test/paymasters/EnvelopePaymaster.t.sol`.

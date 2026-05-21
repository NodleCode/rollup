# EnvelopePaymaster

`src/paymasters/EnvelopePaymaster.sol`

## Purpose

`EnvelopePaymaster` is the ZkSync paymaster for EnvelopeLinks gasless operations. It pays ETH for claims and sender reclaims only when the target `EnvelopeLinks` says the operation is valid and either prepaid (`gaslessFee > 0`) or backend-sponsored (`gaslessSponsored == true`).

## Constructor

```solidity
constructor(address admin, address withdrawer, address envelopeLinks)
```

| Param           | Purpose                                                    |
| --------------- | ---------------------------------------------------------- |
| `admin`         | Default admin for `BasePaymaster` roles.                   |
| `withdrawer`    | Address allowed to withdraw excess ETH from the paymaster. |
| `envelopeLinks` | The only vault destination this paymaster will sponsor.    |

## Validation Flow

The paymaster supports ZkSync general flow only.

1. ZkSync bootloader calls `validateAndPayForPaymasterTransaction` on `BasePaymaster`.
2. `BasePaymaster` forwards `from`, `to`, `requiredETH`, and `transaction.data` to `_validateAndPayGeneralFlow`.
3. `EnvelopePaymaster` requires `to == envelopeLinks`.
4. It calls `EnvelopeLinks.isValidGaslessOperation(from, transaction.data)`.
5. It verifies it has enough ETH for `requiredETH`.
6. `BasePaymaster` pays the bootloader.

The paymaster does not price fees. Fee pricing, prepaid gasless amounts, and backend-sponsored eligibility are recorded in `EnvelopeLinks` at deposit creation.

The paymaster records one validation attempt per link before paying the bootloader. ZkSync runs validation and execution separately, so this attempt remains recorded even when the subsequent vault execution reverts. Up to `MAX_GASLESS_ATTEMPTS_PER_LINK` (currently **3**) attempts are allowed per link. This gives users room for honest retries (e.g. wrong gas limit, receiver contract not yet deployed) while bounding paymaster loss from repeated execution failures. Once the limit is reached, the user can still submit the vault call while paying gas themselves.

## Sponsored Selectors

The paymaster delegates selector checks to the vault. The currently accepted operations are:

- `claim`
- `claimWithMFA`
- `claimAsBoundRecipient`
- `reclaim`

Approval-based paymaster flow is explicitly rejected.

## Funding

The paymaster must be funded with ETH on ZkSync. The vault collects `feeToken` compensation at deposit creation when `gaslessFee > 0`; moving that accumulated fee value back into paymaster ETH funding is an operational/backend treasury process, not a claim-time on-chain transfer. When `gaslessSponsored == true`, no sender-side gasless fee is collected and the backend/paymaster operator funds the claim gas budget directly.

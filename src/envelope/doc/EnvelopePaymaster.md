# EnvelopePaymaster

`src/paymasters/EnvelopePaymaster.sol`

## Purpose

`EnvelopePaymaster` is the ZkSync paymaster for prepaid EnvelopeVault gasless operations. It pays ETH for claims and sender reclaims only when the target `EnvelopeVault` says the operation is valid and prepaid.

## Constructor

```solidity
constructor(address admin, address withdrawer, address envelopeVault)
```

| Param | Purpose |
|---|---|
| `admin` | Default admin for `BasePaymaster` roles. |
| `withdrawer` | Address allowed to withdraw excess ETH from the paymaster. |
| `envelopeVault` | The only vault destination this paymaster will sponsor. |

## Validation Flow

The paymaster supports ZkSync general flow only.

1. ZkSync bootloader calls `validateAndPayForPaymasterTransaction` on `BasePaymaster`.
2. `BasePaymaster` forwards `from`, `to`, `requiredETH`, and `transaction.data` to `_validateAndPayGeneralFlow`.
3. `EnvelopePaymaster` requires `to == envelopeVault`.
4. It calls `EnvelopeVault.isValidGaslessOperation(from, transaction.data)`.
5. It verifies it has enough ETH for `requiredETH`.
6. `BasePaymaster` pays the bootloader.

The paymaster does not keep per-gift state and does not price fees. Fee pricing and eligibility are recorded in `EnvelopeVault` at deposit creation.

## Sponsored Selectors

The paymaster delegates selector checks to the vault. The currently accepted operations are:

- `withdrawDeposit`
- `withdrawMFADeposit`
- `withdrawDepositAsRecipient`
- `withdrawDepositSender`

Approval-based paymaster flow is explicitly rejected.

## Funding

The paymaster must be funded with ETH on ZkSync. The vault collects `feeToken` compensation at deposit creation; moving that accumulated fee value back into paymaster ETH funding is an operational/backend treasury process, not a claim-time on-chain transfer.

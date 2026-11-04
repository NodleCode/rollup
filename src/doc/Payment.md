# Payment

`src/Payment.sol`, built on `src/QuotaControl.sol`

## Purpose

`Payment` holds a balance of one ERC-20 token. Accounts with `ORACLE_ROLE` pay that balance out to recipients, and the total they can pay is capped per period. The admin sets the cap and can withdraw the balance.

## Constructor

```solidity
constructor(address oracle, address _token, uint256 initialQuota, uint256 initialPeriod, address admin)
```

| Param           | Purpose                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------- |
| `oracle`        | First account granted `ORACLE_ROLE`.                                                                    |
| `_token`        | The ERC-20 token the contract pays in. Immutable.                                                       |
| `initialQuota`  | The most that `pay` can send in one period, in the token's smallest unit.                               |
| `initialPeriod` | The period length in seconds. It must be greater than 0 and at most `MAX_PERIOD` (30 days).             |
| `admin`         | Account granted `DEFAULT_ADMIN_ROLE`.                                                                   |

The first period ends at deployment time plus `initialPeriod`.

## Roles

| Role                 | Can call                                                                       |
| -------------------- | ------------------------------------------------------------------------------ |
| `DEFAULT_ADMIN_ROLE` | `setQuota`, `setPeriod`, `withdraw`, and `grantRole` / `revokeRole` for both roles |
| `ORACLE_ROLE`        | `pay`                                                                          |

`ORACLE_ROLE` can be held by several accounts at once. They all draw on the same balance and the same quota. An account that sends transactions from more than one process needs its own nonce handling, so giving each independent caller its own oracle account is simpler.

## State

| Variable                | Meaning                                                                    |
| ----------------------- | -------------------------------------------------------------------------- |
| `token`                 | The token paid out. Immutable.                                             |
| `quota`                 | The most that can be paid in the current period.                           |
| `period`                | The period length in seconds.                                              |
| `quotaRenewalTimestamp` | When the current period ends.                                              |
| `claimed`               | The amount paid in the current period, as of the last `pay`.               |
| `MAX_PERIOD`            | 30 days, a constant.                                                       |

## Paying

```solidity
function pay(address[] calldata recipients, uint256 amount) external onlyRole(ORACLE_ROLE)
```

`pay` sends the same `amount` to every address in `recipients`. Paying different amounts takes one call per amount. In order, it:

1. Requires `ORACLE_ROLE`, or reverts with `AccessControlUnauthorizedAccount`.
2. Computes `needed = recipients.length * amount`. If the contract's token balance is below `needed`, it reverts with `InsufficientBalance(balance, needed)`.
3. Starts a new period if the current one has ended (see below).
4. Adds `needed` to `claimed`. If the result is above `quota`, it reverts with `QuotaExceeded`.
5. Transfers `amount` to each recipient in list order, using `SafeERC20`.

A recipient listed twice is paid twice. The contract keeps no record of who was paid or why, so calling `pay` twice with the same arguments pays twice. A caller that must not pay twice needs its own record of what it sent.

The contract emits no payment event of its own. Each payment shows up as the token's `Transfer` event from the contract's address to the recipient.

## Quota periods

A period does not roll over on a timer. The first `pay` at or after `quotaRenewalTimestamp` resets `claimed` to 0 and moves `quotaRenewalTimestamp` to the next boundary on the original schedule:

```
quotaRenewalTimestamp = now + period - ((now - quotaRenewalTimestamp) % period)
```

For example, with a period of 1 day, a contract deployed at `T` has period boundaries at `T + 1 day`, `T + 2 days`, and so on. A first `pay` at `T + 2.5 days` starts the period that ends at `T + 3 days`. Boundaries follow the deployment time, not midnight.

- **`setQuota(newQuota)`** applies at once, to the current period too. Setting it below `claimed` blocks `pay` until the period ends, and setting it to 0 blocks `pay` entirely. It emits `QuotaSet`.
- **`setPeriod(newPeriod)`** changes the length of periods from the next reset on. It does not move the current `quotaRenewalTimestamp`. It reverts with `ZeroPeriod` for 0 and `TooLongPeriod` above `MAX_PERIOD`, and emits `PeriodSet`.

## Funding and withdrawing

There is no deposit function. The contract is funded by a plain token transfer to its address, from any account.

```solidity
function withdraw(address recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE)
```

`withdraw` sends `amount` of the token to `recipient`. It does not count toward the quota.

## Stopping payments

There is no pause function. The admin can stop payments in two ways:

- Set the quota to 0. This stops every oracle at once.
- Revoke `ORACLE_ROLE` from one account. This stops only that account.

Withdrawing the balance also makes every later `pay` revert with `InsufficientBalance`.

## Events and errors

| Event / error                                          | When                                              |
| ------------------------------------------------------ | ------------------------------------------------- |
| `QuotaSet(uint256 quota)`                              | `setQuota`                                        |
| `PeriodSet(uint256 period)`                            | `setPeriod`                                       |
| `RoleGranted` / `RoleRevoked`                          | Role changes (OpenZeppelin `AccessControl`)       |
| `InsufficientBalance(uint256 balance, uint256 needed)` | `pay` needs more than the contract holds          |
| `QuotaExceeded()`                                      | `pay` would take `claimed` above `quota`          |
| `ZeroPeriod()` / `TooLongPeriod()`                     | A period of 0, or above `MAX_PERIOD`              |
| `AccessControlUnauthorizedAccount(account, role)`      | A caller without the required role                |

## Gas sponsorship

`Payment` does not depend on how its callers pay for gas. On ZkSync, an oracle can send `pay` through a general-flow paymaster that sponsors the contract and the oracle, such as `WhitelistPaymaster` or `BondTreasuryPaymaster` in `src/paymasters/`. Whitelisting the contract on such a paymaster lets every whitelisted user call it for free. That opens nothing new: every function that changes state requires a role, except `renounceRole`, which only drops the caller's own role.

## Deploying on ZkSync

`ops/deploy_payment_zksync.sh <testnet|mainnet> [--broadcast]` runs `script/DeployPaymentZkSync.s.sol` with `forge script --zksync`. Without `--broadcast` it only simulates. A mainnet broadcast also needs `CONFIRM_MAINNET=YES`.

| Variable               | Value                                                       |
| ---------------------- | ----------------------------------------------------------- |
| `DEPLOYER_PRIVATE_KEY` | The deploying account. It ends up holding no role.          |
| `N_TOKEN_ADDR`         | The token. Its `symbol()` must be `NODL`.                   |
| `N_PAYMENT_ADMIN`      | `DEFAULT_ADMIN_ROLE` holder.                                |
| `N_PAYMENT_ORACLE`     | First `ORACLE_ROLE` holder. Not the admin, not the deployer.|
| `N_PAYMENT_QUOTA`      | Quota in wei. At least 1 token (`1e18`).                    |
| `N_PAYMENT_PERIOD`     | Optional period in seconds. Defaults to 1 day.              |

The script refuses invalid inputs before anything is sent. After the simulated deployment, it checks that the admin and the oracle hold their roles and that the deployer holds neither.

Verify the deployed source with:

```bash
python3 ops/verify_zksync_contracts.py --broadcast broadcast/DeployPaymentZkSync.s.sol/<chainId>/run-latest.json --verifier-url <explorer verification URL>
```

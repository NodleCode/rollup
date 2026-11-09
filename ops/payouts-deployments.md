# Payouts contract — deployments

Deployment record for the payouts contract, an instance of [`src/Payment.sol`](../src/Payment.sol) described in [`src/doc/Payment.md`](../src/doc/Payment.md). Backend programs pay users NODL from it, each through its own `ORACLE_ROLE` key.

## Mainnet (ZKsync Era, chain 324)

| Contract | Address | Verified |
|---|---|---|
| `Payment` | [`0x4D5e78077BC149bC1c8ED8BEd1Cb4b973a975f5B`](https://explorer.zksync.io/address/0x4D5e78077BC149bC1c8ED8BEd1Cb4b973a975f5B#contract) | yes |

- Deployed 2026-11-05 in tx [`0xa802693a…e3d8`](https://explorer.zksync.io/tx/0xa802693a2c974cc3630db2a136e56d95633bce01145ca9b9f26248dcd3fde3d8) from `0x0cC73B6E713DdFc1c2B26C841C45ddad60AA772A`, which holds no role.
- Token: L2 NODL `0xBD4372e44c5eE654dd838304006E1f0f69983154`.
- Admin (`DEFAULT_ADMIN_ROLE`): `0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9`, the 2-of-4 Safe. It alone can withdraw, change the quota or period, and grant or revoke `ORACLE_ROLE`.
- Funded by plain NODL transfers to the contract's address. It held 0 NODL at deploy.

| Parameter | Value |
|---|---|
| `quota` / `period` | 200,000 NODL / 1 day |
| Period boundary | 14:51:15 UTC daily, the deploy time |
| `MAX_PERIOD` | 30 days (constant) |

### Oracles

Each program that pays from the contract holds its own `ORACLE_ROLE` key, so no two services share a nonce. All of them draw on the same balance and the same quota.

| Oracle | Held by | Private key | Program |
|---|---|---|---|
| `0xD49f0d1c1D058e0ceA178113500b939f4BD02eFf` | multi-token-api | GCP Secret Manager `multi-token-api-payouts-oracle-key` (project `nodle-network-production`) | adjoe rewards |

### Adding a program

1. The program creates its own oracle key. It never reuses another program's key.
2. The Safe grants it `ORACLE_ROLE` on the contract, and adds it to the paymaster with `addWhitelistedUsers([oracle])`.
3. The Safe raises `quota` by the program's daily volume, and treasury adds its funding.
4. Add a row to the oracles table above.

### Gas sponsorship

Oracles pay no gas: their `pay` transactions use the general flow of `BondTreasuryPaymaster` [`0xb253528104D8C23eE14647410deDf70A9092bfFE`](https://explorer.zksync.io/address/0xb253528104D8C23eE14647410deDf70A9092bfFE). The paymaster checks only that the sender is a whitelisted user and the destination a whitelisted contract. The Safe holds its `WHITELIST_ADMIN_ROLE`, so one Safe transaction covers both:

- `addWhitelistedContracts([payouts contract])`
- `addWhitelistedUsers([oracle])`

Import [`safe/payouts-paymaster-whitelist.json`](safe/payouts-paymaster-whitelist.json) in the Safe Transaction Builder. No bond allowance is needed: an oracle never calls `consumeSponsoredBond`. Neither address was whitelisted at deploy.

Whitelisting is shared across the paymaster's lists. An oracle can also send sponsored transactions to the other whitelisted contracts, but every state-changing function on this contract requires a role, so other whitelisted users gain nothing here.

On Sepolia, a sponsored one-recipient `pay` from the oracle estimated at 315,196 gas on 2026-11-05.

## Sepolia (ZKsync Era Sepolia, chain 300)

| Contract | Address | Verified |
|---|---|---|
| `Payment` | [`0x0E1Afd9e7e5f505193d67206e2c2aD544F5c2376`](https://sepolia.explorer.zksync.io/address/0x0E1Afd9e7e5f505193d67206e2c2aD544F5c2376#contract) | yes |

- Deployed 2026-11-05 in tx [`0xac781a62…8e57`](https://sepolia.explorer.zksync.io/tx/0xac781a62f379a080bb3eefc0e9d0736949f79f41935f72e42b8af46e5fba8e57) from `0x81df54C68DDE05CB1Bf988bc2433ae5A5da01B51`, which holds no role.
- Token: Sepolia NODL `0xb4B74C2BfeA877672B938E408Bae8894918fE41C`.
- Admin (`DEFAULT_ADMIN_ROLE`): `0xc1F2A7b888e4837aFACfc5E914AB647476ceCD46`.
- `quota` / `period`: 200,000 NODL / 1 day, with the period boundary at 14:15:34 UTC.
- Funded with 1,000 NODL in tx [`0xb36b0864…870c`](https://sepolia.explorer.zksync.io/tx/0xb36b0864a07580709c0de81a173d61c7e71b5866f2ddfdce7a9f1e606ebe870c).

| Oracle | Held by | Private key | Program |
|---|---|---|---|
| `0x9386B99cfeaA0C146EAFC4a6773de1513b084A7A` | multi-token-api (staging) | GCP Secret Manager `multi-token-api-payouts-oracle-key` (project `staging-309410`) | adjoe rewards |

Both are whitelisted on the Sepolia `BondTreasuryPaymaster` [`0x6FFD3a0C03f6Fb55406C2E1b71a35Cf2997F13A5`](https://sepolia.explorer.zksync.io/address/0x6FFD3a0C03f6Fb55406C2E1b71a35Cf2997F13A5), sent from its whitelist admin `0xc1F2…cD46`: the contract in tx `0xfd3cbc68…e76e` and the oracle in tx `0xcdafbcd1…d345`.

## Deploy and verify

The deployer must not be the oracle, and must not be the admin: the script refuses a deployer that ends up holding either role.

```bash
CONFIRM_MAINNET=YES DEPLOYER_PRIVATE_KEY=0x… \
N_TOKEN_ADDR=0xBD4372e44c5eE654dd838304006E1f0f69983154 \
N_PAYMENT_ADMIN=0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9 \
N_PAYMENT_ORACLE=0xD49f0d1c1D058e0ceA178113500b939f4BD02eFf \
N_PAYMENT_QUOTA=200000000000000000000000 \
N_PAYMENT_PERIOD=86400 \
  ops/deploy_payment_zksync.sh mainnet --broadcast
```

```bash
python3 ops/verify_zksync_contracts.py --broadcast broadcast/DeployPaymentZkSync.s.sol/324/run-latest.json --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification
```

For Sepolia, use `testnet` without `CONFIRM_MAINNET`, the Sepolia values above, `broadcast/DeployPaymentZkSync.s.sol/300/run-latest.json` and `--verifier-url https://explorer.sepolia.era.zksync.dev/contract_verification`.

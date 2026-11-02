# ArcadeEscrow — deployments

Deployment record for [`src/arcade/ArcadeEscrow.sol`](../src/arcade/ArcadeEscrow.sol).

## Mainnet (ZKsync Era, chain 324)

| Contract | Address | Verified |
|---|---|---|
| `ArcadeEscrow` | [`0x661A48370275F10A7f95a86E408B568C08eFeef0`](https://explorer.zksync.io/address/0x661A48370275F10A7f95a86E408B568C08eFeef0#contract) | yes |

- Deployed 2026-11-02 in tx [`0x1d6735dd…4f52`](https://explorer.zksync.io/tx/0x1d6735ddd6d6a8e5335f251668dc6df89ff755316bef69dc0a609507081a4f52) from `0x49dDBe122B410d4C4A5b1A77030903e6CD391c62`, which holds no role.
- Token: L2 NODL `0xBD4372e44c5eE654dd838304006E1f0f69983154`.
- Admin (`DEFAULT_ADMIN_ROLE`): `0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9`, the 2-of-4 Safe.
- Oracle (`ORACLE_ROLE`): `0x7b0d247131B0A40D66baF289C3d424a3d4123fcD`, arcade-forge's settlement key. Its private key is in GCP Secret Manager as `arcade-escrow-oracle-private-key` (project `nodle-network-production`). It is a separate key from mission-control's `oracle_private_key`.

| Parameter | Value |
|---|---|
| `minDeposit` | 200 NODL |
| `maxCharge` | 20,000 NODL |
| `quota` / `period` | 2,000,000 NODL / 1 day |
| `withdrawDelay` | 1 hour |
| `MAX_WITHDRAW_DELAY` | 7 days (constant) |
| `ADMIN_DELAY` | 8 days (constant) |

Granting `ORACLE_ROLE`, raising `maxCharge` or the quota, and shortening the period go through `scheduleChange` → `executeChange` after `ADMIN_DELAY`. Lowering limits, revoking the oracle and pausing are immediate Safe transactions.

### Gas sponsorship

The oracle pays no gas: its transactions to the escrow use the general flow of `BondTreasuryPaymaster` [`0xb253528104D8C23eE14647410deDf70A9092bfFE`](https://explorer.zksync.io/address/0xb253528104D8C23eE14647410deDf70A9092bfFE). The paymaster checks only that the sender is a whitelisted user and the destination a whitelisted contract, so this needs one Safe transaction, which holds `WHITELIST_ADMIN_ROLE`:

- `addWhitelistedContracts([ArcadeEscrow])`
- `addWhitelistedUsers([oracle])`

Import [`safe/arcade-escrow-paymaster-whitelist.json`](safe/arcade-escrow-paymaster-whitelist.json) in the Safe Transaction Builder. No bond allowance is needed: the oracle never calls `consumeSponsoredBond`.

Whitelisting is shared across the paymaster's lists: the oracle can also send sponsored transactions to the other whitelisted contracts, and existing whitelisted users can call the escrow (for example `deposit`) without gas.

A sponsored `charge` should cost about what mission-control's `Payment.pay` does, ~0.000006 ETH. On 2026-11-02 the paymaster held 0.0859 ETH and had spent 0.0004 ETH in the previous 30 days, so it needs no top-up yet. Its NODL balance funds swarm bonds only.

## Deploy and verify

```bash
CONFIRM_MAINNET=YES DEPLOYER_PRIVATE_KEY=0x… \
N_TOKEN_ADDR=0xBD4372e44c5eE654dd838304006E1f0f69983154 \
N_ARCADE_ADMIN=0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9 \
N_ARCADE_ORACLE=0x7b0d247131B0A40D66baF289C3d424a3d4123fcD \
N_ARCADE_QUOTA=2000000000000000000000000 \
N_ARCADE_MIN_DEPOSIT=200000000000000000000 \
N_ARCADE_MAX_CHARGE=20000000000000000000000 \
  ops/deploy_arcade_escrow_zksync.sh mainnet --broadcast
```

```bash
python3 ops/verify_zksync_contracts.py --broadcast broadcast/DeployArcadeEscrow.s.sol/324/run-latest.json --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification
```

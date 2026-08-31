# Fundraising — deployments

Deployment record for the contracts in [`src/fundraising`](../src/fundraising).

## Mainnet (ZKsync Era, chain 324)

### Current

| Contract | Address | Verified |
|---|---|---|
| `FundraiserFactory` | [`0x408A7A05Ee9e27Af05D9Ba4dc34647f323100841`](https://explorer.zksync.io/address/0x408A7A05Ee9e27Af05D9Ba4dc34647f323100841#contract) | yes |

- Admin (`DEFAULT_ADMIN_ROLE`): `0x5e097ac1bcf81e7ff2657045f72caa6cf06486c9` — the Gnosis Safe v1.3.0 2-of-4 that administers the other production contracts. The deployer holds no role.
- Allow-listed in this order: native USDC `0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4`, then bridged USDC.e `0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4`. Both 6 decimals, and both display as "USDC" in most wallets, so whatever creates a fundraise must choose deliberately.
- **Fee: 100 bps (1%) to the Safe.** Taken only on `withdraw`, never on refunds or unpledges, and snapshotted into each fundraise at creation so a later change cannot reach anything in flight. The recipient is read live, so the Safe can repoint it without touching live fundraises.
- `MAX_FEE_BPS` 500 and `MAX_DURATION` 31536000 are constants and can never change.

Smoke fundraise from the deploy: [`0xec6603f9f188d7b552444377e300c75905f97b3e`](https://explorer.zksync.io/address/0xec6603f9f188d7b552444377e300c75905f97b3e). Created with a supplied organizer different from the sender, confirming creation-on-behalf-of works on EraVM.

### Superseded

| Contract | Address | Note |
|---|---|---|
| `FundraiserFactory` | [`0xCFaF15E15696b2e8D19C5B3bFc4Bf091422Dda5e`](https://explorer.zksync.io/address/0xCFaF15E15696b2e8D19C5B3bFc4Bf091422Dda5e#contract) | Takes the organizer from `msg.sender` and carries a zero fee. Verified, and still functional |

> [!IMPORTANT]
> The superseded factory has **not** been disabled — that needs a Safe transaction, `setTokenAllowed(token, false)` for both USDC addresses, which stops new fundraises being created through it. Until then it will happily create fee-free fundraises whose organizer is whoever sent the transaction. Existing fundraises are unaffected either way; de-listing never reaches money already escrowed.

## Testnet (ZKsync Era Sepolia, chain 300)

### Current

| Contract | Address | Verified |
|---|---|---|
| `FundraiserFactory` | [`0x65d016A46a4339d8111b6006b852027eC8FB1f45`](https://sepolia.explorer.zksync.io/address/0x65d016A46a4339d8111b6006b852027eC8FB1f45#contract) | yes |
| `Fundraiser` (example) | [`0xefbaEaBcA6eb2d53C22644dDCc0759B70D74361c`](https://sepolia.explorer.zksync.io/address/0xefbaeabca6eb2d53c22644ddcc0759b70d74361c#contract) | yes |

- Admin (`DEFAULT_ADMIN_ROLE`): `0xc1F2A7b888e4837aFACfc5E914AB647476ceCD46`
- Allow-listed token: NODL `0x37EDFB6d82c3194e0024c9340aa0993eb42Ec14c`
- `feeBps` 0, `MAX_FEE_BPS` 500, `MAX_DURATION` 31536000

### Superseded

| Contract | Address | Note |
|---|---|---|
| `FundraiserFactory` | [`0x898A7dD2Be10e239c126ff19F99b62223f93279f`](https://sepolia.explorer.zksync.io/address/0x898A7dD2Be10e239c126ff19F99b62223f93279f#contract) | Predates the `groupId` → `externalId` rename, so its `createFundraiser` ABI differs from the current source |
| `Fundraiser` (success path) | [`0x68db256e6042105eff4877fe01d82689714121f4`](https://sepolia.explorer.zksync.io/address/0x68db256e6042105eff4877fe01d82689714121f4#contract) | `Closed`, raised 100 NODL and paid out |
| `Fundraiser` (refund path) | [`0x91305bdd97e1e78259321465ee056065195563fd`](https://sepolia.explorer.zksync.io/address/0x91305bdd97e1e78259321465ee056065195563fd#contract) | `Refunding`, fully refunded |

These are verified and remain on-chain — nothing on ZKsync can be withdrawn once deployed. They have been superseded **functionally as well as in this document**: NODL was de-listed on the superseded factory, so `createFundraiser` now reverts `TokenNotAllowed` and nothing further can be created through it.

De-listing deliberately does not reach the two fundraises already created by it. That is the designed behavior — an allow-list change must never become a freeze switch over funds already escrowed — and it is worth noting that superseding a factory therefore cannot strand anyone's money.

### What was exercised on-chain

Both outcomes, against the superseded factory and re-confirmed against the current one:

- **Target reached** — deposit, unpledge below target, top up to the target, then `unpledge` and `cancel` both reverting `GoalReached`, `finalize` → `Succeeded`, `withdraw` paying the beneficiary in full and leaving the escrow at zero.
- **Target missed** — `finalize` before the deadline reverting `NotFinalizable`; after it, `finalize` → `Refunding`, `refund` returning the contribution exactly, and a second `refund` reverting `NothingToRefund`.

Measured testnet gas: `createFundraiser` 216,226 · `deposit` 120,546.

## Redeploying

```shell
./ops/deploy_fundraising_zksync.sh testnet              # dry run
./ops/deploy_fundraising_zksync.sh testnet --broadcast
```

The script handles the whole path: it checks each allow-listed address is really an ERC-20 on the target network, warns when the admin is an EOA rather than a multisig, moves the L1-only contracts aside so zksolc can compile, gates on `factoryDependencies` being populated, deploys, re-reads the admin role and allow-list from chain, runs a `createFundraiser` smoke test, and verifies source on the explorer.

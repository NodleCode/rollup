# Fundraising — ZKsync Sepolia deployments

Testnet record for the contracts in [`src/fundraising`](../src/fundraising). Chain 300, `https://sepolia.era.zksync.dev`.

## Current

| Contract | Address | Verified |
|---|---|---|
| `FundraiserFactory` | [`0x65d016A46a4339d8111b6006b852027eC8FB1f45`](https://sepolia.explorer.zksync.io/address/0x65d016A46a4339d8111b6006b852027eC8FB1f45#contract) | yes |
| `Fundraiser` (example) | [`0xefbaEaBcA6eb2d53C22644dDCc0759B70D74361c`](https://sepolia.explorer.zksync.io/address/0xefbaeabca6eb2d53c22644ddcc0759b70d74361c#contract) | yes |

- Admin (`DEFAULT_ADMIN_ROLE`): `0xc1F2A7b888e4837aFACfc5E914AB647476ceCD46`
- Allow-listed token: NODL `0x37EDFB6d82c3194e0024c9340aa0993eb42Ec14c`
- `feeBps` 0, `MAX_FEE_BPS` 500, `MAX_DURATION` 31536000

## Superseded

| Contract | Address | Note |
|---|---|---|
| `FundraiserFactory` | [`0x898A7dD2Be10e239c126ff19F99b62223f93279f`](https://sepolia.explorer.zksync.io/address/0x898A7dD2Be10e239c126ff19F99b62223f93279f#contract) | Predates the `groupId` → `externalId` rename, so its `createFundraiser` ABI differs from the current source |
| `Fundraiser` (success path) | [`0x68db256e6042105eff4877fe01d82689714121f4`](https://sepolia.explorer.zksync.io/address/0x68db256e6042105eff4877fe01d82689714121f4#contract) | `Closed`, raised 100 NODL and paid out |
| `Fundraiser` (refund path) | [`0x91305bdd97e1e78259321465ee056065195563fd`](https://sepolia.explorer.zksync.io/address/0x91305bdd97e1e78259321465ee056065195563fd#contract) | `Refunding`, fully refunded |

These are verified and remain on-chain — nothing on ZKsync can be withdrawn once deployed. They have been superseded **functionally as well as in this document**: NODL was de-listed on the superseded factory, so `createFundraiser` now reverts `TokenNotAllowed` and nothing further can be created through it.

De-listing deliberately does not reach the two fundraises already created by it. That is the designed behavior — an allow-list change must never become a freeze switch over funds already escrowed — and it is worth noting that superseding a factory therefore cannot strand anyone's money.

## What was exercised on-chain

Both outcomes, against the superseded factory and re-confirmed against the current one:

- **Target reached** — deposit, unpledge below target, top up to the target, then `unpledge` and `cancel` both reverting `GoalReached`, `finalize` → `Succeeded`, `withdraw` paying the beneficiary in full and leaving the escrow at zero.
- **Target missed** — `finalize` before the deadline reverting `NotFinalizable`; after it, `finalize` → `Refunding`, `refund` returning the contribution exactly, and a second `refund` reverting `NothingToRefund`.

Measured testnet gas: `createFundraiser` 216,226 · `deposit` 120,546.

## Redeploying

See the README section on deploying the fundraising contracts. Note that `forge script --zksync` cannot be run from the repository root — an L1-only contract elsewhere in `src/` uses `EXTCODECOPY`, which EraVM rejects, and `--skip` breaks foundry-zksync's solc/zksolc artifact pairing in scripts.

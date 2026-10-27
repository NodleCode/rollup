# Fundraising — deployments

Deployment record for the contracts in [`src/fundraising`](../src/fundraising).

## Mainnet (ZKsync Era, chain 324)

### Current

| Contract | Address | Verified |
|---|---|---|
| `FundraiserFactory` | [`0x4Ac9b7bE25c701F0a412ADd0500D79d88D005302`](https://explorer.zksync.io/address/0x4Ac9b7bE25c701F0a412ADd0500D79d88D005302#contract) | yes |

- Admin: `0x5e097ac1bcf81e7ff2657045f72caa6cf06486c9`, the 2-of-4 Safe. The deployer holds no role.
- Allow-listed: native USDC `0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4`, then bridged USDC.e `0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4`. Both 6 decimals.
- Fee: 100 bps (1%) to the Safe, **accrued by `withdraw` and pulled with `collectFee`** so the recipient never sits on the beneficiary's critical path.
- `MAX_FEE_BPS` 500, `MAX_DURATION` 31536000. Constants; they can never change.

### Superseded

| Address | Why |
|---|---|
| [`0x408A7A05Ee9e27Af05D9Ba4dc34647f323100841`](https://explorer.zksync.io/address/0x408A7A05Ee9e27Af05D9Ba4dc34647f323100841#contract) | Paid the fee inline inside `withdraw`, reading the recipient live. A recipient unable to receive the token — a blocklisting stablecoin, and USDC is the default — reverted the whole call and stranded the pot until an admin rotated the recipient, putting resolution behind admin cooperation |
| [`0xCFaF15E15696b2e8D19C5B3bFc4Bf091422Dda5e`](https://explorer.zksync.io/address/0xCFaF15E15696b2e8D19C5B3bFc4Bf091422Dda5e#contract) | Took the organizer from `msg.sender`, and carries a zero fee |

Both remain verified and functional; nothing on ZKsync can be withdrawn once deployed. No fundraise created through either is at risk, and none needs migrating — each fundraise is its own contract. De-listing their tokens would stop new ones being created through them, and needs a Safe transaction. Low priority: the API points at the current factory, and `isFundraiser` on it correctly returns false for anything the older ones made.

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

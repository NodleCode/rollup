# User Collections — Mainnet Go-Live Runbook (zkSync Era)

Deploying `CollectionFactory` + `UserCollection721` + `UserCollection1155` to
**zkSync Era mainnet** with source verification. This is a **permanent,
irreversible** deployment — read the prerequisites before running anything.

Companion docs: [`spec/user-collections-specification.md`](spec/user-collections-specification.md),
[`spec/design-and-implementation.md`](spec/design-and-implementation.md),
[`backend-integration.md`](backend-integration.md).

---

## 0. Prerequisites (do not skip)

- [ ] **Code finalized** — PR #113 merged to `main`; deploy from a reviewed `main` commit (note the commit hash in the deployment record).
- [ ] **Audit** — the spec (§7.4) recommends a focused audit of `createCollection*` + both `initialize` flows before mainnet. Decide consciously.
- [ ] **Toolchain pinned** — `hardhat.config.ts` uses **zksolc 1.5.15** (must match what verifies on the explorer).
- [ ] **Deployer funded** — the mainnet deployer EOA holds ETH on zkSync Era for gas.
- [ ] **Governance decided:**
  - `N_FACTORY_OPERATOR` = backend service key (e.g. `0xfe74C8C3f3F1ca3D4b523fd1AE7A3d82dbAc5eCe`).
  - `N_FACTORY_ADMIN` = the admin. **Strongly prefer a Safe multisig.** If launching with the deployer EOA, plan the §6 handoff to a multisig immediately after — the admin controls factory upgrades and impl-pointer swaps (the bytecode of all *future* collections).

---

## 1. Config — `.env-prod`

`.env-prod` is gitignored. Fill in:

```
DEPLOYER_PRIVATE_KEY=<funded mainnet deployer key>      # prefer keystore/hardware
N_FACTORY_ADMIN=<admin: Safe multisig, or deployer EOA for launch>
N_FACTORY_OPERATOR=0xfe74C8C3f3F1ca3D4b523fd1AE7A3d82dbAc5eCe
# CONFIRM_MAINNET=YES   # required to broadcast (see §3)
```

If admin = deployer EOA, set `N_FACTORY_ADMIN` to the deployer's address:
```bash
set -a; source .env-prod; set +a
cast wallet address --private-key $DEPLOYER_PRIVATE_KEY   # use this as N_FACTORY_ADMIN
```

---

## 2. Pre-flight checks

```bash
set -a; source .env-prod; set +a
MRPC=${L2_RPC:-https://mainnet.era.zksync.io}

# deployer funded?
cast balance $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) --rpc-url $MRPC

# operator address valid + intended?
cast to-check-sum-address $N_FACTORY_OPERATOR

# clean build (deploy + verify must share fresh 1.5.15 bytecode)
yarn hardhat clean && yarn hardhat compile
```

---

## 3. Deploy + verify

The deploy script **refuses mainnet without `CONFIRM_MAINNET=YES`** and warns if
`N_FACTORY_ADMIN` is the deployer EOA. To broadcast:

```bash
CONFIRM_MAINNET=YES \
  yarn hardhat deploy-zksync --script DeployCollectionFactory.ts --network zkSyncMainnet
```

This deploys (721 impl → 1155 impl → factory logic → factory `ERC1967Proxy`) and
verifies all four on the mainnet explorer. Capture the four addresses from the
output.

> **Do NOT run a "smoke test" create on mainnet** — it would mint a permanent junk
> collection into the production registry. Your first create should be a real,
> intended collection (see §5).

---

## 4. Post-deploy verification

```bash
PROXY=<factory proxy>; F721=<721 impl>; F1155=<1155 impl>
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000

# roles granted
cast call $PROXY "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $N_FACTORY_ADMIN --rpc-url $MRPC      # true
cast call $PROXY "hasRole(bytes32,address)(bool)" $(cast keccak "OPERATOR_ROLE") $N_FACTORY_OPERATOR --rpc-url $MRPC  # true

# impl pointers wired
cast call $PROXY "erc721Implementation()(address)" --rpc-url $MRPC    # == F721
cast call $PROXY "erc1155Implementation()(address)" --rpc-url $MRPC   # == F1155

# factory EIP-1967 slot points at the logic
cast storage $PROXY 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $MRPC
```
Confirm all four contracts show **verified** on the explorer.

---

## 5. First real collection + record

- Create the first intended collection with the operator key (see
  [`backend-integration.md`](backend-integration.md) §2). Optionally pre-derive
  its address first (§4 of design doc).
- **Record** the deployed addresses + the `main` commit hash in your deployment
  log, and update the backend config (the Hardhat script prints an env block but
  does not write `.env-prod`).

---

## 6. Admin → multisig handoff (if launched with an EOA admin)

Single-step, no timelock — **grant the new admin BEFORE revoking the old**, or you
brick all admin functions:

```bash
# from the current admin (deployer EOA):
cast send $PROXY "grantRole(bytes32,address)" $ADMIN_ROLE $SAFE_MULTISIG --rpc-url $MRPC --private-key $DEPLOYER_PRIVATE_KEY
# confirm the Safe holds it, then drop the EOA:
cast send $PROXY "revokeRole(bytes32,address)" $ADMIN_ROLE $DEPLOYER_ADDR --rpc-url $MRPC --private-key $DEPLOYER_PRIVATE_KEY
```

---

## 7. Operations

| Action | How | Note |
|---|---|---|
| Rotate operator | admin `revokeRole`/`grantRole` on `OPERATOR_ROLE` | Affects who can `createCollection*`. `MINTER_ROLE` on **existing** collections is NOT auto-updated — the creator must grant it to the new operator. |
| Pause new creations | admin revokes all `OPERATOR_ROLE` holders | Existing collections unaffected. |
| Ship a new template | `setImplementation721/1155` (admin) | Future collections only; existing are immutable. |
| Upgrade factory logic | `ops/upgrade_collection_factory_zksync.sh mainnet UPGRADE_FACTORY --broadcast` | UUPS; see the upgrade wrapper. |

There is **no rollback** for already-deployed collections — that is the
immutability guarantee.

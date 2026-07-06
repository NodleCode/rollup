# User Collections — Design & Implementation (ERC1967Proxy architecture)

**Status:** Implemented and deployed (verified on zkSync Sepolia).
**Scope:** `src/collections/` — `CollectionFactory`, `UserCollection721`, `UserCollection1155`.
**Companion:** [`user-collections-specification.md`](user-collections-specification.md) is the authoritative spec (what the system *is*); this doc records *why it's built this way and how*.

> This document consolidates the original `2026-05-08-clones-replacement-design.md`
> and `2026-05-08-clones-replacement-implementation-plan.md` into a single
> as-built reference. The task-by-task plan framing has been dropped (the work
> shipped); the design rationale and implementation details are kept and updated
> to the final state.

---

## 1. Context & decision

### 1.1 The problem we solved

The product requires **per-collection isolation**: every creator's collection is a fully independent contract with its own address, owner, storage, and a **permanent guarantee about its behavior** (spec §1.3). The first design used OpenZeppelin `Clones.clone()` (EIP-1167 minimal proxies).

That is **incompatible with zkSync Era**. Two independent confirmations:

1. **Compiled-artifact evidence.** `Clones.clone()` builds the EIP-1167 runtime blob in memory at runtime, which zksolc never sees statically. The factory's `factoryDependencies` came up empty, so the EraVM `ContractDeployer` could not resolve the deploy.
2. **Matter Labs confirmation.** EraVM uses a different bytecode format and does not support EIP-1167; `Clones.clone()` reverts `ERC1167: create failed` at runtime.

### 1.2 Decision

**Each collection is a per-collection `ERC1967Proxy`, deployed via `new ERC1967Proxy{salt: externalId}(impl, initData)`, where the implementation contracts deliberately do *not* inherit `UUPSUpgradeable`.**

This is the only OZ-canonical pattern that simultaneously:

- **Preserves the immutability promise.** With no `UUPSUpgradeable` on the impl and no `ProxyAdmin`, the EIP-1967 implementation slot is constructor-fixed and unreachable for writes afterward (three independent gates, §3).
- **Compiles cleanly on EraVM.** zksolc statically resolves `ERC1967Proxy`, registers its bytecode hash in the factory's `factoryDependencies`, and lowers `new ERC1967Proxy{salt}(...)` to `ContractDeployer.create2`.
- **Has in-repo precedent.** The factory's *own* proxy is deployed the same way.
- **Enables off-chain address pre-derivation** (§4).

### 1.3 Rejected alternatives

| Pattern | Rejected because |
|---|---|
| `Clones` / EIP-1167 | Incompatible with EraVM (the original blocker). |
| `BeaconProxy` + `UpgradeableBeacon` | Beacon admin can upgrade all collections at once — violates immutability. |
| `TransparentUpgradeableProxy` | Has a `ProxyAdmin` with upgrade authority — violates immutability. |
| `ERC1967Proxy` **with** `UUPSUpgradeable` on the impl | A per-collection admin could upgrade — violates immutability. |
| Forking OZ for a custom minimal proxy | Breaks the OZ-standards-only constraint and burns audit posture. |

---

## 2. Architecture

```
CollectionFactory (UUPS proxy, admin-upgradeable)
  ├── erc721Implementation  ─┐   shared, immutable-per-release impl contracts
  ├── erc1155Implementation ─┘   (deployed once via CREATE, not CREATE2)
  └── createCollection*  ──▶ new ERC1967Proxy{salt: externalId}(impl, initData)
                                  │
                                  ▼
                         Per-collection ERC1967Proxy  (one per collection)
                         delegatecall ─▶ UserCollection721 / UserCollection1155
```

- **`CollectionFactory`** — UUPS-upgradeable (so new templates / fixes ship without disrupting existing creators). Operator-gated creation. Holds the two implementation pointers and the `externalId → collection` registry.
- **`UserCollection721` / `UserCollection1155`** — the shared implementation contracts. Deployed **once** via `CREATE` (sequential nonce, never `CREATE2`). Each per-collection proxy `delegatecall`s into one of them.
- **Per-collection proxies** — one canonical, unmodified OZ `ERC1967Proxy` per collection, with its own storage and address.

### 2.1 Deploy + init flow (atomic)

```
new ERC1967Proxy{salt: externalId}(impl, initData)
  └─ ERC1967Proxy constructor(logic, data)
     └─ ERC1967Utils.upgradeToAndCall(logic, data)
        ├─ SSTORE(EIP-1967 impl slot, logic)
        ├─ emit Upgraded(logic)
        └─ delegatecall logic.initialize(p, operator)   // runs in the proxy's storage
           ├─ grants OWNER_ROLE + MINTER_ROLE to creator
           ├─ grants MINTER_ROLE to operator (msg.sender) + additionalMinters
           ├─ sets baseURI/uri + contractURI
           ├─ sets default royalty (if bps > 0)
           └─ emit Initialized(1)
```

`initData = abi.encodeCall(IUserCollection721.initialize, (p, msg.sender))`, built by the factory. Deploy and init happen in a **single constructor frame** — the collection is never observable on-chain in an uninitialized state, so initialization cannot be front-run.

The factory encodes against the **interface** (`IUserCollection721.initialize`), not the concrete impl, keeping it decoupled from the implementation's code.

### 2.2 Why `salt = externalId`

`externalId` is already the system's uniqueness key (`_checkExternalId` rejects zero and duplicates). Using it as the CREATE2 salt removes the sequential-nonce race for concurrent creations and makes the address a cryptographic commitment to all inputs.

---

## 3. Bytecode permanence (the immutability proof)

Two distinct argument chains, both load-bearing for spec §1.3:

### 3.1 Implementation permanence (`UserCollection721` / `1155`)
- Deployed via **`CREATE` only** (sequential nonce) — never `CREATE2`, so the address can't be re-occupied via salt collision.
- Constructor calls `_disableInitializers()` — the impl singleton can never be initialized directly.
- No `SELFDESTRUCT` in own or inherited code; no `delegatecall` to caller-provided addresses.
- Verified by the opcode-walker tests (`UserCollection721.t.sol` / `UserCollection1155.t.sol`).

### 3.2 Per-collection proxy permanence (`ERC1967Proxy`)
The impl pointer is set once at construction and is unreachable for writes — **three gates that must *all* fail** for an upgrade to slip through:
1. The impls do **not** inherit `UUPSUpgradeable` → no `upgradeToAndCall` / `proxiableUUID` selector exposed.
2. We use `ERC1967Proxy` directly, not `TransparentUpgradeableProxy` → no `ProxyAdmin`.
3. `ERC1967Utils.upgradeToAndCall` is `internal` — callable only from a delegatecall frame whose code is the impl, and by (1) no such frame exists.

Plus: the deployed bytecode is **canonical, unmodified OZ `ERC1967Proxy`** (no `SELFDESTRUCT`), and on EraVM `ContractDeployer` enforces one-deployment-per-address.

### 3.3 EVM-vs-EraVM verification note
The Foundry opcode-walker runs against **EVM** bytecode (Foundry's default backend), not the shipped **EraVM** artifact. That's acceptable because EraVM doesn't support `selfdestruct` at the VM level. As a VM-agnostic guard on the *deployed* artifact, the deploy script (`ops/deploy_collection_factory_zksync.sh`, `verify_implementation_permanence`) asserts the zksolc ABI of both impls exposes **no** `upgradeTo*`/`proxiableUUID` selector — catching any accidental future `UUPSUpgradeable` inheritance.

---

## 4. Address determinism & pre-derivation

Per-collection addresses are deterministic and **pre-derivable off-chain before creation** (validated end-to-end on Sepolia: predicted address == deployed address). The zkSync CREATE2 derivation is a pure function of:

- `sender` = the factory proxy address
- `bytecodeHash` = `utils.hashBytecode(ERC1967Proxy)` — pin to the zksolc version used at deploy time
- `salt` = `externalId`
- `input` = `abi.encode(impl, initData)`, where `initData = initialize(CreateParams, operator)`

Backend flow (`zksync-ethers` `utils.create2Address`):
1. Read `erc721Implementation()` (cache; refresh after admin swaps).
2. Pin `ERC1967Proxy` zk bytecode hash from the factory deploy artifacts.
3. Fix `params`, choose the **current** `OPERATOR_ROLE` holder, generate `externalId`.
4. Compute the address; show it to the user before broadcasting.

**Caveats:** the address is sensitive to *every* input — different params, operator, or impl → different address. The on-chain `collectionByExternalId` mapping stays canonical; pre-derivation is a convenience, not a replacement.

---

## 5. Implementation details (as built)

### 5.1 Roles
- **Factory:** `DEFAULT_ADMIN_ROLE` (admin Safe — upgrades, role admin, impl-pointer swaps), `OPERATOR_ROLE` (backend — `createCollection*`).
- **Per collection:** `OWNER_ROLE` (creator — metadata/royalty/minter management), `MINTER_ROLE` (creator + operator + `additionalMinters`). `OWNER_ROLE` admins `MINTER_ROLE`.
- **Operator auto-grant (§2.3):** the factory passes `msg.sender` into `initialize`, which unconditionally grants it `MINTER_ROLE` — a contract-level invariant, not a backend convention.
- **Role finality (§2.4):** collections are created with **no `DEFAULT_ADMIN_ROLE` holder**. `OWNER_ROLE` is its own non-transferable anchor; owner key loss permanently freezes owner-only functions (tokens/minting unaffected). Intentional.

### 5.2 Custom surface vs OZ
The contracts inherit the full OZ `*Upgradeable` stack (ERC721/1155 + URIStorage/Supply + Burnable + ERC2981 + AccessControl). OZ ships **only `internal` hooks** (`_mint`, `_setURI`, `_baseURI`, `_setDefaultRoyalty`); the public `mint`/`mintBatch`/`setBaseURI`/`setURI`/`setContractURI`/`setDefaultRoyalty`/`lock*`/views are **our** access-gated wrappers. These (plus custom errors/events) are what the interfaces declare — the interfaces never re-declare OZ-provided public methods. `initialize` stays in `IUserCollection721/1155` (the factory encodes against it) but was removed from `ICollectionFactory` (no consumer; it's the `Initializable` deploy hook).

The contracts remain **fully ERC-721 / ERC-1155 compliant** — the custom functions are additive.

### 5.3 Owner-controlled anti-rug locks
`lockMetadata()` / `lockRoyalties()` are one-way, independent switches (emit events for indexers). After `lockMetadata`, `setBaseURI`/`setURI`/`setContractURI` revert; after `lockRoyalties`, `setDefaultRoyalty` reverts. **Unlocked by default** — locking is a deliberate, credible on-chain commitment the creator makes when ready (default-locked would make the setters dead and break reveals/fixes). Not part of any ERC — a custom buyer-protection mechanism.

### 5.4 Metadata-URI convention (option b)
With a non-empty `baseURI`, OZ `ERC721URIStorage` resolves `tokenURI(id) = baseURI + perTokenSuffix`. Callers pass a **relative suffix** to `mint`/`mintBatch`. The per-token suffix is fixed at mint, but the shared `baseURI` is mutable until `lockMetadata` — so **only `metadataLocked` provides a freeze guarantee**, not the per-token suffix alone (validated on-chain: `tokenURI(0) = "ipfs://smoke/1.json"`).

### 5.5 Security hardening (review findings, all applied)
- **Royalty observability** — `setDefaultRoyalty` emits `DefaultRoyaltyUpdated` (ERC-2981 is event-less) so indexers can track royalty changes.
- **`mintBatch` reentrancy** — the 721 batch reserves its ID range *before* the `_safeMint` loop, so a reentrant mint takes a fresh ID instead of relying on OZ's duplicate-mint revert (regression test included).
- **Factory invariant** — the `externalId → collection` registry write trails the deploy+init and is reentrancy-safe *only* while `initialize` makes no external calls; pinned in a code comment for future impls.
- **Fail-closed inputs** — `royaltyBps > 0` with a zero recipient, or `> 10000`, revert the whole `createCollection*` (OZ ERC-2981).

### 5.6 Storage layout
Under OZ v5 ERC-7201 namespaced storage, the inherited mixins occupy keccak-derived slots; the contracts' own variables start at slot 0. The two lock bools pack into one slot. `__gap` reserves headroom for future appended fields when an admin swaps the impl pointer for future collections.

---

## 6. Testing

- **85 tests**, one file per contract + an integration test + the proxy-permanence test. ~97% line coverage on `src/collections/`.
- **Permanence** — opcode-walker (no `0xff`) over both impls and the canonical `ERC1967Proxy`; no-upgrade-selector ABI checks.
- **Address determinism** — `test_createCollection*_addressMatchesCreate2Derivation` (EVM CREATE2 formula on the Foundry backend; the EraVM formula is covered by the on-chain smoke test).
- **Atomicity** — `Upgraded(impl)` then `Initialized(1)` asserted inside the same `createCollection*` tx; immediate same-tx mint via the operator auto-grant.
- **Gap coverage** — initialize guard branches, cross-standard `externalId` collision, `mintBatch` boundary (exactly `MAX_BATCH`) + empty, reentrancy regression.

---

## 7. Deployment & verification

Two deploy paths exist; **Hardhat is preferred** because it source-verifies the factory.

### 7.1 Foundry path
`ops/deploy_collection_factory_zksync.sh <testnet|mainnet> [--broadcast]` — `--zksync` compile (with L1-file move/restore), `factoryDependencies` gate, ABI-permanence gate, asserting post-deploy checks, mainnet confirmation, and a post-broadcast `createCollection721` smoke test. Source verification via `ops/verify_zksync_contracts.py`.

### 7.2 Hardhat path (preferred for verification)
`yarn hardhat deploy-zksync --script DeployCollectionFactory.ts --network zkSyncSepoliaTestnet` — deploys all four (721 impl → 1155 impl → factory logic → factory `ERC1967Proxy`) and verifies via `hre.run("verify:verify")`.

**Run a clean build first** (`yarn hardhat clean && yarn hardhat compile`) so the deploy and the verify step use the *same* fresh bytecode — stale artifacts otherwise cause a self-mismatch at verification time.

### 7.3 The verification tooling split (important)
Neither tool verifies all four contracts alone:
- **Python standard-JSON helper** verifies plain contracts and the bare `ERC1967Proxy`, but **cannot verify `CollectionFactory`** — it carries `factoryDependencies` (the `ERC1967Proxy` bytecode hash) which the standard-JSON payload doesn't convey.
- **Hardhat `hardhat-zksync-verify`** conveys `factoryDeps`, so it verifies `CollectionFactory` + both impls, and (on a clean build) the proxy too via its proxy auto-detection.

They **can't be mixed** on one deployment: hardhat and foundry must use the same zksolc, and the toolchains diverge (zksolc/zkvm-solc minor versions). `hardhat.config.ts` is pinned to **zksolc 1.5.15** to match foundry-zksync and the explorer verification settings. `ERC1967Proxy` must be loaded/verified by its **fully-qualified** `@openzeppelin/contracts/...` name (the upgradable plugin ships a second one → HH701).

**Result on Sepolia:** all four contracts deploy and source-verify; smoke test (`createCollection721` → mint) passes end-to-end.

### 7.4 Environment
`DEPLOYER_PRIVATE_KEY`, `N_FACTORY_ADMIN`, `N_FACTORY_OPERATOR` (admin should be a multisig and operator a separate backend key on mainnet; an all-in-one EOA is fine for testnet).

---

## 8. Upgrades & storage-layout safety

| Operation | How |
|---|---|
| Upgrade factory logic | `ops/upgrade_collection_factory_zksync.sh <net> UPGRADE_FACTORY --broadcast` (admin key) — UUPS `upgradeToAndCall`. |
| Ship a new 721/1155 template | `… SET_IMPL_721` / `SET_IMPL_1155` — affects *future* collections only. |
| Rotate operator | admin `revokeRole`/`grantRole` on `OPERATOR_ROLE`. |
| Pause creation | admin revokes all `OPERATOR_ROLE` holders. |

The upgrade wrapper runs the `--zksync` compile, artifact gates, an admin-key pre-check, mainnet guard, post-broadcast asserts (slot/role/pointer preservation), and source verification.

**Storage-layout safety is on-demand, not a committed baseline.** We do not keep static `*.v1.json` snapshots (they go stale and only mirror git). Before a factory upgrade, regenerate the previous layout from the released ref and diff it (`forge inspect <C> storageLayout --json`, projecting `label/slot/offset/type`); only appended fields consuming `__gap` are safe. For stronger guarantees, wire up the OZ / zkSync upgradable plugin's automated validation. There is no rollback path for already-deployed collections — that is the immutability guarantee.

---

## 9. Audit posture

- New contracts inherit only OZ-audited `*Upgradeable` primitives; the custom surface is small (factory glue, lock flags, role wiring, batch caps).
- Audit must confirm `import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol"` resolves to canonical OZ at the lockfile-pinned version (a fork/remap would invalidate the permanence proof).
- Recommended focus: `CollectionFactory.createCollection*` and both `initialize` flows.

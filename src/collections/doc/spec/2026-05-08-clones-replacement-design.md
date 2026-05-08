# Collections — Replacing `Clones.clone()` for zkSync Era Compatibility

**Date:** 2026-05-08
**Status:** Design (approved through brainstorming; not yet implemented)
**Scope:** `src/collections/` user-collections system
**Driver:** zkSync Sepolia deploy attempt revealed `Clones.clone()` is incompatible with EraVM at runtime
**Related spec:** `src/collections/doc/spec/user-collections-specification.md`

---

## 1. Context

### 1.1 What we tried

Running `./ops/deploy_collection_factory_zksync.sh testnet` against zkSync Sepolia (RPC: `https://rpc.ankr.com/zksync_era_sepolia`, chain id 300). The factory + implementations deploy themselves succeeded conceptually — they use Solidity `new`, which zksolc handles correctly — but the per-collection clone path is broken for two independently-confirmed reasons:

1. **Compiled-artifact evidence.** `zkout/CollectionFactory.sol/CollectionFactory.json` shows `factoryDependencies: {}`. The compiled zk hashes for `UserCollection721` (`010005db…`) and `UserCollection1155` (`0100053b…`) appear zero times in the factory bytecode. zksolc only registers a contract as a `factoryDep` when it sees `type(C).creationCode` or `new C()` *statically* — `Clones.clone(impl)` builds the EIP-1167 runtime blob in memory at runtime, which zksolc never sees. Without a registered factoryDep, EraVM's `ContractDeployer` cannot resolve the deploy.

2. **Matter Labs confirmation.** From zksync-developers discussion #561, an ML maintainer: *"We don't currently support ERC1167 since we have a different bytecode format."* Production users hitting `Clones.clone()` see `execution reverted: ERC1167: create failed`. Discussions #91, #166, and #561 all end with users refactoring away from `Clones`.

### 1.2 What's load-bearing

The user-collections spec (`src/collections/doc/spec/user-collections-specification.md` §1.3) sells per-collection bytecode immutability as the product:

> *"Already-deployed clones cannot be upgraded — buyers and creators retain a permanent guarantee about each collection's behavior."*

This is reinforced in §1.4 row 7, §2.3, §6.3, §7.1, and §7.2 row 15. Any replacement for `Clones.clone()` must preserve this property; admin-pushable upgrades to existing collections (e.g. a `BeaconProxy` fleet upgrade) are explicitly out of scope.

The user has additionally constrained the design to canonical OpenZeppelin patterns — no bespoke proxy or upgrade machinery.

---

## 2. Decision

**Per-collection `ERC1967Proxy` deployed via `new` with `salt: externalId`, where the implementation contracts do not inherit `UUPSUpgradeable`.**

```solidity
// inside CollectionFactory.createCollection721 / createCollection1155
bytes memory initData = abi.encodeCall(
    IUserCollection721.initialize, (p, msg.sender)
);
collection = address(new ERC1967Proxy{salt: externalId}(_erc721Implementation, initData));
```

This is the only OZ-standard pattern that simultaneously:

1. **Preserves the §1.3 immutability promise.** `ERC1967Proxy` is a pure transport. Without `UUPSUpgradeable` on the impl and without a `ProxyAdmin` pattern, the EIP-1967 implementation slot is constructor-fixed and unreachable for write afterward. Three independent gates (no `upgradeToAndCall` selector on the impl, no `ProxyAdmin` slot pattern, `ERC1967Utils.upgradeToAndCall` is `internal` and only callable from inside an impl delegatecall frame that doesn't exist) all have to fail simultaneously for an upgrade to slip through.

2. **Compiles cleanly on EraVM.** zksolc statically resolves `ERC1967Proxy`, registers its bytecode hash in `CollectionFactory.factoryDependencies`, and lowers `new ERC1967Proxy{salt}(...)` to `ContractDeployer.create2(salt, ERC1967ProxyHash, abi.encode(impl, initData))`. This is the same code path zksolc takes for `new UserCollection721()` in the deploy script — already proven working.

3. **Has direct precedent in this repo.** `script/DeployCollectionFactoryZkSync.s.sol:72-75` already deploys the *factory itself* as `new ERC1967Proxy(factoryImpl, initData)` on zkSync Era, with atomic delegatecall init in the constructor. The refactor applies the exact same pattern one layer down per collection.

4. **Enables off-chain address pre-derivation.** With `salt: externalId`, the collection address is a pure function of `(factory, externalId, impl, initData, ERC1967Proxy zk bytecode hash)` — all inputs the backend already controls. The `_collectionByExternalId` mapping remains the canonical on-chain registry; pre-derivation is a redundant lookup path.

### 2.1 Patterns explicitly rejected

| Pattern | Rejected because |
|---|---|
| `BeaconProxy` + `UpgradeableBeacon` | Beacon admin can upgrade all collections at once. Violates §1.3. |
| `TransparentUpgradeableProxy` | Has a `ProxyAdmin` with upgrade authority. Violates §1.3. |
| `ERC1967Proxy` *with* `UUPSUpgradeable` on impl | Per-collection admin (whoever holds DEFAULT_ADMIN_ROLE on the impl) could upgrade. Violates §1.3. |
| Forking OZ to make a custom minimal proxy | Violates the OZ-standards-only constraint and burns audit posture. |
| Full Hardhat zkSync deploy via `factory_deps` JSON | Violates the OZ-standards-only constraint; we don't use Hardhat anywhere else in this repo. |

---

## 3. Detailed Design

### 3.1 Factory state & interface — unchanged

`CollectionFactory.sol` storage layout, public selectors, and external behavior all stay identical. The committed `CollectionFactory.v1.json` baseline remains valid.

```solidity
address private _erc721Implementation;
address private _erc1155Implementation;
mapping(bytes32 externalId => address collection) private _collectionByExternalId;
uint256[47] private __gap;
```

`setImplementation721` / `setImplementation1155` / `erc721Implementation()` / `erc1155Implementation()` / `getCollectionByExternalId(...)` keep the same selectors, the same gating, and the same revert conditions (`ZeroAddress`, `NotAContract(addr)`, `DuplicateExternalId(extId)`).

The `setImplementation*` semantics are unchanged: those setters affect *future* collections only, because the impl address gets baked into each new `ERC1967Proxy`'s EIP-1967 slot at construction and there is no path to rewrite that slot afterward.

### 3.2 Deploy path

#### 3.2.1 Imports

```diff
- import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
+ import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
```

#### 3.2.2 `createCollection721` body

```diff
  function createCollection721(CreateParams721 calldata p, bytes32 externalId)
      external onlyRole(OPERATOR_ROLE) returns (address collection)
  {
      _checkExternalId(externalId);

-     collection = Clones.clone(_erc721Implementation);
-     IUserCollection721(collection).initialize(p, msg.sender);
+     bytes memory initData = abi.encodeCall(
+         IUserCollection721.initialize, (p, msg.sender)
+     );
+     collection = address(
+         new ERC1967Proxy{salt: externalId}(_erc721Implementation, initData)
+     );

      _collectionByExternalId[externalId] = collection;
      emit CollectionCreated(p.owner, collection, Standard.ERC721, externalId);
  }
```

`createCollection1155` takes the same shape with `IUserCollection1155.initialize` and `_erc1155Implementation`.

#### 3.2.3 Why salt = externalId

- `externalId` is already a uniqueness key in the system (`_checkExternalId` enforces no duplicates).
- Removes the sequential-nonce race that would otherwise affect concurrent creations.
- Makes the address a cryptographic commitment to all inputs — same `(externalId, impl, params, operator)` always yields the same address. Different inputs → different address.

#### 3.2.4 zkSync compatibility — the three things that have to work, all of which already do

1. **`new ERC1967Proxy{salt}(impl, initData)` compiles cleanly.** zksolc registers `ERC1967Proxy`'s bytecode hash in the factory's `factoryDependencies`.
2. **`delegatecall` from inside a constructor works on EraVM.** `ERC1967Utils.upgradeToAndCall` does this, and the factory's own deploy already uses this pattern in `script/DeployCollectionFactoryZkSync.s.sol`.
3. **The impl is reached by address, not by factoryDep.** `_erc721Implementation` is passed at runtime, and EraVM resolves the delegatecall target by looking up that address's bytecode on-chain — already registered when the deployer EOA ran `new UserCollection721()` at top level.

### 3.3 Initialization flow

```
new ERC1967Proxy{salt: externalId}(impl, initData)
  └── ERC1967Proxy constructor(address logic, bytes _data)
      └── ERC1967Utils.upgradeToAndCall(logic, _data)
          ├── SSTORE(EIP_1967_IMPL_SLOT, logic)
          ├── emit Upgraded(logic)
          └── if (_data.length > 0)
              └── Address.functionDelegateCall(logic, _data)
                  └── UserCollection721.initialize(p, operatorMinter)
                      ├── grants DEFAULT_ADMIN_ROLE / OWNER_ROLE to p.owner
                      ├── grants MINTER_ROLE to additionalMinters + operatorMinter
                      ├── sets _baseTokenURI / _contractURI
                      ├── sets default royalty (if p.royaltyBps > 0)
                      └── emit Initialized(1)
```

Atomic single constructor frame. If any step reverts, the whole `new ERC1967Proxy` reverts and no contract is deployed. Stronger atomicity than the current two-step `Clones.clone()` + `initialize` pattern.

`_disableInitializers()` in `UserCollection721` / `UserCollection1155` constructors stays unchanged — it hardens the *impl singleton* against ever being directly initialized. The `initializer` modifier on `initialize` still flips `_initialized = 1` in the *proxy's* storage during the constructor's delegatecall, so re-init reverts with OZ's `InvalidInitialization`.

The operator address travels into `initialize` as the `operatorMinter` parameter, encoded at the call site (`abi.encodeCall(initialize, (p, msg.sender))` in the factory's frame, where `msg.sender` is the OPERATOR_ROLE caller). Identical §2.3 auto-grant semantics.

### 3.4 Address determinism

Inputs to the per-collection address derivation:

```
addr = ZK_CREATE2( factory, externalId, ERC1967ProxyZkHash, keccak256(abi.encode(impl, initData)) )
```

Where:
- `factory` = the proxy address of `CollectionFactory` (constant per environment).
- `externalId` = the salt, supplied by the operator at create time.
- `ERC1967ProxyZkHash` = the zksolc-emitted bytecode hash of `@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol`. **Must be pinned in backend artifacts at the version used at factory deploy time.**
- `impl` = the current `_erc721Implementation` (or 1155). Reads via `erc721Implementation()` / `erc1155Implementation()`.
- `initData` = `abi.encodeCall(initialize, (p, operator))`.

Backend pre-derivation flow:

1. Read `_erc721Implementation` once (cache; refresh after admin upgrades).
2. Pin `ERC1967ProxyZkHash` from the factory deploy artifacts.
3. Generate `externalId`.
4. Construct `params` and select the operator address.
5. Compute the address using `zksync-ethers` `utils.create2Address`.
6. Submit `createCollection721(params, externalId)` from the operator key.
7. Verify the on-chain `_collectionByExternalId[externalId]` matches the precomputed address (sanity check, not load-bearing).

#### 3.4.1 Caveats (operational)

1. **Address is sensitive to every input.** Same `externalId` but different `params` → different address. Backends must fix params before generating the externalId.
2. **Operator rotation note (§2.3).** Because `msg.sender` enters `initData`, two operators calling with the same externalId would derive different addresses. In practice `_checkExternalId` rejects the second call (`DuplicateExternalId`); pre-derivation must use the *current* OPERATOR_ROLE holder.
3. **`_collectionByExternalId` mapping stays canonical.** Pre-derivation is a redundant off-chain lookup path, not a replacement for the on-chain registry.
4. **zk bytecode hash pinning.** Upgrading zksolc can change `ERC1967Proxy`'s zk bytecode hash. Pin the hash to the version used at factory deploy time and only refresh during a coordinated tooling bump.

### 3.5 Bytecode-permanence invariants

Existing §7.2 row 15 splits into two clearer sub-rows:

#### 3.5.1 Row 15a — Implementation bytecode permanence (unchanged)

`UserCollection721` / `UserCollection1155` are deployed exactly as before:
- Top-level `new` from the deployer EOA in `DeployCollectionFactoryZkSync.s.sol` → sequential `CREATE`, never `CREATE2`.
- `_disableInitializers()` in their constructors.
- No `SELFDESTRUCT` opcode anywhere in own or inherited code.
- No `delegatecall` to caller-provided addresses.

The opcode-walker bytecode-permanence test continues to run against both impls, with the same assertion set.

#### 3.5.2 Row 15b — Per-collection proxy permanence (new)

Per-collection proxies are deployed via `CREATE2` (`{salt: externalId}`). Permanence comes from a different chain of arguments:

1. **The deployed bytecode is canonical OZ `ERC1967Proxy`, used unmodified.** Imported from `@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol`, no fork, no override. `ERC1967Proxy` and its dependency `Proxy.sol` contain no `SELFDESTRUCT`.
2. **The impl pointer in the EIP-1967 slot is set exactly once at construction and is unreachable for write afterward.** Three independent gates, all of which would have to fail simultaneously for an upgrade to slip through:
   - **(2a)** The implementations do not inherit `UUPSUpgradeable` → no `upgradeToAndCall` selector exposed by the impl.
   - **(2b)** We use `ERC1967Proxy` directly, not `TransparentUpgradeableProxy` → no `ProxyAdmin`.
   - **(2c)** `ERC1967Utils.upgradeToAndCall` is `internal`, only callable from a delegatecall frame whose code is the impl — and since (2a) holds, no caller can ever reach it.
3. **`CREATE2` re-occupation is foreclosed.** For an attacker to re-occupy a deployed collection's address via salt collision, the existing contract would have to first cease to exist (`SELFDESTRUCT`) — but `ERC1967Proxy` has no such opcode (per (1)) and the impl pointer can't be swapped to one that does (per (2)). On EraVM, `ContractDeployer` additionally enforces "one deployment per address" at the protocol layer; the in-bytecode argument alone is sufficient.

### 3.6 Spec doc deltas

#### 3.6.1 Stays verbatim (with single-word `clones → collections` substitution)

§1.3 immutability promise, §2 entire roles/auth model, §3.5/§3.6 method signatures and lock semantics, §5 mint flows, §6.1 factory storage layout, §6.3 storage-layout discipline, §7.1 trust assumptions, §7.3/§7.4 out-of-scope and audit posture, §9.1 "Deploy `UserCollection721` implementation via `CREATE` (sequential nonce, **never** `CREATE2`)" rule.

#### 3.6.2 Substantive content rewrites

| Section | Current | Updated |
|---|---|---|
| §1.1 line 46 | "deploys cheap clones of fixed-behavior implementation contracts" | "deploys per-collection `ERC1967Proxy` instances pointing at fixed-behavior implementation contracts" |
| §1.2 mermaid diagram | subgraph `"User Collections (EIP-1167 minimal proxies)"`, arrow labels `"Clones.clone"` | subgraph `"User Collections (ERC1967Proxy per collection)"`, arrow labels `"new ERC1967Proxy{salt: externalId}"` |
| §1.3 core components table | "EIP-1167 clone target" rows for 721/1155 | "`ERC1967Proxy` implementation" |
| §1.4 row 2 (Deployment model) | "EIP-1167 minimal proxy clones for both standards" | "Per-collection `ERC1967Proxy` deployed via `CREATE2` with `externalId` salt; implementations deployed via `CREATE` only" |
| §1.4 row 7 (Upgradeability) | "Clones: immutable; admin can swap implementation pointer for *future* clones only" | "Per-collection proxies: immutable (impls do not inherit `UUPSUpgradeable`, no admin slot); admin can swap implementation pointer for *future* collections only" |
| §3.4 createCollection atomic-flow bullet | `Clones.clone(impl) → clone.initialize(p, msg.sender) → collectionByExternalId[externalId] = clone` | `abi.encodeCall(initialize, (p, msg.sender)) → new ERC1967Proxy{salt: externalId}(impl, initData) → collectionByExternalId[externalId] = collection`; init is atomic in the proxy constructor |
| §4.1 sequence diagram | `FAC->>CL: Clones.clone(...)` and a separate `CL->>CL: initialize(...)` | Single `FAC->>CL: new ERC1967Proxy{salt}(impl, encodeCall(initialize,(p,msg.sender)))`, with note that `Upgraded(impl)` then `Initialized(1)` events fire inside the constructor |
| §4.2 Atomicity | Current text emphasizes 2-step atomicity within the same tx | Strengthen: deploy + init are now a single constructor frame, no transient uninitialized window |
| §4.4 Gas Profile | "Deploys an EIP-1167 minimal proxy (~45,000 gas on EVM L1 baseline)" | Delete the L1 anchor; replace with "On zkSync Era, per-collection deploy is dominated by `ContractDeployer.create2` + the constructor's delegatecall init; gas measured by `Collections.integration.t.sol` and quoted from the test output (target: < 1.5M gas on zkSync Sepolia for a typical `createCollection721`)" |
| §6.2 Clone Storage opening sentence | "Each clone owns its full storage independently of other clones (EIP-1167 proxies `delegatecall` logic but persist state in the proxy's own address)." | "Each collection owns its full storage independently (`ERC1967Proxy` `delegatecall`s logic at the address in the EIP-1967 implementation slot but persists state in the proxy's own address)." |
| §6.2 gap reservation note | s/clones/collections/g | (same point holds — the EIP-1967 slot doesn't fight the gap because it's at a fixed namespaced slot, not slot N) |

#### 3.6.3 Additions

1. **§1.4 row 7 footnote** explaining the OZ-standards rationale: "We use `ERC1967Proxy` directly (not `TransparentUpgradeableProxy`, not `BeaconProxy`) because the implementation contracts deliberately do not inherit `UUPSUpgradeable`. With no upgrade selector exposed and no admin slot pattern, the proxy's implementation pointer is constructor-fixed and the per-collection immutability promise is enforced by code that already exists in the OZ canonical libraries — no custom upgrade gating needed."
2. **§4.5 (new sub-section) Address Determinism** — documents the salt = externalId convention, derivation inputs, and the four caveats from §3.4.1.
3. **§7.2 row 15 split into 15a / 15b** as specified in §3.5.
4. **§7.2 new row 16**: "Audit must verify the imported `ERC1967Proxy` resolves to canonical OZ at the lockfile-pinned version; remappings or forks of OZ proxy contracts are out of band and would invalidate the bytecode-permanence proof."
5. **§9.1 deploy-script step 4 note**: clarify that the existing `ERC1967Proxy(factoryImpl, ...)` construction in `DeployCollectionFactoryZkSync` is the *factory's own* proxy and does not change. The new per-collection `ERC1967Proxy` instances are deployed by the *factory itself* at `createCollection*` time, not by the deploy script.

#### 3.6.4 Vocabulary pass

Mechanical `s/clone/collection/` and `s/clones/collections/` pass throughout the doc, except:
- Keep "EIP-1167" mentions in §1.4 row 7 footnote where we explain why we moved away from it.
- Keep the historical comparison in §4.4.

### 3.7 Storage-layout baselines

**No baseline JSON changes. v1 stays v1 across all three files.**

| File | Status | Why |
|---|---|---|
| `src/collections/layouts/CollectionFactory.v1.json` | Unchanged | Storage fields identical; refactor is in function bodies only. |
| `src/collections/layouts/UserCollection721.v1.json` | Unchanged | Implementation contract isn't touched. |
| `src/collections/layouts/UserCollection1155.v1.json` | Unchanged | Same. |

The EIP-1967 implementation slot lives at the keccak-derived address `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` — deliberately namespaced, far above any slot index Solidity's allocator would reach. Cannot collide with slots 0..N. So even though every per-collection proxy now stores a non-zero value at that slot (where EIP-1167 minimal proxies stored nothing), it has zero impact on the impl-side layout that `forge inspect storage-layout` produces.

#### 3.7.1 §9.4 runbook addition (one-line `cast` check)

```bash
EIP1967_IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
cast storage "$COLLECTION_ADDR" "$EIP1967_IMPL_SLOT" --rpc-url "$L2_RPC"
# expected: padded address of UserCollection721 (or 1155) impl
```

Same shape as the existing factory-proxy check in `ops/deploy_collection_factory_zksync.sh:248-257`, just reused per collection.

### 3.8 Test impact

#### 3.8.1 Stays green untouched

- All `UserCollection721.t.sol` and `UserCollection1155.t.sol` (impls untouched).
- `CollectionFactory.t.sol` unit tests for `initialize`, `setImplementation*`, `_checkExternalId`, all UUPS upgrade tests on the factory itself.
- The opcode-walker bytecode-permanence test on the impls.

#### 3.8.2 Assertions to update

- **Bytecode-size assertions on the deployed collection.** Switch from EIP-1167's 45-byte runtime to a `> 0` sanity check or the exact `ERC1967Proxy` runtime size from `vm.getCode("ERC1967Proxy")`.
- **EIP-1967 impl slot read post-create.** Replace any "slot is zero" assertion with `vm.load(collection, EIP1967_IMPL_SLOT) == _erc721Implementation()`. This becomes a meaningful positive check instead of vacuously zero.
- **Sequence-of-events tests.** Add `Upgraded(impl)` to the expected emit list in `createCollection*` integration tests (it now fires before `Initialized(1)`, both inside the constructor).

#### 3.8.3 New tests to add

1. **Deterministic address derivation** in `CollectionFactory.t.sol`:
   ```solidity
   function test_createCollection721_addressMatchesCreate2Derivation() public {
       bytes32 extId = keccak256("test-collection");
       bytes memory initData = abi.encodeCall(
           IUserCollection721.initialize, (params, operator)
       );
       address predicted = Create2.computeAddress(
           extId,
           keccak256(abi.encodePacked(
               type(ERC1967Proxy).creationCode,
               abi.encode(impl721, initData)
           )),
           address(factory)
       );
       vm.prank(operator);
       address actual = factory.createCollection721(params, extId);
       assertEq(actual, predicted, "CREATE2 derivation must match");
   }
   ```
   Uses the EVM `CREATE2` formula because Foundry's default backend is EVM. The zkSync formula differs and is covered by the end-to-end integration test in §3.8.3 point 5.

2. **Atomic init**: `vm.expectEmit` for both `Upgraded(impl)` and `Initialized(1)` inside the same `createCollection721` tx, then immediately call `mint` on the returned collection in the same test (operator already has `MINTER_ROLE` from auto-grant) and assert success — proves no transient uninitialized window.

3. **No upgrade selector on impls** in `UserCollection721.t.sol` and `UserCollection1155.t.sol`:
   ```solidity
   function test_implementationHasNoUpgradeSelectors() public {
       address impl = address(new UserCollection721());
       (bool ok1, ) = impl.staticcall(abi.encodeWithSelector(0x52d1902d)); // proxiableUUID
       (bool ok2, ) = impl.staticcall(abi.encodeWithSelector(0x4f1ef286, address(0), bytes(""))); // upgradeToAndCall
       assertFalse(ok1, "impl must not expose proxiableUUID");
       assertFalse(ok2, "impl must not expose upgradeToAndCall");
   }
   ```

4. **ERC1967Proxy bytecode permanence** (new file `test/collections/ERC1967Proxy.permanence.t.sol`): opcode-walker over `vm.getCode("ERC1967Proxy")` runtime, asserting no `0xff` (SELFDESTRUCT) and no delegatecall to caller-provided addresses.

5. **End-to-end zkSync Sepolia smoke test** (new step in `ops/deploy_collection_factory_zksync.sh` post-broadcast): `cast send` a `createCollection721` from the operator key; assert non-empty `code` at the deployed address, EIP-1967 impl slot equals expected impl, and an immediate `cast send mint(...)` succeeds. This is the empirical end-to-end check that the zksolc-compiled output works at runtime on EraVM — the precise gap that left us with a passing dry-run but a broken `Clones.clone()` flow originally.

#### 3.8.4 CI build-artifact check (not a Foundry test)

Add to the deploy script (or the existing CI workflow):

```bash
test "$(jq -r '.factoryDependencies | length' zkout/CollectionFactory.sol/CollectionFactory.json)" -gt 0
```

If `factoryDependencies` is ever empty again on the factory, the build fails immediately — the smoking-gun signal we used to detect the original `Clones.clone()` problem becomes a permanent guardrail.

#### 3.8.5 Coverage

Current 96.91%. The refactor adds new unit tests and changes a few lines of `createCollection*`, so coverage should increase or stay flat. Maintain the existing 95% CI floor.

### 3.9 Audit checklist additions

- "Confirm `import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';` resolves to canonical OZ at the locked version (no remappings override)."
- "Assert `UserCollection721` / `UserCollection1155` ABIs do not include `upgradeTo(address)`, `upgradeToAndCall(address,bytes)`, or `proxiableUUID()` (selector `0x52d1902d`)."
- "Run opcode-walker on `zkout/ERC1967Proxy.sol/ERC1967Proxy.json` runtime bytecode; assert no `0xff` (SELFDESTRUCT)."

---

## 4. Files to Touch

### 4.1 Modified

- `src/collections/CollectionFactory.sol` — imports + body of `createCollection721` / `createCollection1155`. ~10 lines net change.
- `src/collections/doc/spec/user-collections-specification.md` — vocabulary pass + substantive deltas in §3.6.
- `ops/deploy_collection_factory_zksync.sh` — add the post-broadcast end-to-end smoke test (§3.8.3 point 5) and the `factoryDependencies` CI build-artifact check (§3.8.4).
- `test/collections/CollectionFactory.t.sol` — assertions per §3.8.2; new tests per §3.8.3 points 1–2.
- `test/collections/UserCollection721.t.sol` — new test per §3.8.3 point 3.
- `test/collections/UserCollection1155.t.sol` — new test per §3.8.3 point 3.
- `test/collections/Collections.integration.t.sol` — sequence-of-events updates per §3.8.2.

### 4.2 Added

- `test/collections/ERC1967Proxy.permanence.t.sol` — opcode-walker for `ERC1967Proxy` (§3.8.3 point 4).

### 4.3 Unchanged

- `src/collections/UserCollection721.sol`
- `src/collections/UserCollection1155.sol`
- `src/collections/interfaces/*.sol`
- `src/collections/layouts/*.v1.json` (all three baselines)
- `script/DeployCollectionFactoryZkSync.s.sol`
- `script/UpgradeCollectionFactory.s.sol`

---

## 5. Open Questions / Out of Scope

- **Gas benchmarking on zkSync Sepolia.** §4.4 of the spec needs a real gas number. We'll pull it from the integration test's first run after the refactor lands and embed it in the doc at that point — not blocking on this design.
- **Backend pre-derivation library.** The TS/JS code that computes `zksync-ethers utils.create2Address(...)` for collections is out of scope for this Solidity-side spec. Tracked separately in the backend repo.
- **Whether to support deterministic addresses with operator-rotation tolerance** (e.g. by encoding only `(params, operator=null)` in the salt-derivation while still passing the actual operator at runtime). Possible future enhancement; not needed for v1 of this refactor.

---

## 6. Approvals

- Brainstorming dialogue completed 2026-05-08; user approved each of the seven design sections (factory state, deploy path, init flow, bytecode permanence, spec deltas, storage baselines, test impact).
- Decision pinned in engram memory: `collections-immutability-and-oz-standards` (immutability is hard requirement, OZ-standards-only); `zksync-clones-incompatibility` (root-cause analysis of why `Clones.clone()` fails on EraVM).

Next step after spec sign-off: implementation plan via the `superpowers:writing-plans` skill.

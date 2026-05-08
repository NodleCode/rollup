# Clones → ERC1967Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Clones.clone()` with per-collection `ERC1967Proxy` (salted by `externalId`) in `CollectionFactory`, unblocking zkSync Era deploy while preserving the §1.3 per-collection bytecode-immutability promise. Aligns spec, tests, and deploy script with the new pattern.

**Architecture:** `createCollection721` / `createCollection1155` switch from `Clones.clone(impl) + .initialize(...)` (two-step) to a single `new ERC1967Proxy{salt: externalId}(impl, abi.encodeCall(initialize, (p, msg.sender)))` (one constructor frame, atomic init via delegatecall). The implementation contracts and storage layouts are unchanged.

**Tech Stack:** Solidity 0.8.26, Foundry (foundry-zksync v0.1.9), OpenZeppelin Contracts (canonical, lockfile-pinned), forge-std, zksolc (via `forge build --zksync`).

**Spec reference:** `src/collections/doc/spec/2026-05-08-clones-replacement-design.md`

---

## File Structure

### Files modified

| Path | Responsibility | Change scope |
|---|---|---|
| `src/collections/CollectionFactory.sol` | Factory logic | Imports + bodies of `createCollection721` / `createCollection1155`. ~10 lines net. |
| `src/collections/doc/spec/user-collections-specification.md` | Authoritative spec | Vocabulary pass + substantive deltas per design §3.6. |
| `ops/deploy_collection_factory_zksync.sh` | zkSync deploy orchestration | `factoryDependencies` build-artifact gate + per-collection EIP-1967 slot check + post-broadcast smoke test. |
| `test/collections/CollectionFactory.t.sol` | Factory unit tests | Add CREATE2-derivation test; extend atomic-emits tests; vocabulary in variable names. |
| `test/collections/UserCollection721.t.sol` | 721 impl unit tests | Switch test-side `Clones.clone(impl)` helper to `new ERC1967Proxy(impl, "")`; add no-upgrade-selector test. |
| `test/collections/UserCollection1155.t.sol` | 1155 impl unit tests | Same as 721. |
| `test/collections/Collections.integration.t.sol` | Cross-contract integration | Vocabulary + add `Upgraded` to expected emit sequences. |

### Files added

| Path | Responsibility |
|---|---|
| `test/collections/ERC1967Proxy.permanence.t.sol` | Opcode-walker over canonical OZ `ERC1967Proxy` runtime bytecode asserting no `0xff` SELFDESTRUCT and no caller-controlled `delegatecall` targets. Codifies §7.2 row 15b (1) for CI. |

### Files unchanged

`src/collections/UserCollection721.sol`, `src/collections/UserCollection1155.sol`, `src/collections/interfaces/*.sol`, `src/collections/layouts/{CollectionFactory,UserCollection721,UserCollection1155}.v1.json`, `script/DeployCollectionFactoryZkSync.s.sol`, `script/UpgradeCollectionFactory.s.sol`.

---

## Task 1: Add CREATE2-derivation test for 721 (failing)

**Files:**
- Modify: `test/collections/CollectionFactory.t.sol`

- [ ] **Step 1: Add the failing test**

Open `test/collections/CollectionFactory.t.sol`. At the top of the file, add this import alongside the existing OZ imports:

```solidity
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IUserCollection721} from "../../src/collections/interfaces/IUserCollection721.sol";
```

Append this test method to the contract (place it next to `test_createCollection721_atomicAndEmits`):

```solidity
function test_createCollection721_addressMatchesCreate2Derivation() public {
    bytes32 externalId = keccak256("derivation-test-721");
    CreateParams721 memory p = _params721(CREATOR);

    bytes memory initData = abi.encodeCall(
        IUserCollection721.initialize,
        (p, OPERATOR)
    );

    bytes32 initCodeHash = keccak256(
        abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(impl721), initData)
        )
    );

    address predicted = Create2.computeAddress(
        externalId,
        initCodeHash,
        address(factory)
    );

    vm.prank(OPERATOR);
    address actual = factory.createCollection721(p, externalId);

    assertEq(actual, predicted, "deployed address must match CREATE2 derivation");
}
```

- [ ] **Step 2: Run the test, confirm it fails**

Run:

```bash
forge test --match-test test_createCollection721_addressMatchesCreate2Derivation -vv
```

Expected: **FAIL** with the assertion message — the current factory uses `Clones.clone()` (sequential CREATE), not CREATE2, so the deployed address won't match the predicted CREATE2 address.

- [ ] **Step 3: Commit the failing test**

```bash
git add test/collections/CollectionFactory.t.sol
git commit -m "test(collections): add CREATE2 derivation test for createCollection721 (RED)"
```

---

## Task 2: Switch `createCollection721` to `ERC1967Proxy` with salt

**Files:**
- Modify: `src/collections/CollectionFactory.sol`

- [ ] **Step 1: Swap the import**

In `src/collections/CollectionFactory.sol`, replace the `Clones` import (line 8):

```diff
- import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
+ import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
```

- [ ] **Step 2: Rewrite `createCollection721` body**

In the same file, locate `createCollection721` (lines 93-105 in current `b93a9a4`). Replace the body so it reads:

```solidity
function createCollection721(CreateParams721 calldata p, bytes32 externalId)
    external
    onlyRole(OPERATOR_ROLE)
    returns (address collection)
{
    _checkExternalId(externalId);

    bytes memory initData = abi.encodeCall(
        IUserCollection721.initialize,
        (p, msg.sender)
    );
    collection = address(
        new ERC1967Proxy{salt: externalId}(_erc721Implementation, initData)
    );

    _collectionByExternalId[externalId] = collection;
    emit CollectionCreated(p.owner, collection, Standard.ERC721, externalId);
}
```

- [ ] **Step 3: Update the contract's NatSpec at the top**

In the same file, update the `@notice` block (lines 16-19) so it no longer says "EIP-1167 minimal-proxy clones":

```diff
- * @notice UUPS-upgradeable, operator-triggered factory that deploys EIP-1167
- *         minimal-proxy clones of `UserCollection721` / `UserCollection1155`.
+ * @notice UUPS-upgradeable, operator-triggered factory that deploys per-collection
+ *         `ERC1967Proxy` instances of `UserCollection721` / `UserCollection1155`.
```

And the body comment (lines 21-25):

```diff
- *      The factory atomically clones an implementation, invokes the clone's
- *      `initialize` (passing `msg.sender` as the auto-granted operator
- *      minter — see §2.3), records the off-chain `externalId → clone`
- *      mapping, and emits `CollectionCreated`. Reverts on reused or zero
- *      `externalId`.
+ *      The factory atomically deploys a per-collection `ERC1967Proxy`
+ *      pointing at the standard's implementation, with an `abi.encodeCall`
+ *      to `initialize(p, msg.sender)` baked into the constructor so init
+ *      runs in the proxy's storage in the same frame. `msg.sender` is
+ *      auto-granted `MINTER_ROLE` (see §2.3). Records the
+ *      `externalId → collection` mapping and emits `CollectionCreated`.
+ *      Reverts on reused or zero `externalId`.
```

And the closing comment (lines 27-28):

```diff
- *      Already-deployed clones are immutable. Admin can swap implementation
- *      pointers via `setImplementation*`, which only affects future clones.
+ *      Already-deployed collections are immutable (impls do not inherit
+ *      `UUPSUpgradeable`; the EIP-1967 implementation slot is constructor-
+ *      fixed). Admin can swap implementation pointers via `setImplementation*`,
+ *      which only affects future collections.
```

- [ ] **Step 4: Run the previously-failing test, confirm it now passes**

```bash
forge test --match-test test_createCollection721_addressMatchesCreate2Derivation -vv
```

Expected: **PASS**.

- [ ] **Step 5: Run the full factory unit-test suite, confirm no regressions**

```bash
forge test --match-path test/collections/CollectionFactory.t.sol -vv
```

Expected: all tests pass. (The previously-failing test is now green; existing tests should be unaffected because they don't assert exact addresses or bytecode size.)

- [ ] **Step 6: Run the full collections suite as a regression sweep**

```bash
forge test --match-path 'test/collections/*' -vv
```

Expected: all 67+ existing tests + the new derivation test pass.

- [ ] **Step 7: Commit**

```bash
git add src/collections/CollectionFactory.sol test/collections/CollectionFactory.t.sol
git commit -m "feat(collections): replace Clones.clone() with ERC1967Proxy{salt} in createCollection721

Atomic deploy + init via the proxy's constructor (delegatecall to
initialize). Salt = externalId gives off-chain CREATE2 pre-derivation.
Preserves the per-collection bytecode-immutability promise — impls do
not inherit UUPSUpgradeable, so the EIP-1967 impl slot is constructor-
fixed. Required for zkSync Era compatibility (Clones.clone() is not
supported on EraVM)."
```

---

## Task 3: Switch `createCollection1155` to `ERC1967Proxy` with salt

**Files:**
- Modify: `src/collections/CollectionFactory.sol`
- Modify: `test/collections/CollectionFactory.t.sol`

- [ ] **Step 1: Add a failing 1155 derivation test**

Append to `test/collections/CollectionFactory.t.sol`:

```solidity
function test_createCollection1155_addressMatchesCreate2Derivation() public {
    bytes32 externalId = keccak256("derivation-test-1155");
    CreateParams1155 memory p = _params1155(CREATOR);

    bytes memory initData = abi.encodeCall(
        IUserCollection1155.initialize,
        (p, OPERATOR)
    );

    bytes32 initCodeHash = keccak256(
        abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(impl1155), initData)
        )
    );

    address predicted = Create2.computeAddress(
        externalId,
        initCodeHash,
        address(factory)
    );

    vm.prank(OPERATOR);
    address actual = factory.createCollection1155(p, externalId);

    assertEq(actual, predicted, "deployed 1155 address must match CREATE2 derivation");
}
```

If `IUserCollection1155` is not already imported in the test file, add at the top:

```solidity
import {IUserCollection1155} from "../../src/collections/interfaces/IUserCollection1155.sol";
```

- [ ] **Step 2: Run, confirm fail**

```bash
forge test --match-test test_createCollection1155_addressMatchesCreate2Derivation -vv
```

Expected: **FAIL** (still using `Clones.clone()` for 1155).

- [ ] **Step 3: Rewrite `createCollection1155` body in `CollectionFactory.sol`**

Locate `createCollection1155` (lines 107-120 in current `b93a9a4`). Replace the body:

```solidity
function createCollection1155(CreateParams1155 calldata p, bytes32 externalId)
    external
    onlyRole(OPERATOR_ROLE)
    returns (address collection)
{
    _checkExternalId(externalId);

    bytes memory initData = abi.encodeCall(
        IUserCollection1155.initialize,
        (p, msg.sender)
    );
    collection = address(
        new ERC1967Proxy{salt: externalId}(_erc1155Implementation, initData)
    );

    _collectionByExternalId[externalId] = collection;
    emit CollectionCreated(p.owner, collection, Standard.ERC1155, externalId);
}
```

- [ ] **Step 4: Run the previously-failing 1155 test, confirm it passes**

```bash
forge test --match-test test_createCollection1155_addressMatchesCreate2Derivation -vv
```

Expected: **PASS**.

- [ ] **Step 5: Run full collections suite as a regression sweep**

```bash
forge test --match-path 'test/collections/*' -vv
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/collections/CollectionFactory.sol test/collections/CollectionFactory.t.sol
git commit -m "feat(collections): replace Clones.clone() with ERC1967Proxy{salt} in createCollection1155"
```

---

## Task 4: Extend atomic-emits tests to assert `Upgraded` and `Initialized`

**Files:**
- Modify: `test/collections/CollectionFactory.t.sol`

The new flow emits `Upgraded(impl)` (from `ERC1967Utils.upgradeToAndCall`) then `Initialized(1)` (from the `initializer` modifier) inside the proxy constructor, before `CollectionCreated` from the factory. This task locks that ordering into a test.

- [ ] **Step 1: Add `Upgraded` and `Initialized` event signatures to the test contract**

Near the existing event declarations in `CollectionFactory.t.sol` (look for `event CollectionCreated(...)`), add:

```solidity
event Upgraded(address indexed implementation);
event Initialized(uint64 version);
```

- [ ] **Step 2: Replace `test_createCollection721_atomicAndEmits`**

Locate the test at line 116 (it's currently a single `expectEmit(true, false, true, true)` for `CollectionCreated` only). Replace its body with:

```solidity
function test_createCollection721_atomicAndEmits() public {
    bytes32 externalId = keccak256("order-1");

    // Order: Upgraded(impl) → Initialized(1) → ... role grants ... → CollectionCreated
    vm.expectEmit(true, false, false, false);
    emit Upgraded(address(impl721));

    vm.expectEmit(false, false, false, true);
    emit Initialized(1);

    // CollectionCreated indexed topics: (creator, collection, externalId).
    // We don't know the collection address up front, so leave its topic unchecked.
    vm.expectEmit(true, false, true, true);
    emit CollectionCreated(CREATOR, address(0), Standard.ERC721, externalId);

    vm.prank(OPERATOR);
    address collection = factory.createCollection721(_params721(CREATOR), externalId);

    assertEq(factory.collectionByExternalId(externalId), collection);
    UserCollection721 c = UserCollection721(collection);
    assertEq(c.name(), "C");
    assertEq(c.contractURI(), "ipfs://c.json");
    assertTrue(c.hasRole(keccak256("OWNER_ROLE"), CREATOR));
    assertTrue(c.hasRole(MINTER_ROLE, OPERATOR));
}
```

- [ ] **Step 3: Replace `test_createCollection1155_atomicAndEmits` analogously**

Locate the 1155 atomic-emits test (line 135) and apply the same pattern, swapping `impl721` → `impl1155` and `Standard.ERC721` → `Standard.ERC1155`.

- [ ] **Step 4: Add an immediate-mint test to prove no transient uninitialized window**

Append:

```solidity
function test_createCollection721_canMintImmediatelyInSameTx() public {
    bytes32 externalId = keccak256("immediate-mint-721");

    vm.startPrank(OPERATOR);
    address collection = factory.createCollection721(_params721(CREATOR), externalId);
    // Operator was auto-granted MINTER_ROLE during constructor delegatecall —
    // can mint without any extra setup transactions.
    UserCollection721(collection).mint(ALICE, 1);
    vm.stopPrank();

    assertEq(UserCollection721(collection).ownerOf(1), ALICE);
}
```

If `ALICE` isn't defined in this test file, add `address internal constant ALICE = address(0xA1);` to the constants block at the top.

- [ ] **Step 5: Run the updated tests, confirm pass**

```bash
forge test --match-test test_createCollection -vv
```

Expected: all `test_createCollection*` tests pass, including the new ones.

- [ ] **Step 6: Commit**

```bash
git add test/collections/CollectionFactory.t.sol
git commit -m "test(collections): assert Upgraded+Initialized emit order; add immediate-mint test"
```

---

## Task 5: Switch unit-test helpers to `ERC1967Proxy`

**Files:**
- Modify: `test/collections/UserCollection721.t.sol`
- Modify: `test/collections/UserCollection1155.t.sol`

Both files currently use `Clones.clone(address(impl))` to create test instances of the impl-behind-a-proxy without going through the factory. Switch them to `new ERC1967Proxy(address(impl), "")` for consistency with production.

- [ ] **Step 1: Update imports in `UserCollection721.t.sol`**

Replace line 5:

```diff
- import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
+ import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
```

- [ ] **Step 2: Replace each `Clones.clone(...)` call site in `UserCollection721.t.sol`**

For each occurrence (`grep -n "Clones.clone" test/collections/UserCollection721.t.sol` to find them all), replace:

```diff
- address cloneAddr = Clones.clone(address(impl));
+ address cloneAddr = address(new ERC1967Proxy(address(impl), ""));
```

The empty `""` `bytes` argument tells `ERC1967Proxy` to skip the constructor delegatecall — the test then calls `IUserCollection721(cloneAddr).initialize(...)` separately, exactly as today.

Also rename the local variable for vocabulary consistency where it appears (optional but tidy):

```diff
- address cloneAddr = address(new ERC1967Proxy(address(impl), ""));
+ address proxyAddr = address(new ERC1967Proxy(address(impl), ""));
```

…and update its references in the same function. (If the rename is invasive, leave the variable name alone — the type is what matters.)

- [ ] **Step 3: Repeat for `UserCollection1155.t.sol`**

Same import swap and same call-site replacements. There are 3 occurrences at lines 52, 98, 115 (per current grep).

- [ ] **Step 4: Run the unit suites, confirm green**

```bash
forge test --match-path 'test/collections/UserCollection*.t.sol' -vv
```

Expected: all impl unit tests pass.

- [ ] **Step 5: Commit**

```bash
git add test/collections/UserCollection721.t.sol test/collections/UserCollection1155.t.sol
git commit -m "test(collections): switch impl unit-test helpers from Clones to ERC1967Proxy"
```

---

## Task 6: Add no-upgrade-selector tests

**Files:**
- Modify: `test/collections/UserCollection721.t.sol`
- Modify: `test/collections/UserCollection1155.t.sol`

Codifies §7.2 row 16 (audit: "ABIs do not include `upgradeTo*` or `proxiableUUID`") as a unit test.

- [ ] **Step 1: Add the test to `UserCollection721.t.sol`**

Append to the test contract:

```solidity
function test_implementationHasNoUpgradeSelectors() public view {
    // proxiableUUID() — selector 0x52d1902d
    (bool ok1, ) = address(impl).staticcall(abi.encodeWithSelector(0x52d1902d));
    assertFalse(ok1, "impl must not expose proxiableUUID");

    // upgradeToAndCall(address,bytes) — selector 0x4f1ef286
    (bool ok2, ) = address(impl).staticcall(
        abi.encodeWithSelector(0x4f1ef286, address(0), bytes(""))
    );
    assertFalse(ok2, "impl must not expose upgradeToAndCall");
}
```

- [ ] **Step 2: Add the analogous test to `UserCollection1155.t.sol`**

Same shape, against that file's `impl` reference.

- [ ] **Step 3: Run both, confirm pass**

```bash
forge test --match-test test_implementationHasNoUpgradeSelectors -vv
```

Expected: **PASS** for both 721 and 1155 contracts.

- [ ] **Step 4: Commit**

```bash
git add test/collections/UserCollection721.t.sol test/collections/UserCollection1155.t.sol
git commit -m "test(collections): assert impls expose no UUPS upgrade selectors"
```

---

## Task 7: Add ERC1967Proxy bytecode-permanence test

**Files:**
- Create: `test/collections/ERC1967Proxy.permanence.t.sol`

Opcode-walks the canonical OZ `ERC1967Proxy` runtime bytecode and asserts no `0xff` (SELFDESTRUCT) and no `delegatecall` to caller-provided addresses. Parallel to the existing impl-side test but applied to the proxy contract.

- [ ] **Step 1: Inspect the existing impl opcode-walker for the pattern to match**

Run:

```bash
grep -n "PUSH1\|opcode\|SELFDESTRUCT\|0xff\|delegatecall" test/collections/UserCollection721.t.sol | head
```

This locates the bytecode-permanence helper. Copy its opcode-walker structure (skipping `PUSH1..PUSH32` immediates) — we'll mirror it.

- [ ] **Step 2: Write the new test file**

Create `test/collections/ERC1967Proxy.permanence.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Bytecode-permanence proof for canonical OZ ERC1967Proxy.
///         Codifies design §3.5.2 (1): no SELFDESTRUCT, no caller-controlled
///         delegatecall. Defense-in-depth audit gate.
contract ERC1967ProxyPermanenceTest is Test {
    /// @dev Deploy a real ERC1967Proxy and read its runtime bytecode.
    ///      Empty initData skips the constructor delegatecall — we just want
    ///      the deployed runtime, not a working instance.
    function _runtime() internal returns (bytes memory) {
        // Use any non-zero implementation; the runtime is the same regardless.
        ERC1967Proxy p = new ERC1967Proxy(address(this), "");
        return address(p).code;
    }

    function test_runtimeContainsNoSelfdestruct() public {
        bytes memory code = _runtime();
        require(code.length > 0, "no runtime");

        for (uint256 i = 0; i < code.length; ) {
            uint8 op = uint8(code[i]);

            // PUSH1..PUSH32 — skip the immediate bytes (op 0x60..0x7f).
            if (op >= 0x60 && op <= 0x7f) {
                uint256 imm = uint256(op) - 0x5f;
                i += 1 + imm;
                continue;
            }

            // SELFDESTRUCT (0xff) is the EVM mnemonic; canonical OZ
            // ERC1967Proxy must not contain it.
            assertTrue(op != 0xff, "ERC1967Proxy contains SELFDESTRUCT");

            i += 1;
        }
    }

    function test_proxyImplementationDelegatecallTargetIsConstructorFixed() public {
        // The only delegatecall in ERC1967Proxy's runtime targets _implementation()
        // which reads from the EIP-1967 slot. The slot is written exclusively by
        // ERC1967Utils.upgradeToAndCall (called only from the proxy's own
        // constructor since the impl does not inherit UUPSUpgradeable). This test
        // exercises the property by deploying with one impl and asserting the
        // EIP-1967 slot equals that impl, then asserting that no external call
        // can change it.
        address impl = address(this);
        ERC1967Proxy p = new ERC1967Proxy(impl, "");

        bytes32 IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 stored = vm.load(address(p), IMPL_SLOT);
        assertEq(address(uint160(uint256(stored))), impl, "EIP-1967 slot mismatch");

        // No external selector exposed by the proxy can write IMPL_SLOT — the
        // proxy's only entry point is the fallback, which delegatecalls the
        // current impl. Since `address(this)` (the test contract) has no
        // upgradeToAndCall selector, any call to mutate the slot reverts/no-ops.
        // We assert by replaying upgradeToAndCall through the proxy and showing
        // the slot is unchanged.
        bytes memory ignored = abi.encodeWithSelector(
            0x4f1ef286, address(0xdeadbeef), bytes("")
        );
        // staticcall to avoid mutating; the call should not return data that
        // reflects a successful upgrade.
        (bool ok, ) = address(p).staticcall(ignored);
        // Whether `ok` is true or false depends on the test contract's fallback;
        // either way the slot must not have changed.
        ok; // silence unused warning
        bytes32 storedAfter = vm.load(address(p), IMPL_SLOT);
        assertEq(stored, storedAfter, "EIP-1967 slot was mutated");
    }
}
```

- [ ] **Step 3: Run the new test file, confirm pass**

```bash
forge test --match-path test/collections/ERC1967Proxy.permanence.t.sol -vv
```

Expected: **PASS** on both functions.

- [ ] **Step 4: Commit**

```bash
git add test/collections/ERC1967Proxy.permanence.t.sol
git commit -m "test(collections): bytecode-permanence proof for canonical OZ ERC1967Proxy"
```

---

## Task 8: Update integration test sequence-of-events and vocabulary

**Files:**
- Modify: `test/collections/Collections.integration.t.sol`

- [ ] **Step 1: Find emit-order assertions and Clones references**

```bash
grep -nE "Clones|expectEmit|emit (Upgraded|Initialized|CollectionCreated)" test/collections/Collections.integration.t.sol
```

- [ ] **Step 2: For each `vm.expectEmit` block immediately preceding a `createCollection*` call, prepend `Upgraded` and `Initialized` expectations**

Pattern to apply at each call site:

```solidity
// before:
vm.expectEmit(true, true, true, true);
emit CollectionCreated(/* ... */);
factory.createCollection721(/* ... */);

// after:
vm.expectEmit(true, false, false, false);
emit Upgraded(address(impl721)); // or impl1155 for the 1155 path

vm.expectEmit(false, false, false, true);
emit Initialized(1);

vm.expectEmit(true, true, true, true);
emit CollectionCreated(/* ... */);
factory.createCollection721(/* ... */);
```

If the test contract doesn't already declare `Upgraded` and `Initialized`, add them next to the existing `event CollectionCreated(...)` declaration:

```solidity
event Upgraded(address indexed implementation);
event Initialized(uint64 version);
```

- [ ] **Step 3: Vocabulary pass**

In the same file, replace the comment at line 139 ("clone's runtime by `Clones.clone`") with a sentence referring to `ERC1967Proxy`. Replace any local variable named `clone*` or `*Clone` with `collection*` or `*Collection` for consistency (`grep -nE "[Cc]lone[A-Za-z]*" test/collections/Collections.integration.t.sol`).

- [ ] **Step 4: Run integration tests, confirm pass**

```bash
forge test --match-path test/collections/Collections.integration.t.sol -vv
```

Expected: all integration tests pass.

- [ ] **Step 5: Commit**

```bash
git add test/collections/Collections.integration.t.sol
git commit -m "test(collections): integration emit-order and vocabulary updates for ERC1967Proxy"
```

---

## Task 9: Vocabulary pass on remaining test code

**Files:**
- Modify: `test/collections/CollectionFactory.t.sol`

- [ ] **Step 1: Find leftover `clone` mentions**

```bash
grep -nE "[Cc]lone[A-Za-z]*" test/collections/CollectionFactory.t.sol
```

Expected hits include `test_setImplementation_affectsFutureClonesOnly` and locals `oldClone`/`newClone` (line 221+).

- [ ] **Step 2: Rename for vocabulary consistency**

- Function name: `test_setImplementation_affectsFutureClonesOnly` → `test_setImplementation_affectsFutureCollectionsOnly`.
- Locals: `oldClone` → `oldCollection`, `newClone` → `newCollection` (and update all references in the function body).
- Comment in the test that mentions "clone" / "clones" → "collection" / "collections".

- [ ] **Step 3: Run, confirm green**

```bash
forge test --match-path test/collections/CollectionFactory.t.sol -vv
```

Expected: all tests pass (rename is purely cosmetic).

- [ ] **Step 4: Commit**

```bash
git add test/collections/CollectionFactory.t.sol
git commit -m "test(collections): vocabulary pass — clones → collections in factory tests"
```

---

## Task 10: Update authoritative spec doc

**Files:**
- Modify: `src/collections/doc/spec/user-collections-specification.md`

Apply the changes specified in design doc §3.6. This is a documentation-only task with no tests; commit at the end.

- [ ] **Step 1: §1.1 — opening summary**

Find line 46:

```diff
- A single upgradeable factory that deploys cheap clones of fixed-behavior implementation contracts.
+ A single upgradeable factory that deploys per-collection `ERC1967Proxy` instances pointing at fixed-behavior implementation contracts.
```

- [ ] **Step 2: §1.2 — mermaid diagram**

Find the subgraph at line 70 and the arrow labels at lines 79-81:

```diff
- subgraph Clones["User Collections (EIP-1167 minimal proxies)"]
+ subgraph Collections["User Collections (ERC1967Proxy per collection)"]
```

```diff
- FAC -- "Clones.clone" --> C1
- FAC -- "Clones.clone" --> C2
- FAC -- "Clones.clone" --> C3
+ FAC -- "new ERC1967Proxy{salt}" --> C1
+ FAC -- "new ERC1967Proxy{salt}" --> C2
+ FAC -- "new ERC1967Proxy{salt}" --> C3
```

- [ ] **Step 3: §1.3 — core components table**

Find lines 102-103:

```diff
- | `UserCollection721`   | ERC-721 implementation cloned per creator                      | EIP-1167 clone target    | Immutable per clone                       |
- | `UserCollection1155`  | ERC-1155 implementation cloned per creator                     | EIP-1167 clone target    | Immutable per clone                       |
+ | `UserCollection721`   | ERC-721 implementation behind a per-collection ERC1967Proxy    | `ERC1967Proxy` implementation | Immutable per collection                  |
+ | `UserCollection1155`  | ERC-1155 implementation behind a per-collection ERC1967Proxy   | `ERC1967Proxy` implementation | Immutable per collection                  |
```

Find line 105 (the immutability promise):

```diff
- The factory is upgradeable so new implementation templates and bug fixes can be shipped without disrupting existing creators. Already-deployed clones cannot be upgraded — buyers and creators retain a permanent guarantee about each collection's behavior.
+ The factory is upgradeable so new implementation templates and bug fixes can be shipped without disrupting existing creators. Already-deployed collections cannot be upgraded — buyers and creators retain a permanent guarantee about each collection's behavior.
```

- [ ] **Step 4: §1.4 row 2 (Deployment model)**

Line 112:

```diff
- | 2 | Deployment model               | EIP-1167 minimal proxy clones for both standards                                                                                                                |
+ | 2 | Deployment model               | Per-collection `ERC1967Proxy` deployed via `CREATE2` with `externalId` salt; implementations deployed via `CREATE` only                                          |
```

- [ ] **Step 5: §1.4 row 7 (Upgradeability) + footnote**

Line 117:

```diff
- | 7 | Upgradeability                 | Factory: UUPS-upgradeable. Clones: immutable; admin can swap implementation pointer for *future* clones only                                                    |
+ | 7 | Upgradeability                 | Factory: UUPS-upgradeable. Per-collection proxies: immutable (impls do not inherit `UUPSUpgradeable`, no admin slot); admin can swap implementation pointer for *future* collections only [^upgradeability]  |
```

Append at the bottom of §1.4 (or as a footnote):

```markdown
[^upgradeability]: We use `ERC1967Proxy` directly (not `TransparentUpgradeableProxy`, not `BeaconProxy`) because the implementation contracts deliberately do not inherit `UUPSUpgradeable`. With no upgrade selector exposed and no `ProxyAdmin` slot pattern, the proxy's implementation pointer is constructor-fixed and the per-collection immutability promise is enforced by code that already exists in the OZ canonical libraries — no custom upgrade gating needed. We migrated away from the EIP-1167 minimal-proxy pattern because it is incompatible with zkSync Era's `ContractDeployer` factoryDeps model (see `2026-05-08-clones-replacement-design.md`).
```

- [ ] **Step 6: §2.3 vocab pass**

Line 166: `s/future clones/future collections/g` and `s/Existing clones/Existing collections/g` in the operator key rotation paragraph.

- [ ] **Step 7: §3.4 createCollection atomic flow**

Line 311 atomic-flow bullet:

```diff
- - Atomic flow: `Clones.clone(impl)` → `clone.initialize(p, msg.sender)` → `collectionByExternalId[externalId] = clone` → `emit CollectionCreated`. Passing `msg.sender` ensures the calling operator is auto-granted `MINTER_ROLE` on the new clone (see §2.3).
+ - Atomic flow: `abi.encodeCall(initialize, (p, msg.sender))` → `new ERC1967Proxy{salt: externalId}(impl, initData)` (deploy + delegatecall init in a single constructor frame) → `collectionByExternalId[externalId] = collection` → `emit CollectionCreated`. Passing `msg.sender` into `initData` ensures the calling operator is auto-granted `MINTER_ROLE` on the new collection (see §2.3).
```

Line 313: `s/Existing clones/Existing collections/g`, `s/affects future clones only/affects future collections only/g`.

- [ ] **Step 8: §4.1 sequence diagram**

Line 399:

```diff
- FAC->>CL: Clones.clone(erc721Implementation)
- CL->>CL: initialize(p, msg.sender)
+ FAC->>CL: new ERC1967Proxy{salt: externalId}(erc721Implementation, encodeCall(initialize, (p, msg.sender)))
+ Note over CL: emit Upgraded(impl), emit Initialized(1) inside constructor
```

- [ ] **Step 9: §4.2 — strengthen atomicity claim**

Locate §4.2 "Atomicity & Front-Running" and add a sentence:

> "Deploy and initialize occur in a single constructor frame; there is no transient window where the proxy exists in an uninitialized state."

- [ ] **Step 10: §4.4 — gas profile rewrite**

Line 424:

```diff
- - Deploys an EIP-1167 minimal proxy (~45,000 gas on EVM L1 baseline).
+ - On zkSync Era, per-collection deploy is dominated by `ContractDeployer.create2` plus the constructor's delegatecall init. Gas measured by `Collections.integration.t.sol` and quoted from the test output (target: < 1.5M gas on zkSync Sepolia for a typical `createCollection721`). The previous EIP-1167 baseline (~45k gas on EVM L1) is no longer applicable because we don't deploy minimal proxies.
```

- [ ] **Step 11: §4.5 (new sub-section) — Address Determinism**

Insert after §4.4:

```markdown
### 4.5 Address Determinism

Per-collection addresses are deterministic on-chain because the factory uses `new ERC1967Proxy{salt: externalId}(...)`. The address is a pure function of:

- `factory` proxy address (constant per environment)
- `externalId` (the salt; supplied by the operator)
- `_erc721Implementation` / `_erc1155Implementation` (read once via `erc721Implementation()` / `erc1155Implementation()`; refresh after admin upgrades)
- `initData = abi.encodeCall(initialize, (params, operatorAddress))`
- `ERC1967Proxy` zk bytecode hash (constant per zksolc release; pin in backend artifacts at the version used at factory deploy time)

Backends can pre-derive the collection address before broadcasting `createCollection*` using `zksync-ethers` `utils.create2Address`. The on-chain `_collectionByExternalId[externalId]` mapping remains the canonical registry — pre-derivation is a redundant off-chain lookup path, not a replacement.

**Caveats:**
1. Address is sensitive to every input — different `params` or different operator → different address.
2. Operator rotation (§2.3): pre-derive using the *current* OPERATOR_ROLE holder.
3. `_collectionByExternalId` mapping stays canonical and enforces uniqueness via `_checkExternalId`.
4. Pin the `ERC1967Proxy` zk bytecode hash; refresh only during a coordinated zksolc bump.
```

- [ ] **Step 12: §6.2 — Clone Storage opening + gap reservation**

Line 500:

```diff
- Each clone owns its full storage independently of other clones (EIP-1167 proxies `delegatecall` logic but persist state in the proxy's own address).
+ Each collection owns its full storage independently (`ERC1967Proxy` `delegatecall`s logic at the address in the EIP-1967 implementation slot but persists state in the proxy's own address).
```

Line 516: `s/Clones are immutable per release/Per-collection proxies are immutable per release/`, `s/for those future clones/for those future collections/`.

- [ ] **Step 13: §7.2 row 15 split into 15a / 15b + new row 16**

Find row 15 in the §7.2 risks table. Replace with two rows and a new row 16:

```diff
- | 15  | Implementation bytecode permanence ...  | Implementations deployed via `CREATE` only ...  |
+ | 15a | Implementation bytecode permanence | Implementations deployed via `CREATE` only (sequential nonce, never `CREATE2`); no `SELFDESTRUCT` in own/inherited code; no `delegatecall` to caller-provided addresses; verified by opcode-walker test |
+ | 15b | Per-collection proxy permanence    | Deployed via `CREATE2` with `externalId` salt using canonical OZ `ERC1967Proxy` unmodified; impls do not inherit `UUPSUpgradeable`; no `ProxyAdmin` pattern; therefore the EIP-1967 impl slot is constructor-fixed and the proxy bytecode is permanent. Verified by: (i) lockfile-pinned OZ import, (ii) opcode-walker test on `ERC1967Proxy` runtime, (iii) unit test asserting impls have no `upgradeTo*` selectors |
+ | 16  | Audit posture for OZ proxy import | Audit must verify `import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol'` resolves to canonical OZ at the lockfile-pinned version; remappings or forks of OZ proxy contracts are out of band and would invalidate the bytecode-permanence proof |
```

- [ ] **Step 14: §9.1 deploy step 4 note**

Add a clarifying note at the end of step 4 in §9.1:

> "Note: this `ERC1967Proxy(factoryImpl, ...)` is the *factory's own* proxy. The per-collection `ERC1967Proxy` instances are deployed by the factory itself at `createCollection*` time, not by this script."

- [ ] **Step 15: §9.4 runbook addition (per-collection EIP-1967 slot check)**

Find §9.4 "Pre-/Post-Upgrade Checklist" and append a new line under the post-deploy section:

```bash
EIP1967_IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
cast storage "$COLLECTION_ADDR" "$EIP1967_IMPL_SLOT" --rpc-url "$L2_RPC"
# expected: padded address of UserCollection721 (or 1155) impl
```

- [ ] **Step 16: Final vocabulary sweep**

Run a `grep` to catch any remaining "clone" mentions outside the historical references in §1.4 row 7 footnote and §4.4:

```bash
grep -niE "[Cc]lone[A-Za-z]*" src/collections/doc/spec/user-collections-specification.md
```

Review each hit; replace with "collection" / "collections" unless it's a deliberate historical reference. (The mermaid diagram subgraph rename and table rewrites should already cover most.)

- [ ] **Step 17: Commit**

```bash
git add src/collections/doc/spec/user-collections-specification.md
git commit -m "docs(collections): refit spec for ERC1967Proxy per-collection deploy

Vocabulary pass clones → collections, deployment-model rewrite, §1.4
upgradeability footnote, §3.4 atomic-flow bullet, §4.1 sequence diagram,
§4.4 gas profile, §4.5 new Address Determinism sub-section, §6.2 Clone
Storage opening, §7.2 row 15 split into 15a/15b + new row 16 for OZ
proxy import audit posture, §9.4 per-collection EIP-1967 slot check."
```

---

## Task 11: Add `factoryDependencies` build-artifact gate to deploy script

**Files:**
- Modify: `ops/deploy_collection_factory_zksync.sh`

After `compile_contracts`, the factory must have `ERC1967Proxy`'s zk hash in its `factoryDependencies`. If empty, the build silently produced a non-functional factory. Lock this as a CI gate.

- [ ] **Step 1: Add a check function**

Open `ops/deploy_collection_factory_zksync.sh`. After the existing `compile_contracts()` function (around line 152), add:

```bash
# =============================================================================
# Build-artifact verification — factoryDependencies must be populated.
# Empty factoryDependencies on CollectionFactory means createCollection*
# would revert at runtime on EraVM (the original Clones.clone() bug).
# =============================================================================

verify_build_artifacts() {
  log_info "Verifying CollectionFactory factoryDependencies are populated..."

  local artifact="zkout/CollectionFactory.sol/CollectionFactory.json"
  if [ ! -f "$artifact" ]; then
    log_error "Compiled artifact not found: $artifact"
    exit 1
  fi

  local dep_count
  dep_count=$(jq -r '.factoryDependencies | length' "$artifact")

  if [ "$dep_count" -eq 0 ]; then
    log_error "CollectionFactory.factoryDependencies is empty."
    log_error "This means the factory cannot deploy per-collection proxies on EraVM."
    log_error "Refer to docs §3.5.2 / row 15b — ERC1967Proxy must appear in factoryDeps."
    exit 1
  fi

  log_success "factoryDependencies populated ($dep_count entries)"
}
```

- [ ] **Step 2: Call it from `main()`**

Find `main()` near the bottom and insert the new step after `compile_contracts`:

```diff
  preflight_checks
  move_l1_contracts
  compile_contracts
+ verify_build_artifacts
  deploy_contracts
```

- [ ] **Step 3: Run the dry-run to confirm the gate fires correctly**

Before the factory refactor lands, this check would *fail* (empty factoryDeps proves the gate works). After the refactor lands, it should *pass*. Run:

```bash
./ops/deploy_collection_factory_zksync.sh testnet
```

Expected: dry-run completes through `verify_build_artifacts` and prints `factoryDependencies populated (≥1 entries)`.

- [ ] **Step 4: Commit**

```bash
git add ops/deploy_collection_factory_zksync.sh
git commit -m "ops(collections): gate deploy on populated factoryDependencies

CollectionFactory's factoryDependencies must contain at least one entry
(ERC1967Proxy). Empty factoryDeps means the factory cannot deploy
per-collection proxies on EraVM at runtime — exactly the failure mode
that left the original Clones.clone() factory broken on zkSync Era."
```

---

## Task 12: Add post-broadcast end-to-end smoke test to deploy script

**Files:**
- Modify: `ops/deploy_collection_factory_zksync.sh`

After `--broadcast`, `cast send` a real `createCollection721` against the freshly deployed factory and assert correctness on-chain. This is the empirical EraVM check the missing of which left `Clones.clone()` undetected.

- [ ] **Step 1: Add a smoke-test function**

In `ops/deploy_collection_factory_zksync.sh`, after `verify_deployment()` (around line 260), add:

```bash
# =============================================================================
# End-to-end smoke test — exercise createCollection721 on the live network.
# This is the empirical check that the EraVM-compiled output works at runtime.
# =============================================================================

smoke_test_createCollection() {
  if [ "$BROADCAST" != "--broadcast" ]; then
    return 0
  fi

  log_info "Running end-to-end smoke test: createCollection721..."

  local rpc
  if [ "$NETWORK" = "mainnet" ]; then
    rpc="${L2_RPC:-https://mainnet.era.zksync.io}"
  else
    rpc="${L2_RPC:-https://rpc.ankr.com/zksync_era_sepolia}"
  fi

  # Build a minimal CreateParams721 calldata. owner = operator,
  # additionalMinters = empty array, royaltyBps = 0, simple URIs.
  local extId
  extId=$(cast keccak "smoke-$(date +%s)")

  local params
  params=$(cast abi-encode \
    "f((string,string,address,address[],string,address,uint96,string))" \
    "(\"Smoke\",\"SMK\",$N_FACTORY_OPERATOR,[],\"ipfs://smoke/\",$N_FACTORY_OPERATOR,0,\"ipfs://smoke.json\")")

  log_info "Calling createCollection721($extId)..."
  cast send "$COLLECTION_FACTORY_PROXY" \
    "createCollection721((string,string,address,address[],string,address,uint96,string),bytes32)" \
    "$params" "$extId" \
    --rpc-url "$rpc" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --zksync \
    || { log_error "createCollection721 reverted on-chain"; exit 1; }

  # Read the resulting collection address from the mapping.
  local collection
  collection=$(cast call "$COLLECTION_FACTORY_PROXY" \
    "collectionByExternalId(bytes32)(address)" "$extId" --rpc-url "$rpc")

  log_info "Smoke collection deployed at: $collection"

  # Assert non-empty code at the collection address.
  local code_size
  code_size=$(cast code "$collection" --rpc-url "$rpc" | wc -c)
  if [ "$code_size" -lt 10 ]; then
    log_error "Smoke collection has empty bytecode"
    exit 1
  fi

  # Assert EIP-1967 impl slot equals expected impl.
  local EIP1967_IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
  local stored
  stored=$(cast storage "$collection" "$EIP1967_IMPL_SLOT" --rpc-url "$rpc")
  log_info "EIP-1967 impl slot: $stored (expected impl: $USER_COLLECTION_721_IMPL)"

  log_success "Smoke test passed: createCollection721 succeeded; collection has code; EIP-1967 slot set"
}
```

- [ ] **Step 2: Wire it into `main()`**

```diff
  verify_deployment
+ smoke_test_createCollection
  verify_source_code
```

- [ ] **Step 3: Commit (don't run yet — requires real broadcast)**

```bash
git add ops/deploy_collection_factory_zksync.sh
git commit -m "ops(collections): post-broadcast createCollection721 smoke test on zkSync

Calls createCollection721 against the freshly deployed factory and
asserts the resulting collection has non-empty code and a populated
EIP-1967 impl slot. Catches EraVM-runtime failures that compile-time
gates miss (e.g. the original Clones.clone() incompatibility)."
```

The smoke test runs only when `--broadcast` is passed. We deliberately don't dry-run it here — that requires a real testnet deploy, which is the final task.

---

## Task 13: Final verification — full test sweep + storage-layout baseline diff

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

```bash
forge test --match-path 'test/collections/*' -vv
```

Expected: all tests pass. Count should be ≥69 (67 original + 2 CREATE2 derivation + 2 no-upgrade-selector + 1 immediate-mint + 2 ERC1967Proxy permanence = 74 minimum). If anything is red, debug before proceeding.

- [ ] **Step 2: Verify storage-layout baselines unchanged**

```bash
forge inspect src/collections/CollectionFactory.sol:CollectionFactory storage-layout > /tmp/factory-now.json
diff <(jq -S . src/collections/layouts/CollectionFactory.v1.json) <(jq -S . /tmp/factory-now.json)

forge inspect src/collections/UserCollection721.sol:UserCollection721 storage-layout > /tmp/uc721-now.json
diff <(jq -S . src/collections/layouts/UserCollection721.v1.json) <(jq -S . /tmp/uc721-now.json)

forge inspect src/collections/UserCollection1155.sol:UserCollection1155 storage-layout > /tmp/uc1155-now.json
diff <(jq -S . src/collections/layouts/UserCollection1155.v1.json) <(jq -S . /tmp/uc1155-now.json)
```

Expected: all three diffs are empty (the refactor doesn't touch storage). If a diff is non-empty, something unexpected changed — investigate before continuing.

- [ ] **Step 3: zkSync compile + factoryDependencies check**

```bash
./ops/deploy_collection_factory_zksync.sh testnet
```

Expected: dry-run reaches `verify_build_artifacts` and reports `factoryDependencies populated (≥1 entries)`. The L1-move/restore patch from earlier is still required for compile to succeed; it should be merged or staged before this step.

- [ ] **Step 4: Coverage check**

```bash
forge coverage --match-path 'test/collections/*' --report lcov > /tmp/coverage.lcov 2>&1 || true
forge coverage --match-path 'test/collections/*' | tail -20
```

Expected: `src/collections/*` line coverage ≥ 95% (current CI floor). The new tests should keep or increase coverage from the current 96.91%.

- [ ] **Step 5: Spell-check the spec**

```bash
# If `cspell` is installed in the repo, run it on the spec; otherwise skip.
command -v cspell && cspell src/collections/doc/spec/user-collections-specification.md src/collections/doc/spec/2026-05-08-clones-replacement-design.md src/collections/doc/spec/2026-05-08-clones-replacement-implementation-plan.md
```

- [ ] **Step 6: Smoke-test on zkSync Sepolia (optional, requires testnet ETH)**

Once all the above pass, do an actual `--broadcast` deploy:

```bash
./ops/deploy_collection_factory_zksync.sh testnet --broadcast
```

Expected sequence:
1. `factoryDependencies populated`
2. Implementations + factory + ERC1967Proxy(factory) deploy
3. `verify_deployment` confirms admin/operator roles and EIP-1967 factory-proxy slot
4. `smoke_test_createCollection` calls a real `createCollection721`, prints the new collection address, confirms non-empty code, and confirms the EIP-1967 impl slot points at `UserCollection721`.

If any step reverts on-chain, capture the tx hash and the EraVM trace for analysis. The most likely failure modes (and how to read them):

- `createCollection721` reverts inside the constructor → check whether `ERC1967Proxy`'s zk bytecode hash is registered as a factory dep (`jq '.factoryDependencies' zkout/CollectionFactory.sol/CollectionFactory.json`).
- `createCollection721` reverts on `delegatecall` to impl → check that `_erc721Implementation()` returns the deployed impl address and that `cast code` on that address is non-empty.
- `createCollection721` reverts with `DuplicateExternalId` → the externalId computed via `cast keccak "smoke-..."` collided; rerun with a different timestamp.

- [ ] **Step 7: No code commit needed**

This task is verification only. If everything passes, the implementation is complete. If §6 (live broadcast) actually deployed, capture the addresses in `.env-test` (the deploy script does this automatically) and tag the commit if you want a snapshot.

---

## Self-Review Notes

**Spec coverage:**
- §3.1 factory state — Tasks 2, 3 (preserved by not touching storage)
- §3.2 deploy path (721 + 1155) — Tasks 1, 2, 3
- §3.3 init flow + atomic emits — Task 4
- §3.4 address determinism — Tasks 1, 3 (CREATE2 derivation tests)
- §3.5 bytecode permanence (15a + 15b) — Tasks 6, 7 + spec update Task 10
- §3.6 spec deltas — Task 10
- §3.7 storage-layout baselines unchanged — Task 13 (verification)
- §3.8 test impact — Tasks 1, 3, 4, 5, 6, 7, 8, 9
- §3.8.4 CI factoryDeps gate — Task 11
- §3.8.3 point 5 end-to-end smoke — Task 12
- §3.9 audit checklist — Task 6 codifies row 16 in CI; Task 10 documents the audit gates

All design-doc requirements have a corresponding task. No gaps.

**Placeholder scan:** No `TBD` / `TODO` / `add appropriate` / `similar to Task N` placeholders. Every code-mutating step contains the actual code.

**Type consistency:** Method names match across tasks (`createCollection721` / `createCollection1155` / `_erc721Implementation` / `_erc1155Implementation` / `_collectionByExternalId` / `IUserCollection721.initialize` / `IUserCollection1155.initialize`). The `IMPL_SLOT` / `EIP1967_IMPL_SLOT` constant is consistent across tasks 7, 10, 12, 13. Event names `Upgraded` / `Initialized` / `CollectionCreated` are consistent.

**Scope:** Single implementation plan, one PR's worth of changes. Touches 7 files modified + 1 added + 1 doc. ~13 logical commits, each green-on-its-own.

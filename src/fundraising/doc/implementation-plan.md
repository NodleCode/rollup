# Group Fundraising — Implementation Plan

Execution plan for [the specification](spec/group-fundraising-design.md). The spec says *what*; this says *in what order, and where the traps are*.

---

## 1. The deployment mechanism — settled before anything else

The spec originally said the factory would deploy **minimal proxies (`Clones` / EIP-1167)**. That is wrong on zkSync Era, and the spec has been corrected.

`Clones.clone()` assembles the EIP-1167 runtime blob in memory at runtime. zksolc never sees it statically, so the factory's `factoryDependencies` come up empty and the EraVM `ContractDeployer` cannot resolve the deploy — it reverts `ERC1167: create failed`.

This is not a prediction. **Collections shipped its first design on `Clones`, hit exactly this, and replaced it.** The post-mortem is in [`src/collections/doc/spec/design-and-implementation.md`](../../collections/doc/spec/design-and-implementation.md) §1.1, with two independent confirmations recorded there including one from Matter Labs.

**Therefore:** one `ERC1967Proxy` per objective, via `new ERC1967Proxy(implementation, initData)`, with an implementation that deliberately does **not** inherit `UUPSUpgradeable`. That is exactly what `CollectionFactory` does, and it preserves every property the spec wanted from clones:

- **Immutability per objective.** No `UUPSUpgradeable`, no `ProxyAdmin` — the implementation slot is constructor-fixed and unreachable for writes.
- **Upgrades for future objectives only.** The factory's `implementation` pointer changes what gets deployed next and cannot touch a live objective. This is the cheaper answer to spec §10 #1.
- **Atomic initialization.** `initData` runs inside the proxy constructor, in the same frame as the deploy. There is no window to front-run.

**Use plain `CREATE`, not a salt.** `CollectionFactory` salts with `externalId`, but creation there is operator-gated. Here it is permissionless, and the only salt candidate — `groupId` — is an unverified tag anyone may reuse, so a salted deploy invites griefing by squatting. Nothing in the product needs address pre-derivation.

---

## 2. Build order

Every step leaves the tree compiling.

1. **`interfaces/IFundraiser.sol`** — types, events, errors, both interfaces. Locking names first stops interface churn rippling through tests later.
2. **`Fundraiser.sol`** — the escrow. Testable before the factory exists by hand-deploying a proxy.
3. **`FundraiserFactory.sol`** — thin by comparison.
4. **`forge build --zksync` checkpoint.** Do this *before* writing tests. This is where the `Clones` class of failure surfaces, and finding it after 2,000 lines of tests is the expensive path.
5. **Mocks** — fee-on-transfer, reentrant, blocklisting, and an ERC-2612 permit token (the spec's mock list omits permit; `depositWithPermit` needs it).
6. **Shared test base** — deploys factory plus a default fundraiser; every test file inherits it.
7. **Tests** — `Lifecycle` → `GoalLatch` → `Refunds` → `Permissionless` → `Invariants` (last; handlers want the final ABI).
8. **`script/DeployFundraiserFactory.s.sol`** plus its README usage section.
9. **Era smoke deploy** — create, deposit, finalize against era-test-node. Non-negotiable; see §6 risk 1.

---

## 3. Files

### `interfaces/IFundraiser.sol`

Types per spec §6.1 and A.1: `Status { Funding, Succeeded, Refunding, Closed }`, `OnMissed { Refund, PayBeneficiary }`, `FundraiserParams { name, token, goal, deadline, onMissed, beneficiary, minContribution, maxTotalContributions }`.

`IFundraiser`: `initialize(params, organizer, feeBps, factory)`, `deposit(amount)`, `depositWithPermit(...)`, `unpledge(amount)`, `finalize()`, `cancel()`, `withdraw()`, `setPayoutAddress(addr)`, `refund()`, `refundFor(contributor)`, `rescueSurplus(token, to)`, plus views `state()`, `contributionOf(addr)`, `remainingToGoal()`, `canUnpledge()`.

`IFundraiserFactory`: `createFundraiser(params, groupId) returns (address)`, `setTokenAllowed`, `setFeeParams`, `setImplementation`, and views including `isFundraiser(addr)`.

Errors are custom and named for the condition, per repo convention — `PayBeneficiaryRequiresDeadline`, `GoalReached`, `RaisedOverflow`, `CapBelowGoal`, `NotFinalizable`, and the rest.

Events carry what indexers need: `ContributionMade(contributor, credited, raised)` reports the **credited** amount, and both it and `Unpledged` carry the running `raised` so no indexer assumes monotonic growth.

### `Fundraiser.sol`

`Initializable + ReentrancyGuardUpgradeable`, `SafeERC20` throughout. Config set once in `initialize`; mutable state is `status`, `raised`, `unpledged`, `refunded`, and the `contributions` mapping. No storage gap — the implementation is never upgraded, and its absence says so.

`constructor() { _disableInitializers(); }` bricks the bare implementation.

**All parameter validation lives in `initialize`, not the factory**, so the escrow enforces its own invariants no matter who deploys it. The one exception is the token allow-list, which only the factory knows.

`initialize` makes no external calls, preserving the factory's ability to write its registry safely after deployment.

### `FundraiserFactory.sol`

Immutable, non-proxied, `AccessControl`. Holds the allow-list, fee parameters, the implementation pointer, and an `isFundraiser` registry so indexers and the refund sweeper can verify provenance on-chain rather than trusting an address they were handed.

`createFundraiser` has **no role gate** — do not copy `onlyRole(OPERATOR_ROLE)` from the Collections precedent. It checks the allow-list, deploys the proxy with `feeBps` snapshotted by value, records the registry entry, and emits `FundraiserCreated` carrying `groupId`.

`groupId` appears **only in the event**. Never stored, never verified — a hint, not a claim (spec §6.1).

Admin functions touch the allow-list, fee parameters, and the implementation pointer. None reaches a live objective.

---

## 4. The parts that will bite

1. **The goal latch is two strict comparisons.** `raised < goal` in `unpledge` and `cancel`; `raised >= goal` in `finalize`. A deposit crossing the goal latches within that same transaction — no flag, no event, no grace period. Deposits *after* the latch are still accepted, so the invariant is "`raised` never re-crosses below `goal`", not "`raised` stops changing".
2. **Credit the balance delta, never the requested amount.** Measure `balanceOf` either side of `safeTransferFrom` and credit the difference; run every check and every accumulator on that number. `nonReentrant` is what makes the delta attributable to this transfer alone.
3. **Both guards on every exit path.** `unpledge`, `withdraw`, `refund`/`refundFor`, `rescueSurplus`: storage writes complete before the first transfer, *and* the function is `nonReentrant`. Spec §7 #4 requires both, not either.
4. **Initializer safety.** Three hazards, three answers: `_disableInitializers()` in the constructor kills implementation takeover; `initData` inside the proxy constructor removes any front-running window; the plain `initializer` modifier (never `reinitializer`) prevents re-initialization. Test all three, and assert the implementation slot never moves.
5. **`deadline == 0` has exactly four read sites.** `block.timestamp >= 0` is always true, so naive logic finalizes an open-ended objective as missed at birth. Guard the deposit cutoff, the finalize missed-branch, and creation validation on `deadline != 0`; the fourth site is presentational. Keep it to four.
6. **`minContribution` must never stand between an objective and resolution.** A deposit that brings `raised` to at least `goal` is exempt from the minimum — a remaining gap smaller than the minimum must still be fillable. This is the direct generalization of the Party M-06 lesson, and `finalize` itself checks nothing about minimums, ever.
7. **Fee: rate snapshotted, recipient live.** `feeBps` is passed by value at creation and never re-read, bounded by `MAX_FEE_BPS` at both `setFeeParams` and `initialize`. The recipient is read from the factory at withdraw time so a lost collection key can be rotated without touching objectives — safe precisely because the rate is frozen. Applied only on `withdraw`, rounded down, remainder to the group.
8. **`uint128` truncation.** The credited delta is a `uint256`; require it fits before casting, with a named error. Unreachable for capped objectives, a real branch for uncapped ones in an 18-decimal token.

---

## 5. Tests

- **`Lifecycle.t.sol`** — every edge in spec §5, permitted and reverting. Both `OnMissed` outcomes at a passed deadline. The exact boundary timestamp `t == deadline`, where deposits are closed and finalize is open. An open-ended objective warped ten years that still will not resolve. The fee snapshot proven by raising the factory fee mid-flight. The initializer triple. Two regressions named for the prior art: a last contribution below the minimum must still finalize, and an organizer who never calls anything must not be able to freeze the objective.
- **`GoalLatch.t.sol`** — the `goal - 1` / `goal` / `goal + 1` battery with interleaved unpledges, atomic latching within a crossing deposit, deposits still accepted post-latch, and a fuzz run asserting `canUnpledge() == (raised < goal)` after every operation.
- **`Refunds.t.sol`** — the fee-on-transfer end-to-end case where all N contributors refund including the last (the insolvency that balance-delta crediting exists to prevent); reentrancy against each exit path; a blocklisted beneficiary recovering via `setPayoutAddress`; `rescueSurplus` moving only genuine surplus, with unclaimed refunds untouchable.
- **`Permissionless.t.sol`** — a non-member depositing and refunding normally; `unpledge` returning only the caller's own money; a stranger funding the gap latching exactly as a member would, including the organizer-as-beneficiary self-funding case from spec §7 #10; two fundraisers sharing a `groupId` tag; a smart-account contributor.
- **`Invariants.t.sol`** — contributions sum to `raised`; balance covers outstanding liability in every state; `Refunding` never pays the beneficiary; once `raised >= goal` is observed it holds forever; status transitions only along spec §5 edges.

---

## 6. Sequencing risks

1. **`forge test` cannot catch EraVM deployment bugs.** Tests run on the vanilla EVM profile; the entire class of failure that sank the first Collections design only appears under `--zksync` on an Era node. Green tests are not evidence that this deploys. Hence the step-4 checkpoint and the step-9 smoke deploy.
2. **Pick the `ReentrancyGuard` flavour now.** Classic `ReentrancyGuardUpgradeable`, with `__ReentrancyGuard_init()` called. Adopting the transient-storage variant later would change the storage layout, and EraVM `tstore` semantics are not worth gambling on.
3. **Fee recipient live-read vs. full snapshot** changes the `initialize` signature, both contracts, `Lifecycle`, and the deploy script. Overrule it before tests exist or not at all.
4. **Factory mutability** — immutable with `AccessControl` (this plan) versus UUPS like Collections. Settle before step 3 ends. It does not touch `Fundraiser`.
5. **`MAX_FEE_BPS` and `MAX_DURATION` need owners before audit.** Constants cannot be revisited after deployment.
6. Budget the explorer verification step; `foundry.toml` already sets `bytecode_hash = "none"` for Era, but the process is documented as fragile.

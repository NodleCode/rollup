# NODL Bridge — Bridgehub Migration & Cutover Runbook

zkSync deprecated the legacy Mailbox entrypoints our L1 bridge uses for deposits
([announcement, 2026-03-19](https://github.com/zkSync-Community-Hub/zksync-developers/discussions/1147)).
The migration window is 6 months, so the legacy `requestL2Transaction` path may stop working
around **mid-September 2026**. The new `L1Bridge` routes deposits and base-cost quotes through the
Bridgehub. The L2→L1 proof paths (`proveL2MessageInclusion`, `proveL1ToL2TransactionStatus`) are
**not** deprecated and stay on the Diamond proxy.

`L1_MAILBOX` is immutable on a non-proxy contract, so this ships as a **new deployment**. This
document is the sequencing for that cutover.

## Why the new deployment must know its predecessor (`LEGACY_BRIDGE`)

Withdrawal messages carry no nonce — they are `(selector, l1Receiver, amount)`. Replay protection
is each bridge instance's own `isWithdrawalFinalized[batch][index]` map, and inclusion proofs for
historical messages verify on the Diamond forever. A fresh deployment therefore starts willing to
finalize **every historical withdrawal again**, including ones the old bridge already paid out
(verified against mainnet state via the fork suite — see below). Passing the old bridge as
`LEGACY_BRIDGE` makes the new bridge reject any `(batch, index)` the old instance already
finalized.

Equally important in the other direction: after cutover the **old bridge must not keep minting**,
or new withdrawals could be finalized on both instances. Hence the pause/revoke steps below.

**Nuance since the L2 redeploy became mandatory (see next section):** `finalizeWithdrawal` pins
the message sender to the immutable `L2_BRIDGE_ADDR`. Because the cutover deploys a *new* L2
bridge, a historical withdrawal (sender = old L2 bridge) already fails its inclusion proof on the
new L1 bridge, before the `LEGACY_BRIDGE` guard is consulted. Both paths are proven on a mainnet
fork — same real proof, unguarded deployment, only `L2_BRIDGE_ADDR` differing:
`test_Fork_ProofPathWorks_UnguardedDeploymentWouldDoubleMint` (old L2 → double mint) vs
`test_Fork_NewL2Wiring_BlocksOldL2WithdrawalEvenUnguarded` (new L2 → `InvalidProof`).

Keep `LEGACY_BRIDGE` set regardless: it is cheap defense-in-depth, and it is the only guard left
if a future cutover ever reuses an L2 bridge address.

## L2 bridge must also be redeployed

`L2Bridge.initialize(address)` is **one-shot** — once `l1Bridge` is set it cannot be repointed.
Deposits enqueue an L2 call to `finalizeDeposit`, which accepts only the aliased L1 bridge
address stored at initialization (`onlyL1Bridge`).

**Deploying a new L1Bridge against the existing L2Bridge will not mint on L2.** Mainnet cutover
must therefore either:

1. **Redeploy L2Bridge** (same NODL token), call `initialize(newL1Bridge)`, and pass the new L2
   address into the new L1Bridge constructor — this is what the Sepolia rehearsal did; or
2. Ship a contract change (e.g. `setL1Bridge`) before cutover — not available today.

Withdrawal **proofs** still reference the L2 bridge contract address as message sender; a new L2
deployment is fine as long as the new L1Bridge constructor points at the new `L2_BRIDGE_ADDR`.
The `LEGACY_BRIDGE` guard keys off `(batch, index)` finalized on the **old L1** bridge, not the
L2 address in the proof.

## Addresses

| Contract | Ethereum mainnet | Sepolia (legacy) | Sepolia (rehearsal, 2026-07-17) |
| --- | --- | --- | --- |
| Bridgehub (`BRIDGEHUB`) | `0x303a465B659cBB0ab36eE643eA362c509EEb5213` | `0x35A54c8C757806eB6820629bc82d90E056394C92` | same |
| Era Diamond proxy (`L1_MAILBOX`) | `0x32400084C286CF3E17e7B677ea9583e60a000324` | `0x9A6DE0f62Aa270A8bCB1e2610078650D539B1Ef9` | same |
| Era chain id (`L2_CHAIN_ID`) | `324` | `300` | same |
| L1Bridge (`LEGACY_BRIDGE`) | `0x2D02b651Ea9630351719c8c55210e042e940d69a` | `0xF8244F4Aa72D21b4511CD7989221fF96E7D94B60` | — |
| New L1Bridge | — | — | `0xd4676309609543A85ee6d18e8A9Ea385521D01a5` |
| L1 NODL (`L1_NODL`) | `0x6dd0E17ec6fE56c5f58a0Fe2Bb813B9b5cc25990` | `0xE057bF2EAa2A53e8b942Fc9bE327b16088Ac0baC` | same |
| L2 Bridge (`L2_BRIDGE`) | `0x2c1B65dA72d5Cf19b41dE6eDcCFB7DD83d1B529E` | `0x62063BfC39e8ab2A4dE8d84B87B14a8051cE7634` | `0xff735c70f33ca4eF1768F527B5f230b76A61A89b` |

## Pre-deployment validation

1. Unit suite: `forge test` (must be green, fork tests self-skip without an RPC).
2. Mainnet fork suite against live state (repeat shortly before the mainnet deployment):

   ```bash
   MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract L1BridgeMainnetForkTest -vv
   ```

   This exercises the real Bridgehub (deposit + quotes), simulates the Mailbox cutoff, and
   verifies a real historical withdrawal proof against the legacy guard.
3. Deprecation status check (also usable as a cron canary):

   ```bash
   ./ops/check_zksync_deprecation.sh mainnet
   ./ops/check_zksync_deprecation.sh sepolia
   ```

## Sepolia rehearsal

Run the full loop on Sepolia first — it is also the early-warning environment, since zkSync ships
protocol upgrades to testnet before mainnet. **Status: passed 2026-07-17** (see
`ops/sepolia-rehearsal-status.md` if present in your checkout).

1. **Deploy fresh L2 + L1** via `ops/deploy_L1L2_bridge.sh` with `BRIDGEHUB`, `L2_CHAIN_ID=300`,
   and `LEGACY_BRIDGE` set to the current Sepolia L1 bridge. Unset/clear `L1_BRIDGE` and `L2_BRIDGE`
   in `.env` so both are redeployed (reuse existing `L1_NODL` / `NODL` tokens).
   - L2 deploy on zkSync: skip L1-only contracts that break zkSync compile, e.g.
     `forge script ... --skip src/swarms/SwarmRegistryL1Upgradeable.sol test`
   - After L1 deploy: `initialize(newL1Bridge)` on the new L2Bridge.
2. **Deposit → L2 mint** — approve L1 NODL to the new L1 bridge, deposit with Bridgehub fee.
3. **Withdraw → finalize** — approve L2 NODL to the new L2 bridge (`burnFrom`), withdraw on L2,
   wait for batch + proof (`zks_getL2ToL1LogProof`; proof may be available before `ethExecuteTxHash`
   is populated), `finalizeWithdrawal` on the new L1 bridge.
4. **Failed deposit → claim** — Bridgehub rejects absurdly low `_l2TxGasLimit` at enqueue
   (`TxnBodyGasLimitNotEnoughGas`). On Sepolia we forced failure by **pausing L2** before the
   enqueued `finalizeDeposit` executed, then `claimFailedDeposit` after the failed L2 tx lands in
   an L1 batch (~2h on Sepolia testnet). Allow time for batch commit before claiming.
5. **Legacy replay guard** — the old Sepolia bridge had no prior finalized withdrawals, so the
   rehearsal finalized a fresh withdrawal on the **old** L1 bridge, then replayed the same proof on
   the new bridge → must revert `WithdrawalFinalizedOnLegacyBridge`.
6. **When zkSync enforces the deprecation on testnet** (watch the canary), rerun steps 2–3.
   That is the real-world proof the new bridge survives the cutoff — schedule the mainnet
   cutover only after this passes.

### What the rehearsal did not cover

- **Safe-mediated grants.** The Sepolia deployer holds `DEFAULT_ADMIN_ROLE` on the Sepolia tokens,
  so the rehearsal granted `MINTER_ROLE` straight from the deployer key. On mainnet that role is
  Safe-held and the deployer holds nothing, so the whole privileged path below is unrehearsed.
  Dry-run each Safe transaction (Tenderly or a fork) before executing it.
- **Draining in-flight withdrawals.** The rehearsal had no meaningful withdrawal backlog on the
  old Sepolia bridge, so step 5.2 below was never exercised under load.

## Mainnet cutover sequence

Deposits in flight are unaffected throughout (priority ops already enqueued execute on L2
regardless). The ordering below exists to stop users being stranded mid-withdrawal.

The deploy scripts **only deploy**. Every privileged call is a Safe transaction, because
`DEFAULT_ADMIN_ROLE` on both NODL tokens and ownership of both bridges are Safe-held on mainnet —
the deployer EOA holds nothing. The scripts print the required calldata; execute it from the Safe.

| Safe | Chain | Holds |
| --- | --- | --- |
| `0x55f5E48A1d30d67ac13751b523Ca1b3cB5838AD8` | Ethereum | L1 NODL `DEFAULT_ADMIN_ROLE`, old L1 bridge owner |
| `0x5e097AC1BCF81E7Ff2657045F72cAa6cF06486C9` | zkSync Era | L2 NODL `DEFAULT_ADMIN_ROLE`, old L2 bridge owner |

1. **Pre-checks**
   - Rerun the fork suite and the canary (above).
   - Enumerate old-bridge deposits (`DepositInitiated` events) and confirm every L2 tx executed
     successfully — any that failed should be `claimFailedDeposit`-ed on the old bridge *before*
     cutover, while it still has `MINTER_ROLE`.

     **This requires an authenticated archive endpoint, and a free one will lie to you.** The
     bridge deployed at block 23579563, so any full-history scan is an archive request. Free
     public endpoints reject those — but not always as an error you will notice:

     | Endpoint | Behaviour on an archive `eth_getLogs` |
     | --- | --- |
     | `ethereum-rpc.publicnode.com` | `-32602 Archive requests require a personal token`, which **`cast logs` reports as `[]` with exit 0** |
     | `eth.drpc.org` | serves single requests, then `403` on sustained scanning |
     | `cloudflare-eth.com`, `rpc.ankr.com/eth`, `eth.merkle.io` | internal error / unauthorized / method not found |

     An empty result here is indistinguishable from "no deposits", and concluding the latter would
     silently skip refundable failed deposits. Sanity-check any scan against a known-present log
     before trusting a zero: block 23579563 must return the constructor's `OwnershipTransferred`
     (`0x8be0079c...`). If it returns nothing, your endpoint is not answering — stop.

     With an Etherscan key:

     ```bash
     curl -s "https://api.etherscan.io/v2/api?chainid=1&module=logs&action=getLogs\
&address=0x2D02b651Ea9630351719c8c55210e042e940d69a\
&topic0=0x5c8b4b222ae9120808577bfefeb97f913b4a7160435dcf81eb32a273dd41ad05\
&fromBlock=23579563&toBlock=latest&apikey=$ETHERSCAN_API_KEY" | jq '.result | length'
     ```

     Then for each `l2DepositTxHash` (topic 1), check the L2 status via
     `zks_getTransactionReceipt` on `https://mainnet.era.zksync.io`; anything failed or missing
     needs `claimFailedDeposit` on the old bridge before it loses `MINTER_ROLE`.
   - Confirm deployer funding: L1 deployment is ~1.4M gas, so budget **≥0.05 ETH** on L1 for
     headroom against a gas spike mid-cutover, plus ~0.02 ETH on zkSync.
   - Set `BRIDGEHUB`, `L2_CHAIN_ID=324`, `LEGACY_BRIDGE=0x2D02b651Ea9630351719c8c55210e042e940d69a`,
     and **clear `L1_BRIDGE` / `L2_BRIDGE`** so both are redeployed. Run with `REDEPLOY=1`, which
     enforces exactly these conditions instead of warning.
2. **Deploy L2Bridge** (new instance, same L2 NODL token). Then, from the zkSync Safe:
   `grantRole(MINTER_ROLE, newL2Bridge)` on L2 NODL `0xBD4372e44c5eE654dd838304006E1f0f69983154`.
   `initialize(newL1Bridge)` is deferred to step 4 — the L1 address does not exist yet.
3. **Deploy L1Bridge** with `LEGACY_BRIDGE`, `BRIDGEHUB`, `L2_CHAIN_ID=324`, and `L2_BRIDGE` set
   to the **new** L2 deployment from step 2. Then, from the Ethereum Safe:
   `grantRole(MINTER_ROLE, newL1Bridge)` on L1 NODL `0x6dd0E17ec6fE56c5f58a0Fe2Bb813B9b5cc25990`.
4. **Initialize + verify.** From the zkSync Safe, `initialize(newL1Bridge)` on the new L2 bridge
   (one-shot, `onlyOwner`). Confirm explorer verification succeeded on both contracts and that
   constructor wiring reads back correctly, then run one small smoke deposit (L1 approve +
   Bridgehub fee) and confirm it mints on L2.
5. **Neutralize the old bridges — ordered, not rushed.** Read the in-flight section below first;
   the old L1 bridge is paused **last**, after a drain, not in the same breath as the deploy.
   1. zkSync Safe: `pause()` the old L2 bridge `0x2c1B65dA72d5Cf19b41dE6eDcCFB7DD83d1B529E`.
      Stops new burns into a path only the old L1 bridge can settle.
   2. **Drain.** Finalize every already-initiated old-L2 withdrawal on the **old L1 bridge**.
      Wait out Era's L2→L1 execute latency until no unfinalized old-L2 withdrawals remain.
   3. Ethereum Safe: `pause()` the old L1 bridge `0x2D02b651Ea9630351719c8c55210e042e940d69a`,
      then `revokeRole(MINTER_ROLE, oldL1Bridge)` on L1 NODL.
   4. zkSync Safe: `revokeRole(MINTER_ROLE, oldL2Bridge)` on L2 NODL.

   Do not announce the new bridge until 5.1 has executed, so users stop being routed at the old
   L2 bridge; the drain in 5.2 may then run for hours without stranding anyone new.
6. **Repoint** the frontend/app and any off-chain services to the new L1 and L2 bridge addresses.
7. **Post-checks**: new-bridge deposit mints on L2; a fresh L2 withdrawal finalizes on the new
   bridge; replaying an old finalized withdrawal reverts (`InvalidProof` via the sender pin, or
   `WithdrawalFinalizedOnLegacyBridge` if the L2 address were ever reused).

### In-flight withdrawals — drain before pausing the old L1 bridge

Every withdrawal in flight at cutover was necessarily initiated on the **old L2 bridge**, so it
carries the old L2 sender in its inclusion proof. The new L1 bridge pins `L2_BRIDGE_ADDR` to the
*new* L2 bridge, so **none of them can finalize on the new bridge** — they revert `InvalidProof`.
They can only ever be finalized on the old L1 bridge.

Pausing the old L1 bridge therefore **strands every in-flight withdrawal**: burned on L2, with no
L1 instance that will pay out. This is the opposite of the "keep the gap short" instinct that
applies when the L2 bridge address is reused, and it drives the ordering in step 5 above.

The counter-risk that motivated a short gap — the same withdrawal finalizing on both instances —
does not apply here, again because of the sender pin: while the old L1 bridge is still live, the
only withdrawals it can finalize are old-L2 ones, and those are exactly the ones the new bridge
rejects. There is no overlap to race.

Draining is bounded work: pausing the old **L2** bridge first stops new burns into the dead path,
after which the set of stranded-in-waiting withdrawals is finite and shrinks as batches execute.

### Rollback / stragglers

If an old-bridge deposit fails on L2 *after* the old bridge was paused, the Safe can temporarily
`unpause()` it (and re-grant `MINTER_ROLE` if revoked) to serve that specific
`claimFailedDeposit`, then re-pause. Refunds live in the old bridge's `depositAmount` map and are
not portable to the new deployment.

The same escape hatch covers a withdrawal missed by the step 5.2 drain: unpause the old L1 bridge,
re-grant `MINTER_ROLE`, `finalizeWithdrawal`, then re-pause and re-revoke. Keep this in mind before
revoking the role — a straggler is recoverable, but only through a multi-signature round trip.

## Monitoring until the cutoff

- Run `ops/check_zksync_deprecation.sh` (mainnet + sepolia) on a cron/CI schedule. It reports the
  Era protocol version and whether the deprecated entrypoint still accepts calls; it exits
  non-zero the moment enforcement is detected.
- Watch the [zksync-developers announcements](https://github.com/zkSync-Community-Hub/zksync-developers/discussions)
  for the enforcement upgrade notice.
- As of 2026-07-28: mainnet is protocol v29.5, Sepolia v29.1 — the legacy entrypoint is still
  accepted on both, so the step 6 rehearsal gate above has not opened yet.

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

## Mainnet cutover sequence

Deposits in flight are unaffected throughout (priority ops already enqueued execute on L2
regardless). The ordering below exists to prevent double-finalization of withdrawals.

1. **Pre-checks**
   - Rerun the fork suite and the canary (above).
   - Enumerate old-bridge deposits (`DepositInitiated` events) and confirm every L2 tx executed
     successfully — any that failed should be `claimFailedDeposit`-ed on the old bridge *before*
     cutover, while it still has `MINTER_ROLE`.
2. **Deploy L2Bridge** (new instance, same L2 NODL token), grant `MINTER_ROLE`, then
   **`initialize(newL1Bridge)`** once the L1 address is known.
3. **Deploy L1Bridge** with `LEGACY_BRIDGE=0x2D02b651Ea9630351719c8c55210e042e940d69a`,
   `BRIDGEHUB`, `L2_CHAIN_ID=324`, and `L2_BRIDGE` set to the **new** L2 deployment from step 2
   (the deploy script grants the new bridge `MINTER_ROLE`; the grant transaction is executed by
   the NODL admin Safe `0x55f5E48A1d30d67ac13751b523Ca1b3cB5838AD8`).
4. **Verify** the deployment: constructor wiring, explorer verification, one smoke deposit with a
   small amount (L1 approve + Bridgehub fee).
5. **Neutralize the old bridge in the same ops window** (Safe transactions):
   - `pause()` the old bridge (blocks its `deposit`, `finalizeWithdrawal`, `claimFailedDeposit`);
   - optionally also `revokeRole(MINTER_ROLE, oldBridge)` on L1 NODL for defense in depth.
   Until this step completes, a withdrawal could be finalized on **both** instances — keep the
   gap between steps 3 and 5 as short as possible, and do not announce the new bridge until
   step 5 is done.
6. **Repoint** the frontend/app and any off-chain services to the new L1 and L2 bridge addresses.
7. **Post-checks**: new-bridge deposit mints on L2; a fresh L2 withdrawal finalizes on the new
   bridge; replaying an old finalized withdrawal reverts with `WithdrawalFinalizedOnLegacyBridge`.

### In-flight withdrawals

Withdrawals initiated on L2 before the cutover but not yet finalized are **not stuck**: they
finalize on the *new* bridge (the guard only blocks `(batch, index)` pairs the old bridge already
paid). This is why pausing the old bridge is safe for users.

**Note:** withdrawals initiated on the **old L2** bridge before redeployment carry the old L2
sender in their inclusion proof. Finalize those on the old L1 bridge before cutover, or accept
that they require the old L1 instance (still paused for new ops) to complete.

### Rollback / stragglers

If an old-bridge deposit fails on L2 *after* the old bridge was paused, the Safe can temporarily
`unpause()` it (and re-grant `MINTER_ROLE` if revoked) to serve that specific
`claimFailedDeposit`, then re-pause. Refunds live in the old bridge's `depositAmount` map and are
not portable to the new deployment.

## Monitoring until the cutoff

- Run `ops/check_zksync_deprecation.sh` (mainnet + sepolia) on a cron/CI schedule. It reports the
  Era protocol version and whether the deprecated entrypoint still accepts calls; it exits
  non-zero the moment enforcement is detected.
- Watch the [zksync-developers announcements](https://github.com/zkSync-Community-Hub/zksync-developers/discussions)
  for the enforcement upgrade notice.
- As of 2026-07-09: mainnet is protocol v29.4, Sepolia v29.1 — enforcement not yet live anywhere.

# Consuming the fundraising contracts

How a service should sit alongside `FundraiserFactory` — what it owns, and what it must not touch. Written against the contracts in [`../`](../), for a module in `nodle-multi-token-api` shaped like the existing `envelope` one.

---

## 1. The rule

**Writes go direct from the client. The service sits beside the contract, never between a person and their money.**

`deposit`, `unpledge`, `refund`, `finalize` and `withdraw` are permissionless — there is no role a service could hold that would let it do anything the caller cannot do themselves. Routing those calls through a service adds no authority, only a dependency that must be up for someone to contribute or get their money back. Removing that dependency is the reason this design is defensible; it is cheap to lose by accident.

There is an existing pattern in that API to *not* copy. `user-collections` holds an operator key and writes on the user's behalf, because `createCollection` is role-gated and there is no alternative. Copying that here would mean a service key that moves user funds — the custody this design deliberately does without.

## 2. What the service owns

Four things the chain cannot do, and one that needs a signer.

**The `externalId` → address mapping.** `externalId` is emitted, never stored, and never verified: anyone can create a fundraise carrying any tag, including one already in use. A fundraise must therefore be resolved from a record written when it was created. This is what makes a service mandatory rather than convenient — without it there is no trustworthy way to say which fundraise is which.

**Listing and progress.** "Which fundraises exist and how far along are they" is an event-indexing question, not an RPC call. Mirror `envelope-index-cache` / `envelope-summary-cache`.

**Refund sweeping.** `refundFor(contributor)` sends funds to the contributor regardless of who calls, so a service can return money without anyone claiming it. Refunds that require action do not get taken. Sweep on entering `Refunding`, and treat the manual `refund` path as the guarantee underneath rather than the mechanism.

**Finalization.** Permissionless `finalize` is the safety net, not the mechanism. Run it on a schedule: at the deadline, and as soon as `raised >= goal`.

**Gas, if fundraises should not require ETH.** `ERC20FeePaymaster` prices each transaction through an off-chain `erc20-fee-signer`. That is a service responsibility; `envelope-paymaster.service.ts` is the template.

## 3. Module shape

```
fundraising/
  fundraising.module.ts
  fundraising.controller.ts        # read-only endpoints
  fundraising.service.ts           # chain reads, address resolution
  fundraising-registry.service.ts  # externalId <-> address records (the source of truth)
  fundraising-index.service.ts     # event indexing, progress cache
  fundraising-sweeper.service.ts   # scheduled refundFor + finalize
  fundraising-paymaster.service.ts # optional, only if gasless is wanted
  fundraising-dto.ts
```

**Endpoints** — all reads. No endpoint should accept a signed transaction or hold a key that can move escrowed funds.

| Method | Path | Returns |
|---|---|---|
| `GET` | `/fundraising/:address` | Status, target, raised, deadline, `onMissed`, token, beneficiary |
| `GET` | `/fundraising/:address/contributions/:account` | One contributor's credited balance and whether they can still withdraw |
| `GET` | `/fundraising?externalId=…` | Addresses resolved from **our records**, never from the on-chain tag |
| `POST` | `/fundraising/records` | Records an `externalId` → address association after a client creates a fundraise |

**Scheduled work**

- Finalize anything past its deadline, or at or above its target.
- Sweep refunds for everything in `Refunding` with a non-zero balance.
- Reconcile the index against `FundraiserCreated` logs, so a fundraise created outside our flow is still visible rather than invisible.

## 4. What to index

```
FundraiserCreated(fundraiser, organizer, token, externalId, goal, deadline, beneficiary)
ContributionMade(contributor, credited, raised)
Unpledged(contributor, amount, raised)
Finalized(outcome, raised, caller)
Cancelled(organizer, raised)
Withdrawn(to, net, fee)
Refunded(contributor, amount)
PayoutAddressChanged(previous, current)
```

Two traps that will otherwise produce an index that quietly disagrees with the chain:

- **Use `credited`, not the call argument.** For a fee-on-transfer token the amount that arrived is less than the amount sent, and the contract credits what arrived.
- **`raised` can go down.** `unpledge` decrements it. Anything assuming monotonic growth is wrong.

Also index `FundraiserCreated` from the factory rather than only recording what our own clients create — otherwise a fundraise created directly against the contract is invisible to us while being perfectly real on-chain.

## 5. What the service must never do

- Hold a key that can move escrowed funds. It has no such key today; none should be introduced.
- Be required for a deposit, a withdrawal, or a refund to succeed.
- Treat the on-chain `externalId` as authoritative.
- Gate `finalize`. If a scheduled job is the only thing that ever calls it, an outage becomes a freeze — the whole point of it being permissionless is that anyone else can.

## 6. Failure modes worth handling explicitly

| Situation | What happens on-chain | What the service should do |
|---|---|---|
| Service is down | Everything still works; people transact directly | Reconcile from logs on restart, not from its own write path |
| A fundraise is created outside our flow | Perfectly valid, invisible to us | Pick it up from `FundraiserCreated` |
| Two fundraises share an `externalId` | Both valid | Resolve from our records; never assume uniqueness |
| Contributor never claims a refund | Funds stay owed indefinitely | Sweep with `refundFor`; alert if a balance stays unswept |
| Beneficiary repoints payout | `PayoutAddressChanged` | Re-read; the constructor value is no longer current |

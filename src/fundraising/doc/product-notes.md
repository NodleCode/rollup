# Group Fundraising — Product Notes

Companion to [the contract specification](spec/group-fundraising-design.md). That document is deliberately scoped to the contract; this one covers what a member actually experiences, the product decisions that shape the contract interface, and the failure modes that are product problems rather than contract problems.

Nothing here changes the escrow's guarantees. Where a product choice would require one to change, it says so.

---

## 1. What a member sees, mapped to contract state

| Contract state | What the app shows | What the member can do |
|---|---|---|
| `Funding`, below goal | "£340 of £500 — 6 days left" | Contribute. **Withdraw their own contribution.** |
| `Funding`, goal reached | "Goal reached! Closing…" | Contribute (until closed). **Withdrawal is gone.** |
| `Succeeded` | "We did it" | Nothing. The beneficiary collects. |
| `Refunding` | "We didn't reach it — your £40 is waiting" | Claim their money back. |
| `Closed` | "Funded and collected" | Nothing. |

Two of these rows are where the product lives or dies.

### 1.1 The disappearing exit

A member can pull their contribution out until the group hits its target, and then cannot. That is the right rule (spec §3.2), but it is a **surprise** unless the app telegraphs it. If someone discovers the exit is gone at the moment they need it, the design reads as a trap regardless of how defensible it is.

So the withdrawal affordance should visibly carry its own expiry from the first screen: *"You can withdraw until the group reaches £500."* When the objective crosses roughly 90%, that becomes an active warning rather than a caption. The moment it latches, every member gets told — not because a notification is nice, but because the alternative is discovering it silently later.

This is the single highest-value piece of copy in the feature.

### 1.2 Refunds that need claiming are refunds that don't happen

When an objective misses its goal, the contract does not push money back. Each member has to claim it. That is a deliberate safety property — push payments to many addresses are a documented failure mode — but as product behavior it is quietly terrible: a chunk of members will simply never come back, and their money sits in a contract forever.

**The contract already solved this and the product should use it.** `refundFor(id, contributor)` can be called by *anyone*, and the funds always go to the contributor. So the backend can sweep refunds on the group's behalf. The member gets their money back without doing anything; nobody can redirect it; no custody is involved.

Recommended: when an objective enters `Refunding`, the backend sweeps every contributor automatically, and the app frames it as *"refunded"* rather than *"claim your refund"*. The manual claim path stays as the guarantee underneath — it is what makes the money safe if the backend never runs at all.

---

## 2. The gap after success

The contract's job ends when the beneficiary withdraws. The *product's* job does not: "we're saving for a trip" is not finished when money lands in the organizer's wallet — it is finished when the trip is booked.

That gap is unaddressed, and it is the part most likely to generate complaints, because it is exactly where members stop being able to see what happened to their money. A group of six who each put in £80 have no visibility past the withdrawal, and the organizer now holds £480 of other people's money with no on-chain obligation whatsoever.

Three ways to close it, in ascending order of work:

1. **Transparency only.** The app shows the withdrawal and asks the beneficiary to post proof of purchase back into the group. Social pressure, no enforcement. Cheap, honest, and probably right for V1 — the group already trusts each other enough to pool money.
2. **Beneficiary is a shared wallet**, not a person, so the money stays visible after collection.
3. **Pay a merchant directly** — the beneficiary is the vendor, not a member. Strongest, and by far the most work.

**Recommendation: (1) for V1, with the beneficiary address surfaced prominently at objective creation.** "Who gets the money if we succeed?" should be an explicit, unmissable step, not a default the organizer clicks past — because that answer is the entire trust model, and the contract deliberately fixes it at creation and never lets the organizer change it.

---

## 3. Product decisions that shape the contract interface

These are open in spec §10. Each changes the interface, so they should be settled before implementation rather than after.

### 3.1 Protocol fee — recommend OFF at launch

Charging a group of friends a percentage to pool their own money is a bad first impression, and the amounts are small enough that a fee is not meaningful revenue at this stage.

The mechanism should still be built: it is snapshotted per objective at creation and capped by a constant, so turning it on later applies only to *new* objectives and cannot touch anything in flight. Ship the capability, default it to zero.

### 3.2 Keep-what-you-raise — recommend NO for V1

All-or-nothing is what "objective" means and it is the stronger member guarantee. The counter-case is real ("we got 80% and want to go anyway"), but it is a guess right now. The enum slot is reserved, so shipping without it costs nothing later.

The thing to watch after launch: **how often objectives fail narrowly.** A tail of groups missing by under 10% is the signal that this needs revisiting. If most failures are far from goal, it never will.

### 3.3 Overshoot — recommend the goal is a close trigger, and say so in the UI

Once the target is hit, anyone can close the objective. "Raise at least X, more welcome" is not expressible, so the app must not let people think it is. Frame goal-setting as *"how much do we need?"* and never as *"minimum"*.

### 3.4 Many objectives per group — recommend yes, with a small cap

Groups genuinely run concurrent things. The contract does not care; the backend should allow a handful and refuse more, so a group's home screen stays legible and one objective's failure doesn't drag on others.

---

## 3.5 The creation form

Five things the organizer decides, and the whole trust model is set by them:

| Field | Default | Notes |
|---|---|---|
| **Name** | — | Stored on-chain, so the objective is self-describing at its own address. Immutable: no renaming a fundraise after people have put money in |
| **Target** | — | Framed as *"how much do we need?"*, never as a minimum (§3.3) |
| **Asset** | **USDC** | Stable is the right default for a purchase-denominated goal — "£500 for the trip" should not drift with a token price |
| **End date** | — | Either a deadline or **none** — an open-ended objective runs until it hits the target or is cancelled |
| **If we miss the target** | **Refund everyone** | Or pay the beneficiary what was raised (`PayBeneficiary` on-chain — see the naming note in spec §6.1) |

Two of these need care in the UI.

**The two options interact.** "If we miss the target" only means something when there *is* a deadline — with no end date there is no moment of missing. The contract rejects that combination outright rather than accepting a setting that can never fire, so the form must hide the question entirely once someone picks "no end date". Showing a dead control is how people end up believing a fundraise behaves in a way it does not.

**"Pay the beneficiary what we raised" is not a peer of "refund everyone."** It removes the member's guarantee of getting their money back. Whatever the form looks like, a member must see which one they are contributing to *before* they contribute — the choice is fixed at creation and readable on-chain precisely so the app can show it honestly. Open decision (spec §10 #2): whether the app restricts it further, rather than offering it as an equal alternative.

**Open-ended objectives are safe for a non-obvious reason.** A fundraise with no deadline that never reaches its target would, in most designs, trap money forever. Here it does not, because withdrawal stays open the whole time it is below target — the goal latch (§1.1) is what makes the "no end date" option possible at all. Worth knowing before anyone proposes removing it.

---

## 3.6 "Anyone can contribute" is a product decision, not just a contract one

The escrow is group-agnostic. It has no idea what a group is, does not check membership, and will accept money from anyone who has the address. Groups are entirely a layer the app draws on top.

Mostly this is a simplification and a gift: contributing needs no round-trip to us for permission, so it keeps working when we are down, and there is no signing key anywhere in the flow to lose. Three things follow that the product has to decide rather than inherit.

**A fundraise link is bearer-shareable.** Anyone holding the address can contribute. Sometimes that is exactly right — someone's parent chips in toward the trip. Sometimes it is not what a group expects from something presented as private. Decide which one we are building; do not let the share sheet decide it.

**Removing someone from the group does not stop them contributing.** It removes the fundraise from their app, nothing more. Support needs to know this before a member asks.

**Anyone can push a stalled fundraise over its target.** Contribute the remaining gap and the target is reached, the exit closes for everyone, and it can be closed out. That is not theft — the money still goes to the beneficiary the group agreed on at creation — but it means "we are at 900 of 1,200, let us all pull out" stops being available the moment anybody covers the difference, including the organizer covering it themselves. The honest way to describe the latch is therefore not *"withdrawals close when the group reaches its target"* but **"your contribution is committed once the target is reached, and anyone can make that happen."**

---

## 4. Backend policy — the decisions the contract deliberately leaves open

The contract enforces mechanics; the backend's signing policy enforces judgement. These need owners:

- **Deadline presets.** Never a free date field. Consumer apps that allow one get 30-year objectives. Offer 1 week / 1 month / 3 months / custom-with-a-ceiling.
- **Minimum contribution.** Nonzero by default. Dust contributions cost more in gas to refund than they return.
- **Maximum objective size.** A sensible ceiling at launch, raised as confidence grows. Cheap insurance against a bug being expensive.
- **Membership revocation does not stop contributions.** The contract has no membership check, so removing someone from a group only removes the fundraise from their app. If they still hold the address, they can contribute to it directly. Their existing contribution is untouched and still refundable either way. Nothing here is a leak of anyone's money — but do not describe removal as if it cut off access, because it does not.
- **Who may be beneficiary.** Any address. The contract does not restrict it, so this is guidance in the creation flow rather than a rule.
- **Single-member objectives.** Organizer, beneficiary and only contributor being the same address makes the contract a personal lockbox. Harmless, but worth a decision rather than an accident.

---

## 5. Failure modes that are product problems

| Situation | What the contract does | What the product must do |
|---|---|---|
| Member contributes the wrong amount | Withdrawable while below goal; stuck after | Confirmation step on larger amounts; make the latch visible (§1.1) |
| Member loses their phone | Refund is payable only to their address | Wallet-level recovery. There is no contract-level fix, and a backend-signed redirect would make the backend custodial — so this must be handled at the wallet layer |
| Group disbands mid-objective | Deadline passes; anyone finalizes; everyone refunds | Nothing needed — it self-heals. Worth saying so in support docs |
| Organizer goes quiet after success | Beneficiary holds the funds | §2. This is the real one |
| Deadline arrives unnoticed | Nothing happens until someone finalizes | Backend finalizes on a schedule. Permissionless finalize is the safety net, not the mechanism |
| Member has no gas | Cannot transact | See spec §8 — pay in NODL via the existing paymaster, or the member needs ETH |

---

## 6. What to measure

If these are not instrumented from day one, the decisions in §3 will be argued from opinion later:

- **Objectives that fail narrowly** (within 10% of goal) — the keep-what-you-raise signal.
- **Withdrawals before the latch** — how much members actually use the exit. If near zero, the whole latch debate was theoretical.
- **Unclaimed refunds** — should be near zero if the backend sweep in §1.2 works. Anything else means members are losing money to inaction.
- **Time from `Succeeded` to the group confirming the thing happened** — the §2 gap, made visible.
- **Objectives created and abandoned** below any contribution — a signal that creation is too easy or the flow is confusing.

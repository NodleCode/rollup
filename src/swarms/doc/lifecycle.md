# Lifecycle & State Machines

## UUID Registration States

```mermaid
stateDiagram-v2
    [*] --> None

    None --> Owned : claimUuid()
    None --> Local : registerFleetLocal()
    None --> Country : registerFleetCountry()

    Owned --> Local : registerFleetLocal()
    Owned --> Country : registerFleetCountry()
    Owned --> [*] : releaseUuid() / burn()

    Local --> Owned : unregisterToOwned()
    Local --> [*] : burn() all tokens

    Country --> Owned : unregisterToOwned()
    Country --> [*] : burn() all tokens

    note right of Owned : regionKey = 0
    note right of Local : regionKey ≥ 1024
    note right of Country : regionKey 1-999
```

### State Transitions

| From          | To      | Function                   | Bond Effect                                                    |
| :------------ | :------ | :------------------------- | :------------------------------------------------------------- |
| None          | Owned   | `claimUuid()`              | Pull BASE_BOND from owner                                      |
| None          | Local   | `registerFleetLocal()`     | Pull BASE_BOND + tierBond from caller (becomes owner+operator) |
| None          | Country | `registerFleetCountry()`   | Pull BASE_BOND + tierBond from caller (becomes owner+operator) |
| Owned         | Local   | `registerFleetLocal()`     | Pull tierBond from operator (only operator can call)           |
| Owned         | Country | `registerFleetCountry()`   | Pull tierBond from operator (only operator can call)           |
| Local/Country | Owned   | `unregisterToOwned()`      | Refund tierBond to operator                                    |
| Owned         | None    | `releaseUuid()` / `burn()` | Refund BASE_BOND to owner                                      |
| Local/Country | None    | `burn()`                   | Refund tierBond to operator; BASE_BOND to owner on last burn   |

## Swarm Status States

```mermaid
stateDiagram-v2
    [*] --> REGISTERED : registerSwarm()

    REGISTERED --> ACCEPTED : acceptSwarm()
    REGISTERED --> REJECTED : rejectSwarm()

    ACCEPTED --> REGISTERED : updateSwarm*()
    REJECTED --> REGISTERED : updateSwarm*()

    REGISTERED --> [*] : delete / purge
    ACCEPTED --> [*] : delete / purge
    REJECTED --> [*] : delete / purge
```

### Status Effects

| Status     | checkMembership | Provider Action Required         |
| :--------- | :-------------- | :------------------------------- |
| REGISTERED | Reverts         | Accept or reject                 |
| ACCEPTED   | Works           | None                             |
| REJECTED   | Reverts         | None (fleet can update to retry) |

## Fleet Token Lifecycle

```mermaid
sequenceDiagram
    participant TOKEN as BOND_TOKEN
    participant FI as FleetIdentity
    participant Owner
    participant Operator

    Note over FI: Fresh Registration (caller = owner+operator)
    FI->>TOKEN: transferFrom(caller, this, BASE_BOND + tierBond)

    Note over FI: Owned → Registered (operator only)
    FI->>TOKEN: transferFrom(operator, this, tierBond)

    Note over FI: Multi-region (operator only)
    FI->>TOKEN: transferFrom(operator, this, tierBond)

    Note over FI: Promotion (operator pays)
    FI->>TOKEN: transferFrom(operator, this, additionalBond)

    Note over FI: Demotion (operator receives)
    FI->>TOKEN: transfer(operator, refund)

    Note over FI: Change Operator (O(1) via uuidTotalTierBonds)
    FI->>TOKEN: transferFrom(newOperator, this, totalTierBonds)
    FI->>TOKEN: transfer(oldOperator, totalTierBonds)

    Note over FI: Unregister to Owned
    FI->>TOKEN: transfer(operator, tierBond)

    Note over FI: Burn (non-last token)
    FI->>TOKEN: transfer(operator, tierBond)

    Note over FI: Burn (last token)
    FI->>TOKEN: transfer(operator, tierBond)
    FI->>TOKEN: transfer(owner, BASE_BOND)
```

## Orphan Lifecycle

```mermaid
flowchart TD
    ACTIVE[Swarm Active] --> BURN{NFT burned?}
    BURN -->|No| ACTIVE
    BURN -->|Yes| ORPHAN[Swarm Orphaned]
    ORPHAN --> CHECK[isSwarmValid returns false]
    CHECK --> PURGE[Anyone: purgeOrphanedSwarm]
    PURGE --> DELETED[Swarm Deleted + Gas Refund]
```

### Orphan Guards

These operations revert with `SwarmOrphaned()` if either NFT invalid:

- `acceptSwarm(swarmId)`
- `rejectSwarm(swarmId)`
- `checkMembership(swarmId, tagHash)`

## Region Index Maintenance

```mermaid
flowchart LR
    REG[registerFleet*] --> FIRST{First in region?}
    FIRST -->|Yes| ADD[Add to activeCountries/activeAdminAreas]
    FIRST -->|No| SKIP[Already indexed]

    BURN[burn / demotion] --> EMPTY{Region empty?}
    EMPTY -->|Yes| REMOVE[Remove from index]
    EMPTY -->|No| KEEP[Keep]
```

Indexes are automatically maintained—no manual intervention needed.

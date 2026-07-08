# User Collections — Backend Integration Guide

This is the operational guide for the **backend service** — the holder of
`OPERATOR_ROLE` on `CollectionFactory`. It describes everything the backend is
responsible for when **creating** collections and **minting** items, plus the
gotchas, error handling, and reconciliation rules.

- Authoritative contract behavior: [`spec/user-collections-specification.md`](spec/user-collections-specification.md)
- Architecture & rationale: [`spec/design-and-implementation.md`](spec/design-and-implementation.md)

---

## 0. Mental model — what the backend is

The backend is the **operator**: a trusted service key that holds `OPERATOR_ROLE`
on the factory. Fiat payments are collected off-chain; once a payment clears, the
backend triggers the matching on-chain action.

| The operator **can** | The operator **cannot** |
|---|---|
| `createCollection721` / `createCollection1155` (it holds `OPERATOR_ROLE`) | Change a collection's metadata / royalties / URI (that's `OWNER_ROLE` = the creator) |
| `mint` / `mintBatch` into any collection where it holds `MINTER_ROLE` (auto-granted at creation) | Upgrade or alter an already-deployed collection (immutable by design) |
| Be revoked by a creator at any time (`OWNER_ROLE` can `revokeRole(MINTER_ROLE, operator)`) | Grant itself `OWNER_ROLE` (collections have no `DEFAULT_ADMIN_ROLE` holder) |

Roles the backend should know:
- **Factory:** `OPERATOR_ROLE` (the backend), `DEFAULT_ADMIN_ROLE` (the admin Safe — not the backend).
- **Per collection:** `OWNER_ROLE` (the creator), `MINTER_ROLE` (creator + operator + any `additionalMinters`).

---

## 1. Prerequisites

| Item | Notes |
|---|---|
| Factory proxy address | The `CollectionFactory` ERC1967 proxy (per environment). Stored as `COLLECTION_FACTORY_PROXY`. |
| Operator key | Must hold `OPERATOR_ROLE` on the factory. Store in HSM/KMS. |
| L2 RPC | zkSync Era endpoint. |
| Gas | The operator pays L2 gas; seed it via `BondTreasuryPaymaster` (or fund the EOA). |
| Impl pointers (optional) | `erc721Implementation()` / `erc1155Implementation()` — needed only for address pre-derivation. |

Sanity check before going live:
```bash
cast call $COLLECTION_FACTORY_PROXY "hasRole(bytes32,address)(bool)" \
  $(cast keccak "OPERATOR_ROLE") $OPERATOR_ADDR --rpc-url $L2_RPC   # must be true
```

---

## 2. Responsibility A — Create a collection

**Trigger:** a creator's fiat payment for collection creation has cleared.

### 2.1 Build `externalId`
A `bytes32` that is your off-chain reconciliation key **and** the CREATE2 salt.
- Must be **non-zero** → else `InvalidExternalId`.
- Must be **unused** (shared namespace across 721 *and* 1155) → else `ExternalIdAlreadyUsed`.
- Convention: `externalId = keccak256(orderId)`.

### 2.2 Choose the standard and assemble params

**`createCollection721(CreateParams721 p, bytes32 externalId)`**

| # | Field | Type | Backend responsibility |
|---|---|---|---|
| 1 | `owner` | `address` | The creator's wallet. **Non-zero** (else `ZeroAddress`). Receives `OWNER_ROLE` + `MINTER_ROLE`. |
| 2 | `name` | `string` | Collection name. |
| 3 | `symbol` | `string` | Collection symbol. |
| 4 | `baseURI` | `string` | See §4 (URI convention). Pass `""` if minting full per-token URIs. |
| 5 | `contractURI` | `string` | Collection-level metadata JSON (pin to IPFS). |
| 6 | `royaltyRecipient` | `address` | ERC-2981 recipient (usually the creator). |
| 7 | `royaltyBps` | `uint96` | Basis points, e.g. `500` = 5%. **Fail-closed:** `> 0` with zero recipient, or `> 10000`, reverts the whole create. Use `0` for none. |
| 8 | `additionalMinters` | `address[]` | Extra `MINTER_ROLE` grants (e.g. co-creator). May be `[]`. You do **not** need to add the operator here — it's auto-granted. |

**`createCollection1155(CreateParams1155 p, bytes32 externalId)`**

| # | Field | Type | Backend responsibility |
|---|---|---|---|
| 1 | `owner` | `address` | Creator wallet, non-zero. |
| 2 | `uri` | `string` | ERC-1155 URI, typically with an `{id}` placeholder. |
| 3 | `contractURI` | `string` | Collection-level metadata. |
| 4 | `royaltyRecipient` | `address` | |
| 5 | `royaltyBps` | `uint96` | Same fail-closed rules as 721. |
| 6 | `additionalMinters` | `address[]` | May be `[]`. (1155 has no name/symbol/baseURI.) |

### 2.3 (Optional) Pre-derive the address
You can compute the collection address **before** broadcasting and show it to the
user. It's a pure CREATE2 function of `(factory, ERC1967Proxy zk bytecode hash,
externalId, abi.encode(impl, initData))`. Use the **current** `erc721Implementation()`
and the **current** operator address. See `design-and-implementation.md` §4 for the
`zksync-ethers utils.create2Address` recipe.

### 2.4 Broadcast
`cast`:
```bash
cast send $COLLECTION_FACTORY_PROXY \
  "createCollection721((address,string,string,string,string,address,uint96,address[]),bytes32)" \
  "($OWNER,My Collection,MYC,ipfs://base/,ipfs://contract.json,$ROYALTY_RCV,500,[])" \
  $(cast keccak "order-123") \
  --rpc-url $L2_RPC --private-key $OPERATOR_KEY --zksync
```
ethers / zksync-ethers:
```ts
const factory = new Contract(FACTORY, [
  "function createCollection721((address,string,string,string,string,address,uint96,address[]) p, bytes32 externalId) returns (address)",
], operatorWallet);

const p = [owner, "My Collection", "MYC", "ipfs://base/", "ipfs://contract.json", royaltyRcv, 500, []];
const externalId = ethers.id(`order-${orderId}`); // keccak256
const tx = await factory.createCollection721(p, externalId);
await tx.wait();
```

### 2.5 Reconcile
- The new address is returned, recorded in `collectionByExternalId[externalId]`, and emitted in `CollectionCreated(creator, collection, standard, externalId)`.
- **Confirm:** `factory.collectionByExternalId(externalId)` → the address.
- **Idempotency:** if a retry hits the same `externalId`, the tx reverts `ExternalIdAlreadyUsed` — treat that as "already created" and look up the existing address. Never let a duplicate trigger create a second collection.
- **State-loss recovery:** re-derive `externalId = keccak256(orderId)` and look it up on-chain.

---

## 3. Responsibility B — Mint items

**Trigger:** either a creator-driven mint, or a buyer's fiat payment for an item sale has cleared.

The operator can mint only while it holds `MINTER_ROLE` on that collection
(auto-granted at creation; the creator may have revoked it — handle the revert).

### 3.1 ERC-721
```solidity
function mint(address to, string calldata tokenURI_) external returns (uint256 tokenId);
function mintBatch(address[] calldata to, string[] calldata uris) external returns (uint256[] memory tokenIds);
```
- IDs are **auto-assigned, sequential** (start at `nextTokenId()`); `mint` returns the new id, `mintBatch` returns the contiguous range in `to` order. Use the return value for per-buyer attribution — don't parse `Transfer` logs or race concurrent minters.
- `tokenURI_` / each `uris[i]` is a **relative suffix** when `baseURI` is non-empty (see §4).
- `mintBatch`: `to.length == uris.length` (else `LengthMismatch`), and `≤ MAX_BATCH (100)` (else `BatchTooLarge`).

```bash
# single
cast send $COLLECTION "mint(address,string)" $BUYER "42.json" \
  --rpc-url $L2_RPC --private-key $OPERATOR_KEY --zksync
```

### 3.2 ERC-1155
```solidity
function mint(address to, uint256 id, uint256 amount, bytes calldata data) external;
function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external;
```
- IDs are **caller-chosen** (you pick `id`). `amount` is the quantity. `data` is usually `0x`.
- `mintBatch` is **single-recipient** (one `to`, many `(id, amount)` pairs). `ids.length == amounts.length` (else `LengthMismatch`), `≤ MAX_BATCH` (else `BatchTooLarge`).

```bash
cast send $COLLECTION "mint(address,uint256,uint256,bytes)" $BUYER 7 3 0x \
  --rpc-url $L2_RPC --private-key $OPERATOR_KEY --zksync
```

### 3.3 If the operator's `MINTER_ROLE` was revoked
Mints revert `AccessControlUnauthorizedAccount(operator, MINTER_ROLE)`. Surface this
to ops — operator-driven sales for that collection are paused until the creator
re-grants the role. (After an operator-key rotation, the new key is auto-granted on
*future* collections only; pre-rotation collections need the creator to grant it.)

---

## 4. Responsibility C — Metadata & URIs

The backend pins metadata (IPFS) and chooses the URI scheme:

- **ERC-721:** the resolved `tokenURI(id) = baseURI + perTokenSuffix`. So either
  - set `baseURI = "ipfs://<cid>/"` at create and pass **relative suffixes** (`"42.json"`) to `mint`, **or**
  - set `baseURI = ""` and pass **full URIs** (`"ipfs://<cid>/42.json"`) to `mint`.
  Do **not** mix (a full URI with a non-empty base yields a broken double-prefixed URL).
- **ERC-1155:** set `uri` (usually with `{id}`); clients substitute the id. There is no per-token URI.
- **Important:** with a non-empty `baseURI`, the *base* is mutable until the creator calls `lockMetadata` — so already-minted tokens can be re-pointed. Only `metadataLocked` is a true freeze. Communicate this to creators/buyers; it is a creator decision, not the backend's.

---

## 5. What the backend does NOT do (creator/`OWNER_ROLE` operations)

These require `OWNER_ROLE`, which the **creator** holds — the operator cannot call them
(unless the backend custodies the creator's wallet, which is a separate product decision):

`setBaseURI` / `setURI`, `setContractURI`, `setDefaultRoyalty`, `lockMetadata`,
`lockRoyalties`, and granting/revoking `MINTER_ROLE`. If the backend surfaces these
in a UI, it must sign them with the creator's key, not the operator key.

---

## 6. Operator key management

- Store the operator key in HSM/KMS; monitor creation/mint rate off-chain (there is no on-chain rate limit).
- **Rotation:** the admin Safe does `revokeRole(OPERATOR_ROLE, oldKey)` then `grantRole(OPERATOR_ROLE, newKey)`. Auto-grant of `MINTER_ROLE` then applies to *future* collections only; for continued operator-driven minting on pre-rotation collections, each creator must grant `MINTER_ROLE` to the new key. Track this in the rotation runbook.
- **Pause:** the admin can revoke all `OPERATOR_ROLE` holders; new creations revert, existing collections are unaffected.

---

## 7. Error reference

| Revert | Where | Meaning / action |
|---|---|---|
| `InvalidExternalId()` | create | `externalId == 0`. Use a non-zero key. |
| `ExternalIdAlreadyUsed(bytes32)` | create | Already created — look up the existing address (idempotent retry). |
| `ZeroAddress()` | create / init | `owner` (or another required address) is zero. |
| `AccessControlUnauthorizedAccount(addr, role)` | create | Caller lacks `OPERATOR_ROLE`. |
| `AccessControlUnauthorizedAccount(addr, MINTER_ROLE)` | mint | Operator's `MINTER_ROLE` was revoked. Pause sales for that collection. |
| `LengthMismatch()` | mintBatch | Array lengths differ. |
| `BatchTooLarge(len, max)` | mintBatch | `len > 100`. Split the batch. |
| ERC-2981 revert | create | `royaltyBps > 0` with zero recipient, or `> 10000`. Validate before sending. |

---

## 8. End-to-end sequences

**Create:** fiat clears → assign `orderId` → `externalId = keccak256(orderId)` →
(optional) pre-derive address → `createCollection721/1155(params, externalId)` →
confirm via `collectionByExternalId` / `CollectionCreated` → mark order complete,
return the address.

**Operator-driven sale:** buyer pays fiat → backend `mint(buyer, ...)` on the
creator's collection (operator holds `MINTER_ROLE`) → `Transfer`/`TransferSingle`
emitted → mark order complete.

**Creator-driven mint:** the creator signs `mint(...)` from their own wallet
(they hold `MINTER_ROLE`); the backend's role here is metadata pinning only.

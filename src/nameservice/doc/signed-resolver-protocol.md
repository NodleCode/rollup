# Signed-Gateway UniversalResolver — Protocol Specification (RFC-style)

> Describes the on-chain contract, the off-chain gateway, and the EIP-712 message

**Last updated:** 2026-04-13

---

## 1. Overview

`UniversalResolver` is an ENS-compatible L1 resolver that answers name-resolution queries for subdomains registered on Nodle's L2 NameService (zkSync Era). It implements the CCIP-Read pattern (ERC-3668) using a **trusted-gateway signature model**: an off-chain gateway reads the L2 NameService directly and returns an EIP-712 signed response, which the contract verifies against a set of trusted signer addresses.

This replaces an earlier design that used zkSync storage proofs against L1-committed batch roots. That design broke when zkSync Era migrated settlement to ZK Gateway (~2025-07-30), at which point per-batch state roots stopped being committed to the L1 Diamond proxy and the proof verifier could no longer be used as a trust anchor.

## 2. Background

- **ENSIP-10 (wildcard resolution)** lets a single resolver answer lookups for any subdomain of a parent name.
- **ERC-3668 (CCIP-Read)** lets a resolver revert with an `OffchainLookup` error that tells ENS clients where to fetch the answer off-chain and which callback to use to verify it.
- **EIP-712** provides structured, domain-bound signatures that cannot be replayed across contracts or chains.

The previous design used zkSync storage proofs as the verification step in the CCIP-Read callback. After the ZK Gateway migration, the batch commitment pipeline that fed those proofs was no longer available on L1; the resolver became unusable and stayed broken until this rewrite.

## 3. Architecture

```
  ENS client              L1 UniversalResolver           Gateway                L2 NameService
  ──────────              ────────────────────           ───────                ──────────────
      │   resolve(name,data)          │                     │                          │
      │ ─────────────────────────────>│                     │                          │
      │                               │                     │                          │
      │  revert OffchainLookup(       │                     │                          │
      │    urls, callData,            │                     │                          │
      │    resolveWithSig,            │                     │                          │
      │    extraData)                 │                     │                          │
      │ <─────────────────────────────│                     │                          │
      │                                                     │                          │
      │   POST {data: callData}                             │                          │
      │ ──────────────────────────────────────────────────> │                          │
      │                                                     │   resolve / getTextRecord│
      │                                                     │ ────────────────────────>│
      │                                                     │ <────────────────────────│
      │                                                     │   EIP-712 sign           │
      │                                                     │                          │
      │  { data: abi(result,expiresAt,sig) }                │                          │
      │ <────────────────────────────────────────────────── │                          │
      │                                                     │                          │
      │   resolveWithSig(response,    │                     │                          │
      │     extraData)                │                     │                          │
      │ ─────────────────────────────>│                     │                          │
      │                               │  verify EIP-712     │                          │
      │                               │  recover signer     │                          │
      │                               │  check trusted      │                          │
      │   result bytes                │                     │                          │
      │ <─────────────────────────────│                     │                          │
```

**Components**

| Component | Location | Responsibility |
|---|---|---|
| `UniversalResolver` | Ethereum L1 | ENSIP-10 entry point, EIP-712 verification, signer registry, admin surface |
| Gateway (`clk-gateway`) | Off-chain HTTPS service | Reads L2 NameService, signs EIP-712 Resolution payloads |
| L2 NameService (`NameService.sol`) | zkSync Era | Canonical source of subdomain ownership and text records |

## 4. L1 Contract Specification

### 4.1 Interfaces

Implements:

- `IExtendedResolver` (ENSIP-10): `resolve(bytes name, bytes data) returns (bytes)`
- `IERC165`
- `Ownable` (OpenZeppelin) — admin surface
- `EIP712` (OpenZeppelin) — typed-data signing primitives

ERC-165 interface IDs reported as supported:

- `0x01ffc9a7` — `IERC165`
- `0x9061b923` — ENSIP-10 extended resolver (equivalent to `type(IExtendedResolver).interfaceId`; the contract accepts either form as an alias)

### 4.2 Supported ENS selectors

| Selector | Signature | Behavior |
|---|---|---|
| `0x3b3b57de` | `addr(bytes32)` | Resolve to owner address on L2 |
| `0xf1cb7e06` | `addr(bytes32,uint256)` | Same, but only accepts `coinType == 2147483972` (zkSync mainnet, per ENSIP-11) |
| `0x59d1d43c` | `text(bytes32,string)` | Resolve text record on L2 |

Any other selector reverts with `UnsupportedSelector(bytes4)`. Any other coin type reverts with `UnsupportedCoinType(uint256)`.

### 4.3 Bare-domain behavior

Queries for the parent domain itself (no subdomain, e.g. `nodl.eth`) are **not** forwarded to the gateway. They return the ENS "no record" convention on L1:

- `addr` / `addr-multichain` → `abi.encode(address(0))` (32-byte padded, so ENS clients can decode it)
- `text` → `abi.encode("")`

Rationale: this resolver holds no state about the parent name — it exists only to answer subdomain lookups. If a specific address must be bound to the bare domain, set a different resolver at the ENS registry level for that node.

### 4.4 Storage

```solidity
string  public url;                         // CCIP-Read gateway URL
address public immutable registry;          // L2 NameService address — METADATA ONLY, not trusted
mapping(address => bool) public isTrustedSigner;
```

**Trust anchor note:** `registry` is metadata for off-chain tooling and auditors. It is never consulted on-chain. The only trust anchor for resolution is the EIP-712 signer set.

### 4.5 Errors

```solidity
error OffchainLookup(address sender, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData);
error UnsupportedCoinType(uint256 coinType);
error UnsupportedSelector(bytes4 selector);
error SignatureExpired(uint64 expiresAt);
error SignatureTtlTooLong(uint64 expiresAt);
error InvalidSigner(address recovered);
```

### 4.6 Events

```solidity
event UrlUpdated(string oldUrl, string newUrl);
event TrustedSignerUpdated(address indexed signer, bool trusted);
```

### 4.7 Admin surface

| Function | Access | Purpose |
|---|---|---|
| `setUrl(string)` | `onlyOwner` | Rotate gateway URL |
| `setTrustedSigner(address, bool)` | `onlyOwner` | Add or revoke a trusted gateway signer |
| `transferOwnership(address)` | `onlyOwner` | Standard OZ handoff |
| `renounceOwnership()` | **blocked** (reverts) | Prevents permanently bricking admin setters |

At least one trusted signer must remain enabled at all times, or all resolution breaks.

## 5. EIP-712 Payload

### 5.1 Domain

```solidity
EIP712("NodleUniversalResolver", "1")
```

Which produces a domain separator over:

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
  name             = "NodleUniversalResolver"
  version          = "1"
  chainId          = <L1 chain id at verification time>
  verifyingContract = <UniversalResolver deployment address>
```

Both the gateway and the contract must agree on these four fields. If the gateway uses the wrong `verifyingContract` or `chainId`, signatures will recover to an untrusted address and `resolveWithSig` will revert with `InvalidSigner`.

### 5.2 Type

```
Resolution(bytes name,bytes data,bytes result,uint64 expiresAt)
```

Field semantics:

| Field | Type | Description |
|---|---|---|
| `name` | `bytes` | DNS-encoded ENS name, as passed to `resolve()` |
| `data` | `bytes` | Original ABI-encoded ENS call (`addr` / `text` / etc.) |
| `result` | `bytes` | ABI-encoded resolution result the gateway is attesting to |
| `expiresAt` | `uint64` | Unix seconds after which this signature must be rejected |

The typehash is:

```solidity
keccak256("Resolution(bytes name,bytes data,bytes result,uint64 expiresAt)")
```

Dynamic `bytes` fields are hashed with `keccak256` per EIP-712 before being packed into the struct hash.

### 5.3 Signature format

Standard 65-byte `(r, s, v)` concatenation, recovered with OpenZeppelin `ECDSA.recover` (which rejects malleable `s` values). `v` is the last byte.

### 5.4 Expiry cap

```solidity
uint64 private constant _MAX_SIGNATURE_TTL = 5 minutes;
```

`resolveWithSig` enforces both `block.timestamp <= expiresAt` and `expiresAt <= block.timestamp + _MAX_SIGNATURE_TTL`. This bounds the replay window if a signer key is compromised: even a maliciously long `expiresAt` is rejected on-chain.

Five minutes was chosen as comfortably above L1 clock skew (a few blocks) while keeping the compromise blast radius small. The gateway currently signs with TTL = 60 seconds, well inside the cap.

## 6. Gateway Protocol

### 6.1 Request

CCIP-Read clients `POST` to the configured gateway URL:

```
POST <url>
Content-Type: application/json   (or text/plain — see below)

{
  "sender": "0x<UniversalResolver address>",
  "data":   "0x<abi.encode(bytes name, bytes data)>"
}
```

The `data` field is exactly the `callData` from the contract's `OffchainLookup` revert, which is `abi.encode(name, data)` with no selector prefix. Defensive: if a misbehaving client wraps the payload with a 4-byte prefix, the gateway strips it and retries decoding. This is not spec-mandated — ERC-3668 §4 says clients forward `callData` unchanged — it is a tolerance for real-world client quirks.

**Content-Type handling:** the ENS app (and some CCIP-Read clients) POST with `Content-Type: text/plain` to avoid triggering a CORS preflight. The gateway parses JSON on both `application/json` and `text/plain`.

### 6.2 Response

```
200 OK
Content-Type: application/json

{
  "data": "0x<abi.encode(bytes result, uint64 expiresAt, bytes signature)>"
}
```

The client passes this blob verbatim to `UniversalResolver.resolveWithSig(response, extraData)` as the `_response` argument. `extraData` is echoed from the original `OffchainLookup` revert and is `abi.encode(name, data)`.

### 6.3 Gateway dispatch

The gateway:

1. Decodes `(name, data)` from the request.
2. Parses the DNS-encoded name into `(sub, domain, tld)`.
3. Routes to the correct L2 NameService contract by parent `domain` (e.g. `nodl` → `NodleNameService`, `clk` → `ClickNameService`).
4. Dispatches on the ENS selector:
   - `addr` / `addr-multichain` → `NameService.resolve(subdomain)` → ABI-encode `address`
   - `text` → `NameService.getTextRecord(subdomain, key)` → ABI-encode `string`
5. On L2 revert (expired, nonexistent), returns the ENS "no record" encoding rather than leaking per-name existence.
6. Signs `Resolution(name, data, result, now + RESOLUTION_SIGNATURE_TTL_SECONDS)` with the gateway signer key.
7. Returns `abi.encode(result, expiresAt, signature)`.

Bare-domain queries (no subdomain) are short-circuited on L1 and never reach the gateway. If one does, the gateway responds with HTTP 400.

## 7. Trust Model

### 7.1 Trust anchor

The **only** trust anchor for resolution correctness is the set of addresses marked `isTrustedSigner[addr] == true`. Neither the `registry` field, the gateway URL, nor the L2 contract address is consulted on-chain.

### 7.2 What a signer compromise allows

An attacker with a trusted signer private key can, for each signed resolution:

- Lie about the owner of any subdomain under any parent domain this resolver serves.
- Lie about the value of any text record.
- Cause ENS clients to display wrong addresses / avatars / profile data for **up to `_MAX_SIGNATURE_TTL` (5 minutes) per signature**.

### 7.3 What a signer compromise does NOT allow

- Minting, transferring, or expiring subdomains (that's L2 NameService state, untouched).
- Changing the resolver URL, adding new trusted signers, or otherwise escalating (those are `onlyOwner`).
- Replaying an old signature after `expiresAt` (cap enforced on-chain).
- Replaying a signature across a different resolver deployment or chain (EIP-712 domain binds `verifyingContract` and `chainId`).

### 7.4 Liveness

The gateway is a **hard dependency** of resolution. If the gateway is down:

- Subdomain resolution fails (clients see an `OffchainLookup` revert with no reachable responder).
- Bare-domain queries for parent names pointed at this resolver still return their zero/empty "no record" response on L1 without a gateway round-trip.
- L2 state is unaffected; users can still register, transfer, and set text records on L2.

There is no on-chain fallback and no on-chain cache. HA must be provided operationally (multiple gateway replicas, stable URL behind a load balancer).

## 8. Rotation Procedures

### 8.1 Signer rotation (zero downtime)

1. Generate a new signing key in the secret manager.
2. Owner calls `setTrustedSigner(newSigner, true)`.
3. Deploy gateway with the new key (blue/green or rolling) and verify it produces valid signatures end-to-end.
4. Owner calls `setTrustedSigner(oldSigner, false)`.
5. Delete the old key material.

At no point should the contract have zero enabled signers.

### 8.2 Gateway URL rotation

1. Stand up the new gateway at a new URL.
2. Owner calls `setUrl(newUrl)`.
3. Retire the old gateway after cache TTLs have expired on the client side.

Note: the old `OffchainLookup` revert for in-flight requests still contains the old URL, so clients with a request already in progress will use the old URL. In practice, CCIP-Read requests are short-lived; a short overlap period is sufficient.

### 8.3 Ownership handoff

Standard `transferOwnership(newOwner)`. Production owner should be a multisig. `renounceOwnership` is intentionally blocked.

### 8.4 Emergency: signer key compromise

1. From the multisig, call `setTrustedSigner(compromisedSigner, false)` immediately — this is the hard kill.
2. Rotate the gateway to a new signer per §8.1.
3. Audit logs for the suspected window of compromise.
4. Communicate externally if any user-facing impact is suspected.

The 5-minute max TTL guarantees that even signatures already in flight expire within that window — no outstanding signed response can be used after this deadline.

## 9. Known Limitations

- **Gateway is a liveness dependency.** See §7.4.
- **No on-chain cache.** Every resolution call triggers a gateway round-trip. Clients typically cache in ENS.js or at the CDN layer.
- **Single contract may serve multiple parent domains.** One deployment can answer for both `nodl.eth` and `clk.eth` via the gateway's domain routing. This is operationally simple but a signer compromise affects both. Blast-radius isolation requires separate deployments with separate signers.
- **Reverse resolution is not supported.** This resolver does not implement `name(bytes32)` or ENSIP-19 reverse records.
- **No on-chain record of signer identities beyond the address.** Associate human-readable labels in an off-chain rotation log.

## 10. Non-Goals

- **Trustless proof of L2 state.** This design is explicitly trust-minimized on the signer set, not trustless. Trustless resolution of zkSync state from L1 requires storage proofs or a ZK light client, neither of which is operationally viable today post-ZK-Gateway.
- **Multi-sig per-resolution responses.** Each response is signed by a single trusted signer. If a future threat model requires k-of-n on individual resolutions, it is a contract upgrade.
- **On-chain fallback if the gateway is down.** There is no L1 mirror of L2 state; none is planned.

## 11. References

- [ENSIP-10: Wildcard Resolution](https://docs.ens.domains/ensip/10)
- [ENSIP-11: EVM Compatible Chain Address Resolution](https://docs.ens.domains/ensip/11)
- [ERC-3668: CCIP Read](https://eips.ethereum.org/EIPS/eip-3668)
- [EIP-712: Typed Structured Data Hashing and Signing](https://eips.ethereum.org/EIPS/eip-712)
- [ERC-165: Standard Interface Detection](https://eips.ethereum.org/EIPS/eip-165)
- `src/nameservice/UniversalResolver.sol`
- `test/nameservice/UniversalResolver.t.sol`
- `clk-gateway/src/resolver/signResolution.ts`
- `clk-gateway/src/routes/resolve.ts`

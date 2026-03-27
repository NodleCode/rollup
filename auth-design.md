# Device Authentication and Trust Registry Architecture

_Version: 2.0 — March 2026_

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current System Analysis](#2-current-system-analysis)
3. [Design Principles](#3-design-principles)
4. [Architecture Overview](#4-architecture-overview)
5. [Protocol 1: Device Onboarding](#5-protocol-1-device-onboarding)
6. [Protocol 2: Per-Request Authentication](#6-protocol-2-per-request-authentication)
7. [EIP-712 vs DPoP — Method Selection](#7-eip-712-vs-dpop--method-selection)
8. [EIP-712 Typed Data Signing — Detailed Treatment](#8-eip-712-typed-data-signing--detailed-treatment)
9. [Smart Contract Design](#9-smart-contract-design)
10. [Session Management](#10-session-management)
11. [Platform Attestation Integration](#11-platform-attestation-integration)
    - 11.6 [Coexistence with Third-Party Attestation SDKs](#116-coexistence-with-third-party-attestation-sdks)
    - 11.7 [Attestation Credential and API Boundary Summary](#117-attestation-credential-and-api-boundary-summary)
12. [CBOR vs JSON for Request Encoding](#12-cbor-vs-json-for-request-encoding)
13. [Key Lifecycle and Rotation](#13-key-lifecycle-and-rotation)
14. [Migration Path from Current System](#14-migration-path-from-current-system)
15. [Security Analysis](#15-security-analysis)
16. [Known Attack Vectors and Mitigations](#16-known-attack-vectors-and-mitigations)
17. [Trade-offs and Open Questions](#17-trade-offs-and-open-questions)

---

## 1. Executive Summary

This document defines two protocols for authenticating mobile SDK clients (edge
scanners) against the backend:

- **Device Onboarding:** A one-time process that establishes a per-device
  cryptographic identity, verifies the device is genuine via platform
  attestation, and registers it on-chain via a ZkSync smart contract.
- **Per-Request Authentication:** A high-throughput off-chain process where each
  HTTP request carries an EIP-712 typed-data signature produced by the device's
  hardware-backed private key, validated against a session token anchored to
  on-chain state.

The next-generation system drops DTN7/BPv7 bundle framing entirely. Clients
send standard HTTP requests directly to the backend. BLE announcement uploads
use CBOR-encoded batch bodies, so one HTTP POST can carry multiple
announcements from multiple BLE tags. The DTN destination-based routing
(cell/ble/heartbeat URIs) is
replaced by distinct HTTP endpoints or a type field in the payload.

The current symmetric-key HMAC model (shared secrets embedded in the SDK binary
and stored in Google Secret Manager) is replaced with per-device asymmetric
keys stored in hardware secure enclaves. ZkSync serves as a neutral public
control plane for publisher trust, device participation state, and canonical
revocation/deprecation signals shared across relayers. Per-request validation
is entirely off-chain.

**Default deployment model (updated v2.0 recommendation).** V2 is intended to
run as a single modular backend service by default, rather than as multiple
networked microservices. Edge admission, onboarding, request authentication,
session handling, and ingest live in one deployable so the hot path avoids
inter-service RPC. Downstream delivery is still modular: the ingest core emits
canonical accepted events to a pluggable streaming sink interface. The default
open-source sink module publishes to Google Pub/Sub with high-throughput
asynchronous batching, and the same Pub/Sub module is reused for both the
supported and legacy lanes with separate topic configuration. Deployers who do
not want Pub/Sub can swap in another sink module through runtime configuration,
and optionally through build-specific packaging if they want a smaller binary.

**Multi-publisher SDK model (v2.0).** The SDK is published as an open-source
library that third-party developers embed in their own applications. Any
publisher who ships an app containing the SDK registers their application
on-chain via a **PublisherRegistry** smart contract. Registration records only
the publisher's Ethereum address and hashed publisher attributes needed for
verification: hashes of the Android package name / iOS bundle ID and the
SHA-256 digest of the signing certificate used to publish the binary. The
backend relayer only onboards devices running apps from publishers whose
on-chain record is active. An `ADMIN_ROLE` can add or remove trusted
publishers. Platform attestation verdicts are validated against the
publisher's registered hashes, so a device can only onboard if the app binary
was signed by a known publisher and installed from the official store.

The device-side on-chain footprint is intentionally minimal: a pseudonymous
device address, publisher binding, app version hash, attestation commitment,
nonce, timestamps, and active status. No raw attestation tokens, no IP
addresses, no GPS/geo data, no account identifiers, and no other user- or
device-identifiable metadata should be written on-chain.

**Two service classes (final v2.0 model).** The system has exactly two
service classes:

- **Supported attested:** Devices on supported platforms that present valid
  platform attestation and pass publisher verification. This is the only
  class eligible for first-class onboarding and on-chain device registration.
- **Legacy unsupported:** Devices below the supported platform floor. They may
  be admitted to a separate low-trust service lane with lower priority,
  stricter limits, and no on-chain device registration.

There is no self-attestation mode. Devices on supported platforms are expected
to include the platform attestation adapter. The core SDK performs a local
platform capability check and fails onboarding on supported platforms if the
attestation adapter is not present. Because the SDK is open source, a
malicious publisher could remove that check; the governance answer is that
NODL DAO approval of a publisher's registered binary and publisher record is
conditional on shipping the approved attestation-enabled build for supported
platforms.

**Key properties:**

| Property                     | How                                                                                                                                                                                                     |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Privacy minimization         | Device address is pseudonymous; on-chain state is limited to hashes, bindings, revocation state, and non-PII commitments                                                                                |
| Neutral shared trust set     | Publisher and device participation state live in public registries that multiple relayers can consume                                                                                                   |
| Portable participation state | Device state is not trapped in one provider database; publisher binding and revocation state are portable across relayers                                                                               |
| Canonical revocation source  | Independent refresh services converge on the same publisher/device revocation and app deprecation state                                                                                                 |
| Security                     | Per-device hardware-backed keys; platform attestation; body-bound signatures; shared publisher trust state                                                                                              |
| Platform cost model          | No documented per-attestation or per-verification platform fee in the standard Apple App Attest and Google Play Integrity paths; operational limits are quota/rate-limit based rather than usage-billed |
| Scale                        | Per-request auth is entirely off-chain; chain writes are batched and rare                                                                                                                               |
| Public verifiability         | Auditability and tamper evidence are acceptable side effects, while the design minimizes public data disclosure                                                                                         |
| Future extensibility         | Staking, slashing, and self-registration remain optional future extensions, not present-day requirements                                                                                                |

### 1.1 Platform Baseline And Coverage Impact

The security claims in this document assume the following supported platform
floor for **full-trust participation**:

- **Android:** Android 13+ with server-verified Play Integrity and at least
  `MEETS_DEVICE_INTEGRITY`
- **iOS:** iOS 16+ with App Attest

Devices below that floor are outside the full-trust v2.0 security model. They
may still be admitted only through the separate legacy unsupported service
class and are not equivalent to supported attested participation.

This platform floor has a measurable coverage cost, especially on Android:

| Platform | Baseline assumption | Fresh public data                                                                                                                                                                                                                              | Coverage implication                                                                                                                   |
| -------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Android  | Android 13+         | StatCounter worldwide mobile+tablet share for Feb 2026 shows Android 13, 14, and 15 together at about **50.1%** of Android traffic; if its separate `16.0` bucket is treated as the current-release line, Android 13+ rises to about **69.0%** | Android 13+ is a meaningful coverage constraint. The design should treat this as a deliberate security trade-off, not a rounding error |
| iOS      | iOS 16+             | Apple reports that as of Feb 12, 2026, **90%** of all active iPhones and **94%** of iPhones introduced in the last four years run **iOS 18 or later**                                                                                          | Because iOS 18+ is a strict lower bound for iOS 16+, the iOS 16+ assumption has a relatively small coverage cost on active iPhones     |

Implication for the rest of this document: when it says a device is
"supported", "genuine", or in the normal security model, it assumes those
platform floors. The design does not rely on pre-Android-13 or pre-iOS-16
compatibility paths to justify its main security claims.

Devices below that floor may still be admitted only through the separate
legacy unsupported service class. That class is explicitly outside the
full-trust security model, is not eligible for on-chain device registration,
and must not be described as equivalent to supported attested participation.

---

## 2. Current System Analysis

### 2.1 Current request flow

```
  SDK                        dtn-outbox                   Redis          key-provision       Secret Manager
   |                            |                           |                 |                    |
   |-- POST /outbox ----------->|                           |                 |                    |
   |   Authorization: Bearer    |                           |                 |                    |
   |   <HMAC-signed JWT>        |                           |                 |                    |
   |   Body: CBOR(DTN7 bundle)  |                           |                 |                    |
   |                            |-- GET deny:<ip> --------->|                 |                    |
   |                            |<- nil / banned -----------|                 |                    |
   |                            |                           |                 |                    |
   |                            |-- lookup kid from JWT --->|                 |                    |
   |                            |   (in-memory cache,       |- poll --------->|-- list ENABLED --->|
   |                            |    refreshed every 15m)   |                 |                    |
   |                            |                           |                 |                    |
   |                            |-- SETNX dtnh:<hash> ----->|                 |                    |
   |                            |<- OK / replay found ------|                 |                    |
   |                            |                           |                 |                    |
   |                            |-- CBOR decode DTN7 ------>|                 |                    |
   |                            |-- protobuf decode ------->|                 |                    |
   |                            |-- route by DTN URI ------>|                 |                    |
   |                            |-- publish to Pub/Sub ---->|                 |                    |
   |                            |                           |                 |                    |
   |<- 202 Accepted ------------|                           |                 |                    |
```

### 2.2 What changes in the next generation

| Aspect              | Current                                     | Next generation                                    |
| ------------------- | ------------------------------------------- | -------------------------------------------------- |
| Transport           | DTN7/BPv7 bundle over HTTP                  | Plain HTTP request                                 |
| Body encoding       | CBOR wrapping DTN bundle wrapping protobuf  | CBOR batches for BLE ingest; JSON for control APIs |
| Routing             | DTN destination URI inside bundle           | Distinct HTTP endpoints or payload `type` field    |
| Auth                | Symmetric HMAC JWT with custom claims       | Per-device asymmetric key + EIP-712 signature      |
| Key storage         | Shared secrets in Secret Manager            | Per-device key in hardware secure enclave          |
| Replay protection   | Redis SETNX on body hash                    | Monotonic nonce per device                         |
| Device identity     | None (all installations share a key family) | On-chain Ethereum address                          |
| Device verification | Self-declared `device_status` claim         | Platform attestation (Play Integrity / App Attest) |

### 2.3 Weaknesses addressed

| Current weakness                                       | Impact                                                           | New design fix                                                          |
| ------------------------------------------------------ | ---------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Symmetric HMAC secrets shared across all installations | One leaked secret compromises all devices using that key version | Per-device asymmetric keypair in hardware enclave                       |
| Secrets embedded in app binary                         | Extractable via reverse engineering                              | Private key never leaves secure enclave; attestation proves genuine app |
| No per-device identity                                 | Cannot revoke a single compromised device                        | On-chain device registry with per-address revocation                    |
| `device_status` is self-declared                       | Client can claim "genuine" without proof                         | Backend verifies platform attestation before registration               |
| Custom non-standard JWT claims                         | Every validator must understand bespoke contract                 | Standard JWT (RFC 7519) for session + EIP-712 for proof                 |
| Redis-only replay protection                           | No durable audit trail; lost on Redis restart                    | Monotonic nonce per device (persistent, simpler)                        |
| DTN bundle framing overhead                            | Extra encoding layers (CBOR + DTN + protobuf)                    | Direct HTTP; BLE uploads use CBOR batch bodies with no DTN or protobuf  |

---

## 3. Design Principles

1. **Hardware-rooted identity.** Each device's private key lives in the secure
   enclave and never leaves it. Identity is an Ethereum-format address derived
   from the public key.

2. **Verify then trust, with bounded trust windows.** On-chain state is the
   canonical source for publisher trust, device participation, revocation,
   and app deprecation. Off-chain session tokens cache that shared state for a
   bounded period. No unbounded trust window.

3. **Backend is a verifier and relayer, not the sole control plane.** The
   backend verifies attestation and issues sessions, but the smart contracts
   hold the shared publisher/device state that multiple relayers and refresh
   services can consume.

4. **Attestation at the gate, signatures on every request.** Platform
   attestation (expensive, one-time) proves the app is genuine. Per-request
   EIP-712 signatures (cheap, every time) prove the request comes from the
   registered device.

5. **Open-source compatible.** Security does not depend on source code secrecy.
   It depends on app signing certificates (controlled by the publisher) and
   hardware enclaves (controlled by the device manufacturer).

6. **Standards over custom protocols.** Use EIP-712 (already proven in the
   team's prior work), standard JWT (RFC 7519), platform attestation APIs, and
   ZkSync native account abstraction rather than inventing new schemes.

7. **Publisher trust chain.** The SDK is a library, not an application. Trust
   in a device starts with trust in the publisher who shipped the app
   containing the SDK. Publishers register on-chain using hashes of app-store
   identifiers and certificate digests; device attestation is validated
   against those registered values. Unknown publishers are rejected at the
   gate.

8. **Minimal public disclosure.** The chain stores only what is necessary for
   sound shared verification: publisher hashes, device publisher binding,
   app-version hash, revocation/nonce state, and attestation commitment. It
   does not store raw attestation evidence, IPs, user identifiers, location,
   or other unnecessary ecosystem metadata.

9. **Defense in depth, not single-layer security.** No single mechanism
   (attestation, obfuscation, or economic stake) is sufficient in isolation.
   This design layers hardware-rooted identity, platform attestation,
   per-request cryptographic proofs, behavioral monitoring, on-chain
   publisher trust, and session tiering to raise the cost of abuse at every
   level. Each layer is assumed to be individually bypassable by a
   sufficiently motivated attacker; the combination makes sustained abuse
   economically impractical.

10. **Separate low-trust traffic before it becomes expensive.** Unsupported
    platforms are handled in a dedicated legacy service lane with earlier
    rejection, lower limits, separate queues, and separate worker capacity so
    low-trust traffic cannot consume the same bounded resources as supported
    attested traffic.

---

## 4. Architecture Overview

```mermaid
flowchart TD
    subgraph Client["Mobile Device"]
        SE["Secure Enclave
        secp256k1 or P-256 keypair"]
        SDK["Third-Party App
(embeds Nodle SDK)"]
        PA["Platform Attestation
        (Play Integrity / App Attest)"]
    end

    subgraph Publisher["App Publisher"]
        PUB["Publisher Wallet
(Ethereum address)"]
    end

    subgraph Backend["V2 Gateway (default deployment: one Cloud Run service)"]
        OB["Onboarding Module"]
      EDGE["Edge Admission
(rate + size checks)"]
        AUTH["Auth Middleware"]
        CORE["Ingest Core
(replaces dtn-outbox)"]
      LEGACY["Legacy Lane Policy
(low-priority context)"]
        SINK["Streaming Sink Interface"]
        PUBSINK["Pub/Sub Sink Module
(default OSS module)"]
        SESS["Session + Nonce Store
        (Redis)"]
    end

    subgraph Chain["ZkSync Era"]
        PREG["PublisherRegistry
        (Smart Contract)"]
        REG["DeviceRegistry
        (Smart Contract)"]
        PM["Paymaster
        (gas sponsor)"]
    end

    subgraph Downstream
        PS["GCP Pub/Sub"]
      LPS["Legacy Pub/Sub topic
or low-priority queue"]
    end

    PUB -->|"0. registerPublisher(addr,
packageHash, bundleHash,
certHash)"| PREG

    SDK -->|"1. generate keypair"| SE
    SDK -->|"2. get attestation"| PA
    PA -->|"3. attestation token"| SDK
    SDK -->|"4. POST /v2/onboard
pubkey + attestation
+ publisher_address"| OB
    OB -->|"5a. verify attestation
(Apple/Google API)"| OB
    OB -->|"5b. verify publisher
is registered + active"| PREG
    OB -->|"5c. hash attested app ID
and compare to publisher record"| OB
    OB -->|"6. registerDevice(address,
publisher, attestationHash)
via paymaster"| REG
    PM -->|"pays gas"| REG
    OB -->|"7. issue session token"| SDK

    SDK -->|"8. POST /v2/scan/ble
Authorization: Bearer session_token
X-Signature: EIP-712 sig
Body: CBOR batch"| EDGE
    EDGE -->|"9a. supported-attested lane"| AUTH
    EDGE -->|"9b. legacy unsupported lane"| LEGACY
    AUTH -->|"10. validate token
+ EIP-712 sig
+ publisher active"| AUTH
    AUTH -->|"11. check session
+ nonce"| SESS
    AUTH -->|"12. forward"| CORE
    LEGACY -->|"10. throttle / rate-limit / shed"| CORE
    CORE -->|"13. canonical accepted events"| SINK
    SINK -->|"14a. supported topic"| PUBSINK
    SINK -->|"14b. legacy topic"| PUBSINK
    PUBSINK -->|"15a. publish"| PS
    PUBSINK -->|"15b. publish"| LPS
    AUTH -.->|"periodic: verify
on-chain state"| REG
    AUTH -.->|"periodic: verify
publisher active"| PREG
```

The edge admission function is intentionally minimal and cheap. In Google
Cloud, representative implementations include External HTTPS Load Balancer +
Cloud Armor for coarse IP and geo controls, optionally followed by a thin
Cloud Run edge service or API Gateway/Apigee policy layer for body-size caps,
header validation, and fast rejection before deeper auth or downstream work.

The updated deployment recommendation is a modular monolith: one deployable for
the supported hot path, with module boundaries in code rather than internal
HTTP or gRPC boundaries. This keeps the request path simple and avoids a new
inter-service communication layer just to separate concerns. The sink boundary
remains explicit so provider-specific streaming logic stays isolated from the
auth and ingest core.

The default sink module is Pub/Sub and is open-source alongside the rest of the
gateway. It should be implemented using asynchronous publish, client-side
batching, and flow control rather than per-message blocking. The same Pub/Sub
module is reused for both supported and legacy traffic; lane-specific behavior
comes from policy and topic selection, not from duplicating the publisher
implementation.

### 4.1 Deployment And Sink Modules

Recommended default cloud shape per environment:

- External HTTPS Load Balancer + Cloud Armor for coarse admission control
- one main Cloud Run V2 gateway service for onboarding, auth, sessioning, and
  supported ingest
- Memorystore for Redis for sessions, nonce tracking, and abuse controls
- Google Pub/Sub for downstream event streaming
- Cloud KMS for backend signing keys and relayer credentials

Optional cloud components:

- API Gateway or Apigee if policy-heavy API management is required
- a separate Cloud Run service for the legacy unsupported lane if operational
  isolation becomes necessary later

Recommended module boundaries inside the V2 gateway:

- edge admission module
- onboarding module
- auth and nonce validation module
- session and refresh module
- ingest core module
- streaming sink interface
- provider modules such as Pub/Sub, Kafka, Event Hubs, or Kinesis

Recommended sink selection model:

- runtime configuration is the primary mechanism for choosing the active sink
- optional build-specific packaging can exclude unused provider modules, but it
  is a packaging optimization rather than the primary extensibility mechanism
- all sink modules publish the same canonical accepted event contract produced
  by the ingest core

This means the same open-source gateway can be deployed unchanged with the
default Pub/Sub path, or reused by another deployer with a different sink
module while preserving the same upstream authentication and ingest behavior.

### 4.2 New endpoint structure (replaces DTN URI routing)

| Current                                               | New                        | Purpose                                |
| ----------------------------------------------------- | -------------------------- | -------------------------------------- |
| `POST /outbox` (DTN dest: `dtn://nodle.io/ble/scan`)  | `POST /v2/scan/ble`        | CBOR batch upload of BLE announcements |
| `POST /outbox` (DTN dest: `dtn://nodle.io/cell/scan`) | `POST /v2/scan/cell`       | Cell scan data                         |
| `POST /outbox` (DTN dest: `dtn://nodle.io/heartbeat`) | `POST /v2/heartbeat`       | Device heartbeat                       |
| `GET /config/<version>`                               | `GET /v2/config/<version>` | SDK config (unchanged)                 |
| `POST /onboard` (new)                                 | `POST /v2/onboard`         | Device registration                    |
| `POST /session/refresh` (new)                         | `POST /v2/session/refresh` | Session renewal                        |
| (new)                                                 | `POST /v2/publisher`       | Publisher on-chain registration        |
| (new)                                                 | `GET /v2/publisher/:addr`  | Query publisher status                 |
| (new)                                                 | `POST /v2/legacy/scan/ble` | Legacy unsupported low-priority ingest |

---

## 5. Protocol 1: Device Onboarding

### 5.1 Overview

Onboarding establishes a device identity, proves the device is genuine,
verifies that the hosting app was published by a trusted publisher, registers
the device in the shared on-chain registry, and issues the first session
token. It happens once per app installation.

Because the SDK is an open-source library embedded in third-party apps, the
onboarding service must verify not only the device but also the **publisher**.
The attestation verdict from Google or Apple contains the app's package name
(Android) or bundle ID (iOS) and signing certificate. The onboarding service
hashes the attested app identifier, compares it against the on-chain
PublisherRegistry, and confirms that the app was shipped by a registered
publisher.

On supported platforms, onboarding requires the platform-specific attestation
adapter. The core SDK performs a runtime platform check and fails onboarding
locally if the platform is supported but no attestation provider is present.
This local check is an integration safeguard, not the primary security
boundary. The enforceable backend rule is publisher policy: publishers whose
approved builds are registered for full-trust participation must present valid
attestation or onboarding is rejected.

The chain is used here as a neutral shared trust set, not as a place to store
attestation evidence or user-identifiable metadata. Raw attestation tokens and
plaintext app identifiers remain off-chain.

Legacy unsupported devices do not use this onboarding path. They are not
registered in `DeviceRegistry` and do not receive the same service class as
supported attested devices.

### 5.2 Sequence diagram

```mermaid
sequenceDiagram
    autonumber
    participant D as Device (SDK)
    participant SE as Secure Enclave
    participant PA as Platform Attestation
    participant B as Backend (Onboarding Service)
    participant V as Apple/Google Verification
    participant PR as ZkSync PublisherRegistry
    participant Z as ZkSync DeviceRegistry
    participant R as Redis (Session Store)

    Note over D,SE: Step A: Identity Generation
    D->>SE: Generate keypair (secp256k1 or P-256)
    SE-->>D: Public key (private key stays in enclave)
    D->>D: Derive Ethereum address from public key

    Note over D,PA: Step B: Platform Attestation
    D->>B: GET /v2/onboard/challenge
    B-->>D: challenge (random 32 bytes), expires_at
    D->>PA: Request attestation with challenge as nonce
    PA-->>D: Signed attestation token

    Note over D,B: Step C: Registration Request
    D->>B: POST /v2/onboard -- address, pubkey, attestation_token,<br/>challenge, platform, publisher_address

    Note over B,V: Step D: Attestation Verification
    B->>V: Verify attestation token (Play Integrity API or App Attest)
    V-->>B: Verdict -- app_integrity, device_integrity,<br/>packageName/bundleId, certDigest, version
    B->>B: Validate challenge matches and has not expired
    B->>B: Validate verdicts pass minimum threshold

    Note over B,PR: Step E: Publisher Verification
    B->>PR: getPublisher(publisher_address)
    PR-->>B: Publisher record -- packageHash, bundleHash,<br/>certHash, active
    B->>B: Verify keccak(packageName) from attestation<br/>matches publisher record (Android)
    B->>B: Verify keccak(bundleId) from attestation<br/>matches publisher record (iOS)
    B->>B: Verify certDigest from attestation matches<br/>publisher certHash
    B->>B: Verify publisher is active

    Note over B,Z: Step F: On-Chain Registration
    B->>Z: registerDevice(address, publisher_address,<br/>appVersionHash, attestationHash) via Paymaster
    Z-->>B: Transaction receipt -- nonce set to 0, active set to true

    Note over B,D: Step G: Session Token Issuance
    B->>B: Create session JWT signed by backend key
    B->>R: Store session metadata -- address, publisher,<br/>nonce 0, expires
    B-->>D: session_token, token_type, expires_in, chain_nonce
```

### 5.3 Onboarding HTTP contract

**Challenge request:**

```http
GET /v2/onboard/challenge HTTP/1.1
Host: api.nodle.io
```

**Challenge response:**

```json
{
  "challenge": "a1b2c3d4e5f6...64_hex_chars",
  "expires_at": 1710600120
}
```

**Registration request:**

```http
POST /v2/onboard HTTP/1.1
Host: api.nodle.io
Content-Type: application/json

{
  "address": "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18",
  "pubkey": "0x04bfcab2932...(uncompressed public key hex)",
  "attestation": "<base64 Play Integrity or App Attest token>",
  "challenge": "a1b2c3d4e5f6...",
  "platform": "android",
  "publisher_address": "0xPublisherEthereumAddress"
}
```

**Registration response:**

```json
{
  "session_token": "eyJhbGciOiJFZERTQSIsInR5cCI6...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "device_address": "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18",
  "publisher_address": "0xPublisherEthereumAddress",
  "chain_nonce": 0
}
```

### 5.4 Attestation verification rules

**Device integrity checks (platform attestation):**

| Check             | Android (Play Integrity)                                                                    | iOS (App Attest)                                                                                                                          |
| ----------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Token signature   | Verified via Google `decodeIntegrityToken` API (server-to-server)                           | Verified against Apple App Attest Root CA (local verification using public root CA; no publisher credentials required — see section 11.6) |
| App identity      | `keccak256(packageName)` matches publisher's registered package hash                        | `keccak256(bundleId)` + Team ID match publisher record                                                                                    |
| Signing cert      | `certificateSha256Digest` matches publisher's registered `certHash`                         | Certificate chain validates to expected Team ID                                                                                           |
| Device integrity  | Verdict includes `MEETS_DEVICE_INTEGRITY` (minimum) or `MEETS_STRONG_INTEGRITY` (preferred) | Hardware attestation flag present                                                                                                         |
| App integrity     | `appRecognitionVerdict` is `PLAY_RECOGNIZED`                                                | Certificate chain valid                                                                                                                   |
| Challenge binding | `nonce` / `requestHash` matches the server-issued challenge                                 | Challenge embedded in attestation object                                                                                                  |
| Freshness         | Token issued within last 60 seconds                                                         | Assertion counter is new                                                                                                                  |
| Platform floor    | `deviceAttributes.sdkVersion` ≥ 33 (Android 13+) for the supported baseline                 | iOS 16+ for the supported baseline                                                                                                        |

**Publisher verification checks (on-chain cross-reference):**

| #   | Check                               | What                                                                             | Failure code |
| --- | ----------------------------------- | -------------------------------------------------------------------------------- | ------------ |
| P1  | Publisher exists                    | `PublisherRegistry.getPublisher(publisher_address)` returns a record             | 403          |
| P2  | Publisher is active                 | `publisher.active == true`                                                       | 403          |
| P3  | Package name hash matches (Android) | `keccak256(attested packageName)` == publisher's registered `androidPackageHash` | 403          |
| P4  | Bundle ID hash matches (iOS)        | `keccak256(attested bundleId)` == publisher's registered `iosBundleHash`         | 403          |
| P5  | Cert hash matches                   | Attestation `certificateSha256Digest` == publisher's `certHash`                  | 403          |

The backend only proceeds to on-chain device registration (Step F) if **all**
device integrity checks **and** all publisher verification checks pass. This
ensures that the device runs an unmodified binary from a known, trusted
publisher.

If attestation is missing for a publisher enrolled in the supported attested
class, the request fails; it does not downgrade into legacy service. Legacy
service is reserved for unsupported platforms, not for supported platforms
that omitted the adapter or removed the attestation flow.

### 5.5 Off-chain verification with on-chain commitment

Verifying Play Integrity or App Attest tokens directly in a smart contract is
not practical. It would require parsing complex signed payloads (JWS for
Android, CBOR/X.509 for iOS), maintaining Apple/Google root certificates
on-chain, and paying significant gas.

Instead, the backend verifies off-chain and commits a minimal **attestation
commitment hash** on-chain:

```
attestationHash = keccak256(abi.encode(
  sha256(attestation_token_bytes),
  publisher_address,
  keccak256(bytes(app_version_string)),
  keccak256(bytes(platform_string)),
  verifier_policy_version
))
```

This creates a tamper-evident record while keeping the raw attestation token
and any verifier-specific details off-chain. Anyone can later challenge
whether the backend verified honestly by requesting the original attestation
token (stored off-chain by the backend), recomputing the commitment, and
re-verifying it independently.

---

## 6. Protocol 2: Per-Request Authentication

### 6.1 Overview

Every data submission request must prove four things:

1. The sender holds the private key of a registered device (proof of possession)
2. The request body has not been tampered with (integrity)
3. The request is fresh and not a replay (freshness + nonce)
4. The device has a valid, unexpired session (authorization)

For BLE ingest, a single request may carry multiple announcements from
multiple BLE tags. The signature covers the raw CBOR request body as one blob,
so batching does not weaken integrity or replay protection.

### 6.2 Request structure

```http
POST /v2/scan/ble HTTP/1.1
Host: api.nodle.io
Content-Type: application/cbor
Authorization: Bearer <session_token>
X-Signature: <hex-encoded EIP-712 signature>
X-Nonce: 42
X-Timestamp: 1710600042

<raw CBOR body containing a BLE announcement batch>
```

The BLE upload path is CBOR-only. The client does not send JSON or protobuf on
this path.

### 6.2.1 BLE batch body model

The `/v2/scan/ble` request body is a CBOR document containing a batch of BLE
announcements collected by the device. A single POST may include
announcements from several observed BLE tags.

Illustrative logical shape before CBOR encoding:

```javascript
{
  scannerTime: 1710600042,
  announcements: [
    {
      tagId: "ble-tag-a",
      payload: h'0201060AFF4C001005031C7A8E55',
      rssi: -67,
      seenAt: 1710600039
    },
    {
      tagId: "ble-tag-b",
      payload: h'02011A1BFF99040601020304',
      rssi: -74,
      seenAt: 1710600040
    }
  ]
}
```

This document standardizes the transport and encoding choice, not the final
field schema. The key architectural constraint is that BLE uploads are raw
CBOR batches and are not wrapped in protobuf messages.

| Header          | What                                                           | Who produces it                   |
| --------------- | -------------------------------------------------------------- | --------------------------------- |
| `Authorization` | Session token (standard JWT)                                   | Backend, at onboarding or refresh |
| `X-Signature`   | EIP-712 typed-data signature over request metadata + body hash | Device secure enclave             |
| `X-Nonce`       | Monotonic per-device counter                                   | Device SDK                        |
| `X-Timestamp`   | Unix timestamp of request creation                             | Device SDK                        |

### 6.3 Session token (issued by backend)

The session token is a standard JWT (RFC 7519) signed by the backend's private
key (EdDSA or ES256).

The JWT is still issued and enforced off-chain. The chain's role is to provide
the canonical shared publisher/device state that refresh services consult when
deciding whether a session can continue.

**Header:**

```json
{
  "alg": "EdDSA",
  "typ": "at+jwt",
  "kid": "backend-key-2026-03"
}
```

**Payload:**

```json
{
  "iss": "https://api.nodle.io",
  "sub": "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18",
  "aud": "nodle-scan",
  "iat": 1710600000,
  "exp": 1710603600,
  "jti": "unique-session-id-uuid",
  "chain_nonce": 0,
  "app_version": "3.2.1",
  "pubkey_hash": "0xSHA256_of_device_public_key",
  "publisher": "0xPublisherEthereumAddress"
}
```

Key fields:

- `sub`: Device's Ethereum address (on-chain identity).
- `pubkey_hash`: SHA-256 of the device's public key. The server uses this to
  verify that the EIP-712 signature on each request was produced by the same
  key that was registered during onboarding.
- `publisher`: The Ethereum address of the publisher who shipped the app
  containing the SDK. Used during session refresh to re-verify that the
  publisher is still active on-chain.
- `chain_nonce`: The on-chain nonce at the time the session was created. If a
  re-attestation increments the on-chain nonce, sessions created with the old
  nonce become invalid on the next refresh check.
- `exp`: Standard JWT expiry. Forces periodic re-validation against on-chain
  state.

### 6.4 EIP-712 per-request signature (signed by device)

The device signs an EIP-712 typed-data structure covering the request metadata
and body hash. See section 8 for the full EIP-712 specification.

### 6.5 Validation sequence

```mermaid
sequenceDiagram
    autonumber
    participant D as Device (SDK)
    participant LB as Load Balancer
    participant A as Auth Middleware
    participant R as Redis (Session + Nonce)
    participant S as Scan Ingest Service
    participant Z as ZkSync (periodic only)

    D->>D: Build CBOR batch body with one or more BLE announcements
    D->>D: body_hash = SHA-256(body)
    D->>D: Increment local nonce
    D->>D: Sign EIP-712 typed data with enclave key
    D->>LB: POST /v2/scan/ble + headers + body

    LB->>A: Forward (adds X-Client-Geo-Location)

    Note over A: Step 1: Session Token
    A->>A: Decode session JWT
    A->>A: Verify backend signature (EdDSA)
    A->>A: Check exp greater than now
    A->>A: Check iss, aud

    Note over A: Step 2: EIP-712 Signature
    A->>A: Reconstruct EIP-712 typed-data hash from request headers + body hash
    A->>A: ecrecover(signature) to get signer public key
    A->>A: Verify SHA-256(recovered pubkey) matches session token pubkey_hash
    A->>A: Verify derived address matches session token sub

    Note over A,R: Step 3: Replay + Nonce
    A->>R: GET device_nonce:0x742d...
    R-->>A: last_seen_nonce (e.g. 41)
    A->>A: Verify X-Nonce greater than last_seen_nonce
    A->>R: SET device_nonce:0x742d... = 42

    Note over A: Step 4: Freshness
    A->>A: Verify X-Timestamp within allowed drift window

    Note over A: Step 5: Body Integrity
    A->>A: Compute SHA-256 of raw body
    A->>A: Compare to body_hash inside the signed EIP-712 data

    A->>S: Forward validated request with device context
    S-->>D: 202 Accepted

    Note over A,Z: Periodic (not per-request)
    A->>Z: Read devices[address].active and .nonce
    A->>A: If revoked or nonce mismatch then invalidate session
```

### 6.6 Validation summary

| #   | Check                   | What                                        | Failure code   | Current system equivalent               |
| --- | ----------------------- | ------------------------------------------- | -------------- | --------------------------------------- |
| 1   | Session token signature | Backend EdDSA/ES256                         | 401            | (no equivalent)                         |
| 2   | Token expiry            | `exp > now`                                 | 401            | Custom timestamp + max_delay            |
| 3   | EIP-712 signature       | ecrecover matches `sub` and `pubkey_hash`   | 401            | HMAC verification against shared secret |
| 4   | Nonce                   | X-Nonce > last_seen_nonce                   | 401            | Redis SETNX on body hash                |
| 5   | Freshness               | X-Timestamp within +-60s of server time     | 401            | Custom timestamp + max_drift            |
| 6   | Body integrity          | Computed body hash matches signed body_hash | 401            | Body hash in custom JWT claim           |
| 7   | IP ban                  | Redis deny:ip                               | 403            | Same (unchanged)                        |
| 8   | Device active           | On-chain active == true                     | 401 on refresh | (no equivalent)                         |
| 9   | Publisher active        | On-chain publisher.active == true           | 403 on refresh | (no equivalent)                         |

---

## 7. EIP-712 vs DPoP — Method Selection

The team has prior experience with EIP-712 for off-chain signed messages. DPoP
(RFC 9449) was considered as an alternative. This section compares the two and
justifies the choice.

### 7.1 Comparison

| Criterion                  | EIP-712                                                     | DPoP (RFC 9449)                                           |
| -------------------------- | ----------------------------------------------------------- | --------------------------------------------------------- |
| **Standard**               | EIP (Ethereum Improvement Proposal), widely adopted in Web3 | IETF RFC, designed for OAuth 2.0 ecosystem                |
| **Ecosystem fit**          | Native to Ethereum/ZkSync; all Web3 libraries support it    | Native to OAuth/OIDC; less Web3 tooling                   |
| **On-chain verifiability** | Signatures can be verified in Solidity directly             | Cannot be verified on-chain without custom logic          |
| **Team familiarity**       | Previously used in the project                              | Not previously used                                       |
| **Key type**               | secp256k1 native                                            | Supports multiple key types but secp256k1 is non-standard |
| **Body binding**           | Included in typed data natively                             | Extension required (not in core RFC)                      |
| **Request structure**      | One signature header + session token                        | Two JWTs per request (access token + DPoP proof JWT)      |
| **Complexity**             | Single signature scheme                                     | Two token types with binding between them                 |
| **Human readability**      | Typed-data structs are interpretable by wallets             | Opaque JWT                                                |
| **Address recovery**       | Built-in: ecrecover gives signer address                    | Not applicable; uses JWK thumbprint matching              |

### 7.2 Decision

**EIP-712 is selected** for the following reasons:

1. **On-chain verifiability.** If the system ever needs to verify a request
   signature on-chain (e.g., for dispute resolution or decentralized
   validation), EIP-712 signatures can be checked in Solidity with a single
   `ecrecover` call. DPoP signatures cannot.

2. **Simpler request format.** One session token + one signature header vs. two
   JWTs per request. Less parsing, less overhead.

3. **Team experience.** The team has already implemented EIP-712 signing. This
   reduces implementation risk.

4. **Web3 alignment.** The system uses ZkSync, Ethereum addresses, and smart
   contracts. EIP-712 is native to this ecosystem. DPoP would be an OAuth
   pattern grafted onto a Web3 system.

5. **Equivalent security.** Both provide proof-of-possession, body binding,
   replay protection, and freshness. Neither is stronger than the other for
   this use case.

### 7.3 What is kept from the DPoP concept

While the signing mechanism is EIP-712, the session management borrows two
ideas from DPoP/OAuth:

- **Sender-constrained tokens.** The session token contains `pubkey_hash`,
  binding it to a specific device key. A stolen session token is useless
  without the device's private key.
- **Standard JWT claims.** The session token uses registered claims (`iss`,
  `sub`, `aud`, `exp`, `iat`, `jti`) instead of the current custom claims.

---

## 8. EIP-712 Typed Data Signing — Detailed Treatment

### 8.1 What is EIP-712

EIP-712 defines a standard for signing structured data with Ethereum keys. It
produces a deterministic hash of a typed data structure that can be signed with
`eth_signTypedData` and verified on-chain with `ecrecover`.

The standard ensures:

- Signatures are domain-separated (cannot be replayed across different
  contracts or applications).
- Data structures are explicitly typed (prevents ambiguity in encoding).
- The signed data is human-readable when presented by a wallet.

### 8.2 Domain separator

```javascript
const domain = {
  name: "Nodle Network",
  version: "2",
  chainId: 324, // ZkSync Era mainnet
  verifyingContract: "0x<DeviceRegistry_address>",
};
```

The domain separator ties signatures to this specific application on this
specific chain. A signature produced for Nodle Network on ZkSync cannot be
replayed on a different application or chain.

### 8.3 Type definitions

```javascript
const types = {
  ScanRequest: [
    { name: "method", type: "string" },
    { name: "path", type: "string" },
    { name: "bodyHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "timestamp", type: "uint256" },
    { name: "sessionId", type: "bytes32" },
  ],
};
```

| Field       | Purpose                                    | How populated                                                                      |
| ----------- | ------------------------------------------ | ---------------------------------------------------------------------------------- |
| `method`    | HTTP method binding (e.g., `"POST"`)       | Prevents cross-method replay                                                       |
| `path`      | HTTP path binding (e.g., `"/v2/scan/ble"`) | Prevents cross-endpoint replay                                                     |
| `bodyHash`  | SHA-256 of the raw request body            | Integrity; body tampering invalidates signature                                    |
| `nonce`     | Monotonic per-device counter               | Replay protection; must be strictly increasing                                     |
| `timestamp` | Unix timestamp of request creation         | Freshness check                                                                    |
| `sessionId` | `keccak256(session_token)`                 | Binds signature to a specific session; stolen sessions are useless without the key |

### 8.4 Signing process (client side)

```
1. Device builds the request body as a CBOR batch of one or more BLE
  announcements.
2. Device computes bodyHash = SHA-256(body).
3. Device increments its local persistent nonce counter.
4. Device constructs the EIP-712 typed data:
     message = {
       method:    "POST",
       path:      "/v2/scan/ble",
       bodyHash:  bodyHash,
       nonce:     42,
       timestamp: 1710600042,
       sessionId: keccak256(session_token_bytes)
     }
5. Device computes the EIP-712 hash:
     digest = keccak256(
       "\x19\x01" ||
       domainSeparatorHash ||
       keccak256(encodeData(ScanRequest, message))
     )
6. Device signs the digest with its enclave-held private key:
     (v, r, s) = sign(digest, privateKey)
7. Device sends the HTTP request with:
     Authorization: Bearer <session_token>
     X-Signature: 0x<r><s><v>   (65 bytes, hex-encoded = 130 chars + 0x prefix)
     X-Nonce: 42
     X-Timestamp: 1710600042
     Content-Type: application/cbor
    Body: <raw CBOR batch bytes>
```

### 8.5 Verification process (server side)

```
1. Parse X-Signature, X-Nonce, X-Timestamp from headers.
2. Parse and verify the session JWT (signature, exp, iss, aud).
3. Reconstruct the EIP-712 typed data from the request:
     message = {
       method:    request.Method,
       path:      request.URL.Path,
       bodyHash:  SHA-256(request.Body),
       nonce:     X-Nonce,
       timestamp: X-Timestamp,
       sessionId: keccak256(raw session_token bytes)
     }
4. Compute the EIP-712 digest (same as client).
5. ecrecover(digest, signature) → recovered public key.
6. Verify:
     a. SHA-256(recovered_pubkey) == session_token.pubkey_hash
     b. address_from(recovered_pubkey) == session_token.sub
7. Check X-Nonce > last_seen_nonce for this device address (Redis).
8. Check X-Timestamp within allowed drift (±60s).
9. Update last_seen_nonce in Redis.
10. Stream body through SHA-256 hasher; verify matches bodyHash used in
    the signed data structure.
```

### 8.6 Example full request

```http
POST /v2/scan/ble HTTP/1.1
Host: api.nodle.io
Content-Type: application/cbor
Authorization: Bearer eyJhbGciOiJFZERTQSIsInR5cCI6ImF0K2p3dCIsImtpZCI6ImJhY2tlbmQta2V5LTIwMjYtMDMifQ.eyJpc3MiOiJodHRwczovL2FwaS5ub2RsZS5pbyIsInN1YiI6IjB4NzQyZDM1Q2M2NjM0QzA1MzI5MjVhM2I4NDRCYzllNzU5NWYyYkQxOCIsImF1ZCI6Im5vZGxlLXNjYW4iLCJpYXQiOjE3MTA2MDAwMDAsImV4cCI6MTcxMDYwMzYwMCwianRpIjoiZDE0NzZmMDktYThjNC00ZjU1LTlhNTAtMzk4YTE5MDcyODRlIiwiY2hhaW5fbm9uY2UiOjAsImFwcF92ZXJzaW9uIjoiMy4yLjEiLCJwdWJrZXlfaGFzaCI6IjB4YjVhZTY4ZjRhMjc1MDhiMTIzNDU2Nzg5MGFiY2RlZjAwMTIzNDU2Nzg5MGFiY2RlZjAwMTIzNDU2Nzg5MGFiIn0.<backend_signature>
X-Signature: 0x4a8b...65_bytes_hex_encoded
X-Nonce: 42
X-Timestamp: 1710600042

<CBOR-encoded BLE announcement batch>
```

### 8.7 Optional on-chain verification

Because EIP-712 signatures are natively verifiable in Solidity, the system can
optionally verify request signatures on-chain for dispute resolution:

```solidity
function verifyRequest(
    address device,
    string calldata method,
    string calldata path,
    bytes32 bodyHash,
    uint256 nonce,
    uint256 timestamp,
    bytes32 sessionId,
    bytes calldata signature
) external view returns (bool) {
    bytes32 structHash = keccak256(abi.encode(
        SCAN_REQUEST_TYPEHASH,
        keccak256(bytes(method)),
        keccak256(bytes(path)),
        bodyHash,
        nonce,
        timestamp,
        sessionId
    ));
    bytes32 digest = _hashTypedDataV4(structHash);
    address signer = ECDSA.recover(digest, signature);
    return signer == device && devices[device].active;
}
```

This is not used in the hot path but provides a publicly verifiable
mechanism for auditing or dispute resolution.

---

## 9. Smart Contract Design

### 9.1 PublisherRegistry interface

The PublisherRegistry tracks which app publishers are authorized to have their
users onboard onto the network. Publishers register hashes of app-store
identifiers and signing certificate digests. Only publishers with an active
record can have devices onboarded through backend relayers.

**On-chain data and PII considerations:** No personally identifiable information
is stored on-chain. The publisher's Ethereum address is pseudonymous. The
registry stores hashes of public app-store identifiers plus certificate
digests, not plaintext identifiers. This minimizes disclosure while preserving
cross-relayer verifiability. Because app identifiers come from a limited public
namespace, these hashes should be treated as disclosure-minimizing rather than
confidential.

**Verifier inputs for Apple App Attest:** Apple's App Attest validation
procedure requires the verifier to know the publisher's plaintext iOS App ID
(`TeamID.BundleID`) and the expected App Attest environment (`development` or
`production`) for the build channel being validated. In this design, those
values are part of the publisher registration data that the backend resolves
when processing a registered publisher. The current minimal on-chain record is
hash-oriented and does not by itself expose all plaintext verifier inputs, so
the registration/control-plane design must ensure those inputs are available to
the verifier and cross-checked against the on-chain hashes (`iosBundleHash`,
`iosCertHash`) before use. This keeps the trust anchors explicit without
re-introducing Apple secret credentials.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPublisherRegistry {
    struct Publisher {
        uint64  registeredAt;         // block.timestamp of registration
        bytes32 androidPackageHash;   // keccak256(android package name string)
        bytes32 iosBundleHash;        // keccak256(iOS bundle ID string)
        bytes32 androidCertHash;      // SHA-256 of Android signing certificate
        bytes32 iosCertHash;          // SHA-256 of iOS signing certificate (Team ID derived)
        bool    active;               // false means suspended
    }

    event PublisherRegistered(
        address indexed publisher,
        bytes32 androidPackageHash,
        bytes32 iosBundleHash
    );
    event PublisherSuspended(
        address indexed publisher,
        string reason
    );
    event PublisherReinstated(
        address indexed publisher
    );

    /// @notice Register a new publisher. Callable by PUBLISHER_ADMIN_ROLE.
    /// @dev The plaintext package name and bundle ID are NOT stored on-chain.
    ///      Only their keccak256 hashes are stored. The backend verifies by
    ///      hashing the attested identifier before comparison.
    function registerPublisher(
        address publisher,
        bytes32 androidPackageHash,
        bytes32 iosBundleHash,
        bytes32 androidCertHash,
        bytes32 iosCertHash
    ) external;

    /// @notice Suspend a publisher. All devices under this publisher will
    ///         fail session refresh until the publisher is reinstated.
    function suspendPublisher(
        address publisher,
        string calldata reason
    ) external;

    /// @notice Reinstate a previously suspended publisher.
    function reinstatePublisher(address publisher) external;

    /// @notice Update a publisher's certificate hashes (e.g. after key rotation).
    function updatePublisherCerts(
        address publisher,
        bytes32 newAndroidCertHash,
        bytes32 newIosCertHash
    ) external;

    /// @notice Read publisher state (publicly readable shared control-plane state).
    function getPublisher(address publisher)
        external view returns (Publisher memory);

    function isPublisherActive(address publisher)
        external view returns (bool);
}
```

**Why on-chain rather than a backend database?**

- **Neutral public trust set:** Multiple relayers or service providers can
  consume the same publisher trust registry without relying on one operator's
  private database.
- **Canonical revocation source:** Independent refresh services converge on the
  same publisher suspension state.
- **Portable control plane:** Publisher trust state survives backend
  replacement and can be reused by new service providers.
- **Tamper evidence as a side effect:** Registration, suspension, and version
  changes become globally observable, but this is a side effect rather than the
  primary goal.
- **Future extensibility:** Self-registration, staking, and slashing can be
  added later without redesigning the trust surface.

### 9.2 DeviceRegistry interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDeviceRegistry {
    struct Device {
        uint64  registeredAt;       // block.timestamp of registration
        uint64  lastAttestationAt;  // block.timestamp of last re-attestation
        uint256 nonce;              // incremented on re-attestation or key event
        address publisher;          // publisher address from PublisherRegistry
        bytes32 appVersionHash;     // keccak256(app version string)
        bytes32 attestationHash;    // commitment to attestation evidence
        bool    active;             // false means revoked
    }

    event DeviceRegistered(
        address indexed device,
        bytes32 appVersionHash
    );
    event DeviceRevoked(
        address indexed device,
        string reason
    );
    event DeviceReattested(
        address indexed device,
        uint256 newNonce
    );
    event AppVersionDeprecated(
        bytes32 indexed versionHash
    );

    /// @notice Register a new device. Callable by RELAYER_ROLE only.
    /// @dev Reverts if publisher is not active in PublisherRegistry.
    function registerDevice(
        address device,
        address publisher,
        bytes32 appVersionHash,
        bytes32 attestationHash
    ) external;

    /// @notice Batch registration for efficiency.
    function registerDeviceBatch(
        address[] calldata devices,
        address[] calldata publishers,
        bytes32[] calldata appVersionHashes,
        bytes32[] calldata attestationHashes
    ) external;

    /// @notice Re-attestation. Increments nonce, updates attestation data.
    function reattestDevice(
        address device,
        bytes32 newAppVersionHash,
        bytes32 newAttestationHash
    ) external;

    /// @notice Revoke a single device. Callable by ADMIN_ROLE.
    function revokeDevice(
        address device,
        string calldata reason
    ) external;

    /// @notice Deprecate an app version. Devices running this version
    ///         must re-attest before their next session refresh.
    function deprecateAppVersion(bytes32 versionHash) external;

    /// @notice Read device state (publicly readable shared control-plane state).
    function getDevice(address device)
        external view returns (Device memory);

    function isActive(address device)
        external view returns (bool);

    function isAppVersionValid(bytes32 versionHash)
        external view returns (bool);
}
```

**Device registry privacy boundary:** The device registry is intentionally
minimal. It stores a pseudonymous device address plus the minimum shared state
needed for sound coordination across relayers: publisher binding,
app-version hash, attestation commitment, nonce, timestamps, and active flag.
It does not store raw public keys, attestation blobs, IP addresses, location,
or user-linked identifiers.

### 9.3 Access control

```
Roles (OpenZeppelin AccessControl):

  RELAYER_ROLE
    - Can call registerDevice, registerDeviceBatch, reattestDevice
    - Assigned to backend service accounts
    - Cannot revoke devices or manage publishers

  ADMIN_ROLE
    - Can call revokeDevice, deprecateAppVersion
    - Assigned to ops team
    - Cannot register devices (separation of duties)

  PUBLISHER_ADMIN_ROLE
    - Can call registerPublisher, suspendPublisher, reinstatePublisher,
      updatePublisherCerts
    - Assigned to governance multisig or ops team
    - Controls the set of trusted app publishers
    - Separation from ADMIN_ROLE allows different operational teams
      to manage publishers vs. devices

  UPGRADER_ROLE
    - Can upgrade the contracts via UUPS proxy
    - Held by multisig or timelock

Both PublisherRegistry and DeviceRegistry use OpenZeppelin UUPS
upgradeable proxy from day one to allow migration if bugs are found.
```

### 9.4 Batch registration

To handle high device registration volumes:

```
Option A: Batch calldata (recommended to start)
  - registerDeviceBatch() accepts arrays
  - One transaction registers up to approximately 200 devices
  - Backend queues registrations and flushes every N seconds or M devices
  - Simple to implement; adequate for initial scale

Option B: Merkle commitment (for higher scale)
  - Backend builds Merkle tree of new device addresses
  - Submits only the Merkle root on-chain
  - Devices prove inclusion via Merkle proof at session refresh time
  - Lower on-chain cost; higher backend and client complexity
```

### 9.5 App version deprecation flow

When a new SDK version is released:

1. Backend calls `deprecateAppVersion(oldVersionHash)` on-chain.
2. On next session refresh, backend calls `isAppVersionValid(hash)` and sees
   `false`.
3. Backend forces those devices through re-attestation (onboarding Step B
   onward).
4. If the device has updated the app, re-attestation succeeds with the new
   version hash. If not, the session is not renewed.

This replaces the current `DISABLED_KIDS` env var mechanism with a shared,
tamper-evident version deprecation signal.

---

## 10. Session Management

### 10.1 Session lifecycle

```mermaid
stateDiagram-v2
    state "First Install" as FI
    state "Active Session" as AS
    state "Session Expired" as SE
    state "Refresh Check" as RC
    state "Re-Attestation" as RA
    state "Revoked" as RV

    [*] --> FI
    FI --> AS: Onboarding complete
    AS --> AS: Per-request auth (fast path)
    AS --> SE: exp reached
    SE --> RC: Backend checks on-chain state
    RC --> AS: On-chain OK and version valid
    RC --> RA: Version deprecated or nonce mismatch
    RA --> AS: New attestation verified
    RA --> RV: Attestation fails
    AS --> RV: Admin revokes on-chain
    RV --> [*]
```

### 10.2 Service classes and session lifetimes

| Service class      | Lifetime | When used                                                                  |
| ------------------ | -------- | -------------------------------------------------------------------------- |
| Supported attested | 6 hours  | Device passed attestation and publisher verification                       |
| Legacy unsupported | Short    | Unsupported platform admitted to low-priority service with stricter limits |

The service class is determined at issuance and encoded in the session or
request context. For simplicity in v2.0, supported devices that are already in
the supported attested class and are temporarily unable to refresh attestation
continue to receive the same service level during the bounded refresh grace
window. This simplification does not apply to first onboarding.

Legacy unsupported sessions should be materially shorter-lived than supported
attested sessions and may be omitted entirely in favor of simpler low-trust
admission tokens or edge rate control.

### 10.3 Session refresh flow

The refresh path is where the shared on-chain control plane matters most
operationally. Multiple independent refresh services can issue replacement
sessions while converging on the same canonical revocation, publisher, and app
deprecation state.

```mermaid
sequenceDiagram
    autonumber
    participant D as Device
    participant B as Backend
    participant R as Redis
    participant Z as ZkSync

    D->>B: POST /v2/session/refresh -- old session_token + EIP-712 sig
    B->>B: Verify old session token is expired but within grace window
    B->>B: Verify EIP-712 signature matches device

    B->>Z: getDevice(address)
    Z-->>B: Device state -- active, nonce, appVersionHash, publisher
    B->>Z: isPublisherActive(device.publisher)
    Z-->>B: Publisher active status

    alt Device active and publisher active and version valid and nonce matches
        B->>R: Update session -- new jti, reset nonce counter
        B-->>D: New session_token
    else Version deprecated
        B-->>D: 401 -- re-attestation required
    else Device revoked
        B-->>D: 403 -- device revoked
    else Publisher suspended
        B-->>D: 403 -- publisher suspended
    end
```

### 10.4 Redis session state

```
Key:     session:{device_address}
Type:    Hash
Fields:
  jti           -- current session token ID
  chain_nonce   -- on-chain nonce at session creation
  last_nonce    -- last seen per-request nonce from device
  publisher     -- publisher address from on-chain record
  created_at    -- session creation timestamp
  ip            -- IP address at session creation
  tier          -- supported_attested / legacy_unsupported
TTL:     matches session token exp + grace window
```

Legacy traffic should use separate Redis namespaces such as `legacy:*` and
must not rely primarily on claimed per-device identity for abuse control.
Rate control for legacy traffic is keyed first by coarse network and publisher
signals such as IP, subnet, ASN, and publisher address because software-only
legacy identities are cheap to mint.

**Comparison to current Redis usage:**

| Current Redis key  | Purpose                        | New equivalent                                                         |
| ------------------ | ------------------------------ | ---------------------------------------------------------------------- |
| `dtnh:<body_hash>` | Replay detection via body hash | `session:{addr}` field `last_nonce` (monotonic nonce)                  |
| `deny:<ip>`        | IP ban list                    | Unchanged                                                              |
| `ip:<ip>`          | Per-IP new-key tracking        | Adapted: tracks device addresses per IP instead of HMAC key identities |
| `nk:<country>`     | New-key country stats          | Unchanged                                                              |

---

## 11. Platform Attestation Integration

### 11.1 Android — Play Integrity API

```
Flow:
1. SDK calls IntegrityManager.requestIntegrityToken()
   with the server-generated challenge as the nonce.
2. Google Play Services returns a signed integrity token.
3. SDK sends the token to the backend.
4. Backend calls Google verification endpoint:
   POST https://playintegrity.googleapis.com/v1/{packageName}:decodeIntegrityToken
5. Google returns the verdict.

Required verdicts for registration:
  appRecognitionVerdict:  PLAY_RECOGNIZED
  deviceRecognitionVerdict: includes MEETS_DEVICE_INTEGRITY
  appLicensingVerdict:    LICENSED (optional, for paid apps)

Supported baseline for this design:
  Android 13+ devices only
```

**Verification credential model (Android):**

- The backend calls Google's `decodeIntegrityToken` server-to-server API using
  a GCP service account bound to the publisher's Play Console project. This is
  the same GCP project the publisher already operates to distribute the app
  via Google Play — no new credential type is introduced by this design.
- Multiple SDKs within the same app can each call
  `IntegrityManager.requestIntegrityToken()` independently. Play Integrity
  tokens are app-scoped, not SDK-scoped, and each backend decodes them using
  its own GCP service account.
- For SDK-level distribution specifically, Google offers the **Play SDK
  Console** which allows SDK providers to receive integrity signals about
  their SDK across host apps. The primary verification in this design uses
  the app-level token, but the SDK Console path is available as a
  complementary signal.

### 11.2 iOS — App Attest

```
Flow:
1. SDK gets an attestation key via DCAppAttestService.
2. SDK calls attestKey(keyId, clientDataHash) where clientDataHash
   is the SHA-256 of the server-generated challenge.
3. Apple returns a CBOR attestation object signed by Apple CA.
4. SDK sends the attestation to the backend.
5. Backend verifies:
   - Certificate chain up to Apple App Attest Root CA
   - App ID (Team ID + Bundle ID) matches expected values
   - Challenge matches the one issued by the server
   - Attestation counter is valid

Supported baseline for this design:
  iOS 16+ devices only
```

**Verification credential model (iOS):**

- The backend verifies App Attest attestation and assertion objects **locally**
  using only Apple's publicly distributed **App Attest Root CA** certificate.
  No Apple Developer Portal private key (`.p8`), Key ID, or Team ID secret is
  needed by the backend for this verification. The expected App ID
  (`TeamID.BundleID`) and expected App Attest environment are resolved from
  the publisher registration control plane and cross-checked against the
  publisher's on-chain hashes before use.
- This design uses **App Attest** (`DCAppAttestService`), not **DeviceCheck**.
  Apple DeviceCheck is a separate server-to-server API that provides a 2-bit
  per-device state and requires a `.p8` private key for authentication. This
  design does not use DeviceCheck and has no dependency on `.p8` credentials.
- App Attest is still **host-app owned configuration** even though it is not a
  host-app owned secret. The host app controls the App Attest capability /
  entitlement on the app target and, during development, the App Attest
  environment (`development` vs `production`). The SDK can use the framework,
  but it cannot privately own those app-target settings.
- `DCAppAttestService.shared.generateKey()` creates a new independent
  hardware-backed key pair each time it is called. An app can hold multiple
  App Attest keys simultaneously. This means multiple SDKs within the same
  app can each generate and manage their own attestation keys without
  collision or contention — there is no per-app singleton key.

### 11.3 Multi-publisher SDK compatibility

The SDK is an open-source library. Different publishers embed it in their own
apps, each signed with the publisher's own certificate and distributed through
official app stores. Attestation binds to the **publisher's signing
certificate and app store identifier**, not to SDK source code.

To minimize public disclosure, the chain stores only hashes of those publisher
identifiers. The backend compares hashed attested values against the registry;
it does not require plaintext app identifiers to be published on-chain.

| Scenario                                                         | Attestation result                              | Publisher check result                     |
| ---------------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------ |
| Registered publisher's app from Play Store / App Store           | Passes all device checks                        | packageName/bundleId + certHash match      |
| Unregistered publisher's app (legitimate but not yet registered) | Passes device checks                            | **Fails**: publisher not in registry       |
| Recompiled from open source with different signing cert          | Fails `PLAY_RECOGNIZED` / fails bundle ID check | Fails: certHash mismatch                   |
| Registered publisher's app on a rooted phone                     | Fails `MEETS_DEVICE_INTEGRITY`                  | N/A (device check fails first)             |
| Modified binary, re-signed with attacker cert                    | Fails `PLAY_RECOGNIZED`                         | Fails: certHash mismatch                   |
| Registered publisher ships malicious SDK fork                    | Passes all checks                               | Passes — mitigated by publisher revocation |

Security depends on:

- **Publisher registration**: Only apps from publishers whose signing
  certificate hash and hashed app identifiers are recorded on-chain are
  accepted. This is the outer gate.
- **Apple/Google attestation**: Verifies the binary on the device matches the
  publisher's signed binary and that the device hardware is uncompromised.
- **Publisher revocation**: If a publisher is found to be malicious or
  compromised, an admin revokes them on-chain. All devices registered under
  that publisher are force-refreshed and denied new sessions.

None of this requires SDK source code secrecy. A third-party developer who
forks the SDK and builds their own app must register as a publisher before
their users can onboard.

### 11.3.1 Core SDK and attestation adapter packaging

The SDK is split into a core module and optional platform-specific attestation
adapter modules:

- `core`: key generation, EIP-712 signing, onboarding/session protocol,
  challenge handling, transport, and runtime capability checks
- `android attestation adapter`: Play Integrity integration for supported
  Android builds
- `ios attestation adapter`: App Attest integration for supported iOS builds

The core SDK exposes an attestation provider interface. On supported
platforms, the app is expected to ship `core + platform adapter`. On
unsupported platforms, the app may ship `core` only and use the legacy
unsupported service class.

Representative integration guidance:

| App packaging choice | Intended use                    | App developer responsibilities                                                                          |
| -------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Core + adapter       | Supported attested full service | Add the adapter dependency, enable the platform capability, and initialize the provider in the core SDK |
| Core only            | Legacy unsupported service only | Integrate only the core SDK and accept low-priority service with no on-chain registration               |

**Publisher credential requirements for attestation:**

| Platform | What Nodle backend needs from publisher                                                                  | What publisher already has                                                                       | New setup required by this design                                                                                                |
| -------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| iOS      | No secret credentials; verifier inputs for plaintext App ID (`TeamID.BundleID`) and expected environment | Apple Developer enrollment, Team ID, bundle ID, and host-app App Attest capability / entitlement | Enable App Attest on the host app target; ensure publisher registration exposes the App ID / environment data the verifier needs |
| Android  | GCP service account access to `decodeIntegrityToken` API for the publisher's app                         | Play Console project, GCP project for app distribution                                           | Grant the relayer's GCP service account access to the publisher's Play Integrity API, or publisher decodes and forwards verdicts |

On iOS, the attestation adapter is **SDK-config-free** in the narrow sense
that the SDK does not require its own Apple secret credentials or per-SDK
runtime configuration. The remaining requirements are outside the SDK itself:
the host app must enable App Attest on the app target, and the verifier must
be able to resolve the expected plaintext App ID (`TeamID.BundleID`) and build
environment from publisher registration data. No `.p8` key, no Key ID, and no
Apple Developer Portal secret is involved at any point in the attestation or
verification flow.

On supported platforms, the core SDK performs a local capability probe. If the
platform is Android 13+ or iOS 16+ and no attestation provider is registered,
the SDK fails onboarding locally with an explicit integration error rather than
silently entering the legacy lane.

Because the SDK is open source, a malicious publisher can still remove that
check from a fork. The policy response is governance, not protocol trust:
publishers seeking supported attested approval from NODL DAO must ship the
approved attestation-enabled binary associated with their on-chain publisher
record. Publishers that intentionally remove attestation on supported
platforms should not be approved for the supported attested service class.

### 11.3.2 Legacy unsupported service class

Legacy unsupported service exists only for devices below the supported
platform floor. It is a separate low-trust service lane with the following
properties:

- no `DeviceRegistry` registration
- no equivalence to supported attested participation
- lower publish priority and stricter rate limits
- separate queues, workers, and counters
- aggressive shedding under load to protect supported traffic

Legacy unsupported must not be used as a general fallback for supported
platforms that omitted the adapter.

### 11.4 Re-attestation triggers

| Trigger                                     | Action                                       |
| ------------------------------------------- | -------------------------------------------- |
| App update detected (new version hash)      | Force re-attestation at next session refresh |
| App version deprecated on-chain             | Force re-attestation at next session refresh |
| Abuse signals (IP ban, behavioral anomaly)  | Revoke session; require re-attestation       |
| Periodic (configurable, e.g. every 30 days) | Force re-attestation at next session refresh |

### 11.4.1 Attestation availability policy

For simplicity in v2.0, there are only two service classes, and a device that
is already in the supported attested class continues to receive the same level
of service during a bounded refresh grace window if attestation refresh is
temporarily unavailable. This policy is only for already-known supported
devices. It does not permit first-time onboarding without attestation, and it
does not allow a supported platform to fall back into legacy unsupported.

### 11.5 Cost and quota implications

This design assumes that introducing platform attestation does **not** create a
new per-request vendor billing surface for app publishers or backend
verifiers in the standard integration paths.

**Apple App Attest:**

- Apple does not document a per-attestation or per-assertion usage fee for App
  Attest.
- The normal verification flow is performed by the backend using Apple's
  published certificate chain and verification procedure, so the design does
  not depend on a separately billed Apple verification API.
- The paid prerequisite is the publisher's normal Apple developer/distribution
  enrollment, which already exists for shipping the app and is not introduced
  by this design.

**Google Play Integrity:**

- Google does not document a per-request fee for standard Play Integrity token
  generation or server-side token decryption/verification.
- Google does document default daily quotas for token requests and decryption
  calls, with a quota-increase process for higher volume. This is an
  availability and rollout-planning constraint, not a documented usage-billed
  platform fee.
- The required prerequisites are the publisher's normal Play Console / Google
  Cloud setup needed to ship and operate the app on Google Play.

**Design implication:**

- The architecture should be treated as cost-neutral with respect to
  platform-metered attestation billing at the time of writing.
- The real operational concerns are quota management, throttling, staged
  rollout, and ordinary backend compute/storage costs, not a new per-attest or
  per-verify platform charge.
- This document should avoid stronger claims such as "guaranteed free forever";
  platform pricing, quotas, and terms can change over time and should be
  monitored as part of normal platform governance.

**Scope boundary:**

- This cost-neutral statement applies to the standard App Attest and Play
  Integrity flows used by this design.
- Optional or future platform features with separate commercial terms are not
  required for the baseline security model.

Quota management is therefore treated as an operational planning concern, not
as a justification for introducing self-attestation or a supported-platform
legacy fallback. If quotas become tight, the system should preferentially
protect supported attested onboarding and refresh while shedding or limiting
legacy unsupported traffic first.

### 11.6 Coexistence with third-party attestation SDKs

Apps that embed the Nodle SDK may also embed other SDKs that use platform
attestation or device-integrity APIs — for example, ad-fraud prevention SDKs,
attribution SDKs, or anti-cheat libraries. A common concern is whether
multiple SDKs can use App Attest or Play Integrity simultaneously in the
same app without conflict. The short answer is **yes, by design**.

**iOS — no conflict.**

- `DCAppAttestService.shared.generateKey()` creates a new independent
  hardware-backed key pair each time it is called. There is no per-app
  singleton key. The Nodle SDK generates its own key; any other SDK in the
  same app generates its own separate key. The keys do not interfere.
- The Nodle backend verifies attestation and assertion objects **locally**
  using Apple's publicly distributed App Attest Root CA certificate. It does
  not call any Apple server-to-server API, and it does not need the
  publisher's `.p8` private key, Key ID, or Team ID secret.
- Third-party SDKs that claim exclusive use of "App Attest credentials" or
  "DeviceCheck credentials" are typically referring to the `.p8` private key
  used for Apple's separate **server-to-server** APIs: the DeviceCheck
  query/update API (which reads and writes a 2-bit per-device state) and the
  App Attest fraud-receipt API (which reports fraud metrics to Apple). Both
  of those APIs require `.p8` authentication. **This design uses neither
  API** — it relies only on the on-device `DCAppAttestService` framework and
  the public-key verification procedure documented by Apple.
- Consequence: the Nodle iOS attestation adapter and a third-party SDK (e.g.,
  an ad-fraud or attribution SDK) can coexist in the same app with **zero
  secret-credential overlap** and **no SDK-private configuration conflict**.
  The remaining shared concern is ordinary host-app ownership of the App
  Attest capability / entitlement and the selected development or production
  environment, which are app-target settings rather than SDK-private settings.

**Android — no conflict.**

- Play Integrity tokens are app-scoped, not SDK-scoped. Any code running
  inside the app can call `IntegrityManager.requestIntegrityToken()` and
  receive a valid token.
- The `decodeIntegrityToken` API is called server-side. Multiple backends can
  each decode tokens independently using their own GCP service accounts —
  there is no single-consumer restriction.
- For SDK-level distribution specifically, Google offers the
  **Play SDK Console** which gives SDK providers their own integrity signals
  independently of the host app's Play Console project.

**Summary of resource isolation:**

| Attestation resource             | Per-app singleton?           | Used by this design | Used by typical third-party SDK        | Conflict? |
| -------------------------------- | ---------------------------- | ------------------- | -------------------------------------- | --------- |
| iOS App Attest key               | No (unlimited)               | Own key             | Own separate key                       | None      |
| iOS DeviceCheck `.p8` key        | One per developer            | **Not used**        | May use for server-to-server fraud API | None      |
| iOS DeviceCheck 2-bit state      | One per device per developer | **Not used**        | May use                                | None      |
| iOS App Attest fraud receipt API | Requires `.p8`               | **Not used**        | May use                                | None      |
| Android Play Integrity token     | App-scoped                   | Used                | May use                                | None      |
| Android `decodeIntegrityToken`   | Per GCP account              | Used                | Independent server-side decoding       | None      |

**Why the "only one per app" misconception arises:**

Apple's DeviceCheck documentation describes per-developer, per-device state
(2 bits) and the `.p8` key used to access it. Some third-party SDKs that
rely on DeviceCheck ask publishers not to share the `.p8` key or use the
same DeviceCheck credentials for other purposes. Because App Attest and
DeviceCheck are grouped in the same Apple framework documentation, it is easy
to conflate them and conclude that App Attest is similarly exclusive. It is
not. App Attest key generation is a per-call operation, and verification uses
a public root CA — both are inherently multi-tenant.

### 11.7 Attestation credential and API boundary summary

This table consolidates every relevant Apple and Google API or credential,
stating which ones this design uses and which it deliberately avoids. It is
intended as a quick reference for integration engineers evaluating
compatibility with other SDKs or publisher requirements.

| Platform API / Credential                         | Used by this design? | Purpose                                                                 | Why included or excluded                                                                             |
| ------------------------------------------------- | -------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| iOS `DCAppAttestService` (on-device framework)    | **Yes**              | Generate attestation keys, produce attestation and assertion objects    | Core iOS attestation mechanism; supports unlimited independent keys per app                          |
| iOS App Attest entitlement / environment          | **Yes**              | Host-app capability and development-vs-production environment selection | Required by Apple at the app target; host-app owned configuration, not an SDK-private setting        |
| iOS App Attest Root CA (public certificate)       | **Yes**              | Backend verifies attestation/assertion objects                          | Publicly available; no publisher-specific credential needed                                          |
| iOS DeviceCheck server-to-server API              | **No**               | Query/update 2-bit per-device state                                     | Requires `.p8` key; not needed for attestation verification; may conflict with third-party SDK usage |
| iOS App Attest fraud receipt API                  | **No**               | Report fraud metrics to Apple                                           | Requires `.p8` key; not needed for core attestation; informational only                              |
| iOS `.p8` private key / Key ID / Team ID secret   | **No**               | Authenticate server-to-server Apple API calls                           | Not required — all iOS verification in this design is local against the public root CA               |
| iOS plaintext App ID (`TeamID.BundleID`) metadata | **Yes**              | Server input for App Attest validation                                  | Required by Apple's validation procedure; kept off-chain and cross-checked against on-chain hashes   |
| Android `IntegrityManager` (on-device API)        | **Yes**              | Request Play Integrity token from Google Play Services                  | Core Android attestation mechanism                                                                   |
| Android `decodeIntegrityToken` (server-to-server) | **Yes**              | Decrypt and verify integrity token on backend                           | Requires GCP service account (standard Play Console setup the publisher already has)                 |
| Android Play SDK Console                          | **Optional**         | SDK-level integrity signals for SDK providers                           | Available for Nodle as an SDK provider; not required for app-level integration                       |

---

## 12. CBOR vs JSON for Request Encoding

### 12.1 Should CBOR be kept?

The current system uses CBOR as the outer encoding for the DTN7 bundle. With
DTN removed, the main question for the new ingest path is whether BLE
announcements should be sent as CBOR or JSON.

| Criterion        | CBOR                                                               | JSON                                           |
| ---------------- | ------------------------------------------------------------------ | ---------------------------------------------- |
| Size             | 20-40% smaller for binary-heavy payloads (BLE advertisement bytes) | Larger due to base64 encoding of binary fields |
| Parse speed      | Faster (binary format, no string parsing)                          | Slower                                         |
| Schema evolution | Tag-based, similar to protobuf                                     | Flexible but no built-in schema                |
| Debuggability    | Requires tooling to inspect                                        | Human-readable                                 |
| Library support  | Good on mobile (iOS/Android have mature CBOR libs)                 | Universal                                      |
| Body hashing     | Deterministic binary = stable hash                                 | JSON key ordering must be canonicalized        |

### 12.2 Recommendation

**Use CBOR only for BLE announcement ingest** (`/v2/scan/ble`). This path
carries binary BLE advertisement payloads and may batch multiple
announcements from multiple tags in one request. CBOR keeps these uploads
compact and preserves a stable byte representation for hashing.

**Do not use protobuf on the client-to-backend BLE path.** In this repository,
protobuf is part of the current DTN-based transport and legacy shared data
contracts. That reason disappears in the new direct HTTP ingest design, so
protobuf adds framing and schema-maintenance overhead without a corresponding
benefit at this boundary.

**Use JSON for control endpoints** (`/v2/onboard`, `/v2/session/refresh`,
`/v2/config`). These are low-frequency and benefit from human readability
during debugging.

The `Content-Type` header determines encoding:

- `application/cbor` → CBOR
- `application/json` → JSON

For BLE ingest, `Content-Type: application/cbor` is required. The auth
middleware remains encoding-agnostic at the hashing layer and hashes the raw
body bytes regardless of encoding.

---

## 13. Key Lifecycle and Rotation

### 13.1 Key types

| Key                 | Type                           | Where stored   | Rotation                                          | Purpose                          |
| ------------------- | ------------------------------ | -------------- | ------------------------------------------------- | -------------------------------- |
| Device key          | secp256k1 (or P-256, see 13.2) | Secure Enclave | Never rotated; new key = new device identity      | Signs EIP-712 per-request proofs |
| Backend signing key | EdDSA (Ed25519)                | Cloud KMS      | Quarterly; old keys valid until all tokens expire | Signs session tokens             |
| Relayer key         | Ethereum account               | Cloud KMS      | As needed; contract role transferable             | Submits txs to ZkSync            |

### 13.2 Android enclave key type

Android StrongBox Keymaster on most devices supports ECDSA P-256 but not
secp256k1 natively.

**Options:**

| Option                              | Security                    | Ethereum compatibility          |
| ----------------------------------- | --------------------------- | ------------------------------- |
| P-256 in StrongBox                  | Hardware-backed (strongest) | Non-standard address derivation |
| secp256k1 in Android Keystore (TEE) | TEE-backed (strong)         | Standard Ethereum address       |
| secp256k1 in software               | Software-only (weakest)     | Standard Ethereum address       |

**Recommendation:** Use secp256k1 in Android Keystore (TEE). This provides
strong hardware backing (TEE isolation) while maintaining standard Ethereum
address derivation. StrongBox (the dedicated security chip) is preferred when
available for P-256, but most modern Android devices provide adequate TEE
protection for secp256k1 via the Keystore API.

On iOS, the Secure Enclave natively supports P-256. Use P-256 on iOS and
derive the on-chain address via `keccak256(pubkey)` (non-standard but
deterministic and functional).

### 13.3 Backend signing key rotation

Standard JWT key rotation with `kid` headers:

1. Generate new key pair in Cloud KMS.
2. Start signing new session tokens with the new `kid`.
3. Keep the old public key available for verification until
   `max(existing_token.exp)` has passed.
4. Remove the old key after the grace period.

### 13.4 What replaces key-provision

| Current key-provision function   | New system equivalent                                        |
| -------------------------------- | ------------------------------------------------------------ |
| Store SDK signing secrets        | Unnecessary; each device has its own key                     |
| Serve key versions to dtn-outbox | Unnecessary; EIP-712 carries the public key in the signature |
| Key version enable/disable       | App version deprecation on DeviceRegistry                    |
| RBAC for key management          | Access control on DeviceRegistry contract                    |

`key-provision` is no longer needed for SDK client authentication. It may
remain useful for internal service-to-service auth.

---

## 14. Migration Path from Current System

### Phase 0: Preparation

- Deploy DeviceRegistry contract to ZkSync testnet.
- Implement backend onboarding service (`/v2/onboard`).
- Implement EIP-712 validation middleware (behind feature flag).
- Implement legacy unsupported ingress and isolated low-priority processing.
- Implement the streaming sink interface and the default open-source Pub/Sub
  sink module.
- Implement new scan endpoints (`/v2/scan/ble`, `/v2/scan/cell`,
  `/v2/heartbeat`).
- Configure the same Pub/Sub sink module to publish supported and legacy events
  to separate topics or subscriptions as needed by policy.
- Ship SDK update with secure enclave key generation, core/adapter split, and
  runtime adapter requirement checks on supported platforms.

### Phase 1: Dual-mode (weeks 1-4)

Both old and new auth flows are accepted. Old endpoints and new endpoints
coexist.

```
Auth middleware pseudocode:

if path starts with /v2/:
    validate new flow (session token + EIP-712 signature)
else if path starts with /v2/legacy/:
  validate legacy unsupported flow
else if path is /outbox or /:
    validate old flow (HMAC JWT + DTN bundle)
else:
    reject 401
```

- New SDK versions use `/v2/` endpoints with new auth.
- Unsupported legacy devices use the dedicated legacy lane.
- Old SDK versions continue using `/outbox` with HMAC auth.
- Track adoption via metrics: old-flow requests vs new-flow requests.

### Phase 2: Deprecation (weeks 4-8)

- Call `deprecateAppVersion(oldVersionHash)` on-chain for old SDK versions.
- Old SDK versions cannot re-attest and lose sessions on expiry.
- Push update notifications to users on old versions.

### Phase 3: Removal (week 8+)

- Remove HMAC validation path from auth middleware.
- Remove DTN bundle parsing from ingest service.
- Remove key-provision polling from backend.
- Decommission key-provision service for SDK auth.
- Remove old `/outbox` endpoints.
- Keep legacy unsupported isolated as a separate operational lane if still
  needed for product reasons, either logically in the same service or as a
  later separate deployable if operations require it.

---

## 15. Security Analysis

### 15.1 Threat model comparison

| Threat                        | Current system                                        | New system                                                                                                                         |
| ----------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Extracted app secret**      | Compromises all devices using that key version        | Impossible; private key in secure enclave is non-extractable                                                                       |
| **Intercepted bearer token**  | Can replay until body hash is seen in Redis           | Useless without the device's private key for EIP-712 signing                                                                       |
| **Replay attack**             | Redis SETNX on body hash (lost on restart)            | Monotonic nonce per device (persistent, survives restart)                                                                          |
| **Rooted/jailbroken device**  | Not detected (self-declared device_status)            | Rejected at onboarding by platform attestation                                                                                     |
| **Compromised single device** | Cannot isolate (shared symmetric key)                 | Revoke single address on-chain                                                                                                     |
| **Backend compromise**        | Attacker gets all HMAC secrets                        | Attacker gets backend signing key (can mint sessions) but cannot forge device signatures; shared revocation state remains portable |
| **Open-source SDK**           | Reveals key obfuscation strategy                      | No impact; security depends on signing cert + hardware + publisher registration                                                    |
| **Man-in-the-middle**         | Body hash provides integrity; TLS for confidentiality | Same, plus EIP-712 binds to method/path/session                                                                                    |
| **Replay across endpoints**   | Not prevented (same HMAC key for all paths)           | Prevented: EIP-712 includes method and path                                                                                        |
| **Clock skew abuse**          | Custom max_drift check                                | Standard timestamp check; similar but with standard claims                                                                         |
| **Rogue publisher**           | N/A (single publisher)                                | Publisher suspended on-chain; all devices under that publisher denied on next session refresh                                      |
| **Unregistered app clone**    | Same HMAC key works in any binary                     | Rejected: packageName/bundleId or certHash won't match any registered publisher                                                    |
| **Unsupported legacy abuse**  | Same shared flow as normal traffic                    | Isolated legacy lane with separate quotas, queues, and aggressive early rejection                                                  |

### 15.2 What this design does not solve

| Gap                              | Why                                                          | Mitigation                                                                                                            |
| -------------------------------- | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| Sophisticated attestation bypass | Play Integrity can be spoofed using leaked keybox files      | Tiered trust, behavioral analysis, CRL monitoring, Android 16+ RKP                                                    |
| Public device registry           | Device addresses and state transitions are visible on ZkSync | Registry is minimized to pseudonymous addresses, hashes, and revocation state; avoid non-essential fields like counts |
| Backend as single relayer        | If backend is down, no new registrations                     | Contract supports multiple relayers via RELAYER_ROLE                                                                  |
| Real-time revocation             | Session tokens valid until exp                               | Short lifetimes (1-6h) bound the window                                                                               |
| Secure Enclave compromise        | Physical attacker with device access                         | Out of scope; same as all mobile security models                                                                      |
| Rogue registered publisher       | A trusted publisher could ship a malicious SDK fork          | Publisher suspension on-chain; behavioral monitoring of per-publisher data                                            |
| Legacy lane abuse                | Cheap identities can be created in software-only clients     | Separate ingress, coarse network limits, queue isolation, and lower priority processing                               |
| Publisher key compromise         | Attacker signs a malicious binary with the publisher's cert  | Publisher cert rotation on-chain; revocation and re-registration                                                      |

### 15.3 Industry comparison

| System                        | Auth model                       | Device identity           | Attestation                 | On-chain              |
| ----------------------------- | -------------------------------- | ------------------------- | --------------------------- | --------------------- |
| **This design**               | Session JWT + EIP-712 proof      | Per-device enclave key    | Play Integrity / App Attest | ZkSync smart contract |
| Apple Push Notification       | TLS client cert + device token   | Per-device; Apple-managed | Built into iOS              | No                    |
| Helium IoT                    | Burn HNT for device registration | Per-device ECC key        | No                          | Solana                |
| DIMO                          | Device minting via NFT           | Per-device secp256k1      | Partial                     | Polygon               |
| Google SafetyNet (deprecated) | Attestation-only                 | No persistent identity    | Yes                         | No                    |
| Current Nodle system          | Shared HMAC JWT                  | None (shared key family)  | Self-declared               | No                    |

---

## 16. Known Attack Vectors and Mitigations

This section catalogs concrete attack vectors against the authentication
system, assesses their real-world viability, and specifies the mitigation
approach taken or recommended. Many of these were identified during internal
review of the platform attestation strategy.

### 16.1 Play Integrity bypass via leaked hardware keybox (Android)

**Attack:** An attacker uses tools like PlayIntegrityFix, TrickyStore, or
similar Magisk/KernelSU modules on a rooted device to present a forged
`MEETS_STRONG_INTEGRITY` verdict. These tools rely on leaked hardware
attestation keybox files from OEM manufacturing processes to construct
valid-looking hardware key attestation certificate chains.

**Real-world viability:** Moderate within the supported Android 13+ baseline.
The easiest property-spoofing attacks target pre-Android-13 devices, which are
outside the supported attested baseline and, in this design, belong only to
the legacy unsupported service class. For Android 13+ devices, bypassing server-
verified Play Integrity generally requires leaked keybox files and multiple
coordinated Magisk or KernelSU modules. The PlayIntegrityFork repository
itself notes that its primary target is the pre-Android-13 verdict, not the
A13+ verdict which "relies on locked bootloader checks."

**Mitigation (implemented):**

| Layer                  | Mitigation                                                                                                                | Effect                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Attestation tier       | Require Android 13+ and at least `MEETS_DEVICE_INTEGRITY`; prefer `MEETS_STRONG_INTEGRITY` where available                | Forces attackers to source leaked keyboxes rather than just spoof properties          |
| Minimum SDK version    | Require `deviceAttributes.sdkVersion` ≥ 33 (Android 13) for the supported baseline                                        | Excludes devices vulnerable to the easiest property-spoofing bypasses                 |
| Certificate revocation | Backend periodically polls Google's hardware attestation CRL at `https://android.googleapis.com/attestation/status`       | Leaked keyboxes are revoked by Google; devices using them fail on next re-attestation |
| Recent device activity | Opt in to `recentDeviceActivity` in Play Integrity verdicts                                                               | Detects farming devices making excessive attestation requests                         |
| Device Recall          | Optional future enhancement only; not required for the baseline cost-neutral design                                       | Tags survive factory resets; cross-session device reputation                          |
| Session lifetime       | Devices with `MEETS_DEVICE_INTEGRITY` but without STRONG may receive shorter session lifetimes within the supported class | Bounds the damage window if a device's integrity verdict was forged                   |
| RKP roadmap            | Android 16+ mandates Remote Key Provisioning — attestation keys are remotely provisioned by Google, not burned at factory | Eliminates the keybox leak attack vector entirely for new devices                     |

### 16.2 App binary tampering / static attack

**Attack:** An attacker decompiles the APK or IPA, removes attestation API
calls, patches the binary to skip integrity checks, dumps authentication
tokens from a real device, and replays them from the tampered binary.

**Real-world viability:** High for the decompilation step; low for the
replay step given this design.

**Why this design is resistant:**

1. **Attestation is server-verified, not client-verified.** Removing the
   attestation API call from the client doesn't help — the backend requires a
   valid attestation token to onboard. The token is produced by Google/Apple
   servers, not by client code.
2. **Token dumping is bounded.** Attestation tokens are challenge-bound
   (single-use) and expire within 60 seconds. Session tokens expire in 1-6h.
   Both are useless without the device's hardware-backed private key for
   EIP-712 signing.
3. **Modified binaries fail publisher verification.** A re-signed APK has a
   different `certificateSha256Digest`. This won't match any registered
   publisher's `certHash` in the PublisherRegistry.
4. **`PLAY_RECOGNIZED` fails for sideloaded binaries.** Google verifies the
   app was distributed through the Play Store, signed with the publisher's
   registered key.

**Mitigation (implemented):**

- Server-side-only attestation verification (never trust client-side results)
- Challenge-response freshness binding
- Publisher certificate hash verification against on-chain record
- EIP-712 proof-of-possession on every request (session token alone is useless)

### 16.3 Rooted device spoofing all attestation responses

**Attack:** On a rooted device, intercept all calls from the Play Integrity
SDK to Google Play Services and return spoofed "genuine" responses.

**Real-world viability:** This misunderstands the Play Integrity architecture
for server-verified tokens. The flow is:

1. App calls Play Integrity SDK → SDK communicates with Google Play Services
2. Google Play Services communicates with **Google's servers**
3. **Google's servers** produce a cryptographically signed token using Google's
   private key
4. Your backend verifies the token by calling Google's `decodeIntegrityToken`
   API (server-to-server)

Intercepting the client-side SDK call and returning a fake token does not work
because the backend calls Google's server to decode and verify the token. A
forged token would fail Google's cryptographic verification.

The actual bypass vector is not interception but **tricking Google's servers**
into issuing a passing verdict (see 16.1 — leaked keybox approach).

**Mitigation:** Same as 16.1. Additionally, never implement client-side token
parsing or verification.

### 16.4 Open-source code gives attackers a roadmap

**Attack:** With source code public, attackers know exactly which endpoints to
target, what checks exist, and where to focus their efforts.

**Real-world viability:** Valid concern for obfuscation-based security.
Irrelevant for cryptographic security.

**Why this design is resistant:**

- Knowing that EIP-712 is used doesn't help forge signatures (mathematical
  guarantee)
- Knowing attestation is checked server-side doesn't help produce valid
  attestation tokens (Google/Apple server guarantee)
- Knowing the PublisherRegistry contract address doesn't help register a fake
  publisher (requires `PUBLISHER_ADMIN_ROLE`)
- Knowing the session token format doesn't help mint tokens (requires backend
  signing key in Cloud KMS)

This is the "open padlock" principle: the security of a lock should depend on
the key, not on the lock's design being secret. All major security standards
(TLS, Signal Protocol, Ethereum) are open and auditable.

**Mitigation (implemented):** Security model relies exclusively on:

- **Possession** of hardware-backed keys (non-extractable)
- **Platform attestation** from Apple/Google (server-verified)
- **On-chain publisher trust** (admin-controlled)
- **Cryptographic signatures** (mathematically unforgeable)

### 16.5 Cross-publisher device sharing and replay

**Attack:** A device registered under Publisher A attempts to send data as if
it belongs to Publisher B, or replays requests between publishers.

**Real-world viability:** Low. Each device is registered with a specific
`publisher` address on-chain. The session token embeds the `publisher` claim.

**Mitigation (implemented):**

- Device-to-publisher binding is recorded on-chain at registration time
- Session token includes `publisher` claim, verified at each request
- EIP-712 domain separator includes the contract address, preventing
  cross-contract replay
- A device can only re-register under a different publisher by going through
  full onboarding again (new attestation + publisher verification)

### 16.6 Rogue registered publisher

**Attack:** A publisher who passes registration ships a malicious fork of the
SDK that fabricates BLE scan data, inflates contribution metrics, or otherwise
abuses the network.

**Real-world viability:** Moderate. This is the "insider threat" for a
multi-publisher model.

**Mitigation (implemented + recommended):**

| Layer                              | Mitigation                                                                                                                                    | Status                           |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| Publisher suspension               | `PUBLISHER_ADMIN_ROLE` can call `suspendPublisher()` to instantly block all devices under that publisher from refreshing sessions             | Implemented in contract design   |
| Per-publisher rate limiting        | Backend tracks request rates per `publisher` address; anomalous volume triggers investigation                                                 | Recommended: backend operational |
| Per-publisher data quality scoring | Downstream analytics score data quality per publisher; low-quality publishers flagged                                                         | Recommended: analytics layer     |
| Publisher staking (future)         | Require publishers to stake tokens; slashable for bad behavior                                                                                | Open question (Section 17)       |
| Publisher audit trail              | All publisher registration/suspension events are on-chain and publicly auditable; this is useful but not the primary architectural goal       | Implemented in contract design   |
| Approved binary governance         | Publishers that remove required attestation logic from supported builds are not approved by NODL DAO for the supported attested service class | Recommended governance policy    |

### 16.7 TLS interception / man-in-the-middle

**Attack:** Break TLS certificate pinning on a rooted device (e.g., with
Frida) to observe and modify traffic between the SDK and the backend.

**Real-world viability:** High on rooted devices.

**Why this design is resistant:** TLS provides confidentiality but is **not
a security boundary** for authentication. Even if TLS is broken:

- Attacker **cannot forge** EIP-712 signatures (requires the device's
  hardware-backed private key)
- Attacker **cannot replay** requests (monotonic nonce)
- Attacker **cannot mint** session tokens (requires backend signing key)
- Attacker **can observe** request contents (mitigated by TLS where
  available; acceptable risk for BLE scan data which is not sensitive)

**Mitigation (implemented):** Authentication security is independent of
transport security. EIP-712 provides integrity and proof-of-possession at the
application layer.

### 16.8 Continuous maintenance burden

**Concern:** Any security model requires ongoing maintenance. Obfuscation
(GuardSquare/RASP) requires frequent updates as attackers adapt. Does this
design have the same burden?

**Assessment:** The maintenance profiles are fundamentally different:

| Aspect                      | Obfuscation (GuardSquare/RASP)                         | This design (attestation + crypto)                       |
| --------------------------- | ------------------------------------------------------ | -------------------------------------------------------- |
| What changes                | Obfuscation patterns, root detection heuristics        | Attacker tooling evolves; leaked keyboxes found          |
| Who maintains the hard part | Your team (weekly-monthly obfuscation rotations)       | Google/Apple (CRL updates, RKP, OS security patches)     |
| Update frequency            | Days to weeks                                          | Automated CRL polling; periodic min SDK version bumps    |
| Open-source impact          | Obfuscation defeated immediately                       | No impact (security based on crypto, not secrecy)        |
| Cost                        | ~$20K/year license + engineering time per update cycle | Smart contract deployment (one-time) + backend infra     |
| Cat-and-mouse game          | Continuous, with your team as the mouse                | Google/Apple play the mouse (with vastly more resources) |

The key insight: this design **delegates the cat-and-mouse game** to
Google and Apple (who maintain the attestation infrastructure) and to
the mathematical guarantees of cryptography (which don't degrade over time).
The residual maintenance is operational: monitoring CRLs,
bumping minimum SDK versions, and managing publisher registrations.

### 16.9 Why self-attestation is not used

This design intentionally does not define a self-attestation path. A
self-issued claim adds too little trustworthy signal to justify on-chain
registration or equivalence with supported attested devices. Unsupported
platforms, quota pressure, or missing adapter integration are handled through
service-class policy and admission control rather than by introducing a weak
cryptographic-looking fallback that is still controlled entirely by the
client.

### 16.10 Backend isolation for legacy unsupported traffic

The backend should assume that legacy unsupported identities are cheap to
create and easy to discard. To keep them from harming supported attested
traffic, low-trust admission should happen before expensive work.

Representative Google Cloud architecture:

- External HTTPS Load Balancer + Cloud Armor for coarse IP, ASN, geo, and
  volumetric filtering
- thin Cloud Run edge admission service, API Gateway, or Apigee policy layer
  for request-size caps, header checks, and fast rejection
- Memorystore for Redis for low-cost counters such as `legacy:ip:*`,
  `legacy:publisher:*`, and short-lived admission tokens
- either a logical legacy lane inside the main V2 gateway or a separate Cloud
  Run legacy ingest service with its own max instances and concurrency
  settings if stronger isolation is needed
- separate Pub/Sub topic or low-priority subscription for legacy traffic,
  typically produced by the same sink module used for the supported lane

The ordering principle is:

1. coarse network and size checks first
2. cheap Redis-backed admission decisions second
3. only then parse, queue, or publish legacy traffic

This keeps unsupported legacy traffic from consuming the same worker pool,
queue depth, or downstream publish budget as supported attested devices.

### 16.11 Economic deterrents as a complementary layer

**Observation:** Cryptographic and attestation-based security can be
complemented by economic mechanisms (staking, reputation scoring) to further
raise the cost of abuse.

**Compatibility with this design:**

The on-chain PublisherRegistry and DeviceRegistry are natural extension points
for economic mechanisms. These are future advantages of the architecture, not
required for the initial security model:

- **Publisher staking:** Require publishers to deposit tokens when registering.
  Slashable if their devices produce low-quality data.
- **Device reputation scoring:** Backend assigns scores based on data quality,
  uptime consistency, and behavioral signals. Scores can be committed on-chain
  for transparency.
- **Reward tiering:** Devices in the supported attested class earn full
  rewards. Legacy unsupported devices earn proportionally less, making it
  economically unattractive to run large numbers of low-trust devices.

These mechanisms are additive and can be introduced without changes to the core
authentication protocol.

---

## 17. Trade-offs and Open Questions

### 17.1 Decided trade-offs

| Decision                                      | Trade-off accepted                                             | Rationale                                                                                                     |
| --------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Off-chain attestation verification            | Backend is trusted to verify honestly                          | On-chain verification too expensive; the chain stores only a minimal commitment and shared revocation state   |
| Session token (not per-request chain read)    | Trust window of up to 6 hours                                  | Per-request chain reads limit throughput and add latency; refresh-time chain checks give canonical revocation |
| EIP-712 over DPoP                             | Less alignment with IETF OAuth standards                       | Better Web3 fit; on-chain verifiable; team familiarity; simpler                                               |
| CBOR for scan data, JSON for control          | Two content types to support                                   | Each encoding used where it suits best                                                                        |
| Monotonic nonce over body-hash replay         | Cannot detect duplicate identical bodies with different nonces | Simpler; more efficient; survives Redis restart; supports offline queuing                                     |
| TEE-backed secp256k1 on Android               | Not StrongBox-backed (dedicated secure chip)                   | Standard Ethereum compatibility; TEE is adequate                                                              |
| Two service classes only                      | Less granularity than multi-tier trust ladder                  | Simpler policy: supported attested vs legacy unsupported                                                      |
| Adapter required on supported platforms       | More publisher integration work                                | Preserves a clean full-trust model and avoids supported-platform downgrade into legacy                        |
| Single deployable with modular internals      | Less deployment isolation than early microservices             | Avoids inter-service latency, retries, and operational complexity in the hot path                             |
| Pluggable sink interface with Pub/Sub default | Provider adapters must map the same canonical event contract   | Keeps the gateway reusable while allowing the default deployment to optimize directly for Pub/Sub throughput  |
| Separate legacy lane                          | More backend components and routing rules                      | Prevents low-trust traffic from competing with supported attested traffic for scarce capacity                 |

### 17.2 Open questions

1. **Batch registration cadence.** How frequently should queued registrations
   be flushed to ZkSync? Every 10 seconds? Every 100 devices? Should be
   configurable; measure cost vs. latency in staging.

2. **Session refresh grace window.** When a session token expires, how long
   should the device have to refresh before being forced to fully re-attest?
   Suggestion: `exp + 5 minutes` grace for refresh; beyond that, full
   re-attestation.

3. **Decentralized relayer set.** The contract supports multiple relayers via
   RELAYER_ROLE. When should additional relayers and refresh services be
   added? Start with backend only; expand when there is operational need or
   community demand.

4. **ZK-based registration privacy.** If revealing device registration timing
   is a concern, a future version could use ZK proofs or other privacy layers
   for registration. This adds significant complexity and should only be
   pursued if the threat model demands it.

5. **Offline device queuing.** If a device is offline and queues multiple scan
   payloads, it can pre-sign them with sequential nonces. The backend must
   accept them in order. Define maximum queue depth (e.g., 1000 requests) to
   bound nonce advancement.

6. **Legacy publisher opt-out policy.** Should supported-platform publishers
   ever be allowed to ship a legacy-only build, or should the supported lane
   require the adapter unconditionally? The simpler security posture is to
   require the adapter for all approved supported builds.

7. **Publisher self-registration vs. admin-only registration.** The current
   design uses `PUBLISHER_ADMIN_ROLE` for registration. A future version could
   allow publishers to self-register by staking tokens, with the admin role
   shifting to governing the staking parameters and slashing conditions.
   Evaluate whether the network is mature enough for permissionless publisher
   registration.

8. **Publisher certificate rotation.** When a publisher rotates their app
   signing certificate (e.g., Google Play App Signing key rotation), they
   must update their on-chain `certHash`. Define a grace period during which
   both old and new certificate hashes are accepted to avoid disrupting
   existing users mid-rotation.

9. **Publisher staking and slashing.** Should publishers be required to
   deposit a bond when registering? If so, define the bond amount, the
   slashing conditions (e.g., sustained low data quality, confirmed abuse),
   and the governance process for slashing decisions.

10. **Cross-publisher device migration.** If a user switches from Publisher
    A's app to Publisher B's app on the same device, should the device's
    on-chain history carry over, or should it re-onboard as a fresh identity?
    Re-onboarding is simpler and more secure; carrying history requires
    either the device to prove its previous identity to the new publisher or
    a cross-publisher protocol.

11. **Legacy service budget.** What fixed worker, queue, and publish budget
    should be reserved for the legacy unsupported lane so it remains useful
    without threatening supported traffic under abuse or load?

---

_End of design document._

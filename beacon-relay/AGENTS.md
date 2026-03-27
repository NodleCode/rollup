# Beacon Relay — Rust Development Standards

This file is the authoritative reference for AI agents working on the
`beacon-relay` Rust project. Read it before every task. Trust these
instructions and only search if information here is incomplete or wrong.

## Project Overview

**beacon-relay** is the v2 gateway for the Nodle DePIN network. It is the
first point of processing for BLE scan data, device heartbeats, and telemetry
collected by participating mobile devices. The service authenticates devices
via EIP-712 signatures, validates sessions backed by on-chain state (ZkSync
Era), and relays accepted data to downstream streaming sinks (default: Google
Pub/Sub).

- **Design document**: `auth-design.md` in the monorepo root.
- **Crate name**: `beacon-relay`
- **Location**: `beacon-relay/` in the monorepo root.
- **Language**: Rust (edition 2021)
- **Async runtime**: Tokio
- **Web framework**: Axum

---

## Build, Test, Run Commands

```bash
# All commands from the beacon-relay/ directory
cd beacon-relay

# Build (debug)
cargo build

# Build (release)
cargo build --release

# Run the server (default: 127.0.0.1:3000)
cargo run

# Run with custom config via env vars
APP_HOST=0.0.0.0 APP_PORT=8080 cargo run

# Run all tests
cargo test

# Run a specific test
cargo test test_name

# Lint (treat warnings as errors)
cargo clippy -- -D warnings

# Format check
cargo fmt --check

# Format (apply)
cargo fmt
```

Always run `cargo clippy -- -D warnings` and `cargo fmt --check` before
considering a task complete.

---

## Project Structure

```
beacon-relay/
├── Cargo.toml              # Manifest — pin major versions, use ~ for minor
├── Cargo.lock              # Committed to version control (binary crate)
├── AGENTS.md               # This file
├── .gitignore              # Rust-specific ignores
├── config/
│   └── default.toml        # Default configuration values
├── src/
│   ├── main.rs             # Entry point: config → tracing → router → serve
│   ├── config.rs           # Figment-based config loading
│   ├── error.rs            # AppError enum (thiserror), IntoResponse impl
│   ├── telemetry.rs        # Tracing subscriber initialization
│   └── routes/
│       ├── mod.rs          # Router builder: create_router()
│       └── health.rs       # GET /healthz
└── tests/
    └── health_test.rs      # Integration test for health endpoint
```

As the project grows, new modules should follow this pattern:
- `src/routes/<domain>.rs` for HTTP handlers
- `src/middleware/` for Tower middleware layers
- `src/models/` for shared data types
- `src/services/` for business logic (not HTTP-coupled)
- `src/db/` for database/Redis interaction

---

## Approved Dependencies (Stable, Mature Crates)

Only add dependencies from this list unless there is a clear, documented
reason. Prefer crates with >10M downloads, active maintenance, and no
known security advisories.

### Core Stack

| Purpose | Crate | Version | Notes |
|---|---|---|---|
| Web framework | `axum` | ~0.8 | Tokio-team, macro-free, Tower ecosystem |
| Async runtime | `tokio` | 1 (features: full) | De facto standard |
| Serialization | `serde` | 1 (features: derive) | Universal |
| JSON | `serde_json` | 1 | Standard JSON |
| Structured logging | `tracing` | 0.1 | Async-aware, structured |
| Log subscriber | `tracing-subscriber` | 0.3 (features: env-filter, json) | Configurable output |
| Config loading | `figment` | 0.10 (features: toml, env) | Hierarchical, type-safe |
| Error types | `thiserror` | 2 | Derive Error for enums |
| HTTP middleware | `tower-http` | 0.6 (features: trace, cors) | Tower layers for axum |
| HTTP types | `tower` | 0.5 | Service trait, layers |

### Future Iterations (Do Not Add Until Needed)

| Purpose | Crate | Notes |
|---|---|---|
| CBOR encoding | `ciborium` | BLE batch body parsing |
| Redis client | `fred` or `redis` | Session/nonce store |
| JWT | `jsonwebtoken` | Session token issuance/validation |
| Ethereum/EIP-712 | `alloy` | Signature verification, chain interaction |
| HTTP client | `reqwest` | Play Integrity API calls |
| UUID | `uuid` | Session IDs |
| Time | `chrono` or `time` | Prefer `time` (lighter, no C deps) |
| Pub/Sub | `google-cloud-pubsub` | Streaming sink |
| OpenTelemetry | `tracing-opentelemetry` | Distributed tracing export |

### Dependency Selection Criteria

When evaluating a new dependency:
1. **Downloads**: >10M total on crates.io preferred; >1M acceptable if niche.
2. **Maintenance**: Last release within 6 months; active issue triage.
3. **Security**: No open advisories in `cargo audit`.
4. **Compatibility**: Must work with current Tokio and Axum versions.
5. **Size**: Prefer crates with minimal transitive dependencies.
6. **Alternatives**: Check if the functionality exists in `std` or an already-included crate first.

---

## Coding Standards

### Error Handling

- Use `thiserror` for all error enums. Every variant must have a `#[error("...")]` message.
- Implement `IntoResponse` for error types that reach HTTP handlers.
- Map errors to appropriate HTTP status codes — do not leak internal details to clients.
- Use `?` propagation freely; avoid manual `match` on `Result` unless you need to transform the error.
- Reserve `unwrap()` and `expect()` for cases where the invariant is provably upheld (e.g., compile-time constants, test code). Add a comment explaining why.
- Never use `unwrap()` on user input, network responses, or file I/O.

### Logging and Tracing

- Use `tracing` macros (`info!`, `warn!`, `error!`, `debug!`, `trace!`), never `println!` or `eprintln!` in library/production code.
- Add structured fields: `tracing::info!(endpoint = %path, status = %code, "request handled")`.
- Use `#[tracing::instrument]` on async functions that benefit from span context. Skip large arguments with `skip(body)`.

### Naming Conventions

- **Files**: `snake_case.rs`
- **Types**: `PascalCase` — `AppError`, `HealthResponse`
- **Functions**: `snake_case` — `create_router`, `init_tracing`
- **Constants**: `SCREAMING_SNAKE_CASE`
- **Test functions**: `test_<description>` (e.g., `test_healthz_returns_200`)

### Code Organization

- Keep handler functions short. Extract business logic into separate functions or service modules.
- One public type or function per conceptual responsibility.
- Group related `use` statements: std → external crates → crate modules.
- Prefer returning `impl IntoResponse` from handlers over concrete types.

### Testing

- **Integration tests** go in `tests/` directory — they test the HTTP interface via Tower `ServiceExt`.
- **Unit tests** go in `#[cfg(test)] mod tests` blocks within source files.
- Test names: `test_<what>` (e.g., `test_healthz_returns_200`).
- Use `#[tokio::test]` for async tests.
- Assert both status codes and response bodies.
- Do not use `unwrap()` in tests without a comment — prefer `expect("reason")`.

### Security

- Never log secrets, tokens, private keys, or raw attestation blobs at INFO level or above.
- Validate and bound all external input at system boundaries.
- Use constant-time comparison for secrets and signatures.
- Set appropriate CORS and security headers via Tower middleware.
- Follow OWASP Top 10 guidance.

### Performance

- Handlers should be non-blocking. Use `tokio::task::spawn_blocking` for CPU-heavy work.
- Prefer streaming/zero-copy patterns for large request bodies (BLE batches).
- Use `Arc<T>` for shared application state passed via Axum's `State` extractor.

---

## Configuration

Configuration is loaded via Figment in this order (later overrides earlier):

1. `config/default.toml` — defaults committed to VCS
2. `config/{APP_ENV}.toml` — environment-specific (e.g., `production.toml`), optional
3. Environment variables prefixed with `APP_` — highest priority

Nested config uses `__` separator in env vars: `APP_SERVER__PORT=8080`.

All config fields must have sensible defaults in `default.toml` so the server
starts with zero configuration.

---

## Design Document Reference

The full v2 gateway design is in `auth-design.md` at the monorepo root. Key
sections for backend implementation:

- §4 Architecture Overview — module boundaries and endpoint map
- §5 Protocol 1: Device Onboarding — `/v2/onboard` flow
- §6 Protocol 2: Per-Request Authentication — `/v2/scan/ble` validation
- §8 EIP-712 Typed Data Signing — signature verification details  
- §9 Smart Contract Design — `PublisherRegistry` and `DeviceRegistry` interfaces
- §10 Session Management — Redis state, refresh flow, service classes

When implementing a new endpoint or module, read the corresponding design
document section first.

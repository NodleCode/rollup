---
applyTo: "beacon-relay/**/*.rs,beacon-relay/Cargo.toml"
---

# Rust Development Instructions (beacon-relay)

This project is a Rust API server using **axum 0.8**, **tokio**, and **serde**.
Full development standards are in `beacon-relay/AGENTS.md` — read that file
before making changes.

## Quick Reference

- **Build**: `cd beacon-relay && cargo build`
- **Test**: `cd beacon-relay && cargo test`
- **Lint**: `cd beacon-relay && cargo clippy -- -D warnings`
- **Format**: `cd beacon-relay && cargo fmt --check`
- **Run**: `cd beacon-relay && cargo run`

## Key Conventions

- Use `thiserror` for error types, implement `IntoResponse` for HTTP errors.
- Use `tracing` macros for logging, never `println!`.
- Handlers return `impl IntoResponse`; extract state via `axum::extract::State`.
- Config loaded via Figment: `config/default.toml` → env vars (`APP_` prefix).
- Integration tests use Tower `ServiceExt` to call the router directly.
- Always run `cargo clippy -- -D warnings` and `cargo fmt --check` before finishing.

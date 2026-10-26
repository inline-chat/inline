//! Codex on the bridge v2 session contract (spec §4.1, §4.2).
//!
//! Inline runs its own `codex app-server` over stdio, never Codex's managed
//! daemon. Every native event lands in the session stream; approvals offer
//! exactly the decisions Codex advertises, with Codex's labels.

mod connection;
mod decisions;
mod delivery;
mod manifest;
mod mapper;

pub use connection::{CodexHarness, CodexHarnessConfig, CodexSession};

#[cfg(test)]
mod fixture_tests;

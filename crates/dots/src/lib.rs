//! ChatGPT Dots client and relay connector.
//!
//! A Dot is a persistent ChatGPT agent with a native DM room. This crate
//! talks to the undocumented `chatgpt.com/backend-api` endpoints the ChatGPT
//! apps use, authenticating with the ChatGPT login held by the local Codex
//! app-server (`codex login`). It never stores credentials and never presents
//! itself as a browser.

#![forbid(unsafe_code)]

pub mod auth;
pub mod client;
pub mod connector;
pub mod error;
pub mod realtime;
pub mod types;

pub use auth::{AccessToken, CodexAppServerTokenSource, Identity, StaticTokenSource, TokenSource};
pub use client::{DotsClient, DotsConfig, MessageQuery, SendMessage};
pub use connector::{ConnectorSettings, DotRoom, DotsConnector, SyncState, discover};
pub use error::{DotsError, DotsResult};

/// First six characters of an id, for logs.
pub fn redact_id(id: &str) -> String {
    let prefix: String = id.chars().take(6).collect();
    format!("{prefix}…")
}

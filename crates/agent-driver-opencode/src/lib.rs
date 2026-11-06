//! Native OpenCode v2 driver for Inline's local coding-agent bridge.
//!
//! OpenCode v2 runs one background service per user that every client
//! shares. This driver is one more client of that service: it speaks the
//! service's HTTP API, follows its event stream, and serves Inline's tools
//! as a client-hosted MCP server, so an Inline thread and the owner's
//! terminal see the same live session.
//!
//! - [`service`]: find or start the shared service.
//! - [`api`]: HTTP requests and SSE streams.
//! - [`events`]: the routed event connection.
//! - [`mapper`]: OpenCode events to the bridge's session events.
//! - [`catalog`]: models, modes, commands, skills, folders and usage.
//! - [`tools`]: Inline's host tools over client MCP.
//! - [`harness`]: [`OpenCodeHarness`] and its sessions.

pub mod api;
pub mod catalog;
pub mod events;
pub mod harness;
pub mod ids;
pub mod link;
pub mod mapper;
pub mod service;
mod session;
pub mod sse;
pub mod tools;
pub mod version;

pub use harness::{OpenCodeHarness, OpenCodeHarnessConfig};
pub use service::{Endpoint, ServiceConfig, ServiceError};
pub use version::{CORE_FLOOR, native_supported};

/// Provider id shared with the ACP route, so bindings move between routes.
pub const PROVIDER: &str = "opencode";

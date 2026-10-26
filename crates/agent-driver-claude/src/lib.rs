//! Rust-native Claude Code driver for Inline's local coding-agent bridge.
//!
//! Inline runs the user's own installed `claude` and speaks its stream-json
//! control protocol directly, with no bundled runtime: all behavior lives in
//! the CLI, and the Agent SDKs are thin clients of the same protocol. The MIT
//! Python Agent SDK is the readable reference for this port; the TypeScript
//! SDK's `sdk.d.ts` is the coverage checklist.
//!
//! - [`options`]: how the CLI is launched (explicit permission mode,
//!   `--session-id` / `--resume`, scrubbed environment).
//! - [`client`]: the control protocol in both directions, cancellation and
//!   in-process MCP routing.
//! - [`wire`]: stdout frames, typed leniently, native payload always kept.
//! - [`input`]: user messages with `uuid`, `priority`, `shouldQuery`, `origin`.
//! - [`mcp`]: in-process MCP tool servers answered over `mcp_message`.
//! - [`sessions`]: the JSONL session store (list, history, rename, fork,
//!   subagent transcripts).
//! - [`agents`]: live sessions (`claude agents --json`) for held detection.
//! - [`harness`]: the bridge v2 session contract (`HarnessDriver`, `Session`).

pub mod agents;
pub mod client;
pub mod control;
pub mod harness;
pub mod input;
pub mod mcp;
pub mod options;
pub mod sessions;
pub mod transport;
pub mod version;
pub mod wire;

pub use client::{
    CancelSignal, ClaudeClient, ClientConfig, ClientEvent, ConnectError, ControlError,
    ControlHandler, EventReceiver, ExitReport, IncomingCall, RefuseAll,
};
pub use control::{
    InitializeRequest, InitializeResponse, InterruptReceipt, IncomingRequest, PermissionDecision,
    PermissionRequest,
};
pub use input::{Origin, Priority, UserContent, UserMessage};
pub use options::{LaunchOptions, ProcessHost, SessionStart};
pub use sessions::{SessionInfo, SessionMessage, SessionStore};
pub use version::ClaudeVersion;
pub use wire::{CliMessage, MessageKind, StartupFailure};

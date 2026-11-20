//! Computer use for agents Inline runs.
//!
//! `inline computer-use mcp` serves these tools over stdio MCP, and the bridge
//! hands that server to the agents that lack computer use of their own
//! (Claude, OpenCode, Amp). Agents work the way the best computer-use tools
//! do: read an app's accessibility tree, act on an element by its ref, fall
//! back to screen coordinates, and look at a screenshot when the tree is not
//! enough. Ref actions go to the app in the background, so the user keeps
//! their cursor and focus.
//!
//! Inline owns the tool surface ([`tools`]); the engine underneath is
//! agent-desktop, which can be swapped without changing what agents see.

mod server;
pub mod tools;

#[cfg(target_os = "macos")]
mod engine;
#[cfg(target_os = "macos")]
mod image;

pub use server::serve_stdio;

/// The MCP server name agents see the tools under (`mcp__computer__click`).
pub const SERVER_NAME: &str = "computer";

/// Whether this platform has computer use.
pub const fn is_supported() -> bool {
    cfg!(target_os = "macos")
}

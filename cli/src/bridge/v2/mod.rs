//! Bridge v2: Codex, Claude, OpenCode application v2 and qualified Amp ACP.
//!
//! OpenCode v1 and older Amp adapters stay on v1; INLINE_BRIDGE_V2 can roll back.

pub(crate) mod api;
#[cfg(test)]
mod corpus;
pub(crate) mod doc;
#[cfg(test)]
mod e2e;
pub(crate) mod files;
pub(crate) mod folders;
pub(crate) mod intake;
pub(crate) mod ledger;
pub(crate) mod limits;
pub(crate) mod render;
pub(crate) mod runtime;
pub(crate) mod settings;
pub(crate) mod tools;
pub(crate) mod work;

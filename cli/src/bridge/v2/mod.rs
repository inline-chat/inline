//! Bridge v2: the session-contract runtime, default for Codex and Claude in alpha.
//!
//! Other providers stay on v1; INLINE_BRIDGE_V2 can select providers or roll back.

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

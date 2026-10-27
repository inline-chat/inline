//! Bridge v2: the session-contract runtime, behind a per-provider flag.
//!
//! v1 stays untouched until a provider passes its stage acceptance.

pub(crate) mod api;
pub(crate) mod doc;
#[cfg(test)]
mod e2e;
pub(crate) mod files;
pub(crate) mod intake;
pub(crate) mod ledger;
pub(crate) mod render;
pub(crate) mod runtime;
pub(crate) mod tools;
pub(crate) mod work;

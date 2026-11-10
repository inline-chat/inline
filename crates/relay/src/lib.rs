//! Provider-neutral relay between one hosted-agent conversation on another
//! network and the owner's DM with an Inline bot.
//!
//! A [`Connector`] owns one network (auth, discovery, wire format, realtime,
//! capabilities). An [`InlineSide`] owns the bot's DM. The [`Relay`] owns
//! everything in between: the owner check, durable id mapping, cursors,
//! pending-send reservations, duplicate suppression, restart recovery,
//! confirmation claims, task cards, and health.

#![forbid(unsafe_code)]
#![warn(missing_docs)]

mod engine;
mod model;
pub mod render;
mod store;

pub use engine::{Relay, RelayConfig, RelayError, RelayHealth, RelayResult, correlation_id};
pub use model::*;
pub use store::{
    ConfirmationCard, ConfirmationState, Link, Origin, PendingSend, RelayStore, StoreError,
    StoreResult, part,
};

#[cfg(test)]
mod tests;

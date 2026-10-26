//! Per-operation availability and the capability manifest (spec §4.3).
//!
//! Capabilities come from the binary on every connection. The core (start,
//! resume, turn, steer, interrupt, approvals, items, history) has a version
//! floor; below it the runtime needs setup. Everything else degrades per
//! operation with a visible reason.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use super::{DeliveryKind, OpKind};
use crate::ProviderId;

/// Whether one operation or delivery can be used, and why not.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Availability {
    /// Usable now.
    Supported,
    /// Needs a newer harness ("Queue needs Codex ≥ 0.150.0").
    NeedsVersion {
        /// Minimum harness version.
        min: String,
    },
    /// Needs a harness feature or flag that is off.
    NeedsFeature {
        /// Native feature or flag name.
        flag: String,
    },
    /// Not available, with a reason shown to the user.
    Unavailable {
        /// Human-readable reason.
        reason: String,
    },
}

impl Availability {
    /// Whether the operation can be used.
    pub fn is_supported(&self) -> bool {
        matches!(self, Self::Supported)
    }

    /// Shorthand for [`Availability::Unavailable`].
    pub fn unavailable(reason: impl Into<String>) -> Self {
        Self::Unavailable {
            reason: reason.into(),
        }
    }

    /// The user-facing reason, or `None` when supported.
    pub fn reason(&self, harness: &str) -> Option<String> {
        match self {
            Self::Supported => None,
            Self::NeedsVersion { min } => Some(format!("needs {harness} ≥ {min}")),
            Self::NeedsFeature { flag } => Some(format!("needs the {harness} feature `{flag}`")),
            Self::Unavailable { reason } => Some(reason.clone()),
        }
    }
}

impl std::fmt::Display for Availability {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Supported => formatter.write_str("supported"),
            Self::NeedsVersion { min } => write!(formatter, "needs version {min} or newer"),
            Self::NeedsFeature { flag } => write!(formatter, "needs feature {flag}"),
            Self::Unavailable { reason } => formatter.write_str(reason),
        }
    }
}

/// Availability of every operation and delivery for one connection.
///
/// A missing entry means the driver did not declare it and reads as
/// unavailable: the table fails closed.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AvailabilityMatrix {
    /// By delivery.
    #[serde(default)]
    pub deliveries: BTreeMap<DeliveryKind, Availability>,
    /// By operation.
    #[serde(default)]
    pub ops: BTreeMap<OpKind, Availability>,
}

impl AvailabilityMatrix {
    /// Availability of one delivery.
    pub fn delivery(&self, kind: DeliveryKind) -> Availability {
        self.deliveries
            .get(&kind)
            .cloned()
            .unwrap_or_else(|| Availability::unavailable("not offered by this harness"))
    }

    /// Availability of one operation.
    pub fn op(&self, kind: OpKind) -> Availability {
        self.ops
            .get(&kind)
            .cloned()
            .unwrap_or_else(|| Availability::unavailable("not offered by this harness"))
    }

    /// Builder: declare one delivery.
    pub fn with_delivery(mut self, kind: DeliveryKind, availability: Availability) -> Self {
        self.deliveries.insert(kind, availability);
        self
    }

    /// Builder: declare one operation.
    pub fn with_op(mut self, kind: OpKind, availability: Availability) -> Self {
        self.ops.insert(kind, availability);
        self
    }
}

/// Compatibility tier of the connected harness.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tier", rename_all = "snake_case")]
pub enum CompatTier {
    /// The core works; other operations follow the availability table.
    Supported,
    /// The harness is older than the core floor: `needs_setup{update_runtime}`.
    BelowFloor {
        /// Core floor version.
        min_version: String,
    },
    /// The harness has a core shape this bridge cannot parse: `needs_setup{update_inline}`.
    NewerThanBridge {
        /// What did not parse.
        reason: String,
    },
}

/// Everything learned about a harness binary on one connection.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilityManifest {
    /// Provider the manifest describes.
    pub provider: ProviderId,
    /// Harness version from the binary (Codex `userAgent`, Claude `claude_code_version`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Hash of the executable the schema was generated from (cache key).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary_sha256: Option<String>,
    /// Hash of the generated protocol schema (drift detection).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema_sha256: Option<String>,
    /// Two-tier compatibility verdict.
    pub tier: CompatTier,
    /// Per-operation availability.
    pub availability: AvailabilityMatrix,
    /// Client request methods the harness serves.
    #[serde(default)]
    pub methods: BTreeSet<String>,
    /// Requests the harness may send the client (approvals, questions, dialogs).
    #[serde(default)]
    pub server_requests: BTreeSet<String>,
    /// Notifications the harness may send.
    #[serde(default)]
    pub notifications: BTreeSet<String>,
    /// Native item types.
    #[serde(default)]
    pub item_types: BTreeSet<String>,
    /// Native approval decisions, by request kind (`commandExecution` → `accept`, ...).
    #[serde(default)]
    pub approval_decisions: BTreeMap<String, BTreeSet<String>>,
}

impl CapabilityManifest {
    /// Whether the core can run.
    pub fn core_ready(&self) -> bool {
        matches!(self.tier, CompatTier::Supported)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn undeclared_entries_fail_closed() {
        let matrix = AvailabilityMatrix::default()
            .with_delivery(DeliveryKind::Turn, Availability::Supported)
            .with_op(
                OpKind::QueueStart,
                Availability::NeedsVersion {
                    min: "0.150.0".to_owned(),
                },
            );
        assert!(matrix.delivery(DeliveryKind::Turn).is_supported());
        assert!(!matrix.delivery(DeliveryKind::Passive).is_supported());
        assert_eq!(
            matrix.op(OpKind::QueueStart).reason("Codex").as_deref(),
            Some("needs Codex ≥ 0.150.0")
        );
        assert!(!matrix.op(OpKind::Sample).is_supported());
    }

    #[test]
    fn matrix_serializes_with_readable_keys() {
        let matrix = AvailabilityMatrix::default()
            .with_delivery(DeliveryKind::SteerNext, Availability::Supported)
            .with_op(
                OpKind::Sample,
                Availability::NeedsFeature {
                    flag: "experimentalApi".to_owned(),
                },
            );
        let encoded = serde_json::to_value(&matrix).expect("encode");
        assert_eq!(
            encoded,
            serde_json::json!({
                "deliveries": {"steer_next": {"status": "supported"}},
                "ops": {"sample": {"status": "needs_feature", "flag": "experimentalApi"}}
            })
        );
        assert_eq!(
            serde_json::from_value::<AvailabilityMatrix>(encoded).expect("decode"),
            matrix
        );
    }
}

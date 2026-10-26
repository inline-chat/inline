//! Codex capability manifest (spec §4.3).
//!
//! Built on every connection from the app-server version and the protocol
//! schema the binary generates (`codex app-server generate-json-schema
//! --experimental`), cached by the binary's SHA-256. The core has a floor;
//! everything else degrades per operation with a reason.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use inline_agent_bridge::ProviderId;
use inline_agent_bridge::harness::{
    Availability, AvailabilityMatrix, CapabilityManifest, CompatTier, DeliveryKind, OpKind,
};
use semver::Version;
use serde_json::Value;
use sha2::{Digest, Sha256};

/// Oldest Codex the core supports. The CI matrix includes it (spec §9).
pub(crate) const CORE_FLOOR: Version = Version::new(0, 146, 0);

/// Methods the core cannot work without.
const CORE_METHODS: &[&str] = &[
    "thread/start",
    "thread/resume",
    "turn/start",
    "turn/steer",
    "turn/interrupt",
];

/// Protocol surface parsed from a generated schema bundle.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct SchemaSurface {
    pub methods: BTreeSet<String>,
    pub server_requests: BTreeSet<String>,
    pub notifications: BTreeSet<String>,
    pub item_types: BTreeSet<String>,
    pub command_decisions: BTreeSet<String>,
    pub sha256: String,
}

/// Reads the method, request, notification, item and decision sets from a
/// `generate-json-schema --experimental` output directory.
pub(crate) fn read_schema_dir(dir: &Path) -> std::io::Result<SchemaSurface> {
    let read = |name: &str| -> std::io::Result<Value> {
        let text = std::fs::read_to_string(dir.join(name))?;
        serde_json::from_str(&text).map_err(std::io::Error::other)
    };
    let mut hasher = Sha256::new();
    let mut surface = SchemaSurface::default();
    for (file, target) in [
        ("ClientRequest.json", &mut surface.methods),
        ("ServerRequest.json", &mut surface.server_requests),
        ("ServerNotification.json", &mut surface.notifications),
    ] {
        let value = read(file)?;
        hasher.update(value.to_string().as_bytes());
        target.extend(method_names(&value));
    }
    if let Ok(bundle) = read("codex_app_server_protocol.v2.schemas.json") {
        hasher.update(bundle.to_string().as_bytes());
        let definitions = bundle.get("definitions");
        if let Some(item) = definitions.and_then(|definitions| definitions.get("ThreadItem")) {
            surface.item_types.extend(tag_values(item, "type"));
        }
        if let Some(decision) =
            definitions.and_then(|definitions| definitions.get("CommandExecutionApprovalDecision"))
        {
            surface.command_decisions.extend(decision_names(decision));
        }
    }
    surface.sha256 = hex(&hasher.finalize());
    Ok(surface)
}

fn method_names(value: &Value) -> Vec<String> {
    value
        .get("oneOf")
        .or_else(|| value.get("anyOf"))
        .and_then(Value::as_array)
        .map(|variants| {
            variants
                .iter()
                .flat_map(|variant| tag_values_of(variant, "method"))
                .collect()
        })
        .unwrap_or_default()
}

fn tag_values(value: &Value, tag: &str) -> Vec<String> {
    value
        .get("oneOf")
        .or_else(|| value.get("anyOf"))
        .and_then(Value::as_array)
        .map(|variants| {
            variants
                .iter()
                .flat_map(|variant| tag_values_of(variant, tag))
                .collect()
        })
        .unwrap_or_default()
}

fn tag_values_of(variant: &Value, tag: &str) -> Vec<String> {
    let Some(property) = variant.pointer(&format!("/properties/{tag}")) else {
        return Vec::new();
    };
    if let Some(value) = property.get("const").and_then(Value::as_str) {
        return vec![value.to_owned()];
    }
    property
        .get("enum")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn decision_names(decision: &Value) -> Vec<String> {
    decision
        .get("oneOf")
        .and_then(Value::as_array)
        .map(|variants| {
            variants
                .iter()
                .flat_map(|variant| {
                    let mut names: Vec<String> = variant
                        .get("enum")
                        .and_then(Value::as_array)
                        .map(|values| {
                            values
                                .iter()
                                .filter_map(Value::as_str)
                                .map(str::to_owned)
                                .collect()
                        })
                        .unwrap_or_default();
                    if let Some(required) = variant.get("required").and_then(Value::as_array) {
                        names.extend(required.iter().filter_map(Value::as_str).map(str::to_owned));
                    }
                    names
                })
                .collect()
        })
        .unwrap_or_default()
}

/// SHA-256 of the executable, the schema cache key.
pub(crate) fn binary_sha256(path: &Path) -> std::io::Result<String> {
    let bytes = std::fs::read(path)?;
    Ok(hex(&Sha256::digest(&bytes)))
}

/// Cache folder for one binary hash under `cache_root`.
pub(crate) fn schema_cache_dir(cache_root: &Path, binary_sha256: &str) -> PathBuf {
    cache_root.join("codex-schema").join(binary_sha256)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Builds the manifest. `surface` is `None` when the binary cannot generate a
/// schema; then availability follows the version alone and experimental
/// operations stay unavailable.
pub(crate) fn build_manifest(
    version: Option<&Version>,
    binary_sha256: Option<String>,
    surface: Option<&SchemaSurface>,
) -> CapabilityManifest {
    let has = |method: &str| surface.is_none_or(|surface| surface.methods.contains(method));
    let tier = match version {
        Some(version) if version < &CORE_FLOOR => CompatTier::BelowFloor {
            min_version: CORE_FLOOR.to_string(),
        },
        _ => match CORE_METHODS.iter().find(|method| !has(method)) {
            Some(missing) => CompatTier::NewerThanBridge {
                reason: format!("Codex no longer offers `{missing}`"),
            },
            None => CompatTier::Supported,
        },
    };
    let gated = |method: &str| -> Availability {
        match surface {
            Some(surface) if surface.methods.contains(method) => Availability::Supported,
            Some(_) => Availability::Unavailable {
                reason: format!("this Codex has no `{method}`; update Codex"),
            },
            None => Availability::NeedsFeature {
                flag: format!("{method} (schema unavailable)"),
            },
        }
    };
    let core = |method: &str| -> Availability {
        if has(method) {
            Availability::Supported
        } else {
            Availability::Unavailable {
                reason: format!("this Codex has no `{method}`"),
            }
        }
    };
    let unavailable = Availability::unavailable;
    let availability = AvailabilityMatrix::default()
        .with_delivery(DeliveryKind::Turn, core("turn/start"))
        .with_delivery(DeliveryKind::SteerNow, core("turn/steer"))
        .with_delivery(DeliveryKind::SteerNext, core("turn/steer"))
        .with_delivery(DeliveryKind::Queue, gated("thread/queue/add"))
        .with_delivery(DeliveryKind::Passive, gated("thread/inject_items"))
        .with_op(OpKind::Interrupt, core("turn/interrupt"))
        .with_op(
            OpKind::InterruptCancelQueued,
            unavailable("Codex keeps its queue after a stop"),
        )
        .with_op(OpKind::QueueStart, gated("thread/queue/start"))
        .with_op(OpKind::QueueEdit, gated("thread/queue/delete"))
        .with_op(OpKind::SettingsTurn, gated("turn/settings/update"))
        .with_op(OpKind::SettingsThread, gated("thread/settings/update"))
        .with_op(OpKind::SettingsPersisted, gated("config/batchWrite"))
        .with_op(OpKind::Compact, gated("thread/compact/start"))
        .with_op(OpKind::Rename, gated("thread/name/set"))
        .with_op(OpKind::Archive, gated("thread/archive"))
        .with_op(
            OpKind::Clear,
            unavailable("Codex has no clear; use /new for a fresh session"),
        )
        .with_op(OpKind::RewindFiles, gated("thread/revert"))
        .with_op(OpKind::Mode, gated("collaborationMode/list"))
        .with_op(OpKind::Review, gated("review/start"))
        .with_op(OpKind::Goal, gated("thread/goal/set"))
        .with_op(
            OpKind::StopChild,
            gated("thread/backgroundTerminals/terminate"),
        )
        .with_op(OpKind::Answer, Availability::Supported)
        .with_op(OpKind::Sample, gated("thread/sample"))
        .with_op(OpKind::McpAuth, gated("mcpServer/oauth/login"));
    let mut approval_decisions = BTreeMap::new();
    if let Some(surface) = surface
        && !surface.command_decisions.is_empty()
    {
        approval_decisions.insert(
            "commandExecution".to_owned(),
            surface.command_decisions.clone(),
        );
    }
    CapabilityManifest {
        provider: ProviderId::new("codex").expect("provider id"),
        version: version.map(Version::to_string),
        binary_sha256,
        schema_sha256: surface.map(|surface| surface.sha256.clone()),
        tier,
        availability,
        methods: surface
            .map(|surface| surface.methods.clone())
            .unwrap_or_default(),
        server_requests: surface
            .map(|surface| surface.server_requests.clone())
            .unwrap_or_default(),
        notifications: surface
            .map(|surface| surface.notifications.clone())
            .unwrap_or_default(),
        item_types: surface
            .map(|surface| surface.item_types.clone())
            .unwrap_or_default(),
        approval_decisions,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn surface(methods: &[&str]) -> SchemaSurface {
        SchemaSurface {
            methods: methods.iter().map(|method| (*method).to_owned()).collect(),
            ..SchemaSurface::default()
        }
    }

    #[test]
    fn below_the_floor_needs_an_update_and_missing_core_needs_inline() {
        let old = build_manifest(Some(&Version::new(0, 145, 9)), None, None);
        assert_eq!(
            old.tier,
            CompatTier::BelowFloor {
                min_version: "0.146.0".to_owned()
            }
        );
        let broken = build_manifest(
            Some(&Version::new(0, 170, 0)),
            None,
            Some(&surface(&[
                "thread/start",
                "thread/resume",
                "turn/start",
                "turn/interrupt",
            ])),
        );
        assert!(matches!(broken.tier, CompatTier::NewerThanBridge { .. }));
    }

    #[test]
    fn optional_operations_follow_the_schema() {
        let manifest = build_manifest(
            Some(&Version::new(0, 162, 0)),
            Some("abc".to_owned()),
            Some(&surface(&[
                "thread/start",
                "thread/resume",
                "turn/start",
                "turn/steer",
                "turn/interrupt",
                "thread/queue/add",
            ])),
        );
        assert!(manifest.core_ready());
        assert!(
            manifest
                .availability
                .delivery(DeliveryKind::Queue)
                .is_supported()
        );
        assert!(!manifest.availability.op(OpKind::Sample).is_supported());
        assert!(
            !manifest
                .availability
                .op(OpKind::InterruptCancelQueued)
                .is_supported()
        );
    }

    #[test]
    fn schema_bundles_parse_methods_items_and_decisions() {
        let dir = tempfile::tempdir().expect("dir");
        let write = |name: &str, value: Value| {
            std::fs::write(dir.path().join(name), value.to_string()).expect("write");
        };
        write(
            "ClientRequest.json",
            serde_json::json!({"oneOf": [{"properties": {"method": {"enum": ["turn/start"]}}}]}),
        );
        write(
            "ServerRequest.json",
            serde_json::json!({"oneOf": [{"properties": {"method": {"const": "item/tool/call"}}}]}),
        );
        write("ServerNotification.json", serde_json::json!({"oneOf": []}));
        write(
            "codex_app_server_protocol.v2.schemas.json",
            serde_json::json!({"definitions": {
                "ThreadItem": {"oneOf": [{"properties": {"type": {"enum": ["agentMessage"]}}}]},
                "CommandExecutionApprovalDecision": {"oneOf": [
                    {"enum": ["accept"]},
                    {"required": ["acceptWithExecpolicyAmendment"]}
                ]}
            }}),
        );
        let surface = read_schema_dir(dir.path()).expect("surface");
        assert!(surface.methods.contains("turn/start"));
        assert!(surface.server_requests.contains("item/tool/call"));
        assert!(surface.item_types.contains("agentMessage"));
        assert!(
            surface
                .command_decisions
                .contains("acceptWithExecpolicyAmendment")
        );
        assert_eq!(surface.sha256.len(), 64);
    }
}

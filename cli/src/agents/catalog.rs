use clap::ValueEnum;
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentTarget {
    Openclaw,
    Hermes,
    Codex,
    Opencode,
    Claude,
    Amp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TargetFamily {
    Gateway,
    Bridge,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct TargetDescriptor {
    pub(crate) target: AgentTarget,
    pub(crate) id: &'static str,
    pub(crate) display_name: &'static str,
    pub(crate) executable: &'static str,
    pub(crate) family: TargetFamily,
}

impl AgentTarget {
    pub(crate) fn descriptor(self) -> &'static TargetDescriptor {
        TARGETS
            .iter()
            .find(|descriptor| descriptor.target == self)
            .expect("every target enum has a descriptor")
    }
}

pub(crate) const TARGETS: &[TargetDescriptor] = &[
    TargetDescriptor {
        target: AgentTarget::Openclaw,
        id: "openclaw",
        display_name: "OpenClaw",
        executable: "openclaw",
        family: TargetFamily::Gateway,
    },
    TargetDescriptor {
        target: AgentTarget::Hermes,
        id: "hermes",
        display_name: "Hermes",
        executable: "hermes",
        family: TargetFamily::Gateway,
    },
    TargetDescriptor {
        target: AgentTarget::Codex,
        id: "codex",
        display_name: "Codex",
        executable: "codex",
        family: TargetFamily::Bridge,
    },
    TargetDescriptor {
        target: AgentTarget::Opencode,
        id: "opencode",
        display_name: "OpenCode",
        executable: "opencode",
        family: TargetFamily::Bridge,
    },
    TargetDescriptor {
        target: AgentTarget::Claude,
        id: "claude",
        display_name: "Claude",
        executable: "claude",
        family: TargetFamily::Bridge,
    },
    TargetDescriptor {
        target: AgentTarget::Amp,
        id: "amp",
        display_name: "Amp",
        executable: "amp",
        family: TargetFamily::Bridge,
    },
];

pub(crate) fn bridge_catalog_matches() -> bool {
    let local = TARGETS
        .iter()
        .filter(|descriptor| descriptor.family == TargetFamily::Bridge)
        .map(|descriptor| {
            (
                descriptor.id,
                descriptor.display_name,
                descriptor.executable,
            )
        })
        .collect::<Vec<_>>();
    let canonical = crate::bridge::bridge_provider_setup_descriptors()
        .into_iter()
        .map(|descriptor| {
            (
                descriptor.provider_id,
                descriptor.display_name,
                descriptor.runtime_executable,
            )
        })
        .collect::<Vec<_>>();
    local == canonical
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_targets_match_the_canonical_bridge_catalog() {
        assert!(bridge_catalog_matches());
    }
}

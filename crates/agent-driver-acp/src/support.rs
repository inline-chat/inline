use std::path::PathBuf;

use inline_agent_bridge::ProviderId;

use crate::AcpLaunchDescriptor;

/// How an ACP-speaking provider is distributed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AcpDistribution {
    /// ACP is built into the provider's own executable.
    Native,
    /// ACP is supplied by a separately installed npm adapter.
    NpmAdapter(NpmAdapterDistribution),
    /// ACP is supplied by a source-pinned adapter artifact embedded by Inline.
    EmbeddedAdapter(EmbeddedAdapterDistribution),
}

/// Locally embedded adapter identity and provenance.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EmbeddedAdapterDistribution {
    /// Adapter version reported over ACP, plus a short source revision suffix.
    pub version: &'static str,
    /// Exact upstream source revision used to produce the embedded artifact.
    pub source_revision: &'static str,
    /// SHA-256 of the embedded executable artifact.
    pub checksum: &'static str,
}

/// Locally verified npm adapter metadata.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NpmAdapterDistribution {
    pub package: &'static str,
    /// Version recorded by the pinned local ACP Registry snapshot.
    pub registry_version: &'static str,
    /// Package integrity from locally pinned package or lock metadata.
    ///
    /// `None` deliberately prevents treating a registry version as a verified
    /// automatic-install pin.
    pub integrity: Option<&'static str>,
}

impl NpmAdapterDistribution {
    /// Whether the locally pinned evidence is sufficient for unattended install.
    pub const fn is_verified_install_pin(self) -> bool {
        self.integrity.is_some()
    }
}

/// Where setup can obtain a provider version without parsing startup logs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VersionDiscovery {
    /// Run the executable with these arguments before launching ACP.
    Command(&'static [&'static str]),
    /// Read `agentInfo.version` from the negotiated ACP initialize response.
    InitializeAgentInfo,
}

/// A non-interactive command that reports whether the underlying CLI is logged in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AuthProbe {
    pub program: &'static str,
    pub arguments: &'static [&'static str],
}

/// Provider-owned environment that may survive the bridge's secret scrubber.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SensitiveEnvironmentPolicy {
    /// Sensitive names beginning with one of these prefixes may be inherited.
    pub allowed_prefixes: &'static [&'static str],
    /// Sensitive names that may be inherited even without a permitted prefix.
    pub allowed_exact: &'static [&'static str],
    /// Names that must be removed even when they match an allowed prefix.
    pub removed_exact: &'static [&'static str],
    /// False means local sources do not enumerate every supported credential name.
    pub evidence_complete: bool,
}

impl SensitiveEnvironmentPolicy {
    /// Returns whether a sensitive environment name may be inherited.
    pub fn allows(self, name: &str) -> bool {
        if self.removed_exact.contains(&name) {
            return false;
        }
        self.allowed_exact.contains(&name)
            || self
                .allowed_prefixes
                .iter()
                .any(|prefix| name.starts_with(prefix))
    }
}

/// Features a client may present optimistically before ACP initialization.
///
/// Optional fields remain `None` when the pinned provider sources do not make
/// a stable guarantee. Runtime behavior must still follow negotiated ACP
/// capabilities and session config options.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AcpCapabilityExpectations {
    pub authentication: bool,
    pub load_session: Option<bool>,
    /// Whether durable sessions are reliable across adapter process epochs.
    pub durable_session_resume: bool,
    pub permission_requests: Option<bool>,
    pub session_config_options: Option<bool>,
}

/// Evidence-backed launch and setup metadata for one supported ACP provider.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AcpProviderSupport {
    pub provider_id: &'static str,
    pub display_name: &'static str,
    pub executable: &'static str,
    pub executable_aliases: &'static [&'static str],
    pub arguments: &'static [&'static str],
    pub distribution: AcpDistribution,
    pub version_discovery: VersionDiscovery,
    pub login_program: &'static str,
    pub login_arguments: &'static [&'static str],
    pub auth_probe: Option<AuthProbe>,
    pub environment: SensitiveEnvironmentPolicy,
    pub expected_mode_ids: &'static [&'static str],
    pub capabilities: AcpCapabilityExpectations,
}

impl AcpProviderSupport {
    /// Builds a launch descriptor carrying the verified adapter identity when
    /// this provider is backed by a pinned package.
    pub fn launch_descriptor(self, program_override: Option<PathBuf>) -> AcpLaunchDescriptor {
        let provider_id = ProviderId::new(self.provider_id).expect("static provider id");
        let program = program_override.unwrap_or_else(|| PathBuf::from(self.executable));
        let arguments = self
            .arguments
            .iter()
            .map(|arg| (*arg).to_string())
            .collect();
        match self.distribution {
            AcpDistribution::NpmAdapter(adapter) => AcpLaunchDescriptor {
                provider_id,
                program,
                arguments,
                provider_runtime: None,
                process_host: None,
                adapter_version: Some(adapter.registry_version.to_string()),
                adapter_checksum: adapter.integrity.map(str::to_string),
            },
            AcpDistribution::EmbeddedAdapter(adapter) => AcpLaunchDescriptor {
                provider_id,
                program,
                arguments,
                provider_runtime: None,
                process_host: None,
                adapter_version: Some(adapter.version.to_string()),
                adapter_checksum: Some(adapter.checksum.to_string()),
            },
            AcpDistribution::Native => AcpLaunchDescriptor {
                provider_id,
                program,
                arguments,
                provider_runtime: None,
                process_host: None,
                adapter_version: None,
                adapter_checksum: None,
            },
        }
    }
}

const OPENCODE: AcpProviderSupport = AcpProviderSupport {
    provider_id: "opencode",
    display_name: "OpenCode",
    executable: "opencode",
    executable_aliases: &[],
    arguments: &["acp"],
    distribution: AcpDistribution::Native,
    version_discovery: VersionDiscovery::Command(&["--version"]),
    login_program: "opencode",
    login_arguments: &["auth", "login"],
    auth_probe: None,
    environment: SensitiveEnvironmentPolicy {
        allowed_prefixes: &["OPENCODE_"],
        allowed_exact: &[],
        removed_exact: &[],
        // OpenCode also accepts credentials owned by many model providers.
        evidence_complete: false,
    },
    expected_mode_ids: &[],
    capabilities: AcpCapabilityExpectations {
        authentication: true,
        load_session: Some(true),
        durable_session_resume: true,
        permission_requests: Some(true),
        session_config_options: Some(true),
    },
};

const CLAUDE: AcpProviderSupport = AcpProviderSupport {
    provider_id: "claude",
    display_name: "Claude",
    executable: "claude-agent-acp",
    executable_aliases: &["claude-code-acp"],
    arguments: &[],
    distribution: AcpDistribution::NpmAdapter(NpmAdapterDistribution {
        package: "@agentclientprotocol/claude-agent-acp",
        registry_version: "0.73.0",
        integrity: Some(
            "sha512-xKnGIntdBbr2dDS2NEsVGdjoLH62EaWjfYlp/U7TYdxUJzERlApe2gliYW3rVFTeWGjG0dUyPszhG9TWhsqGlA==",
        ),
    }),
    version_discovery: VersionDiscovery::InitializeAgentInfo,
    login_program: "claude",
    login_arguments: &[],
    auth_probe: Some(AuthProbe {
        program: "claude",
        arguments: &["auth", "status"],
    }),
    environment: SensitiveEnvironmentPolicy {
        allowed_prefixes: &["ANTHROPIC_", "CLAUDE_"],
        allowed_exact: &[],
        // The adapter wraps Claude Code and otherwise rejects nested sessions.
        removed_exact: &["CLAUDECODE"],
        // The adapter source is not among the pinned local references.
        evidence_complete: false,
    },
    expected_mode_ids: &[
        "default",
        "acceptEdits",
        "plan",
        "auto",
        "bypassPermissions",
    ],
    capabilities: AcpCapabilityExpectations {
        authentication: true,
        load_session: None,
        durable_session_resume: false,
        permission_requests: Some(true),
        session_config_options: Some(true),
    },
};

const AMP: AcpProviderSupport = AcpProviderSupport {
    provider_id: "amp",
    display_name: "Amp",
    executable: "amp-acp",
    executable_aliases: &[],
    arguments: &[],
    distribution: AcpDistribution::EmbeddedAdapter(EmbeddedAdapterDistribution {
        version: "0.8.1+e4ccce1.inline1",
        source_revision: "e4ccce1b57c7ae92d75e8ba97fc03b92d414c06a",
        checksum: "sha256-ec55d86cff5ea604e67c6bc0862acf21259254114b881238bcdae57cded495eb",
    }),
    version_discovery: VersionDiscovery::InitializeAgentInfo,
    login_program: "amp",
    login_arguments: &[],
    auth_probe: None,
    environment: SensitiveEnvironmentPolicy {
        allowed_prefixes: &[],
        allowed_exact: &["AMP_API_KEY"],
        removed_exact: &[],
        // The pinned adapter documents Amp's API key as its headless
        // provider-owned authentication surface.
        evidence_complete: true,
    },
    expected_mode_ids: &["bypass", "default"],
    capabilities: AcpCapabilityExpectations {
        authentication: true,
        load_session: None,
        durable_session_resume: false,
        permission_requests: Some(true),
        session_config_options: Some(true),
    },
};

const PROVIDERS: &[AcpProviderSupport] = &[OPENCODE, CLAUDE, AMP];

/// Returns all ACP providers supported by the v1 bridge.
pub const fn provider_support_catalog() -> &'static [AcpProviderSupport] {
    PROVIDERS
}

/// Resolves a supported provider by its stable Inline provider ID.
pub fn provider_support(provider_id: &str) -> Option<&'static AcpProviderSupport> {
    PROVIDERS
        .iter()
        .find(|provider| provider.provider_id == provider_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_uses_native_opencode_and_shared_adapter_launches() {
        let opencode = provider_support("opencode").expect("opencode support");
        assert_eq!(opencode.arguments, ["acp"]);
        assert_eq!(opencode.distribution, AcpDistribution::Native);
        assert!(opencode.capabilities.durable_session_resume);

        let claude = provider_support("claude").expect("claude support");
        assert_eq!(claude.executable, "claude-agent-acp");
        assert_eq!(claude.arguments, [] as [&str; 0]);
        assert!(!claude.capabilities.durable_session_resume);

        let amp = provider_support("amp").expect("amp support");
        assert_eq!(amp.executable, "amp-acp");
        assert_eq!(amp.arguments, [] as [&str; 0]);
    }

    #[test]
    fn curated_adapters_have_complete_install_pins() {
        let claude = provider_support("claude").expect("Claude support");
        let AcpDistribution::NpmAdapter(adapter) = claude.distribution else {
            panic!("expected npm adapter");
        };
        assert!(adapter.is_verified_install_pin());

        let amp = provider_support("amp").expect("Amp support");
        let AcpDistribution::EmbeddedAdapter(adapter) = amp.distribution else {
            panic!("expected embedded adapter");
        };
        assert!(adapter.checksum.starts_with("sha256-"));
        assert_eq!(adapter.source_revision.len(), 40);
    }

    #[test]
    fn provider_environment_policy_preserves_auth_without_nested_claude_state() {
        let opencode = provider_support("opencode").expect("opencode support");
        assert!(opencode.environment.allows("OPENCODE_AUTH_CONTENT"));
        assert!(!opencode.environment.allows("INLINE_TOKEN"));

        let claude = provider_support("claude").expect("claude support");
        assert!(claude.environment.allows("ANTHROPIC_API_KEY"));
        assert!(claude.environment.allows("CLAUDE_CODE_EXECUTABLE"));
        assert!(!claude.environment.allows("CLAUDECODE"));

        let amp = provider_support("amp").expect("amp support");
        assert!(amp.environment.evidence_complete);
        assert!(amp.environment.allows("AMP_API_KEY"));
        assert!(!amp.environment.allows("AMP_TOKEN"));
    }

    #[test]
    fn launch_descriptors_preserve_verified_adapter_pins() {
        let support = provider_support("claude").expect("claude support");
        let descriptor = support.launch_descriptor(None);
        assert_eq!(descriptor.provider_id.as_str(), "claude");
        assert_eq!(descriptor.program, PathBuf::from("claude-agent-acp"));
        assert_eq!(descriptor.adapter_version.as_deref(), Some("0.73.0"));
        assert!(
            descriptor
                .adapter_checksum
                .as_deref()
                .is_some_and(|checksum| checksum.starts_with("sha512-"))
        );
        assert_eq!(descriptor.validate(), Ok(()));
        assert_eq!(
            support.expected_mode_ids,
            [
                "default",
                "acceptEdits",
                "plan",
                "auto",
                "bypassPermissions"
            ]
        );
        let auth = support.auth_probe.expect("Claude auth probe");
        assert_eq!(auth.program, "claude");
        assert_eq!(auth.arguments, ["auth", "status"]);
    }
}

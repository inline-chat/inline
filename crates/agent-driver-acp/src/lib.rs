//! Stable ACP v1 driver for Inline's local coding-agent bridge.

mod descriptor;
mod driver;
mod elicitation;
mod harness;
mod host_tools;
mod isolated_harness;
mod mapping;
mod opencode;
mod process;
mod support;

pub use descriptor::{AcpDescriptorError, AcpLaunchDescriptor};
pub use driver::AcpDriver;
pub use harness::{AcpHarness, AcpSession, acp_availability};
pub use host_tools::run_inline_tools_mcp;
pub use isolated_harness::IsolatedAcpHarness;
pub use opencode::{
    OPENCODE_MIGRATION_URL, OPENCODE_V1_GUIDANCE, parse_opencode_version, require_opencode_v2,
    require_supported_opencode_version,
};
pub use process::{
    AcpLaunchError, AcpProcessStatus, SpawnedAcpDriver, should_scrub_acp_environment_name,
    spawn_acp_driver,
};
pub use support::{
    AcpCapabilityExpectations, AcpDistribution, AcpProviderSupport, AuthProbe,
    EmbeddedAdapterDistribution, NpmAdapterDistribution, SensitiveEnvironmentPolicy,
    VersionDiscovery, provider_support, provider_support_catalog,
};

//! Stable ACP v1 driver for Inline's local coding-agent bridge.

mod descriptor;
mod driver;
mod elicitation;
mod host_tools;
mod mapping;
mod process;
mod support;

pub use descriptor::{AcpDescriptorError, AcpLaunchDescriptor};
pub use driver::AcpDriver;
pub use host_tools::run_inline_tools_mcp;
pub use process::{
    AcpLaunchError, AcpProcessStatus, SpawnedAcpDriver, should_scrub_acp_environment_name,
    spawn_acp_driver,
};
pub use support::{
    AcpCapabilityExpectations, AcpDistribution, AcpProviderSupport, AuthProbe,
    EmbeddedAdapterDistribution, NpmAdapterDistribution, SensitiveEnvironmentPolicy,
    VersionDiscovery, provider_support, provider_support_catalog,
};

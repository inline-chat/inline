use std::path::PathBuf;

use inline_agent_bridge::{ProcessHostConfig, ProviderId};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AcpLaunchDescriptor {
    pub provider_id: ProviderId,
    pub program: PathBuf,
    pub arguments: Vec<String>,
    /// Exact provider runtime selected during setup when an adapter wraps a
    /// second executable. Amp uses this to avoid resolving a different CLI
    /// from the background service's `PATH`.
    #[serde(default)]
    pub provider_runtime: Option<PathBuf>,
    #[serde(skip)]
    pub process_host: Option<ProcessHostConfig>,
    pub adapter_version: Option<String>,
    pub adapter_checksum: Option<String>,
}

impl AcpLaunchDescriptor {
    pub fn opencode(program: impl Into<PathBuf>) -> Self {
        Self {
            provider_id: ProviderId::new("opencode").expect("static provider id"),
            program: program.into(),
            arguments: vec!["acp".to_string()],
            provider_runtime: None,
            process_host: None,
            adapter_version: None,
            adapter_checksum: None,
        }
    }

    pub fn pinned_adapter(
        provider_id: ProviderId,
        program: impl Into<PathBuf>,
        arguments: Vec<String>,
        version: impl Into<String>,
        checksum: impl Into<String>,
    ) -> Result<Self, AcpDescriptorError> {
        let descriptor = Self {
            provider_id,
            program: program.into(),
            arguments,
            provider_runtime: None,
            process_host: None,
            adapter_version: Some(version.into()),
            adapter_checksum: Some(checksum.into()),
        };
        descriptor.validate()?;
        Ok(descriptor)
    }

    pub fn validate(&self) -> Result<(), AcpDescriptorError> {
        if self.program.as_os_str().is_empty() {
            return Err(AcpDescriptorError::MissingProgram);
        }
        if self
            .provider_runtime
            .as_ref()
            .is_some_and(|program| program.as_os_str().is_empty())
        {
            return Err(AcpDescriptorError::MissingProviderRuntime);
        }
        if self.provider_runtime.is_some() && self.provider_id.as_str() != "amp" {
            return Err(AcpDescriptorError::UnsupportedProviderRuntime);
        }
        if self.process_host.as_ref().is_some_and(|host| {
            host.executable.as_os_str().is_empty()
                || !host.executable.is_absolute()
                || host.lock_file.as_os_str().is_empty()
                || !host.lock_file.is_absolute()
        }) {
            return Err(AcpDescriptorError::InvalidProcessHost);
        }
        match (&self.adapter_version, &self.adapter_checksum) {
            (Some(version), Some(checksum))
                if !version.trim().is_empty() && !checksum.trim().is_empty() => {}
            (None, None) => {}
            _ => return Err(AcpDescriptorError::IncompleteAdapterPin),
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Error, PartialEq, Eq)]
pub enum AcpDescriptorError {
    #[error("ACP launch descriptor is missing a program")]
    MissingProgram,
    #[error("ACP launch descriptor has an empty provider runtime")]
    MissingProviderRuntime,
    #[error("only the Amp ACP adapter supports an explicit provider runtime")]
    UnsupportedProviderRuntime,
    #[error("ACP process host paths must be non-empty and absolute")]
    InvalidProcessHost,
    #[error("ACP adapter descriptors require both version and checksum")]
    IncompleteAdapterPin,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opencode_uses_native_acp_subcommand() {
        let descriptor = AcpLaunchDescriptor::opencode("opencode");
        assert_eq!(descriptor.arguments, ["acp"]);
        assert_eq!(descriptor.provider_id.as_str(), "opencode");
        assert_eq!(descriptor.validate(), Ok(()));
    }

    #[test]
    fn adapter_pin_must_be_complete() {
        let descriptor = AcpLaunchDescriptor {
            provider_id: ProviderId::new("claude").expect("provider id"),
            program: "claude-agent-acp".into(),
            arguments: Vec::new(),
            provider_runtime: None,
            process_host: None,
            adapter_version: Some("1.0.0".to_string()),
            adapter_checksum: None,
        };
        assert_eq!(
            descriptor.validate(),
            Err(AcpDescriptorError::IncompleteAdapterPin)
        );
    }
}

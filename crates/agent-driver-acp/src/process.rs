use std::ffi::OsString;

use agent_client_protocol::{AcpAgent, AcpAgentConfig};
use inline_agent_bridge::{DriverError, reap_stale_process_host};
use thiserror::Error;
use tokio::sync::watch;

use crate::{AcpDriver, AcpLaunchDescriptor, provider_support};

const ENV_PROGRAM: &str = "/usr/bin/env";

const ALWAYS_REMOVE_ENVIRONMENT: &[&str] = &[
    "INLINE_TOKEN",
    "INLINE_SECRETS_PATH",
    "INLINE_DEVICE_ID",
    "DATABASE_URL",
    "REDIS_URL",
    "SENTRY_DSN",
    "SENTRY_AUTH_TOKEN",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "NPM_TOKEN",
    "BUN_AUTH_TOKEN",
    "YARN_NPM_AUTH_TOKEN",
];

#[derive(Debug, Error)]
pub enum AcpLaunchError {
    #[error(transparent)]
    InvalidDescriptor(#[from] crate::AcpDescriptorError),
    #[error("ACP provider runtime is unavailable: {0}")]
    ProviderRuntimeUnavailable(std::path::PathBuf),
    #[error("ACP agent initialization failed: {0}")]
    Initialize(#[from] DriverError),
    #[error("ACP process host recovery failed: {0}")]
    ProcessHost(#[source] std::io::Error),
}

#[derive(Clone, Debug)]
pub struct AcpProcessStatus {
    completion: watch::Receiver<Option<Result<(), String>>>,
}

impl AcpProcessStatus {
    pub fn is_finished(&self) -> bool {
        self.completion.borrow().is_some()
    }

    pub fn exit_description(&self) -> Option<String> {
        self.completion
            .borrow()
            .as_ref()
            .map(|result| match result {
                Ok(()) => "ACP agent exited".to_string(),
                Err(error) => error.clone(),
            })
    }

    pub async fn wait(&self) -> Result<(), String> {
        let mut completion = self.completion.clone();
        loop {
            if let Some(result) = completion.borrow().clone() {
                return result;
            }
            completion
                .changed()
                .await
                .map_err(|_| "ACP process status channel closed".to_string())?;
        }
    }
}

#[derive(Debug)]
pub struct SpawnedAcpDriver {
    pub driver: AcpDriver,
    pub process_status: AcpProcessStatus,
}

pub async fn spawn_acp_driver(
    descriptor: AcpLaunchDescriptor,
    bridge_version: &str,
) -> Result<SpawnedAcpDriver, AcpLaunchError> {
    descriptor.validate()?;
    if let Some(provider_runtime) = descriptor.provider_runtime.as_ref()
        && !provider_runtime.is_file()
    {
        return Err(AcpLaunchError::ProviderRuntimeUnavailable(
            provider_runtime.clone(),
        ));
    }
    if let Some(process_host) = descriptor.process_host.as_ref() {
        reap_stale_process_host(&process_host.lock_file)
            .await
            .map_err(AcpLaunchError::ProcessHost)?;
    }
    let output_cache_dir = descriptor
        .process_host
        .as_ref()
        .and_then(|host| host.lock_file.parent())
        .map(|parent| parent.join("provider-output"));
    let agent = AcpAgent::new(scrubbed_launch_config(&descriptor));
    let durable_session_resume = provider_support(descriptor.provider_id.as_str())
        .is_none_or(|support| support.capabilities.durable_session_resume);
    let mut driver =
        AcpDriver::connect_transport_with_output_cache(agent, bridge_version, output_cache_dir)
            .await?;
    if !durable_session_resume {
        driver.disable_durable_session_resume();
    }
    let process_status = AcpProcessStatus {
        completion: driver.lifecycle.completion.clone(),
    };
    Ok(SpawnedAcpDriver {
        driver,
        process_status,
    })
}

fn scrubbed_launch_config(descriptor: &AcpLaunchDescriptor) -> AcpAgentConfig {
    let mut arguments = Vec::new();
    for name in environment_names_to_remove(descriptor) {
        arguments.push("-u".to_string());
        arguments.push(name.to_string_lossy().into_owned());
    }
    if let Some(provider_runtime) = descriptor.provider_runtime.as_ref() {
        arguments.push(format!(
            "AMP_CLI_PATH={}",
            provider_runtime.to_string_lossy()
        ));
        arguments.push("AMP_ACP_TRANSPORT=cli".to_string());
        arguments.push("AMP_SKIP_UPDATE_CHECK=1".to_string());
        arguments.push("CI=1".to_string());
    }
    if let Some(process_host) = descriptor.process_host.as_ref() {
        arguments.push(process_host.executable.to_string_lossy().into_owned());
        arguments.extend([
            "bridge".to_string(),
            "provider-host".to_string(),
            "--lock-file".to_string(),
            process_host.lock_file.to_string_lossy().into_owned(),
            "--".to_string(),
        ]);
    }
    arguments.push(descriptor.program.to_string_lossy().into_owned());
    arguments.extend(descriptor.arguments.iter().cloned());
    AcpAgentConfig::new(ENV_PROGRAM).args(arguments)
}

fn environment_names_to_remove(descriptor: &AcpLaunchDescriptor) -> Vec<OsString> {
    let provider_policy =
        provider_support(descriptor.provider_id.as_str()).map(|support| support.environment);
    let mut names = std::env::vars_os()
        .filter_map(|(name, _)| {
            should_scrub_acp_environment_name_with_policy(&name, provider_policy).then_some(name)
        })
        .collect::<Vec<_>>();
    for name in ALWAYS_REMOVE_ENVIRONMENT {
        if !provider_policy.is_some_and(|policy| policy.allows(name))
            && !names.iter().any(|candidate| candidate == name)
        {
            names.push(OsString::from(name));
        }
    }
    if let Some(policy) = provider_policy {
        for name in policy.removed_exact {
            if !names.iter().any(|candidate| candidate == name) {
                names.push(OsString::from(name));
            }
        }
    }
    names.sort();
    names.dedup();
    names
}

/// Returns whether a host environment variable must be removed before an ACP
/// provider probe or launch. Only credential names explicitly owned by the
/// selected provider's reviewed policy may survive the generic secret filter.
pub fn should_scrub_acp_environment_name(name: &std::ffi::OsStr, provider_id: &str) -> bool {
    let provider_policy = provider_support(provider_id).map(|support| support.environment);
    should_scrub_acp_environment_name_with_policy(name, provider_policy)
}

fn should_scrub_acp_environment_name_with_policy(
    name: &std::ffi::OsStr,
    provider_policy: Option<crate::SensitiveEnvironmentPolicy>,
) -> bool {
    let Some(name) = name.to_str() else {
        return true;
    };
    let uppercase = name.to_ascii_uppercase();
    if ALWAYS_REMOVE_ENVIRONMENT.contains(&uppercase.as_str())
        || uppercase.starts_with("INLINE_")
        || provider_policy.is_some_and(|policy| policy.removed_exact.contains(&uppercase.as_str()))
    {
        return true;
    }
    if provider_policy.is_some_and(|policy| policy.allows(&uppercase)) {
        return false;
    }

    let components: Vec<_> = uppercase.split('_').collect();
    components.iter().any(|component| {
        matches!(
            *component,
            "TOKEN"
                | "SECRET"
                | "PASSWORD"
                | "PASSWD"
                | "CREDENTIAL"
                | "CREDENTIALS"
                | "KEY"
                | "DSN"
        )
    }) || uppercase.contains("API_KEY")
        || uppercase.contains("ACCESS_KEY")
        || uppercase.contains("PRIVATE_KEY")
        || uppercase.contains("CONNECTION_STRING")
}

#[cfg(test)]
mod tests {
    use inline_agent_bridge::ProviderId;

    use super::*;

    #[test]
    fn launch_uses_env_unset_without_putting_secret_values_in_arguments() {
        let descriptor = AcpLaunchDescriptor::opencode("/opt/opencode");
        let config = scrubbed_launch_config(&descriptor);
        assert_eq!(config.command(), std::path::Path::new(ENV_PROGRAM));
        assert!(
            config
                .arguments()
                .windows(2)
                .any(|pair| pair == ["-u", "INLINE_TOKEN"])
        );
        assert!(config.arguments().iter().any(|arg| arg == "/opt/opencode"));
        assert!(config.arguments().iter().any(|arg| arg == "acp"));
    }

    #[test]
    fn launch_routes_the_provider_through_the_bundled_process_host() {
        let mut descriptor = AcpLaunchDescriptor::opencode("/opt/opencode");
        descriptor.process_host = Some(inline_agent_bridge::ProcessHostConfig {
            executable: "/opt/inline".into(),
            lock_file: "/tmp/provider.process.lock".into(),
        });

        let config = scrubbed_launch_config(&descriptor);
        let arguments = config.arguments();
        let host_index = arguments
            .iter()
            .position(|argument| argument == "/opt/inline")
            .expect("process host executable");
        assert_eq!(
            &arguments[host_index..],
            [
                "/opt/inline",
                "bridge",
                "provider-host",
                "--lock-file",
                "/tmp/provider.process.lock",
                "--",
                "/opt/opencode",
                "acp",
            ]
        );
    }

    #[test]
    fn environment_scrubber_removes_host_credentials_and_preserves_only_provider_auth() {
        let policy = provider_support("opencode")
            .expect("OpenCode support")
            .environment;
        for name in [
            "INLINE_TOKEN",
            "INLINE_BRIDGE_CONTROL_TOKEN",
            "GITHUB_TOKEN",
            "AWS_ACCESS_KEY_ID",
            "APP_PRIVATE_KEY",
            "SERVICE_CREDENTIALS",
            "DATABASE_URL",
            "SENTRY_DSN",
            "CUSTOM_CONNECTION_STRING",
        ] {
            assert!(
                should_scrub_acp_environment_name_with_policy(
                    std::ffi::OsStr::new(name),
                    Some(policy)
                ),
                "{name} should not reach an ACP provider"
            );
        }
        for name in [
            "PATH",
            "HOME",
            "SSH_AUTH_SOCK",
            "XDG_CONFIG_HOME",
            "OPENCODE_API_KEY",
            "OPENCODE_AUTH_CONTENT",
        ] {
            assert!(
                !should_scrub_acp_environment_name_with_policy(
                    std::ffi::OsStr::new(name),
                    Some(policy)
                ),
                "{name} is needed for normal OpenCode operation"
            );
        }
    }

    #[test]
    fn pinned_adapter_is_still_a_shared_acp_launch() {
        let descriptor = AcpLaunchDescriptor::pinned_adapter(
            ProviderId::new("claude").expect("provider"),
            "claude-agent-acp",
            Vec::new(),
            "1.2.3",
            "sha256:test",
        )
        .expect("descriptor");
        let config = scrubbed_launch_config(&descriptor);
        assert!(
            config
                .arguments()
                .iter()
                .any(|arg| arg == "claude-agent-acp")
        );
    }

    #[test]
    fn amp_launch_pins_the_installed_cli_runtime() {
        let mut descriptor = AcpLaunchDescriptor::pinned_adapter(
            ProviderId::new("amp").expect("provider"),
            "/bridge/node_modules/amp-acp/dist/index.js",
            Vec::new(),
            "0.8.1",
            "sha512:test",
        )
        .expect("descriptor");
        descriptor.provider_runtime = Some("/bridge/node_modules/.bin/amp".into());
        descriptor.validate().expect("runtime descriptor");

        let config = scrubbed_launch_config(&descriptor);
        assert!(
            config
                .arguments()
                .iter()
                .any(|arg| arg == "AMP_CLI_PATH=/bridge/node_modules/.bin/amp")
        );
        assert!(
            config
                .arguments()
                .iter()
                .any(|arg| arg == "AMP_ACP_TRANSPORT=cli")
        );
        assert!(
            config
                .arguments()
                .iter()
                .any(|arg| arg == "AMP_SKIP_UPDATE_CHECK=1")
        );
        assert!(config.arguments().iter().any(|arg| arg == "CI=1"));
        assert!(!should_scrub_acp_environment_name(
            std::ffi::OsStr::new("AMP_API_KEY"),
            "amp"
        ));
    }

    #[tokio::test]
    async fn process_completion_can_be_awaited_and_inspected() {
        let (completion_tx, completion_rx) = watch::channel(None);
        let status = AcpProcessStatus {
            completion: completion_rx,
        };
        assert!(!status.is_finished());
        assert_eq!(status.exit_description(), None);

        completion_tx
            .send(Some(Err("agent process exited with code 9".to_string())))
            .expect("status receiver");
        assert_eq!(
            status.wait().await,
            Err("agent process exited with code 9".to_string())
        );
        assert!(status.is_finished());
        assert_eq!(
            status.exit_description().as_deref(),
            Some("agent process exited with code 9")
        );
    }
}

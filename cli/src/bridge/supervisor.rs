//! Account-level provider membership and failure-isolation state.

use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;

use super::service::{ProviderRuntimeState, RuntimeHealth};
use super::*;

/// Starts one provider without making its already-connected Inline bot go
/// silent. Temporary launch failures remain local to this provider; eligible
/// deliveries are durably queued throughout backoff and initialization.
pub(super) struct ResponsiveProviderLaunch<'a> {
    pub provider_launch: &'a ProviderLaunch,
    pub installation: &'a ProviderInstallationConfig,
    pub provider_name: &'a str,
    pub bot: &'a InlineClient,
    pub route: &'a InboundRoute,
    pub readiness: Option<&'a ProviderReadiness>,
    pub installation_id: &'a str,
    pub probe_capacity: &'a tokio::sync::Semaphore,
}

pub(super) async fn launch_provider_responsively<T>(
    launch: ResponsiveProviderLaunch<'_>,
    inline_events: &mut inline_client::LosslessEventReceiver,
    external_shutdown: &mut Option<tokio::sync::watch::Receiver<bool>>,
    termination: &mut Pin<Box<T>>,
) -> Result<Option<SpawnedProvider>, Box<dyn std::error::Error>>
where
    T: Future<Output = ()>,
{
    let mut failures = 0_u32;
    loop {
        if failures > 0 {
            let mut retry_delay = Box::pin(tokio::time::sleep(provider_restart_delay(failures)));
            loop {
                tokio::select! {
                    _ = &mut retry_delay => break,
                    delivery = inline_events.recv_delivery() => {
                        let Some(delivery) = delivery else {
                            return Err(io::Error::new(
                                io::ErrorKind::ConnectionAborted,
                                "Inline bot event stream closed while the provider was starting",
                            ).into());
                        };
                        if let Some(readiness) = launch.readiness {
                            readiness.observe_inline_event(
                                delivery.event(),
                                launch.bot,
                                launch.installation_id,
                            );
                        }
                        accept_provider_unavailable_delivery(launch.bot, delivery, launch.route).await?;
                    }
                    _ = wait_for_control_shutdown(external_shutdown) => return Ok(None),
                    _ = termination.as_mut() => return Ok(None),
                }
            }
        }

        let mut spawning = Box::pin(async {
            if requires_service_prelaunch_probe(&launch.installation.provider_id) {
                // Bound compatibility probes without serializing the actual
                // provider startups. A slow sibling probe must not prevent an
                // already verified provider from becoming ready.
                let _probe_permit = launch.probe_capacity.acquire().await.map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "provider probe coordinator closed",
                    )
                })?;
                probe_service_provider_async(
                    &launch.installation.provider_id,
                    &launch.installation.executable,
                )
                .await
                .map_err(|message| io::Error::new(io::ErrorKind::NotFound, message))?;
            }
            launch
                .provider_launch
                .spawn(env!("CARGO_PKG_VERSION"))
                .await
        });
        let result = loop {
            tokio::select! {
                result = &mut spawning => break result,
                delivery = inline_events.recv_delivery() => {
                    let Some(delivery) = delivery else {
                        return Err(io::Error::new(
                            io::ErrorKind::ConnectionAborted,
                            "Inline bot event stream closed while the provider was starting",
                        ).into());
                    };
                    if let Some(readiness) = launch.readiness {
                        readiness.observe_inline_event(
                            delivery.event(),
                            launch.bot,
                            launch.installation_id,
                        );
                    }
                    accept_provider_unavailable_delivery(launch.bot, delivery, launch.route).await?;
                }
                _ = wait_for_control_shutdown(external_shutdown) => return Ok(None),
                _ = termination.as_mut() => return Ok(None),
            }
        };
        match result {
            Ok(spawned) => {
                if let Some(description) = spawned.process_status.exit_description() {
                    failures = failures.saturating_add(1);
                    if let Some(readiness) = launch.readiness {
                        readiness.mark_restarting(launch.installation_id);
                    }
                    eprintln!(
                        "{} exited during startup; retrying while Inline stays connected: {}",
                        launch.provider_name,
                        safe_diagnostic(&description)
                    );
                    let _ = spawned.driver.shutdown().await;
                    continue;
                }
                return Ok(Some(spawned));
            }
            Err(error) => {
                failures = failures.saturating_add(1);
                let requires_bridge_update = provider_probe_requires_bridge_update(
                    &launch.installation.provider_id,
                    &error.to_string(),
                );
                if let Some(readiness) = launch.readiness {
                    if requires_bridge_update {
                        readiness.mark_unavailable(launch.installation_id);
                    } else {
                        readiness.mark_restarting(launch.installation_id);
                    }
                }
                eprintln!(
                    "{} startup attempt failed{}: {}",
                    launch.provider_name,
                    if requires_bridge_update {
                        "; waiting for a compatible Inline update while the bot stays connected"
                    } else {
                        "; retrying while Inline stays connected"
                    },
                    safe_diagnostic(&error.to_string())
                );
                if requires_bridge_update {
                    loop {
                        tokio::select! {
                            delivery = inline_events.recv_delivery() => {
                                let Some(delivery) = delivery else {
                                    return Err(io::Error::new(
                                        io::ErrorKind::ConnectionAborted,
                                        "Inline bot event stream closed while the provider required an update",
                                    ).into());
                                };
                                if let Some(readiness) = launch.readiness {
                                    readiness.observe_inline_event(
                                        delivery.event(),
                                        launch.bot,
                                        launch.installation_id,
                                    );
                                }
                                accept_provider_unavailable_delivery(
                                    launch.bot,
                                    delivery,
                                    launch.route,
                                ).await?;
                            }
                            _ = wait_for_control_shutdown(external_shutdown) => return Ok(None),
                            _ = termination.as_mut() => return Ok(None),
                        }
                    }
                }
            }
        }
    }
}

pub(super) fn shutdown_requested(shutdown: &Option<tokio::sync::watch::Receiver<bool>>) -> bool {
    shutdown.as_ref().is_some_and(|shutdown| *shutdown.borrow())
}

#[derive(Clone, Debug)]
pub(super) struct ProviderReadiness {
    health: RuntimeHealth,
}

impl ProviderReadiness {
    pub(super) fn new(health: RuntimeHealth) -> Self {
        Self { health }
    }

    pub(super) fn mark_ready(&self, installation_id: &str) {
        self.health
            .mark_provider_state(installation_id, ProviderRuntimeState::Ready);
    }

    pub(super) fn mark_connected(&self, installation_id: &str) {
        self.health.mark_inline_connected(installation_id);
    }

    pub(super) fn mark_disconnected(&self, installation_id: &str) {
        self.health.mark_inline_disconnected(installation_id);
    }

    pub(super) fn mark_restarting(&self, installation_id: &str) {
        self.health
            .mark_provider_state(installation_id, ProviderRuntimeState::Restarting);
    }

    pub(super) fn mark_unavailable(&self, installation_id: &str) {
        self.health
            .mark_provider_state(installation_id, ProviderRuntimeState::Unavailable);
    }

    fn observe_inline_event(&self, event: &ClientEvent, bot: &InlineClient, installation_id: &str) {
        if !matches!(event, ClientEvent::StatusChanged { .. }) {
            return;
        }
        // Status events are durably replayed, but connection health is a
        // level-triggered property of the current client epoch. Project the
        // latest watch snapshot so an unacknowledged ShuttingDown/Connecting
        // event from the previous process cannot overwrite a successful new
        // connection.
        let snapshot = bot.status_snapshot();
        let status = snapshot.status;
        let failure = snapshot.failure;
        match failure {
            Some(ref failure) => eprintln!(
                "Inline connection for {installation_id} changed to {status:?} ({:?}): {}",
                failure.category,
                safe_diagnostic(&failure.message)
            ),
            None => eprintln!("Inline connection for {installation_id} changed to {status:?}."),
        }
        self.health
            .observe_inline_status(installation_id, status, failure.as_ref());
    }
}

pub(super) struct ProviderConnectionLease {
    readiness: Option<ProviderReadiness>,
    installation_id: String,
}

impl ProviderConnectionLease {
    pub(super) fn new(readiness: Option<&ProviderReadiness>, installation_id: &str) -> Self {
        if let Some(readiness) = readiness {
            readiness.mark_connected(installation_id);
        }
        Self {
            readiness: readiness.cloned(),
            installation_id: installation_id.to_string(),
        }
    }

    pub(super) fn observe(&self, event: &ClientEvent, bot: &InlineClient) {
        if let Some(readiness) = self.readiness.as_ref() {
            readiness.observe_inline_event(event, bot, &self.installation_id);
        }
    }
}

impl Drop for ProviderConnectionLease {
    fn drop(&mut self) {
        if let Some(readiness) = self.readiness.as_ref() {
            readiness.mark_disconnected(&self.installation_id);
        }
    }
}

#[derive(Debug)]
pub(super) struct ProviderSupervisor {
    active: HashSet<String>,
}

impl ProviderSupervisor {
    pub(super) fn new(installation_ids: impl IntoIterator<Item = String>) -> Self {
        Self {
            active: installation_ids.into_iter().collect(),
        }
    }

    /// Records one provider runtime ending and returns whether another remains.
    pub(super) fn provider_stopped(&mut self, installation_id: &str) -> bool {
        self.active.remove(installation_id);
        !self.active.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_provider_failure_does_not_stop_its_sibling() {
        let mut supervisor = ProviderSupervisor::new(["codex".to_string(), "opencode".to_string()]);

        assert!(supervisor.provider_stopped("codex"));
        assert!(!supervisor.provider_stopped("opencode"));
    }

    #[test]
    fn an_unknown_completion_cannot_empty_the_active_set() {
        let mut supervisor = ProviderSupervisor::new(["codex".to_string()]);
        assert!(supervisor.provider_stopped("unknown"));
        assert!(!supervisor.provider_stopped("codex"));
    }

    #[test]
    fn aggregate_readiness_survives_one_provider_restarting() {
        let health = RuntimeHealth::starting(["codex".to_string(), "opencode".to_string()]);
        let readiness = ProviderReadiness::new(health.clone());
        assert_eq!(health.snapshot(), (false, false));
        let codex_connection = ProviderConnectionLease::new(Some(&readiness), "codex");
        let opencode_connection = ProviderConnectionLease::new(Some(&readiness), "opencode");
        readiness.mark_ready("codex");
        readiness.mark_ready("opencode");
        readiness.mark_restarting("codex");
        assert_eq!(health.snapshot(), (true, true));
        readiness.mark_unavailable("opencode");
        assert_eq!(health.snapshot(), (true, false));
        drop(codex_connection);
        assert_eq!(health.snapshot(), (true, false));
        drop(opencode_connection);
        assert_eq!(health.snapshot(), (false, false));
    }

    #[test]
    fn connection_status_is_scoped_to_the_observed_provider() {
        let health = RuntimeHealth::starting(["codex".to_string(), "opencode".to_string()]);
        let readiness = ProviderReadiness::new(health.clone());
        let _codex = ProviderConnectionLease::new(Some(&readiness), "codex");
        let _opencode = ProviderConnectionLease::new(Some(&readiness), "opencode");

        health.observe_inline_status("codex", inline_client::ClientStatus::Reconnecting, None);

        let providers = health.provider_snapshot();
        let codex = providers
            .iter()
            .find(|provider| provider.installation_id == "codex")
            .expect("codex health");
        let opencode = providers
            .iter()
            .find(|provider| provider.installation_id == "opencode")
            .expect("opencode health");
        assert_eq!(codex.inline_connected, Some(false));
        assert_eq!(
            codex.detail.as_deref(),
            Some(BridgeNotice::InlineReconnecting.message())
        );
        assert_eq!(opencode.inline_connected, Some(true));
        assert!(health.snapshot().0);
    }

    #[test]
    fn replayed_status_event_projects_the_current_client_epoch() {
        let health = RuntimeHealth::starting(["codex".to_string()]);
        let readiness = ProviderReadiness::new(health.clone());
        let connection = ProviderConnectionLease::new(Some(&readiness), "codex");
        let bot = InlineClient::builder()
            .initial_status(inline_client::ClientStatus::Connected)
            .build()
            .client;

        connection.observe(
            &ClientEvent::StatusChanged {
                status: inline_client::ClientStatus::ShuttingDown,
                failure: None,
            },
            &bot,
        );

        let provider = health
            .provider_snapshot()
            .into_iter()
            .find(|provider| provider.installation_id == "codex")
            .expect("codex health");
        assert_eq!(provider.inline_connected, Some(true));
        assert_eq!(provider.detail, None);
    }

    #[test]
    fn requested_account_shutdown_wins_provider_completion_races() {
        let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
        let shutdown = Some(shutdown_rx);
        assert!(!shutdown_requested(&shutdown));
        shutdown_tx.send(true).expect("request shutdown");
        assert!(shutdown_requested(&shutdown));
    }
}

use std::collections::BTreeMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

use inline_client::{ClientFailure, ClientStatus};
use serde::{Deserialize, Serialize};

use super::super::copy::inline_client_notice;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(in crate::bridge) enum ProviderRuntimeState {
    Starting,
    Ready,
    Restarting,
    Unavailable,
}

impl ProviderRuntimeState {
    pub(in crate::bridge) fn status(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Ready => "running",
            Self::Restarting => "restarting",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(in crate::bridge) struct ProviderRuntimeStatus {
    pub(in crate::bridge) installation_id: String,
    pub(in crate::bridge) state: ProviderRuntimeState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(in crate::bridge) inline_connected: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(in crate::bridge) detail: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct InlineConnectionState {
    connected: bool,
    detail: Option<String>,
}

#[derive(Clone, Debug)]
struct ProviderHealthState {
    state: ProviderRuntimeState,
    detail: Option<String>,
}

#[derive(Clone, Debug)]
pub(in crate::bridge) struct RuntimeHealth {
    inline_connected: Arc<AtomicBool>,
    provider_ready: Arc<AtomicBool>,
    provider_states: Arc<Mutex<BTreeMap<String, ProviderHealthState>>>,
    inline_states: Arc<Mutex<BTreeMap<String, InlineConnectionState>>>,
}

impl RuntimeHealth {
    pub(in crate::bridge) fn starting(installation_ids: impl IntoIterator<Item = String>) -> Self {
        let installation_ids = installation_ids.into_iter().collect::<Vec<_>>();
        Self {
            inline_connected: Arc::new(AtomicBool::new(false)),
            provider_ready: Arc::new(AtomicBool::new(false)),
            provider_states: Arc::new(Mutex::new(
                installation_ids
                    .iter()
                    .cloned()
                    .map(|installation_id| {
                        (
                            installation_id,
                            ProviderHealthState {
                                state: ProviderRuntimeState::Starting,
                                detail: None,
                            },
                        )
                    })
                    .collect(),
            )),
            inline_states: Arc::new(Mutex::new(
                installation_ids
                    .into_iter()
                    .map(|installation_id| (installation_id, InlineConnectionState::default()))
                    .collect(),
            )),
        }
    }

    pub(in crate::bridge) fn ready() -> Self {
        Self {
            inline_connected: Arc::new(AtomicBool::new(true)),
            provider_ready: Arc::new(AtomicBool::new(true)),
            provider_states: Arc::new(Mutex::new(BTreeMap::new())),
            inline_states: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub(in crate::bridge) fn mark_provider_unavailable(&self) {
        self.provider_ready.store(false, Ordering::Release);
    }

    pub(in crate::bridge) fn mark_provider_ready(&self) {
        self.provider_ready.store(true, Ordering::Release);
    }

    pub(in crate::bridge) fn mark_stopped(&self) {
        self.inline_states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .values_mut()
            .for_each(|state| state.connected = false);
        self.inline_connected.store(false, Ordering::Release);
        self.provider_ready.store(false, Ordering::Release);
    }

    pub(in crate::bridge) fn mark_inline_connected(&self, installation_id: &str) {
        self.update_inline_state(installation_id, true, None);
    }

    pub(in crate::bridge) fn mark_inline_disconnected(&self, installation_id: &str) {
        self.update_inline_state(installation_id, false, None);
    }

    pub(in crate::bridge) fn observe_inline_status(
        &self,
        installation_id: &str,
        status: ClientStatus,
        failure: Option<&ClientFailure>,
    ) {
        let connected = matches!(status, ClientStatus::Connected);
        let detail =
            inline_client_notice(status, failure).map(|notice| notice.message().to_string());
        self.update_inline_state(installation_id, connected, detail);
    }

    fn update_inline_state(&self, installation_id: &str, connected: bool, detail: Option<String>) {
        let any_connected = {
            let mut states = self
                .inline_states
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            states.insert(
                installation_id.to_string(),
                InlineConnectionState { connected, detail },
            );
            states.values().any(|state| state.connected)
        };
        self.inline_connected
            .store(any_connected, Ordering::Release);
    }

    pub(in crate::bridge) fn mark_provider_state(
        &self,
        installation_id: &str,
        state: ProviderRuntimeState,
    ) {
        self.mark_provider_state_with_detail(installation_id, state, None);
    }

    pub(in crate::bridge) fn mark_provider_state_with_detail(
        &self,
        installation_id: &str,
        state: ProviderRuntimeState,
        detail: Option<&str>,
    ) {
        let detail = detail
            .map(crate::diagnostics::safe_text)
            .filter(|detail| !detail.is_empty());
        let any_ready = {
            let mut states = self
                .provider_states
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            states.insert(
                installation_id.to_string(),
                ProviderHealthState { state, detail },
            );
            states
                .values()
                .any(|state| matches!(state.state, ProviderRuntimeState::Ready))
        };
        self.provider_ready.store(any_ready, Ordering::Release);
    }

    pub(in crate::bridge) fn provider_snapshot(&self) -> Vec<ProviderRuntimeStatus> {
        let inline_states = self
            .inline_states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.provider_states
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .iter()
            .map(|(installation_id, state)| {
                let inline = inline_states.get(installation_id);
                ProviderRuntimeStatus {
                    installation_id: installation_id.clone(),
                    state: state.state,
                    inline_connected: inline.map(|inline| inline.connected),
                    detail: state
                        .detail
                        .clone()
                        .or_else(|| inline.and_then(|inline| inline.detail.clone())),
                }
            })
            .collect()
    }

    pub(in crate::bridge) fn snapshot(&self) -> (bool, bool) {
        (
            self.inline_connected.load(Ordering::Acquire),
            self.provider_ready.load(Ordering::Acquire),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_failure_survives_inline_connection_updates_and_clears_when_ready() {
        let health = RuntimeHealth::starting(["codex".into()]);
        health.mark_provider_state_with_detail(
            "codex",
            ProviderRuntimeState::Restarting,
            Some("Codex login expired; TOKEN=fixture-secret"),
        );
        health.mark_inline_connected("codex");
        let snapshot = health.provider_snapshot();
        assert!(
            snapshot[0]
                .detail
                .as_deref()
                .unwrap()
                .contains("login expired")
        );
        assert!(
            !snapshot[0]
                .detail
                .as_deref()
                .unwrap()
                .contains("fixture-secret")
        );
        health.mark_provider_state("codex", ProviderRuntimeState::Ready);
        assert!(health.provider_snapshot()[0].detail.is_none());
    }
}

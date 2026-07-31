use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use thiserror::Error;
use tokio::sync::Mutex;

use crate::{
    AgentDriver, BindingKey, BridgeStore, DriverError, ProviderId, ProviderSessionId,
    ResumeSessionSpec, SessionReplay, SessionSpec, StartedTurn, StoreError, TurnInput, TurnOptions,
};

/// Describes how a provider session became available to a bridge binding.
///
/// Automatic replacement is distinct from first creation so presentation
/// layers can tell the user once without exposing provider-specific failures.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionOpenOutcome {
    /// The session was already open in this bridge process.
    Active(ProviderSessionId),
    /// No durable binding existed, so a new provider session was created.
    Created(ProviderSessionId),
    /// A durable provider session was resumed successfully.
    Resumed(ProviderSessionId),
    /// A durable session could not be resumed and was atomically replaced.
    Replaced(ProviderSessionId),
}

impl SessionOpenOutcome {
    /// Returns the provider session selected for subsequent operations.
    pub const fn session_id(&self) -> &ProviderSessionId {
        match self {
            Self::Active(session_id)
            | Self::Created(session_id)
            | Self::Resumed(session_id)
            | Self::Replaced(session_id) => session_id,
        }
    }

    /// Consumes the outcome and returns the selected provider session.
    pub fn into_session_id(self) -> ProviderSessionId {
        match self {
            Self::Active(session_id)
            | Self::Created(session_id)
            | Self::Resumed(session_id)
            | Self::Replaced(session_id) => session_id,
        }
    }

    /// Whether an existing durable binding was replaced automatically.
    pub const fn was_replaced(&self) -> bool {
        matches!(self, Self::Replaced(_))
    }
}

/// Serializes provider-session creation/resume for bridge bindings and caches
/// sessions initialized in the current bridge process.
pub struct ProviderSessionManager<D> {
    driver: Arc<D>,
    store: Arc<BridgeStore>,
    provider_id: ProviderId,
    session_configuration_fingerprint: Option<String>,
    slots: Mutex<HashMap<BindingKey, Arc<Mutex<Option<ProviderSessionId>>>>>,
}

impl<D> std::fmt::Debug for ProviderSessionManager<D> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProviderSessionManager")
            .field("driver", &"<agent-driver>")
            .field("store", &self.store)
            .field("provider_id", &self.provider_id)
            .finish_non_exhaustive()
    }
}

impl<D> ProviderSessionManager<D>
where
    D: AgentDriver + 'static,
{
    pub fn new(driver: Arc<D>, store: Arc<BridgeStore>, provider_id: ProviderId) -> Self {
        Self {
            driver,
            store,
            provider_id,
            session_configuration_fingerprint: None,
            slots: Mutex::new(HashMap::new()),
        }
    }

    /// Requires durable sessions to have been created with the same immutable
    /// provider configuration. A mismatch rotates once instead of resuming a
    /// session whose native tools or other attached capabilities are stale.
    pub fn with_session_configuration_fingerprint(mut self, fingerprint: Option<String>) -> Self {
        self.session_configuration_fingerprint = fingerprint;
        self
    }

    pub fn driver(&self) -> &Arc<D> {
        &self.driver
    }

    pub fn provider_id(&self) -> &ProviderId {
        &self.provider_id
    }

    fn workspace_path(
        &self,
        binding: &BindingKey,
        now: i64,
    ) -> Result<PathBuf, SessionManagerError> {
        Ok(self
            .store
            .verified_workspace(&binding.installation_id, &binding.workspace_id, now)?
            .path)
    }

    /// Loads provider settings only after revalidating the registered
    /// workspace root. Some ACP providers create a prewarmed session while
    /// answering this request, so it has the same containment requirement as
    /// an explicit session start.
    pub async fn settings_catalog(
        &self,
        binding: &BindingKey,
        now: i64,
    ) -> Result<crate::DriverSettingsCatalog, SessionManagerError> {
        let cwd = self.workspace_path(binding, now)?;
        let capabilities = self.driver.capabilities();
        if capabilities.settings_catalog_starts_session {
            let slot = self.session_slot(binding).await;
            let active = slot.lock().await;
            if capabilities.resume_session
                && active.is_none()
                && self.store.get_binding(binding)?.is_some()
            {
                // A durable binding must be resumed by ensure_session. Starting
                // a disposable settings session here can serialize ahead of
                // resume inside ACP providers and make the first turn time out.
                return Ok(crate::DriverSettingsCatalog::default());
            }
            return Ok(self.driver.settings_catalog(&cwd).await?);
        }
        Ok(self.driver.settings_catalog(&cwd).await?)
    }

    pub async fn ensure_session(
        &self,
        binding: &BindingKey,
        now: i64,
    ) -> Result<SessionOpenOutcome, SessionManagerError> {
        let slot = self.session_slot(binding).await;
        let mut active = slot.lock().await;
        let cwd = self.workspace_path(binding, now)?;
        if let Some(session_id) = active.as_ref() {
            log::trace!(
                target: "inline_agent_bridge::session",
                "phase=session_active provider_id={:?} chat_id={} session_id={:?}",
                self.provider_id.as_str(),
                binding.chat_id,
                session_id.as_str()
            );
            return Ok(SessionOpenOutcome::Active(session_id.clone()));
        }

        let outcome = match self.store.get_binding_with_configuration(binding)? {
            Some((stored_provider, session_id, stored_fingerprint)) => {
                if stored_provider != self.provider_id {
                    return Err(SessionManagerError::ProviderMismatch {
                        expected: self.provider_id.clone(),
                        found: stored_provider,
                    });
                }
                if stored_fingerprint != self.session_configuration_fingerprint
                    || !self.driver.capabilities().resume_session
                {
                    log::trace!(
                        target: "inline_agent_bridge::session",
                        "phase=session_rotate provider_id={:?} chat_id={} reason={} stored_configuration={} required_configuration={}",
                        self.provider_id.as_str(),
                        binding.chat_id,
                        if stored_fingerprint != self.session_configuration_fingerprint {
                            "configuration_changed"
                        } else {
                            "resume_unsupported"
                        },
                        stored_fingerprint.is_some(),
                        self.session_configuration_fingerprint.is_some()
                    );
                    SessionOpenOutcome::Replaced(self.replace_session(binding, now).await?)
                } else {
                    log::trace!(
                        target: "inline_agent_bridge::session",
                        "phase=session_resume_started provider_id={:?} chat_id={} session_id={:?}",
                        self.provider_id.as_str(),
                        binding.chat_id,
                        session_id.as_str()
                    );
                    match self
                        .driver
                        .resume_session(ResumeSessionSpec {
                            session_id: session_id.clone(),
                            cwd: cwd.clone(),
                            replay: SessionReplay::None,
                        })
                        .await
                    {
                        Ok(()) => {
                            log::trace!(
                                target: "inline_agent_bridge::session",
                                "phase=session_resume_confirmed provider_id={:?} chat_id={} session_id={:?}",
                                self.provider_id.as_str(),
                                binding.chat_id,
                                session_id.as_str()
                            );
                            SessionOpenOutcome::Resumed(session_id)
                        }
                        // This is intentionally narrower than a generic rejection.
                        // A timeout, unavailable process, or ordinary provider error
                        // must keep the binding intact for a later retry.
                        Err(DriverError::InvalidSession(_)) => {
                            SessionOpenOutcome::Replaced(self.replace_session(binding, now).await?)
                        }
                        Err(error) => return Err(error.into()),
                    }
                }
            }
            None => {
                log::trace!(
                    target: "inline_agent_bridge::session",
                    "phase=session_create provider_id={:?} chat_id={}",
                    self.provider_id.as_str(),
                    binding.chat_id
                );
                SessionOpenOutcome::Created(self.replace_session(binding, now).await?)
            }
        };
        *active = Some(outcome.session_id().clone());
        Ok(outcome)
    }

    async fn session_slot(&self, binding: &BindingKey) -> Arc<Mutex<Option<ProviderSessionId>>> {
        let mut slots = self.slots.lock().await;
        slots
            .entry(binding.clone())
            .or_insert_with(|| Arc::new(Mutex::new(None)))
            .clone()
    }

    /// Starts a fresh provider session and persists it only after the provider
    /// accepted creation. This deliberately does not replay Inline or provider
    /// history into the new session.
    async fn replace_session(
        &self,
        binding: &BindingKey,
        now: i64,
    ) -> Result<ProviderSessionId, SessionManagerError> {
        let cwd = self.workspace_path(binding, now)?;
        let session_id = self.driver.start_session(SessionSpec { cwd }).await?;
        self.store.put_binding_with_configuration(
            binding,
            &self.provider_id,
            &session_id,
            self.session_configuration_fingerprint.as_deref(),
            now,
        )?;
        Ok(session_id)
    }

    pub async fn start_turn(
        &self,
        binding: &BindingKey,
        now: i64,
        input: TurnInput,
        mut options: TurnOptions,
    ) -> Result<(SessionOpenOutcome, StartedTurn), SessionManagerError> {
        let session = self.ensure_session(binding, now).await?;
        let cwd = self.workspace_path(binding, now)?;
        options.cwd.get_or_insert(cwd);
        let turn = self
            .driver
            .start_turn(session.session_id(), input, options)
            .await?;
        Ok((session, turn))
    }

    /// Rotates one binding to a fresh provider session without touching files
    /// or replaying Inline/provider history.
    pub async fn rotate_session(
        &self,
        binding: &BindingKey,
        now: i64,
    ) -> Result<ProviderSessionId, SessionManagerError> {
        let slot = self.session_slot(binding).await;
        let mut active = slot.lock().await;
        let session_id = self.replace_session(binding, now).await?;
        *active = Some(session_id.clone());
        Ok(session_id)
    }
}

#[derive(Debug, Error)]
pub enum SessionManagerError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Driver(#[from] DriverError),
    #[error("binding belongs to provider {found}, not {expected}")]
    ProviderMismatch {
        expected: ProviderId,
        found: ProviderId,
    },
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex as StdMutex;

    use super::*;
    use crate::{
        AgentEventReceiver, ApprovalDecision, DirectionId, DriverCapabilities, DriverFuture,
        DriverSettingsCatalog, InstallationId, SteeringSupport, TurnId, WorkspaceId,
    };

    #[derive(Debug)]
    struct FakeDriver {
        capabilities: DriverCapabilities,
        starts: StdMutex<Vec<PathBuf>>,
        settings_catalogs: StdMutex<Vec<PathBuf>>,
        resumes: StdMutex<Vec<ResumeSessionSpec>>,
        resume_error: StdMutex<Option<DriverError>>,
        yield_on_resume: bool,
        resume_gate: Option<Arc<tokio::sync::Barrier>>,
        turns: StdMutex<Vec<(ProviderSessionId, TurnInput, TurnOptions)>>,
    }

    impl Default for FakeDriver {
        fn default() -> Self {
            Self {
                capabilities: DriverCapabilities {
                    resume_session: true,
                    steering: SteeringSupport::Native,
                    ..DriverCapabilities::default()
                },
                starts: StdMutex::default(),
                settings_catalogs: StdMutex::default(),
                resumes: StdMutex::default(),
                resume_error: StdMutex::default(),
                yield_on_resume: false,
                resume_gate: None,
                turns: StdMutex::default(),
            }
        }
    }

    impl AgentDriver for FakeDriver {
        fn capabilities(&self) -> DriverCapabilities {
            self.capabilities.clone()
        }

        fn start_session<'a>(&'a self, spec: SessionSpec) -> DriverFuture<'a, ProviderSessionId> {
            Box::pin(async move {
                self.starts.lock().expect("starts").push(spec.cwd);
                ProviderSessionId::new("session-new")
                    .map_err(|error| DriverError::Protocol(error.to_string()))
            })
        }

        fn settings_catalog<'a>(
            &'a self,
            cwd: &'a std::path::Path,
        ) -> DriverFuture<'a, DriverSettingsCatalog> {
            Box::pin(async move {
                self.settings_catalogs
                    .lock()
                    .expect("settings catalogs")
                    .push(cwd.to_path_buf());
                Ok(DriverSettingsCatalog::default())
            })
        }

        fn resume_session<'a>(&'a self, spec: ResumeSessionSpec) -> DriverFuture<'a, ()> {
            Box::pin(async move {
                self.resumes.lock().expect("resumes").push(spec);
                if self.yield_on_resume {
                    tokio::task::yield_now().await;
                }
                if let Some(gate) = self.resume_gate.as_ref() {
                    gate.wait().await;
                }
                self.resume_error
                    .lock()
                    .expect("resume error")
                    .clone()
                    .map_or(Ok(()), Err)
            })
        }

        fn start_turn<'a>(
            &'a self,
            session_id: &'a ProviderSessionId,
            input: TurnInput,
            options: TurnOptions,
        ) -> DriverFuture<'a, StartedTurn> {
            Box::pin(async move {
                self.turns
                    .lock()
                    .expect("turns")
                    .push((session_id.clone(), input, options));
                let (_tx, events) = AgentEventReceiver::default_channel();
                Ok(StartedTurn {
                    turn_id: TurnId::new("turn-1")
                        .map_err(|error| DriverError::Protocol(error.to_string()))?,
                    events,
                })
            })
        }

        fn steer_turn<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
            _turn_id: &'a TurnId,
            _input: TurnInput,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn cancel_turn<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
            _turn_id: &'a TurnId,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn compact_session<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn resolve_approval<'a>(
            &'a self,
            _approval_id: &'a str,
            _decision: ApprovalDecision,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }
    }

    fn binding() -> BindingKey {
        BindingKey {
            installation_id: InstallationId::new("install-1").expect("installation"),
            chat_id: 7,
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
        }
    }

    fn registered_store(provider: &ProviderId) -> (tempfile::TempDir, Arc<BridgeStore>, PathBuf) {
        let workspace = tempfile::tempdir().expect("workspace");
        let cwd = std::fs::canonicalize(workspace.path()).expect("canonical workspace");
        let store = Arc::new(BridgeStore::open_in_memory().expect("store"));
        store
            .put_installation(&crate::InstallationRecord {
                installation_id: binding().installation_id,
                provider_id: provider.clone(),
                display_name: "Agent".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        store
            .select_workspace(&binding().installation_id, &binding().workspace_id, &cwd, 1)
            .expect("registered workspace");
        (workspace, store, cwd)
    }

    #[tokio::test]
    async fn creates_and_reuses_one_session_per_process() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider);

        let first = manager
            .ensure_session(&binding(), 10)
            .await
            .expect("first session");
        let second = manager
            .ensure_session(&binding(), 11)
            .await
            .expect("cached session");

        assert!(
            matches!(&first, SessionOpenOutcome::Created(session_id) if session_id.as_str() == "session-new")
        );
        assert!(
            matches!(&second, SessionOpenOutcome::Active(session_id) if session_id.as_str() == "session-new")
        );
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
        assert!(driver.resumes.lock().expect("resumes").is_empty());
        assert_eq!(
            store.get_binding(&binding()).expect("binding"),
            Some((ProviderId::new("codex").unwrap(), first.into_session_id()))
        );
    }

    #[tokio::test]
    async fn explicit_rotation_starts_and_persists_a_fresh_session() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider.clone());
        manager
            .ensure_session(&binding(), 10)
            .await
            .expect("first session");

        let rotated = manager
            .rotate_session(&binding(), 20)
            .await
            .expect("rotate");

        assert_eq!(driver.starts.lock().expect("starts").len(), 2);
        assert_eq!(
            store.get_binding(&binding()).expect("binding"),
            Some((provider, rotated))
        );
    }

    #[tokio::test]
    async fn resumes_a_durable_session_without_replaying_provider_history() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding(&binding(), &provider, &session, 10)
            .expect("binding");
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store, provider);

        let outcome = manager
            .ensure_session(&binding(), 20)
            .await
            .expect("resume");
        assert_eq!(outcome, SessionOpenOutcome::Resumed(session));
        let resumes = driver.resumes.lock().expect("resumes");
        assert_eq!(resumes.len(), 1);
        assert_eq!(resumes[0].replay, SessionReplay::None);
        assert!(driver.starts.lock().expect("starts").is_empty());
    }

    #[tokio::test]
    async fn rotates_a_durable_session_when_its_configuration_fingerprint_changes() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let old_session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding_with_configuration(
                &binding(),
                &provider,
                &old_session,
                Some("sha256:old"),
                10,
            )
            .expect("binding");
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider)
            .with_session_configuration_fingerprint(Some("sha256:new".to_string()));

        let outcome = manager
            .ensure_session(&binding(), 20)
            .await
            .expect("rotated session");

        assert!(matches!(outcome, SessionOpenOutcome::Replaced(_)));
        assert!(driver.resumes.lock().expect("resumes").is_empty());
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
        assert_eq!(
            store
                .get_binding_with_configuration(&binding())
                .expect("binding")
                .and_then(|(_, _, fingerprint)| fingerprint),
            Some("sha256:new".to_string())
        );
    }

    #[tokio::test]
    async fn cold_session_starting_catalog_does_not_race_durable_resume() {
        let provider = ProviderId::new("claude").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding(&binding(), &provider, &session, 10)
            .expect("binding");
        let driver = Arc::new(FakeDriver {
            capabilities: DriverCapabilities {
                resume_session: true,
                settings_catalog: true,
                settings_catalog_starts_session: true,
                ..DriverCapabilities::default()
            },
            ..FakeDriver::default()
        });
        let manager = ProviderSessionManager::new(driver.clone(), store, provider);

        assert_eq!(
            manager
                .settings_catalog(&binding(), 20)
                .await
                .expect("cold catalog"),
            DriverSettingsCatalog::default()
        );
        assert!(
            driver
                .settings_catalogs
                .lock()
                .expect("settings catalogs")
                .is_empty()
        );

        assert_eq!(
            manager
                .ensure_session(&binding(), 21)
                .await
                .expect("resume"),
            SessionOpenOutcome::Resumed(session)
        );
        manager
            .settings_catalog(&binding(), 22)
            .await
            .expect("active catalog");
        assert_eq!(
            driver
                .settings_catalogs
                .lock()
                .expect("settings catalogs")
                .len(),
            1
        );
        assert_eq!(driver.resumes.lock().expect("resumes").len(), 1);
        assert!(driver.starts.lock().expect("starts").is_empty());
    }

    #[tokio::test]
    async fn nonresumable_driver_can_prewarm_before_replacing_a_durable_binding() {
        let provider = ProviderId::new("claude").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        store
            .put_binding(
                &binding(),
                &provider,
                &ProviderSessionId::new("session-old").expect("session"),
                10,
            )
            .expect("binding");
        let driver = Arc::new(FakeDriver {
            capabilities: DriverCapabilities {
                settings_catalog: true,
                settings_catalog_starts_session: true,
                ..DriverCapabilities::default()
            },
            ..FakeDriver::default()
        });
        let manager = ProviderSessionManager::new(driver.clone(), store, provider);

        manager
            .settings_catalog(&binding(), 20)
            .await
            .expect("catalog");
        assert_eq!(
            driver
                .settings_catalogs
                .lock()
                .expect("settings catalogs")
                .len(),
            1
        );
        assert!(matches!(
            manager.ensure_session(&binding(), 21).await.expect("session"),
            SessionOpenOutcome::Replaced(session) if session.as_str() == "session-new"
        ));
        assert!(driver.resumes.lock().expect("resumes").is_empty());
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
    }

    #[tokio::test]
    async fn replaces_an_authoritatively_invalid_durable_session_without_replay() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let old_session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding(&binding(), &provider, &old_session, 10)
            .expect("binding");
        let driver = Arc::new(FakeDriver::default());
        *driver.resume_error.lock().expect("resume error") = Some(DriverError::InvalidSession(
            "thread was deleted".to_string(),
        ));
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider.clone());

        let replacement = manager
            .ensure_session(&binding(), 20)
            .await
            .expect("replacement");

        assert!(matches!(
            &replacement,
            SessionOpenOutcome::Replaced(session_id) if session_id.as_str() == "session-new"
        ));
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
        let resumes = driver.resumes.lock().expect("resumes");
        assert_eq!(resumes.len(), 1);
        assert_eq!(resumes[0].session_id, old_session);
        assert_eq!(resumes[0].replay, SessionReplay::None);
        assert_eq!(
            store.get_binding(&binding()).expect("binding"),
            Some((provider, replacement.into_session_id()))
        );
    }

    #[tokio::test]
    async fn preserves_a_durable_binding_after_transient_or_generic_resume_failure() {
        for error in [
            DriverError::Transient("request timed out".to_string()),
            DriverError::Unavailable("app server restarting".to_string()),
            DriverError::Rejected("bad request".to_string()),
        ] {
            let provider = ProviderId::new("codex").expect("provider");
            let (_workspace, store, _cwd) = registered_store(&provider);
            let old_session = ProviderSessionId::new("session-old").expect("session");
            store
                .put_binding(&binding(), &provider, &old_session, 10)
                .expect("binding");
            let driver = Arc::new(FakeDriver::default());
            *driver.resume_error.lock().expect("resume error") = Some(error.clone());
            let manager =
                ProviderSessionManager::new(driver.clone(), store.clone(), provider.clone());

            assert!(matches!(
                manager
                    .ensure_session(&binding(), 20)
                    .await,
                Err(SessionManagerError::Driver(found)) if found == error
            ));
            assert!(driver.starts.lock().expect("starts").is_empty());
            assert_eq!(
                store.get_binding(&binding()).expect("binding"),
                Some((provider, old_session))
            );
        }
    }

    #[tokio::test]
    async fn replaces_a_saved_binding_when_the_driver_cannot_resume_sessions() {
        let provider = ProviderId::new("opencode").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let old_session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding(&binding(), &provider, &old_session, 10)
            .expect("binding");
        let driver = Arc::new(FakeDriver {
            capabilities: DriverCapabilities::default(),
            ..FakeDriver::default()
        });
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider.clone());

        let replacement = manager
            .ensure_session(&binding(), 20)
            .await
            .expect("replacement");

        assert!(matches!(
            &replacement,
            SessionOpenOutcome::Replaced(session_id) if session_id.as_str() == "session-new"
        ));
        assert!(driver.resumes.lock().expect("resumes").is_empty());
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
        assert_eq!(
            store.get_binding(&binding()).expect("binding"),
            Some((provider, replacement.into_session_id()))
        );
    }

    #[tokio::test]
    async fn simultaneous_invalid_session_recovery_creates_one_replacement() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let old_session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding(&binding(), &provider, &old_session, 10)
            .expect("binding");
        let driver = Arc::new(FakeDriver {
            yield_on_resume: true,
            ..FakeDriver::default()
        });
        *driver.resume_error.lock().expect("resume error") = Some(DriverError::InvalidSession(
            "thread was deleted".to_string(),
        ));
        let manager = Arc::new(ProviderSessionManager::new(driver.clone(), store, provider));
        let first = {
            let manager = manager.clone();
            tokio::spawn(async move { manager.ensure_session(&binding(), 20).await })
        };
        let second = {
            let manager = manager.clone();
            tokio::spawn(async move { manager.ensure_session(&binding(), 20).await })
        };
        let (first, second) = tokio::join!(first, second);

        let outcomes = [
            first.expect("first task").expect("first session"),
            second.expect("second task").expect("second session"),
        ];
        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| outcome.was_replaced())
                .count(),
            1
        );
        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| matches!(outcome, SessionOpenOutcome::Active(_)))
                .count(),
            1
        );
        assert_eq!(outcomes[0].session_id(), outcomes[1].session_id());
        assert_eq!(driver.resumes.lock().expect("resumes").len(), 1);
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);
    }

    #[tokio::test]
    async fn different_bindings_do_not_hold_a_global_lock_during_provider_io() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_first_workspace, store, _first_cwd) = registered_store(&provider);
        let first_binding = binding();
        let mut second_binding = binding();
        second_binding.chat_id = 8;
        second_binding.workspace_id = WorkspaceId::new("workspace-2").expect("workspace");
        let second_workspace = tempfile::tempdir().expect("second workspace");
        let second_cwd =
            std::fs::canonicalize(second_workspace.path()).expect("canonical second workspace");
        store
            .select_workspace(
                &second_binding.installation_id,
                &second_binding.workspace_id,
                &second_cwd,
                2,
            )
            .expect("registered second workspace");
        let old_session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding(&first_binding, &provider, &old_session, 10)
            .expect("first binding");
        store
            .put_binding(&second_binding, &provider, &old_session, 10)
            .expect("second binding");
        let gate = Arc::new(tokio::sync::Barrier::new(2));
        let driver = Arc::new(FakeDriver {
            resume_gate: Some(gate),
            ..FakeDriver::default()
        });
        let manager = Arc::new(ProviderSessionManager::new(driver, store, provider));

        let first = {
            let manager = manager.clone();
            tokio::spawn(async move { manager.ensure_session(&first_binding, 20).await })
        };
        let second = {
            let manager = manager.clone();
            tokio::spawn(async move { manager.ensure_session(&second_binding, 20).await })
        };

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            first.await.expect("first task").expect("first session");
            second.await.expect("second task").expect("second session");
        })
        .await
        .expect("independent session initialization should overlap");
    }

    #[tokio::test]
    async fn start_turn_sets_the_workspace_cwd() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, cwd) = registered_store(&provider);
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store, provider);
        let direction_id = DirectionId::new("event-1").expect("direction");

        let (session, _) = manager
            .start_turn(
                &binding(),
                10,
                TurnInput {
                    text: "fix tests".to_string(),
                    attachments: Vec::new(),
                    client_message_id: Some(direction_id.to_string()),
                },
                TurnOptions::default(),
            )
            .await
            .expect("turn");

        assert!(matches!(session, SessionOpenOutcome::Created(_)));
        let turns = driver.turns.lock().expect("turns");
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].2.cwd.as_ref(), Some(&cwd));
    }
}

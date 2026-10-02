use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use thiserror::Error;
use tokio::sync::{Mutex, OwnedMutexGuard, OwnedRwLockReadGuard, RwLock};

use crate::{
    AgentDriver, BindingKey, BridgeStore, DriverError, ProviderId, ProviderSessionId,
    ResumeSessionSpec, SessionReplay, SessionSpec, SessionThreadBindOutcome, SessionThreadBinding,
    SessionThreadOpening, SessionThreadPrepareOutcome, StartedTurn, StoreError, TurnId, TurnInput,
    TurnOptions,
};

struct ActiveSession {
    session_id: ProviderSessionId,
    history_ready: bool,
}

type SessionSlot = Arc<Mutex<Option<ActiveSession>>>;
type ThreadTransitionKey = (crate::InstallationId, i64);
type ThreadTransitionSlot = Arc<Mutex<()>>;
type ProviderSessionClaimSlot = Arc<Mutex<()>>;

struct SessionThreadClaimGuard {
    _guard: OwnedMutexGuard<()>,
}

/// Keeps the provider epoch globally non-idle for the lifetime of one turn.
/// This is process-local coordination for epoch-wide actions such as `/close`;
/// the provider remains the authoritative owner of its session writer.
pub struct ProviderWorkLease {
    _guard: OwnedRwLockReadGuard<()>,
}

impl std::fmt::Debug for ProviderWorkLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ProviderWorkLease(<active>)")
    }
}

impl std::fmt::Debug for SessionThreadClaimGuard {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SessionThreadClaimGuard(<locked>)")
    }
}

/// Holds the provider-session claim across Inline's create-or-return reply
/// thread request and the atomic local completion. Dropping it is safe: the
/// durable opening retains the original anchor for the next bridge process.
pub struct PreparedSessionThread {
    _claim: SessionThreadClaimGuard,
    outcome: SessionThreadPrepareOutcome,
}

impl PreparedSessionThread {
    pub fn binding(&self) -> Option<&SessionThreadBinding> {
        self.outcome.binding()
    }

    pub fn opening(&self) -> Option<&SessionThreadOpening> {
        self.outcome.opening()
    }
}

impl std::fmt::Debug for PreparedSessionThread {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PreparedSessionThread")
            .field(
                "state",
                &if self.binding().is_some() {
                    "bound"
                } else {
                    "opening"
                },
            )
            .finish()
    }
}

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
    slots: Arc<Mutex<HashMap<BindingKey, SessionSlot>>>,
    transition_slots: Arc<Mutex<HashMap<ThreadTransitionKey, ThreadTransitionSlot>>>,
    session_claim_slots: Arc<Mutex<HashMap<crate::ProviderSessionRef, ProviderSessionClaimSlot>>>,
    epoch_gate: Arc<RwLock<()>>,
    epoch_ended: Arc<AtomicBool>,
}

impl<D> Clone for ProviderSessionManager<D> {
    fn clone(&self) -> Self {
        Self {
            driver: self.driver.clone(),
            store: self.store.clone(),
            provider_id: self.provider_id.clone(),
            session_configuration_fingerprint: self.session_configuration_fingerprint.clone(),
            slots: self.slots.clone(),
            transition_slots: self.transition_slots.clone(),
            session_claim_slots: self.session_claim_slots.clone(),
            epoch_gate: self.epoch_gate.clone(),
            epoch_ended: self.epoch_ended.clone(),
        }
    }
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
            slots: Arc::new(Mutex::new(HashMap::new())),
            transition_slots: Arc::new(Mutex::new(HashMap::new())),
            session_claim_slots: Arc::new(Mutex::new(HashMap::new())),
            epoch_gate: Arc::new(RwLock::new(())),
            epoch_ended: Arc::new(AtomicBool::new(false)),
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
        let stored = self.store.get_binding_with_configuration_state(binding)?;
        if let Some(current) = active.as_ref().filter(|current| {
            stored
                .as_ref()
                .is_some_and(|(provider, session, _, invalidated)| {
                    provider == &self.provider_id && !invalidated && session == &current.session_id
                })
        }) {
            let session_id = &current.session_id;
            log::trace!(
                target: "inline_agent_bridge::session",
                "phase=session_active provider_id={:?} chat_id={} session_id={:?}",
                self.provider_id.as_str(),
                binding.chat_id,
                session_id.as_str()
            );
            return Ok(SessionOpenOutcome::Active(session_id.clone()));
        }

        *active = None;
        let outcome = match stored {
            Some((stored_provider, session_id, stored_fingerprint, invalidated)) => {
                if stored_provider != self.provider_id {
                    return Err(SessionManagerError::ProviderMismatch {
                        expected: self.provider_id.clone(),
                        found: stored_provider,
                    });
                }
                let configuration_changed =
                    stored_fingerprint != self.session_configuration_fingerprint;
                let session_thread_pinned = self
                    .store
                    .session_thread_binding_for_chat(&binding.installation_id, binding.chat_id)?
                    .is_some();
                if invalidated
                    || (configuration_changed && !session_thread_pinned)
                    || !self.driver.capabilities().resume_session
                {
                    log::trace!(
                        target: "inline_agent_bridge::session",
                        "phase=session_rotate provider_id={:?} chat_id={} reason={} stored_configuration={} required_configuration={}",
                        self.provider_id.as_str(),
                        binding.chat_id,
                        if configuration_changed {
                            "configuration_changed"
                        } else {
                            "resume_unsupported"
                        },
                        stored_fingerprint.is_some(),
                        self.session_configuration_fingerprint.is_some()
                    );
                    SessionOpenOutcome::Replaced(self.replace_session(binding, now, false).await?)
                } else {
                    if configuration_changed {
                        log::trace!(
                            target: "inline_agent_bridge::session",
                            "phase=session_configuration_preserved provider_id={:?} chat_id={} reason=session_thread_pinned",
                            self.provider_id.as_str(),
                            binding.chat_id,
                        );
                    }
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
                        Err(DriverError::InvalidSession(_)) => SessionOpenOutcome::Replaced(
                            self.replace_session(binding, now, false).await?,
                        ),
                        Err(error) => {
                            self.seal_epoch_if_needed(&error);
                            return Err(error.into());
                        }
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
                SessionOpenOutcome::Created(self.replace_session(binding, now, false).await?)
            }
        };
        *active = Some(ActiveSession {
            session_id: outcome.session_id().clone(),
            history_ready: false,
        });
        Ok(outcome)
    }

    async fn session_slot(&self, binding: &BindingKey) -> SessionSlot {
        let mut slots = self.slots.lock().await;
        slots
            .entry(binding.clone())
            .or_insert_with(|| Arc::new(Mutex::new(None)))
            .clone()
    }

    /// Whether this provider epoch has actually resumed or created the
    /// binding's session. A durable binding alone can be read-only history and
    /// must not be presented as current writer ownership.
    pub async fn session_is_active(&self, binding: &BindingKey) -> bool {
        let slot = self.session_slot(binding).await;
        slot.lock().await.is_some()
    }

    /// Writer ownership alone does not mean the client finished importing
    /// history. Linked-session prompts require both in the current epoch.
    pub async fn session_history_is_ready(&self, binding: &BindingKey) -> bool {
        let slot = self.session_slot(binding).await;
        slot.lock()
            .await
            .as_ref()
            .is_some_and(|active| active.history_ready)
            && !self.epoch_ended.load(Ordering::Acquire)
    }

    /// Acknowledges or invalidates history only for the active exact session.
    /// Call with false before a refresh, then true only after sync succeeds.
    pub async fn set_session_history_ready(
        &self,
        binding: &BindingKey,
        session_id: &ProviderSessionId,
        ready: bool,
    ) -> bool {
        let slot = self.session_slot(binding).await;
        let mut slot = slot.lock().await;
        let Some(active) = slot.as_mut() else {
            return false;
        };
        if &active.session_id != session_id || self.epoch_ended.load(Ordering::Acquire) {
            return false;
        }
        active.history_ready = ready;
        true
    }

    async fn transition_slot(
        &self,
        installation_id: &crate::InstallationId,
        chat_id: i64,
    ) -> ThreadTransitionSlot {
        let mut slots = self.transition_slots.lock().await;
        slots
            .entry((installation_id.clone(), chat_id))
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    /// Serializes the check/create/bind sequence for one provider session so
    /// two picker cards cannot create different Inline reply threads before
    /// either one commits the durable reverse owner.
    async fn claim_session_thread(
        &self,
        session: &crate::ProviderSessionRef,
    ) -> Result<SessionThreadClaimGuard, SessionManagerError> {
        let found_provider = session.provider().provider_id();
        if found_provider != &self.provider_id {
            return Err(SessionManagerError::ProviderMismatch {
                expected: self.provider_id.clone(),
                found: found_provider.clone(),
            });
        }
        let slot = {
            let mut slots = self.session_claim_slots.lock().await;
            slots
                .entry(session.clone())
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone()
        };
        Ok(SessionThreadClaimGuard {
            _guard: slot.lock_owned().await,
        })
    }

    /// Durably records the reply-thread anchor before any remote create call
    /// and retains the per-provider-session claim until completion.
    pub async fn prepare_session_thread(
        &self,
        proposed: &SessionThreadOpening,
        now: i64,
    ) -> Result<PreparedSessionThread, SessionManagerError> {
        let claim = self.claim_session_thread(proposed.session()).await?;
        let outcome = self.store.prepare_session_thread_opening(proposed, now)?;
        Ok(PreparedSessionThread {
            _claim: claim,
            outcome,
        })
    }

    /// Completes the durable opening only after Inline returns the stable
    /// reply-thread chat ID. The opening and both binding directions commit in
    /// one local transaction.
    pub async fn complete_prepared_session_thread(
        &self,
        prepared: PreparedSessionThread,
        thread_chat_id: i64,
        now: i64,
    ) -> Result<SessionThreadBindOutcome, SessionManagerError> {
        let Some(opening) = prepared.opening() else {
            let binding = prepared
                .binding()
                .expect("prepared session thread has one state")
                .clone();
            return Ok(SessionThreadBindOutcome::Existing(binding));
        };
        let found_provider = opening.session().provider().provider_id();
        if found_provider != &self.provider_id {
            return Err(SessionManagerError::ProviderMismatch {
                expected: self.provider_id.clone(),
                found: found_provider.clone(),
            });
        }
        let transition = self
            .transition_slot(
                opening.session().provider().installation_id(),
                thread_chat_id,
            )
            .await;
        let _transition = transition.lock().await;
        Ok(self.store.complete_session_thread_opening(
            opening,
            thread_chat_id,
            self.session_configuration_fingerprint.as_deref(),
            now,
        )?)
    }

    /// Binds an already-created Inline reply thread. Runtime browser flows use
    /// `prepare_session_thread` instead so remote creation is crash-recoverable.
    /// This path still
    /// serialize against provider session creation and rotation for the same
    /// Inline thread, including across workspace-scoped forward bindings.
    pub async fn bind_session_thread(
        &self,
        proposed: &SessionThreadBinding,
        now: i64,
    ) -> Result<SessionThreadBindOutcome, SessionManagerError> {
        let found_provider = proposed.session().provider().provider_id();
        if found_provider != &self.provider_id {
            return Err(SessionManagerError::ProviderMismatch {
                expected: self.provider_id.clone(),
                found: found_provider.clone(),
            });
        }
        let transition = self
            .transition_slot(
                proposed.session().provider().installation_id(),
                proposed.thread_chat_id(),
            )
            .await;
        let _transition = transition.lock().await;
        Ok(self.store.bind_session_thread(
            proposed,
            self.session_configuration_fingerprint.as_deref(),
            now,
        )?)
    }

    /// Starts a fresh provider session and persists it only after the provider
    /// accepted creation. This deliberately does not replay Inline or provider
    /// history into the new session.
    async fn replace_session(
        &self,
        binding: &BindingKey,
        now: i64,
        reset_context: bool,
    ) -> Result<ProviderSessionId, SessionManagerError> {
        let transition = self
            .transition_slot(&binding.installation_id, binding.chat_id)
            .await;
        let _transition = transition.lock().await;
        if reset_context && self.store.chat_has_submitted_input(binding)? {
            return Err(DriverError::SessionBusy(
                "a provider input is still running in this conversation; stop it before resetting"
                    .to_string(),
            )
            .into());
        }
        if self
            .store
            .session_thread_binding_for_chat(&binding.installation_id, binding.chat_id)?
            .is_some()
        {
            return Err(SessionManagerError::SessionThreadPinned {
                chat_id: binding.chat_id,
            });
        }
        let cwd = self.workspace_path(binding, now)?;
        let session_id = match self.driver.start_session(SessionSpec { cwd }).await {
            Ok(session_id) => session_id,
            Err(error) => {
                self.seal_epoch_if_needed(&error);
                return Err(error.into());
            }
        };
        self.store.put_binding_with_configuration_and_reset(
            binding,
            &self.provider_id,
            &session_id,
            self.session_configuration_fingerprint.as_deref(),
            now,
            reset_context,
        )?;
        Ok(session_id)
    }

    pub async fn start_turn(
        &self,
        binding: &BindingKey,
        now: i64,
        input: TurnInput,
        mut options: TurnOptions,
    ) -> Result<(SessionOpenOutcome, StartedTurn, ProviderWorkLease), SessionManagerError> {
        let lease = self.begin_provider_work().await?;
        let session = self.ensure_session(binding, now).await?;
        let cwd = self.workspace_path(binding, now)?;
        options.cwd.get_or_insert(cwd);
        let turn = match self
            .driver
            .start_turn(session.session_id(), input, options)
            .await
        {
            Ok(turn) => turn,
            Err(error) => {
                self.seal_epoch_if_needed(&error);
                return Err(error.into());
            }
        };
        Ok((session, turn, lease))
    }

    /// Submit only the immutable input admitted in the existing inbox. The
    /// provider acknowledgement is persisted before callers render progress.
    pub async fn start_admitted_turn(
        &self,
        event_id: &str,
        binding: &BindingKey,
        now: i64,
        mut options: TurnOptions,
    ) -> Result<(SessionOpenOutcome, StartedTurn, ProviderWorkLease), SessionManagerError> {
        let lease = self.begin_provider_work().await?;
        let session = self.ensure_session(binding, now).await?;
        options
            .cwd
            .get_or_insert(self.workspace_path(binding, now)?);
        let transition = self
            .transition_slot(&binding.installation_id, binding.chat_id)
            .await;
        let _transition = transition.lock().await;
        let snapshot = self
            .store
            .begin_context_input(event_id, binding, session.session_id())?;
        let turn = match self
            .driver
            .start_turn(session.session_id(), snapshot.input, options)
            .await
        {
            Ok(turn) => turn,
            Err(error) => {
                self.seal_epoch_if_needed(&error);
                self.store.reject_context_input(event_id, &error)?;
                return Err(error.into());
            }
        };
        self.record_input_acceptance(event_id, session.session_id(), &turn.turn_id)
            .await?;
        Ok((session, turn, lease))
    }

    async fn record_input_acceptance(
        &self,
        event_id: &str,
        session_id: &ProviderSessionId,
        turn_id: &TurnId,
    ) -> Result<(), SessionManagerError> {
        if matches!(self.store.accept_context_input(event_id, turn_id), Ok(true)) {
            return Ok(());
        }
        // Retain the live handle and work lease through the stop attempt.
        // Submitting remains an honest unknown receipt even if SQLite fails.
        self.epoch_ended.store(true, Ordering::Release);
        if self.driver.cancel_turn(session_id, turn_id).await.is_err() {
            let _ = self.driver.shutdown().await;
        }
        Err(DriverError::EpochEnded("provider accepted input but its durable acknowledgement was lost; cancellation was attempted and this connection cannot be reused".to_string()).into())
    }

    pub async fn steer_admitted_turn(
        &self,
        event_id: &str,
        binding: &BindingKey,
        session_id: &ProviderSessionId,
        turn_id: &TurnId,
    ) -> Result<(), SessionManagerError> {
        let _lease = self.begin_provider_work().await?;
        let transition = self
            .transition_slot(&binding.installation_id, binding.chat_id)
            .await;
        let _transition = transition.lock().await;
        let snapshot = self
            .store
            .begin_context_input(event_id, binding, session_id)?;
        if let Err(error) = self
            .driver
            .steer_turn(session_id, turn_id, snapshot.input)
            .await
        {
            self.seal_epoch_if_needed(&error);
            self.store.reject_context_input(event_id, &error)?;
            return Err(error.into());
        }
        self.record_input_acceptance(event_id, session_id, turn_id)
            .await
    }

    fn seal_epoch_if_needed(&self, error: &DriverError) {
        if error.ends_epoch() {
            self.epoch_ended.store(true, Ordering::Release);
        }
    }

    /// Runs compaction with the same epoch lease and event ownership as a turn.
    pub async fn compact_session(
        &self,
        binding: &BindingKey,
        now: i64,
    ) -> Result<(SessionOpenOutcome, StartedTurn, ProviderWorkLease), SessionManagerError> {
        let lease = self.begin_provider_work().await?;
        let session = self.ensure_session(binding, now).await?;
        let turn = match self.driver.compact_session(session.session_id()).await {
            Ok(turn) => turn,
            Err(error) => {
                self.seal_epoch_if_needed(&error);
                return Err(error.into());
            }
        };
        Ok((session, turn, lease))
    }

    /// Marks one Inline lane as provider work before it begins preparation,
    /// settings, session mutation, or turn execution. `/close` skips its own
    /// lease and can therefore acquire the epoch-wide write side only when no
    /// other lane is in flight.
    pub async fn begin_provider_work(&self) -> Result<ProviderWorkLease, SessionManagerError> {
        let lease = ProviderWorkLease {
            _guard: self.epoch_gate.clone().read_owned().await,
        };
        if self.epoch_ended.load(Ordering::Acquire) {
            return Err(
                DriverError::EpochEnded("provider connection epoch has ended".to_string()).into(),
            );
        }
        Ok(lease)
    }

    /// Attempts to reserve provider work without waiting for an epoch-wide
    /// action such as `/close`. Supervisors use this before claiming durable
    /// inbox work so a pending shutdown can keep making progress.
    pub fn try_begin_provider_work(
        &self,
    ) -> Result<Option<ProviderWorkLease>, SessionManagerError> {
        let Ok(guard) = self.epoch_gate.clone().try_read_owned() else {
            return Ok(None);
        };
        if self.epoch_ended.load(Ordering::Acquire) {
            return Err(
                DriverError::EpochEnded("provider connection epoch has ended".to_string()).into(),
            );
        }
        Ok(Some(ProviderWorkLease { _guard: guard }))
    }

    /// Prevents newly detached control work from entering a provider
    /// generation that the supervisor is replacing. Existing work is
    /// cancelled and quiesced by the runtime before the new generation starts.
    pub fn seal_provider_epoch(&self) {
        self.epoch_ended.store(true, Ordering::Release);
    }

    /// Ends the whole private provider epoch only when no turn is active in
    /// any Inline conversation. Once accepted, this manager stays sealed so a
    /// queued lane cannot race onto the driver after shutdown.
    pub async fn shutdown_epoch_if_idle(&self) -> Result<bool, SessionManagerError> {
        let Ok(_exclusive) = self.epoch_gate.clone().try_write_owned() else {
            return Ok(false);
        };
        self.epoch_ended.store(true, Ordering::Release);
        self.driver.shutdown().await?;
        Ok(true)
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
        let session_id = self.replace_session(binding, now, true).await?;
        *active = Some(ActiveSession {
            session_id: session_id.clone(),
            history_ready: false,
        });
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
    #[error("provider session reply thread {chat_id} cannot rotate to a different session")]
    SessionThreadPinned { chat_id: i64 },
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex as StdMutex;

    use super::*;
    use crate::{
        AgentEventReceiver, ApprovalDecision, DirectionId, DriverCapabilities, DriverFuture,
        DriverSettingsCatalog, InstallationId, ProviderInstanceRef, ProviderSessionRef,
        SessionThreadBinding, SteeringSupport, TurnId, WorkspaceId,
    };

    #[derive(Debug)]
    struct FakeDriver {
        capabilities: DriverCapabilities,
        starts: StdMutex<Vec<PathBuf>>,
        settings_catalogs: StdMutex<Vec<PathBuf>>,
        resumes: StdMutex<Vec<ResumeSessionSpec>>,
        resume_error: StdMutex<Option<DriverError>>,
        start_gate: Option<Arc<tokio::sync::Barrier>>,
        yield_on_resume: bool,
        resume_gate: Option<Arc<tokio::sync::Barrier>>,
        turns: StdMutex<Vec<(ProviderSessionId, TurnInput, TurnOptions)>>,
        cancellations: StdMutex<Vec<(ProviderSessionId, TurnId)>>,
        cancel_error: bool,
        cancel_gate: Option<Arc<tokio::sync::Barrier>>,
        shutdowns: StdMutex<usize>,
        shutdown_gate: Option<Arc<tokio::sync::Barrier>>,
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
                start_gate: None,
                yield_on_resume: false,
                resume_gate: None,
                turns: StdMutex::default(),
                cancellations: StdMutex::default(),
                cancel_error: false,
                cancel_gate: None,
                shutdowns: StdMutex::default(),
                shutdown_gate: None,
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
                if let Some(gate) = self.start_gate.as_ref() {
                    gate.wait().await;
                }
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
            session_id: &'a ProviderSessionId,
            turn_id: &'a TurnId,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async move {
                self.cancellations
                    .lock()
                    .unwrap()
                    .push((session_id.clone(), turn_id.clone()));
                if let Some(gate) = self.cancel_gate.as_ref() {
                    gate.wait().await;
                    gate.wait().await;
                }
                if self.cancel_error {
                    Err(DriverError::Transient(
                        "cancel acknowledgement lost".to_string(),
                    ))
                } else {
                    Ok(())
                }
            })
        }

        fn compact_session<'a>(
            &'a self,
            _session_id: &'a ProviderSessionId,
        ) -> DriverFuture<'a, StartedTurn> {
            self.start_turn(
                _session_id,
                TurnInput {
                    text: String::new(),
                    attachments: Vec::new(),
                    client_message_id: None,
                },
                TurnOptions::default(),
            )
        }

        fn resolve_approval<'a>(
            &'a self,
            _approval_id: &'a str,
            _decision: ApprovalDecision,
        ) -> DriverFuture<'a, ()> {
            Box::pin(async { Ok(()) })
        }

        fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()> {
            Box::pin(async move {
                *self.shutdowns.lock().expect("shutdowns") += 1;
                if let Some(gate) = self.shutdown_gate.as_ref() {
                    gate.wait().await;
                }
                Ok(())
            })
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
    async fn admitted_turn_sends_frozen_public_input_and_records_acceptance_before_completion() {
        let provider = ProviderId::new("codex").unwrap();
        let (_workspace, store, _cwd) = registered_store(&provider);
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider);
        let session = manager.ensure_session(&binding(), 10).await.unwrap();
        let record = crate::InboundRecord {
            event_id: "public-input".to_string(),
            binding: binding(),
            message_id: 1,
            delivery_chat_id: 7,
            sender_user_id: 7,
            direction: crate::Direction::new(
                DirectionId::new("public-input").unwrap(),
                "Current direction",
            )
            .with_source_version(Some(crate::SourceMessageVersion {
                revision: 0,
                source_snapshot: None,
                visible_fingerprint: Some("a".repeat(64)),
                discretionary: false,
                text: "Current direction".into(),
            })),
            state: crate::InboundState::Accepted,
            accepted_at: 10,
            started_at: None,
            lease_expires_at: None,
            attempt_count: 0,
            provider_turn_id: None,
            stream_message_id: None,
            failure: None,
        };
        store.accept_inbound(&record).unwrap();
        store.start_inbound(&record.event_id, 11).unwrap();
        let input = TurnInput {
            text: "Public excerpt\nCurrent direction".to_string(),
            attachments: vec![],
            client_message_id: Some("public-input".to_string()),
        };
        store
            .prepare_context_input(
                &record.event_id,
                &crate::ContextInputSnapshot {
                    binding: binding(),
                    provider_session_id: session.session_id().clone(),
                    generation: store.context_receipt(&binding()).unwrap().generation,
                    input: input.clone(),
                    messages: vec![crate::ContextMessageRef {
                        chat_id: 7,
                        message_id: 1,
                        revision: 0,
                        source_snapshot: None,
                        visible_fingerprint: Some("a".repeat(64)),
                    }],
                    trigger: Some(crate::ContextTriggerProof {
                        chat_id: 7,
                        message_id: 1,
                        timestamp: 10,
                    }),
                },
            )
            .unwrap();
        let (_, turn, _lease) = manager
            .start_admitted_turn(&record.event_id, &binding(), 12, TurnOptions::default())
            .await
            .unwrap();
        assert_eq!(driver.turns.lock().unwrap()[0].1, input);
        assert_eq!(
            store.context_input(&record.event_id).unwrap().unwrap().1,
            crate::ContextInputState::Accepted
        );
        assert_eq!(
            store
                .get_inbound(&record.event_id)
                .unwrap()
                .unwrap()
                .provider_turn_id,
            Some(turn.turn_id)
        );
        assert_eq!(
            store.get_inbound(&record.event_id).unwrap().unwrap().state,
            crate::InboundState::Started
        );
        assert_eq!(store.context_receipt(&binding()).unwrap().consumed.len(), 1);
        assert!(
            manager
                .start_admitted_turn(&record.event_id, &binding(), 13, TurnOptions::default())
                .await
                .is_err()
        );
        assert_eq!(driver.turns.lock().unwrap().len(), 1);
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

    fn admitted_record(binding: BindingKey, event_id: &str) -> crate::InboundRecord {
        crate::InboundRecord {
            event_id: event_id.to_string(),
            message_id: 1,
            delivery_chat_id: binding.chat_id,
            binding,
            sender_user_id: 7,
            direction: crate::Direction::new(DirectionId::new(event_id).unwrap(), "request")
                .with_source_version(Some(crate::SourceMessageVersion {
                    revision: 0,
                    source_snapshot: None,
                    visible_fingerprint: Some("a".repeat(64)),
                    discretionary: false,
                    text: "request".into(),
                })),
            state: crate::InboundState::Accepted,
            accepted_at: 10,
            started_at: None,
            lease_expires_at: None,
            attempt_count: 0,
            provider_turn_id: None,
            stream_message_id: None,
            failure: None,
        }
    }

    fn admit(
        store: &BridgeStore,
        record: &crate::InboundRecord,
        session: &ProviderSessionId,
    ) -> crate::ContextInputSnapshot {
        store.accept_inbound(record).unwrap();
        store.start_inbound(&record.event_id, 11).unwrap();
        let snapshot = crate::ContextInputSnapshot {
            binding: record.binding.clone(),
            provider_session_id: session.clone(),
            generation: store.context_receipt(&record.binding).unwrap().generation,
            input: TurnInput {
                text: record.direction.text.clone(),
                attachments: vec![],
                client_message_id: Some(record.event_id.clone()),
            },
            messages: vec![crate::ContextMessageRef {
                chat_id: record.binding.chat_id,
                message_id: record.message_id,
                revision: 0,
                source_snapshot: None,
                visible_fingerprint: Some("a".repeat(64)),
            }],
            trigger: Some(crate::ContextTriggerProof {
                chat_id: record.binding.chat_id,
                message_id: record.message_id,
                timestamp: 10,
            }),
        };
        store
            .prepare_context_input(&record.event_id, &snapshot)
            .unwrap();
        snapshot
    }

    #[tokio::test]
    async fn receipt_sql_error_after_provider_acceptance_cancels_before_releasing_epoch_lease() {
        for steering in [false, true] {
            let workspace = tempfile::tempdir().unwrap();
            let database = workspace.path().join("receipt.sqlite");
            let store = Arc::new(BridgeStore::open(&database).unwrap());
            store
                .put_installation(&crate::InstallationRecord {
                    installation_id: binding().installation_id,
                    provider_id: ProviderId::new("codex").unwrap(),
                    display_name: "Agent".to_string(),
                    created_at: 1,
                    updated_at: 1,
                })
                .unwrap();
            store
                .select_workspace(
                    &binding().installation_id,
                    &binding().workspace_id,
                    workspace.path(),
                    1,
                )
                .unwrap();
            let gate = Arc::new(tokio::sync::Barrier::new(2));
            let driver = Arc::new(FakeDriver {
                cancel_gate: Some(gate.clone()),
                cancel_error: steering,
                ..FakeDriver::default()
            });
            let manager = Arc::new(ProviderSessionManager::new(
                driver.clone(),
                store.clone(),
                ProviderId::new("codex").unwrap(),
            ));
            let session = manager
                .ensure_session(&binding(), 10)
                .await
                .unwrap()
                .into_session_id();
            let record = admitted_record(binding(), "lost-receipt");
            admit(&store, &record, &session);
            rusqlite::Connection::open(&database).unwrap().execute_batch(
                "CREATE TRIGGER fail_receipt BEFORE UPDATE OF context_input_state ON inbound_directions
                 WHEN NEW.context_input_state = 'accepted' BEGIN SELECT RAISE(FAIL, 'synthetic receipt failure'); END;"
            ).unwrap();
            let worker = manager.clone();
            let task = tokio::spawn(async move {
                if steering {
                    worker
                        .steer_admitted_turn(
                            "lost-receipt",
                            &binding(),
                            &session,
                            &TurnId::new("turn-1").unwrap(),
                        )
                        .await
                } else {
                    worker
                        .start_admitted_turn("lost-receipt", &binding(), 12, TurnOptions::default())
                        .await
                        .map(|_| ())
                }
            });
            gate.wait().await;
            assert!(
                !manager.shutdown_epoch_if_idle().await.unwrap(),
                "live accepted handle must retain the epoch lease while cancelling"
            );
            assert_eq!(
                store.context_input("lost-receipt").unwrap().unwrap().1,
                crate::ContextInputState::Submitting
            );
            gate.wait().await;
            assert!(matches!(
                task.await.unwrap(),
                Err(SessionManagerError::Driver(DriverError::EpochEnded(_)))
            ));
            assert_eq!(driver.cancellations.lock().unwrap().len(), 1);
            assert_eq!(*driver.shutdowns.lock().unwrap(), usize::from(steering));
            assert!(manager.begin_provider_work().await.is_err());
            assert_eq!(store.recover_expired_inbound(1000).unwrap(), 0);
            assert!(!store.defer_inbound("lost-receipt").unwrap());
            assert!(
                store
                    .context_receipt(&binding())
                    .unwrap()
                    .consumed
                    .is_empty()
            );
        }
    }

    #[tokio::test]
    async fn reset_invalidates_preexisting_alternate_workspace_and_cached_provider_history() {
        let provider = ProviderId::new("codex").unwrap();
        let (_first_workspace, store, _cwd) = registered_store(&provider);
        let second_workspace = tempfile::tempdir().unwrap();
        let second = BindingKey {
            workspace_id: WorkspaceId::new("workspace-b").unwrap(),
            ..binding()
        };
        store
            .select_workspace(
                &second.installation_id,
                &second.workspace_id,
                second_workspace.path(),
                1,
            )
            .unwrap();
        let old_second_session = ProviderSessionId::new("pre-reset-private-history-b").unwrap();
        store
            .put_binding(&second, &provider, &old_second_session, 2)
            .unwrap();
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider);
        manager.ensure_session(&binding(), 10).await.unwrap();
        manager.ensure_session(&second, 10).await.unwrap();
        let record = admitted_record(second.clone(), "queued-b");
        let snapshot = admit(&store, &record, &old_second_session);
        manager.rotate_session(&binding(), 20).await.unwrap();
        assert_eq!(
            store.get_inbound("queued-b").unwrap().unwrap().state,
            crate::InboundState::Failed
        );
        assert!(store.context_receipt(&second).is_err());
        assert!(
            store
                .begin_context_input("queued-b", &second, &old_second_session)
                .is_err()
        );
        let reopened = manager.ensure_session(&second, 21).await.unwrap();
        assert!(matches!(reopened, SessionOpenOutcome::Replaced(_)));
        assert_ne!(reopened.session_id(), &old_second_session);
        assert_eq!(driver.starts.lock().unwrap().len(), 3);
        assert_eq!(
            driver.resumes.lock().unwrap().len(),
            1,
            "alternate cached session must not resume its pre-reset history"
        );
        let receipt = store.context_receipt(&second).unwrap();
        assert_eq!(receipt.reset_at, 20);
        assert!(receipt.generation > snapshot.generation);
        assert!(
            manager
                .start_admitted_turn("queued-b", &second, 22, TurnOptions::default())
                .await
                .is_err()
        );
        assert!(driver.turns.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn history_readiness_requires_exact_sync_and_is_reset_by_rotation_and_restart() {
        let provider = ProviderId::new("codex").unwrap();
        let (_workspace, store, _) = registered_store(&provider);
        store
            .put_binding(
                &binding(),
                &provider,
                &ProviderSessionId::new("session-old").unwrap(),
                1,
            )
            .unwrap();
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider.clone());
        assert!(!manager.session_history_is_ready(&binding()).await);
        let session = manager
            .ensure_session(&binding(), 10)
            .await
            .unwrap()
            .session_id()
            .clone();
        assert!(manager.session_is_active(&binding()).await);
        assert!(!manager.session_history_is_ready(&binding()).await);
        assert!(
            !manager
                .set_session_history_ready(
                    &binding(),
                    &ProviderSessionId::new("wrong").unwrap(),
                    true
                )
                .await
        );
        assert!(
            manager
                .set_session_history_ready(&binding(), &session, true)
                .await
        );
        assert!(manager.session_history_is_ready(&binding()).await);
        assert!(
            manager
                .set_session_history_ready(&binding(), &session, false)
                .await
        );
        assert!(!manager.session_history_is_ready(&binding()).await);
        assert!(
            manager
                .set_session_history_ready(&binding(), &session, true)
                .await
        );
        let restarted = ProviderSessionManager::new(driver, store, provider);
        assert!(!restarted.session_history_is_ready(&binding()).await);
        manager.rotate_session(&binding(), 20).await.unwrap();
        assert!(!manager.session_history_is_ready(&binding()).await);
        assert!(
            !manager
                .set_session_history_ready(&binding(), &session, true)
                .await
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
    async fn session_reply_thread_preserves_identity_across_configuration_updates() {
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
            .expect("forward binding");
        let provider_instance =
            ProviderInstanceRef::new(binding().installation_id, provider.clone())
                .expect("provider instance");
        let provider_session =
            ProviderSessionRef::new(provider_instance, old_session.clone()).expect("session ref");
        let thread_binding = SessionThreadBinding::new(
            provider_session,
            binding().workspace_id,
            7,
            binding().chat_id,
        )
        .expect("session thread");
        store
            .bind_session_thread(&thread_binding, Some("sha256:old"), 11)
            .expect("bind session thread");
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store.clone(), provider.clone())
            .with_session_configuration_fingerprint(Some("sha256:new".to_string()));

        assert!(matches!(
            manager.ensure_session(&binding(), 20).await,
            Ok(SessionOpenOutcome::Resumed(session)) if session == old_session
        ));
        assert!(driver.starts.lock().expect("starts").is_empty());
        assert_eq!(driver.resumes.lock().expect("resumes").len(), 1);
        assert_eq!(
            store.get_binding(&binding()).expect("forward binding"),
            Some((provider, old_session))
        );
        assert_eq!(
            store
                .session_thread_binding(thread_binding.session())
                .expect("reverse binding"),
            Some(thread_binding)
        );
        assert_eq!(
            store
                .get_binding_with_configuration(&binding())
                .expect("configured binding")
                .and_then(|(_, _, fingerprint)| fingerprint),
            Some("sha256:old".to_string())
        );
    }

    #[tokio::test]
    async fn session_thread_claim_serializes_with_provider_session_creation() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let start_gate = Arc::new(tokio::sync::Barrier::new(2));
        let driver = Arc::new(FakeDriver {
            start_gate: Some(start_gate.clone()),
            ..FakeDriver::default()
        });
        let manager = Arc::new(ProviderSessionManager::new(
            driver.clone(),
            store.clone(),
            provider.clone(),
        ));
        let creation = {
            let manager = manager.clone();
            tokio::spawn(async move { manager.ensure_session(&binding(), 20).await })
        };
        for _ in 0..100 {
            if !driver.starts.lock().expect("starts").is_empty() {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert_eq!(driver.starts.lock().expect("starts").len(), 1);

        let selected_session = ProviderSessionRef::new(
            ProviderInstanceRef::new(binding().installation_id, provider.clone())
                .expect("provider instance"),
            ProviderSessionId::new("session-selected").expect("selected session"),
        )
        .expect("session ref");
        let proposed = SessionThreadBinding::new(
            selected_session,
            binding().workspace_id,
            6,
            binding().chat_id,
        )
        .expect("thread binding");
        let claim = {
            let manager = manager.clone();
            let proposed = proposed.clone();
            tokio::spawn(async move { manager.bind_session_thread(&proposed, 21).await })
        };
        tokio::task::yield_now().await;
        start_gate.wait().await;

        let created = creation
            .await
            .expect("creation task")
            .expect("created session");
        assert!(matches!(
            created,
            SessionOpenOutcome::Created(session) if session.as_str() == "session-new"
        ));
        assert!(matches!(
            claim.await.expect("claim task"),
            Err(SessionManagerError::Store(
                StoreError::SessionThreadBindingConflict { thread_chat_id: 7 }
            ))
        ));
        assert_eq!(
            store.get_binding(&binding()).expect("persisted session"),
            Some((
                provider,
                ProviderSessionId::new("session-new").expect("created session"),
            ))
        );
        assert_eq!(
            store
                .session_thread_binding(proposed.session())
                .expect("reverse owner"),
            None
        );
    }

    #[tokio::test]
    async fn provider_session_claims_serialize_without_exposing_session_identity() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let manager = Arc::new(ProviderSessionManager::new(
            Arc::new(FakeDriver::default()),
            store,
            provider.clone(),
        ));
        let session = ProviderSessionRef::new(
            ProviderInstanceRef::new(binding().installation_id, provider)
                .expect("provider instance"),
            ProviderSessionId::new("private-session-id").expect("session"),
        )
        .expect("session ref");
        let first = manager
            .claim_session_thread(&session)
            .await
            .expect("first claim");
        assert!(!format!("{first:?}").contains("private-session-id"));
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let second = {
            let manager = manager.clone();
            let session = session.clone();
            tokio::spawn(async move {
                let _ = started_tx.send(());
                manager.claim_session_thread(&session).await
            })
        };
        started_rx.await.expect("second claim started");
        tokio::task::yield_now().await;
        assert!(!second.is_finished());

        drop(first);
        let second = second.await.expect("second task").expect("second claim");
        assert!(!format!("{second:?}").contains("private-session-id"));
    }

    #[tokio::test]
    async fn prepared_session_thread_holds_the_claim_through_durable_completion() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let manager = Arc::new(ProviderSessionManager::new(
            Arc::new(FakeDriver::default()),
            store,
            provider.clone(),
        ));
        let session = ProviderSessionRef::new(
            ProviderInstanceRef::new(binding().installation_id, provider)
                .expect("provider instance"),
            ProviderSessionId::new("private-session-id").expect("session"),
        )
        .expect("session ref");
        let opening =
            SessionThreadOpening::new(session, binding().workspace_id, 7, 11).expect("opening");
        let prepared = manager
            .prepare_session_thread(&opening, 20)
            .await
            .expect("prepare");
        assert!(!format!("{prepared:?}").contains("private-session-id"));

        let second = {
            let manager = manager.clone();
            let opening = opening.clone();
            tokio::spawn(async move { manager.prepare_session_thread(&opening, 21).await })
        };
        tokio::task::yield_now().await;
        assert!(!second.is_finished());

        let completed = manager
            .complete_prepared_session_thread(prepared, 20, 22)
            .await
            .expect("complete");
        assert!(matches!(completed, SessionThreadBindOutcome::Created(_)));
        let second = second.await.expect("second task").expect("second prepare");
        assert_eq!(
            second.binding().map(SessionThreadBinding::thread_chat_id),
            Some(20)
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
    async fn fatal_resume_failure_seals_the_manager_epoch() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let old_session = ProviderSessionId::new("session-old").expect("session");
        store
            .put_binding(&binding(), &provider, &old_session, 10)
            .expect("binding");
        let driver = Arc::new(FakeDriver::default());
        *driver.resume_error.lock().expect("resume error") = Some(DriverError::EpochEnded(
            "provider shutdown was not confirmed".to_string(),
        ));
        let manager = ProviderSessionManager::new(driver, store.clone(), provider.clone());

        assert!(matches!(
            manager.ensure_session(&binding(), 20).await,
            Err(SessionManagerError::Driver(DriverError::EpochEnded(_)))
        ));
        assert!(matches!(
            manager.try_begin_provider_work(),
            Err(SessionManagerError::Driver(DriverError::EpochEnded(_)))
        ));
        assert_eq!(
            store.get_binding(&binding()).expect("binding"),
            Some((provider, old_session))
        );
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

        let (session, _, _lease) = manager
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

    #[tokio::test]
    async fn epoch_shutdown_waits_for_provider_work_before_turn_start() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let driver = Arc::new(FakeDriver::default());
        let manager = ProviderSessionManager::new(driver.clone(), store, provider);

        let lease = manager.begin_provider_work().await.expect("provider work");

        assert!(!manager.shutdown_epoch_if_idle().await.expect("busy check"));
        assert_eq!(*driver.shutdowns.lock().expect("shutdowns"), 0);

        drop(lease);
        assert!(
            manager
                .shutdown_epoch_if_idle()
                .await
                .expect("idle shutdown")
        );
        assert_eq!(*driver.shutdowns.lock().expect("shutdowns"), 1);
        assert!(matches!(
            manager
                .start_turn(
                    &binding(),
                    11,
                    TurnInput {
                        text: "too late".to_string(),
                        attachments: Vec::new(),
                        client_message_id: None,
                    },
                    TurnOptions::default(),
                )
                .await,
            Err(SessionManagerError::Driver(error)) if error.ends_epoch()
        ));
    }

    #[tokio::test]
    async fn provider_admission_does_not_wait_behind_pending_shutdown() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let shutdown_gate = Arc::new(tokio::sync::Barrier::new(2));
        let driver = Arc::new(FakeDriver {
            shutdown_gate: Some(shutdown_gate.clone()),
            ..FakeDriver::default()
        });
        let manager = Arc::new(ProviderSessionManager::new(driver.clone(), store, provider));
        let task_manager = manager.clone();
        let shutdown = tokio::spawn(async move { task_manager.shutdown_epoch_if_idle().await });

        for _ in 0..100 {
            if *driver.shutdowns.lock().expect("shutdowns") == 1 {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert_eq!(*driver.shutdowns.lock().expect("shutdowns"), 1);
        assert!(
            manager
                .try_begin_provider_work()
                .expect("nonblocking admission")
                .is_none()
        );

        shutdown_gate.wait().await;
        assert!(shutdown.await.expect("shutdown task").expect("shutdown"));
        assert!(matches!(
            manager.try_begin_provider_work(),
            Err(SessionManagerError::Driver(error)) if error.ends_epoch()
        ));
    }

    #[test]
    fn sealing_one_manager_clone_seals_the_whole_provider_generation() {
        let provider = ProviderId::new("codex").expect("provider");
        let (_workspace, store, _cwd) = registered_store(&provider);
        let manager = ProviderSessionManager::new(Arc::new(FakeDriver::default()), store, provider);
        let detached_clone = manager.clone();

        manager.seal_provider_epoch();

        assert!(matches!(
            detached_clone.try_begin_provider_work(),
            Err(SessionManagerError::Driver(error)) if error.ends_epoch()
        ));
    }
}

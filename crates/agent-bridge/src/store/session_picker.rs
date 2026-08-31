//! Durable, restart-safe session browser cards and atomic Open claims.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};

use crate::{
    InstallationId, ProviderId, ProviderInstanceRef, ProviderSessionId, ProviderSessionRef,
    SessionAvailability, SessionSummary, WorkspaceId,
};

use super::{
    BridgeStore, StoreError, StoreResult, parse_installation_id, parse_provider_id,
    parse_workspace_id,
};

pub const MAX_ACTIVE_SESSION_PICKERS: usize = 32;
pub const MAX_SESSION_PICKER_ITEMS: usize = 1_000;
pub const SESSION_PICKER_PAGE_SIZE: usize = 6;
const MAX_CALLBACK_TOKEN_BYTES: usize = 256;
const MAX_EVENT_ID_BYTES: usize = 512;
const MAX_WORKSPACE_LABEL_CHARS: usize = 80;
const MAX_SESSIONS_JSON_BYTES: usize = 1024 * 1024;
const MAX_FAILURE_CHARS: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPickerState {
    Publishing,
    Active,
    Opening,
    Retryable,
    Completed,
    Expired,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPickerThreadGate {
    Ready,
    Opening,
    Failed,
}

impl SessionPickerState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Publishing => "publishing",
            Self::Active => "active",
            Self::Opening => "opening",
            Self::Retryable => "retryable",
            Self::Completed => "completed",
            Self::Expired => "expired",
            Self::Failed => "failed",
        }
    }

    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "publishing" => Ok(Self::Publishing),
            "active" => Ok(Self::Active),
            "opening" => Ok(Self::Opening),
            "retryable" => Ok(Self::Retryable),
            "completed" => Ok(Self::Completed),
            "expired" => Ok(Self::Expired),
            "failed" => Ok(Self::Failed),
            _ => Err(StoreError::UnknownSessionPickerState(value)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingSessionPicker {
    pub callback_token: String,
    pub origin_event_id: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub owner_user_id: i64,
    pub chat_id: i64,
    pub workspace_id: WorkspaceId,
    pub workspace_label: String,
    pub sessions: Vec<SessionSummary>,
    pub catalog_cursor: Option<String>,
    pub created_at: i64,
    pub expires_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionPickerRecord {
    pub callback_token: String,
    pub origin_event_id: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub owner_user_id: i64,
    pub chat_id: i64,
    pub workspace_id: WorkspaceId,
    pub workspace_label: String,
    pub picker_message_id: Option<i64>,
    pub sessions: Vec<SessionSummary>,
    pub catalog_cursor: Option<String>,
    pub page: usize,
    pub state: SessionPickerState,
    pub selected_index: Option<usize>,
    pub thread_chat_id: Option<i64>,
    pub agent_session_id: Option<i64>,
    pub status_message_id: Option<i64>,
    pub terminal_projected: bool,
    pub status_pinned: bool,
    pub attempt_count: i64,
    pub lease_owner: Option<String>,
    pub lease_expires_at: Option<i64>,
    pub last_error: Option<String>,
    pub created_at: i64,
    pub expires_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionPickerClaimContext {
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub owner_user_id: i64,
    pub actor_user_id: i64,
    pub chat_id: i64,
    pub message_id: i64,
    pub workspace_id: WorkspaceId,
    pub lease_owner: String,
    pub now: i64,
    pub lease_expires_at: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionPickerCompletion {
    pub thread_chat_id: i64,
    pub agent_session_id: i64,
    pub status_message_id: i64,
    pub status_pinned: bool,
    pub completed_at: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPickerAction {
    Open { index: usize },
    Page { page: usize },
    LoadOlder { expected_count: usize },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionPickerClaimOutcome {
    Claimed(SessionPickerRecord),
    Resumable(SessionPickerRecord),
    InProgress(SessionPickerRecord),
    Navigated(SessionPickerRecord),
    LoadRequested(SessionPickerRecord),
    Completed(SessionPickerRecord),
    Expired(SessionPickerRecord),
    Failed(SessionPickerRecord),
    Unknown,
    Unauthorized,
    WrongContext,
    InvalidChoice,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct StoredSessionSummary {
    provider_session_id: String,
    title: Option<String>,
    preview: Option<String>,
    updated_at: Option<i64>,
    availability: SessionAvailability,
}

impl BridgeStore {
    pub fn insert_session_picker(&self, picker: &PendingSessionPicker) -> StoreResult<bool> {
        let sessions_json = encode_sessions(picker)?;
        validate_pending_picker(picker, &sessions_json)?;
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        transaction.execute(
            "UPDATE session_pickers
             SET state = 'retryable', lease_owner = NULL, lease_expires_at = NULL,
                 last_error = COALESCE(last_error, 'Opening lease expired'),
                 updated_at = ?2
             WHERE installation_id = ?1 AND state = 'opening'
               AND (lease_expires_at IS NULL OR lease_expires_at <= ?2)",
            params![picker.installation_id.as_str(), picker.created_at],
        )?;
        transaction.execute(
            "UPDATE session_pickers
             SET state = CASE WHEN thread_chat_id IS NULL THEN 'expired' ELSE 'failed' END,
                 last_error = CASE
                    WHEN thread_chat_id IS NULL THEN last_error
                    ELSE COALESCE(last_error, 'Session opening expired before completion')
                 END,
                 updated_at = ?2
             WHERE installation_id = ?1
               AND state IN ('publishing', 'active', 'retryable')
               AND expires_at <= ?2",
            params![picker.installation_id.as_str(), picker.created_at],
        )?;
        let active: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM session_pickers
             WHERE installation_id = ?1
               AND state IN ('publishing', 'active', 'opening', 'retryable')
               AND (state != 'publishing' OR last_error IS NULL)",
            params![picker.installation_id.as_str()],
            |row| row.get(0),
        )?;
        if active >= MAX_ACTIVE_SESSION_PICKERS as i64 {
            transaction.commit()?;
            return Ok(false);
        }
        let changed = transaction.execute(
            "INSERT OR IGNORE INTO session_pickers (
                callback_token, origin_event_id, installation_id, provider_id,
                owner_user_id, chat_id, workspace_id, workspace_label,
                picker_message_id, sessions_json, page, state, selected_index,
                thread_chat_id, agent_session_id, status_message_id, attempt_count,
                lease_owner, lease_expires_at, last_error, created_at, expires_at,
                updated_at, catalog_cursor
             ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, ?9, 0, 'publishing',
                NULL, NULL, NULL, NULL, 0, NULL, NULL, NULL, ?10, ?11, ?10, ?12
             )",
            params![
                picker.callback_token,
                picker.origin_event_id,
                picker.installation_id.as_str(),
                picker.provider_id.as_str(),
                picker.owner_user_id,
                picker.chat_id,
                picker.workspace_id.as_str(),
                picker.workspace_label,
                sessions_json,
                picker.created_at,
                picker.expires_at,
                picker.catalog_cursor,
            ],
        )?;
        transaction.commit()?;
        Ok(changed == 1)
    }

    /// Append provider results without replacing any existing Open index. The
    /// cursor/count comparison makes retried or stale Load Older taps no-ops.
    pub fn append_session_picker_sessions(
        &self,
        expected: &SessionPickerRecord,
        incoming: &[SessionSummary],
        next_cursor: Option<String>,
        now: i64,
    ) -> StoreResult<Option<SessionPickerRecord>> {
        validate_catalog_cursor(next_cursor.as_deref())?;
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let Some(picker) = read_picker(&transaction, &expected.callback_token)? else {
            return Ok(None);
        };
        if picker.state != SessionPickerState::Active
            || picker.expires_at <= now
            || picker.catalog_cursor.is_none()
            || picker.catalog_cursor != expected.catalog_cursor
            || picker.sessions.len() != expected.sessions.len()
        {
            return Ok(None);
        }
        if next_cursor == picker.catalog_cursor {
            return Err(invalid_picker_identifier("<repeated catalog cursor>"));
        }
        let provider =
            ProviderInstanceRef::new(picker.installation_id.clone(), picker.provider_id.clone())
                .map_err(|_| invalid_picker_identifier("<provider>"))?;
        let mut sessions = picker.sessions.clone();
        let mut seen = sessions
            .iter()
            .map(|session| session.session().session_id().as_str().to_owned())
            .collect::<std::collections::HashSet<_>>();
        for session in incoming {
            if session.session().provider() != &provider
                || session.workspace_id() != &picker.workspace_id
            {
                return Err(invalid_picker_identifier("<session scope>"));
            }
            if seen.insert(session.session().session_id().as_str().to_owned()) {
                sessions.push(session.clone());
            }
        }
        let pending = PendingSessionPicker {
            callback_token: picker.callback_token.clone(),
            origin_event_id: picker.origin_event_id.clone(),
            installation_id: picker.installation_id.clone(),
            provider_id: picker.provider_id.clone(),
            owner_user_id: picker.owner_user_id,
            chat_id: picker.chat_id,
            workspace_id: picker.workspace_id.clone(),
            workspace_label: picker.workspace_label.clone(),
            sessions,
            catalog_cursor: next_cursor,
            created_at: picker.created_at,
            expires_at: picker.expires_at,
        };
        let encoded = encode_sessions(&pending)?;
        validate_pending_picker(&pending, &encoded)?;
        // Revisit a partial last page so no newly fetched entry is skipped.
        let page = (picker.sessions.len() / SESSION_PICKER_PAGE_SIZE)
            .min((pending.sessions.len() - 1) / SESSION_PICKER_PAGE_SIZE);
        transaction.execute(
            "UPDATE session_pickers SET sessions_json = ?2, catalog_cursor = ?3,
             page = ?4, updated_at = ?5 WHERE callback_token = ?1",
            params![
                picker.callback_token,
                encoded,
                pending.catalog_cursor,
                page as i64,
                now
            ],
        )?;
        let updated = read_picker(&transaction, &picker.callback_token)?;
        transaction.commit()?;
        Ok(updated)
    }

    pub fn attach_session_picker_message(
        &self,
        callback_token: &str,
        message_id: i64,
        updated_at: i64,
    ) -> StoreResult<bool> {
        if message_id <= 0 {
            return Ok(false);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers
             SET picker_message_id = ?2, state = 'active', updated_at = ?3
             WHERE callback_token = ?1 AND state IN ('publishing', 'active')
               AND (picker_message_id IS NULL OR picker_message_id = ?2)",
            params![callback_token, message_id, updated_at],
        )?;
        Ok(changed == 1)
    }

    pub fn record_session_picker_publication_failure(
        &self,
        callback_token: &str,
        failure: &str,
        updated_at: i64,
    ) -> StoreResult<bool> {
        let failure = normalize_failure(failure);
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers
             SET last_error = ?2, updated_at = ?3
             WHERE callback_token = ?1 AND state = 'publishing'
               AND picker_message_id IS NULL",
            params![callback_token, failure, updated_at],
        )?;
        Ok(changed == 1)
    }

    pub fn session_picker(&self, callback_token: &str) -> StoreResult<Option<SessionPickerRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        read_picker(&connection, callback_token)
    }

    pub fn session_picker_for_origin_event(
        &self,
        installation_id: &InstallationId,
        origin_event_id: &str,
    ) -> StoreResult<Option<SessionPickerRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let token = connection
            .query_row(
                "SELECT callback_token FROM session_pickers
                 WHERE installation_id = ?1 AND origin_event_id = ?2",
                params![installation_id.as_str(), origin_event_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        token
            .as_deref()
            .map(|token| read_picker(&connection, token))
            .transpose()
            .map(Option::flatten)
    }

    /// Publication is repairable independently of the command's terminal
    /// state: a remote send may have committed before its local attachment.
    pub fn recoverable_session_picker_commands(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Vec<SessionPickerRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let tokens = {
            let mut statement = connection.prepare(
                "SELECT session_pickers.callback_token
                 FROM session_pickers
                 INNER JOIN inbound_directions
                   ON inbound_directions.event_id = session_pickers.origin_event_id
                  AND inbound_directions.installation_id = session_pickers.installation_id
                 WHERE session_pickers.installation_id = ?1
                   AND inbound_directions.terminal_state IS NULL
                   AND ((inbound_directions.state = 'started'
                         AND session_pickers.picker_message_id IS NOT NULL)
                        OR session_pickers.state IN ('publishing', 'active'))
                 ORDER BY inbound_directions.ingest_order ASC",
            )?;
            statement
                .query_map(params![installation_id.as_str()], |row| {
                    row.get::<_, String>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        tokens
            .into_iter()
            .map(|token| {
                read_picker(&connection, &token)?.ok_or_else(|| invalid_picker_identifier(&token))
            })
            .collect()
    }

    pub fn claim_session_picker(
        &self,
        callback_token: &str,
        action: SessionPickerAction,
        context: &SessionPickerClaimContext,
    ) -> StoreResult<SessionPickerClaimOutcome> {
        validate_claim_context(context)?;
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let Some(mut picker) = read_picker(&transaction, callback_token)? else {
            transaction.commit()?;
            return Ok(SessionPickerClaimOutcome::Unknown);
        };
        if context.actor_user_id != picker.owner_user_id
            || context.actor_user_id != context.owner_user_id
        {
            transaction.commit()?;
            return Ok(SessionPickerClaimOutcome::Unauthorized);
        }
        if context.installation_id != picker.installation_id
            || context.provider_id != picker.provider_id
            || context.owner_user_id != picker.owner_user_id
            || context.chat_id != picker.chat_id
            || context.workspace_id != picker.workspace_id
            || picker
                .picker_message_id
                .is_some_and(|message_id| message_id != context.message_id)
        {
            transaction.commit()?;
            return Ok(SessionPickerClaimOutcome::WrongContext);
        }
        if picker.picker_message_id.is_none() && picker.state == SessionPickerState::Publishing {
            transaction.execute(
                "UPDATE session_pickers
                 SET picker_message_id = ?2, state = 'active', updated_at = ?3
                 WHERE callback_token = ?1 AND state = 'publishing'
                   AND picker_message_id IS NULL",
                params![callback_token, context.message_id, context.now],
            )?;
            picker.picker_message_id = Some(context.message_id);
            picker.state = SessionPickerState::Active;
            picker.updated_at = context.now;
        }
        match picker.state {
            SessionPickerState::Completed => {
                transaction.commit()?;
                return Ok(SessionPickerClaimOutcome::Completed(picker));
            }
            SessionPickerState::Expired => {
                transaction.commit()?;
                return Ok(SessionPickerClaimOutcome::Expired(picker));
            }
            SessionPickerState::Failed => {
                transaction.commit()?;
                return Ok(SessionPickerClaimOutcome::Failed(picker));
            }
            _ => {}
        }
        let opening_lease_is_live = picker.state == SessionPickerState::Opening
            && picker
                .lease_expires_at
                .is_some_and(|expires_at| expires_at > context.now);
        if picker.expires_at <= context.now && !opening_lease_is_live {
            let terminal_state = if picker.thread_chat_id.is_some() {
                SessionPickerState::Failed
            } else {
                SessionPickerState::Expired
            };
            transaction.execute(
                "UPDATE session_pickers
                 SET state = ?2,
                     last_error = CASE
                        WHEN ?2 = 'failed' THEN
                            COALESCE(last_error, 'Session opening expired before completion')
                        ELSE last_error
                     END,
                     updated_at = ?3
                 WHERE callback_token = ?1",
                params![callback_token, terminal_state.as_str(), context.now],
            )?;
            picker.state = terminal_state;
            picker.updated_at = context.now;
            transaction.commit()?;
            return Ok(match terminal_state {
                SessionPickerState::Failed => SessionPickerClaimOutcome::Failed(picker),
                _ => SessionPickerClaimOutcome::Expired(picker),
            });
        }
        // Once Open may have created a remote thread, keep its target fixed.
        // Old navigation/other-choice buttons redraw the recovery card instead
        // of changing the session under its durable checkpoints.
        if picker.state == SessionPickerState::Retryable
            && !matches!(action, SessionPickerAction::Open { index } if picker.selected_index == Some(index))
        {
            transaction.commit()?;
            return Ok(SessionPickerClaimOutcome::Navigated(picker));
        }
        match action {
            SessionPickerAction::LoadOlder { expected_count } => {
                // The fetch may have committed before editing the card. An
                // old button repairs that card instead of fetching twice.
                if picker.state == SessionPickerState::Active
                    && expected_count < picker.sessions.len()
                {
                    transaction.commit()?;
                    return Ok(SessionPickerClaimOutcome::Navigated(picker));
                }
                let available = picker.state == SessionPickerState::Active
                    && picker.sessions.len() == expected_count
                    && expected_count < MAX_SESSION_PICKER_ITEMS
                    && picker.catalog_cursor.is_some();
                transaction.commit()?;
                Ok(if available {
                    SessionPickerClaimOutcome::LoadRequested(picker)
                } else {
                    SessionPickerClaimOutcome::InvalidChoice
                })
            }
            SessionPickerAction::Page { page } => {
                if picker.state != SessionPickerState::Active || !page_exists(&picker, page) {
                    transaction.commit()?;
                    return Ok(SessionPickerClaimOutcome::InvalidChoice);
                }
                transaction.execute(
                    "UPDATE session_pickers SET page = ?2, updated_at = ?3
                     WHERE callback_token = ?1 AND state = 'active'",
                    params![callback_token, page as i64, context.now],
                )?;
                picker.page = page;
                picker.updated_at = context.now;
                transaction.commit()?;
                Ok(SessionPickerClaimOutcome::Navigated(picker))
            }
            SessionPickerAction::Open { index } => {
                if !picker
                    .sessions
                    .get(index)
                    .is_some_and(|session| session.availability() == SessionAvailability::Available)
                {
                    transaction.commit()?;
                    return Ok(SessionPickerClaimOutcome::InvalidChoice);
                }
                if picker.state == SessionPickerState::Opening {
                    if picker.selected_index != Some(index) {
                        transaction.commit()?;
                        return Ok(SessionPickerClaimOutcome::InvalidChoice);
                    }
                    if picker
                        .lease_expires_at
                        .is_some_and(|expires_at| expires_at > context.now)
                    {
                        transaction.commit()?;
                        return Ok(SessionPickerClaimOutcome::InProgress(picker));
                    }
                    transaction.execute(
                        "UPDATE session_pickers
                         SET lease_owner = ?2, lease_expires_at = ?3,
                             attempt_count = attempt_count + 1, updated_at = ?4,
                             last_error = NULL
                         WHERE callback_token = ?1 AND state = 'opening'
                           AND selected_index = ?5",
                        params![
                            callback_token,
                            context.lease_owner,
                            context.lease_expires_at,
                            context.now,
                            index as i64,
                        ],
                    )?;
                    picker.lease_owner = Some(context.lease_owner.clone());
                    picker.lease_expires_at = Some(context.lease_expires_at);
                    picker.attempt_count += 1;
                    picker.updated_at = context.now;
                    picker.last_error = None;
                    transaction.commit()?;
                    return Ok(SessionPickerClaimOutcome::Resumable(picker));
                }
                if !matches!(
                    picker.state,
                    SessionPickerState::Active | SessionPickerState::Retryable
                ) {
                    transaction.commit()?;
                    return Ok(SessionPickerClaimOutcome::InvalidChoice);
                }
                transaction.execute(
                    "UPDATE session_pickers
                     SET state = 'opening', selected_index = ?2, lease_owner = ?3,
                         lease_expires_at = ?4, attempt_count = attempt_count + 1,
                         updated_at = ?5, last_error = NULL
                     WHERE callback_token = ?1 AND state IN ('active', 'retryable')",
                    params![
                        callback_token,
                        index as i64,
                        context.lease_owner,
                        context.lease_expires_at,
                        context.now,
                    ],
                )?;
                picker.state = SessionPickerState::Opening;
                picker.selected_index = Some(index);
                picker.lease_owner = Some(context.lease_owner.clone());
                picker.lease_expires_at = Some(context.lease_expires_at);
                picker.attempt_count += 1;
                picker.updated_at = context.now;
                picker.last_error = None;
                transaction.commit()?;
                Ok(SessionPickerClaimOutcome::Claimed(picker))
            }
        }
    }

    pub fn retry_session_picker_open(
        &self,
        callback_token: &str,
        lease_owner: &str,
        failure: &str,
        updated_at: i64,
    ) -> StoreResult<bool> {
        let failure = normalize_failure(failure);
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers
             SET state = 'retryable', lease_owner = NULL, lease_expires_at = NULL,
                 last_error = ?3, updated_at = ?4
             WHERE callback_token = ?1 AND state = 'opening' AND lease_owner = ?2",
            params![callback_token, lease_owner, failure, updated_at],
        )?;
        Ok(changed == 1)
    }

    pub fn update_session_picker_open_progress(
        &self,
        callback_token: &str,
        lease_owner: &str,
        thread_chat_id: Option<i64>,
        agent_session_id: Option<i64>,
        status_message_id: Option<i64>,
        updated_at: i64,
    ) -> StoreResult<bool> {
        if thread_chat_id.is_some_and(|id| id <= 0)
            || agent_session_id.is_some_and(|id| id <= 0)
            || status_message_id.is_some_and(|id| id <= 0)
        {
            return Ok(false);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers
             SET thread_chat_id = COALESCE(thread_chat_id, ?3),
                 agent_session_id = COALESCE(agent_session_id, ?4),
                 status_message_id = COALESCE(status_message_id, ?5),
                 updated_at = ?6
             WHERE callback_token = ?1 AND state = 'opening' AND lease_owner = ?2
               AND lease_expires_at > ?6
               AND (?3 IS NULL OR thread_chat_id IS NULL OR thread_chat_id = ?3)
               AND (?4 IS NULL OR agent_session_id IS NULL OR agent_session_id = ?4)
               AND (?5 IS NULL OR status_message_id IS NULL OR status_message_id = ?5)",
            params![
                callback_token,
                lease_owner,
                thread_chat_id,
                agent_session_id,
                status_message_id,
                updated_at,
            ],
        )?;
        Ok(changed == 1)
    }

    /// Replace a pre-connect target checkpoint with a canonical binding found
    /// during retry. Once any server/session projection has been checkpointed,
    /// identity is immutable and a mismatch must fail closed.
    pub fn reconcile_session_picker_open_thread(
        &self,
        callback_token: &str,
        lease_owner: &str,
        expected_thread_chat_id: i64,
        canonical_thread_chat_id: i64,
        updated_at: i64,
    ) -> StoreResult<bool> {
        if expected_thread_chat_id <= 0 || canonical_thread_chat_id <= 0 {
            return Ok(false);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers
             SET thread_chat_id = ?4, updated_at = ?5
             WHERE callback_token = ?1 AND state = 'opening' AND lease_owner = ?2
               AND lease_expires_at > ?5 AND thread_chat_id = ?3
               AND agent_session_id IS NULL AND status_message_id IS NULL",
            params![
                callback_token,
                lease_owner,
                expected_thread_chat_id,
                canonical_thread_chat_id,
                updated_at,
            ],
        )?;
        Ok(changed == 1)
    }

    pub fn recover_session_pickers(
        &self,
        installation_id: &InstallationId,
        now: i64,
    ) -> StoreResult<usize> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let retryable = transaction.execute(
            "UPDATE session_pickers
             SET state = 'retryable', lease_owner = NULL, lease_expires_at = NULL,
                 last_error = COALESCE(last_error, 'Bridge restarted while opening'),
                 updated_at = ?2
             WHERE installation_id = ?1 AND state = 'opening'",
            params![installation_id.as_str(), now],
        )?;
        let expired = transaction.execute(
            "UPDATE session_pickers
             SET state = CASE WHEN thread_chat_id IS NULL THEN 'expired' ELSE 'failed' END,
                 last_error = CASE
                    WHEN thread_chat_id IS NULL THEN last_error
                    ELSE COALESCE(last_error, 'Session opening expired before completion')
                 END,
                 updated_at = ?2
             WHERE installation_id = ?1
               AND state IN ('publishing', 'active', 'retryable')
               AND expires_at <= ?2",
            params![installation_id.as_str(), now],
        )?;
        transaction.commit()?;
        Ok(retryable + expired)
    }

    pub fn complete_session_picker_open(
        &self,
        callback_token: &str,
        lease_owner: &str,
        completion: SessionPickerCompletion,
    ) -> StoreResult<bool> {
        if completion.thread_chat_id <= 0
            || completion.agent_session_id <= 0
            || completion.status_message_id <= 0
        {
            return Ok(false);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers
             SET state = 'completed', thread_chat_id = ?3, agent_session_id = ?4,
                 status_message_id = ?5, lease_owner = NULL, lease_expires_at = NULL,
                 status_pinned = ?6, last_error = NULL, updated_at = ?7
             WHERE callback_token = ?1 AND state = 'opening' AND lease_owner = ?2
               AND lease_expires_at > ?7
               AND (thread_chat_id IS NULL OR thread_chat_id = ?3)
               AND (agent_session_id IS NULL OR agent_session_id = ?4)
               AND (status_message_id IS NULL OR status_message_id = ?5)",
            params![
                callback_token,
                lease_owner,
                completion.thread_chat_id,
                completion.agent_session_id,
                completion.status_message_id,
                completion.status_pinned,
                completion.completed_at,
            ],
        )?;
        Ok(changed == 1)
    }

    pub fn mark_session_picker_terminal_projected(
        &self,
        callback_token: &str,
        updated_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers SET terminal_projected = 1, updated_at = ?2
             WHERE callback_token = ?1 AND state IN ('completed', 'expired', 'failed')",
            params![callback_token, updated_at],
        )?;
        Ok(changed == 1)
    }

    pub fn mark_session_picker_status_pinned(
        &self,
        callback_token: &str,
        updated_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE session_pickers SET status_pinned = 1, updated_at = ?2
             WHERE callback_token = ?1 AND state = 'completed'",
            params![callback_token, updated_at],
        )?;
        Ok(changed == 1)
    }

    pub fn session_picker_projection_repairs(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Vec<SessionPickerRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let tokens = {
            let mut statement = connection.prepare(
                "SELECT callback_token FROM session_pickers
                 WHERE installation_id = ?1 AND state = 'completed'
                   AND (terminal_projected = 0 OR status_pinned = 0)
                 ORDER BY updated_at ASC",
            )?;
            statement
                .query_map(params![installation_id.as_str()], |row| {
                    row.get::<_, String>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        tokens
            .into_iter()
            .map(|token| {
                read_picker(&connection, &token)?.ok_or_else(|| invalid_picker_identifier(&token))
            })
            .collect()
    }

    pub fn session_picker_recovery_cards(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Vec<SessionPickerRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let tokens = {
            let mut statement = connection.prepare(
                "SELECT callback_token FROM session_pickers
                 WHERE installation_id = ?1 AND picker_message_id IS NOT NULL
                   AND (
                        (state = 'retryable' AND selected_index IS NOT NULL) OR
                        (state IN ('expired', 'failed') AND terminal_projected = 0)
                   )
                 ORDER BY updated_at ASC",
            )?;
            statement
                .query_map(params![installation_id.as_str()], |row| {
                    row.get::<_, String>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        tokens
            .into_iter()
            .map(|token| {
                read_picker(&connection, &token)?.ok_or_else(|| invalid_picker_identifier(&token))
            })
            .collect()
    }

    pub fn session_picker_thread_gate(
        &self,
        installation_id: &InstallationId,
        thread_chat_id: i64,
        now: i64,
    ) -> StoreResult<SessionPickerThreadGate> {
        if thread_chat_id <= 0 {
            return Ok(SessionPickerThreadGate::Ready);
        }
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let state = session_picker_thread_gate_in_transaction(
            &transaction,
            installation_id,
            thread_chat_id,
            now,
        )?;
        transaction.commit()?;
        Ok(state)
    }
}

pub(super) fn session_picker_thread_gate_in_transaction(
    transaction: &Transaction<'_>,
    installation_id: &InstallationId,
    thread_chat_id: i64,
    now: i64,
) -> StoreResult<SessionPickerThreadGate> {
    transaction.execute(
        "UPDATE session_pickers
             SET state = 'retryable', lease_owner = NULL, lease_expires_at = NULL,
                 last_error = COALESCE(last_error, 'Opening lease expired'), updated_at = ?2
             WHERE installation_id = ?1 AND state = 'opening'
               AND (lease_expires_at IS NULL OR lease_expires_at <= ?2)",
        params![installation_id.as_str(), now],
    )?;
    // A picker that already checkpointed a target thread must never fall
    // through to ordinary turn admission. The exact provider binding is
    // written later in Open, so expiring this intent as if it were an
    // untouched card could resume a different/default provider session.
    transaction.execute(
        "UPDATE session_pickers
             SET state = CASE WHEN thread_chat_id IS NULL THEN 'expired' ELSE 'failed' END,
                 last_error = CASE
                    WHEN thread_chat_id IS NULL THEN last_error
                    ELSE COALESCE(last_error, 'Session opening expired before completion')
                 END,
                 updated_at = ?2
             WHERE installation_id = ?1 AND state = 'retryable' AND expires_at <= ?2",
        params![installation_id.as_str(), now],
    )?;
    let state = transaction
        .query_row(
            "SELECT state FROM session_pickers
             WHERE installation_id = ?1 AND thread_chat_id = ?2
               AND state IN ('opening', 'retryable', 'completed', 'failed')
             ORDER BY created_at DESC, rowid DESC
             LIMIT 1",
            params![installation_id.as_str(), thread_chat_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    match state.as_deref() {
        None | Some("completed") => Ok(SessionPickerThreadGate::Ready),
        Some("opening" | "retryable") => Ok(SessionPickerThreadGate::Opening),
        Some("failed") => Ok(SessionPickerThreadGate::Failed),
        _ => Err(invalid_picker_identifier("<thread-gate>")),
    }
}

fn encode_sessions(picker: &PendingSessionPicker) -> StoreResult<String> {
    let sessions = picker
        .sessions
        .iter()
        .map(|session| StoredSessionSummary {
            provider_session_id: session.session().session_id().to_string(),
            title: session.title().map(str::to_string),
            preview: session.preview().map(str::to_string),
            updated_at: session.updated_at(),
            availability: session.availability(),
        })
        .collect::<Vec<_>>();
    Ok(serde_json::to_string(&sessions)?)
}

fn decode_sessions(
    installation_id: &InstallationId,
    provider_id: &ProviderId,
    workspace_id: &WorkspaceId,
    value: &str,
) -> StoreResult<Vec<SessionSummary>> {
    if value.len() > MAX_SESSIONS_JSON_BYTES {
        return Err(invalid_picker_identifier("<sessions>"));
    }
    let stored = serde_json::from_str::<Vec<StoredSessionSummary>>(value)?;
    if stored.is_empty() || stored.len() > MAX_SESSION_PICKER_ITEMS {
        return Err(invalid_picker_identifier("<sessions>"));
    }
    let provider = ProviderInstanceRef::new(installation_id.clone(), provider_id.clone())
        .map_err(|_| invalid_picker_identifier("<provider>"))?;
    stored
        .into_iter()
        .map(|stored_session| {
            let session_id = ProviderSessionId::new(stored_session.provider_session_id)
                .map_err(|_| invalid_picker_identifier("<session>"))?;
            let session = ProviderSessionRef::new(provider.clone(), session_id)
                .map_err(|_| invalid_picker_identifier("<session>"))?;
            SessionSummary::new(
                session,
                workspace_id.clone(),
                stored_session.title,
                stored_session.preview,
                stored_session.updated_at,
                stored_session.availability,
            )
            .map_err(|_| invalid_picker_identifier("<session>"))
        })
        .collect()
}

fn validate_pending_picker(picker: &PendingSessionPicker, sessions_json: &str) -> StoreResult<()> {
    validate_catalog_cursor(picker.catalog_cursor.as_deref())?;
    let provider =
        ProviderInstanceRef::new(picker.installation_id.clone(), picker.provider_id.clone())
            .map_err(|_| invalid_picker_identifier(&picker.callback_token))?;
    if picker.callback_token.is_empty()
        || picker.callback_token.len() > MAX_CALLBACK_TOKEN_BYTES
        || picker.callback_token.chars().any(char::is_control)
        || picker.origin_event_id.is_empty()
        || picker.origin_event_id.len() > MAX_EVENT_ID_BYTES
        || picker.origin_event_id.chars().any(char::is_control)
        || picker.owner_user_id <= 0
        || picker.chat_id <= 0
        || picker.created_at < 0
        || picker.expires_at <= picker.created_at
        || picker.sessions.is_empty()
        || picker.sessions.len() > MAX_SESSION_PICKER_ITEMS
        || sessions_json.len() > MAX_SESSIONS_JSON_BYTES
        || picker.workspace_label.trim().is_empty()
        || picker.workspace_label.chars().count() > MAX_WORKSPACE_LABEL_CHARS
        || picker.workspace_label.chars().any(char::is_control)
        || picker.sessions.iter().any(|session| {
            session.session().provider() != &provider
                || session.workspace_id() != &picker.workspace_id
        })
    {
        return Err(invalid_picker_identifier(&picker.callback_token));
    }
    Ok(())
}

fn validate_catalog_cursor(cursor: Option<&str>) -> StoreResult<()> {
    if let Some(cursor) = cursor {
        crate::SessionPageCursor::new(cursor.to_owned())
            .map_err(|_| invalid_picker_identifier("<catalog cursor>"))?;
    }
    Ok(())
}

fn validate_claim_context(context: &SessionPickerClaimContext) -> StoreResult<()> {
    if context.owner_user_id <= 0
        || context.actor_user_id <= 0
        || context.chat_id <= 0
        || context.message_id <= 0
        || context.lease_owner.is_empty()
        || context.lease_owner.len() > MAX_EVENT_ID_BYTES
        || context.lease_owner.chars().any(char::is_control)
        || context.now < 0
        || context.lease_expires_at <= context.now
    {
        return Err(invalid_picker_identifier(&context.lease_owner));
    }
    Ok(())
}

fn invalid_picker_identifier(value: &str) -> StoreError {
    StoreError::InvalidIdentifier {
        kind: "session picker",
        value: value.to_string(),
    }
}

fn normalize_failure(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .take(MAX_FAILURE_CHARS)
        .collect()
}

fn page_exists(picker: &SessionPickerRecord, page: usize) -> bool {
    page.saturating_mul(SESSION_PICKER_PAGE_SIZE) < picker.sessions.len()
}

fn read_picker(
    connection: &Connection,
    callback_token: &str,
) -> StoreResult<Option<SessionPickerRecord>> {
    let raw = connection
        .query_row(
            "SELECT origin_event_id, installation_id, provider_id, owner_user_id,
                    chat_id, workspace_id, workspace_label, picker_message_id,
                    sessions_json, page, state, selected_index, thread_chat_id,
                    agent_session_id, status_message_id, terminal_projected,
                    status_pinned, attempt_count, lease_owner, lease_expires_at,
                    last_error, created_at, expires_at, updated_at, catalog_cursor
             FROM session_pickers WHERE callback_token = ?1",
            params![callback_token],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, Option<i64>>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, i64>(9)?,
                    row.get::<_, String>(10)?,
                    row.get::<_, Option<i64>>(11)?,
                    row.get::<_, Option<i64>>(12)?,
                    row.get::<_, Option<i64>>(13)?,
                    row.get::<_, Option<i64>>(14)?,
                    row.get::<_, bool>(15)?,
                    row.get::<_, bool>(16)?,
                    row.get::<_, i64>(17)?,
                    row.get::<_, Option<String>>(18)?,
                    row.get::<_, Option<i64>>(19)?,
                    row.get::<_, Option<String>>(20)?,
                    row.get::<_, i64>(21)?,
                    row.get::<_, i64>(22)?,
                    row.get::<_, i64>(23)?,
                    row.get::<_, Option<String>>(24)?,
                ))
            },
        )
        .optional()?;
    let Some((
        origin_event_id,
        installation_id,
        provider_id,
        owner_user_id,
        chat_id,
        workspace_id,
        workspace_label,
        picker_message_id,
        sessions_json,
        page,
        state,
        selected_index,
        thread_chat_id,
        agent_session_id,
        status_message_id,
        terminal_projected,
        status_pinned,
        attempt_count,
        lease_owner,
        lease_expires_at,
        last_error,
        created_at,
        expires_at,
        updated_at,
        catalog_cursor,
    )) = raw
    else {
        return Ok(None);
    };
    let installation_id = parse_installation_id(installation_id)?;
    let provider_id = parse_provider_id(provider_id)?;
    let workspace_id = parse_workspace_id(workspace_id)?;
    validate_catalog_cursor(catalog_cursor.as_deref())?;
    let sessions = decode_sessions(
        &installation_id,
        &provider_id,
        &workspace_id,
        &sessions_json,
    )?;
    Ok(Some(SessionPickerRecord {
        callback_token: callback_token.to_string(),
        origin_event_id,
        installation_id,
        provider_id,
        owner_user_id,
        chat_id,
        workspace_id,
        workspace_label,
        picker_message_id,
        sessions,
        catalog_cursor,
        page: usize::try_from(page).map_err(|_| invalid_picker_identifier(callback_token))?,
        state: SessionPickerState::parse(state)?,
        selected_index: selected_index
            .map(usize::try_from)
            .transpose()
            .map_err(|_| invalid_picker_identifier(callback_token))?,
        thread_chat_id,
        agent_session_id,
        status_message_id,
        terminal_projected,
        status_pinned,
        attempt_count,
        lease_owner,
        lease_expires_at,
        last_error,
        created_at,
        expires_at,
        updated_at,
    }))
}

pub(super) fn migrate_v27(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE session_pickers (
            callback_token TEXT PRIMARY KEY NOT NULL,
            origin_event_id TEXT NOT NULL,
            installation_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            owner_user_id INTEGER NOT NULL,
            chat_id INTEGER NOT NULL,
            workspace_id TEXT NOT NULL,
            workspace_label TEXT NOT NULL,
            picker_message_id INTEGER,
            sessions_json TEXT NOT NULL,
            page INTEGER NOT NULL,
            state TEXT NOT NULL CHECK (
                state IN ('publishing', 'active', 'opening', 'retryable',
                          'completed', 'expired', 'failed')
            ),
            selected_index INTEGER,
            thread_chat_id INTEGER,
            agent_session_id INTEGER,
            status_message_id INTEGER,
            attempt_count INTEGER NOT NULL,
            lease_owner TEXT,
            lease_expires_at INTEGER,
            last_error TEXT,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE (installation_id, origin_event_id),
            FOREIGN KEY (installation_id, workspace_id)
                REFERENCES workspaces(installation_id, workspace_id)
                ON DELETE RESTRICT
         );
         CREATE INDEX session_pickers_open
         ON session_pickers (state, lease_expires_at);
         CREATE INDEX session_pickers_expiry
         ON session_pickers (installation_id, expires_at);
         PRAGMA user_version = 27;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v28(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE session_pickers ADD COLUMN terminal_projected INTEGER NOT NULL
             DEFAULT 0 CHECK (terminal_projected IN (0, 1));
         ALTER TABLE session_pickers ADD COLUMN status_pinned INTEGER NOT NULL
             DEFAULT 0 CHECK (status_pinned IN (0, 1));
         PRAGMA user_version = 28;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v30(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE session_pickers ADD COLUMN catalog_cursor TEXT;
         PRAGMA user_version = 30;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{InboundRecord, InboundState};
    use crate::{BindingKey, Direction, DirectionId, InstallationRecord, WorkspaceRecord};

    fn install_fixture(store: &BridgeStore, workspace: &std::path::Path) -> PendingSessionPicker {
        let installation_id = InstallationId::new("host-codex").expect("installation");
        let provider_id = ProviderId::new("codex").expect("provider");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: provider_id.clone(),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        let workspace_id = WorkspaceId::new("workspace-1").expect("workspace id");
        let WorkspaceRecord { display_name, .. } = store
            .select_workspace(&installation_id, &workspace_id, workspace, 1)
            .expect("select workspace");
        let provider = ProviderInstanceRef::new(installation_id.clone(), provider_id.clone())
            .expect("provider");
        let sessions = (0..3)
            .map(|index| {
                SessionSummary::new(
                    ProviderSessionRef::new(
                        provider.clone(),
                        ProviderSessionId::new(format!("session-{index}")).expect("session id"),
                    )
                    .expect("session"),
                    workspace_id.clone(),
                    Some(format!("Session {index}")),
                    Some(format!("Preview {index}")),
                    Some(index),
                    SessionAvailability::Available,
                )
                .expect("summary")
            })
            .collect();
        PendingSessionPicker {
            callback_token: "opaque-token".to_string(),
            origin_event_id: "source-event".to_string(),
            installation_id,
            provider_id,
            owner_user_id: 7,
            chat_id: 11,
            workspace_id,
            workspace_label: display_name,
            sessions,
            catalog_cursor: None,
            created_at: 100,
            expires_at: 200,
        }
    }

    fn memory_fixture() -> (BridgeStore, PendingSessionPicker, tempfile::TempDir) {
        let store = BridgeStore::open_in_memory().expect("store");
        let workspace = tempfile::tempdir().expect("workspace");
        let picker = install_fixture(&store, workspace.path());
        (store, picker, workspace)
    }

    fn context(
        picker: &PendingSessionPicker,
        lease_owner: &str,
        now: i64,
    ) -> SessionPickerClaimContext {
        SessionPickerClaimContext {
            installation_id: picker.installation_id.clone(),
            provider_id: picker.provider_id.clone(),
            owner_user_id: picker.owner_user_id,
            actor_user_id: picker.owner_user_id,
            chat_id: picker.chat_id,
            message_id: 13,
            workspace_id: picker.workspace_id.clone(),
            lease_owner: lease_owner.to_string(),
            now,
            lease_expires_at: now + 30,
        }
    }

    #[test]
    fn older_pages_preserve_indices_and_cursor_across_restart() {
        let state = tempfile::tempdir().expect("state");
        let workspace = tempfile::tempdir().expect("workspace");
        let path = state.path().join("bridge.sqlite");
        let store = BridgeStore::open(&path).expect("store");
        let mut picker = install_fixture(&store, workspace.path());
        picker.catalog_cursor = Some("page-2".to_string());
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        let SessionPickerClaimOutcome::LoadRequested(expected) = store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::LoadOlder { expected_count: 3 },
                &context(&picker, "load", 102),
            )
            .expect("claim")
        else {
            panic!("page request")
        };
        let new = SessionSummary::new(
            ProviderSessionRef::new(
                picker.sessions[0].session().provider().clone(),
                ProviderSessionId::new("older-session").expect("id"),
            )
            .expect("session"),
            picker.workspace_id.clone(),
            Some("Older session".to_string()),
            None,
            Some(0),
            SessionAvailability::Available,
        )
        .expect("summary");
        let updated = store
            .append_session_picker_sessions(
                &expected,
                &[picker.sessions[0].clone(), new.clone()],
                Some("page-3".into()),
                103,
            )
            .expect("append")
            .expect("updated");
        assert_eq!(&updated.sessions[..3], picker.sessions.as_slice());
        assert_eq!(updated.sessions[3], new);
        assert!(
            store
                .append_session_picker_sessions(&expected, &[], None, 104)
                .expect("duplicate")
                .is_none()
        );
        drop(store);
        let store = BridgeStore::open(&path).expect("reopen");
        let recovered = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        assert_eq!(recovered.sessions, updated.sessions);
        assert_eq!(recovered.catalog_cursor.as_deref(), Some("page-3"));
        // If the card edit failed after the durable append, its old button
        // redraws the persisted page instead of permanently stranding it.
        assert!(matches!(
            store.claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::LoadOlder { expected_count: 3 },
                &context(&picker, "redraw", 105),
            ).expect("stale card"),
            SessionPickerClaimOutcome::Navigated(record) if record == recovered
        ));
        let claim = store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 3 },
                &context(&picker, "open", 105),
            )
            .expect("open");
        assert!(matches!(claim, SessionPickerClaimOutcome::Claimed(record)
            if record.sessions[record.selected_index.expect("index")] == new));
    }

    #[test]
    fn older_page_claims_and_results_fail_closed_without_changing_the_picker() {
        let (store, mut picker, _workspace) = memory_fixture();
        picker.catalog_cursor = Some("page-2".into());
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        let expected = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        let mut unauthorized = context(&picker, "load", 102);
        unauthorized.actor_user_id = 999;
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::LoadOlder { expected_count: 3 },
                    &unauthorized
                )
                .expect("claim"),
            SessionPickerClaimOutcome::Unauthorized
        ));
        assert!(
            store
                .append_session_picker_sessions(
                    &expected,
                    &picker.sessions,
                    Some("page-2".into()),
                    102
                )
                .is_err()
        );
        let mut other = picker.sessions[0].clone();
        other = SessionSummary::new(
            other.session().clone(),
            WorkspaceId::new("wrong-workspace").expect("workspace"),
            None,
            None,
            None,
            SessionAvailability::Available,
        )
        .expect("summary");
        assert!(
            store
                .append_session_picker_sessions(&expected, &[other], None, 102)
                .is_err()
        );
        assert_eq!(
            store
                .session_picker(&picker.callback_token)
                .expect("read")
                .expect("picker"),
            expected
        );
        assert!(
            store
                .append_session_picker_sessions(&expected, &[], None, 201)
                .expect("expired")
                .is_none()
        );
    }

    #[test]
    fn duplicate_only_pages_advance_the_cursor_without_changing_open_targets() {
        let (store, mut picker, _workspace) = memory_fixture();
        picker.catalog_cursor = Some("page-2".into());
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        let expected = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        let updated = store
            .append_session_picker_sessions(&expected, &picker.sessions, Some("page-3".into()), 102)
            .expect("append")
            .expect("updated");
        assert_eq!(updated.sessions, expected.sessions);
        assert_eq!(updated.catalog_cursor.as_deref(), Some("page-3"));
        let exhausted = store
            .append_session_picker_sessions(&updated, &[], None, 103)
            .expect("exhaust")
            .expect("updated");
        assert_eq!(exhausted.sessions, expected.sessions);
        assert_eq!(exhausted.catalog_cursor, None);
    }

    #[test]
    fn busy_sessions_remain_visible_without_claiming_an_open() {
        let (store, mut picker, _workspace) = memory_fixture();
        picker.sessions[0] = SessionSummary::new(
            picker.sessions[0].session().clone(),
            picker.workspace_id.clone(),
            Some("Running work".into()),
            None,
            None,
            SessionAvailability::Active,
        )
        .expect("summary");
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 0 },
                    &context(&picker, "open", 102)
                )
                .expect("claim"),
            SessionPickerClaimOutcome::InvalidChoice
        ));
        let current = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        assert_eq!(current.state, SessionPickerState::Active);
        assert_eq!(current.sessions.len(), 3);
        assert!(current.selected_index.is_none());
    }

    #[test]
    fn picker_survives_store_reopen() {
        let state = tempfile::tempdir().expect("state");
        let workspace = tempfile::tempdir().expect("workspace");
        let database = state.path().join("bridge.sqlite");
        let picker = {
            let store = BridgeStore::open(&database).expect("store A");
            let picker = install_fixture(&store, workspace.path());
            assert!(store.insert_session_picker(&picker).expect("insert"));
            assert!(
                store
                    .attach_session_picker_message(&picker.callback_token, 13, 101)
                    .expect("attach")
            );
            picker
        };

        let store = BridgeStore::open(&database).expect("store B");
        let record = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        assert_eq!(record.state, SessionPickerState::Active);
        assert_eq!(record.sessions, picker.sessions);
    }

    #[test]
    fn duplicate_origin_recovers_the_first_publishing_operation() {
        let (store, picker, _workspace) = memory_fixture();
        assert!(store.insert_session_picker(&picker).expect("first insert"));
        let mut replay = picker.clone();
        replay.callback_token = "different-token".to_string();
        assert!(!store.insert_session_picker(&replay).expect("replay insert"));

        let recovered = store
            .session_picker_for_origin_event(&picker.installation_id, &picker.origin_event_id)
            .expect("origin lookup")
            .expect("publishing operation");
        assert_eq!(recovered.callback_token, picker.callback_token);
        assert_eq!(recovered.state, SessionPickerState::Publishing);
    }

    #[test]
    fn failed_publication_releases_capacity_but_a_committed_card_can_recover() {
        let (store, picker, _workspace) = memory_fixture();
        assert!(store.insert_session_picker(&picker).expect("insert"));
        assert!(
            store
                .record_session_picker_publication_failure(
                    &picker.callback_token,
                    "transport",
                    102,
                )
                .expect("record publication failure")
        );
        let record = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        assert_eq!(record.state, SessionPickerState::Publishing);
        assert_eq!(record.last_error.as_deref(), Some("transport"));
        let mut next = picker.clone();
        next.callback_token = "next-token".to_string();
        next.origin_event_id = "next-event".to_string();
        assert!(
            store
                .insert_session_picker(&next)
                .expect("released capacity")
        );
        assert!(
            store
                .attach_session_picker_message(&picker.callback_token, 13, 103)
                .expect("recover committed card")
        );
        assert_eq!(
            store
                .session_picker(&picker.callback_token)
                .expect("read recovered")
                .expect("picker")
                .state,
            SessionPickerState::Active
        );
        assert!(
            !store
                .record_session_picker_publication_failure(&picker.callback_token, "repeat", 104,)
                .expect("repeat")
        );
    }

    #[test]
    fn published_card_can_attach_from_its_first_callback() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");

        let outcome = store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Page { page: 0 },
                &context(&picker, "page-event", 110),
            )
            .expect("claim");

        let SessionPickerClaimOutcome::Navigated(record) = outcome else {
            panic!("expected navigation");
        };
        assert_eq!(record.picker_message_id, Some(13));
    }

    #[test]
    fn duplicate_open_is_single_flight_and_expired_lease_resumes() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 1 },
                    &context(&picker, "lease-1", 110),
                )
                .expect("first"),
            SessionPickerClaimOutcome::Claimed(_)
        ));
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 1 },
                    &context(&picker, "lease-1", 111),
                )
                .expect("same-owner duplicate"),
            SessionPickerClaimOutcome::InProgress(_)
        ));
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 1 },
                    &context(&picker, "lease-2", 111),
                )
                .expect("duplicate"),
            SessionPickerClaimOutcome::InProgress(_)
        ));
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 1 },
                    &context(&picker, "lease-3", 141),
                )
                .expect("resume"),
            SessionPickerClaimOutcome::Resumable(_)
        ));
    }

    #[test]
    fn failure_retries_and_completion_is_terminal() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 2 },
                &context(&picker, "lease-1", 110),
            )
            .expect("claim");
        assert!(
            store
                .update_session_picker_open_progress(
                    &picker.callback_token,
                    "lease-1",
                    Some(20),
                    None,
                    None,
                    110,
                )
                .expect("progress")
        );
        assert!(
            store
                .retry_session_picker_open(&picker.callback_token, "lease-1", "network", 111)
                .expect("retryable")
        );
        for action in [
            SessionPickerAction::Page { page: 0 },
            SessionPickerAction::LoadOlder { expected_count: 3 },
            SessionPickerAction::Open { index: 0 },
        ] {
            assert!(matches!(
                store.claim_session_picker(&picker.callback_token, action, &context(&picker, "stale-card", 112)).expect("redraw"),
                SessionPickerClaimOutcome::Navigated(record)
                    if record.state == SessionPickerState::Retryable
                        && record.selected_index == Some(2)
                        && record.thread_chat_id == Some(20)
            ));
        }
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 2 },
                    &context(&picker, "lease-2", 112),
                )
                .expect("retry"),
            SessionPickerClaimOutcome::Claimed(_)
        ));
        assert!(
            store
                .complete_session_picker_open(
                    &picker.callback_token,
                    "lease-2",
                    SessionPickerCompletion {
                        thread_chat_id: 20,
                        agent_session_id: 30,
                        status_message_id: 40,
                        status_pinned: false,
                        completed_at: 113,
                    },
                )
                .expect("complete")
        );
        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 2 },
                    &context(&picker, "lease-3", 114),
                )
                .expect("terminal"),
            SessionPickerClaimOutcome::Completed(_)
        ));
        let repairs = store
            .session_picker_projection_repairs(&picker.installation_id)
            .expect("projection repair debt");
        assert_eq!(repairs.len(), 1);
        assert!(!repairs[0].terminal_projected);
        assert!(!repairs[0].status_pinned);
        assert!(
            store
                .mark_session_picker_status_pinned(&picker.callback_token, 114)
                .expect("pin repaired")
        );
        assert_eq!(
            store
                .session_picker_projection_repairs(&picker.installation_id)
                .expect("card repair remains")
                .len(),
            1
        );
        assert!(
            store
                .mark_session_picker_terminal_projected(&picker.callback_token, 115)
                .expect("card repaired")
        );
        assert!(
            store
                .session_picker_projection_repairs(&picker.installation_id)
                .expect("all projection debt cleared")
                .is_empty()
        );
    }

    #[test]
    fn pre_connect_thread_checkpoint_can_follow_a_canonical_retry_binding() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&picker, "lease-1", 110),
            )
            .expect("claim");
        assert!(
            store
                .update_session_picker_open_progress(
                    &picker.callback_token,
                    "lease-1",
                    Some(20),
                    None,
                    None,
                    111,
                )
                .expect("initial target")
        );
        assert!(
            store
                .reconcile_session_picker_open_thread(
                    &picker.callback_token,
                    "lease-1",
                    20,
                    21,
                    112,
                )
                .expect("canonical target")
        );
        assert_eq!(
            store
                .session_picker(&picker.callback_token)
                .expect("read")
                .expect("picker")
                .thread_chat_id,
            Some(21)
        );

        assert!(
            store
                .update_session_picker_open_progress(
                    &picker.callback_token,
                    "lease-1",
                    Some(21),
                    Some(30),
                    None,
                    113,
                )
                .expect("server identity")
        );
        assert!(
            !store
                .reconcile_session_picker_open_thread(
                    &picker.callback_token,
                    "lease-1",
                    21,
                    22,
                    114,
                )
                .expect("identity is immutable after connect")
        );
        assert!(
            !store
                .complete_session_picker_open(
                    &picker.callback_token,
                    "lease-1",
                    SessionPickerCompletion {
                        thread_chat_id: 22,
                        agent_session_id: 30,
                        status_message_id: 40,
                        status_pinned: false,
                        completed_at: 115,
                    },
                )
                .expect("conflicting completion")
        );
        let retained = store
            .session_picker(&picker.callback_token)
            .expect("read retained checkpoint")
            .expect("picker");
        assert_eq!(retained.state, SessionPickerState::Opening);
        assert_eq!(retained.thread_chat_id, Some(21));
        assert_eq!(retained.agent_session_id, Some(30));
    }

    #[test]
    fn startup_recovery_reclaims_a_live_lease_once_old_tasks_are_gone() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&picker, "old-process-lease", 110),
            )
            .expect("claim");
        assert_eq!(
            store
                .recover_session_pickers(&picker.installation_id, 111)
                .expect("process restart recovery"),
            1
        );
        let recovered = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        assert_eq!(recovered.state, SessionPickerState::Retryable);
        assert!(recovered.lease_owner.is_none());
        assert_eq!(
            store
                .session_picker_recovery_cards(&picker.installation_id)
                .expect("retryable recovery card")
                .len(),
            1
        );
    }

    #[test]
    fn startup_recovery_releases_stale_lease_without_losing_progress() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&picker, "lease-1", 110),
            )
            .expect("claim");
        store
            .update_session_picker_open_progress(
                &picker.callback_token,
                "lease-1",
                Some(20),
                Some(30),
                None,
                111,
            )
            .expect("progress");
        assert!(
            !store
                .update_session_picker_open_progress(
                    &picker.callback_token,
                    "lease-1",
                    Some(20),
                    Some(30),
                    Some(40),
                    141,
                )
                .expect("expired progress lease")
        );
        assert!(
            !store
                .complete_session_picker_open(
                    &picker.callback_token,
                    "lease-1",
                    SessionPickerCompletion {
                        thread_chat_id: 20,
                        agent_session_id: 30,
                        status_message_id: 40,
                        status_pinned: false,
                        completed_at: 141,
                    },
                )
                .expect("expired completion lease")
        );

        assert_eq!(
            store
                .recover_session_pickers(&picker.installation_id, 141)
                .expect("recover"),
            1
        );
        let recovered = store
            .session_picker(&picker.callback_token)
            .expect("read")
            .expect("picker");
        assert_eq!(recovered.state, SessionPickerState::Retryable);
        assert_eq!(recovered.thread_chat_id, Some(20));
        assert_eq!(recovered.agent_session_id, Some(30));
        assert!(recovered.lease_owner.is_none());
    }

    #[test]
    fn expired_partial_open_fails_closed_after_its_opening_lease_ends() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&picker, "lease-1", 190),
            )
            .expect("claim");
        assert!(
            store
                .update_session_picker_open_progress(
                    &picker.callback_token,
                    "lease-1",
                    Some(20),
                    None,
                    None,
                    191,
                )
                .expect("thread checkpoint")
        );

        assert!(matches!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 1 },
                    &context(&picker, "lease-2", 221),
                )
                .expect("expired claim"),
            SessionPickerClaimOutcome::Failed(_)
        ));
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 221)
                .expect("failed thread gate"),
            SessionPickerThreadGate::Failed
        );
        assert_eq!(
            store
                .session_picker_recovery_cards(&picker.installation_id)
                .expect("failed recovery card")
                .len(),
            1
        );
        assert!(
            store
                .mark_session_picker_terminal_projected(&picker.callback_token, 222)
                .expect("failed card projected")
        );
        assert!(
            store
                .session_picker_recovery_cards(&picker.installation_id)
                .expect("failed recovery debt cleared")
                .is_empty()
        );
    }

    #[test]
    fn abandoned_open_never_falls_through_to_ordinary_turn_admission() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&picker, "lease-1", 110),
            )
            .expect("claim");
        assert!(
            store
                .update_session_picker_open_progress(
                    &picker.callback_token,
                    "lease-1",
                    Some(20),
                    None,
                    None,
                    111,
                )
                .expect("thread checkpoint")
        );
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 111)
                .expect("live block"),
            SessionPickerThreadGate::Opening
        );
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 141)
                .expect("retryable block"),
            SessionPickerThreadGate::Opening
        );
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 201)
                .expect("failed gate"),
            SessionPickerThreadGate::Failed
        );
        assert_eq!(
            store
                .session_picker(&picker.callback_token)
                .expect("picker")
                .expect("record")
                .state,
            SessionPickerState::Failed
        );
    }

    #[test]
    fn publication_recovery_survives_failed_commands_and_repairs_active_cards() {
        let (store, picker, _workspace) = memory_fixture();
        let binding = BindingKey {
            installation_id: picker.installation_id.clone(),
            chat_id: picker.chat_id,
            workspace_id: picker.workspace_id.clone(),
        };
        store
            .accept_inbound(&InboundRecord {
                event_id: picker.origin_event_id.clone(),
                binding,
                message_id: 12,
                delivery_chat_id: picker.chat_id,
                sender_user_id: picker.owner_user_id,
                direction: Direction::new(DirectionId::new("picker-command").unwrap(), "/sessions"),
                state: InboundState::Accepted,
                accepted_at: 100,
                started_at: None,
                lease_expires_at: None,
                attempt_count: 0,
                provider_turn_id: None,
                stream_message_id: None,
                failure: None,
            })
            .expect("accept command");
        store
            .start_inbound(&picker.origin_event_id, 100)
            .expect("start");
        store.insert_session_picker(&picker).expect("insert");
        store
            .stage_inbound_final_send(
                &picker.origin_event_id,
                InboundState::Failed,
                "Run /sessions again.",
                Some("publication interrupted"),
            )
            .expect("stage failure notice");
        assert!(
            store
                .recoverable_session_picker_commands(&picker.installation_id)
                .expect("pending notice must keep journal ownership")
                .is_empty()
        );
        assert_eq!(
            store
                .pending_inbound_final_sends(&picker.installation_id)
                .unwrap()
                .len(),
            1
        );
        store
            .commit_inbound_final_send(&picker.origin_event_id)
            .expect("confirm failure notice");
        let recovery = store
            .recoverable_session_picker_commands(&picker.installation_id)
            .expect("recovery");
        assert_eq!(recovery.len(), 1);
        assert_eq!(recovery[0].state, SessionPickerState::Publishing);
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        let recovery = store
            .recoverable_session_picker_commands(&picker.installation_id)
            .expect("active repair");
        assert_eq!(recovery.len(), 1);
        assert_eq!(recovery[0].state, SessionPickerState::Active);
    }

    #[test]
    fn expired_unpublished_picker_keeps_its_command_for_durable_interruption() {
        let (store, picker, _workspace) = memory_fixture();
        store
            .accept_inbound(&InboundRecord {
                event_id: picker.origin_event_id.clone(),
                binding: BindingKey {
                    installation_id: picker.installation_id.clone(),
                    chat_id: picker.chat_id,
                    workspace_id: picker.workspace_id.clone(),
                },
                message_id: 12,
                delivery_chat_id: picker.chat_id,
                sender_user_id: picker.owner_user_id,
                direction: Direction::new(DirectionId::new("expired-picker").unwrap(), "/sessions"),
                state: InboundState::Accepted,
                accepted_at: 100,
                started_at: None,
                lease_expires_at: None,
                attempt_count: 0,
                provider_turn_id: None,
                stream_message_id: None,
                failure: None,
            })
            .expect("accept command");
        store
            .start_inbound(&picker.origin_event_id, 100)
            .expect("start");
        store.insert_session_picker(&picker).expect("insert");
        store
            .recover_session_pickers(&picker.installation_id, picker.expires_at)
            .expect("expire");
        assert!(
            store
                .recoverable_session_picker_commands(&picker.installation_id)
                .expect("recoverable")
                .is_empty()
        );
        assert_eq!(
            store
                .get_inbound(&picker.origin_event_id)
                .unwrap()
                .unwrap()
                .state,
            InboundState::Started
        );
        store
            .stage_interrupted_inbound_for_installation(
                &picker.installation_id,
                "interrupted",
                "Run /sessions again.",
            )
            .expect("stage interruption");
        let pending = store
            .pending_inbound_final_sends(&picker.installation_id)
            .unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].event_id, picker.origin_event_id);
        assert_eq!(pending[0].state, InboundState::Failed);
    }

    #[test]
    fn latest_picker_operation_controls_the_thread_gate() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert old");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach old");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&picker, "old", 110),
            )
            .expect("claim old");
        assert!(
            store
                .complete_session_picker_open(
                    &picker.callback_token,
                    "old",
                    SessionPickerCompletion {
                        thread_chat_id: 20,
                        agent_session_id: 30,
                        status_message_id: 40,
                        status_pinned: true,
                        completed_at: 111,
                    }
                )
                .expect("complete old")
        );
        let mut newer = picker.clone();
        newer.callback_token = "newer-token".to_string();
        newer.origin_event_id = "newer-event".to_string();
        newer.created_at = 112;
        store.insert_session_picker(&newer).expect("insert newer");
        store
            .attach_session_picker_message(&newer.callback_token, 13, 113)
            .expect("attach newer");
        store
            .claim_session_picker(
                &newer.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&newer, "newer", 114),
            )
            .expect("claim newer");
        store
            .update_session_picker_open_progress(
                &newer.callback_token,
                "newer",
                Some(20),
                None,
                None,
                115,
            )
            .expect("checkpoint newer");
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 116)
                .expect("opening"),
            SessionPickerThreadGate::Opening
        );
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 145)
                .expect("retryable"),
            SessionPickerThreadGate::Opening
        );
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 201)
                .expect("failed"),
            SessionPickerThreadGate::Failed
        );
        // A later presentation repair of an older completed operation must not
        // change which operation owns admission.
        store
            .mark_session_picker_terminal_projected(&picker.callback_token, 202)
            .expect("repair old");
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 20, 203)
                .expect("still failed"),
            SessionPickerThreadGate::Failed
        );
        assert_eq!(
            store
                .session_picker_thread_gate(&picker.installation_id, 21, 203)
                .expect("unrelated thread"),
            SessionPickerThreadGate::Ready
        );
    }

    #[test]
    fn guarded_inbound_claim_and_picker_checkpoint_are_one_decision() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        store
            .claim_session_picker(
                &picker.callback_token,
                SessionPickerAction::Open { index: 1 },
                &context(&picker, "lease-1", 110),
            )
            .expect("claim");
        store
            .update_session_picker_open_progress(
                &picker.callback_token,
                "lease-1",
                Some(20),
                None,
                None,
                111,
            )
            .expect("target checkpoint");
        let binding = BindingKey {
            installation_id: picker.installation_id.clone(),
            chat_id: 20,
            workspace_id: picker.workspace_id.clone(),
        };
        let inbound = InboundRecord {
            event_id: "event-guarded".to_string(),
            binding: binding.clone(),
            message_id: 50,
            delivery_chat_id: 20,
            sender_user_id: 7,
            direction: Direction::new(
                DirectionId::new("direction-guarded").expect("direction"),
                "continue",
            ),
            state: InboundState::Accepted,
            accepted_at: 111,
            started_at: None,
            lease_expires_at: None,
            attempt_count: 0,
            provider_turn_id: None,
            stream_message_id: None,
            failure: None,
        };
        assert!(store.accept_inbound(&inbound).expect("accept inbound"));
        assert!(
            store
                .take_next_inbound_if_session_ready(&binding, 112)
                .expect("guarded claim")
                .is_none()
        );
        assert!(
            store
                .complete_session_picker_open(
                    &picker.callback_token,
                    "lease-1",
                    SessionPickerCompletion {
                        thread_chat_id: 20,
                        agent_session_id: 30,
                        status_message_id: 40,
                        status_pinned: true,
                        completed_at: 113,
                    },
                )
                .expect("complete picker")
        );
        assert_eq!(
            store
                .take_next_inbound_if_session_ready(&binding, 114)
                .expect("ready claim")
                .expect("claimed inbound")
                .event_id,
            inbound.event_id
        );
    }

    #[test]
    fn claim_enforces_owner_and_workspace() {
        let (store, picker, _workspace) = memory_fixture();
        store.insert_session_picker(&picker).expect("insert");
        store
            .attach_session_picker_message(&picker.callback_token, 13, 101)
            .expect("attach");
        let mut outsider = context(&picker, "lease-1", 110);
        outsider.actor_user_id = 99;
        assert_eq!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 0 },
                    &outsider,
                )
                .expect("outsider"),
            SessionPickerClaimOutcome::Unauthorized
        );
        let mut wrong_workspace = context(&picker, "lease-2", 110);
        wrong_workspace.workspace_id = WorkspaceId::new("other").expect("workspace");
        assert_eq!(
            store
                .claim_session_picker(
                    &picker.callback_token,
                    SessionPickerAction::Open { index: 0 },
                    &wrong_workspace,
                )
                .expect("wrong context"),
            SessionPickerClaimOutcome::WrongContext
        );
    }
}

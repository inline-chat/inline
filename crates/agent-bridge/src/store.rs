use std::collections::HashSet;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, MAIN_DB, OpenFlags, OptionalExtension, params};
use thiserror::Error;

use crate::{
    BindingKey, Direction, DirectionId, ProviderId, ProviderSessionId, QueueItemId, TurnId,
};

mod approval;
mod command_choice;
mod history_import;
mod host_tool;
mod inbound_scan;
mod operator_allowlist;
#[path = "store/finalization.rs"]
mod pending_final_send;
#[path = "store/progress.rs"]
mod progress;
mod question;
#[path = "store/rejection.rs"]
mod rejection;
mod reply_threads;
mod session_picker;
mod session_thread;
mod settings;
mod workspace;

pub use approval::{
    ApprovalClaim, ApprovalClaimContext, ApprovalClaimOutcome, ApprovalRecord, ApprovalState,
    PendingApproval,
};
pub use command_choice::{
    CommandChoiceAction, CommandChoiceClaimContext, CommandChoiceClaimOutcome,
    CommandChoiceRequest, CommandChoiceState, PendingCommandChoiceRequest,
};
pub use history_import::HistoryImportState;
pub use host_tool::{HostToolCallClaim, HostToolCallRecord};
pub use inbound_scan::InboundUndoOutcome;
pub use operator_allowlist::{
    OperatorAllowlistClaimContext, OperatorAllowlistClaimOutcome, OperatorAllowlistDecision,
    OperatorAllowlistRequest, OperatorAllowlistState, PendingOperatorAllowlistRequest,
};
pub use pending_final_send::{PendingAgentOutputLink, PendingFinalSend};
pub use progress::DurableProgress;
pub use question::{
    PendingQuestion, QuestionClaimContext, QuestionClaimLocator, QuestionClaimOutcome,
    QuestionRecord, QuestionResolution, QuestionState,
};
pub use reply_threads::{ReplyThreadMode, ReplyThreadOverride, ReplyThreadOverrideUpdateOutcome};
pub use session_picker::{
    MAX_ACTIVE_SESSION_PICKERS, MAX_SESSION_PICKER_ITEMS, PendingSessionPicker,
    SESSION_PICKER_PAGE_SIZE, SessionPickerAction, SessionPickerClaimContext,
    SessionPickerClaimOutcome, SessionPickerCompletion, SessionPickerRecord, SessionPickerState,
    SessionPickerThreadGate,
};
pub use session_thread::{
    SessionThreadBindOutcome, SessionThreadBinding, SessionThreadOpening,
    SessionThreadPrepareOutcome,
};
pub use settings::{ChatSettingsRecord, SettingsUpdateOutcome};
pub use workspace::{
    InstallationRecord, MAX_RECENT_WORKSPACES, WorkspaceChoice, WorkspaceFilesystemIdentity,
    WorkspaceRecord,
};

const CURRENT_SCHEMA_VERSION: i64 = 30;
const DEFAULT_QUEUE_LEASE_SECONDS: i64 = 300;
const DEFAULT_INBOUND_LEASE_SECONDS: i64 = 300;

pub type StoreResult<T> = Result<T, StoreError>;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("bridge state I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("bridge state database error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("bridge state migration backup {path} has schema {found}, expected schema {expected}")]
    InvalidMigrationBackup {
        path: String,
        found: i64,
        expected: i64,
    },
    #[error("bridge state migration backup {path} failed integrity check: {result}")]
    InvalidMigrationBackupIntegrity { path: String, result: String },
    #[error("bridge state serialization error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("bridge state contains an invalid {kind}: {value}")]
    InvalidIdentifier { kind: &'static str, value: String },
    #[error("bridge state contains an unknown queue state: {0}")]
    UnknownQueueState(String),
    #[error("bridge state contains an unknown inbound state: {0}")]
    UnknownInboundState(String),
    #[error("bridge state cannot stage non-terminal inbound state: {0}")]
    InvalidInboundFinalState(String),
    #[error("bridge terminal message is empty")]
    InvalidInboundFinalText,
    #[error(
        "bridge terminal message uses {actual_bytes} bytes, exceeding the {limit_bytes}-byte durable limit"
    )]
    InboundFinalTextBytesExceeded {
        actual_bytes: usize,
        limit_bytes: usize,
    },
    #[error(
        "bridge terminal message uses {actual_utf16} UTF-16 units, exceeding the {limit_utf16}-unit Inline limit"
    )]
    InboundFinalTextUtf16Exceeded {
        actual_utf16: usize,
        limit_utf16: usize,
    },
    #[error(
        "bridge terminal output has {actual_count} attachments, exceeding the {limit_count}-attachment durable limit"
    )]
    InboundOutputAttachmentCountExceeded {
        actual_count: usize,
        limit_count: usize,
    },
    #[error(
        "bridge terminal output attachment metadata uses {actual_bytes} bytes, exceeding the {limit_bytes}-byte durable limit"
    )]
    InboundOutputAttachmentBytesExceeded {
        actual_bytes: usize,
        limit_bytes: usize,
    },
    #[error("provider turn has conflicting terminal Inline message identities")]
    AmbiguousInboundTerminalIdentity,
    #[error("bridge progress ledger is empty")]
    InvalidProgressLedger,
    #[error(
        "bridge progress ledger uses {actual_bytes} bytes, exceeding the {limit_bytes}-byte durable limit"
    )]
    ProgressLedgerBytesExceeded {
        actual_bytes: usize,
        limit_bytes: usize,
    },
    #[error("bridge state contains an unknown approval state: {0}")]
    UnknownApprovalState(String),
    #[error("bridge state contains an unknown question state: {0}")]
    UnknownQuestionState(String),
    #[error("bridge state contains an unknown operator allowlist state: {0}")]
    UnknownOperatorAllowlistState(String),
    #[error("bridge state contains an unknown command choice state: {0}")]
    UnknownCommandChoiceState(String),
    #[error("bridge state contains an unknown history import state: {0}")]
    UnknownHistoryImportState(String),
    #[error("bridge state contains an unknown session picker state: {0}")]
    UnknownSessionPickerState(String),
    #[error("history import thread {chat_id} is already owned by another import")]
    HistoryImportConflict { chat_id: i64 },
    #[error("bridge state contains an unknown reply-thread mode: {0}")]
    UnknownReplyThreadMode(String),
    #[error("reply-thread settings require a positive chat ID")]
    InvalidReplyThreadScope,
    #[error("provider session reply-thread binding is invalid")]
    InvalidSessionThreadBinding,
    #[error("provider session reply-thread opening conflicts with existing durable state")]
    SessionThreadOpeningConflict,
    #[error("provider session reply-thread opening is no longer available")]
    SessionThreadOpeningUnavailable,
    #[error("Inline reply thread {thread_chat_id} is already bound to another provider session")]
    SessionThreadBindingConflict { thread_chat_id: i64 },
    #[error("invalid workspace path {path}: {reason}")]
    InvalidWorkspacePath { path: String, reason: &'static str },
    #[error("workspace path {path} is already registered with another opaque ID")]
    WorkspaceIdentityConflict { path: String },
    #[error("workspace {workspace_id} is no longer available")]
    WorkspaceUnavailable { workspace_id: String },
    #[error("invalid {kind} display metadata")]
    InvalidDisplayMetadata { kind: &'static str },
    #[error("invalid {kind} setting value")]
    InvalidSettingValue { kind: &'static str },
    #[error("invalid settings revision {revision}")]
    InvalidSettingsRevision { revision: i64 },
    #[error("settings are missing for {installation_id}/{chat_id}/{workspace_id}")]
    MissingSettings {
        installation_id: String,
        chat_id: i64,
        workspace_id: String,
    },
    #[error("bridge state schema version {found} is newer than this bridge supports ({supported})")]
    UnsupportedSchemaVersion { found: i64, supported: i64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueueState {
    Pending,
    Started,
    Completed,
    Failed,
    Removed,
}

impl QueueState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Started => "started",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Removed => "removed",
        }
    }

    #[cfg(test)]
    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "pending" => Ok(Self::Pending),
            "started" => Ok(Self::Started),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "removed" => Ok(Self::Removed),
            _ => Err(StoreError::UnknownQueueState(value)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueueRecord {
    pub queue_id: QueueItemId,
    pub binding: BindingKey,
    pub direction: Direction,
    pub state: QueueState,
    pub created_at: i64,
    pub started_at: Option<i64>,
    pub lease_expires_at: Option<i64>,
    pub attempt_count: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InboundState {
    Accepted,
    Started,
    Completed,
    Failed,
}

impl InboundState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Started => "started",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }

    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "accepted" => Ok(Self::Accepted),
            "started" => Ok(Self::Started),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            _ => Err(StoreError::UnknownInboundState(value)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InboundRecord {
    pub event_id: String,
    pub binding: BindingKey,
    pub message_id: i64,
    pub delivery_chat_id: i64,
    pub sender_user_id: i64,
    pub direction: Direction,
    pub state: InboundState,
    pub accepted_at: i64,
    pub started_at: Option<i64>,
    pub lease_expires_at: Option<i64>,
    pub attempt_count: i64,
    pub provider_turn_id: Option<TurnId>,
    pub stream_message_id: Option<i64>,
    pub failure: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InterruptedInbound {
    pub event_id: String,
    pub binding: BindingKey,
    pub message_id: i64,
    pub delivery_chat_id: i64,
    pub stream_message_id: Option<i64>,
}

pub struct BridgeStore {
    connection: Mutex<Connection>,
}

impl std::fmt::Debug for BridgeStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BridgeStore")
            .field("connection", &"<sqlite>")
            .finish()
    }
}

impl BridgeStore {
    pub fn open(path: impl AsRef<Path>) -> StoreResult<Self> {
        let path = path.as_ref();
        prepare_private_file(path)?;
        let _migration_lock = acquire_migration_lock(path)?;
        let connection = Connection::open(path)?;
        prepare_migration_backup(path, &connection)?;
        Self::from_connection(connection)
    }

    pub fn open_in_memory() -> StoreResult<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> StoreResult<Self> {
        migrate(&connection)?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    pub fn claim_event(&self, event_id: &str, accepted_at: i64) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "INSERT OR IGNORE INTO processed_events (event_id, accepted_at) VALUES (?1, ?2)",
            params![event_id, accepted_at],
        )?;
        Ok(changed == 1)
    }

    pub fn event_processed(&self, event_id: &str) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM processed_events WHERE event_id = ?1)",
                params![event_id],
                |row| row.get(0),
            )
            .map_err(StoreError::from)
    }

    /// Atomically accepts an Inline direction into the durable work inbox.
    ///
    /// The host may acknowledge the corresponding lossless Inline delivery
    /// only after this method succeeds. Duplicate event IDs or stable Inline
    /// message identities are not inserted.
    pub fn accept_inbound(&self, record: &InboundRecord) -> StoreResult<bool> {
        self.accept_inbound_inner(record, false)
    }

    /// Accepts an explicit handoff and cancels earlier queued work in this
    /// conversation atomically. Retains every record and leaves running work,
    /// other conversations, and later user input untouched.
    pub fn accept_session_handoff(&self, record: &InboundRecord) -> StoreResult<bool> {
        self.accept_inbound_inner(record, true)
    }

    fn accept_inbound_inner(
        &self,
        record: &InboundRecord,
        cancel_earlier_pending: bool,
    ) -> StoreResult<bool> {
        let attachments_json = serde_json::to_string(&record.direction.attachments)?;
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let already_processed = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM processed_events WHERE event_id = ?1)",
            params![record.event_id],
            |row| row.get::<_, bool>(0),
        )?;
        if already_processed {
            transaction.commit()?;
            return Ok(false);
        }
        let duplicate_message = transaction.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM inbound_directions
                WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                  AND message_id = ?4 AND sender_user_id = ?5
             )",
            params![
                record.binding.installation_id.as_str(),
                record.binding.chat_id,
                record.binding.workspace_id.as_str(),
                record.message_id,
                record.sender_user_id,
            ],
            |row| row.get::<_, bool>(0),
        )?;
        if duplicate_message {
            transaction.commit()?;
            return Ok(false);
        }
        let changed = transaction.execute(
            "INSERT OR IGNORE INTO inbound_directions (
                event_id, installation_id, chat_id, workspace_id, message_id,
                delivery_chat_id, sender_user_id, direction_id, direction_text,
                direction_attachments_json, state, accepted_at,
                started_at, lease_expires_at, attempt_count, provider_turn_id,
                stream_message_id, failure, ingest_order
             ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                ?14, ?15, ?16, ?17, ?18,
                (SELECT COALESCE(MAX(ingest_order), 0) + 1 FROM inbound_directions)
             )",
            params![
                record.event_id,
                record.binding.installation_id.as_str(),
                record.binding.chat_id,
                record.binding.workspace_id.as_str(),
                record.message_id,
                record.delivery_chat_id,
                record.sender_user_id,
                record.direction.id.as_str(),
                record.direction.text,
                attachments_json,
                record.state.as_str(),
                record.accepted_at,
                record.started_at,
                record.lease_expires_at,
                record.attempt_count,
                record.provider_turn_id.as_ref().map(TurnId::as_str),
                record.stream_message_id,
                record.failure,
            ],
        )?;
        if changed == 1 {
            if cancel_earlier_pending {
                transaction.execute(
                    "UPDATE inbound_directions SET state = 'failed',
                        failure = 'cancelled for session handoff'
                     WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                       AND state = 'accepted' AND terminal_state IS NULL
                       AND ingest_order < (
                           SELECT ingest_order FROM inbound_directions WHERE event_id = ?4
                       )",
                    params![
                        record.binding.installation_id.as_str(),
                        record.binding.chat_id,
                        record.binding.workspace_id.as_str(),
                        record.event_id,
                    ],
                )?;
            }
            transaction.execute(
                "INSERT OR IGNORE INTO processed_events (event_id, accepted_at) VALUES (?1, ?2)",
                params![record.event_id, record.accepted_at],
            )?;
        }
        transaction.commit()?;
        Ok(changed == 1)
    }

    /// Monotonically fills attachments that arrived after an inbound message
    /// was durably accepted but before its queued turn started.
    ///
    /// Inline can deliver the same stored message once before its media URL is
    /// hydrated and again after hydration. Never replace an existing
    /// descriptor set: the first non-empty set remains the durable source of
    /// truth, and started or terminal work is immutable.
    pub fn enrich_accepted_inbound_attachments(&self, record: &InboundRecord) -> StoreResult<bool> {
        if record.direction.attachments.is_empty() {
            return Ok(false);
        }
        let attachments_json = serde_json::to_string(&record.direction.attachments)?;
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions
             SET direction_attachments_json = ?1
             WHERE event_id = ?2
               AND installation_id = ?3 AND chat_id = ?4 AND workspace_id = ?5
               AND message_id = ?6 AND delivery_chat_id = ?7 AND sender_user_id = ?8
               AND direction_id = ?9 AND direction_text = ?10
               AND state = 'accepted' AND direction_attachments_json = '[]'",
            params![
                attachments_json,
                record.event_id,
                record.binding.installation_id.as_str(),
                record.binding.chat_id,
                record.binding.workspace_id.as_str(),
                record.message_id,
                record.delivery_chat_id,
                record.sender_user_id,
                record.direction.id.as_str(),
                record.direction.text,
            ],
        )?;
        Ok(changed == 1)
    }

    pub fn get_inbound(&self, event_id: &str) -> StoreResult<Option<InboundRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let raw = connection
            .query_row(
                "SELECT installation_id, chat_id, workspace_id, message_id,
                        delivery_chat_id, sender_user_id, direction_id, direction_text,
                        direction_attachments_json, state,
                        accepted_at, started_at, lease_expires_at, attempt_count,
                        provider_turn_id, stream_message_id, failure
                 FROM inbound_directions WHERE event_id = ?1",
                params![event_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, String>(8)?,
                        row.get::<_, String>(9)?,
                        row.get::<_, i64>(10)?,
                        row.get::<_, Option<i64>>(11)?,
                        row.get::<_, Option<i64>>(12)?,
                        row.get::<_, i64>(13)?,
                        row.get::<_, Option<String>>(14)?,
                        row.get::<_, Option<i64>>(15)?,
                        row.get::<_, Option<String>>(16)?,
                    ))
                },
            )
            .optional()?;
        let Some((
            installation_id,
            chat_id,
            workspace_id,
            message_id,
            delivery_chat_id,
            sender_user_id,
            direction_id,
            direction_text,
            direction_attachments_json,
            state,
            accepted_at,
            started_at,
            lease_expires_at,
            attempt_count,
            provider_turn_id,
            stream_message_id,
            failure,
        )) = raw
        else {
            return Ok(None);
        };
        Ok(Some(InboundRecord {
            event_id: event_id.to_string(),
            binding: BindingKey {
                installation_id: parse_installation_id(installation_id)?,
                chat_id,
                workspace_id: parse_workspace_id(workspace_id)?,
            },
            message_id,
            delivery_chat_id,
            sender_user_id,
            direction: Direction::new(parse_direction_id(direction_id)?, direction_text)
                .with_attachments(serde_json::from_str(&direction_attachments_json)?),
            state: InboundState::parse(state)?,
            accepted_at,
            started_at,
            lease_expires_at,
            attempt_count,
            provider_turn_id: provider_turn_id.map(parse_turn_id).transpose()?,
            stream_message_id,
            failure,
        }))
    }

    /// Confirms that one provider-returned client direction originated from
    /// this exact Inline conversation. Provider client IDs are not globally
    /// trustworthy across reinstalls or other bridge instances.
    pub fn inbound_direction_belongs_to_binding(
        &self,
        binding: &BindingKey,
        direction_id: &DirectionId,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        Ok(connection.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM inbound_directions
                WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                  AND direction_id = ?4
             )",
            params![
                binding.installation_id.as_str(),
                binding.chat_id,
                binding.workspace_id.as_str(),
                direction_id.as_str(),
            ],
            |row| row.get::<_, bool>(0),
        )?)
    }

    pub fn inbound_for_provider_turn(
        &self,
        turn_id: &TurnId,
    ) -> StoreResult<Option<InboundRecord>> {
        let event_id = {
            let connection = self.connection.lock().expect("bridge store poisoned");
            connection
                .query_row(
                    "SELECT event_id FROM inbound_directions
                     WHERE provider_turn_id = ?1 AND state = 'started'
                     ORDER BY ingest_order DESC LIMIT 1",
                    params![turn_id.as_str()],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
        };
        event_id
            .as_deref()
            .map(|event_id| self.get_inbound(event_id))
            .transpose()
            .map(Option::flatten)
    }

    /// Returns one unambiguous completed Inline direction whose provider turn,
    /// binding, delivery thread, and normalized input text all match history.
    /// Legacy session-history adoption deliberately fails closed when more
    /// than one local direction could own the provider item.
    pub fn completed_inbound_for_provider_turn_input(
        &self,
        turn_id: &TurnId,
        binding: &BindingKey,
        direction_text: &str,
    ) -> StoreResult<Option<InboundRecord>> {
        let event_ids = {
            let connection = self.connection.lock().expect("bridge store poisoned");
            let mut statement = connection.prepare(
                "SELECT event_id FROM inbound_directions
                 WHERE provider_turn_id = ?1 AND state = 'completed'
                   AND installation_id = ?2 AND chat_id = ?3 AND workspace_id = ?4
                   AND delivery_chat_id = ?3 AND direction_text = ?5
                 ORDER BY ingest_order ASC LIMIT 2",
            )?;
            statement
                .query_map(
                    params![
                        turn_id.as_str(),
                        binding.installation_id.as_str(),
                        binding.chat_id,
                        binding.workspace_id.as_str(),
                        direction_text,
                    ],
                    |row| row.get::<_, String>(0),
                )?
                .collect::<Result<Vec<_>, _>>()?
        };
        let [event_id] = event_ids.as_slice() else {
            return Ok(None);
        };
        self.get_inbound(event_id)
    }

    /// Returns the one stable terminal Inline identity for a completed provider
    /// turn and binding, even when later steering directions share that turn.
    pub fn completed_terminal_random_id_for_provider_turn(
        &self,
        turn_id: &TurnId,
        binding: &BindingKey,
    ) -> StoreResult<Option<i64>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let mut statement = connection.prepare(
            "SELECT DISTINCT terminal_random_id FROM inbound_directions
             WHERE provider_turn_id = ?1 AND state = 'completed'
               AND installation_id = ?2 AND chat_id = ?3 AND workspace_id = ?4
               AND delivery_chat_id = ?3 AND terminal_random_id IS NOT NULL
             LIMIT 2",
        )?;
        let random_ids = statement
            .query_map(
                params![
                    turn_id.as_str(),
                    binding.installation_id.as_str(),
                    binding.chat_id,
                    binding.workspace_id.as_str(),
                ],
                |row| row.get::<_, i64>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?;
        match random_ids.as_slice() {
            [] => Ok(None),
            [random_id] => Ok(Some(*random_id)),
            _ => Err(StoreError::AmbiguousInboundTerminalIdentity),
        }
    }

    /// Claims the oldest accepted direction for one binding under a lease.
    pub fn take_next_inbound(
        &self,
        binding: &BindingKey,
        started_at: i64,
    ) -> StoreResult<Option<InboundRecord>> {
        self.take_next_inbound_inner(binding, started_at, false)
    }

    /// Claims the oldest accepted direction only when no incomplete session
    /// Open operation owns this conversation. Gate evaluation and the inbox
    /// compare-and-set share one SQLite transaction, so Open cannot checkpoint
    /// the target between those decisions.
    pub fn take_next_inbound_if_session_ready(
        &self,
        binding: &BindingKey,
        started_at: i64,
    ) -> StoreResult<Option<InboundRecord>> {
        self.take_next_inbound_inner(binding, started_at, true)
    }

    fn take_next_inbound_inner(
        &self,
        binding: &BindingKey,
        started_at: i64,
        require_session_ready: bool,
    ) -> StoreResult<Option<InboundRecord>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        if require_session_ready
            && session_picker::session_picker_thread_gate_in_transaction(
                &transaction,
                &binding.installation_id,
                binding.chat_id,
                started_at,
            )? != SessionPickerThreadGate::Ready
        {
            transaction.commit()?;
            return Ok(None);
        }
        let raw = transaction
            .query_row(
                "SELECT event_id, message_id, delivery_chat_id, sender_user_id, direction_id,
                        direction_text, direction_attachments_json, accepted_at,
                        attempt_count, stream_message_id
                 FROM inbound_directions
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                   AND state = 'accepted'
                 ORDER BY ingest_order ASC
                 LIMIT 1",
                params![
                    binding.installation_id.as_str(),
                    binding.chat_id,
                    binding.workspace_id.as_str()
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, i64>(8)?,
                        row.get::<_, Option<i64>>(9)?,
                    ))
                },
            )
            .optional()?;
        let Some((
            event_id,
            message_id,
            delivery_chat_id,
            sender_user_id,
            direction_id,
            direction_text,
            direction_attachments_json,
            accepted_at,
            attempt_count,
            stream_message_id,
        )) = raw
        else {
            transaction.commit()?;
            return Ok(None);
        };
        let lease_expires_at = started_at.saturating_add(DEFAULT_INBOUND_LEASE_SECONDS);
        let changed = transaction.execute(
            "UPDATE inbound_directions SET
                state = 'started', started_at = ?2, lease_expires_at = ?3,
                attempt_count = attempt_count + 1, failure = NULL
             WHERE event_id = ?1 AND state = 'accepted'",
            params![event_id, started_at, lease_expires_at],
        )?;
        if changed != 1 {
            transaction.commit()?;
            return Ok(None);
        }
        transaction.commit()?;
        Ok(Some(InboundRecord {
            event_id,
            binding: binding.clone(),
            message_id,
            delivery_chat_id,
            sender_user_id,
            direction: Direction::new(parse_direction_id(direction_id)?, direction_text)
                .with_attachments(serde_json::from_str(&direction_attachments_json)?),
            state: InboundState::Started,
            accepted_at,
            started_at: Some(started_at),
            lease_expires_at: Some(lease_expires_at),
            attempt_count: attempt_count.saturating_add(1),
            provider_turn_id: None,
            stream_message_id,
            failure: None,
        }))
    }

    /// Claims one known accepted inbox item under a lease. This is used when a
    /// live direction is steered into the current provider turn instead of
    /// waiting in FIFO order for a new turn.
    pub fn start_inbound(&self, event_id: &str, started_at: i64) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                state = 'started', started_at = ?2, lease_expires_at = ?3,
                attempt_count = attempt_count + 1, failure = NULL
             WHERE event_id = ?1 AND state = 'accepted'",
            params![
                event_id,
                started_at,
                started_at.saturating_add(DEFAULT_INBOUND_LEASE_SECONDS)
            ],
        )?;
        Ok(changed == 1)
    }

    /// Promotes a claimed turn's Inline delivery lane before any progress is
    /// published. The source binding remains immutable for audit and context.
    pub fn set_inbound_delivery_chat(
        &self,
        event_id: &str,
        delivery_chat_id: i64,
    ) -> StoreResult<bool> {
        if delivery_chat_id <= 0 {
            return Ok(false);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET delivery_chat_id = ?2
             WHERE event_id = ?1 AND state = 'started' AND provider_turn_id IS NULL
               AND stream_message_id IS NULL AND terminal_state IS NULL",
            params![event_id, delivery_chat_id],
        )?;
        Ok(changed == 1)
    }

    /// Associates a provider turn and mutable Inline stream message with a
    /// started inbox item. The compare-and-set prevents stale workers from
    /// replacing terminal state.
    pub fn attach_inbound_turn(
        &self,
        event_id: &str,
        turn_id: &TurnId,
        stream_message_id: Option<i64>,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                provider_turn_id = ?2,
                stream_message_id = COALESCE(?3, stream_message_id)
             WHERE event_id = ?1 AND state = 'started'",
            params![event_id, turn_id.as_str(), stream_message_id],
        )?;
        Ok(changed == 1)
    }

    /// Provider turns whose Inline final projection completed for this exact
    /// conversation. Session snapshot hydration uses this to avoid rendering
    /// the same user/assistant turn again after a provider-session reopen.
    pub fn completed_provider_turn_ids(
        &self,
        binding: &BindingKey,
    ) -> StoreResult<HashSet<String>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let mut statement = connection.prepare(
            "SELECT DISTINCT provider_turn_id
             FROM inbound_directions
             WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
               AND state = 'completed' AND provider_turn_id IS NOT NULL",
        )?;
        let values = statement
            .query_map(
                params![
                    binding.installation_id.as_str(),
                    binding.chat_id,
                    binding.workspace_id.as_str(),
                ],
                |row| row.get::<_, String>(0),
            )?
            .collect::<Result<HashSet<_>, _>>()?;
        Ok(values)
    }

    /// Persists the one mutable Inline progress message for a started turn.
    /// Reattaching the same server-recognized send after recovery is harmless.
    pub fn attach_inbound_stream_message(
        &self,
        event_id: &str,
        message_id: i64,
    ) -> StoreResult<bool> {
        if message_id <= 0 {
            return Ok(false);
        }
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE inbound_directions SET stream_message_id = ?2
             WHERE event_id = ?1 AND state = 'started'",
            params![event_id, message_id],
        )?;
        if changed == 1 {
            transaction.execute(
                "INSERT OR IGNORE INTO inbound_progress_messages (
                    event_id, chunk_index, message_id
                 ) VALUES (?1, 0, ?2)",
                params![event_id, message_id],
            )?;
        }
        transaction.commit()?;
        Ok(changed == 1)
    }

    pub fn renew_inbound_lease(&self, event_id: &str, now: i64) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET lease_expires_at = ?2
             WHERE event_id = ?1 AND state = 'started'",
            params![event_id, now.saturating_add(DEFAULT_INBOUND_LEASE_SECONDS)],
        )?;
        Ok(changed == 1)
    }

    /// Returns a started inbox item to the accepted queue when live steering
    /// cannot be applied. The direction remains durable for the next turn.
    pub fn defer_inbound(&self, event_id: &str) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                state = 'accepted', started_at = NULL, lease_expires_at = NULL,
                provider_turn_id = NULL
             WHERE event_id = ?1 AND state = 'started'",
            params![event_id],
        )?;
        Ok(changed == 1)
    }

    pub fn complete_inbound(&self, event_id: &str) -> StoreResult<bool> {
        self.finish_inbound(event_id, InboundState::Completed, None)
    }

    pub fn fail_inbound(&self, event_id: &str, failure: &str) -> StoreResult<bool> {
        self.finish_inbound(event_id, InboundState::Failed, Some(failure))
    }

    fn finish_inbound(
        &self,
        event_id: &str,
        state: InboundState,
        failure: Option<&str>,
    ) -> StoreResult<bool> {
        debug_assert!(matches!(
            state,
            InboundState::Completed | InboundState::Failed
        ));
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                state = ?2, lease_expires_at = NULL, failure = ?3
             WHERE event_id = ?1 AND state = 'started'",
            params![event_id, state.as_str(), failure],
        )?;
        Ok(changed == 1)
    }

    pub fn recover_expired_inbound(&self, now: i64) -> StoreResult<usize> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                state = 'accepted', started_at = NULL, lease_expires_at = NULL,
                provider_turn_id = NULL
             WHERE state = 'started' AND terminal_state IS NULL
               AND lease_expires_at <= ?1",
            params![now],
        )?;
        Ok(changed)
    }

    /// Marks work left in progress by a previous bridge process as interrupted.
    ///
    /// A provider turn cannot be proven safe to replay after the bridge loses
    /// its live process handle. Failing it visibly avoids starting the same
    /// coding task twice after a restart.
    pub fn interrupt_started_inbound(
        &self,
        binding: &BindingKey,
        failure: &str,
    ) -> StoreResult<Vec<InterruptedInbound>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let interrupted = {
            let mut statement = transaction.prepare(
                "SELECT event_id, message_id, delivery_chat_id, stream_message_id
                 FROM inbound_directions
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                   AND state = 'started' AND terminal_state IS NULL
                 ORDER BY ingest_order ASC",
            )?;
            statement
                .query_map(
                    params![
                        binding.installation_id.as_str(),
                        binding.chat_id,
                        binding.workspace_id.as_str()
                    ],
                    |row| {
                        Ok(InterruptedInbound {
                            event_id: row.get(0)?,
                            binding: binding.clone(),
                            message_id: row.get(1)?,
                            delivery_chat_id: row.get(2)?,
                            stream_message_id: row.get(3)?,
                        })
                    },
                )?
                .collect::<Result<Vec<_>, _>>()?
        };
        transaction.execute(
            "UPDATE inbound_directions SET
                state = 'failed', lease_expires_at = NULL, failure = ?4
             WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
               AND state = 'started' AND terminal_state IS NULL",
            params![
                binding.installation_id.as_str(),
                binding.chat_id,
                binding.workspace_id.as_str(),
                failure
            ],
        )?;
        transaction.commit()?;
        Ok(interrupted)
    }

    pub fn put_binding(
        &self,
        key: &BindingKey,
        provider_id: &ProviderId,
        provider_session_id: &ProviderSessionId,
        updated_at: i64,
    ) -> StoreResult<()> {
        self.put_binding_with_configuration(key, provider_id, provider_session_id, None, updated_at)
    }

    pub(crate) fn put_binding_with_configuration(
        &self,
        key: &BindingKey,
        provider_id: &ProviderId,
        provider_session_id: &ProviderSessionId,
        session_configuration_fingerprint: Option<&str>,
        updated_at: i64,
    ) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        match session_thread::read_by_chat(&transaction, &key.installation_id, key.chat_id)? {
            Some(owner)
                if owner.workspace_id() != &key.workspace_id
                    || owner.session().provider().provider_id() != provider_id
                    || owner.session().session_id() != provider_session_id =>
            {
                return Err(StoreError::SessionThreadBindingConflict {
                    thread_chat_id: key.chat_id,
                });
            }
            Some(_) | None => {}
        }
        transaction.execute(
            "INSERT INTO session_bindings (
                installation_id, chat_id, workspace_id, provider_id, provider_session_id,
                updated_at, session_configuration_fingerprint
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT (installation_id, chat_id, workspace_id) DO UPDATE SET
                provider_id = excluded.provider_id,
                provider_session_id = excluded.provider_session_id,
                updated_at = excluded.updated_at,
                session_configuration_fingerprint = excluded.session_configuration_fingerprint",
            params![
                key.installation_id.as_str(),
                key.chat_id,
                key.workspace_id.as_str(),
                provider_id.as_str(),
                provider_session_id.as_str(),
                updated_at,
                session_configuration_fingerprint,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn get_binding(
        &self,
        key: &BindingKey,
    ) -> StoreResult<Option<(ProviderId, ProviderSessionId)>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let raw = connection
            .query_row(
                "SELECT provider_id, provider_session_id
                 FROM session_bindings
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
                params![
                    key.installation_id.as_str(),
                    key.chat_id,
                    key.workspace_id.as_str()
                ],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        raw.map(|(provider, session)| {
            Ok((
                parse_provider_id(provider)?,
                parse_provider_session_id(session)?,
            ))
        })
        .transpose()
    }

    pub(crate) fn get_binding_with_configuration(
        &self,
        key: &BindingKey,
    ) -> StoreResult<Option<(ProviderId, ProviderSessionId, Option<String>)>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let raw = connection
            .query_row(
                "SELECT provider_id, provider_session_id, session_configuration_fingerprint
                 FROM session_bindings
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
                params![
                    key.installation_id.as_str(),
                    key.chat_id,
                    key.workspace_id.as_str()
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()?;
        raw.map(|(provider, session, fingerprint)| {
            Ok((
                parse_provider_id(provider)?,
                parse_provider_session_id(session)?,
                fingerprint,
            ))
        })
        .transpose()
    }

    pub fn enqueue(&self, record: &QueueRecord) -> StoreResult<()> {
        let attachments_json = serde_json::to_string(&record.direction.attachments)?;
        let connection = self.connection.lock().expect("bridge store poisoned");
        connection.execute(
            "INSERT INTO queue_items (
                queue_id, installation_id, chat_id, workspace_id,
                direction_id, direction_text, direction_attachments_json, state, created_at, started_at
                , lease_expires_at, attempt_count
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                record.queue_id.as_str(),
                record.binding.installation_id.as_str(),
                record.binding.chat_id,
                record.binding.workspace_id.as_str(),
                record.direction.id.as_str(),
                record.direction.text,
                attachments_json,
                record.state.as_str(),
                record.created_at,
                record.started_at,
                record.lease_expires_at,
                record.attempt_count,
            ],
        )?;
        Ok(())
    }

    pub fn undo_queue(&self, queue_id: &QueueItemId) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE queue_items SET state = 'removed'
             WHERE queue_id = ?1 AND state = 'pending'",
            params![queue_id.as_str()],
        )?;
        Ok(changed == 1)
    }

    pub fn take_next_queue(
        &self,
        binding: &BindingKey,
        started_at: i64,
    ) -> StoreResult<Option<QueueRecord>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let raw = transaction
            .query_row(
                "SELECT queue_id, direction_id, direction_text, direction_attachments_json,
                        created_at, attempt_count
                 FROM queue_items
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                   AND state = 'pending'
                 ORDER BY created_at ASC, queue_id ASC
                 LIMIT 1",
                params![
                    binding.installation_id.as_str(),
                    binding.chat_id,
                    binding.workspace_id.as_str()
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                    ))
                },
            )
            .optional()?;
        let Some((
            queue_id,
            direction_id,
            direction_text,
            direction_attachments_json,
            created_at,
            attempt_count,
        )) = raw
        else {
            transaction.commit()?;
            return Ok(None);
        };
        let changed = transaction.execute(
            "UPDATE queue_items SET
                state = 'started',
                started_at = ?2,
                lease_expires_at = ?3,
                attempt_count = attempt_count + 1
             WHERE queue_id = ?1 AND state = 'pending'",
            params![
                queue_id,
                started_at,
                started_at.saturating_add(DEFAULT_QUEUE_LEASE_SECONDS)
            ],
        )?;
        if changed != 1 {
            transaction.commit()?;
            return Ok(None);
        }
        transaction.commit()?;
        Ok(Some(QueueRecord {
            queue_id: parse_queue_id(queue_id)?,
            binding: binding.clone(),
            direction: Direction::new(parse_direction_id(direction_id)?, direction_text)
                .with_attachments(serde_json::from_str(&direction_attachments_json)?),
            state: QueueState::Started,
            created_at,
            started_at: Some(started_at),
            lease_expires_at: Some(started_at.saturating_add(DEFAULT_QUEUE_LEASE_SECONDS)),
            attempt_count: attempt_count.saturating_add(1),
        }))
    }

    pub fn complete_queue(&self, queue_id: &QueueItemId) -> StoreResult<bool> {
        self.finish_queue(queue_id, QueueState::Completed)
    }

    pub fn fail_queue(&self, queue_id: &QueueItemId) -> StoreResult<bool> {
        self.finish_queue(queue_id, QueueState::Failed)
    }

    fn finish_queue(&self, queue_id: &QueueItemId, state: QueueState) -> StoreResult<bool> {
        debug_assert!(matches!(state, QueueState::Completed | QueueState::Failed));
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE queue_items SET state = ?2, lease_expires_at = NULL
             WHERE queue_id = ?1 AND state = 'started'",
            params![queue_id.as_str(), state.as_str()],
        )?;
        Ok(changed == 1)
    }

    pub fn recover_expired_queue(&self, now: i64) -> StoreResult<usize> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE queue_items SET
                state = 'pending',
                started_at = NULL,
                lease_expires_at = NULL
             WHERE state = 'started' AND lease_expires_at <= ?1",
            params![now],
        )?;
        Ok(changed)
    }
}

fn migrate(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch("PRAGMA foreign_keys = ON;")?;
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version > CURRENT_SCHEMA_VERSION {
        return Err(StoreError::UnsupportedSchemaVersion {
            found: version,
            supported: CURRENT_SCHEMA_VERSION,
        });
    }
    if version == 0 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
         CREATE TABLE IF NOT EXISTS processed_events (
            event_id TEXT PRIMARY KEY NOT NULL,
            accepted_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS session_bindings (
            installation_id TEXT NOT NULL,
            chat_id INTEGER NOT NULL,
            workspace_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            provider_session_id TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (installation_id, chat_id, workspace_id)
         );
         CREATE TABLE IF NOT EXISTS queue_items (
            queue_id TEXT PRIMARY KEY NOT NULL,
            installation_id TEXT NOT NULL,
            chat_id INTEGER NOT NULL,
            workspace_id TEXT NOT NULL,
            direction_id TEXT NOT NULL,
            direction_text TEXT NOT NULL,
            state TEXT NOT NULL CHECK (
                state IN ('pending', 'started', 'completed', 'failed', 'removed')
            ),
            created_at INTEGER NOT NULL,
            started_at INTEGER,
            lease_expires_at INTEGER,
            attempt_count INTEGER NOT NULL DEFAULT 0
         );
         CREATE INDEX IF NOT EXISTS queue_items_pending_binding
         ON queue_items (installation_id, chat_id, workspace_id, state, created_at);
         PRAGMA user_version = 1;
         COMMIT;",
        )?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 1 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             CREATE TABLE inbound_directions (
                event_id TEXT PRIMARY KEY NOT NULL,
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                message_id INTEGER NOT NULL,
                sender_user_id INTEGER NOT NULL,
                direction_id TEXT NOT NULL,
                direction_text TEXT NOT NULL,
                state TEXT NOT NULL CHECK (
                    state IN ('accepted', 'started', 'completed', 'failed')
                ),
                accepted_at INTEGER NOT NULL,
                started_at INTEGER,
                lease_expires_at INTEGER,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                provider_turn_id TEXT,
                stream_message_id INTEGER,
                failure TEXT
             );
             CREATE INDEX inbound_directions_pending_binding
             ON inbound_directions (
                installation_id, chat_id, workspace_id, state, accepted_at
             );
             PRAGMA user_version = 2;
             COMMIT;",
        )?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 2 {
        approval::migrate_v3(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 3 {
        workspace::migrate_v4(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 4 {
        settings::migrate_v5(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 5 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             ALTER TABLE inbound_directions ADD COLUMN ingest_order INTEGER;
             UPDATE inbound_directions SET ingest_order = rowid WHERE ingest_order IS NULL;
             CREATE UNIQUE INDEX inbound_directions_ingest_order
                 ON inbound_directions (ingest_order);
             PRAGMA user_version = 6;
             COMMIT;",
        )?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 6 {
        approval::migrate_v7(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 7 {
        approval::migrate_v8(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 8 {
        pending_final_send::migrate_v9(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 9 {
        pending_final_send::migrate_v10(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 10 {
        question::migrate_v11(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 11 {
        workspace::migrate_v12(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 12 {
        operator_allowlist::migrate_v13(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 13 {
        host_tool::migrate_v14(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 14 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             ALTER TABLE session_bindings
                 ADD COLUMN session_configuration_fingerprint TEXT;
             PRAGMA user_version = 15;
             COMMIT;",
        )?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 15 {
        progress::migrate_v16(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 16 {
        rejection::migrate_v17(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 17 {
        command_choice::migrate_v18(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 18 {
        reply_threads::migrate_v19(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 19 {
        connection.execute_batch(
            "BEGIN IMMEDIATE;
             ALTER TABLE inbound_directions
                 ADD COLUMN delivery_chat_id INTEGER NOT NULL DEFAULT 0;
             UPDATE inbound_directions SET delivery_chat_id = chat_id
                 WHERE delivery_chat_id = 0;
             PRAGMA user_version = 20;
             COMMIT;",
        )?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 20 {
        connection.execute_batch("BEGIN IMMEDIATE;")?;
        let result = (|| -> StoreResult<()> {
            for table in ["inbound_directions", "queue_items"] {
                if table_exists(connection, table)?
                    && !table_has_column(connection, table, "direction_attachments_json")?
                {
                    connection.execute(
                        &format!(
                            "ALTER TABLE {table} ADD COLUMN direction_attachments_json TEXT NOT NULL DEFAULT '[]'"
                        ),
                        [],
                    )?;
                }
            }
            connection.execute_batch("PRAGMA user_version = 21;")?;
            Ok(())
        })();
        match result {
            Ok(()) => connection.execute_batch("COMMIT;")?,
            Err(error) => {
                let _ = connection.execute_batch("ROLLBACK;");
                return Err(error);
            }
        }
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 21 {
        pending_final_send::migrate_v22(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 22 {
        history_import::migrate_v23(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 23 {
        session_thread::migrate_v24(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 24 {
        session_thread::migrate_v25(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 25 {
        workspace::migrate_v26(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 26 {
        session_picker::migrate_v27(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 27 {
        session_picker::migrate_v28(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 28 {
        pending_final_send::migrate_v29(connection)?;
    }
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 29 {
        session_picker::migrate_v30(connection)?;
    }
    Ok(())
}

fn table_exists(connection: &Connection, table: &str) -> StoreResult<bool> {
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
            [table],
            |row| row.get(0),
        )
        .map_err(StoreError::from)
}

fn table_has_column(connection: &Connection, table: &str, column: &str) -> StoreResult<bool> {
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2)",
            params![table, column],
            |row| row.get(0),
        )
        .map_err(StoreError::from)
}

fn prepare_private_file(path: &Path) -> StoreResult<()> {
    let parent = path
        .parent()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    fs::create_dir_all(&parent)?;
    set_dir_permissions(&parent, 0o700)?;
    if !path.exists() {
        fs::File::create(path)?;
    }
    set_file_permissions(path, 0o600)?;
    Ok(())
}

fn acquire_migration_lock(path: &Path) -> StoreResult<fs::File> {
    let file_name = path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_else(|| "bridge.sqlite".into());
    let mut lock_name = OsString::from(".");
    lock_name.push(file_name);
    lock_name.push(".migration.lock");
    let lock_path = path.with_file_name(lock_name);
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lock = options.open(&lock_path)?;
    set_file_permissions(&lock_path, 0o600)?;
    lock.lock().map_err(|error| {
        std::io::Error::other(format!(
            "could not lock bridge state migration {}: {error}",
            lock_path.display()
        ))
    })?;
    Ok(lock)
}

/// Creates one consistent, private copy before an on-disk schema upgrade.
/// Older beta binaries reject newer schema versions, so this artifact is the
/// recoverable rollback point for the user's pre-upgrade bridge state.
fn prepare_migration_backup(path: &Path, connection: &Connection) -> StoreResult<Option<PathBuf>> {
    let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == 0 || version >= CURRENT_SCHEMA_VERSION {
        return Ok(None);
    }

    let file_name = path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_else(|| "bridge.sqlite".into());
    let mut backup_name = file_name;
    backup_name.push(format!(
        ".pre-schema-{CURRENT_SCHEMA_VERSION}-from-{version}.backup"
    ));
    let mut backup_path = path.with_file_name(backup_name);

    if backup_path.exists() {
        let metadata = fs::symlink_metadata(&backup_path)?;
        if !metadata.file_type().is_file() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "bridge state migration backup is not a regular file: {}",
                    backup_path.display()
                ),
            )
            .into());
        }
        set_file_permissions(&backup_path, 0o600)?;
        validate_migration_backup(&backup_path, version)?;

        // A user may deliberately restore this rollback artifact, create new
        // old-schema state, and later upgrade again. Never mistake the first
        // backup for a copy of that newer source database. Preserve both by
        // assigning every subsequent upgrade a private generation.
        let generation = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let mut generated_name = backup_path
            .file_name()
            .map(|name| name.to_os_string())
            .unwrap_or_else(|| "bridge.sqlite.backup".into());
        generated_name.push(format!(".{}.{}", std::process::id(), generation));
        backup_path = backup_path.with_file_name(generated_name);
    }

    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let backup_file_name = backup_path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_else(|| "bridge.sqlite.backup".into());
    let mut temporary_name = OsString::from(".");
    temporary_name.push(backup_file_name);
    temporary_name.push(format!(".{}.{}.pending", std::process::id(), nonce));
    let temporary_path = backup_path.with_file_name(temporary_name);
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary_path)?;
    set_file_permissions(&temporary_path, 0o600)?;
    connection.backup(MAIN_DB, &temporary_path, None)?;
    validate_migration_backup(&temporary_path, version)?;
    fs::File::open(&temporary_path)?.sync_all()?;
    fs::rename(&temporary_path, &backup_path)?;
    set_file_permissions(&backup_path, 0o600)?;
    sync_parent_directory(&backup_path)?;
    validate_migration_backup(&backup_path, version)?;
    Ok(Some(backup_path))
}

fn validate_migration_backup(path: &Path, expected: i64) -> StoreResult<()> {
    let backup = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let found: i64 = backup.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if found != expected {
        return Err(StoreError::InvalidMigrationBackup {
            path: path.display().to_string(),
            found,
            expected,
        });
    }
    let quick_check: String = backup.query_row("PRAGMA quick_check(1)", [], |row| row.get(0))?;
    if quick_check != "ok" {
        return Err(StoreError::InvalidMigrationBackupIntegrity {
            path: path.display().to_string(),
            result: quick_check,
        });
    }
    Ok(())
}

#[cfg(unix)]
fn sync_parent_directory(path: &Path) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::File::open(parent)?.sync_all()
}

#[cfg(not(unix))]
fn sync_parent_directory(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_file_permissions(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_file_permissions(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_dir_permissions(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_dir_permissions(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

fn parse_provider_id(value: String) -> StoreResult<ProviderId> {
    ProviderId::new(value.clone()).map_err(|_| StoreError::InvalidIdentifier {
        kind: "provider id",
        value,
    })
}

fn parse_installation_id(value: String) -> StoreResult<crate::InstallationId> {
    crate::InstallationId::new(value.clone()).map_err(|_| StoreError::InvalidIdentifier {
        kind: "installation id",
        value,
    })
}

fn parse_workspace_id(value: String) -> StoreResult<crate::WorkspaceId> {
    crate::WorkspaceId::new(value.clone()).map_err(|_| StoreError::InvalidIdentifier {
        kind: "workspace id",
        value,
    })
}

fn parse_provider_session_id(value: String) -> StoreResult<ProviderSessionId> {
    ProviderSessionId::new(value.clone()).map_err(|_| StoreError::InvalidIdentifier {
        kind: "provider session id",
        value,
    })
}

fn parse_queue_id(value: String) -> StoreResult<QueueItemId> {
    QueueItemId::new(value.clone()).map_err(|_| StoreError::InvalidIdentifier {
        kind: "queue item id",
        value,
    })
}

fn parse_direction_id(value: String) -> StoreResult<DirectionId> {
    DirectionId::new(value.clone()).map_err(|_| StoreError::InvalidIdentifier {
        kind: "direction id",
        value,
    })
}

fn parse_turn_id(value: String) -> StoreResult<TurnId> {
    TurnId::new(value.clone()).map_err(|_| StoreError::InvalidIdentifier {
        kind: "turn id",
        value,
    })
}

#[cfg(test)]
mod tests;

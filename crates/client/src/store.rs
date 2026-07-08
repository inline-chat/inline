//! Store boundary for durable client state.
//!
//! Production `inline-client` storage will eventually be backed by SQLite. This
//! trait is intentionally small for now: session, dialogs, users, history, and
//! sent message recording are enough to support the first adapter paths
//! while keeping the runner independent from filesystem assumptions.

use std::{
    collections::HashMap,
    fmt,
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use futures_util::future::BoxFuture;
use rusqlite::{Connection, OptionalExtension, params};

use crate::{
    AuthCredential, ClientErrorCategory, ClientFailure, DialogRecord, DialogsPage, DialogsRequest,
    HistoryPage, HistoryRequest, InlineId, MessageContent, MessageRecord, TransactionEvent,
    TransactionId, TransactionIdentity, TransactionState, UserRecord,
};

/// Result type returned by client stores.
pub type StoreResult<T> = Result<T, StoreError>;

/// Redacted store error.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{category:?}: {message}")]
pub struct StoreError {
    /// Stable error category.
    pub category: ClientErrorCategory,
    /// Redacted message suitable for hosts.
    pub message: String,
}

impl StoreError {
    /// Creates a store error.
    pub fn new(category: ClientErrorCategory, message: impl Into<String>) -> Self {
        Self {
            category,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self::new(ClientErrorCategory::Internal, message)
    }
}

/// Stored session metadata.
#[derive(Clone, PartialEq, Eq)]
pub struct StoredSession {
    /// Auth credential needed by the runtime.
    pub auth: AuthCredential,
    /// Optional account/store namespace chosen by the host.
    pub account_namespace: Option<String>,
}

impl fmt::Debug for StoredSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoredSession")
            .field("auth", &self.auth)
            .field("account_namespace", &self.account_namespace)
            .finish()
    }
}

/// Durable store boundary for client state.
pub trait ClientStore: fmt::Debug + Send + Sync + 'static {
    /// Saves the current session.
    fn save_session(&self, session: StoredSession) -> BoxFuture<'static, StoreResult<()>>;

    /// Loads the current session.
    fn load_session(&self) -> BoxFuture<'static, StoreResult<Option<StoredSession>>>;

    /// Clears the current session.
    fn clear_session(&self) -> BoxFuture<'static, StoreResult<()>>;

    /// Lists stored dialogs.
    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, StoreResult<DialogsPage>>;

    /// Records a dialog in local state.
    fn record_dialog(&self, dialog: DialogRecord) -> BoxFuture<'static, StoreResult<()>>;

    /// Records user summaries in local state.
    fn record_users(&self, users: Vec<UserRecord>) -> BoxFuture<'static, StoreResult<()>>;

    /// Fetches stored history.
    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, StoreResult<HistoryPage>>;

    /// Records a message in stored history.
    fn record_message(&self, message: MessageRecord) -> BoxFuture<'static, StoreResult<()>>;

    /// Records a transaction state change.
    fn record_transaction(
        &self,
        transaction: StoredTransaction,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Finds a transaction by transaction ID.
    fn transaction(
        &self,
        transaction_id: TransactionId,
    ) -> BoxFuture<'static, StoreResult<Option<StoredTransaction>>>;
}

/// Stored durable transaction state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredTransaction {
    /// Mutation identity and reconciliation IDs.
    pub identity: TransactionIdentity,
    /// Current transaction state.
    pub state: TransactionState,
    /// Chat containing the transaction, when known.
    pub chat_id: Option<InlineId>,
    /// Final message ID, when known.
    pub message_id: Option<InlineId>,
    /// Redacted failure for failed transactions.
    pub failure: Option<ClientFailure>,
    /// Unix timestamp in seconds when the transaction row was created.
    pub created_at: i64,
    /// Unix timestamp in seconds when the transaction row was last updated.
    pub updated_at: i64,
}

impl StoredTransaction {
    /// Creates a stored transaction in the provided state.
    pub fn new(identity: TransactionIdentity, state: TransactionState) -> Self {
        let now = now_seconds();
        Self {
            identity,
            state,
            chat_id: None,
            message_id: None,
            failure: None,
            created_at: now,
            updated_at: now,
        }
    }

    /// Sets the chat ID.
    pub fn with_chat_id(mut self, chat_id: InlineId) -> Self {
        self.chat_id = Some(chat_id);
        self
    }

    /// Sets the final message ID.
    pub fn with_message_id(mut self, message_id: InlineId) -> Self {
        self.message_id = Some(message_id);
        self.identity.final_message_id = Some(message_id);
        self
    }

    /// Sets the redacted failure.
    pub fn with_failure(mut self, failure: ClientFailure) -> Self {
        self.failure = Some(failure);
        self
    }

    /// Converts to a client event payload.
    pub fn event(&self) -> TransactionEvent {
        TransactionEvent {
            identity: self.identity.clone(),
            state: self.state,
            failure: self.failure.clone(),
        }
    }
}

/// In-memory store for tests and early client development.
#[derive(Clone, Debug, Default)]
pub struct InMemoryStore {
    state: Arc<Mutex<InMemoryStoreState>>,
}

#[derive(Debug, Default)]
struct InMemoryStoreState {
    session: Option<StoredSession>,
    dialogs: Vec<DialogRecord>,
    users: HashMap<i64, UserRecord>,
    messages: HashMap<i64, Vec<MessageRecord>>,
    transactions: HashMap<String, StoredTransaction>,
}

impl InMemoryStore {
    /// Creates an empty in-memory store.
    pub fn new() -> Self {
        Self::default()
    }

    /// Inserts or replaces a dialog.
    pub fn upsert_dialog(&self, dialog: DialogRecord) {
        let mut state = self.state.lock().expect("in-memory store poisoned");
        upsert_dialog(&mut state.dialogs, dialog);
    }

    /// Inserts or replaces a user summary.
    pub fn upsert_user(&self, user: UserRecord) {
        let mut state = self.state.lock().expect("in-memory store poisoned");
        state.users.insert(user.user_id.get(), user);
    }

    /// Inserts a message into history.
    pub fn insert_message(&self, message: MessageRecord) {
        let mut state = self.state.lock().expect("in-memory store poisoned");
        insert_message(&mut state.messages, message);
    }
}

impl ClientStore for InMemoryStore {
    fn save_session(&self, session: StoredSession) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .session = Some(session);
            Ok(())
        })
    }

    fn load_session(&self) -> BoxFuture<'static, StoreResult<Option<StoredSession>>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .session
                .clone())
        })
    }

    fn clear_session(&self) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .session = None;
            Ok(())
        })
    }

    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, StoreResult<DialogsPage>> {
        let store = self.clone();
        Box::pin(async move {
            let state = store.state.lock().expect("in-memory store poisoned");
            let start = parse_cursor(request.cursor.as_deref())?;
            let limit = request.limit.unwrap_or(50).max(1) as usize;
            let dialogs = state
                .dialogs
                .iter()
                .skip(start)
                .take(limit)
                .map(|dialog| {
                    dialog_with_synced_through(
                        dialog.clone(),
                        max_message_id_from_memory(&state.messages, dialog.chat_id),
                    )
                })
                .collect::<Vec<_>>();
            let next = start + dialogs.len();
            let users = all_users_from_memory(&state.users);
            Ok(DialogsPage {
                dialogs,
                users,
                next_cursor: (next < state.dialogs.len()).then(|| next.to_string()),
            })
        })
    }

    fn record_dialog(&self, dialog: DialogRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store.upsert_dialog(dialog);
            Ok(())
        })
    }

    fn record_users(&self, users: Vec<UserRecord>) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            for user in users {
                state.users.insert(user.user_id.get(), user);
            }
            Ok(())
        })
    }

    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, StoreResult<HistoryPage>> {
        let store = self.clone();
        Box::pin(async move {
            let state = store.state.lock().expect("in-memory store poisoned");
            let mut messages = state
                .messages
                .get(&request.chat_id.get())
                .cloned()
                .unwrap_or_default();
            messages.sort_by_key(|message| (message.timestamp, message.message_id.get()));
            if request.before_message_id.is_some() && request.after_message_id.is_some() {
                return Err(StoreError::new(
                    ClientErrorCategory::InvalidInput,
                    "history request cannot specify both before_message_id and after_message_id",
                ));
            }
            if let Some(before) = request.before_message_id {
                messages.retain(|message| message.message_id.get() < before.get());
            }
            if let Some(after) = request.after_message_id {
                messages.retain(|message| message.message_id.get() > after.get());
            }
            let limit = request.limit.unwrap_or(50).max(1) as usize;
            let has_more = messages.len() > limit;
            if has_more {
                if request.after_message_id.is_some() {
                    messages.truncate(limit);
                } else {
                    let start = messages.len() - limit;
                    messages = messages[start..].to_vec();
                }
            }
            let users = users_for_messages_from_memory(&state.users, &messages);
            Ok(HistoryPage {
                messages,
                users,
                has_more,
                next_cursor: None,
            })
        })
    }

    fn record_message(&self, message: MessageRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            insert_message(&mut state.messages, message);
            Ok(())
        })
    }

    fn record_transaction(
        &self,
        transaction: StoredTransaction,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            state.transactions.insert(
                transaction.identity.transaction_id.as_str().to_owned(),
                transaction,
            );
            Ok(())
        })
    }

    fn transaction(
        &self,
        transaction_id: TransactionId,
    ) -> BoxFuture<'static, StoreResult<Option<StoredTransaction>>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .transactions
                .get(transaction_id.as_str())
                .cloned())
        })
    }
}

/// SQLite-backed durable store.
#[derive(Clone)]
pub struct SqliteStore {
    connection: Arc<Mutex<Connection>>,
}

impl fmt::Debug for SqliteStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SqliteStore")
            .field("connection", &"<sqlite>")
            .finish()
    }
}

impl SqliteStore {
    /// Opens a SQLite store at `path`, creating parent directories and schema.
    pub fn open(path: impl AsRef<Path>) -> StoreResult<Self> {
        let path = path.as_ref();
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent).map_err(|error| {
                StoreError::internal(format!("create store directory: {error}"))
            })?;
        }
        let connection = Connection::open(path).map_err(sqlite_error)?;
        Self::from_connection(connection)
    }

    /// Opens an in-memory SQLite store.
    pub fn open_in_memory() -> StoreResult<Self> {
        let connection = Connection::open_in_memory().map_err(sqlite_error)?;
        Self::from_connection(connection)
    }

    fn from_connection(connection: Connection) -> StoreResult<Self> {
        migrate_sqlite(&connection)?;
        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    /// Inserts or replaces a dialog.
    pub fn upsert_dialog(&self, dialog: DialogRecord) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        upsert_sqlite_dialog(&connection, dialog)
    }

    /// Inserts or replaces a user summary.
    pub fn upsert_user(&self, user: UserRecord) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        upsert_sqlite_user(&connection, user)
    }

    /// Inserts a message into history.
    pub fn insert_message(&self, message: MessageRecord) -> StoreResult<()> {
        self.record_message_sync(message)
    }

    fn save_session_sync(&self, session: StoredSession) -> StoreResult<()> {
        let auth_json = serde_json::to_string(&session.auth)
            .map_err(|error| StoreError::internal(format!("encode session auth: {error}")))?;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO sessions (id, auth_json, account_namespace, updated_at)
                 VALUES (1, ?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET
                   auth_json = excluded.auth_json,
                   account_namespace = excluded.account_namespace,
                   updated_at = excluded.updated_at",
                params![auth_json, session.account_namespace, now_seconds()],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn load_session_sync(&self) -> StoreResult<Option<StoredSession>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let row = connection
            .query_row(
                "SELECT auth_json, account_namespace FROM sessions WHERE id = 1",
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .optional()
            .map_err(sqlite_error)?;

        row.map(|(auth_json, account_namespace)| {
            let auth = serde_json::from_str::<AuthCredential>(&auth_json)
                .map_err(|error| StoreError::internal(format!("decode session auth: {error}")))?;
            Ok(StoredSession {
                auth,
                account_namespace,
            })
        })
        .transpose()
    }

    fn clear_session_sync(&self) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute("DELETE FROM sessions WHERE id = 1", [])
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn dialogs_sync(&self, request: DialogsRequest) -> StoreResult<DialogsPage> {
        let start = parse_cursor(request.cursor.as_deref())?;
        let limit = request.limit.unwrap_or(50).max(1) as usize;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let rows = {
            let mut stmt = connection
                .prepare(
                    "SELECT d.chat_id, d.title, d.last_message_id,
                            (SELECT MAX(m.message_id) FROM messages m WHERE m.chat_id = d.chat_id) AS synced_through_message_id,
                            d.unread_count
                     FROM dialogs d
                     ORDER BY COALESCE(last_message_id, 0) DESC, chat_id ASC
                     LIMIT ?1 OFFSET ?2",
                )
                .map_err(sqlite_error)?;
            stmt.query_map(params![(limit + 1) as i64, start as i64], |row| {
                Ok(DialogRecord {
                    chat_id: InlineId::new(row.get::<_, i64>(0)?),
                    title: row.get::<_, Option<String>>(1)?,
                    last_message_id: row.get::<_, Option<i64>>(2)?.map(InlineId::new),
                    synced_through_message_id: row.get::<_, Option<i64>>(3)?.map(InlineId::new),
                    unread_count: row
                        .get::<_, Option<i64>>(4)?
                        .and_then(|value| u32::try_from(value).ok()),
                })
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)?
        };

        let has_more = rows.len() > limit;
        let dialogs = rows.into_iter().take(limit).collect::<Vec<_>>();
        let users = all_sqlite_users(&connection)?;
        Ok(DialogsPage {
            next_cursor: has_more.then(|| (start + dialogs.len()).to_string()),
            dialogs,
            users,
        })
    }

    fn history_sync(&self, request: HistoryRequest) -> StoreResult<HistoryPage> {
        let limit = request.limit.unwrap_or(50).max(1) as usize;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let rows = if request.before_message_id.is_some() && request.after_message_id.is_some() {
            return Err(StoreError::new(
                ClientErrorCategory::InvalidInput,
                "history request cannot specify both before_message_id and after_message_id",
            ));
        } else if let Some(before) = request.before_message_id {
            let mut stmt = connection
                .prepare(
                    "SELECT chat_id, message_id, sender_id, timestamp, is_outgoing,
                            content_json, reply_to_message_id, transaction_json
                     FROM messages
                     WHERE chat_id = ?1 AND message_id < ?2
                     ORDER BY message_id DESC
                     LIMIT ?3",
                )
                .map_err(sqlite_error)?;
            query_message_rows(
                &mut stmt,
                params![request.chat_id.get(), before.get(), (limit + 1) as i64],
            )?
        } else if let Some(after) = request.after_message_id {
            let mut stmt = connection
                .prepare(
                    "SELECT chat_id, message_id, sender_id, timestamp, is_outgoing,
                            content_json, reply_to_message_id, transaction_json
                     FROM messages
                     WHERE chat_id = ?1 AND message_id > ?2
                     ORDER BY message_id ASC
                     LIMIT ?3",
                )
                .map_err(sqlite_error)?;
            query_message_rows(
                &mut stmt,
                params![request.chat_id.get(), after.get(), (limit + 1) as i64],
            )?
        } else {
            let mut stmt = connection
                .prepare(
                    "SELECT chat_id, message_id, sender_id, timestamp, is_outgoing,
                            content_json, reply_to_message_id, transaction_json
                     FROM messages
                     WHERE chat_id = ?1
                     ORDER BY message_id DESC
                     LIMIT ?2",
                )
                .map_err(sqlite_error)?;
            query_message_rows(
                &mut stmt,
                params![request.chat_id.get(), (limit + 1) as i64],
            )?
        };

        let has_more = rows.len() > limit;
        let mut messages = rows
            .into_iter()
            .take(limit)
            .map(raw_sqlite_message_to_record)
            .collect::<StoreResult<Vec<_>>>()?;
        messages.sort_by_key(|message| (message.timestamp, message.message_id.get()));
        let users = sqlite_users_for_messages(&connection, &messages)?;
        Ok(HistoryPage {
            messages,
            users,
            has_more,
            next_cursor: None,
        })
    }

    fn record_users_sync(&self, users: Vec<UserRecord>) -> StoreResult<()> {
        if users.is_empty() {
            return Ok(());
        }
        let connection = self.connection.lock().expect("sqlite store poisoned");
        for user in users {
            upsert_sqlite_user(&connection, user)?;
        }
        Ok(())
    }

    fn record_message_sync(&self, message: MessageRecord) -> StoreResult<()> {
        let content_json = serde_json::to_string(&message.content)
            .map_err(|error| StoreError::internal(format!("encode message content: {error}")))?;
        let transaction_json = message
            .transaction
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| {
                StoreError::internal(format!("encode transaction identity: {error}"))
            })?;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO messages (
                   chat_id, message_id, sender_id, timestamp, is_outgoing,
                   content_json, reply_to_message_id, transaction_json
                 )
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(chat_id, message_id) DO UPDATE SET
                   sender_id = excluded.sender_id,
                   timestamp = excluded.timestamp,
                   is_outgoing = excluded.is_outgoing,
                   content_json = excluded.content_json,
                   reply_to_message_id = excluded.reply_to_message_id,
                   transaction_json = excluded.transaction_json",
                params![
                    message.chat_id.get(),
                    message.message_id.get(),
                    message.sender_id.get(),
                    message.timestamp,
                    i64::from(message.is_outgoing),
                    content_json,
                    message.reply_to_message_id.map(InlineId::get),
                    transaction_json,
                ],
            )
            .map_err(sqlite_error)?;
        upsert_sqlite_dialog_last_message(&connection, message.chat_id, message.message_id)?;
        Ok(())
    }

    fn record_transaction_sync(&self, transaction: StoredTransaction) -> StoreResult<()> {
        let identity_json = serde_json::to_string(&transaction.identity).map_err(|error| {
            StoreError::internal(format!("encode transaction identity: {error}"))
        })?;
        let state_json = serde_json::to_string(&transaction.state)
            .map_err(|error| StoreError::internal(format!("encode transaction state: {error}")))?;
        let failure_json = transaction
            .failure
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| {
                StoreError::internal(format!("encode transaction failure: {error}"))
            })?;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO transactions (
                   transaction_id, identity_json, state_json, chat_id, message_id,
                   random_id, external_source, external_id, failure_json, created_at, updated_at
                 )
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                 ON CONFLICT(transaction_id) DO UPDATE SET
                   identity_json = excluded.identity_json,
                   state_json = excluded.state_json,
                   chat_id = excluded.chat_id,
                   message_id = excluded.message_id,
                   random_id = excluded.random_id,
                   external_source = excluded.external_source,
                   external_id = excluded.external_id,
                   failure_json = excluded.failure_json,
                   updated_at = excluded.updated_at",
                params![
                    transaction.identity.transaction_id.as_str(),
                    identity_json,
                    state_json,
                    transaction.chat_id.map(InlineId::get),
                    transaction.message_id.map(InlineId::get),
                    transaction.identity.random_id.get(),
                    transaction
                        .identity
                        .external_id
                        .as_ref()
                        .map(|external| external.source()),
                    transaction
                        .identity
                        .external_id
                        .as_ref()
                        .map(|external| external.id()),
                    failure_json,
                    transaction.created_at,
                    transaction.updated_at,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn transaction_sync(
        &self,
        transaction_id: TransactionId,
    ) -> StoreResult<Option<StoredTransaction>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let row = connection
            .query_row(
                "SELECT identity_json, state_json, chat_id, message_id,
                        failure_json, created_at, updated_at
                 FROM transactions
                 WHERE transaction_id = ?1",
                params![transaction_id.as_str()],
                |row| {
                    Ok(RawSqliteTransaction {
                        identity_json: row.get(0)?,
                        state_json: row.get(1)?,
                        chat_id: row.get(2)?,
                        message_id: row.get(3)?,
                        failure_json: row.get(4)?,
                        created_at: row.get(5)?,
                        updated_at: row.get(6)?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)?;

        row.map(raw_sqlite_transaction_to_record).transpose()
    }
}

impl ClientStore for SqliteStore {
    fn save_session(&self, session: StoredSession) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.save_session_sync(session) })
    }

    fn load_session(&self) -> BoxFuture<'static, StoreResult<Option<StoredSession>>> {
        let store = self.clone();
        Box::pin(async move { store.load_session_sync() })
    }

    fn clear_session(&self) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.clear_session_sync() })
    }

    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, StoreResult<DialogsPage>> {
        let store = self.clone();
        Box::pin(async move { store.dialogs_sync(request) })
    }

    fn record_dialog(&self, dialog: DialogRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.upsert_dialog(dialog) })
    }

    fn record_users(&self, users: Vec<UserRecord>) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_users_sync(users) })
    }

    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, StoreResult<HistoryPage>> {
        let store = self.clone();
        Box::pin(async move { store.history_sync(request) })
    }

    fn record_message(&self, message: MessageRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_message_sync(message) })
    }

    fn record_transaction(
        &self,
        transaction: StoredTransaction,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_transaction_sync(transaction) })
    }

    fn transaction(
        &self,
        transaction_id: TransactionId,
    ) -> BoxFuture<'static, StoreResult<Option<StoredTransaction>>> {
        let store = self.clone();
        Box::pin(async move { store.transaction_sync(transaction_id) })
    }
}

pub(crate) fn parse_cursor(cursor: Option<&str>) -> StoreResult<usize> {
    match cursor {
        Some(cursor) if !cursor.trim().is_empty() => cursor.parse::<usize>().map_err(|_| {
            StoreError::new(
                ClientErrorCategory::InvalidInput,
                "invalid pagination cursor",
            )
        }),
        _ => Ok(0),
    }
}

fn migrate_sqlite(connection: &Connection) -> StoreResult<()> {
    connection
        .execute_batch(
            "
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                auth_json TEXT NOT NULL,
                account_namespace TEXT,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS dialogs (
                chat_id INTEGER PRIMARY KEY,
                title TEXT,
                last_message_id INTEGER,
                unread_count INTEGER,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS users (
                user_id INTEGER PRIMARY KEY,
                display_name TEXT,
                username TEXT,
                first_name TEXT,
                last_name TEXT,
                avatar_url TEXT,
                is_bot INTEGER,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                sender_id INTEGER NOT NULL,
                timestamp INTEGER NOT NULL,
                is_outgoing INTEGER NOT NULL,
                content_json TEXT NOT NULL,
                reply_to_message_id INTEGER,
                transaction_json TEXT,
                PRIMARY KEY (chat_id, message_id)
            );

            CREATE INDEX IF NOT EXISTS idx_messages_chat_message
                ON messages (chat_id, message_id DESC);

            CREATE TABLE IF NOT EXISTS transactions (
                transaction_id TEXT PRIMARY KEY,
                identity_json TEXT NOT NULL,
                state_json TEXT NOT NULL,
                chat_id INTEGER,
                message_id INTEGER,
                random_id INTEGER NOT NULL,
                external_source TEXT,
                external_id TEXT,
                failure_json TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_transactions_external
                ON transactions (external_source, external_id);
            CREATE INDEX IF NOT EXISTS idx_transactions_random
                ON transactions (random_id);
            ",
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn upsert_sqlite_user(connection: &Connection, user: UserRecord) -> StoreResult<()> {
    connection
        .execute(
            "INSERT INTO users (
               user_id, display_name, username, first_name, last_name,
               avatar_url, is_bot, updated_at
             )
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(user_id) DO UPDATE SET
               display_name = excluded.display_name,
               username = excluded.username,
               first_name = excluded.first_name,
               last_name = excluded.last_name,
               avatar_url = excluded.avatar_url,
               is_bot = excluded.is_bot,
               updated_at = excluded.updated_at",
            params![
                user.user_id.get(),
                user.display_name,
                user.username,
                user.first_name,
                user.last_name,
                user.avatar_url,
                user.is_bot.map(|is_bot| if is_bot { 1_i64 } else { 0_i64 }),
                now_seconds(),
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn upsert_sqlite_dialog(connection: &Connection, dialog: DialogRecord) -> StoreResult<()> {
    connection
        .execute(
            "INSERT INTO dialogs (chat_id, title, last_message_id, unread_count, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(chat_id) DO UPDATE SET
               title = excluded.title,
               last_message_id = excluded.last_message_id,
               unread_count = excluded.unread_count,
               updated_at = excluded.updated_at",
            params![
                dialog.chat_id.get(),
                dialog.title,
                dialog.last_message_id.map(InlineId::get),
                dialog.unread_count.map(i64::from),
                now_seconds(),
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn upsert_sqlite_dialog_last_message(
    connection: &Connection,
    chat_id: InlineId,
    message_id: InlineId,
) -> StoreResult<()> {
    let updated = connection
        .execute(
            "UPDATE dialogs
             SET last_message_id = ?1, updated_at = ?2
             WHERE chat_id = ?3",
            params![message_id.get(), now_seconds(), chat_id.get()],
        )
        .map_err(sqlite_error)?;
    if updated == 0 {
        connection
            .execute(
                "INSERT INTO dialogs (chat_id, title, last_message_id, unread_count, updated_at)
                 VALUES (?1, NULL, ?2, 0, ?3)",
                params![chat_id.get(), message_id.get(), now_seconds()],
            )
            .map_err(sqlite_error)?;
    }
    Ok(())
}

fn all_sqlite_users(connection: &Connection) -> StoreResult<Vec<UserRecord>> {
    let mut stmt = connection
        .prepare(
            "SELECT user_id, display_name, username, first_name, last_name, avatar_url, is_bot
             FROM users
             ORDER BY user_id ASC",
        )
        .map_err(sqlite_error)?;
    query_user_rows(&mut stmt, [])
}

fn sqlite_users_for_messages(
    connection: &Connection,
    messages: &[MessageRecord],
) -> StoreResult<Vec<UserRecord>> {
    let mut user_ids = messages
        .iter()
        .map(|message| message.sender_id.get())
        .collect::<Vec<_>>();
    user_ids.sort_unstable();
    user_ids.dedup();

    let mut users = Vec::new();
    let mut stmt = connection
        .prepare(
            "SELECT user_id, display_name, username, first_name, last_name, avatar_url, is_bot
             FROM users
             WHERE user_id = ?1",
        )
        .map_err(sqlite_error)?;
    for user_id in user_ids {
        if let Some(user) = stmt
            .query_row(params![user_id], sqlite_user_from_row)
            .optional()
            .map_err(sqlite_error)?
        {
            users.push(user);
        }
    }
    Ok(users)
}

fn query_user_rows<P>(stmt: &mut rusqlite::Statement<'_>, params: P) -> StoreResult<Vec<UserRecord>>
where
    P: rusqlite::Params,
{
    stmt.query_map(params, sqlite_user_from_row)
        .map_err(sqlite_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sqlite_error)
}

fn sqlite_user_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<UserRecord> {
    Ok(UserRecord {
        user_id: InlineId::new(row.get::<_, i64>(0)?),
        display_name: row.get::<_, Option<String>>(1)?,
        username: row.get::<_, Option<String>>(2)?,
        first_name: row.get::<_, Option<String>>(3)?,
        last_name: row.get::<_, Option<String>>(4)?,
        avatar_url: row.get::<_, Option<String>>(5)?,
        is_bot: row.get::<_, Option<i64>>(6)?.map(|value| value != 0),
    })
}

#[derive(Debug)]
struct RawSqliteMessage {
    chat_id: i64,
    message_id: i64,
    sender_id: i64,
    timestamp: i64,
    is_outgoing: bool,
    content_json: String,
    reply_to_message_id: Option<i64>,
    transaction_json: Option<String>,
}

fn query_message_rows<P>(
    stmt: &mut rusqlite::Statement<'_>,
    params: P,
) -> StoreResult<Vec<RawSqliteMessage>>
where
    P: rusqlite::Params,
{
    stmt.query_map(params, |row| {
        Ok(RawSqliteMessage {
            chat_id: row.get(0)?,
            message_id: row.get(1)?,
            sender_id: row.get(2)?,
            timestamp: row.get(3)?,
            is_outgoing: row.get::<_, i64>(4)? != 0,
            content_json: row.get(5)?,
            reply_to_message_id: row.get(6)?,
            transaction_json: row.get(7)?,
        })
    })
    .map_err(sqlite_error)?
    .collect::<Result<Vec<_>, _>>()
    .map_err(sqlite_error)
}

fn raw_sqlite_message_to_record(raw: RawSqliteMessage) -> StoreResult<MessageRecord> {
    let content = serde_json::from_str::<MessageContent>(&raw.content_json)
        .map_err(|error| StoreError::internal(format!("decode message content: {error}")))?;
    let transaction = raw
        .transaction_json
        .as_deref()
        .map(serde_json::from_str::<TransactionIdentity>)
        .transpose()
        .map_err(|error| StoreError::internal(format!("decode transaction identity: {error}")))?;
    Ok(MessageRecord {
        chat_id: InlineId::new(raw.chat_id),
        message_id: InlineId::new(raw.message_id),
        sender_id: InlineId::new(raw.sender_id),
        timestamp: raw.timestamp,
        is_outgoing: raw.is_outgoing,
        content,
        reply_to_message_id: raw.reply_to_message_id.map(InlineId::new),
        transaction,
    })
}

#[derive(Debug)]
struct RawSqliteTransaction {
    identity_json: String,
    state_json: String,
    chat_id: Option<i64>,
    message_id: Option<i64>,
    failure_json: Option<String>,
    created_at: i64,
    updated_at: i64,
}

fn raw_sqlite_transaction_to_record(raw: RawSqliteTransaction) -> StoreResult<StoredTransaction> {
    let identity = serde_json::from_str::<TransactionIdentity>(&raw.identity_json)
        .map_err(|error| StoreError::internal(format!("decode transaction identity: {error}")))?;
    let state = serde_json::from_str::<TransactionState>(&raw.state_json)
        .map_err(|error| StoreError::internal(format!("decode transaction state: {error}")))?;
    let failure = raw
        .failure_json
        .as_deref()
        .map(serde_json::from_str::<ClientFailure>)
        .transpose()
        .map_err(|error| StoreError::internal(format!("decode transaction failure: {error}")))?;
    Ok(StoredTransaction {
        identity,
        state,
        chat_id: raw.chat_id.map(InlineId::new),
        message_id: raw.message_id.map(InlineId::new),
        failure,
        created_at: raw.created_at,
        updated_at: raw.updated_at,
    })
}

fn sqlite_error(error: rusqlite::Error) -> StoreError {
    StoreError::internal(format!("sqlite store error: {error}"))
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

fn all_users_from_memory(users: &HashMap<i64, UserRecord>) -> Vec<UserRecord> {
    let mut users = users.values().cloned().collect::<Vec<_>>();
    users.sort_by_key(|user| user.user_id.get());
    users
}

fn max_message_id_from_memory(
    messages: &HashMap<i64, Vec<MessageRecord>>,
    chat_id: InlineId,
) -> Option<InlineId> {
    messages
        .get(&chat_id.get())?
        .iter()
        .map(|message| message.message_id.get())
        .max()
        .map(InlineId::new)
}

fn dialog_with_synced_through(
    mut dialog: DialogRecord,
    synced_through_message_id: Option<InlineId>,
) -> DialogRecord {
    dialog.synced_through_message_id = synced_through_message_id;
    dialog
}

fn users_for_messages_from_memory(
    users: &HashMap<i64, UserRecord>,
    messages: &[MessageRecord],
) -> Vec<UserRecord> {
    let mut user_ids = messages
        .iter()
        .map(|message| message.sender_id.get())
        .collect::<Vec<_>>();
    user_ids.sort_unstable();
    user_ids.dedup();
    user_ids
        .into_iter()
        .filter_map(|user_id| users.get(&user_id).cloned())
        .collect()
}

fn upsert_dialog(dialogs: &mut Vec<DialogRecord>, dialog: DialogRecord) {
    if let Some(existing) = dialogs
        .iter_mut()
        .find(|existing| existing.chat_id == dialog.chat_id)
    {
        *existing = dialog;
        return;
    }
    dialogs.push(dialog);
}

fn insert_message(messages: &mut HashMap<i64, Vec<MessageRecord>>, message: MessageRecord) {
    let chat_id = message.chat_id.get();
    messages.entry(chat_id).or_default().push(message);
    if let Some(messages) = messages.get_mut(&chat_id) {
        messages.sort_by_key(|message| (message.timestamp, message.message_id.get()));
    }
}

/// Updates or inserts a dialog's last message pointer.
pub(crate) fn upsert_dialog_last_message(
    dialogs: &mut Vec<DialogRecord>,
    chat_id: InlineId,
    message_id: InlineId,
) {
    if let Some(dialog) = dialogs.iter_mut().find(|dialog| dialog.chat_id == chat_id) {
        dialog.last_message_id = Some(message_id);
        return;
    }
    dialogs.push(DialogRecord {
        chat_id,
        title: None,
        last_message_id: Some(message_id),
        synced_through_message_id: None,
        unread_count: Some(0),
    });
}

#[cfg(test)]
mod tests {
    use crate::{AuthToken, ExternalId, RandomId};

    use super::*;

    fn session() -> StoredSession {
        StoredSession {
            auth: AuthCredential::AccessToken {
                token: AuthToken::try_new("secret-token").unwrap(),
            },
            account_namespace: Some("team".to_owned()),
        }
    }

    #[tokio::test]
    async fn stored_session_debug_redacts_token() {
        let rendered = format!("{:?}", session());

        assert!(rendered.contains("[redacted]"));
        assert!(!rendered.contains("secret-token"));
    }

    #[tokio::test]
    async fn in_memory_store_saves_and_clears_session() {
        let store = InMemoryStore::new();
        store.save_session(session()).await.unwrap();

        assert!(store.load_session().await.unwrap().is_some());

        store.clear_session().await.unwrap();
        assert!(store.load_session().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn in_memory_store_lists_dialogs_and_history() {
        let store = InMemoryStore::new();
        store.upsert_dialog(DialogRecord {
            chat_id: InlineId::new(7),
            title: Some("general".to_owned()),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
        });
        store
            .record_users(vec![UserRecord {
                user_id: InlineId::new(2),
                display_name: Some("Ada Lovelace".to_owned()),
                username: Some("ada".to_owned()),
                first_name: Some("Ada".to_owned()),
                last_name: Some("Lovelace".to_owned()),
                avatar_url: None,
                is_bot: Some(false),
            }])
            .await
            .unwrap();
        store
            .record_message(MessageRecord {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(1),
                sender_id: InlineId::new(2),
                timestamp: 1,
                is_outgoing: false,
                content: MessageContent::Text {
                    text: "hello".to_owned(),
                },
                reply_to_message_id: None,
                transaction: None,
            })
            .await
            .unwrap();

        let dialogs = store.dialogs(DialogsRequest::default()).await.unwrap();
        assert_eq!(dialogs.dialogs.len(), 1);
        assert_eq!(
            dialogs.dialogs[0].synced_through_message_id,
            Some(InlineId::new(1))
        );
        assert_eq!(dialogs.users.len(), 1);
        assert_eq!(
            dialogs.users[0].display_name.as_deref(),
            Some("Ada Lovelace")
        );

        let history = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(10),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();
        assert_eq!(history.messages.len(), 1);
        assert_eq!(history.users.len(), 1);
        assert_eq!(history.users[0].user_id, InlineId::new(2));
    }

    #[tokio::test]
    async fn in_memory_store_records_transactions() {
        let store = InMemoryStore::new();
        let transaction = stored_transaction("txn-mem", TransactionState::Queued);

        store.record_transaction(transaction.clone()).await.unwrap();

        let loaded = store
            .transaction(transaction.identity.transaction_id.clone())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            loaded.identity.transaction_id,
            transaction.identity.transaction_id
        );
        assert_eq!(loaded.state, TransactionState::Queued);
    }

    #[tokio::test]
    async fn in_memory_store_fetches_history_after_checkpoint() {
        let store = InMemoryStore::new();
        for message_id in 1..=3 {
            store
                .record_message(MessageRecord {
                    chat_id: InlineId::new(7),
                    message_id: InlineId::new(message_id),
                    sender_id: InlineId::new(2),
                    timestamp: message_id,
                    is_outgoing: false,
                    content: MessageContent::Text {
                        text: format!("message {message_id}"),
                    },
                    reply_to_message_id: None,
                    transaction: None,
                })
                .await
                .unwrap();
        }

        let history = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(1),
                before_message_id: None,
                after_message_id: Some(InlineId::new(1)),
            })
            .await
            .unwrap();

        assert_eq!(history.messages.len(), 1);
        assert_eq!(history.messages[0].message_id, InlineId::new(2));
        assert!(history.has_more);
    }

    #[tokio::test]
    async fn sqlite_store_persists_session_dialogs_and_history() {
        let path = sqlite_temp_path("persist");
        let store = SqliteStore::open(&path).unwrap();

        store.save_session(session()).await.unwrap();
        store
            .upsert_dialog(DialogRecord {
                chat_id: InlineId::new(7),
                title: Some("general".to_owned()),
                last_message_id: None,
                synced_through_message_id: None,
                unread_count: Some(3),
            })
            .unwrap();
        store
            .record_users(vec![UserRecord {
                user_id: InlineId::new(2),
                display_name: Some("Grace Hopper".to_owned()),
                username: Some("grace".to_owned()),
                first_name: Some("Grace".to_owned()),
                last_name: Some("Hopper".to_owned()),
                avatar_url: Some("https://cdn.inline.test/grace.jpg".to_owned()),
                is_bot: Some(false),
            }])
            .await
            .unwrap();
        store
            .record_message(MessageRecord {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(10),
                sender_id: InlineId::new(2),
                timestamp: 100,
                is_outgoing: false,
                content: MessageContent::Text {
                    text: "persisted".to_owned(),
                },
                reply_to_message_id: None,
                transaction: None,
            })
            .await
            .unwrap();
        drop(store);

        let reopened = SqliteStore::open(&path).unwrap();
        let session = reopened.load_session().await.unwrap().unwrap();
        assert_eq!(session.account_namespace.as_deref(), Some("team"));
        assert!(!format!("{reopened:?}").contains(path.to_string_lossy().as_ref()));

        let dialogs = reopened.dialogs(DialogsRequest::default()).await.unwrap();
        assert_eq!(dialogs.dialogs.len(), 1);
        assert_eq!(dialogs.dialogs[0].chat_id, InlineId::new(7));
        assert_eq!(dialogs.dialogs[0].last_message_id, Some(InlineId::new(10)));
        assert_eq!(
            dialogs.dialogs[0].synced_through_message_id,
            Some(InlineId::new(10))
        );
        assert_eq!(dialogs.users.len(), 1);
        assert_eq!(
            dialogs.users[0].display_name.as_deref(),
            Some("Grace Hopper")
        );

        let history = reopened
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(10),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();
        assert_eq!(history.messages.len(), 1);
        assert_eq!(history.messages[0].message_id, InlineId::new(10));
        assert!(matches!(
            history.messages[0].content,
            MessageContent::Text { ref text } if text == "persisted"
        ));
        assert_eq!(history.users.len(), 1);
        assert_eq!(
            history.users[0].avatar_url.as_deref(),
            Some("https://cdn.inline.test/grace.jpg")
        );

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sqlite_store_persists_transactions() {
        let path = sqlite_temp_path("transactions");
        let store = SqliteStore::open(&path).unwrap();
        let transaction = stored_transaction("txn-sqlite", TransactionState::Sent)
            .with_chat_id(InlineId::new(7))
            .with_message_id(InlineId::new(11));

        store.record_transaction(transaction.clone()).await.unwrap();
        drop(store);

        let reopened = SqliteStore::open(&path).unwrap();
        let loaded = reopened
            .transaction(transaction.identity.transaction_id.clone())
            .await
            .unwrap()
            .unwrap();

        assert_eq!(
            loaded.identity.transaction_id,
            transaction.identity.transaction_id
        );
        assert_eq!(
            loaded.identity.external_id,
            transaction.identity.external_id
        );
        assert_eq!(loaded.state, TransactionState::Sent);
        assert_eq!(loaded.chat_id, Some(InlineId::new(7)));
        assert_eq!(loaded.message_id, Some(InlineId::new(11)));

        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sqlite_store_replaces_messages_by_chat_and_message_id() {
        let store = SqliteStore::open_in_memory().unwrap();

        store
            .record_message(MessageRecord {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(10),
                sender_id: InlineId::new(2),
                timestamp: 100,
                is_outgoing: false,
                content: MessageContent::Text {
                    text: "first".to_owned(),
                },
                reply_to_message_id: None,
                transaction: None,
            })
            .await
            .unwrap();
        store
            .record_message(MessageRecord {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(10),
                sender_id: InlineId::new(2),
                timestamp: 101,
                is_outgoing: false,
                content: MessageContent::Text {
                    text: "updated".to_owned(),
                },
                reply_to_message_id: None,
                transaction: None,
            })
            .await
            .unwrap();

        let history = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(10),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();
        assert_eq!(history.messages.len(), 1);
        assert!(matches!(
            history.messages[0].content,
            MessageContent::Text { ref text } if text == "updated"
        ));
    }

    fn sqlite_temp_path(label: &str) -> std::path::PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "inline-client-{label}-{}-{unique}.db",
            std::process::id()
        ))
    }

    fn stored_transaction(id: &str, state: TransactionState) -> StoredTransaction {
        StoredTransaction::new(
            TransactionIdentity::new(
                TransactionId::try_new(id).unwrap(),
                Some(ExternalId::try_new("host-event", "event-1").unwrap()),
                RandomId::new(42),
            ),
            state,
        )
    }
}

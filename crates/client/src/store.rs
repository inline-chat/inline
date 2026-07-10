//! Store boundary for durable client state.
//!
//! The built-in SQLite implementation persists sessions, sync cursors and
//! journals, dialogs, users, messages, reconciliation state, and transactions.
//! The trait keeps storage pluggable for hosts with platform-specific keychain
//! or database requirements.

use std::{
    collections::{HashMap, HashSet},
    fmt,
    fs::OpenOptions,
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use futures_util::future::BoxFuture;
use rusqlite::{Connection, OptionalExtension, Row, params, types::Type};
use serde::{Deserialize, Serialize};

use crate::{
    AuthCredential, ChatParticipantRecord, ClientErrorCategory, ClientFailure, DialogFollowMode,
    DialogNotificationMode, DialogRecord, DialogsPage, DialogsRequest, HistoryPage, HistoryRequest,
    InlineId, MessageContent, MessageRecord, SpaceMemberRecord, SpaceRecord, TransactionEvent,
    TransactionId, TransactionIdentity, TransactionState, UserRecord, UserSettingsRecord,
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

/// Durable global synchronization state.
///
/// `last_sync_date` is the newest server update date that the client has
/// coherently applied. It is used as the discovery cursor for
/// `getUpdatesState` after startup and reconnect.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SyncState {
    /// Latest coherently applied server update date, in Unix seconds.
    pub last_sync_date: i64,
}

/// Peer identity for an Inline chat update bucket.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyncBucketPeer {
    /// Direct-message bucket addressed by user ID.
    User {
        /// Inline user ID.
        user_id: InlineId,
    },
    /// Group or thread bucket addressed by chat ID.
    Chat {
        /// Inline chat ID.
        chat_id: InlineId,
    },
}

/// Stable identity of an Inline update bucket.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyncBucketKey {
    /// Updates scoped to the authenticated user.
    User,
    /// Updates scoped to an Inline space.
    Space {
        /// Inline space ID.
        space_id: InlineId,
    },
    /// Updates scoped to a direct-message or chat peer.
    Chat {
        /// Peer that owns the chat bucket.
        peer: SyncBucketPeer,
    },
}

/// Durable cursor for one Inline update bucket.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SyncBucketState {
    /// Last coherently applied sequence for the bucket.
    pub seq: i64,
    /// Newest coherently applied update date for the bucket, in Unix seconds.
    pub date: i64,
}

/// Durable write-ahead record for one fetched update batch. The opaque payload
/// is owned by the sync engine and retained until reducer writes and the bucket
/// cursor have both committed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingSyncBatch {
    /// Bucket receiving the batch.
    pub key: SyncBucketKey,
    /// Cursor to commit after the batch is reapplied successfully.
    pub committed_state: SyncBucketState,
    /// Versioned opaque encoded updates and sidecars.
    pub payload: Vec<u8>,
}

/// Durable current reaction state for one user and message.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredReaction {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Inline message ID.
    pub message_id: InlineId,
    /// Inline user ID that owns the reaction.
    pub user_id: InlineId,
    /// Reaction emoji.
    pub reaction: String,
}

/// Durable read state for one chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredReadState {
    /// Inline chat ID.
    pub chat_id: InlineId,
    /// Highest message ID known read, when supplied by the server.
    pub read_max_id: Option<InlineId>,
    /// Remaining unread count, when supplied by the server.
    pub unread_count: Option<u32>,
    /// Whether the dialog is explicitly marked unread.
    pub marked_unread: bool,
}

/// Durable account-level state needed to reconcile a consumer after an event
/// stream retention gap.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountStateSnapshot {
    /// Chats that were removed after being observed by this account store.
    pub deleted_chat_ids: Vec<InlineId>,
}

/// Durable per-chat state that complements paged dialog/history queries during
/// reconciliation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatStateSnapshot {
    /// Inline chat ID represented by this snapshot.
    pub chat_id: InlineId,
    /// Current dialog metadata, or `None` if the chat is deleted or unknown.
    pub dialog: Option<DialogRecord>,
    /// Whether the store has a durable chat deletion tombstone.
    pub deleted: bool,
    /// Message IDs known to have been deleted from this chat.
    pub deleted_message_ids: Vec<InlineId>,
    /// Current reaction set known for the chat.
    pub reactions: Vec<StoredReaction>,
    /// Message IDs whose reaction set was observed as a complete snapshot,
    /// including messages with zero reactions.
    pub reaction_snapshot_message_ids: Vec<InlineId>,
    /// Current read state known for the chat.
    pub read_state: Option<StoredReadState>,
    /// Current direct participant snapshot known for the chat.
    pub participants: Vec<ChatParticipantRecord>,
    /// Whether `participants` is a complete snapshot rather than only deltas.
    pub participants_complete: bool,
}

impl fmt::Debug for StoredSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoredSession")
            .field("auth", &self.auth)
            .field(
                "account_namespace",
                &self.account_namespace.as_ref().map(|_| "<redacted>"),
            )
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

    /// Clears all account-owned cache, sync, and transaction state while
    /// leaving the session row under separate lifecycle control.
    fn clear_account_data(&self) -> BoxFuture<'static, StoreResult<()>>;

    /// Loads the global synchronization discovery cursor.
    fn sync_state(&self) -> BoxFuture<'static, StoreResult<SyncState>>;

    /// Saves the global synchronization discovery cursor.
    fn save_sync_state(&self, state: SyncState) -> BoxFuture<'static, StoreResult<()>>;

    /// Clears the global synchronization cursor and all bucket cursors.
    fn clear_sync_state(&self) -> BoxFuture<'static, StoreResult<()>>;

    /// Loads the cursor for one update bucket.
    fn sync_bucket_state(
        &self,
        key: SyncBucketKey,
    ) -> BoxFuture<'static, StoreResult<SyncBucketState>>;

    /// Saves the cursor for one update bucket.
    fn save_sync_bucket_state(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Saves multiple bucket cursors atomically when supported by the store.
    fn save_sync_bucket_states(
        &self,
        states: Vec<(SyncBucketKey, SyncBucketState)>,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Removes the cursor for one update bucket.
    fn remove_sync_bucket_state(&self, key: SyncBucketKey) -> BoxFuture<'static, StoreResult<()>>;

    /// Saves or replaces the write-ahead batch for one bucket before reducer
    /// state is changed.
    fn save_pending_sync_batch(
        &self,
        batch: PendingSyncBatch,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Lists write-ahead batches that were not fully committed.
    fn pending_sync_batches(&self) -> BoxFuture<'static, StoreResult<Vec<PendingSyncBatch>>>;

    /// Atomically advances a bucket cursor and removes its write-ahead batch.
    fn commit_pending_sync_batch(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Lists stored dialogs.
    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, StoreResult<DialogsPage>>;

    /// Loads one stored dialog by chat ID.
    fn dialog(&self, chat_id: InlineId) -> BoxFuture<'static, StoreResult<Option<DialogRecord>>>;

    /// Records a dialog in local state.
    fn record_dialog(&self, dialog: DialogRecord) -> BoxFuture<'static, StoreResult<()>>;

    /// Removes a dialog and its client-owned per-chat state.
    fn remove_dialog(&self, chat_id: InlineId) -> BoxFuture<'static, StoreResult<()>>;

    /// Lists durable chat deletion tombstones.
    fn deleted_chat_ids(&self) -> BoxFuture<'static, StoreResult<Vec<InlineId>>>;

    /// Records user summaries in local state.
    fn record_users(&self, users: Vec<UserRecord>) -> BoxFuture<'static, StoreResult<()>>;

    /// Inserts or replaces a durable space summary.
    fn record_space(&self, space: SpaceRecord) -> BoxFuture<'static, StoreResult<()>>;

    /// Loads a durable space summary.
    fn space(&self, space_id: InlineId) -> BoxFuture<'static, StoreResult<Option<SpaceRecord>>>;

    /// Inserts or replaces one durable space member.
    fn record_space_member(&self, member: SpaceMemberRecord)
    -> BoxFuture<'static, StoreResult<()>>;

    /// Replaces the complete durable membership snapshot for one space.
    fn record_space_members(
        &self,
        space_id: InlineId,
        members: Vec<SpaceMemberRecord>,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Removes one durable space member.
    fn remove_space_member(
        &self,
        space_id: InlineId,
        user_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Lists durable members for a space.
    fn space_members(
        &self,
        space_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<SpaceMemberRecord>>>;

    /// Replaces durable global user settings.
    fn record_user_settings(
        &self,
        settings: UserSettingsRecord,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Loads durable global user settings.
    fn user_settings(&self) -> BoxFuture<'static, StoreResult<Option<UserSettingsRecord>>>;

    /// Replaces the durable participant snapshot for a chat.
    fn record_chat_participants(
        &self,
        chat_id: InlineId,
        participants: Vec<ChatParticipantRecord>,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Inserts or replaces one durable chat participant.
    fn record_chat_participant(
        &self,
        chat_id: InlineId,
        participant: ChatParticipantRecord,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Removes one durable chat participant.
    fn remove_chat_participant(
        &self,
        chat_id: InlineId,
        user_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Loads the durable participant snapshot for a chat.
    fn chat_participants(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<ChatParticipantRecord>>>;

    /// Returns whether the participant list was observed as a complete snapshot.
    fn chat_participants_complete(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<bool>>;

    /// Fetches stored history.
    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, StoreResult<HistoryPage>>;

    /// Records a message in stored history.
    fn record_message(&self, message: MessageRecord) -> BoxFuture<'static, StoreResult<()>>;

    /// Records a durable message tombstone and removes the live message row.
    fn record_message_deleted(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Returns whether a message has a durable deletion tombstone.
    fn message_deleted(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<bool>>;

    /// Lists durable message deletion tombstones for one chat.
    fn deleted_message_ids(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>>;

    /// Clears stored messages for one chat and returns the removed IDs.
    fn clear_chat_messages(
        &self,
        chat_id: InlineId,
        before_date: Option<i64>,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>>;

    /// Lists chat IDs currently associated with a space.
    fn chat_ids_in_space(
        &self,
        space_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>>;

    /// Inserts or replaces one current reaction.
    fn record_reaction(&self, reaction: StoredReaction) -> BoxFuture<'static, StoreResult<()>>;

    /// Removes one current reaction.
    fn remove_reaction(&self, reaction: StoredReaction) -> BoxFuture<'static, StoreResult<()>>;

    /// Replaces the complete reaction set for one message.
    fn replace_message_reactions(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
        reactions: Vec<StoredReaction>,
    ) -> BoxFuture<'static, StoreResult<()>>;

    /// Lists current reactions for a message.
    fn reactions(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<StoredReaction>>>;

    /// Lists the current reaction set for all known messages in one chat.
    fn reactions_for_chat(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<StoredReaction>>>;

    /// Lists message IDs whose reaction set is known to be complete.
    fn reaction_snapshot_message_ids(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>>;

    /// Inserts or replaces read state for a chat.
    fn record_read_state(&self, state: StoredReadState) -> BoxFuture<'static, StoreResult<()>>;

    /// Loads read state for a chat.
    fn read_state(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Option<StoredReadState>>>;

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
    sync_state: SyncState,
    sync_buckets: HashMap<SyncBucketKey, SyncBucketState>,
    pending_sync_batches: HashMap<SyncBucketKey, PendingSyncBatch>,
    dialogs: Vec<DialogRecord>,
    chat_tombstones: HashSet<i64>,
    users: HashMap<i64, UserRecord>,
    spaces: HashMap<i64, SpaceRecord>,
    space_members: HashMap<(i64, i64), SpaceMemberRecord>,
    user_settings: Option<UserSettingsRecord>,
    participants: HashMap<i64, HashMap<i64, ChatParticipantRecord>>,
    participant_snapshots: HashSet<i64>,
    messages: HashMap<i64, Vec<MessageRecord>>,
    message_tombstones: HashSet<(i64, i64)>,
    reactions: HashMap<(i64, i64, i64, String), StoredReaction>,
    reaction_snapshots: HashSet<(i64, i64)>,
    read_states: HashMap<i64, StoredReadState>,
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
        state.chat_tombstones.remove(&dialog.chat_id.get());
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
        state
            .message_tombstones
            .remove(&(message.chat_id.get(), message.message_id.get()));
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

    fn clear_account_data(&self) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            let session = state.session.take();
            *state = InMemoryStoreState::default();
            state.session = session;
            Ok(())
        })
    }

    fn sync_state(&self) -> BoxFuture<'static, StoreResult<SyncState>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .sync_state)
        })
    }

    fn save_sync_state(&self, state: SyncState) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .sync_state = state;
            Ok(())
        })
    }

    fn clear_sync_state(&self) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            state.sync_state = SyncState::default();
            state.sync_buckets.clear();
            Ok(())
        })
    }

    fn sync_bucket_state(
        &self,
        key: SyncBucketKey,
    ) -> BoxFuture<'static, StoreResult<SyncBucketState>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .sync_buckets
                .get(&key)
                .copied()
                .unwrap_or_default())
        })
    }

    fn save_sync_bucket_state(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .sync_buckets
                .insert(key, state);
            Ok(())
        })
    }

    fn save_sync_bucket_states(
        &self,
        states: Vec<(SyncBucketKey, SyncBucketState)>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut stored = store.state.lock().expect("in-memory store poisoned");
            stored.sync_buckets.extend(states);
            Ok(())
        })
    }

    fn remove_sync_bucket_state(&self, key: SyncBucketKey) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .sync_buckets
                .remove(&key);
            Ok(())
        })
    }

    fn save_pending_sync_batch(
        &self,
        batch: PendingSyncBatch,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .pending_sync_batches
                .insert(batch.key, batch);
            Ok(())
        })
    }

    fn pending_sync_batches(&self) -> BoxFuture<'static, StoreResult<Vec<PendingSyncBatch>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut batches = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .pending_sync_batches
                .values()
                .cloned()
                .collect::<Vec<_>>();
            batches.sort_by_key(|batch| sync_bucket_sort_key(batch.key));
            Ok(batches)
        })
    }

    fn commit_pending_sync_batch(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut stored = store.state.lock().expect("in-memory store poisoned");
            stored.sync_buckets.insert(key, state);
            stored.pending_sync_batches.remove(&key);
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

    fn dialog(&self, chat_id: InlineId) -> BoxFuture<'static, StoreResult<Option<DialogRecord>>> {
        let store = self.clone();
        Box::pin(async move {
            let state = store.state.lock().expect("in-memory store poisoned");
            Ok(state
                .dialogs
                .iter()
                .find(|dialog| dialog.chat_id == chat_id)
                .cloned()
                .map(|dialog| {
                    dialog_with_synced_through(
                        dialog,
                        max_message_id_from_memory(&state.messages, chat_id),
                    )
                }))
        })
    }

    fn record_dialog(&self, dialog: DialogRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store.upsert_dialog(dialog);
            Ok(())
        })
    }

    fn remove_dialog(&self, chat_id: InlineId) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            state.dialogs.retain(|dialog| dialog.chat_id != chat_id);
            if let Some(messages) = state.messages.remove(&chat_id.get()) {
                state.message_tombstones.extend(
                    messages
                        .into_iter()
                        .map(|message| (chat_id.get(), message.message_id.get())),
                );
            }
            state.participants.remove(&chat_id.get());
            state.participant_snapshots.remove(&chat_id.get());
            state
                .reactions
                .retain(|_, reaction| reaction.chat_id != chat_id);
            state
                .reaction_snapshots
                .retain(|(stored_chat_id, _)| *stored_chat_id != chat_id.get());
            state.read_states.remove(&chat_id.get());
            state.chat_tombstones.insert(chat_id.get());
            Ok(())
        })
    }

    fn deleted_chat_ids(&self) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut ids = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .chat_tombstones
                .iter()
                .copied()
                .map(InlineId::new)
                .collect::<Vec<_>>();
            ids.sort_by_key(|id| id.get());
            Ok(ids)
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

    fn record_space(&self, space: SpaceRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .spaces
                .insert(space.space_id.get(), space);
            Ok(())
        })
    }

    fn space(&self, space_id: InlineId) -> BoxFuture<'static, StoreResult<Option<SpaceRecord>>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .spaces
                .get(&space_id.get())
                .cloned())
        })
    }

    fn record_space_member(
        &self,
        member: SpaceMemberRecord,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .space_members
                .insert((member.space_id.get(), member.user_id.get()), member);
            Ok(())
        })
    }

    fn record_space_members(
        &self,
        space_id: InlineId,
        members: Vec<SpaceMemberRecord>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            if members.iter().any(|member| member.space_id != space_id) {
                return Err(StoreError::new(
                    ClientErrorCategory::InvalidInput,
                    "space member snapshot contains a different space id",
                ));
            }
            let mut state = store.state.lock().expect("in-memory store poisoned");
            state
                .space_members
                .retain(|(stored_space_id, _), _| *stored_space_id != space_id.get());
            for member in members {
                state
                    .space_members
                    .insert((space_id.get(), member.user_id.get()), member);
            }
            Ok(())
        })
    }

    fn remove_space_member(
        &self,
        space_id: InlineId,
        user_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .space_members
                .remove(&(space_id.get(), user_id.get()));
            Ok(())
        })
    }

    fn space_members(
        &self,
        space_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<SpaceMemberRecord>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut members = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .space_members
                .iter()
                .filter(|((stored_space_id, _), _)| *stored_space_id == space_id.get())
                .map(|(_, member)| member.clone())
                .collect::<Vec<_>>();
            members.sort_by_key(|member| member.user_id.get());
            Ok(members)
        })
    }

    fn record_user_settings(
        &self,
        settings: UserSettingsRecord,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .user_settings = Some(settings);
            Ok(())
        })
    }

    fn user_settings(&self) -> BoxFuture<'static, StoreResult<Option<UserSettingsRecord>>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .user_settings
                .clone())
        })
    }

    fn record_chat_participants(
        &self,
        chat_id: InlineId,
        participants: Vec<ChatParticipantRecord>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let snapshot = participants
                .into_iter()
                .map(|participant| (participant.user_id.get(), participant))
                .collect();
            let mut state = store.state.lock().expect("in-memory store poisoned");
            state.participants.insert(chat_id.get(), snapshot);
            state.participant_snapshots.insert(chat_id.get());
            Ok(())
        })
    }

    fn record_chat_participant(
        &self,
        chat_id: InlineId,
        participant: ChatParticipantRecord,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .participants
                .entry(chat_id.get())
                .or_default()
                .insert(participant.user_id.get(), participant);
            Ok(())
        })
    }

    fn remove_chat_participant(
        &self,
        chat_id: InlineId,
        user_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            if let Some(participants) = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .participants
                .get_mut(&chat_id.get())
            {
                participants.remove(&user_id.get());
            }
            Ok(())
        })
    }

    fn chat_participants(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<ChatParticipantRecord>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut participants = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .participants
                .get(&chat_id.get())
                .map(|participants| participants.values().cloned().collect::<Vec<_>>())
                .unwrap_or_default();
            sort_participants(&mut participants);
            Ok(participants)
        })
    }

    fn chat_participants_complete(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<bool>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .participant_snapshots
                .contains(&chat_id.get()))
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
            state
                .message_tombstones
                .remove(&(message.chat_id.get(), message.message_id.get()));
            insert_message(&mut state.messages, message);
            Ok(())
        })
    }

    fn record_message_deleted(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            if let Some(messages) = state.messages.get_mut(&chat_id.get()) {
                messages.retain(|message| message.message_id != message_id);
            }
            state.reactions.retain(|_, reaction| {
                reaction.chat_id != chat_id || reaction.message_id != message_id
            });
            state
                .reaction_snapshots
                .remove(&(chat_id.get(), message_id.get()));
            state
                .message_tombstones
                .insert((chat_id.get(), message_id.get()));
            Ok(())
        })
    }

    fn message_deleted(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<bool>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .message_tombstones
                .contains(&(chat_id.get(), message_id.get())))
        })
    }

    fn deleted_message_ids(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut ids = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .message_tombstones
                .iter()
                .filter(|(stored_chat_id, _)| *stored_chat_id == chat_id.get())
                .map(|(_, message_id)| InlineId::new(*message_id))
                .collect::<Vec<_>>();
            ids.sort_by_key(|id| id.get());
            Ok(ids)
        })
    }

    fn clear_chat_messages(
        &self,
        chat_id: InlineId,
        before_date: Option<i64>,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            let mut removed = Vec::new();
            if let Some(messages) = state.messages.get_mut(&chat_id.get()) {
                messages.retain(|message| {
                    let should_remove = before_date.is_none_or(|date| message.timestamp < date);
                    if should_remove {
                        removed.push(message.message_id);
                    }
                    !should_remove
                });
            }
            let removed_ids = removed.iter().map(|id| id.get()).collect::<HashSet<_>>();
            state.reactions.retain(|_, reaction| {
                reaction.chat_id != chat_id || !removed_ids.contains(&reaction.message_id.get())
            });
            state
                .reaction_snapshots
                .retain(|(stored_chat_id, message_id)| {
                    *stored_chat_id != chat_id.get() || !removed_ids.contains(message_id)
                });
            state.message_tombstones.extend(
                removed_ids
                    .iter()
                    .map(|message_id| (chat_id.get(), *message_id)),
            );
            let last_message_id = state.messages.get(&chat_id.get()).and_then(|messages| {
                messages
                    .iter()
                    .map(|message| message.message_id)
                    .max_by_key(|id| id.get())
            });
            if let Some(dialog) = state
                .dialogs
                .iter_mut()
                .find(|dialog| dialog.chat_id == chat_id)
            {
                dialog.last_message_id = last_message_id;
            }
            removed.sort_by_key(|id| id.get());
            Ok(removed)
        })
    }

    fn chat_ids_in_space(
        &self,
        space_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut chat_ids = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .dialogs
                .iter()
                .filter(|dialog| dialog.space_id == Some(space_id))
                .map(|dialog| dialog.chat_id)
                .collect::<Vec<_>>();
            chat_ids.sort_by_key(|id| id.get());
            Ok(chat_ids)
        })
    }

    fn record_reaction(&self, reaction: StoredReaction) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let key = reaction_key(&reaction);
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .reactions
                .insert(key, reaction);
            Ok(())
        })
    }

    fn remove_reaction(&self, reaction: StoredReaction) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .reactions
                .remove(&reaction_key(&reaction));
            Ok(())
        })
    }

    fn replace_message_reactions(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
        reactions: Vec<StoredReaction>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            let mut state = store.state.lock().expect("in-memory store poisoned");
            state.reactions.retain(|_, reaction| {
                reaction.chat_id != chat_id || reaction.message_id != message_id
            });
            for reaction in reactions {
                state.reactions.insert(reaction_key(&reaction), reaction);
            }
            state
                .reaction_snapshots
                .insert((chat_id.get(), message_id.get()));
            Ok(())
        })
    }

    fn reactions(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<StoredReaction>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut reactions = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .reactions
                .values()
                .filter(|reaction| reaction.chat_id == chat_id && reaction.message_id == message_id)
                .cloned()
                .collect::<Vec<_>>();
            sort_reactions(&mut reactions);
            Ok(reactions)
        })
    }

    fn reactions_for_chat(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<StoredReaction>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut reactions = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .reactions
                .values()
                .filter(|reaction| reaction.chat_id == chat_id)
                .cloned()
                .collect::<Vec<_>>();
            reactions.sort_by(|left, right| {
                (
                    left.message_id.get(),
                    left.user_id.get(),
                    left.reaction.as_str(),
                )
                    .cmp(&(
                        right.message_id.get(),
                        right.user_id.get(),
                        right.reaction.as_str(),
                    ))
            });
            Ok(reactions)
        })
    }

    fn reaction_snapshot_message_ids(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move {
            let mut ids = store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .reaction_snapshots
                .iter()
                .filter(|(stored_chat_id, _)| *stored_chat_id == chat_id.get())
                .map(|(_, message_id)| InlineId::new(*message_id))
                .collect::<Vec<_>>();
            ids.sort_by_key(|id| id.get());
            Ok(ids)
        })
    }

    fn record_read_state(&self, state: StoredReadState) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move {
            store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .read_states
                .insert(state.chat_id.get(), state);
            Ok(())
        })
    }

    fn read_state(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Option<StoredReadState>>> {
        let store = self.clone();
        Box::pin(async move {
            Ok(store
                .state
                .lock()
                .expect("in-memory store poisoned")
                .read_states
                .get(&chat_id.get())
                .copied())
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
        prepare_private_sqlite_file(path)?;
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

    fn clear_account_data_sync(&self) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        for table in [
            "sync_state",
            "sync_buckets",
            "pending_sync_batches",
            "dialogs",
            "chat_tombstones",
            "users",
            "spaces",
            "space_members",
            "user_settings",
            "chat_participants",
            "chat_participant_snapshots",
            "messages",
            "message_tombstones",
            "reactions",
            "reaction_snapshots",
            "read_states",
            "transactions",
        ] {
            transaction
                .execute(&format!("DELETE FROM {table}"), [])
                .map_err(sqlite_error)?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn sync_state_sync(&self) -> StoreResult<SyncState> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let last_sync_date = connection
            .query_row(
                "SELECT last_sync_date FROM sync_state WHERE id = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .optional()
            .map_err(sqlite_error)?
            .unwrap_or_default();
        Ok(SyncState { last_sync_date })
    }

    fn save_sync_state_sync(&self, state: SyncState) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO sync_state (id, last_sync_date, updated_at)
                 VALUES (1, ?1, ?2)
                 ON CONFLICT(id) DO UPDATE SET
                   last_sync_date = excluded.last_sync_date,
                   updated_at = excluded.updated_at",
                params![state.last_sync_date, now_seconds()],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn clear_sync_state_sync(&self) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute("DELETE FROM sync_state", [])
            .map_err(sqlite_error)?;
        transaction
            .execute("DELETE FROM sync_buckets", [])
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn sync_bucket_state_sync(&self, key: SyncBucketKey) -> StoreResult<SyncBucketState> {
        let (kind, entity_id) = sync_bucket_key_parts(key);
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let state = connection
            .query_row(
                "SELECT seq, date FROM sync_buckets
                 WHERE bucket_kind = ?1 AND entity_id = ?2",
                params![kind, entity_id],
                |row| {
                    Ok(SyncBucketState {
                        seq: row.get(0)?,
                        date: row.get(1)?,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)?
            .unwrap_or_default();
        Ok(state)
    }

    fn save_sync_bucket_state_sync(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> StoreResult<()> {
        let (kind, entity_id) = sync_bucket_key_parts(key);
        let connection = self.connection.lock().expect("sqlite store poisoned");
        upsert_sync_bucket(&connection, kind, entity_id, state)
    }

    fn save_sync_bucket_states_sync(
        &self,
        states: Vec<(SyncBucketKey, SyncBucketState)>,
    ) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        for (key, state) in states {
            let (kind, entity_id) = sync_bucket_key_parts(key);
            upsert_sync_bucket(&transaction, kind, entity_id, state)?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn remove_sync_bucket_state_sync(&self, key: SyncBucketKey) -> StoreResult<()> {
        let (kind, entity_id) = sync_bucket_key_parts(key);
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "DELETE FROM sync_buckets WHERE bucket_kind = ?1 AND entity_id = ?2",
                params![kind, entity_id],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn save_pending_sync_batch_sync(&self, batch: PendingSyncBatch) -> StoreResult<()> {
        let (kind, entity_id) = sync_bucket_key_parts(batch.key);
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO pending_sync_batches (
                   bucket_kind, entity_id, seq, date, payload, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(bucket_kind, entity_id) DO UPDATE SET
                   seq = excluded.seq,
                   date = excluded.date,
                   payload = excluded.payload,
                   updated_at = excluded.updated_at",
                params![
                    kind,
                    entity_id,
                    batch.committed_state.seq,
                    batch.committed_state.date,
                    batch.payload,
                    now_seconds(),
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn pending_sync_batches_sync(&self) -> StoreResult<Vec<PendingSyncBatch>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare(
                "SELECT bucket_kind, entity_id, seq, date, payload
                 FROM pending_sync_batches
                 ORDER BY bucket_kind ASC, entity_id ASC",
            )
            .map_err(sqlite_error)?;
        statement
            .query_map([], |row| {
                let kind = row.get::<_, String>(0)?;
                let entity_id = row.get::<_, i64>(1)?;
                let key = sync_bucket_key_from_parts(&kind, entity_id).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error))
                })?;
                Ok(PendingSyncBatch {
                    key,
                    committed_state: SyncBucketState {
                        seq: row.get(2)?,
                        date: row.get(3)?,
                    },
                    payload: row.get(4)?,
                })
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    fn commit_pending_sync_batch_sync(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> StoreResult<()> {
        let (kind, entity_id) = sync_bucket_key_parts(key);
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        upsert_sync_bucket(&transaction, kind, entity_id, state)?;
        transaction
            .execute(
                "DELETE FROM pending_sync_batches
                 WHERE bucket_kind = ?1 AND entity_id = ?2",
                params![kind, entity_id],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn dialogs_sync(&self, request: DialogsRequest) -> StoreResult<DialogsPage> {
        let start = parse_cursor(request.cursor.as_deref())?;
        let limit = request.limit.unwrap_or(50).max(1) as usize;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let rows = {
            let mut stmt = connection
                .prepare(
                    "SELECT d.chat_id, d.peer_user_id, d.title, d.emoji, d.last_message_id,
                            (SELECT MAX(m.message_id) FROM messages m WHERE m.chat_id = d.chat_id) AS synced_through_message_id,
                            d.unread_count, d.space_id, d.is_public, d.archived, d.pinned,
                            d.open, d.chat_list_hidden, d.list_order, d.pinned_order,
                            d.notification_mode, d.follow_mode, d.pinned_message_ids_json
                     FROM dialogs d
                     ORDER BY COALESCE(last_message_id, 0) DESC, chat_id ASC
                     LIMIT ?1 OFFSET ?2",
                )
                .map_err(sqlite_error)?;
            stmt.query_map(
                params![(limit + 1) as i64, start as i64],
                sqlite_dialog_from_row,
            )
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

    fn dialog_sync(&self, chat_id: InlineId) -> StoreResult<Option<DialogRecord>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .query_row(
                "SELECT d.chat_id, d.peer_user_id, d.title, d.emoji, d.last_message_id,
                        (SELECT MAX(m.message_id) FROM messages m WHERE m.chat_id = d.chat_id),
                        d.unread_count, d.space_id, d.is_public, d.archived, d.pinned,
                        d.open, d.chat_list_hidden, d.list_order, d.pinned_order,
                        d.notification_mode, d.follow_mode, d.pinned_message_ids_json
                 FROM dialogs d WHERE d.chat_id = ?1",
                params![chat_id.get()],
                sqlite_dialog_from_row,
            )
            .optional()
            .map_err(sqlite_error)
    }

    fn remove_dialog_sync(&self, chat_id: InlineId) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "INSERT INTO chat_tombstones (chat_id, deleted_at)
                 VALUES (?1, ?2)
                 ON CONFLICT(chat_id) DO UPDATE SET deleted_at = excluded.deleted_at",
                params![chat_id.get(), now_seconds()],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "INSERT INTO message_tombstones (chat_id, message_id, deleted_at)
                 SELECT chat_id, message_id, ?2 FROM messages WHERE chat_id = ?1
                 ON CONFLICT(chat_id, message_id) DO UPDATE SET deleted_at = excluded.deleted_at",
                params![chat_id.get(), now_seconds()],
            )
            .map_err(sqlite_error)?;
        for table in [
            "dialogs",
            "messages",
            "chat_participants",
            "chat_participant_snapshots",
            "reactions",
            "reaction_snapshots",
            "read_states",
        ] {
            transaction
                .execute(
                    &format!("DELETE FROM {table} WHERE chat_id = ?1"),
                    params![chat_id.get()],
                )
                .map_err(sqlite_error)?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn deleted_chat_ids_sync(&self) -> StoreResult<Vec<InlineId>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare("SELECT chat_id FROM chat_tombstones ORDER BY chat_id ASC")
            .map_err(sqlite_error)?;
        statement
            .query_map([], |row| row.get::<_, i64>(0).map(InlineId::new))
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
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

    fn record_space_sync(&self, space: SpaceRecord) -> StoreResult<()> {
        let payload = serde_json::to_string(&space)
            .map_err(|error| StoreError::internal(format!("encode space: {error}")))?;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO spaces (space_id, record_json, updated_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(space_id) DO UPDATE SET
                   record_json = excluded.record_json,
                   updated_at = excluded.updated_at",
                params![space.space_id.get(), payload, now_seconds()],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn space_sync(&self, space_id: InlineId) -> StoreResult<Option<SpaceRecord>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .query_row(
                "SELECT record_json FROM spaces WHERE space_id = ?1",
                params![space_id.get()],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(sqlite_error)?
            .map(|payload| {
                serde_json::from_str(&payload)
                    .map_err(|error| StoreError::internal(format!("decode space: {error}")))
            })
            .transpose()
    }

    fn record_space_member_sync(&self, member: SpaceMemberRecord) -> StoreResult<()> {
        let payload = serde_json::to_string(&member)
            .map_err(|error| StoreError::internal(format!("encode space member: {error}")))?;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO space_members (space_id, user_id, record_json, updated_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(space_id, user_id) DO UPDATE SET
                   record_json = excluded.record_json,
                   updated_at = excluded.updated_at",
                params![
                    member.space_id.get(),
                    member.user_id.get(),
                    payload,
                    now_seconds()
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn record_space_members_sync(
        &self,
        space_id: InlineId,
        members: Vec<SpaceMemberRecord>,
    ) -> StoreResult<()> {
        if members.iter().any(|member| member.space_id != space_id) {
            return Err(StoreError::new(
                ClientErrorCategory::InvalidInput,
                "space member snapshot contains a different space id",
            ));
        }
        let mut encoded = Vec::with_capacity(members.len());
        for member in members {
            let payload = serde_json::to_string(&member)
                .map_err(|error| StoreError::internal(format!("encode space member: {error}")))?;
            encoded.push((member, payload));
        }
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "DELETE FROM space_members WHERE space_id = ?1",
                params![space_id.get()],
            )
            .map_err(sqlite_error)?;
        for (member, payload) in encoded {
            transaction
                .execute(
                    "INSERT INTO space_members (space_id, user_id, record_json, updated_at)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![
                        member.space_id.get(),
                        member.user_id.get(),
                        payload,
                        now_seconds()
                    ],
                )
                .map_err(sqlite_error)?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn remove_space_member_sync(&self, space_id: InlineId, user_id: InlineId) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "DELETE FROM space_members WHERE space_id = ?1 AND user_id = ?2",
                params![space_id.get(), user_id.get()],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn space_members_sync(&self, space_id: InlineId) -> StoreResult<Vec<SpaceMemberRecord>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare(
                "SELECT record_json FROM space_members
                 WHERE space_id = ?1 ORDER BY user_id ASC",
            )
            .map_err(sqlite_error)?;
        let payloads = statement
            .query_map(params![space_id.get()], |row| row.get::<_, String>(0))
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)?;
        payloads
            .into_iter()
            .map(|payload| {
                serde_json::from_str(&payload)
                    .map_err(|error| StoreError::internal(format!("decode space member: {error}")))
            })
            .collect()
    }

    fn record_user_settings_sync(&self, settings: UserSettingsRecord) -> StoreResult<()> {
        let payload = serde_json::to_string(&settings)
            .map_err(|error| StoreError::internal(format!("encode user settings: {error}")))?;
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO user_settings (id, settings_json, updated_at)
                 VALUES (1, ?1, ?2)
                 ON CONFLICT(id) DO UPDATE SET
                   settings_json = excluded.settings_json,
                   updated_at = excluded.updated_at",
                params![payload, now_seconds()],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn user_settings_sync(&self) -> StoreResult<Option<UserSettingsRecord>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .query_row(
                "SELECT settings_json FROM user_settings WHERE id = 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(sqlite_error)?
            .map(|payload| {
                serde_json::from_str(&payload)
                    .map_err(|error| StoreError::internal(format!("decode user settings: {error}")))
            })
            .transpose()
    }

    fn record_chat_participants_sync(
        &self,
        chat_id: InlineId,
        participants: Vec<ChatParticipantRecord>,
    ) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "DELETE FROM chat_participants WHERE chat_id = ?1",
                params![chat_id.get()],
            )
            .map_err(sqlite_error)?;
        for participant in participants {
            upsert_sqlite_participant(&transaction, chat_id, participant)?;
        }
        transaction
            .execute(
                "INSERT INTO chat_participant_snapshots (chat_id, updated_at)
                 VALUES (?1, ?2)
                 ON CONFLICT(chat_id) DO UPDATE SET updated_at = excluded.updated_at",
                params![chat_id.get(), now_seconds()],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn record_chat_participant_sync(
        &self,
        chat_id: InlineId,
        participant: ChatParticipantRecord,
    ) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        upsert_sqlite_participant(&connection, chat_id, participant)
    }

    fn remove_chat_participant_sync(
        &self,
        chat_id: InlineId,
        user_id: InlineId,
    ) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "DELETE FROM chat_participants WHERE chat_id = ?1 AND user_id = ?2",
                params![chat_id.get(), user_id.get()],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn chat_participants_sync(&self, chat_id: InlineId) -> StoreResult<Vec<ChatParticipantRecord>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare(
                "SELECT user_id, date FROM chat_participants
                 WHERE chat_id = ?1 ORDER BY user_id ASC",
            )
            .map_err(sqlite_error)?;
        statement
            .query_map(params![chat_id.get()], |row| {
                Ok(ChatParticipantRecord {
                    user_id: InlineId::new(row.get(0)?),
                    date: row.get(1)?,
                })
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    fn chat_participants_complete_sync(&self, chat_id: InlineId) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .query_row(
                "SELECT 1 FROM chat_participant_snapshots WHERE chat_id = ?1",
                params![chat_id.get()],
                |_| Ok(()),
            )
            .optional()
            .map(|row| row.is_some())
            .map_err(sqlite_error)
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
        connection
            .execute(
                "DELETE FROM message_tombstones WHERE chat_id = ?1 AND message_id = ?2",
                params![message.chat_id.get(), message.message_id.get()],
            )
            .map_err(sqlite_error)?;
        upsert_sqlite_dialog_last_message(&connection, message.chat_id, message.message_id)?;
        Ok(())
    }

    fn record_message_deleted_sync(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "DELETE FROM messages WHERE chat_id = ?1 AND message_id = ?2",
                params![chat_id.get(), message_id.get()],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "DELETE FROM reactions WHERE chat_id = ?1 AND message_id = ?2",
                params![chat_id.get(), message_id.get()],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "DELETE FROM reaction_snapshots WHERE chat_id = ?1 AND message_id = ?2",
                params![chat_id.get(), message_id.get()],
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "INSERT INTO message_tombstones (chat_id, message_id, deleted_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(chat_id, message_id) DO UPDATE SET
                   deleted_at = excluded.deleted_at",
                params![chat_id.get(), message_id.get(), now_seconds()],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn message_deleted_sync(&self, chat_id: InlineId, message_id: InlineId) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .query_row(
                "SELECT 1 FROM message_tombstones WHERE chat_id = ?1 AND message_id = ?2",
                params![chat_id.get(), message_id.get()],
                |_| Ok(()),
            )
            .optional()
            .map(|row| row.is_some())
            .map_err(sqlite_error)
    }

    fn deleted_message_ids_sync(&self, chat_id: InlineId) -> StoreResult<Vec<InlineId>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare(
                "SELECT message_id FROM message_tombstones
                 WHERE chat_id = ?1 ORDER BY message_id ASC",
            )
            .map_err(sqlite_error)?;
        statement
            .query_map(params![chat_id.get()], |row| {
                row.get::<_, i64>(0).map(InlineId::new)
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    fn clear_chat_messages_sync(
        &self,
        chat_id: InlineId,
        before_date: Option<i64>,
    ) -> StoreResult<Vec<InlineId>> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        let removed = {
            let (query, parameters): (&str, Vec<i64>) = match before_date {
                Some(date) => (
                    "SELECT message_id FROM messages
                     WHERE chat_id = ?1 AND timestamp < ?2 ORDER BY message_id ASC",
                    vec![chat_id.get(), date],
                ),
                None => (
                    "SELECT message_id FROM messages
                     WHERE chat_id = ?1 ORDER BY message_id ASC",
                    vec![chat_id.get()],
                ),
            };
            let mut statement = transaction.prepare(query).map_err(sqlite_error)?;
            statement
                .query_map(rusqlite::params_from_iter(parameters), |row| {
                    row.get::<_, i64>(0).map(InlineId::new)
                })
                .map_err(sqlite_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sqlite_error)?
        };
        for message_id in &removed {
            transaction
                .execute(
                    "DELETE FROM reactions WHERE chat_id = ?1 AND message_id = ?2",
                    params![chat_id.get(), message_id.get()],
                )
                .map_err(sqlite_error)?;
            transaction
                .execute(
                    "DELETE FROM reaction_snapshots WHERE chat_id = ?1 AND message_id = ?2",
                    params![chat_id.get(), message_id.get()],
                )
                .map_err(sqlite_error)?;
            transaction
                .execute(
                    "INSERT INTO message_tombstones (chat_id, message_id, deleted_at)
                     VALUES (?1, ?2, ?3)
                     ON CONFLICT(chat_id, message_id) DO UPDATE SET deleted_at = excluded.deleted_at",
                    params![chat_id.get(), message_id.get(), now_seconds()],
                )
                .map_err(sqlite_error)?;
        }
        match before_date {
            Some(date) => transaction
                .execute(
                    "DELETE FROM messages WHERE chat_id = ?1 AND timestamp < ?2",
                    params![chat_id.get(), date],
                )
                .map_err(sqlite_error)?,
            None => transaction
                .execute(
                    "DELETE FROM messages WHERE chat_id = ?1",
                    params![chat_id.get()],
                )
                .map_err(sqlite_error)?,
        };
        transaction
            .execute(
                "UPDATE dialogs SET
                   last_message_id = (SELECT MAX(message_id) FROM messages WHERE chat_id = ?1),
                   updated_at = ?2
                 WHERE chat_id = ?1",
                params![chat_id.get(), now_seconds()],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(removed)
    }

    fn chat_ids_in_space_sync(&self, space_id: InlineId) -> StoreResult<Vec<InlineId>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare("SELECT chat_id FROM dialogs WHERE space_id = ?1 ORDER BY chat_id ASC")
            .map_err(sqlite_error)?;
        statement
            .query_map(params![space_id.get()], |row| {
                row.get::<_, i64>(0).map(InlineId::new)
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    fn record_reaction_sync(&self, reaction: StoredReaction) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO reactions (chat_id, message_id, user_id, reaction, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(chat_id, message_id, user_id, reaction) DO UPDATE SET
                   updated_at = excluded.updated_at",
                params![
                    reaction.chat_id.get(),
                    reaction.message_id.get(),
                    reaction.user_id.get(),
                    reaction.reaction,
                    now_seconds(),
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn remove_reaction_sync(&self, reaction: StoredReaction) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "DELETE FROM reactions
                 WHERE chat_id = ?1 AND message_id = ?2 AND user_id = ?3 AND reaction = ?4",
                params![
                    reaction.chat_id.get(),
                    reaction.message_id.get(),
                    reaction.user_id.get(),
                    reaction.reaction,
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn replace_message_reactions_sync(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
        reactions: Vec<StoredReaction>,
    ) -> StoreResult<()> {
        let mut connection = self.connection.lock().expect("sqlite store poisoned");
        let transaction = connection.transaction().map_err(sqlite_error)?;
        transaction
            .execute(
                "DELETE FROM reactions WHERE chat_id = ?1 AND message_id = ?2",
                params![chat_id.get(), message_id.get()],
            )
            .map_err(sqlite_error)?;
        for reaction in reactions {
            transaction
                .execute(
                    "INSERT INTO reactions (chat_id, message_id, user_id, reaction, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![
                        chat_id.get(),
                        message_id.get(),
                        reaction.user_id.get(),
                        reaction.reaction,
                        now_seconds(),
                    ],
                )
                .map_err(sqlite_error)?;
        }
        transaction
            .execute(
                "INSERT INTO reaction_snapshots (chat_id, message_id, updated_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(chat_id, message_id) DO UPDATE SET updated_at = excluded.updated_at",
                params![chat_id.get(), message_id.get(), now_seconds()],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(())
    }

    fn reactions_sync(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> StoreResult<Vec<StoredReaction>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare(
                "SELECT user_id, reaction FROM reactions
                 WHERE chat_id = ?1 AND message_id = ?2
                 ORDER BY user_id ASC, reaction ASC",
            )
            .map_err(sqlite_error)?;
        statement
            .query_map(params![chat_id.get(), message_id.get()], |row| {
                Ok(StoredReaction {
                    chat_id,
                    message_id,
                    user_id: InlineId::new(row.get(0)?),
                    reaction: row.get(1)?,
                })
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    fn reactions_for_chat_sync(&self, chat_id: InlineId) -> StoreResult<Vec<StoredReaction>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare(
                "SELECT message_id, user_id, reaction FROM reactions
                 WHERE chat_id = ?1
                 ORDER BY message_id ASC, user_id ASC, reaction ASC",
            )
            .map_err(sqlite_error)?;
        statement
            .query_map(params![chat_id.get()], |row| {
                Ok(StoredReaction {
                    chat_id,
                    message_id: InlineId::new(row.get(0)?),
                    user_id: InlineId::new(row.get(1)?),
                    reaction: row.get(2)?,
                })
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    fn reaction_snapshot_message_ids_sync(&self, chat_id: InlineId) -> StoreResult<Vec<InlineId>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        let mut statement = connection
            .prepare(
                "SELECT message_id FROM reaction_snapshots
                 WHERE chat_id = ?1 ORDER BY message_id ASC",
            )
            .map_err(sqlite_error)?;
        statement
            .query_map(params![chat_id.get()], |row| {
                row.get::<_, i64>(0).map(InlineId::new)
            })
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)
    }

    fn record_read_state_sync(&self, state: StoredReadState) -> StoreResult<()> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .execute(
                "INSERT INTO read_states (
                   chat_id, read_max_id, unread_count, marked_unread, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(chat_id) DO UPDATE SET
                   read_max_id = excluded.read_max_id,
                   unread_count = excluded.unread_count,
                   marked_unread = excluded.marked_unread,
                   updated_at = excluded.updated_at",
                params![
                    state.chat_id.get(),
                    state.read_max_id.map(InlineId::get),
                    state.unread_count.map(i64::from),
                    i64::from(state.marked_unread),
                    now_seconds(),
                ],
            )
            .map_err(sqlite_error)?;
        Ok(())
    }

    fn read_state_sync(&self, chat_id: InlineId) -> StoreResult<Option<StoredReadState>> {
        let connection = self.connection.lock().expect("sqlite store poisoned");
        connection
            .query_row(
                "SELECT read_max_id, unread_count, marked_unread
                 FROM read_states WHERE chat_id = ?1",
                params![chat_id.get()],
                |row| {
                    Ok(StoredReadState {
                        chat_id,
                        read_max_id: row.get::<_, Option<i64>>(0)?.map(InlineId::new),
                        unread_count: row
                            .get::<_, Option<i64>>(1)?
                            .and_then(|value| u32::try_from(value).ok()),
                        marked_unread: row.get::<_, i64>(2)? != 0,
                    })
                },
            )
            .optional()
            .map_err(sqlite_error)
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

fn prepare_private_sqlite_file(path: &Path) -> StoreResult<()> {
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let _file = options
        .open(path)
        .map_err(|error| StoreError::internal(format!("prepare SQLite store file: {error}")))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(
            |error| StoreError::internal(format!("secure SQLite store permissions: {error}")),
        )?;
    }
    Ok(())
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

    fn clear_account_data(&self) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.clear_account_data_sync() })
    }

    fn sync_state(&self) -> BoxFuture<'static, StoreResult<SyncState>> {
        let store = self.clone();
        Box::pin(async move { store.sync_state_sync() })
    }

    fn save_sync_state(&self, state: SyncState) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.save_sync_state_sync(state) })
    }

    fn clear_sync_state(&self) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.clear_sync_state_sync() })
    }

    fn sync_bucket_state(
        &self,
        key: SyncBucketKey,
    ) -> BoxFuture<'static, StoreResult<SyncBucketState>> {
        let store = self.clone();
        Box::pin(async move { store.sync_bucket_state_sync(key) })
    }

    fn save_sync_bucket_state(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.save_sync_bucket_state_sync(key, state) })
    }

    fn save_sync_bucket_states(
        &self,
        states: Vec<(SyncBucketKey, SyncBucketState)>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.save_sync_bucket_states_sync(states) })
    }

    fn remove_sync_bucket_state(&self, key: SyncBucketKey) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.remove_sync_bucket_state_sync(key) })
    }

    fn save_pending_sync_batch(
        &self,
        batch: PendingSyncBatch,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.save_pending_sync_batch_sync(batch) })
    }

    fn pending_sync_batches(&self) -> BoxFuture<'static, StoreResult<Vec<PendingSyncBatch>>> {
        let store = self.clone();
        Box::pin(async move { store.pending_sync_batches_sync() })
    }

    fn commit_pending_sync_batch(
        &self,
        key: SyncBucketKey,
        state: SyncBucketState,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.commit_pending_sync_batch_sync(key, state) })
    }

    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, StoreResult<DialogsPage>> {
        let store = self.clone();
        Box::pin(async move { store.dialogs_sync(request) })
    }

    fn dialog(&self, chat_id: InlineId) -> BoxFuture<'static, StoreResult<Option<DialogRecord>>> {
        let store = self.clone();
        Box::pin(async move { store.dialog_sync(chat_id) })
    }

    fn record_dialog(&self, dialog: DialogRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.upsert_dialog(dialog) })
    }

    fn remove_dialog(&self, chat_id: InlineId) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.remove_dialog_sync(chat_id) })
    }

    fn deleted_chat_ids(&self) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move { store.deleted_chat_ids_sync() })
    }

    fn record_users(&self, users: Vec<UserRecord>) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_users_sync(users) })
    }

    fn record_space(&self, space: SpaceRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_space_sync(space) })
    }

    fn space(&self, space_id: InlineId) -> BoxFuture<'static, StoreResult<Option<SpaceRecord>>> {
        let store = self.clone();
        Box::pin(async move { store.space_sync(space_id) })
    }

    fn record_space_member(
        &self,
        member: SpaceMemberRecord,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_space_member_sync(member) })
    }

    fn record_space_members(
        &self,
        space_id: InlineId,
        members: Vec<SpaceMemberRecord>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_space_members_sync(space_id, members) })
    }

    fn remove_space_member(
        &self,
        space_id: InlineId,
        user_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.remove_space_member_sync(space_id, user_id) })
    }

    fn space_members(
        &self,
        space_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<SpaceMemberRecord>>> {
        let store = self.clone();
        Box::pin(async move { store.space_members_sync(space_id) })
    }

    fn record_user_settings(
        &self,
        settings: UserSettingsRecord,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_user_settings_sync(settings) })
    }

    fn user_settings(&self) -> BoxFuture<'static, StoreResult<Option<UserSettingsRecord>>> {
        let store = self.clone();
        Box::pin(async move { store.user_settings_sync() })
    }

    fn record_chat_participants(
        &self,
        chat_id: InlineId,
        participants: Vec<ChatParticipantRecord>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_chat_participants_sync(chat_id, participants) })
    }

    fn record_chat_participant(
        &self,
        chat_id: InlineId,
        participant: ChatParticipantRecord,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_chat_participant_sync(chat_id, participant) })
    }

    fn remove_chat_participant(
        &self,
        chat_id: InlineId,
        user_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.remove_chat_participant_sync(chat_id, user_id) })
    }

    fn chat_participants(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<ChatParticipantRecord>>> {
        let store = self.clone();
        Box::pin(async move { store.chat_participants_sync(chat_id) })
    }

    fn chat_participants_complete(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<bool>> {
        let store = self.clone();
        Box::pin(async move { store.chat_participants_complete_sync(chat_id) })
    }

    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, StoreResult<HistoryPage>> {
        let store = self.clone();
        Box::pin(async move { store.history_sync(request) })
    }

    fn record_message(&self, message: MessageRecord) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_message_sync(message) })
    }

    fn record_message_deleted(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_message_deleted_sync(chat_id, message_id) })
    }

    fn message_deleted(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<bool>> {
        let store = self.clone();
        Box::pin(async move { store.message_deleted_sync(chat_id, message_id) })
    }

    fn deleted_message_ids(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move { store.deleted_message_ids_sync(chat_id) })
    }

    fn clear_chat_messages(
        &self,
        chat_id: InlineId,
        before_date: Option<i64>,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move { store.clear_chat_messages_sync(chat_id, before_date) })
    }

    fn chat_ids_in_space(
        &self,
        space_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move { store.chat_ids_in_space_sync(space_id) })
    }

    fn record_reaction(&self, reaction: StoredReaction) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_reaction_sync(reaction) })
    }

    fn remove_reaction(&self, reaction: StoredReaction) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.remove_reaction_sync(reaction) })
    }

    fn replace_message_reactions(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
        reactions: Vec<StoredReaction>,
    ) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(
            async move { store.replace_message_reactions_sync(chat_id, message_id, reactions) },
        )
    }

    fn reactions(
        &self,
        chat_id: InlineId,
        message_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<StoredReaction>>> {
        let store = self.clone();
        Box::pin(async move { store.reactions_sync(chat_id, message_id) })
    }

    fn reactions_for_chat(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<StoredReaction>>> {
        let store = self.clone();
        Box::pin(async move { store.reactions_for_chat_sync(chat_id) })
    }

    fn reaction_snapshot_message_ids(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Vec<InlineId>>> {
        let store = self.clone();
        Box::pin(async move { store.reaction_snapshot_message_ids_sync(chat_id) })
    }

    fn record_read_state(&self, state: StoredReadState) -> BoxFuture<'static, StoreResult<()>> {
        let store = self.clone();
        Box::pin(async move { store.record_read_state_sync(state) })
    }

    fn read_state(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, StoreResult<Option<StoredReadState>>> {
        let store = self.clone();
        Box::pin(async move { store.read_state_sync(chat_id) })
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

            CREATE TABLE IF NOT EXISTS sync_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                last_sync_date INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sync_buckets (
                bucket_kind TEXT NOT NULL,
                entity_id INTEGER NOT NULL,
                seq INTEGER NOT NULL,
                date INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (bucket_kind, entity_id)
            );

            CREATE TABLE IF NOT EXISTS pending_sync_batches (
                bucket_kind TEXT NOT NULL,
                entity_id INTEGER NOT NULL,
                seq INTEGER NOT NULL,
                date INTEGER NOT NULL,
                payload BLOB NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (bucket_kind, entity_id)
            );

            CREATE TABLE IF NOT EXISTS dialogs (
                chat_id INTEGER PRIMARY KEY,
                peer_user_id INTEGER,
                title TEXT,
                emoji TEXT,
                last_message_id INTEGER,
                unread_count INTEGER,
                space_id INTEGER,
                is_public INTEGER,
                archived INTEGER,
                pinned INTEGER,
                open INTEGER,
                chat_list_hidden INTEGER,
                list_order TEXT,
                pinned_order TEXT,
                notification_mode TEXT,
                follow_mode TEXT,
                pinned_message_ids_json TEXT NOT NULL DEFAULT '[]',
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS chat_tombstones (
                chat_id INTEGER PRIMARY KEY,
                deleted_at INTEGER NOT NULL
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

            CREATE TABLE IF NOT EXISTS spaces (
                space_id INTEGER PRIMARY KEY,
                record_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS space_members (
                space_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                record_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (space_id, user_id)
            );

            CREATE INDEX IF NOT EXISTS idx_space_members_space
                ON space_members (space_id, user_id);

            CREATE TABLE IF NOT EXISTS user_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                settings_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS chat_participants (
                chat_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                date INTEGER,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (chat_id, user_id)
            );

            CREATE TABLE IF NOT EXISTS chat_participant_snapshots (
                chat_id INTEGER PRIMARY KEY,
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

            CREATE TABLE IF NOT EXISTS message_tombstones (
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                deleted_at INTEGER NOT NULL,
                PRIMARY KEY (chat_id, message_id)
            );

            CREATE TABLE IF NOT EXISTS reactions (
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                reaction TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (chat_id, message_id, user_id, reaction)
            );

            CREATE INDEX IF NOT EXISTS idx_reactions_message
                ON reactions (chat_id, message_id);

            CREATE TABLE IF NOT EXISTS reaction_snapshots (
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (chat_id, message_id)
            );

            CREATE TABLE IF NOT EXISTS read_states (
                chat_id INTEGER PRIMARY KEY,
                read_max_id INTEGER,
                unread_count INTEGER,
                marked_unread INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

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
    ensure_sqlite_column(connection, "sessions", "account_namespace", "TEXT")?;
    ensure_sqlite_column(connection, "dialogs", "peer_user_id", "INTEGER")?;
    ensure_sqlite_column(connection, "dialogs", "emoji", "TEXT")?;
    ensure_sqlite_column(connection, "dialogs", "space_id", "INTEGER")?;
    ensure_sqlite_column(connection, "dialogs", "is_public", "INTEGER")?;
    ensure_sqlite_column(connection, "dialogs", "archived", "INTEGER")?;
    ensure_sqlite_column(connection, "dialogs", "pinned", "INTEGER")?;
    ensure_sqlite_column(connection, "dialogs", "open", "INTEGER")?;
    ensure_sqlite_column(connection, "dialogs", "chat_list_hidden", "INTEGER")?;
    ensure_sqlite_column(connection, "dialogs", "list_order", "TEXT")?;
    ensure_sqlite_column(connection, "dialogs", "pinned_order", "TEXT")?;
    ensure_sqlite_column(connection, "dialogs", "notification_mode", "TEXT")?;
    ensure_sqlite_column(connection, "dialogs", "follow_mode", "TEXT")?;
    ensure_sqlite_column(
        connection,
        "dialogs",
        "pinned_message_ids_json",
        "TEXT NOT NULL DEFAULT '[]'",
    )?;
    Ok(())
}

fn ensure_sqlite_column(
    connection: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> StoreResult<()> {
    let pragma = format!("PRAGMA table_info({table})");
    let mut stmt = connection.prepare(&pragma).map_err(sqlite_error)?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(sqlite_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(sqlite_error)?;
    if columns.iter().any(|name| name == column) {
        return Ok(());
    }
    connection
        .execute(
            &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
            [],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn sync_bucket_key_parts(key: SyncBucketKey) -> (&'static str, i64) {
    match key {
        SyncBucketKey::User => ("user", 0),
        SyncBucketKey::Space { space_id } => ("space", space_id.get()),
        SyncBucketKey::Chat {
            peer: SyncBucketPeer::User { user_id },
        } => ("chat_user", user_id.get()),
        SyncBucketKey::Chat {
            peer: SyncBucketPeer::Chat { chat_id },
        } => ("chat_chat", chat_id.get()),
    }
}

fn sync_bucket_key_from_parts(kind: &str, entity_id: i64) -> StoreResult<SyncBucketKey> {
    match kind {
        "user" if entity_id == 0 => Ok(SyncBucketKey::User),
        "space" => Ok(SyncBucketKey::Space {
            space_id: InlineId::new(entity_id),
        }),
        "chat_user" => Ok(SyncBucketKey::Chat {
            peer: SyncBucketPeer::User {
                user_id: InlineId::new(entity_id),
            },
        }),
        "chat_chat" => Ok(SyncBucketKey::Chat {
            peer: SyncBucketPeer::Chat {
                chat_id: InlineId::new(entity_id),
            },
        }),
        _ => Err(StoreError::internal(format!(
            "invalid stored sync bucket {kind:?}/{entity_id}"
        ))),
    }
}

fn sync_bucket_sort_key(key: SyncBucketKey) -> (u8, i64) {
    match key {
        SyncBucketKey::User => (0, 0),
        SyncBucketKey::Space { space_id } => (1, space_id.get()),
        SyncBucketKey::Chat {
            peer: SyncBucketPeer::User { user_id },
        } => (2, user_id.get()),
        SyncBucketKey::Chat {
            peer: SyncBucketPeer::Chat { chat_id },
        } => (3, chat_id.get()),
    }
}

fn upsert_sync_bucket(
    connection: &Connection,
    kind: &str,
    entity_id: i64,
    state: SyncBucketState,
) -> StoreResult<()> {
    connection
        .execute(
            "INSERT INTO sync_buckets (bucket_kind, entity_id, seq, date, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(bucket_kind, entity_id) DO UPDATE SET
               seq = excluded.seq,
               date = excluded.date,
               updated_at = excluded.updated_at",
            params![kind, entity_id, state.seq, state.date, now_seconds()],
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

fn upsert_sqlite_participant(
    connection: &Connection,
    chat_id: InlineId,
    participant: ChatParticipantRecord,
) -> StoreResult<()> {
    connection
        .execute(
            "INSERT INTO chat_participants (chat_id, user_id, date, updated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(chat_id, user_id) DO UPDATE SET
               date = excluded.date,
               updated_at = excluded.updated_at",
            params![
                chat_id.get(),
                participant.user_id.get(),
                participant.date,
                now_seconds(),
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn sqlite_dialog_from_row(row: &Row<'_>) -> rusqlite::Result<DialogRecord> {
    let pinned_json = row.get::<_, String>(17)?;
    let pinned_message_ids = serde_json::from_str(&pinned_json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(17, Type::Text, Box::new(error))
    })?;
    Ok(DialogRecord {
        chat_id: InlineId::new(row.get(0)?),
        peer_user_id: row.get::<_, Option<i64>>(1)?.map(InlineId::new),
        title: row.get(2)?,
        emoji: row.get(3)?,
        last_message_id: row.get::<_, Option<i64>>(4)?.map(InlineId::new),
        synced_through_message_id: row.get::<_, Option<i64>>(5)?.map(InlineId::new),
        unread_count: row
            .get::<_, Option<i64>>(6)?
            .and_then(|value| u32::try_from(value).ok()),
        space_id: row.get::<_, Option<i64>>(7)?.map(InlineId::new),
        is_public: row.get::<_, Option<bool>>(8)?,
        archived: row.get::<_, Option<bool>>(9)?,
        pinned: row.get::<_, Option<bool>>(10)?,
        open: row.get::<_, Option<bool>>(11)?,
        chat_list_hidden: row.get::<_, Option<bool>>(12)?,
        order: row.get(13)?,
        pinned_order: row.get(14)?,
        notification_mode: row
            .get::<_, Option<String>>(15)?
            .as_deref()
            .and_then(dialog_notification_mode_from_store),
        follow_mode: row
            .get::<_, Option<String>>(16)?
            .as_deref()
            .and_then(dialog_follow_mode_from_store),
        pinned_message_ids,
    })
}

fn upsert_sqlite_dialog(connection: &Connection, dialog: DialogRecord) -> StoreResult<()> {
    let chat_id = dialog.chat_id;
    let pinned_message_ids_json = serde_json::to_string(&dialog.pinned_message_ids)
        .map_err(|error| StoreError::internal(format!("encode pinned message IDs: {error}")))?;
    connection
        .execute(
            "INSERT INTO dialogs (
               chat_id, peer_user_id, title, emoji, last_message_id, unread_count,
               space_id, is_public, archived, pinned, open, chat_list_hidden,
               list_order, pinned_order, notification_mode, follow_mode,
               pinned_message_ids_json, updated_at
             ) VALUES (
               ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
               ?14, ?15, ?16, ?17, ?18
             )
             ON CONFLICT(chat_id) DO UPDATE SET
               peer_user_id = excluded.peer_user_id,
               title = excluded.title,
               emoji = excluded.emoji,
               last_message_id = excluded.last_message_id,
               unread_count = excluded.unread_count,
               space_id = excluded.space_id,
               is_public = excluded.is_public,
               archived = excluded.archived,
               pinned = excluded.pinned,
               open = excluded.open,
               chat_list_hidden = excluded.chat_list_hidden,
               list_order = excluded.list_order,
               pinned_order = excluded.pinned_order,
               notification_mode = excluded.notification_mode,
               follow_mode = excluded.follow_mode,
               pinned_message_ids_json = excluded.pinned_message_ids_json,
               updated_at = excluded.updated_at",
            params![
                dialog.chat_id.get(),
                dialog.peer_user_id.map(InlineId::get),
                dialog.title,
                dialog.emoji,
                dialog.last_message_id.map(InlineId::get),
                dialog.unread_count.map(i64::from),
                dialog.space_id.map(InlineId::get),
                dialog.is_public.map(i64::from),
                dialog.archived.map(i64::from),
                dialog.pinned.map(i64::from),
                dialog.open.map(i64::from),
                dialog.chat_list_hidden.map(i64::from),
                dialog.order,
                dialog.pinned_order,
                dialog
                    .notification_mode
                    .map(dialog_notification_mode_for_store),
                dialog.follow_mode.map(dialog_follow_mode_for_store),
                pinned_message_ids_json,
                now_seconds(),
            ],
        )
        .map_err(sqlite_error)?;
    connection
        .execute(
            "DELETE FROM chat_tombstones WHERE chat_id = ?1",
            params![chat_id.get()],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

const fn dialog_notification_mode_for_store(mode: DialogNotificationMode) -> &'static str {
    match mode {
        DialogNotificationMode::All => "all",
        DialogNotificationMode::Mentions => "mentions",
        DialogNotificationMode::None => "none",
    }
}

fn dialog_notification_mode_from_store(value: &str) -> Option<DialogNotificationMode> {
    match value {
        "all" => Some(DialogNotificationMode::All),
        "mentions" => Some(DialogNotificationMode::Mentions),
        "none" => Some(DialogNotificationMode::None),
        _ => None,
    }
}

const fn dialog_follow_mode_for_store(mode: DialogFollowMode) -> &'static str {
    match mode {
        DialogFollowMode::Following => "following",
    }
}

fn dialog_follow_mode_from_store(value: &str) -> Option<DialogFollowMode> {
    match value {
        "following" => Some(DialogFollowMode::Following),
        _ => None,
    }
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
    connection
        .execute(
            "DELETE FROM chat_tombstones WHERE chat_id = ?1",
            params![chat_id.get()],
        )
        .map_err(sqlite_error)?;
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

fn reaction_key(reaction: &StoredReaction) -> (i64, i64, i64, String) {
    (
        reaction.chat_id.get(),
        reaction.message_id.get(),
        reaction.user_id.get(),
        reaction.reaction.clone(),
    )
}

fn sort_reactions(reactions: &mut [StoredReaction]) {
    reactions.sort_by(|left, right| {
        (left.user_id.get(), left.reaction.as_str())
            .cmp(&(right.user_id.get(), right.reaction.as_str()))
    });
}

fn sort_participants(participants: &mut [ChatParticipantRecord]) {
    participants.sort_by_key(|participant| participant.user_id.get());
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
        peer_user_id: None,
        title: None,
        last_message_id: Some(message_id),
        synced_through_message_id: None,
        unread_count: Some(0),
        ..DialogRecord::new(chat_id)
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

    fn test_message(message_id: i64) -> MessageRecord {
        MessageRecord {
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
        }
    }

    #[tokio::test]
    async fn stored_session_debug_redacts_token() {
        let rendered = format!("{:?}", session());

        assert!(rendered.contains("[redacted]"));
        assert!(rendered.contains("<redacted>"));
        assert!(!rendered.contains("secret-token"));
        assert!(!rendered.contains("team"));
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
    async fn in_memory_store_round_trips_sync_cursors() {
        let store = InMemoryStore::new();
        let user = SyncBucketKey::User;
        let direct = SyncBucketKey::Chat {
            peer: SyncBucketPeer::User {
                user_id: InlineId::new(2),
            },
        };
        let chat = SyncBucketKey::Chat {
            peer: SyncBucketPeer::Chat {
                chat_id: InlineId::new(7),
            },
        };
        let space = SyncBucketKey::Space {
            space_id: InlineId::new(9),
        };

        assert_eq!(store.sync_state().await.unwrap(), SyncState::default());
        assert_eq!(
            store.sync_bucket_state(user).await.unwrap(),
            SyncBucketState::default()
        );

        store
            .save_sync_state(SyncState { last_sync_date: 40 })
            .await
            .unwrap();
        store
            .save_sync_bucket_state(user, SyncBucketState { seq: 3, date: 30 })
            .await
            .unwrap();
        store
            .save_sync_bucket_states(vec![
                (direct, SyncBucketState { seq: 4, date: 31 }),
                (chat, SyncBucketState { seq: 5, date: 32 }),
                (space, SyncBucketState { seq: 6, date: 33 }),
            ])
            .await
            .unwrap();
        store
            .save_sync_bucket_state(user, SyncBucketState { seq: 7, date: 41 })
            .await
            .unwrap();

        assert_eq!(
            store.sync_state().await.unwrap(),
            SyncState { last_sync_date: 40 }
        );
        assert_eq!(
            store.sync_bucket_state(user).await.unwrap(),
            SyncBucketState { seq: 7, date: 41 }
        );
        assert_eq!(
            store.sync_bucket_state(direct).await.unwrap(),
            SyncBucketState { seq: 4, date: 31 }
        );
        assert_eq!(
            store.sync_bucket_state(chat).await.unwrap(),
            SyncBucketState { seq: 5, date: 32 }
        );
        assert_eq!(
            store.sync_bucket_state(space).await.unwrap(),
            SyncBucketState { seq: 6, date: 33 }
        );

        store.remove_sync_bucket_state(direct).await.unwrap();
        assert_eq!(
            store.sync_bucket_state(direct).await.unwrap(),
            SyncBucketState::default()
        );

        store.clear_sync_state().await.unwrap();
        assert_eq!(store.sync_state().await.unwrap(), SyncState::default());
        assert_eq!(
            store.sync_bucket_state(user).await.unwrap(),
            SyncBucketState::default()
        );
        assert_eq!(
            store.sync_bucket_state(space).await.unwrap(),
            SyncBucketState::default()
        );
    }

    #[tokio::test]
    async fn in_memory_store_lists_dialogs_and_history() {
        let store = InMemoryStore::new();
        store.upsert_dialog(DialogRecord {
            chat_id: InlineId::new(7),
            peer_user_id: None,
            title: Some("general".to_owned()),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
            ..DialogRecord::new(InlineId::new(7))
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
    async fn in_memory_store_persists_message_reaction_and_read_mutations() {
        let store = InMemoryStore::new();
        let message = test_message(10);
        let reaction = StoredReaction {
            chat_id: message.chat_id,
            message_id: message.message_id,
            user_id: InlineId::new(2),
            reaction: "👍".to_owned(),
        };
        let read_state = StoredReadState {
            chat_id: message.chat_id,
            read_max_id: Some(message.message_id),
            unread_count: Some(3),
            marked_unread: false,
        };

        store.record_message(message.clone()).await.unwrap();
        store.record_reaction(reaction.clone()).await.unwrap();
        store.record_read_state(read_state).await.unwrap();
        assert_eq!(
            store
                .reactions(message.chat_id, message.message_id)
                .await
                .unwrap(),
            vec![reaction.clone()]
        );
        assert_eq!(
            store.read_state(message.chat_id).await.unwrap(),
            Some(read_state)
        );

        store
            .record_message_deleted(message.chat_id, message.message_id)
            .await
            .unwrap();
        assert!(
            store
                .message_deleted(message.chat_id, message.message_id)
                .await
                .unwrap()
        );
        assert!(
            store
                .reactions(message.chat_id, message.message_id)
                .await
                .unwrap()
                .is_empty()
        );

        store.record_message(message.clone()).await.unwrap();
        assert!(
            !store
                .message_deleted(message.chat_id, message.message_id)
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn in_memory_store_fetches_history_after_checkpoint() {
        let store = InMemoryStore::new();
        for message_id in 1..=3 {
            store
                .record_message(test_message(message_id))
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
    async fn in_memory_store_latest_history_keeps_newest_window() {
        let store = InMemoryStore::new();
        for message_id in 1..=4 {
            store
                .record_message(test_message(message_id))
                .await
                .unwrap();
        }

        let history = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(2),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();

        assert!(history.has_more);
        assert_eq!(
            history
                .messages
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(3), InlineId::new(4)]
        );
    }

    #[tokio::test]
    async fn sqlite_store_persists_session_dialogs_and_history() {
        let path = sqlite_temp_path("persist");
        let store = SqliteStore::open(&path).unwrap();

        store.save_session(session()).await.unwrap();
        store
            .upsert_dialog(DialogRecord {
                chat_id: InlineId::new(7),
                peer_user_id: Some(InlineId::new(2)),
                title: Some("general".to_owned()),
                emoji: Some("🚀".to_owned()),
                last_message_id: None,
                synced_through_message_id: None,
                unread_count: Some(3),
                space_id: Some(InlineId::new(5)),
                is_public: Some(true),
                archived: Some(false),
                pinned: Some(true),
                open: Some(true),
                chat_list_hidden: Some(false),
                order: Some("a0".to_owned()),
                pinned_order: Some("p0".to_owned()),
                notification_mode: Some(DialogNotificationMode::Mentions),
                follow_mode: Some(DialogFollowMode::Following),
                pinned_message_ids: vec![InlineId::new(99), InlineId::new(98)],
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
        assert_eq!(dialogs.dialogs[0].peer_user_id, Some(InlineId::new(2)));
        assert_eq!(dialogs.dialogs[0].title.as_deref(), Some("general"));
        assert_eq!(dialogs.dialogs[0].emoji.as_deref(), Some("🚀"));
        assert_eq!(dialogs.dialogs[0].last_message_id, Some(InlineId::new(10)));
        assert_eq!(dialogs.dialogs[0].space_id, Some(InlineId::new(5)));
        assert_eq!(dialogs.dialogs[0].is_public, Some(true));
        assert_eq!(dialogs.dialogs[0].archived, Some(false));
        assert_eq!(dialogs.dialogs[0].pinned, Some(true));
        assert_eq!(dialogs.dialogs[0].open, Some(true));
        assert_eq!(dialogs.dialogs[0].chat_list_hidden, Some(false));
        assert_eq!(dialogs.dialogs[0].order.as_deref(), Some("a0"));
        assert_eq!(dialogs.dialogs[0].pinned_order.as_deref(), Some("p0"));
        assert_eq!(
            dialogs.dialogs[0].notification_mode,
            Some(DialogNotificationMode::Mentions)
        );
        assert_eq!(
            dialogs.dialogs[0].follow_mode,
            Some(DialogFollowMode::Following)
        );
        assert_eq!(
            dialogs.dialogs[0].pinned_message_ids,
            vec![InlineId::new(99), InlineId::new(98)]
        );
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

    #[cfg(unix)]
    #[tokio::test]
    async fn sqlite_store_file_permissions_are_private() {
        use std::os::unix::fs::PermissionsExt;

        let path = sqlite_temp_path("permissions");
        let store = SqliteStore::open(&path).unwrap();
        store.save_session(session()).await.unwrap();

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    async fn assert_clear_history_store(store: &dyn ClientStore) {
        let mut dialog = DialogRecord::new(InlineId::new(7));
        dialog.space_id = Some(InlineId::new(5));
        store.record_dialog(dialog).await.unwrap();
        for (message_id, timestamp) in [(10, 100), (11, 200)] {
            store
                .record_message(MessageRecord {
                    chat_id: InlineId::new(7),
                    message_id: InlineId::new(message_id),
                    sender_id: InlineId::new(2),
                    timestamp,
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
        store
            .record_reaction(StoredReaction {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(10),
                user_id: InlineId::new(2),
                reaction: "ok".to_owned(),
            })
            .await
            .unwrap();

        assert_eq!(
            store.chat_ids_in_space(InlineId::new(5)).await.unwrap(),
            vec![InlineId::new(7)]
        );
        assert_eq!(
            store
                .clear_chat_messages(InlineId::new(7), Some(150))
                .await
                .unwrap(),
            vec![InlineId::new(10)]
        );
        assert!(
            store
                .message_deleted(InlineId::new(7), InlineId::new(10))
                .await
                .unwrap()
        );
        assert!(
            store
                .reactions(InlineId::new(7), InlineId::new(10))
                .await
                .unwrap()
                .is_empty()
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
        assert_eq!(
            history
                .messages
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(11)]
        );
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .last_message_id,
            Some(InlineId::new(11))
        );
    }

    #[tokio::test]
    async fn stores_clear_history_with_tombstones_and_space_lookup() {
        let memory = InMemoryStore::new();
        assert_clear_history_store(&memory).await;
        let sqlite = SqliteStore::open_in_memory().unwrap();
        assert_clear_history_store(&sqlite).await;
    }

    async fn assert_space_and_settings_store(store: &dyn ClientStore) {
        let space = SpaceRecord {
            space_id: InlineId::new(5),
            name: "Engineering".to_owned(),
            creator: true,
            date: 100,
            is_public: Some(false),
        };
        let member = SpaceMemberRecord {
            space_id: InlineId::new(5),
            user_id: InlineId::new(2),
            role: Some(crate::SpaceMemberRole::Admin),
            date: 101,
            can_access_public_chats: true,
        };
        let settings = UserSettingsRecord {
            notification_mode: Some(crate::NotificationMode::Mentions),
            silent: Some(true),
            zen_mode_requires_mention: Some(true),
            zen_mode_uses_default_rules: Some(false),
            zen_mode_custom_rules: Some("important".to_owned()),
            disable_dm_notifications: Some(false),
        };

        store.record_space(space.clone()).await.unwrap();
        store.record_space_member(member.clone()).await.unwrap();
        store.record_user_settings(settings.clone()).await.unwrap();

        assert_eq!(store.space(InlineId::new(5)).await.unwrap(), Some(space));
        assert_eq!(
            store.space_members(InlineId::new(5)).await.unwrap(),
            vec![member]
        );
        assert_eq!(store.user_settings().await.unwrap(), Some(settings));
        store
            .remove_space_member(InlineId::new(5), InlineId::new(2))
            .await
            .unwrap();
        assert!(
            store
                .space_members(InlineId::new(5))
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn stores_persist_spaces_members_and_user_settings() {
        let memory = InMemoryStore::new();
        assert_space_and_settings_store(&memory).await;
        let sqlite = SqliteStore::open_in_memory().unwrap();
        assert_space_and_settings_store(&sqlite).await;
    }

    #[tokio::test]
    async fn sqlite_store_persists_sync_cursors_across_reopen() {
        let path = sqlite_temp_path("sync-cursors");
        let store = SqliteStore::open(&path).unwrap();
        let user = SyncBucketKey::User;
        let direct = SyncBucketKey::Chat {
            peer: SyncBucketPeer::User {
                user_id: InlineId::new(2),
            },
        };
        let chat = SyncBucketKey::Chat {
            peer: SyncBucketPeer::Chat {
                chat_id: InlineId::new(7),
            },
        };
        let space = SyncBucketKey::Space {
            space_id: InlineId::new(9),
        };

        store
            .save_sync_state(SyncState { last_sync_date: 80 })
            .await
            .unwrap();
        store
            .save_sync_bucket_states(vec![
                (user, SyncBucketState { seq: 10, date: 70 }),
                (direct, SyncBucketState { seq: 11, date: 71 }),
                (chat, SyncBucketState { seq: 12, date: 72 }),
                (space, SyncBucketState { seq: 13, date: 73 }),
            ])
            .await
            .unwrap();
        store
            .save_sync_bucket_state(direct, SyncBucketState { seq: 14, date: 74 })
            .await
            .unwrap();
        drop(store);

        let reopened = SqliteStore::open(&path).unwrap();
        assert_eq!(
            reopened.sync_state().await.unwrap(),
            SyncState { last_sync_date: 80 }
        );
        assert_eq!(
            reopened.sync_bucket_state(user).await.unwrap(),
            SyncBucketState { seq: 10, date: 70 }
        );
        assert_eq!(
            reopened.sync_bucket_state(direct).await.unwrap(),
            SyncBucketState { seq: 14, date: 74 }
        );
        assert_eq!(
            reopened.sync_bucket_state(chat).await.unwrap(),
            SyncBucketState { seq: 12, date: 72 }
        );
        assert_eq!(
            reopened.sync_bucket_state(space).await.unwrap(),
            SyncBucketState { seq: 13, date: 73 }
        );

        reopened.remove_sync_bucket_state(chat).await.unwrap();
        assert_eq!(
            reopened.sync_bucket_state(chat).await.unwrap(),
            SyncBucketState::default()
        );
        reopened.clear_sync_state().await.unwrap();
        assert_eq!(reopened.sync_state().await.unwrap(), SyncState::default());
        assert_eq!(
            reopened.sync_bucket_state(space).await.unwrap(),
            SyncBucketState::default()
        );

        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sqlite_store_upgrades_initial_client_schema_in_place() {
        let path = sqlite_temp_path("initial-client-upgrade");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "
                CREATE TABLE sessions (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    auth_json TEXT NOT NULL,
                    account_namespace TEXT,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE dialogs (
                    chat_id INTEGER PRIMARY KEY,
                    peer_user_id INTEGER,
                    title TEXT,
                    last_message_id INTEGER,
                    unread_count INTEGER,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE users (
                    user_id INTEGER PRIMARY KEY,
                    display_name TEXT,
                    username TEXT,
                    first_name TEXT,
                    last_name TEXT,
                    avatar_url TEXT,
                    is_bot INTEGER,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE messages (
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
                CREATE TABLE transactions (
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
                ",
            )
            .unwrap();
        let initial_session = session();
        connection
            .execute(
                "INSERT INTO sessions (id, auth_json, account_namespace, updated_at)
                 VALUES (1, ?1, ?2, 1)",
                params![
                    serde_json::to_string(&initial_session.auth).unwrap(),
                    initial_session.account_namespace
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO dialogs (
                   chat_id, peer_user_id, title, last_message_id, unread_count, updated_at
                 ) VALUES (7, 2, 'General', 10, 1, 1)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO messages (
                   chat_id, message_id, sender_id, timestamp, is_outgoing,
                   content_json, reply_to_message_id, transaction_json
                 ) VALUES (7, 10, 2, 10, 0, ?1, NULL, NULL)",
                params![
                    serde_json::to_string(&MessageContent::Text {
                        text: "from the initial client".to_owned(),
                    })
                    .unwrap()
                ],
            )
            .unwrap();
        drop(connection);

        let upgraded = SqliteStore::open(&path).unwrap();
        assert_eq!(
            upgraded
                .load_session()
                .await
                .unwrap()
                .unwrap()
                .account_namespace
                .as_deref(),
            Some("team")
        );
        let dialogs = upgraded.dialogs(DialogsRequest::default()).await.unwrap();
        assert_eq!(dialogs.dialogs.len(), 1);
        assert_eq!(dialogs.dialogs[0].chat_id, InlineId::new(7));
        assert_eq!(dialogs.dialogs[0].peer_user_id, Some(InlineId::new(2)));
        assert_eq!(dialogs.dialogs[0].title.as_deref(), Some("General"));
        let history = upgraded
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
            &history.messages[0].content,
            MessageContent::Text { text } if text == "from the initial client"
        ));
        assert_eq!(upgraded.sync_state().await.unwrap(), SyncState::default());
        upgraded
            .save_sync_bucket_state(SyncBucketKey::User, SyncBucketState { seq: 3, date: 30 })
            .await
            .unwrap();
        assert_eq!(
            upgraded
                .sync_bucket_state(SyncBucketKey::User)
                .await
                .unwrap(),
            SyncBucketState { seq: 3, date: 30 }
        );

        drop(upgraded);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sqlite_store_persists_message_tombstones_reactions_and_read_state() {
        let path = sqlite_temp_path("message-state");
        let store = SqliteStore::open(&path).unwrap();
        let message = test_message(10);
        let reaction = StoredReaction {
            chat_id: message.chat_id,
            message_id: message.message_id,
            user_id: InlineId::new(2),
            reaction: "🔥".to_owned(),
        };
        let read_state = StoredReadState {
            chat_id: message.chat_id,
            read_max_id: Some(message.message_id),
            unread_count: Some(1),
            marked_unread: true,
        };

        store.record_message(message.clone()).await.unwrap();
        store.record_reaction(reaction).await.unwrap();
        store.record_read_state(read_state).await.unwrap();
        store
            .record_message_deleted(message.chat_id, message.message_id)
            .await
            .unwrap();
        drop(store);

        let reopened = SqliteStore::open(&path).unwrap();
        assert!(
            reopened
                .message_deleted(message.chat_id, message.message_id)
                .await
                .unwrap()
        );
        assert!(
            reopened
                .reactions(message.chat_id, message.message_id)
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            reopened.read_state(message.chat_id).await.unwrap(),
            Some(read_state)
        );

        reopened.record_message(message.clone()).await.unwrap();
        assert!(
            !reopened
                .message_deleted(message.chat_id, message.message_id)
                .await
                .unwrap()
        );

        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sqlite_store_preserves_complete_reconciliation_markers_and_chat_tombstones() {
        let path = sqlite_temp_path("reconciliation-state");
        let store = SqliteStore::open(&path).unwrap();
        let message = test_message(10);
        store
            .record_dialog(DialogRecord::new(message.chat_id))
            .await
            .unwrap();
        store.record_message(message.clone()).await.unwrap();
        store
            .record_chat_participants(message.chat_id, Vec::new())
            .await
            .unwrap();
        store
            .replace_message_reactions(
                message.chat_id,
                message.message_id,
                vec![StoredReaction {
                    chat_id: message.chat_id,
                    message_id: message.message_id,
                    user_id: InlineId::new(2),
                    reaction: "👍".to_owned(),
                }],
            )
            .await
            .unwrap();

        assert!(
            store
                .chat_participants_complete(message.chat_id)
                .await
                .unwrap()
        );
        assert_eq!(
            store
                .reaction_snapshot_message_ids(message.chat_id)
                .await
                .unwrap(),
            vec![message.message_id]
        );

        store.remove_dialog(message.chat_id).await.unwrap();
        drop(store);
        let reopened = SqliteStore::open(&path).unwrap();
        assert_eq!(
            reopened.deleted_chat_ids().await.unwrap(),
            vec![message.chat_id]
        );
        assert_eq!(
            reopened.deleted_message_ids(message.chat_id).await.unwrap(),
            vec![message.message_id]
        );
        assert!(
            !reopened
                .chat_participants_complete(message.chat_id)
                .await
                .unwrap()
        );

        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn sqlite_store_commits_sync_cursor_and_journal_removal_atomically() {
        let path = sqlite_temp_path("sync-journal");
        let key = SyncBucketKey::Chat {
            peer: SyncBucketPeer::Chat {
                chat_id: InlineId::new(7),
            },
        };
        let state = SyncBucketState { seq: 9, date: 90 };
        let store = SqliteStore::open(&path).unwrap();
        store
            .save_pending_sync_batch(PendingSyncBatch {
                key,
                committed_state: state,
                payload: vec![1, 2, 3],
            })
            .await
            .unwrap();
        drop(store);

        let reopened = SqliteStore::open(&path).unwrap();
        assert_eq!(
            reopened.pending_sync_batches().await.unwrap(),
            vec![PendingSyncBatch {
                key,
                committed_state: state,
                payload: vec![1, 2, 3],
            }]
        );
        reopened
            .commit_pending_sync_batch(key, state)
            .await
            .unwrap();
        assert_eq!(reopened.sync_bucket_state(key).await.unwrap(), state);
        assert!(reopened.pending_sync_batches().await.unwrap().is_empty());

        drop(reopened);
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

    #[tokio::test]
    async fn sqlite_store_history_windows_match_client_cursors() {
        let store = SqliteStore::open_in_memory().unwrap();
        for message_id in 1..=4 {
            store
                .record_message(test_message(message_id))
                .await
                .unwrap();
        }

        let latest = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(2),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();
        assert!(latest.has_more);
        assert_eq!(
            latest
                .messages
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(3), InlineId::new(4)]
        );

        let newer = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(2),
                before_message_id: None,
                after_message_id: Some(InlineId::new(1)),
            })
            .await
            .unwrap();
        assert!(newer.has_more);
        assert_eq!(
            newer
                .messages
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(2), InlineId::new(3)]
        );

        let older = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(2),
                before_message_id: Some(InlineId::new(4)),
                after_message_id: None,
            })
            .await
            .unwrap();
        assert!(older.has_more);
        assert_eq!(
            older
                .messages
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(2), InlineId::new(3)]
        );
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

//! Backend boundary for client runtime operations.
//!
//! The runtime talks to this trait instead of directly embedding transport,
//! sync, or storage behavior. The in-memory backend is useful for client and
//! bridge-adapter tests; the production backend will compose the real Inline SDK,
//! realtime transport, store, sync engine, and transaction manager behind the
//! same shape.

use std::{
    collections::{HashMap, VecDeque},
    fmt,
    sync::{Arc, Mutex},
    time::Duration,
};

use futures_util::future::BoxFuture;

use crate::{
    AccountStateSnapshot, AddChatParticipantRequest, AuthStartRequest, AuthStartResult,
    AuthVerifyRequest, AuthVerifyResult, ChatParticipantRecord, ChatParticipantsPage,
    ChatParticipantsRequest, ChatStateSnapshot, ClientErrorCategory, ClientEvent, ClientFailure,
    ClientStatus, ClientStatusSnapshot, ConnectRequest, CreateDmRequest, CreateReplyThreadRequest,
    CreateThreadRequest, CreatedChat, DeleteChatRequest, DeleteMessageRequest, DialogRecord,
    DialogsPage, DialogsRequest, EditMessageRequest, HistoryPage, HistoryRequest, InlineId,
    MessageContent, MessageMutation, MessageRecord, RandomId, ReactRequest, ReadRequest,
    RemoveChatParticipantRequest, SendTextRequest, SetMarkedUnreadRequest, TransactionEvent,
    TransactionId, TransactionIdentity, TransactionState, TypingRequest, UpdateChatInfoRequest,
    UpdateDialogNotificationsRequest, UploadRequest,
};

/// Result type returned by client backends.
pub type BackendResult<T> = Result<T, BackendError>;

/// Redacted backend error.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{category:?}: {message}")]
#[non_exhaustive]
pub struct BackendError {
    /// Stable error category.
    pub category: ClientErrorCategory,
    /// Redacted message suitable for hosts.
    pub message: String,
    /// Server-requested retry delay, when the failure is rate limited.
    pub retry_after_seconds: Option<u64>,
}

impl BackendError {
    /// Creates a backend error.
    pub fn new(category: ClientErrorCategory, message: impl Into<String>) -> Self {
        Self {
            category,
            message: message.into(),
            retry_after_seconds: None,
        }
    }

    /// Attaches a server-requested retry delay.
    pub fn with_retry_after_seconds(mut self, seconds: u64) -> Self {
        self.retry_after_seconds = (seconds > 0).then_some(seconds);
        self
    }
}

impl From<BackendError> for ClientFailure {
    fn from(error: BackendError) -> Self {
        Self::new(error.category, error.message)
    }
}

pub(crate) fn retry_after_seconds_from_message(message: &str) -> Option<u64> {
    let normalized = message.to_ascii_lowercase();
    for marker in ["retry after ", "retry_after=", "flood_wait_"] {
        let Some((_, suffix)) = normalized.split_once(marker) else {
            continue;
        };
        let Ok(seconds) = suffix
            .chars()
            .take_while(char::is_ascii_digit)
            .collect::<String>()
            .parse::<u64>()
        else {
            continue;
        };
        if seconds > 0 {
            return Some(seconds);
        }
    }
    None
}

/// Outcome from a text-send operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SendTextOutcome {
    /// Client mutation acknowledgement.
    pub mutation: MessageMutation,
    /// Chat containing the message.
    pub chat_id: InlineId,
    /// Final message ID, when known.
    pub message_id: Option<InlineId>,
    /// Message record applied to the client store, when known.
    pub message: Option<MessageRecord>,
    /// Durable transaction state after the send attempt.
    pub state: TransactionState,
    /// Redacted failure, when the transaction failed.
    pub failure: Option<ClientFailure>,
}

/// Outcome from a side-effect operation.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OperationOutcome {
    /// Committed client events caused by the operation.
    pub events: Vec<ClientEvent>,
}

impl OperationOutcome {
    /// Creates an outcome with no committed events.
    pub fn empty() -> Self {
        Self::default()
    }

    /// Creates an outcome with committed events.
    pub fn with_events(events: Vec<ClientEvent>) -> Self {
        Self { events }
    }
}

impl SendTextOutcome {
    /// Creates a text-send outcome.
    pub fn new(mutation: MessageMutation, chat_id: InlineId, message_id: Option<InlineId>) -> Self {
        Self::with_state(
            mutation,
            chat_id,
            message_id,
            None,
            TransactionState::Completed,
            None,
        )
    }

    /// Creates a text-send outcome with an explicit transaction state.
    pub fn with_state(
        mutation: MessageMutation,
        chat_id: InlineId,
        message_id: Option<InlineId>,
        message: Option<MessageRecord>,
        state: TransactionState,
        failure: Option<ClientFailure>,
    ) -> Self {
        Self {
            mutation,
            chat_id,
            message_id,
            message,
            state,
            failure,
        }
    }

    /// Returns a transaction event for this send outcome.
    pub fn transaction_event(&self) -> TransactionEvent {
        TransactionEvent {
            identity: self.mutation.transaction.clone(),
            state: self.state,
            failure: self.failure.clone(),
        }
    }
}

/// Async backend boundary for the client runner.
pub trait ClientBackend: fmt::Debug + Send + Sync + 'static {
    /// Sends an Inline login code.
    fn auth_start(
        &self,
        request: AuthStartRequest,
    ) -> BoxFuture<'static, BackendResult<AuthStartResult>>;

    /// Verifies an Inline login code and persists the resulting session.
    fn auth_verify(
        &self,
        request: AuthVerifyRequest,
    ) -> BoxFuture<'static, BackendResult<AuthVerifyResult>>;

    /// Resumes a previously stored session, if available.
    fn resume_session(&self) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>>;

    /// Connects or reconnects the client.
    fn connect(
        &self,
        request: ConnectRequest,
    ) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>>;

    /// Logs out the current account.
    fn logout(&self) -> BoxFuture<'static, BackendResult<()>>;

    /// Lists dialogs.
    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, BackendResult<DialogsPage>>;

    /// Lists only durable cached dialogs without a network request.
    fn cached_dialogs(
        &self,
        request: DialogsRequest,
    ) -> BoxFuture<'static, BackendResult<DialogsPage>>;

    /// Loads account-level durable state used for consumer reconciliation.
    fn account_state(&self) -> BoxFuture<'static, BackendResult<AccountStateSnapshot>>;

    /// Loads durable state for one chat used for consumer reconciliation.
    fn chat_state(&self, chat_id: InlineId)
    -> BoxFuture<'static, BackendResult<ChatStateSnapshot>>;

    /// Fetches chat history.
    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, BackendResult<HistoryPage>>;

    /// Fetches only the client's durable cached history without making a
    /// network request. This is intended for offline consumers and state
    /// reconciliation; ordinary callers should prefer [`Self::history`].
    fn cached_history(
        &self,
        request: HistoryRequest,
    ) -> BoxFuture<'static, BackendResult<HistoryPage>>;

    /// Fetches chat participants.
    fn chat_participants(
        &self,
        request: ChatParticipantsRequest,
    ) -> BoxFuture<'static, BackendResult<ChatParticipantsPage>>;

    /// Adds a user to a chat.
    fn add_chat_participant(
        &self,
        request: AddChatParticipantRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Removes a user from a chat.
    fn remove_chat_participant(
        &self,
        request: RemoveChatParticipantRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Updates mutable chat metadata.
    fn update_chat_info(
        &self,
        request: UpdateChatInfoRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Deletes a chat when permitted by the service.
    fn delete_chat(
        &self,
        request: DeleteChatRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Creates or opens a direct message chat.
    fn create_dm(&self, request: CreateDmRequest)
    -> BoxFuture<'static, BackendResult<CreatedChat>>;

    /// Creates a regular Inline thread chat.
    fn create_thread(
        &self,
        request: CreateThreadRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>>;

    /// Creates a child/reply Inline thread chat.
    fn create_reply_thread(
        &self,
        request: CreateReplyThreadRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>>;

    /// Sends a text message.
    fn send_text(
        &self,
        request: SendTextRequest,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>>;

    /// Uploads and sends a media message.
    fn send_media(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>>;

    /// Edits a text message.
    fn edit_message(
        &self,
        request: EditMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Deletes or unsends a message.
    fn delete_message(
        &self,
        request: DeleteMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Adds or removes a reaction.
    fn react(&self, request: ReactRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Marks messages read.
    fn read(&self, request: ReadRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Sets the explicit marked-unread state for a chat.
    fn set_marked_unread(
        &self,
        request: SetMarkedUnreadRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Sets or clears a per-dialog notification override.
    fn update_dialog_notifications(
        &self,
        request: UpdateDialogNotificationsRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Sends a typing state.
    fn typing(&self, request: TypingRequest)
    -> BoxFuture<'static, BackendResult<OperationOutcome>>;

    /// Receives the next batch of server-pushed client events.
    fn receive_events(&self) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>>;
}

/// In-memory backend for client, bridge-adapter, and runtime tests.
#[derive(Clone, Debug, Default)]
pub struct InMemoryBackend {
    state: Arc<Mutex<InMemoryBackendState>>,
}

#[derive(Debug)]
struct InMemoryBackendState {
    connected: bool,
    account_namespace: Option<String>,
    dialogs: Vec<DialogRecord>,
    participants: HashMap<i64, Vec<ChatParticipantRecord>>,
    messages: HashMap<i64, Vec<MessageRecord>>,
    event_batches: VecDeque<BackendResult<Vec<ClientEvent>>>,
    next_chat_id: i64,
    next_message_id: i64,
    next_random_id: i64,
    next_transaction_id: u64,
}

impl Default for InMemoryBackendState {
    fn default() -> Self {
        Self {
            connected: false,
            account_namespace: None,
            dialogs: Vec::new(),
            participants: HashMap::new(),
            messages: HashMap::new(),
            event_batches: VecDeque::new(),
            next_chat_id: 10_000,
            next_message_id: 1,
            next_random_id: 1,
            next_transaction_id: 1,
        }
    }
}

impl InMemoryBackend {
    /// Creates an empty in-memory backend.
    pub fn new() -> Self {
        Self::default()
    }

    /// Inserts or replaces a dialog.
    pub fn upsert_dialog(&self, dialog: DialogRecord) {
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        if let Some(existing) = state
            .dialogs
            .iter_mut()
            .find(|existing| existing.chat_id == dialog.chat_id)
        {
            *existing = dialog;
            return;
        }
        state.dialogs.push(dialog);
    }

    /// Replaces the participant snapshot for a chat.
    pub fn set_chat_participants(
        &self,
        chat_id: InlineId,
        participants: Vec<ChatParticipantRecord>,
    ) {
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        state.participants.insert(chat_id.get(), participants);
    }

    /// Inserts a message into the in-memory history.
    pub fn insert_message(&self, message: MessageRecord) {
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        let chat_id = message.chat_id.get();
        state.messages.entry(chat_id).or_default().push(message);
        if let Some(messages) = state.messages.get_mut(&chat_id) {
            messages.sort_by_key(|message| (message.timestamp, message.message_id.get()));
        }
    }

    /// Queues a server-pushed event batch for [`ClientBackend::receive_events`].
    pub fn push_event_batch(&self, events: Vec<ClientEvent>) {
        self.state
            .lock()
            .expect("in-memory backend poisoned")
            .event_batches
            .push_back(Ok(events));
    }

    /// Queues a server-pushed receive error for [`ClientBackend::receive_events`].
    pub fn push_event_error(&self, error: BackendError) {
        self.state
            .lock()
            .expect("in-memory backend poisoned")
            .event_batches
            .push_back(Err(error));
    }

    /// Returns whether the backend is connected.
    pub fn is_connected(&self) -> bool {
        self.state
            .lock()
            .expect("in-memory backend poisoned")
            .connected
    }

    fn connect_now(&self, request: ConnectRequest) -> BackendResult<ClientStatusSnapshot> {
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        state.connected = true;
        state.account_namespace = request.account_namespace;
        Ok(ClientStatusSnapshot::current(ClientStatus::Connected))
    }

    fn auth_start_now(&self, request: AuthStartRequest) -> BackendResult<AuthStartResult> {
        if request.contact.trim().is_empty() {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "auth contact must not be empty",
            ));
        }
        Ok(AuthStartResult {
            existing_user: true,
            needs_invite_code: false,
            challenge_token: None,
        })
    }

    fn auth_verify_now(&self, request: AuthVerifyRequest) -> BackendResult<AuthVerifyResult> {
        if request.contact.trim().is_empty() {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "auth contact must not be empty",
            ));
        }
        if request.code.trim().is_empty() {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "verification code must not be empty",
            ));
        }
        let account_namespace = request
            .account_namespace
            .map(|namespace| namespace.trim().to_owned())
            .filter(|namespace| !namespace.is_empty())
            .unwrap_or_else(|| "1".to_owned());
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        state.connected = true;
        state.account_namespace = Some(account_namespace.clone());
        Ok(AuthVerifyResult {
            user_id: InlineId::new(1),
            account_namespace,
            status: ClientStatusSnapshot::current(ClientStatus::Connected),
        })
    }

    fn resume_session_now(&self) -> BackendResult<ClientStatusSnapshot> {
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        if state.connected || state.account_namespace.is_some() {
            state.connected = true;
            Ok(ClientStatusSnapshot::current(ClientStatus::Connected))
        } else {
            Ok(ClientStatusSnapshot::current(ClientStatus::AuthRequired))
        }
    }

    fn logout_now(&self) -> BackendResult<()> {
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        state.connected = false;
        Ok(())
    }

    fn dialogs_now(&self, request: DialogsRequest) -> BackendResult<DialogsPage> {
        self.require_connected()?;
        let state = self.state.lock().expect("in-memory backend poisoned");
        let start = parse_cursor(request.cursor.as_deref())?;
        let limit = request.limit.unwrap_or(50).max(1) as usize;
        let dialogs = state
            .dialogs
            .iter()
            .skip(start)
            .take(limit)
            .map(|dialog| {
                let mut dialog = dialog.clone();
                dialog.synced_through_message_id =
                    max_message_id_from_backend(&state.messages, dialog.chat_id);
                dialog
            })
            .collect::<Vec<_>>();
        let next = start + dialogs.len();
        Ok(DialogsPage {
            dialogs,
            users: Vec::new(),
            next_cursor: (next < state.dialogs.len()).then(|| next.to_string()),
        })
    }

    fn history_now(&self, request: HistoryRequest) -> BackendResult<HistoryPage> {
        self.require_connected()?;
        let state = self.state.lock().expect("in-memory backend poisoned");
        let mut messages = state
            .messages
            .get(&request.chat_id.get())
            .cloned()
            .unwrap_or_default();
        messages.sort_by_key(|message| (message.timestamp, message.message_id.get()));
        if request.before_message_id.is_some() && request.after_message_id.is_some() {
            return Err(BackendError::new(
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
        Ok(HistoryPage {
            messages,
            users: Vec::new(),
            has_more,
            next_cursor: None,
        })
    }

    fn send_text_now(&self, request: SendTextRequest) -> BackendResult<SendTextOutcome> {
        self.require_connected()?;
        if request.text.trim().is_empty() {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "message text must not be empty",
            ));
        }

        let mut state = self.state.lock().expect("in-memory backend poisoned");
        let chat_id = chat_id_for_peer(request.peer);
        let message_id = InlineId::new(state.next_message_id);
        state.next_message_id += 1;
        let random_id = request.random_id.unwrap_or_else(|| {
            let id = RandomId::new(state.next_random_id);
            state.next_random_id += 1;
            id
        });
        let transaction_id = TransactionId::try_new(format!("mem-{}", state.next_transaction_id))
            .expect("generated transaction id is valid");
        state.next_transaction_id += 1;

        let transaction = TransactionIdentity::new(transaction_id, request.external_id, random_id)
            .with_final_message_id(message_id);
        let message = MessageRecord {
            chat_id,
            message_id,
            sender_id: InlineId::new(0),
            timestamp: message_id.get(),
            is_outgoing: true,
            content: MessageContent::Text { text: request.text },
            reply_to_message_id: request.reply_to_message_id,
            transaction: Some(transaction.clone()),
        };
        state
            .messages
            .entry(chat_id.get())
            .or_default()
            .push(message.clone());
        crate::store::upsert_dialog_last_message(&mut state.dialogs, chat_id, message_id);

        Ok(SendTextOutcome::with_state(
            MessageMutation {
                transaction,
                message_id: Some(message_id),
                state: None,
                failure: None,
            },
            chat_id,
            Some(message_id),
            Some(message),
            TransactionState::Completed,
            None,
        ))
    }

    fn create_chat_now(
        &self,
        title: Option<String>,
        parent_chat_id: Option<InlineId>,
        parent_message_id: Option<InlineId>,
        participants: Vec<ChatParticipantRecord>,
    ) -> BackendResult<CreatedChat> {
        self.require_connected()?;
        let title = title
            .map(|title| title.trim().to_owned())
            .filter(|title| !title.is_empty());
        let mut state = self.state.lock().expect("in-memory backend poisoned");
        let chat_id = InlineId::new(state.next_chat_id);
        state.next_chat_id += 1;
        state.dialogs.push(DialogRecord {
            chat_id,
            peer_user_id: None,
            title: title.clone(),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
            ..DialogRecord::new(chat_id)
        });
        if !participants.is_empty() {
            state.participants.insert(chat_id.get(), participants);
        }
        Ok(CreatedChat {
            chat_id,
            title,
            parent_chat_id,
            parent_message_id,
        })
    }

    fn send_media_now(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
    ) -> BackendResult<SendTextOutcome> {
        self.require_connected()?;
        if bytes.is_empty() {
            return Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "media bytes must not be empty",
            ));
        }

        let mut state = self.state.lock().expect("in-memory backend poisoned");
        let chat_id = chat_id_for_peer(request.peer);
        let message_id = InlineId::new(state.next_message_id);
        state.next_message_id += 1;
        let random_id = request.random_id.unwrap_or_else(|| {
            let id = RandomId::new(state.next_random_id);
            state.next_random_id += 1;
            id
        });
        let transaction_id =
            TransactionId::try_new(format!("mem-upload-{}", state.next_transaction_id))
                .expect("generated transaction id is valid");
        state.next_transaction_id += 1;

        let transaction =
            TransactionIdentity::new(transaction_id, request.external_id.clone(), random_id)
                .with_final_message_id(message_id);
        let message = MessageRecord {
            chat_id,
            message_id,
            sender_id: InlineId::new(0),
            timestamp: message_id.get(),
            is_outgoing: true,
            content: MessageContent::Media {
                kind: request.kind,
                file_id: format!("mem-file-{}", message_id.get()),
                url: None,
                mime_type: request.mime_type.clone(),
                file_name: request.file_name.clone(),
                caption: request.caption.clone(),
                size_bytes: request.size_bytes.or(Some(bytes.len() as u64)),
                width: request.width,
                height: request.height,
                duration_ms: request.duration_ms,
            },
            reply_to_message_id: request.reply_to_message_id,
            transaction: Some(transaction.clone()),
        };
        state
            .messages
            .entry(chat_id.get())
            .or_default()
            .push(message.clone());
        crate::store::upsert_dialog_last_message(&mut state.dialogs, chat_id, message_id);

        Ok(SendTextOutcome::with_state(
            MessageMutation {
                transaction,
                message_id: Some(message_id),
                state: None,
                failure: None,
            },
            chat_id,
            Some(message_id),
            Some(message),
            TransactionState::Completed,
            None,
        ))
    }

    fn require_connected(&self) -> BackendResult<()> {
        if self
            .state
            .lock()
            .expect("in-memory backend poisoned")
            .connected
        {
            Ok(())
        } else {
            Err(BackendError::new(
                ClientErrorCategory::AuthRequired,
                "client is not connected",
            ))
        }
    }
}

impl ClientBackend for InMemoryBackend {
    fn auth_start(
        &self,
        request: AuthStartRequest,
    ) -> BoxFuture<'static, BackendResult<AuthStartResult>> {
        let backend = self.clone();
        Box::pin(async move { backend.auth_start_now(request) })
    }

    fn auth_verify(
        &self,
        request: AuthVerifyRequest,
    ) -> BoxFuture<'static, BackendResult<AuthVerifyResult>> {
        let backend = self.clone();
        Box::pin(async move { backend.auth_verify_now(request) })
    }

    fn resume_session(&self) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>> {
        let backend = self.clone();
        Box::pin(async move { backend.resume_session_now() })
    }

    fn connect(
        &self,
        request: ConnectRequest,
    ) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>> {
        let backend = self.clone();
        Box::pin(async move { backend.connect_now(request) })
    }

    fn logout(&self) -> BoxFuture<'static, BackendResult<()>> {
        let backend = self.clone();
        Box::pin(async move { backend.logout_now() })
    }

    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, BackendResult<DialogsPage>> {
        let backend = self.clone();
        Box::pin(async move { backend.dialogs_now(request) })
    }

    fn cached_dialogs(
        &self,
        request: DialogsRequest,
    ) -> BoxFuture<'static, BackendResult<DialogsPage>> {
        let backend = self.clone();
        Box::pin(async move { backend.dialogs_now(request) })
    }

    fn account_state(&self) -> BoxFuture<'static, BackendResult<AccountStateSnapshot>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            Ok(AccountStateSnapshot::default())
        })
    }

    fn chat_state(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, BackendResult<ChatStateSnapshot>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            let state = backend.state.lock().expect("in-memory backend poisoned");
            let dialog = state
                .dialogs
                .iter()
                .find(|dialog| dialog.chat_id == chat_id)
                .cloned();
            let participants = state
                .participants
                .get(&chat_id.get())
                .cloned()
                .unwrap_or_default();
            Ok(ChatStateSnapshot {
                chat_id,
                dialog,
                deleted: false,
                deleted_message_ids: Vec::new(),
                reactions: Vec::new(),
                reaction_snapshot_message_ids: Vec::new(),
                read_state: None,
                participants,
                participants_complete: true,
            })
        })
    }

    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, BackendResult<HistoryPage>> {
        let backend = self.clone();
        Box::pin(async move { backend.history_now(request) })
    }

    fn cached_history(
        &self,
        request: HistoryRequest,
    ) -> BoxFuture<'static, BackendResult<HistoryPage>> {
        let backend = self.clone();
        Box::pin(async move { backend.history_now(request) })
    }

    fn chat_participants(
        &self,
        request: ChatParticipantsRequest,
    ) -> BoxFuture<'static, BackendResult<ChatParticipantsPage>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            let state = backend.state.lock().expect("in-memory backend poisoned");
            Ok(ChatParticipantsPage {
                participants: state
                    .participants
                    .get(&request.chat_id.get())
                    .cloned()
                    .unwrap_or_default(),
                users: Vec::new(),
            })
        })
    }

    fn add_chat_participant(
        &self,
        request: AddChatParticipantRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            if request.chat_id.get() <= 0 || request.user_id.get() <= 0 {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "chat_id and user_id must be positive",
                ));
            }
            let mut state = backend.state.lock().expect("in-memory backend poisoned");
            let participants = state.participants.entry(request.chat_id.get()).or_default();
            if !participants
                .iter()
                .any(|participant| participant.user_id == request.user_id)
            {
                participants.push(ChatParticipantRecord {
                    user_id: request.user_id,
                    date: None,
                });
            }
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ChatParticipantsChanged {
                    chat_id: request.chat_id,
                },
            ]))
        })
    }

    fn remove_chat_participant(
        &self,
        request: RemoveChatParticipantRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            let mut state = backend.state.lock().expect("in-memory backend poisoned");
            state
                .participants
                .entry(request.chat_id.get())
                .or_default()
                .retain(|participant| participant.user_id != request.user_id);
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ChatParticipantsChanged {
                    chat_id: request.chat_id,
                },
            ]))
        })
    }

    fn update_chat_info(
        &self,
        request: UpdateChatInfoRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            if request.title.is_none() && request.emoji.is_none() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "at least one chat info field must be provided",
                ));
            }
            if let Some(title) = request.title {
                if title.trim().is_empty() {
                    return Err(BackendError::new(
                        ClientErrorCategory::InvalidInput,
                        "chat title must not be empty",
                    ));
                }
                if let Some(dialog) = backend
                    .state
                    .lock()
                    .expect("in-memory backend poisoned")
                    .dialogs
                    .iter_mut()
                    .find(|dialog| dialog.chat_id == request.chat_id)
                {
                    dialog.title = Some(title.trim().to_owned());
                }
            }
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ChatUpserted {
                    chat_id: request.chat_id,
                },
            ]))
        })
    }

    fn delete_chat(
        &self,
        request: DeleteChatRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            let mut state = backend.state.lock().expect("in-memory backend poisoned");
            state
                .dialogs
                .retain(|dialog| dialog.chat_id != request.chat_id);
            state.participants.remove(&request.chat_id.get());
            state.messages.remove(&request.chat_id.get());
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ChatDeleted {
                    chat_id: request.chat_id,
                },
            ]))
        })
    }

    fn create_dm(
        &self,
        request: CreateDmRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>> {
        let backend = self.clone();
        Box::pin(async move {
            if request.user_id.get() <= 0 {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "user_id must be positive",
                ));
            }
            backend.create_chat_now(
                Some(format!("DM {}", request.user_id.get())),
                None,
                None,
                vec![
                    ChatParticipantRecord {
                        user_id: InlineId::new(0),
                        date: None,
                    },
                    ChatParticipantRecord {
                        user_id: request.user_id,
                        date: None,
                    },
                ],
            )
        })
    }

    fn create_thread(
        &self,
        request: CreateThreadRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>> {
        let backend = self.clone();
        Box::pin(async move {
            let participants = request
                .participants
                .into_iter()
                .map(|participant| ChatParticipantRecord {
                    user_id: participant.user_id,
                    date: None,
                })
                .collect();
            backend.create_chat_now(request.title, None, None, participants)
        })
    }

    fn create_reply_thread(
        &self,
        request: CreateReplyThreadRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>> {
        let backend = self.clone();
        Box::pin(async move {
            if request.parent_chat_id.get() <= 0 {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "parent_chat_id must be positive",
                ));
            }
            let participants = request
                .participants
                .into_iter()
                .map(|participant| ChatParticipantRecord {
                    user_id: participant.user_id,
                    date: None,
                })
                .collect();
            backend.create_chat_now(
                request.title,
                Some(request.parent_chat_id),
                request.parent_message_id,
                participants,
            )
        })
    }

    fn send_text(
        &self,
        request: SendTextRequest,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>> {
        let backend = self.clone();
        Box::pin(async move { backend.send_text_now(request) })
    }

    fn send_media(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>> {
        let backend = self.clone();
        Box::pin(async move { backend.send_media_now(request, bytes) })
    }

    fn edit_message(
        &self,
        request: EditMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            if request.text.trim().is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "message text must not be empty",
                ));
            }
            let mut state = backend.state.lock().expect("in-memory backend poisoned");
            let messages = state.messages.entry(request.chat_id.get()).or_default();
            if let Some(message) = messages
                .iter_mut()
                .find(|message| message.message_id == request.message_id)
            {
                message.content = MessageContent::Text { text: request.text };
                return Ok(OperationOutcome::with_events(vec![
                    ClientEvent::MessageStored {
                        message: message.clone(),
                    },
                ]));
            }
            Err(BackendError::new(
                ClientErrorCategory::InvalidInput,
                "message not found",
            ))
        })
    }

    fn delete_message(
        &self,
        request: DeleteMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            let mut state = backend.state.lock().expect("in-memory backend poisoned");
            let messages = state.messages.entry(request.chat_id.get()).or_default();
            messages.retain(|message| message.message_id != request.message_id);
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::MessageDeleted {
                    chat_id: request.chat_id,
                    message_id: request.message_id,
                },
            ]))
        })
    }

    fn react(&self, request: ReactRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            if request.reaction.trim().is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "reaction must not be empty",
                ));
            }
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ReactionChanged {
                    chat_id: request.chat_id,
                    message_id: request.message_id,
                    user_id: InlineId::new(0),
                    reaction: request.reaction,
                    removed: request.remove,
                },
            ]))
        })
    }

    fn read(&self, request: ReadRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ReadStateChanged {
                    chat_id: request.chat_id,
                },
            ]))
        })
    }

    fn set_marked_unread(
        &self,
        request: SetMarkedUnreadRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ReadStateChanged {
                    chat_id: request.chat_id,
                },
            ]))
        })
    }

    fn update_dialog_notifications(
        &self,
        request: UpdateDialogNotificationsRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            if let Some(dialog) = backend
                .state
                .lock()
                .expect("in-memory backend poisoned")
                .dialogs
                .iter_mut()
                .find(|dialog| dialog.chat_id == request.chat_id)
            {
                dialog.notification_mode = request.mode;
            }
            Ok(OperationOutcome::with_events(vec![
                ClientEvent::ChatUpserted {
                    chat_id: request.chat_id,
                },
            ]))
        })
    }

    fn typing(
        &self,
        request: TypingRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            backend.require_connected()?;
            Ok(OperationOutcome::with_events(vec![ClientEvent::Typing {
                chat_id: request.chat_id,
                user_id: InlineId::new(0),
                is_typing: request.is_typing,
            }]))
        })
    }

    fn receive_events(&self) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>> {
        let backend = self.clone();
        Box::pin(async move {
            loop {
                {
                    let mut state = backend.state.lock().expect("in-memory backend poisoned");
                    if !state.connected {
                        return Err(BackendError::new(
                            ClientErrorCategory::AuthRequired,
                            "client is not connected",
                        ));
                    }
                    if let Some(events) = state.event_batches.pop_front() {
                        return events;
                    }
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
    }
}

fn parse_cursor(cursor: Option<&str>) -> BackendResult<usize> {
    match cursor {
        Some(cursor) if !cursor.trim().is_empty() => cursor.parse::<usize>().map_err(|_| {
            BackendError::new(
                ClientErrorCategory::InvalidInput,
                "invalid pagination cursor",
            )
        }),
        _ => Ok(0),
    }
}

fn max_message_id_from_backend(
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

fn chat_id_for_peer(peer: crate::PeerRef) -> InlineId {
    match peer {
        crate::PeerRef::User { user_id } => user_id,
        crate::PeerRef::Chat { chat_id } => chat_id,
        crate::PeerRef::Thread { thread_id } => thread_id,
    }
}

#[cfg(test)]
mod tests {
    use crate::{PeerRef, SendTextRequest};

    use super::*;

    fn token_connect() -> ConnectRequest {
        ConnectRequest::new(crate::AuthCredential::AccessToken {
            token: crate::AuthToken::try_new("token").unwrap(),
        })
    }

    #[tokio::test]
    async fn in_memory_backend_requires_connect_for_dialogs() {
        let backend = InMemoryBackend::new();

        let err = backend
            .dialogs(DialogsRequest::default())
            .await
            .expect_err("dialogs should require connect");

        assert_eq!(err.category, ClientErrorCategory::AuthRequired);
    }

    #[tokio::test]
    async fn in_memory_backend_lists_dialogs_with_cursor() {
        let backend = InMemoryBackend::new();
        backend.upsert_dialog(DialogRecord {
            chat_id: InlineId::new(1),
            peer_user_id: None,
            title: Some("one".to_owned()),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
            ..DialogRecord::new(InlineId::new(1))
        });
        backend.upsert_dialog(DialogRecord {
            chat_id: InlineId::new(2),
            peer_user_id: Some(InlineId::new(3)),
            title: Some("two".to_owned()),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
            ..DialogRecord::new(InlineId::new(2))
        });
        backend.connect(token_connect()).await.unwrap();

        let first = backend
            .dialogs(DialogsRequest {
                limit: Some(1),
                cursor: None,
            })
            .await
            .unwrap();
        assert_eq!(first.dialogs[0].chat_id, InlineId::new(1));
        assert_eq!(first.next_cursor.as_deref(), Some("1"));

        let second = backend
            .dialogs(DialogsRequest {
                limit: Some(1),
                cursor: first.next_cursor,
            })
            .await
            .unwrap();
        assert_eq!(second.dialogs[0].chat_id, InlineId::new(2));
        assert_eq!(second.next_cursor, None);
    }

    #[tokio::test]
    async fn in_memory_backend_returns_chat_participants() {
        let backend = InMemoryBackend::new();
        backend.set_chat_participants(
            InlineId::new(7),
            vec![ChatParticipantRecord {
                user_id: InlineId::new(42),
                date: Some(100),
            }],
        );
        backend.connect(token_connect()).await.unwrap();

        let page = backend
            .chat_participants(ChatParticipantsRequest {
                chat_id: InlineId::new(7),
            })
            .await
            .unwrap();

        assert_eq!(page.participants.len(), 1);
        assert_eq!(page.participants[0].user_id, InlineId::new(42));
        assert_eq!(page.participants[0].date, Some(100));
    }

    #[tokio::test]
    async fn in_memory_backend_sends_text_and_records_history() {
        let backend = InMemoryBackend::new();
        backend.connect(token_connect()).await.unwrap();

        let outcome = backend
            .send_text(SendTextRequest::new(
                PeerRef::Chat {
                    chat_id: InlineId::new(7),
                },
                "hello",
            ))
            .await
            .unwrap();

        assert_eq!(outcome.chat_id, InlineId::new(7));
        assert_eq!(outcome.message_id, Some(InlineId::new(1)));

        let history = backend
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(10),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();
        assert_eq!(history.messages.len(), 1);
        assert_eq!(history.messages[0].message_id, InlineId::new(1));
    }

    #[tokio::test]
    async fn in_memory_backend_rejects_empty_text() {
        let backend = InMemoryBackend::new();
        backend.connect(token_connect()).await.unwrap();

        let err = backend
            .send_text(SendTextRequest::new(
                PeerRef::Chat {
                    chat_id: InlineId::new(7),
                },
                " ",
            ))
            .await
            .expect_err("empty message should fail");

        assert_eq!(err.category, ClientErrorCategory::InvalidInput);
    }
}

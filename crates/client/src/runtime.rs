//! Async client facade and runner.
//!
//! This module establishes the TDLib-style host shape: cheap cloneable handle,
//! single owner runner, bounded command queue, and broadcast committed events.
//! Transport, sync, store, and transaction managers plug into this runner
//! instead of being spread across bridges or agents.

use std::{
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio::task::{JoinHandle, JoinSet};

use crate::backend::retry_after_seconds_from_message;
use crate::{
    AccountStateSnapshot, AddChatParticipantRequest, AuthStartRequest, AuthStartResult,
    AuthVerifyRequest, AuthVerifyResult, BackendError, BackendResult, ChatParticipantsPage,
    ChatParticipantsRequest, ChatStateSnapshot, ClientBackend, ClientErrorCategory, ClientEvent,
    ClientFailure, ClientStatus, ClientStatusSnapshot, ConnectRequest, CreateDmRequest,
    CreateReplyThreadRequest, CreateThreadRequest, CreatedChat, DeleteChatRequest,
    DeleteMessageRequest, DialogsPage, DialogsRequest, EditMessageRequest, HistoryPage,
    HistoryRequest, InMemoryBackend, InlineId, MessageMutation, OperationOutcome, ReactRequest,
    ReadRequest, RemoveChatParticipantRequest, SendTextOutcome, SendTextRequest,
    SetMarkedUnreadRequest, TypingRequest, UpdateChatInfoRequest, UpdateDialogNotificationsRequest,
    UploadRequest,
};

/// Default bounded command queue capacity.
pub const DEFAULT_COMMAND_QUEUE_CAPACITY: usize = 128;
/// Default maximum number of concurrent backend requests.
pub const DEFAULT_MAX_CONCURRENT_REQUESTS: usize = 32;

/// Default broadcast event queue capacity.
pub const DEFAULT_EVENT_QUEUE_CAPACITY: usize = 1024;
/// Default bounded queue capacity for the optional single lossless consumer.
pub const DEFAULT_LOSSLESS_EVENT_QUEUE_CAPACITY: usize = 4096;

/// Reconnect/backoff policy for the long-lived backend event receiver.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReconnectPolicy {
    /// Delay before the first network/timeout retry.
    pub initial_delay: Duration,
    /// Maximum network/timeout retry delay.
    pub max_delay: Duration,
    /// Delay before the first rate-limit retry when no server hint is present.
    pub rate_limit_initial_delay: Duration,
    /// Maximum rate-limit retry delay.
    pub rate_limit_max_delay: Duration,
    /// Symmetric percentage of jitter applied to retry delays.
    pub jitter_percent: u8,
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_secs(1),
            max_delay: Duration::from_secs(60),
            rate_limit_initial_delay: Duration::from_secs(30),
            rate_limit_max_delay: Duration::from_secs(5 * 60),
            jitter_percent: 20,
        }
    }
}

/// Errors returned by the async client handle before an operation reaches the backend.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum ClientCommandError {
    /// The client runner has stopped accepting commands.
    #[error("inline client runner is closed")]
    Closed,

    /// The client runner dropped a command response before completing it.
    #[error("inline client runner dropped command response")]
    ResponseDropped,
}

/// Errors returned by typed client operations.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum ClientRequestError {
    /// The operation could not be delivered to the runner.
    #[error(transparent)]
    Command(#[from] ClientCommandError),

    /// The backend rejected or failed the operation.
    #[error(transparent)]
    Backend(#[from] BackendError),
}

/// Builder for an [`InlineClient`] runtime.
#[derive(Clone, Debug)]
pub struct InlineClientBuilder {
    command_queue_capacity: usize,
    max_concurrent_requests: usize,
    event_queue_capacity: usize,
    lossless_event_queue_capacity: usize,
    reconnect_policy: ReconnectPolicy,
    initial_status: ClientStatus,
    backend: Arc<dyn ClientBackend>,
}

impl InlineClientBuilder {
    /// Sets the backend used by the runner.
    pub fn backend(mut self, backend: impl ClientBackend) -> Self {
        self.backend = Arc::new(backend);
        self
    }

    /// Sets the shared backend used by the runner.
    pub fn shared_backend(mut self, backend: Arc<dyn ClientBackend>) -> Self {
        self.backend = backend;
        self
    }

    /// Sets the bounded command queue capacity.
    pub fn command_queue_capacity(mut self, capacity: usize) -> Self {
        self.command_queue_capacity = capacity.max(1);
        self
    }

    /// Sets the maximum number of backend requests allowed in flight.
    pub fn max_concurrent_requests(mut self, maximum: usize) -> Self {
        self.max_concurrent_requests = maximum.max(1);
        self
    }

    /// Sets the broadcast event queue capacity.
    pub fn event_queue_capacity(mut self, capacity: usize) -> Self {
        self.event_queue_capacity = capacity.max(1);
        self
    }

    /// Sets the bounded queue capacity for the optional lossless event consumer.
    pub fn lossless_event_queue_capacity(mut self, capacity: usize) -> Self {
        self.lossless_event_queue_capacity = capacity.max(1);
        self
    }

    /// Sets event-stream reconnect and rate-limit backoff policy.
    pub fn reconnect_policy(mut self, policy: ReconnectPolicy) -> Self {
        self.reconnect_policy = policy;
        self
    }

    /// Sets the initial client status.
    pub fn initial_status(mut self, status: ClientStatus) -> Self {
        self.initial_status = status;
        self
    }

    /// Builds a client handle and runner pair.
    pub fn build(self) -> InlineClientRuntime {
        let (command_tx, command_rx) = mpsc::channel(self.command_queue_capacity);
        let (event_tx, _) = broadcast::channel(self.event_queue_capacity);
        let (lossless_event_tx, lossless_event_rx) =
            mpsc::channel(self.lossless_event_queue_capacity);
        let lossless_event_active = Arc::new(AtomicBool::new(false));
        let (status_tx, status_rx) = watch::channel(self.initial_status);
        let (failure_tx, failure_rx) = watch::channel(None);
        let (signal_tx, signal_rx) = mpsc::channel(self.command_queue_capacity);

        let client = InlineClient {
            command_tx,
            event_tx: event_tx.clone(),
            lossless_event_rx: Arc::new(StdMutex::new(Some(lossless_event_rx))),
            lossless_event_active: lossless_event_active.clone(),
            status_rx,
            failure_rx,
        };
        let event_emitter = ClientEventEmitter {
            broadcast: event_tx,
            lossless: lossless_event_tx,
            lossless_active: lossless_event_active,
        };
        let runner = ClientRunner {
            command_rx,
            event_emitter,
            status_tx,
            failure_tx,
            status: self.initial_status,
            failure: None,
            backend: self.backend,
            signal_tx,
            signal_rx,
            event_task: None,
            request_tasks: JoinSet::new(),
            max_concurrent_requests: self.max_concurrent_requests,
            reconnect_policy: self.reconnect_policy,
        };

        InlineClientRuntime { client, runner }
    }
}

impl Default for InlineClientBuilder {
    fn default() -> Self {
        Self {
            command_queue_capacity: DEFAULT_COMMAND_QUEUE_CAPACITY,
            max_concurrent_requests: DEFAULT_MAX_CONCURRENT_REQUESTS,
            event_queue_capacity: DEFAULT_EVENT_QUEUE_CAPACITY,
            lossless_event_queue_capacity: DEFAULT_LOSSLESS_EVENT_QUEUE_CAPACITY,
            reconnect_policy: ReconnectPolicy::default(),
            initial_status: ClientStatus::Disconnected,
            backend: Arc::new(InMemoryBackend::default()),
        }
    }
}

/// Built client runtime before the runner is hosted.
#[derive(Debug)]
pub struct InlineClientRuntime {
    /// Cloneable client handle.
    pub client: InlineClient,
    /// Single-owner client runner.
    pub runner: ClientRunner,
}

/// Single-consumer bounded stream for hosts that must not silently lose
/// committed lossless client events.
#[derive(Debug)]
pub struct LosslessEventReceiver {
    receiver: mpsc::Receiver<ClientEvent>,
}

impl LosslessEventReceiver {
    /// Receives the next lossless event, or `None` after the client runner
    /// closes.
    pub async fn recv(&mut self) -> Option<ClientEvent> {
        self.receiver.recv().await
    }
}

impl InlineClientRuntime {
    /// Splits the runtime into handle and runner.
    pub fn split(self) -> (InlineClient, ClientRunner) {
        (self.client, self.runner)
    }

    /// Spawns the runner on the current Tokio runtime and returns the handle.
    pub fn spawn(self) -> InlineClient {
        let (client, runner) = self.split();
        tokio::spawn(runner.run());
        client
    }
}

/// Cheap cloneable handle for apps, bridges, agents, and tests.
#[derive(Clone, Debug)]
pub struct InlineClient {
    command_tx: mpsc::Sender<ClientCommand>,
    event_tx: broadcast::Sender<ClientEvent>,
    lossless_event_rx: Arc<StdMutex<Option<mpsc::Receiver<ClientEvent>>>>,
    lossless_event_active: Arc<AtomicBool>,
    status_rx: watch::Receiver<ClientStatus>,
    failure_rx: watch::Receiver<Option<ClientFailure>>,
}

impl InlineClient {
    /// Creates a default client runtime builder.
    pub fn builder() -> InlineClientBuilder {
        InlineClientBuilder::default()
    }

    /// Returns the latest observed client status.
    pub fn status(&self) -> ClientStatus {
        *self.status_rx.borrow()
    }

    /// Returns the latest observed status snapshot.
    pub fn status_snapshot(&self) -> ClientStatusSnapshot {
        ClientStatusSnapshot {
            status: *self.status_rx.borrow(),
            failure: self.failure_rx.borrow().clone(),
        }
    }

    /// Subscribes to committed client events.
    pub fn subscribe(&self) -> broadcast::Receiver<ClientEvent> {
        self.event_tx.subscribe()
    }

    /// Claims the single bounded lossless event stream.
    ///
    /// Once claimed, the runner applies backpressure before accepting more
    /// work rather than dropping lossless events. Broadcast subscribers remain
    /// independent and may still observe lag errors. Returns `None` after the
    /// lossless stream has already been claimed.
    pub fn take_lossless_events(&self) -> Option<LosslessEventReceiver> {
        let receiver = self
            .lossless_event_rx
            .lock()
            .expect("lossless event receiver poisoned")
            .take()?;
        self.lossless_event_active.store(true, Ordering::Release);
        Some(LosslessEventReceiver { receiver })
    }

    /// Sends an Inline login code.
    pub async fn auth_start(
        &self,
        request: AuthStartRequest,
    ) -> Result<AuthStartResult, ClientRequestError> {
        match self.request(ClientRequest::AuthStart(request)).await? {
            ClientResponse::AuthStart(result) => Ok(result),
            other => unreachable!("auth_start returned {other:?}"),
        }
    }

    /// Verifies an Inline login code and persists the resulting session.
    pub async fn auth_verify(
        &self,
        request: AuthVerifyRequest,
    ) -> Result<AuthVerifyResult, ClientRequestError> {
        match self.request(ClientRequest::AuthVerify(request)).await? {
            ClientResponse::AuthVerify(result) => Ok(result),
            other => unreachable!("auth_verify returned {other:?}"),
        }
    }

    /// Resumes a previously stored session, if available.
    pub async fn resume_session(&self) -> Result<ClientStatusSnapshot, ClientRequestError> {
        match self.request(ClientRequest::Resume).await? {
            ClientResponse::Status(status) => Ok(status),
            other => unreachable!("resume_session returned {other:?}"),
        }
    }

    /// Connects or reconnects the client.
    pub async fn connect(
        &self,
        request: ConnectRequest,
    ) -> Result<ClientStatusSnapshot, ClientRequestError> {
        match self.request(ClientRequest::Connect(request)).await? {
            ClientResponse::Status(status) => Ok(status),
            other => unreachable!("connect returned {other:?}"),
        }
    }

    /// Logs out the current account.
    pub async fn logout(&self) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::Logout).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("logout returned {other:?}"),
        }
    }

    /// Lists dialogs.
    pub async fn dialogs(
        &self,
        request: DialogsRequest,
    ) -> Result<DialogsPage, ClientRequestError> {
        match self.request(ClientRequest::Dialogs(request)).await? {
            ClientResponse::Dialogs(page) => Ok(page),
            other => unreachable!("dialogs returned {other:?}"),
        }
    }

    /// Lists only durable cached dialogs without making a network request.
    pub async fn cached_dialogs(
        &self,
        request: DialogsRequest,
    ) -> Result<DialogsPage, ClientRequestError> {
        match self.request(ClientRequest::CachedDialogs(request)).await? {
            ClientResponse::Dialogs(page) => Ok(page),
            other => unreachable!("cached_dialogs returned {other:?}"),
        }
    }

    /// Loads account-level durable state for recovery after a consumer event
    /// stream retention gap.
    pub async fn account_state(&self) -> Result<AccountStateSnapshot, ClientRequestError> {
        match self.request(ClientRequest::AccountState).await? {
            ClientResponse::AccountState(snapshot) => Ok(snapshot),
            other => unreachable!("account_state returned {other:?}"),
        }
    }

    /// Loads durable state for one chat. Current messages remain paged through
    /// [`Self::history`] so large accounts do not require an unbounded snapshot.
    pub async fn chat_state(
        &self,
        chat_id: InlineId,
    ) -> Result<ChatStateSnapshot, ClientRequestError> {
        match self.request(ClientRequest::ChatState(chat_id)).await? {
            ClientResponse::ChatState(snapshot) => Ok(*snapshot),
            other => unreachable!("chat_state returned {other:?}"),
        }
    }

    /// Fetches chat history.
    pub async fn history(
        &self,
        request: HistoryRequest,
    ) -> Result<HistoryPage, ClientRequestError> {
        match self.request(ClientRequest::History(request)).await? {
            ClientResponse::History(page) => Ok(page),
            other => unreachable!("history returned {other:?}"),
        }
    }

    /// Fetches only durable locally cached history without a network request.
    pub async fn cached_history(
        &self,
        request: HistoryRequest,
    ) -> Result<HistoryPage, ClientRequestError> {
        match self.request(ClientRequest::CachedHistory(request)).await? {
            ClientResponse::History(page) => Ok(page),
            other => unreachable!("cached_history returned {other:?}"),
        }
    }

    /// Fetches chat participants.
    pub async fn chat_participants(
        &self,
        request: ChatParticipantsRequest,
    ) -> Result<ChatParticipantsPage, ClientRequestError> {
        match self
            .request(ClientRequest::ChatParticipants(request))
            .await?
        {
            ClientResponse::ChatParticipants(page) => Ok(page),
            other => unreachable!("chat_participants returned {other:?}"),
        }
    }

    /// Adds a user to an Inline chat.
    pub async fn add_chat_participant(
        &self,
        request: AddChatParticipantRequest,
    ) -> Result<(), ClientRequestError> {
        match self
            .request(ClientRequest::AddChatParticipant(request))
            .await?
        {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("add_chat_participant returned {other:?}"),
        }
    }

    /// Removes a user from an Inline chat.
    pub async fn remove_chat_participant(
        &self,
        request: RemoveChatParticipantRequest,
    ) -> Result<(), ClientRequestError> {
        match self
            .request(ClientRequest::RemoveChatParticipant(request))
            .await?
        {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("remove_chat_participant returned {other:?}"),
        }
    }

    /// Updates mutable Inline chat metadata.
    pub async fn update_chat_info(
        &self,
        request: UpdateChatInfoRequest,
    ) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::UpdateChatInfo(request)).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("update_chat_info returned {other:?}"),
        }
    }

    /// Deletes an Inline chat when permitted by the service.
    pub async fn delete_chat(&self, request: DeleteChatRequest) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::DeleteChat(request)).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("delete_chat returned {other:?}"),
        }
    }

    /// Creates or opens a direct message chat.
    pub async fn create_dm(
        &self,
        request: CreateDmRequest,
    ) -> Result<CreatedChat, ClientRequestError> {
        match self.request(ClientRequest::CreateDm(request)).await? {
            ClientResponse::CreatedChat(chat) => Ok(chat),
            other => unreachable!("create_dm returned {other:?}"),
        }
    }

    /// Creates a regular Inline thread chat.
    pub async fn create_thread(
        &self,
        request: CreateThreadRequest,
    ) -> Result<CreatedChat, ClientRequestError> {
        match self.request(ClientRequest::CreateThread(request)).await? {
            ClientResponse::CreatedChat(chat) => Ok(chat),
            other => unreachable!("create_thread returned {other:?}"),
        }
    }

    /// Creates a child/reply Inline thread chat.
    pub async fn create_reply_thread(
        &self,
        request: CreateReplyThreadRequest,
    ) -> Result<CreatedChat, ClientRequestError> {
        match self
            .request(ClientRequest::CreateReplyThread(request))
            .await?
        {
            ClientResponse::CreatedChat(chat) => Ok(chat),
            other => unreachable!("create_reply_thread returned {other:?}"),
        }
    }

    /// Sends a text message.
    pub async fn send_text(
        &self,
        request: SendTextRequest,
    ) -> Result<MessageMutation, ClientRequestError> {
        match self.request(ClientRequest::SendText(request)).await? {
            ClientResponse::Message(mutation) => Ok(mutation),
            other => unreachable!("send_text returned {other:?}"),
        }
    }

    /// Uploads and sends a media message.
    pub async fn send_media(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
    ) -> Result<MessageMutation, ClientRequestError> {
        match self
            .request(ClientRequest::SendMedia { request, bytes })
            .await?
        {
            ClientResponse::Message(mutation) => Ok(mutation),
            other => unreachable!("send_media returned {other:?}"),
        }
    }

    /// Edits a text message.
    pub async fn edit_message(
        &self,
        request: EditMessageRequest,
    ) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::EditMessage(request)).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("edit_message returned {other:?}"),
        }
    }

    /// Deletes or unsends a message.
    pub async fn delete_message(
        &self,
        request: DeleteMessageRequest,
    ) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::DeleteMessage(request)).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("delete_message returned {other:?}"),
        }
    }

    /// Adds or removes a reaction.
    pub async fn react(&self, request: ReactRequest) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::React(request)).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("react returned {other:?}"),
        }
    }

    /// Marks messages read.
    pub async fn read(&self, request: ReadRequest) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::Read(request)).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("read returned {other:?}"),
        }
    }

    /// Sets the explicit marked-unread state for a chat.
    pub async fn set_marked_unread(
        &self,
        request: SetMarkedUnreadRequest,
    ) -> Result<(), ClientRequestError> {
        match self
            .request(ClientRequest::SetMarkedUnread(request))
            .await?
        {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("set_marked_unread returned {other:?}"),
        }
    }

    /// Sets or clears a per-dialog notification override.
    pub async fn update_dialog_notifications(
        &self,
        request: UpdateDialogNotificationsRequest,
    ) -> Result<(), ClientRequestError> {
        match self
            .request(ClientRequest::UpdateDialogNotifications(request))
            .await?
        {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("update_dialog_notifications returned {other:?}"),
        }
    }

    /// Sends a typing state.
    pub async fn typing(&self, request: TypingRequest) -> Result<(), ClientRequestError> {
        match self.request(ClientRequest::Typing(request)).await? {
            ClientResponse::Empty => Ok(()),
            other => unreachable!("typing returned {other:?}"),
        }
    }

    /// Updates status through the runner.
    ///
    /// This is public so early hosts and tests can exercise the event/status
    /// pipeline before the real transport manager is wired in. Future transport
    /// code should call the same internal command path.
    pub async fn set_status(
        &self,
        status: ClientStatus,
        failure: Option<ClientFailure>,
    ) -> Result<(), ClientCommandError> {
        let (respond_to, response) = oneshot::channel();
        self.command_tx
            .send(ClientCommand::SetStatus {
                status,
                failure,
                respond_to,
            })
            .await
            .map_err(|_| ClientCommandError::Closed)?;
        response
            .await
            .map_err(|_| ClientCommandError::ResponseDropped)
    }

    /// Requests runner shutdown.
    pub async fn shutdown(&self) -> Result<(), ClientCommandError> {
        let (respond_to, response) = oneshot::channel();
        self.command_tx
            .send(ClientCommand::Shutdown { respond_to })
            .await
            .map_err(|_| ClientCommandError::Closed)?;
        response
            .await
            .map_err(|_| ClientCommandError::ResponseDropped)
    }

    async fn request(&self, request: ClientRequest) -> Result<ClientResponse, ClientRequestError> {
        let (respond_to, response) = oneshot::channel();
        self.command_tx
            .send(ClientCommand::Request {
                request: Box::new(request),
                respond_to,
            })
            .await
            .map_err(|_| ClientCommandError::Closed)?;
        response
            .await
            .map_err(|_| ClientCommandError::ResponseDropped)?
            .map_err(ClientRequestError::Backend)
    }
}

/// Single-owner async client runner.
#[derive(Debug)]
pub struct ClientRunner {
    command_rx: mpsc::Receiver<ClientCommand>,
    event_emitter: ClientEventEmitter,
    status_tx: watch::Sender<ClientStatus>,
    failure_tx: watch::Sender<Option<ClientFailure>>,
    status: ClientStatus,
    failure: Option<ClientFailure>,
    backend: Arc<dyn ClientBackend>,
    signal_tx: mpsc::Sender<RunnerSignal>,
    signal_rx: mpsc::Receiver<RunnerSignal>,
    event_task: Option<JoinHandle<()>>,
    request_tasks: JoinSet<()>,
    max_concurrent_requests: usize,
    reconnect_policy: ReconnectPolicy,
}

#[derive(Clone, Debug)]
struct ClientEventEmitter {
    broadcast: broadcast::Sender<ClientEvent>,
    lossless: mpsc::Sender<ClientEvent>,
    lossless_active: Arc<AtomicBool>,
}

impl ClientEventEmitter {
    async fn emit(&self, event: ClientEvent) {
        let _ = self.broadcast.send(event.clone());
        if event.reliability() == crate::EventReliability::Lossless
            && self.lossless_active.load(Ordering::Acquire)
            && self.lossless.send(event).await.is_err()
        {
            self.lossless_active.store(false, Ordering::Release);
        }
    }

    async fn emit_operation_events(&self, outcome: OperationOutcome) {
        for event in outcome.events {
            self.emit(event).await;
        }
    }

    async fn emit_send_outcome(&self, outcome: SendTextOutcome) -> MessageMutation {
        let transaction = outcome.transaction_event();
        let message_id = outcome.message_id;
        let chat_id = outcome.chat_id;
        let message = outcome.message;
        let mut mutation = outcome.mutation;
        mutation.state = Some(outcome.state);
        mutation.failure = outcome.failure.clone();
        self.emit(ClientEvent::TransactionChanged(transaction))
            .await;
        if let Some(message_id) = message_id {
            self.emit(ClientEvent::MessageUpserted {
                chat_id,
                message_id,
            })
            .await;
        }
        if let Some(message) = message {
            self.emit(ClientEvent::MessageStored { message }).await;
        }
        mutation
    }
}

impl ClientRunner {
    /// Runs the client command loop until shutdown or all handles are dropped.
    pub async fn run(mut self) {
        log::debug!("inline client runner started");
        loop {
            tokio::select! {
                command = self.command_rx.recv(), if self.request_tasks.len() < self.max_concurrent_requests => {
                    if !self.handle_optional_command(command).await {
                        break;
                    }
                }
                signal = self.signal_rx.recv() => {
                    if let Some(signal) = signal {
                        self.handle_signal(signal).await;
                    }
                }
                completed = self.request_tasks.join_next(), if !self.request_tasks.is_empty() => {
                    if let Some(Err(error)) = completed {
                        log::error!("inline client request task failed: {error}");
                    }
                }
            }
        }
        self.stop_event_receiver();
        log::debug!("inline client runner stopped");
    }

    async fn handle_optional_command(&mut self, command: Option<ClientCommand>) -> bool {
        let Some(command) = command else {
            return false;
        };
        self.handle_command(command).await
    }

    async fn handle_command(&mut self, command: ClientCommand) -> bool {
        match command {
            ClientCommand::Request {
                request,
                respond_to,
            } => {
                if request.can_run_concurrently() {
                    self.spawn_concurrent_request(*request, respond_to);
                    return true;
                }
                self.finish_concurrent_requests().await;
                let response = self.handle_request(*request).await;
                let _ = respond_to.send(response);
                true
            }
            ClientCommand::SetStatus {
                status,
                failure,
                respond_to,
            } => {
                self.update_status(status, failure).await;
                let _ = respond_to.send(());
                true
            }
            ClientCommand::Shutdown { respond_to } => {
                log::debug!("inline client runner shutdown requested");
                self.request_tasks.abort_all();
                self.update_status(ClientStatus::ShuttingDown, None).await;
                let _ = respond_to.send(());
                false
            }
        }
    }

    const fn should_receive_events(&self) -> bool {
        matches!(
            self.status,
            ClientStatus::Connected | ClientStatus::Reconnecting
        )
    }

    async fn emit_received_events(&self, events: Vec<ClientEvent>) {
        for event in events {
            self.event_emitter.emit(event).await;
        }
    }

    async fn handle_signal(&mut self, signal: RunnerSignal) {
        match signal {
            RunnerSignal::Events(events) => {
                if self.status == ClientStatus::Reconnecting {
                    self.update_status(ClientStatus::Connected, None).await;
                }
                self.emit_received_events(events).await;
            }
            RunnerSignal::ReceiveError(error) => {
                self.update_status_for_backend_error(&error).await;
            }
        }
    }

    async fn handle_request(&mut self, request: ClientRequest) -> BackendResult<ClientResponse> {
        log::debug!("handling inline client request: {}", request.kind());
        match request {
            ClientRequest::AuthStart(auth) => self
                .backend
                .auth_start(auth)
                .await
                .map(ClientResponse::AuthStart),
            ClientRequest::AuthVerify(auth) => {
                self.update_status(ClientStatus::Connecting, None).await;
                match self.backend.auth_verify(auth).await {
                    Ok(result) => {
                        let status = result.status.clone();
                        self.update_status(status.status, status.failure.clone())
                            .await;
                        Ok(ClientResponse::AuthVerify(result))
                    }
                    Err(error) => {
                        self.update_status_for_backend_error(&error).await;
                        Err(error)
                    }
                }
            }
            ClientRequest::Resume => {
                self.update_status(ClientStatus::Connecting, None).await;
                match self.backend.resume_session().await {
                    Ok(status) => {
                        self.update_status(status.status, status.failure.clone())
                            .await;
                        Ok(ClientResponse::Status(status))
                    }
                    Err(error) => {
                        self.update_status_for_backend_error(&error).await;
                        Err(error)
                    }
                }
            }
            ClientRequest::Connect(connect) => {
                self.update_status(ClientStatus::Connecting, None).await;
                match self.backend.connect(connect).await {
                    Ok(status) => {
                        self.update_status(status.status, status.failure.clone())
                            .await;
                        Ok(ClientResponse::Status(status))
                    }
                    Err(error) => {
                        self.update_status_for_backend_error(&error).await;
                        Err(error)
                    }
                }
            }
            ClientRequest::Logout => {
                self.backend.logout().await?;
                self.update_status(ClientStatus::LoggedOut, None).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::Dialogs(dialogs) => self
                .backend
                .dialogs(dialogs)
                .await
                .map(ClientResponse::Dialogs),
            ClientRequest::CachedDialogs(dialogs) => self
                .backend
                .cached_dialogs(dialogs)
                .await
                .map(ClientResponse::Dialogs),
            ClientRequest::AccountState => self
                .backend
                .account_state()
                .await
                .map(ClientResponse::AccountState),
            ClientRequest::ChatState(chat_id) => self
                .backend
                .chat_state(chat_id)
                .await
                .map(Box::new)
                .map(ClientResponse::ChatState),
            ClientRequest::History(history) => self
                .backend
                .history(history)
                .await
                .map(ClientResponse::History),
            ClientRequest::CachedHistory(history) => self
                .backend
                .cached_history(history)
                .await
                .map(ClientResponse::History),
            ClientRequest::ChatParticipants(participants) => self
                .backend
                .chat_participants(participants)
                .await
                .map(ClientResponse::ChatParticipants),
            ClientRequest::AddChatParticipant(request) => {
                let outcome = self.backend.add_chat_participant(request).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::RemoveChatParticipant(request) => {
                let outcome = self.backend.remove_chat_participant(request).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::UpdateChatInfo(request) => {
                let outcome = self.backend.update_chat_info(request).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::DeleteChat(request) => {
                let outcome = self.backend.delete_chat(request).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::CreateDm(request) => self
                .backend
                .create_dm(request)
                .await
                .map(ClientResponse::CreatedChat),
            ClientRequest::CreateThread(request) => self
                .backend
                .create_thread(request)
                .await
                .map(ClientResponse::CreatedChat),
            ClientRequest::CreateReplyThread(request) => self
                .backend
                .create_reply_thread(request)
                .await
                .map(ClientResponse::CreatedChat),
            ClientRequest::SendText(send) => {
                let outcome = self.backend.send_text(send).await?;
                Ok(ClientResponse::Message(
                    self.event_emitter.emit_send_outcome(outcome).await,
                ))
            }
            ClientRequest::SendMedia { request, bytes } => {
                let outcome = self.backend.send_media(request, bytes).await?;
                Ok(ClientResponse::Message(
                    self.event_emitter.emit_send_outcome(outcome).await,
                ))
            }
            ClientRequest::EditMessage(edit) => {
                let outcome = self.backend.edit_message(edit).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::DeleteMessage(delete) => {
                let outcome = self.backend.delete_message(delete).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::React(react) => {
                let outcome = self.backend.react(react).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::Read(read) => {
                let outcome = self.backend.read(read).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::SetMarkedUnread(request) => {
                let outcome = self.backend.set_marked_unread(request).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::UpdateDialogNotifications(request) => {
                let outcome = self.backend.update_dialog_notifications(request).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
            ClientRequest::Typing(typing) => {
                let outcome = self.backend.typing(typing).await?;
                self.event_emitter.emit_operation_events(outcome).await;
                Ok(ClientResponse::Empty)
            }
        }
    }

    async fn update_status_for_backend_error(&mut self, error: &BackendError) {
        let status = match error.category {
            ClientErrorCategory::AuthRequired => ClientStatus::AuthRequired,
            ClientErrorCategory::AuthExpired => ClientStatus::AuthExpired,
            ClientErrorCategory::Network
            | ClientErrorCategory::Timeout
            | ClientErrorCategory::RateLimited => ClientStatus::Reconnecting,
            _ => ClientStatus::Disconnected,
        };
        self.update_status(
            status,
            Some(ClientFailure::new(error.category, error.message.clone())),
        )
        .await;
    }

    async fn update_status(&mut self, status: ClientStatus, failure: Option<ClientFailure>) {
        log::debug!("inline client status changed: {status:?}");
        self.status = status;
        self.failure = failure.clone();
        let _ = self.status_tx.send(status);
        let _ = self.failure_tx.send(failure.clone());
        self.event_emitter
            .emit(ClientEvent::StatusChanged { status, failure })
            .await;
        self.sync_event_receiver_to_status();
    }

    fn spawn_concurrent_request(
        &mut self,
        request: ClientRequest,
        respond_to: oneshot::Sender<BackendResult<ClientResponse>>,
    ) {
        let backend = self.backend.clone();
        let event_emitter = self.event_emitter.clone();
        self.request_tasks.spawn(async move {
            let response = handle_concurrent_request(backend, event_emitter, request).await;
            let _ = respond_to.send(response);
        });
    }

    async fn finish_concurrent_requests(&mut self) {
        while let Some(completed) = self.request_tasks.join_next().await {
            if let Err(error) = completed {
                log::error!("inline client request task failed: {error}");
            }
        }
    }

    fn sync_event_receiver_to_status(&mut self) {
        if self.should_receive_events() {
            self.start_event_receiver();
        } else {
            self.stop_event_receiver();
        }
    }

    fn start_event_receiver(&mut self) {
        if self.event_task.is_some() {
            return;
        }
        let backend = self.backend.clone();
        let signal_tx = self.signal_tx.clone();
        let reconnect_policy = self.reconnect_policy;
        self.event_task = Some(tokio::spawn(run_backend_event_receiver(
            backend,
            signal_tx,
            reconnect_policy,
        )));
    }

    fn stop_event_receiver(&mut self) {
        if let Some(task) = self.event_task.take() {
            task.abort();
        }
    }
}

async fn handle_concurrent_request(
    backend: Arc<dyn ClientBackend>,
    events: ClientEventEmitter,
    request: ClientRequest,
) -> BackendResult<ClientResponse> {
    log::debug!(
        "handling concurrent inline client request: {}",
        request.kind()
    );
    match request {
        ClientRequest::Dialogs(request) => {
            backend.dialogs(request).await.map(ClientResponse::Dialogs)
        }
        ClientRequest::CachedDialogs(request) => backend
            .cached_dialogs(request)
            .await
            .map(ClientResponse::Dialogs),
        ClientRequest::AccountState => backend
            .account_state()
            .await
            .map(ClientResponse::AccountState),
        ClientRequest::ChatState(chat_id) => backend
            .chat_state(chat_id)
            .await
            .map(Box::new)
            .map(ClientResponse::ChatState),
        ClientRequest::History(request) => {
            backend.history(request).await.map(ClientResponse::History)
        }
        ClientRequest::CachedHistory(request) => backend
            .cached_history(request)
            .await
            .map(ClientResponse::History),
        ClientRequest::ChatParticipants(request) => backend
            .chat_participants(request)
            .await
            .map(ClientResponse::ChatParticipants),
        ClientRequest::AddChatParticipant(request) => {
            events
                .emit_operation_events(backend.add_chat_participant(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::RemoveChatParticipant(request) => {
            events
                .emit_operation_events(backend.remove_chat_participant(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::UpdateChatInfo(request) => {
            events
                .emit_operation_events(backend.update_chat_info(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::DeleteChat(request) => {
            events
                .emit_operation_events(backend.delete_chat(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::CreateDm(request) => backend
            .create_dm(request)
            .await
            .map(ClientResponse::CreatedChat),
        ClientRequest::CreateThread(request) => backend
            .create_thread(request)
            .await
            .map(ClientResponse::CreatedChat),
        ClientRequest::CreateReplyThread(request) => backend
            .create_reply_thread(request)
            .await
            .map(ClientResponse::CreatedChat),
        ClientRequest::SendText(request) => {
            let outcome = backend.send_text(request).await?;
            Ok(ClientResponse::Message(
                events.emit_send_outcome(outcome).await,
            ))
        }
        ClientRequest::SendMedia { request, bytes } => {
            let outcome = backend.send_media(request, bytes).await?;
            Ok(ClientResponse::Message(
                events.emit_send_outcome(outcome).await,
            ))
        }
        ClientRequest::EditMessage(request) => {
            events
                .emit_operation_events(backend.edit_message(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::DeleteMessage(request) => {
            events
                .emit_operation_events(backend.delete_message(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::React(request) => {
            events
                .emit_operation_events(backend.react(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::Read(request) => {
            events
                .emit_operation_events(backend.read(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::SetMarkedUnread(request) => {
            events
                .emit_operation_events(backend.set_marked_unread(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::UpdateDialogNotifications(request) => {
            events
                .emit_operation_events(backend.update_dialog_notifications(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::Typing(request) => {
            events
                .emit_operation_events(backend.typing(request).await?)
                .await;
            Ok(ClientResponse::Empty)
        }
        ClientRequest::AuthStart(_)
        | ClientRequest::AuthVerify(_)
        | ClientRequest::Resume
        | ClientRequest::Connect(_)
        | ClientRequest::Logout => unreachable!("session request was spawned concurrently"),
    }
}

async fn run_backend_event_receiver(
    backend: Arc<dyn ClientBackend>,
    signal_tx: mpsc::Sender<RunnerSignal>,
    reconnect_policy: ReconnectPolicy,
) {
    let mut retry_attempt = 0_u32;
    loop {
        match backend.receive_events().await {
            Ok(events) => {
                retry_attempt = 0;
                if signal_tx.send(RunnerSignal::Events(events)).await.is_err() {
                    break;
                }
            }
            Err(error) => {
                let retry = should_retry_event_receive(&error);
                let delay = event_retry_delay(&error, retry_attempt, reconnect_policy);
                if signal_tx
                    .send(RunnerSignal::ReceiveError(error))
                    .await
                    .is_err()
                {
                    break;
                }
                if !retry {
                    break;
                }
                retry_attempt = retry_attempt.saturating_add(1);
                tokio::time::sleep(delay).await;
            }
        }
    }
}

enum ClientCommand {
    Request {
        request: Box<ClientRequest>,
        respond_to: oneshot::Sender<BackendResult<ClientResponse>>,
    },
    SetStatus {
        status: ClientStatus,
        failure: Option<ClientFailure>,
        respond_to: oneshot::Sender<()>,
    },
    Shutdown {
        respond_to: oneshot::Sender<()>,
    },
}

#[derive(Debug)]
enum RunnerSignal {
    Events(Vec<ClientEvent>),
    ReceiveError(BackendError),
}

impl std::fmt::Debug for ClientCommand {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Request { request, .. } => f
                .debug_struct("Request")
                .field("request", request)
                .finish_non_exhaustive(),
            Self::SetStatus {
                status, failure, ..
            } => f
                .debug_struct("SetStatus")
                .field("status", status)
                .field("failure", failure)
                .finish_non_exhaustive(),
            Self::Shutdown { .. } => f.debug_struct("Shutdown").finish_non_exhaustive(),
        }
    }
}

#[derive(Debug)]
enum ClientRequest {
    AuthStart(AuthStartRequest),
    AuthVerify(AuthVerifyRequest),
    Resume,
    Connect(ConnectRequest),
    Logout,
    Dialogs(DialogsRequest),
    CachedDialogs(DialogsRequest),
    AccountState,
    ChatState(InlineId),
    History(HistoryRequest),
    CachedHistory(HistoryRequest),
    ChatParticipants(ChatParticipantsRequest),
    AddChatParticipant(AddChatParticipantRequest),
    RemoveChatParticipant(RemoveChatParticipantRequest),
    UpdateChatInfo(UpdateChatInfoRequest),
    DeleteChat(DeleteChatRequest),
    CreateDm(CreateDmRequest),
    CreateThread(CreateThreadRequest),
    CreateReplyThread(CreateReplyThreadRequest),
    SendText(SendTextRequest),
    SendMedia {
        request: UploadRequest,
        bytes: Vec<u8>,
    },
    EditMessage(EditMessageRequest),
    DeleteMessage(DeleteMessageRequest),
    React(ReactRequest),
    Read(ReadRequest),
    SetMarkedUnread(SetMarkedUnreadRequest),
    UpdateDialogNotifications(UpdateDialogNotificationsRequest),
    Typing(TypingRequest),
}

impl ClientRequest {
    const fn can_run_concurrently(&self) -> bool {
        !matches!(
            self,
            Self::AuthStart(_)
                | Self::AuthVerify(_)
                | Self::Resume
                | Self::Connect(_)
                | Self::Logout
        )
    }

    const fn kind(&self) -> &'static str {
        match self {
            Self::AuthStart(_) => "auth_start",
            Self::AuthVerify(_) => "auth_verify",
            Self::Resume => "resume",
            Self::Connect(_) => "connect",
            Self::Logout => "logout",
            Self::Dialogs(_) => "dialogs",
            Self::CachedDialogs(_) => "cached_dialogs",
            Self::AccountState => "account_state",
            Self::ChatState(_) => "chat_state",
            Self::History(_) => "history",
            Self::CachedHistory(_) => "cached_history",
            Self::ChatParticipants(_) => "chat_participants",
            Self::AddChatParticipant(_) => "add_chat_participant",
            Self::RemoveChatParticipant(_) => "remove_chat_participant",
            Self::UpdateChatInfo(_) => "update_chat_info",
            Self::DeleteChat(_) => "delete_chat",
            Self::CreateDm(_) => "create_dm",
            Self::CreateThread(_) => "create_thread",
            Self::CreateReplyThread(_) => "create_reply_thread",
            Self::SendText(_) => "send_text",
            Self::SendMedia { .. } => "send_media",
            Self::EditMessage(_) => "edit_message",
            Self::DeleteMessage(_) => "delete_message",
            Self::React(_) => "react",
            Self::Read(_) => "read",
            Self::SetMarkedUnread(_) => "set_marked_unread",
            Self::UpdateDialogNotifications(_) => "update_dialog_notifications",
            Self::Typing(_) => "typing",
        }
    }
}

fn event_retry_delay(error: &BackendError, attempt: u32, policy: ReconnectPolicy) -> Duration {
    if error.category == ClientErrorCategory::RateLimited
        && let Some(hint) = error
            .retry_after_seconds
            .map(Duration::from_secs)
            .or_else(|| retry_after_hint(&error.message))
    {
        return apply_retry_jitter(hint.min(policy.rate_limit_max_delay), policy.jitter_percent);
    }
    let (initial, maximum) = match error.category {
        ClientErrorCategory::RateLimited => {
            (policy.rate_limit_initial_delay, policy.rate_limit_max_delay)
        }
        _ => (policy.initial_delay, policy.max_delay),
    };
    let multiplier = 1_u32.checked_shl(attempt.min(16)).unwrap_or(u32::MAX);
    apply_retry_jitter(
        initial.saturating_mul(multiplier).min(maximum),
        policy.jitter_percent,
    )
}

fn retry_after_hint(message: &str) -> Option<Duration> {
    retry_after_seconds_from_message(message).map(Duration::from_secs)
}

fn apply_retry_jitter(delay: Duration, jitter_percent: u8) -> Duration {
    let jitter = u64::from(jitter_percent.min(100));
    if jitter == 0 || delay.is_zero() {
        return delay;
    }
    let seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u64;
    let spread = jitter * 2 + 1;
    let factor = 100_u64.saturating_sub(jitter) + seed % spread;
    Duration::from_millis(
        u64::try_from(delay.as_millis().saturating_mul(u128::from(factor)) / 100)
            .unwrap_or(u64::MAX),
    )
}

const fn should_retry_event_receive(error: &BackendError) -> bool {
    matches!(
        error.category,
        ClientErrorCategory::Network
            | ClientErrorCategory::Timeout
            | ClientErrorCategory::RateLimited
    )
}

#[derive(Debug)]
enum ClientResponse {
    Empty,
    Status(ClientStatusSnapshot),
    AuthStart(AuthStartResult),
    AuthVerify(AuthVerifyResult),
    Dialogs(DialogsPage),
    AccountState(AccountStateSnapshot),
    ChatState(Box<ChatStateSnapshot>),
    History(HistoryPage),
    ChatParticipants(ChatParticipantsPage),
    CreatedChat(CreatedChat),
    Message(MessageMutation),
}

#[cfg(test)]
mod tests {
    use crate::{
        AuthContactKind, AuthCredential, AuthToken, DialogRecord, HistoryRequest, InlineId,
        MediaKind, MessageContent, PeerRef,
    };

    #[tokio::test]
    async fn lossless_subscriber_receives_events_that_overflow_broadcast_history() {
        let client = InlineClient::builder()
            .event_queue_capacity(1)
            .lossless_event_queue_capacity(3)
            .build()
            .spawn();
        let mut broadcast = client.subscribe();
        let mut lossless = client.take_lossless_events().unwrap();
        assert!(client.take_lossless_events().is_none());

        for status in [
            ClientStatus::AuthRequired,
            ClientStatus::AuthExpired,
            ClientStatus::LoggedOut,
        ] {
            client.set_status(status, None).await.unwrap();
        }

        let mut received = Vec::new();
        for _ in 0..3 {
            received.push(lossless.recv().await.unwrap());
        }
        let statuses = received
            .into_iter()
            .map(|event| match event {
                ClientEvent::StatusChanged { status, .. } => status,
                other => panic!("expected status event, got {other:?}"),
            })
            .collect::<Vec<_>>();
        assert_eq!(
            statuses,
            vec![
                ClientStatus::AuthRequired,
                ClientStatus::AuthExpired,
                ClientStatus::LoggedOut
            ]
        );
        assert!(matches!(
            broadcast.recv().await,
            Err(broadcast::error::RecvError::Lagged(2))
        ));
    }

    #[test]
    fn reconnect_backoff_is_bounded_and_uses_rate_limit_hints() {
        let policy = ReconnectPolicy {
            initial_delay: Duration::from_secs(1),
            max_delay: Duration::from_secs(8),
            rate_limit_initial_delay: Duration::from_secs(30),
            rate_limit_max_delay: Duration::from_secs(120),
            jitter_percent: 0,
        };
        let network = BackendError::new(ClientErrorCategory::Network, "offline");
        assert_eq!(
            event_retry_delay(&network, 0, policy),
            Duration::from_secs(1)
        );
        assert_eq!(
            event_retry_delay(&network, 1, policy),
            Duration::from_secs(2)
        );
        assert_eq!(
            event_retry_delay(&network, 20, policy),
            Duration::from_secs(8)
        );

        let limited = BackendError::new(
            ClientErrorCategory::RateLimited,
            "FLOOD_WAIT_45: retry later",
        );
        assert_eq!(
            event_retry_delay(&limited, 0, policy),
            Duration::from_secs(45)
        );
        let typed_limited = BackendError::new(ClientErrorCategory::RateLimited, "slow down")
            .with_retry_after_seconds(75);
        assert_eq!(
            event_retry_delay(&typed_limited, 0, policy),
            Duration::from_secs(75)
        );
        assert_eq!(
            retry_after_hint("please retry after 12 seconds"),
            Some(Duration::from_secs(12))
        );
        assert_eq!(
            retry_after_hint("retry_after=19"),
            Some(Duration::from_secs(19))
        );
    }

    use super::*;

    fn token_connect() -> ConnectRequest {
        ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new("token").unwrap(),
        })
    }

    fn auth_verify_request() -> AuthVerifyRequest {
        AuthVerifyRequest {
            contact: "mo@example.com".to_owned(),
            kind: AuthContactKind::Email,
            code: "123456".to_owned(),
            challenge_token: None,
            device_name: Some("inline-client test".to_owned()),
            account_namespace: None,
        }
    }

    #[tokio::test]
    async fn status_snapshot_returns_current_status() {
        let client = InlineClient::builder()
            .initial_status(ClientStatus::Connected)
            .build()
            .spawn();

        let status = client.status_snapshot();

        assert_eq!(status.status, ClientStatus::Connected);
        assert_eq!(status.failure, None);
    }

    #[tokio::test]
    async fn set_status_emits_lossless_event() {
        let client = InlineClient::builder().build().spawn();
        let mut events = client.subscribe();

        client
            .set_status(
                ClientStatus::AuthExpired,
                Some(ClientFailure::new(
                    ClientErrorCategory::AuthExpired,
                    "relogin required",
                )),
            )
            .await
            .unwrap();

        let event = recv_until_event(&mut events, |event| {
            matches!(
                event,
                ClientEvent::StatusChanged {
                    status: ClientStatus::AuthExpired,
                    ..
                }
            )
        })
        .await;
        assert_eq!(event.reliability(), crate::EventReliability::Lossless);
        assert!(matches!(
            event,
            ClientEvent::StatusChanged {
                status: ClientStatus::AuthExpired,
                ..
            }
        ));
        assert_eq!(client.status(), ClientStatus::AuthExpired);
        assert_eq!(
            client.status_snapshot().failure.unwrap().category,
            ClientErrorCategory::AuthExpired
        );
    }

    #[tokio::test]
    async fn connect_updates_status_and_emits_event() {
        let client = InlineClient::builder().build().spawn();
        let mut events = client.subscribe();

        let status = client.connect(token_connect()).await.unwrap();

        assert_eq!(status.status, ClientStatus::Connected);
        assert_eq!(client.status(), ClientStatus::Connected);

        let event = recv_until_event(&mut events, |event| {
            matches!(
                event,
                ClientEvent::StatusChanged {
                    status: ClientStatus::Connected,
                    ..
                }
            )
        })
        .await;
        assert!(matches!(
            event,
            ClientEvent::StatusChanged {
                status: ClientStatus::Connected,
                ..
            }
        ));
    }

    #[tokio::test]
    async fn runner_emits_backend_pushed_events_while_connected() {
        let backend = InMemoryBackend::new();
        let client = InlineClient::builder()
            .backend(backend.clone())
            .build()
            .spawn();
        let mut events = client.subscribe();

        client.connect(token_connect()).await.unwrap();
        backend.push_event_batch(vec![ClientEvent::MessageDeleted {
            chat_id: InlineId::new(7),
            message_id: InlineId::new(99),
        }]);

        let event = recv_until_event(&mut events, |event| {
            matches!(
                event,
                ClientEvent::MessageDeleted {
                    chat_id,
                    message_id,
                } if *chat_id == InlineId::new(7) && *message_id == InlineId::new(99)
            )
        })
        .await;
        assert_eq!(
            event,
            ClientEvent::MessageDeleted {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(99),
            }
        );
    }

    #[tokio::test]
    async fn runner_marks_reconnecting_when_event_receive_is_rate_limited() {
        let backend = InMemoryBackend::new();
        let client = InlineClient::builder()
            .backend(backend.clone())
            .build()
            .spawn();
        let mut events = client.subscribe();

        client.connect(token_connect()).await.unwrap();
        backend.push_event_error(BackendError::new(
            ClientErrorCategory::RateLimited,
            "rate limited",
        ));

        let event = recv_until_event(&mut events, |event| {
            matches!(
                event,
                ClientEvent::StatusChanged {
                    status: ClientStatus::Reconnecting,
                    ..
                }
            )
        })
        .await;
        assert!(matches!(
            event,
            ClientEvent::StatusChanged {
                status: ClientStatus::Reconnecting,
                ..
            }
        ));
        assert_eq!(client.status(), ClientStatus::Reconnecting);
    }

    #[tokio::test]
    async fn auth_start_and_verify_flow_through_backend() {
        let client = InlineClient::builder().build().spawn();
        let mut events = client.subscribe();

        let started = client
            .auth_start(AuthStartRequest {
                contact: "mo@example.com".to_owned(),
                kind: AuthContactKind::Email,
                device_name: Some("inline-client test".to_owned()),
            })
            .await
            .unwrap();
        assert!(started.existing_user);
        assert!(!started.needs_invite_code);

        let verified = client.auth_verify(auth_verify_request()).await.unwrap();
        assert_eq!(verified.user_id, InlineId::new(1));
        assert_eq!(verified.account_namespace, "1");
        assert_eq!(verified.status.status, ClientStatus::Connected);
        assert_eq!(client.status(), ClientStatus::Connected);

        let event = recv_until_event(&mut events, |event| {
            matches!(
                event,
                ClientEvent::StatusChanged {
                    status: ClientStatus::Connected,
                    ..
                }
            )
        })
        .await;
        assert!(matches!(
            event,
            ClientEvent::StatusChanged {
                status: ClientStatus::Connected,
                ..
            }
        ));
    }

    #[tokio::test]
    async fn resume_without_session_reports_auth_required() {
        let client = InlineClient::builder().build().spawn();
        let mut events = client.subscribe();

        let status = client.resume_session().await.unwrap();

        assert_eq!(status.status, ClientStatus::AuthRequired);
        assert_eq!(client.status(), ClientStatus::AuthRequired);

        let event = recv_until_event(&mut events, |event| {
            matches!(
                event,
                ClientEvent::StatusChanged {
                    status: ClientStatus::AuthRequired,
                    ..
                }
            )
        })
        .await;
        assert!(matches!(
            event,
            ClientEvent::StatusChanged {
                status: ClientStatus::AuthRequired,
                ..
            }
        ));
    }

    #[tokio::test]
    async fn dialogs_and_history_flow_through_backend() {
        let backend = InMemoryBackend::new();
        backend.upsert_dialog(DialogRecord {
            chat_id: InlineId::new(7),
            peer_user_id: None,
            title: Some("general".to_owned()),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
            ..DialogRecord::new(InlineId::new(7))
        });
        backend.insert_message(crate::MessageRecord {
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
        });
        let client = InlineClient::builder().backend(backend).build().spawn();
        client.connect(token_connect()).await.unwrap();

        let dialogs = client.dialogs(DialogsRequest::default()).await.unwrap();
        assert_eq!(dialogs.dialogs.len(), 1);
        assert_eq!(dialogs.dialogs[0].chat_id, InlineId::new(7));

        let history = client
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
    async fn send_text_returns_mutation_and_emits_events() {
        let client = InlineClient::builder().build().spawn();
        client.connect(token_connect()).await.unwrap();
        let mut events = client.subscribe();

        let mutation = client
            .send_text(SendTextRequest::new(
                PeerRef::Chat {
                    chat_id: InlineId::new(7),
                },
                "hello",
            ))
            .await
            .unwrap();

        assert_eq!(mutation.message_id, Some(InlineId::new(1)));
        assert_eq!(mutation.state, Some(crate::TransactionState::Completed));
        assert!(mutation.failure.is_none());
        assert_eq!(
            mutation.transaction.final_message_id,
            Some(InlineId::new(1))
        );

        let events = [
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
            events.recv().await.unwrap(),
        ];
        assert!(
            events
                .iter()
                .any(|event| matches!(event, ClientEvent::TransactionChanged(_)))
        );
        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::MessageUpserted {
                chat_id: InlineId(7),
                message_id: InlineId(1)
            }
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::MessageStored { message }
                if message.chat_id == InlineId::new(7)
                    && message.message_id == InlineId::new(1)
        )));
    }

    #[tokio::test]
    async fn edit_message_emits_stored_upsert_event() {
        let backend = InMemoryBackend::new();
        backend.insert_message(crate::MessageRecord {
            chat_id: InlineId::new(7),
            message_id: InlineId::new(1),
            sender_id: InlineId::new(2),
            timestamp: 1,
            is_outgoing: false,
            content: MessageContent::Text {
                text: "old".to_owned(),
            },
            reply_to_message_id: None,
            transaction: None,
        });
        let client = InlineClient::builder().backend(backend).build().spawn();
        client.connect(token_connect()).await.unwrap();
        let mut events = client.subscribe();

        client
            .edit_message(EditMessageRequest {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(1),
                text: "edited".to_owned(),
                external_id: None,
            })
            .await
            .unwrap();

        match events.recv().await.unwrap() {
            ClientEvent::MessageStored { message } => {
                assert_eq!(message.chat_id, InlineId::new(7));
                assert_eq!(message.message_id, InlineId::new(1));
                assert_eq!(
                    message.content,
                    MessageContent::Text {
                        text: "edited".to_owned()
                    }
                );
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[tokio::test]
    async fn send_media_emits_message_events() {
        let client = InlineClient::builder().build().spawn();
        client.connect(token_connect()).await.unwrap();
        let mut events = client.subscribe();

        let mutation = client
            .send_media(
                UploadRequest {
                    peer: PeerRef::Chat {
                        chat_id: InlineId::new(7),
                    },
                    kind: MediaKind::Photo,
                    file_name: Some("image.png".to_owned()),
                    mime_type: Some("image/png".to_owned()),
                    size_bytes: Some(4),
                    caption: Some("caption".to_owned()),
                    width: Some(10),
                    height: Some(10),
                    duration_ms: None,
                    external_id: None,
                    random_id: None,
                    reply_to_message_id: None,
                },
                vec![1, 2, 3, 4],
            )
            .await
            .unwrap();

        assert_eq!(mutation.message_id, Some(InlineId::new(1)));

        let _transaction = events.recv().await.unwrap();
        let _upsert = events.recv().await.unwrap();
        match events.recv().await.unwrap() {
            ClientEvent::MessageStored { message } => {
                assert_eq!(message.chat_id, InlineId::new(7));
                assert_eq!(message.message_id, InlineId::new(1));
                match message.content {
                    MessageContent::Media {
                        kind,
                        file_name,
                        caption,
                        ..
                    } => {
                        assert_eq!(kind, MediaKind::Photo);
                        assert_eq!(file_name.as_deref(), Some("image.png"));
                        assert_eq!(caption.as_deref(), Some("caption"));
                    }
                    other => panic!("unexpected content: {other:?}"),
                }
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[tokio::test]
    async fn shutdown_stops_runner() {
        let client = InlineClient::builder().build().spawn();

        client.shutdown().await.unwrap();
        let err = client
            .dialogs(DialogsRequest::default())
            .await
            .expect_err("runner should reject commands after shutdown");

        assert!(matches!(
            err,
            ClientRequestError::Command(
                ClientCommandError::Closed | ClientCommandError::ResponseDropped
            )
        ));
    }

    async fn recv_until_event(
        events: &mut broadcast::Receiver<ClientEvent>,
        matches: impl Fn(&ClientEvent) -> bool,
    ) -> ClientEvent {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let event = events.recv().await.unwrap();
                if matches(&event) {
                    return event;
                }
            }
        })
        .await
        .expect("expected matching client event")
    }
}

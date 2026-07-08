//! Async client facade and runner skeleton.
//!
//! This module establishes the TDLib-style host shape: cheap cloneable handle,
//! single owner runner, bounded command queue, and broadcast committed events.
//! Transport, sync, store, and transaction managers plug into this runner
//! instead of being spread across bridges or agents.

use std::sync::Arc;

use tokio::sync::{broadcast, mpsc, oneshot, watch};

use crate::{
    AuthStartRequest, AuthStartResult, AuthVerifyRequest, AuthVerifyResult, BackendError,
    BackendResult, ChatParticipantsPage, ChatParticipantsRequest, ClientBackend,
    ClientErrorCategory, ClientEvent, ClientFailure, ClientStatus, ClientStatusSnapshot,
    ConnectRequest, CreateDmRequest, CreateReplyThreadRequest, CreateThreadRequest, CreatedChat,
    DeleteMessageRequest, DialogsPage, DialogsRequest, EditMessageRequest, HistoryPage,
    HistoryRequest, InMemoryBackend, MessageMutation, OperationOutcome, ReactRequest, ReadRequest,
    SendTextOutcome, SendTextRequest, TypingRequest, UploadRequest,
};

/// Default bounded command queue capacity.
pub const DEFAULT_COMMAND_QUEUE_CAPACITY: usize = 128;

/// Default broadcast event queue capacity.
pub const DEFAULT_EVENT_QUEUE_CAPACITY: usize = 1024;

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
    event_queue_capacity: usize,
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

    /// Sets the broadcast event queue capacity.
    pub fn event_queue_capacity(mut self, capacity: usize) -> Self {
        self.event_queue_capacity = capacity.max(1);
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
        let (status_tx, status_rx) = watch::channel(self.initial_status);
        let (failure_tx, failure_rx) = watch::channel(None);

        let client = InlineClient {
            command_tx,
            event_tx: event_tx.clone(),
            status_rx,
            failure_rx,
        };
        let runner = ClientRunner {
            command_rx,
            event_tx,
            status_tx,
            failure_tx,
            status: self.initial_status,
            failure: None,
            backend: self.backend,
        };

        InlineClientRuntime { client, runner }
    }
}

impl Default for InlineClientBuilder {
    fn default() -> Self {
        Self {
            command_queue_capacity: DEFAULT_COMMAND_QUEUE_CAPACITY,
            event_queue_capacity: DEFAULT_EVENT_QUEUE_CAPACITY,
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
    event_tx: broadcast::Sender<ClientEvent>,
    status_tx: watch::Sender<ClientStatus>,
    failure_tx: watch::Sender<Option<ClientFailure>>,
    status: ClientStatus,
    failure: Option<ClientFailure>,
    backend: Arc<dyn ClientBackend>,
}

impl ClientRunner {
    /// Runs the client command loop until shutdown or all handles are dropped.
    pub async fn run(mut self) {
        log::debug!("inline client runner started");
        while let Some(command) = self.command_rx.recv().await {
            match command {
                ClientCommand::Request {
                    request,
                    respond_to,
                } => {
                    let response = self.handle_request(*request).await;
                    let _ = respond_to.send(response);
                }
                ClientCommand::SetStatus {
                    status,
                    failure,
                    respond_to,
                } => {
                    self.update_status(status, failure);
                    let _ = respond_to.send(());
                }
                ClientCommand::Shutdown { respond_to } => {
                    log::debug!("inline client runner shutdown requested");
                    self.update_status(ClientStatus::ShuttingDown, None);
                    let _ = respond_to.send(());
                    break;
                }
            }
        }
        log::debug!("inline client runner stopped");
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
                let result = self.backend.auth_verify(auth).await?;
                let status = result.status.clone();
                self.update_status(status.status, status.failure.clone());
                Ok(ClientResponse::AuthVerify(result))
            }
            ClientRequest::Resume => match self.backend.resume_session().await {
                Ok(status) => {
                    self.update_status(status.status, status.failure.clone());
                    Ok(ClientResponse::Status(status))
                }
                Err(error) => {
                    self.update_status_for_backend_error(&error);
                    Err(error)
                }
            },
            ClientRequest::Connect(connect) => {
                let status = self.backend.connect(connect).await?;
                self.update_status(status.status, status.failure.clone());
                Ok(ClientResponse::Status(status))
            }
            ClientRequest::Logout => {
                self.backend.logout().await?;
                self.update_status(ClientStatus::Disconnected, None);
                Ok(ClientResponse::Empty)
            }
            ClientRequest::Dialogs(dialogs) => self
                .backend
                .dialogs(dialogs)
                .await
                .map(ClientResponse::Dialogs),
            ClientRequest::History(history) => self
                .backend
                .history(history)
                .await
                .map(ClientResponse::History),
            ClientRequest::ChatParticipants(participants) => self
                .backend
                .chat_participants(participants)
                .await
                .map(ClientResponse::ChatParticipants),
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
                Ok(ClientResponse::Message(self.emit_send_outcome(outcome)))
            }
            ClientRequest::SendMedia { request, bytes } => {
                let outcome = self.backend.send_media(request, bytes).await?;
                Ok(ClientResponse::Message(self.emit_send_outcome(outcome)))
            }
            ClientRequest::EditMessage(edit) => {
                let outcome = self.backend.edit_message(edit).await?;
                self.emit_operation_events(outcome);
                Ok(ClientResponse::Empty)
            }
            ClientRequest::DeleteMessage(delete) => {
                let outcome = self.backend.delete_message(delete).await?;
                self.emit_operation_events(outcome);
                Ok(ClientResponse::Empty)
            }
            ClientRequest::React(react) => {
                let outcome = self.backend.react(react).await?;
                self.emit_operation_events(outcome);
                Ok(ClientResponse::Empty)
            }
            ClientRequest::Read(read) => {
                let outcome = self.backend.read(read).await?;
                self.emit_operation_events(outcome);
                Ok(ClientResponse::Empty)
            }
            ClientRequest::Typing(typing) => {
                let outcome = self.backend.typing(typing).await?;
                self.emit_operation_events(outcome);
                Ok(ClientResponse::Empty)
            }
        }
    }

    fn emit_operation_events(&self, outcome: OperationOutcome) {
        for event in outcome.events {
            let _ = self.event_tx.send(event);
        }
    }

    fn emit_send_outcome(&self, outcome: SendTextOutcome) -> MessageMutation {
        let transaction = outcome.transaction_event();
        let message_id = outcome.message_id;
        let chat_id = outcome.chat_id;
        let message = outcome.message;
        let mutation = outcome.mutation;
        let _ = self
            .event_tx
            .send(ClientEvent::TransactionChanged(transaction));
        if let Some(message_id) = message_id {
            let _ = self.event_tx.send(ClientEvent::MessageUpserted {
                chat_id,
                message_id,
            });
        }
        if let Some(message) = message {
            let _ = self.event_tx.send(ClientEvent::MessageStored { message });
        }
        mutation
    }

    fn update_status_for_backend_error(&mut self, error: &BackendError) {
        let status = match error.category {
            ClientErrorCategory::AuthRequired => ClientStatus::AuthRequired,
            ClientErrorCategory::AuthExpired => ClientStatus::AuthExpired,
            ClientErrorCategory::Network => ClientStatus::Reconnecting,
            _ => ClientStatus::Disconnected,
        };
        self.update_status(
            status,
            Some(ClientFailure::new(error.category, error.message.clone())),
        );
    }

    fn update_status(&mut self, status: ClientStatus, failure: Option<ClientFailure>) {
        log::debug!("inline client status changed: {status:?}");
        self.status = status;
        self.failure = failure.clone();
        let _ = self.status_tx.send(status);
        let _ = self.failure_tx.send(failure.clone());
        let _ = self
            .event_tx
            .send(ClientEvent::StatusChanged { status, failure });
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
    History(HistoryRequest),
    ChatParticipants(ChatParticipantsRequest),
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
    Typing(TypingRequest),
}

impl ClientRequest {
    const fn kind(&self) -> &'static str {
        match self {
            Self::AuthStart(_) => "auth_start",
            Self::AuthVerify(_) => "auth_verify",
            Self::Resume => "resume",
            Self::Connect(_) => "connect",
            Self::Logout => "logout",
            Self::Dialogs(_) => "dialogs",
            Self::History(_) => "history",
            Self::ChatParticipants(_) => "chat_participants",
            Self::CreateDm(_) => "create_dm",
            Self::CreateThread(_) => "create_thread",
            Self::CreateReplyThread(_) => "create_reply_thread",
            Self::SendText(_) => "send_text",
            Self::SendMedia { .. } => "send_media",
            Self::EditMessage(_) => "edit_message",
            Self::DeleteMessage(_) => "delete_message",
            Self::React(_) => "react",
            Self::Read(_) => "read",
            Self::Typing(_) => "typing",
        }
    }
}

#[derive(Debug)]
enum ClientResponse {
    Empty,
    Status(ClientStatusSnapshot),
    AuthStart(AuthStartResult),
    AuthVerify(AuthVerifyResult),
    Dialogs(DialogsPage),
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

        let event = events.recv().await.unwrap();
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

        let event = events.recv().await.unwrap();
        assert!(matches!(
            event,
            ClientEvent::StatusChanged {
                status: ClientStatus::Connected,
                ..
            }
        ));
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

        let event = events.recv().await.unwrap();
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

        let event = events.recv().await.unwrap();
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
}

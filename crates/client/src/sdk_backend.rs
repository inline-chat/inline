//! SDK-backed backend skeleton.
//!
//! This backend is the production-facing seam: it owns the configured
//! `inline-sdk` clients and durable store. Network-backed realtime sync and
//! transaction managers will be added behind this type without changing the
//! native client API or runner shape.

use std::{
    collections::HashMap,
    fmt,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use futures_util::future::BoxFuture;
use inline_sdk::{
    ApiClient, ApiError, AuthMetadata, ClientIdentity, RealtimeClient, RealtimeError,
    UploadFileBytesInput, UploadFileResult, UploadFileType, UploadVideoMetadata, proto,
};
use serde_json::Value;

use crate::{
    AuthContactKind, AuthCredential, AuthStartRequest, AuthStartResult, AuthToken,
    AuthVerifyRequest, AuthVerifyResult, BackendError, BackendResult, ChatCreateParticipant,
    ChatParticipantRecord, ChatParticipantsPage, ChatParticipantsRequest, ClientBackend,
    ClientErrorCategory, ClientEvent, ClientStatusSnapshot, ClientStore, ConnectRequest,
    CreateDmRequest, CreateReplyThreadRequest, CreateThreadRequest, CreatedChat,
    DeleteMessageRequest, DialogRecord, DialogsPage, DialogsRequest, EditMessageRequest,
    HistoryPage, HistoryRequest, InMemoryStore, InlineId, MediaKind, MessageContent,
    MessageMutation, MessageRecord, OperationOutcome, PeerRef, RandomId, ReactRequest, ReadRequest,
    RealtimeConnectRequest, RealtimeConnector, SdkRealtimeConnector, SendTextOutcome,
    SendTextRequest, StoreError, StoredSession, StoredTransaction, TransactionId,
    TransactionIdentity, TransactionState, TypingRequest, UploadRequest, UserRecord, VERSION,
};

const DEFAULT_API_BASE_URL: &str = "https://api.inline.chat/v1";
const DEFAULT_REALTIME_URL: &str = "wss://api.inline.chat/realtime";

/// Error returned when building an [`SdkBackend`].
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum SdkBackendBuildError {
    /// API client configuration failed.
    #[error("failed to build Inline API client: {0}")]
    Api(#[from] ApiError),
}

/// Builder for [`SdkBackend`].
#[derive(Clone)]
pub struct SdkBackendBuilder {
    api_base_url: String,
    realtime_url: String,
    identity: ClientIdentity,
    store: Arc<dyn ClientStore>,
    realtime_connector: Option<Arc<dyn RealtimeConnector>>,
}

impl fmt::Debug for SdkBackendBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SdkBackendBuilder")
            .field("api_base_url", &self.api_base_url)
            .field("realtime_url", &redacted_url_for_debug(&self.realtime_url))
            .field("identity", &self.identity)
            .field("store", &"<client-store>")
            .field(
                "realtime_connector",
                &self
                    .realtime_connector
                    .as_ref()
                    .map(|_| "<realtime-connector>"),
            )
            .finish()
    }
}

impl Default for SdkBackendBuilder {
    fn default() -> Self {
        Self {
            api_base_url: DEFAULT_API_BASE_URL.to_owned(),
            realtime_url: DEFAULT_REALTIME_URL.to_owned(),
            identity: ClientIdentity::new("inline-client", VERSION),
            store: Arc::new(InMemoryStore::new()),
            realtime_connector: None,
        }
    }
}

impl SdkBackendBuilder {
    /// Sets the Inline API base URL.
    pub fn api_base_url(mut self, api_base_url: impl Into<String>) -> Self {
        self.api_base_url = api_base_url.into();
        self
    }

    /// Sets the Inline realtime WebSocket URL.
    pub fn realtime_url(mut self, realtime_url: impl Into<String>) -> Self {
        self.realtime_url = realtime_url.into();
        self
    }

    /// Sets the client identity sent through SDK transports.
    pub fn identity(mut self, identity: ClientIdentity) -> Self {
        self.identity = identity;
        self
    }

    /// Sets the client store.
    pub fn store(mut self, store: impl ClientStore) -> Self {
        self.store = Arc::new(store);
        self
    }

    /// Sets a shared client store.
    pub fn shared_store(mut self, store: Arc<dyn ClientStore>) -> Self {
        self.store = store;
        self
    }

    /// Enables realtime handshake using the SDK realtime connector.
    pub fn enable_realtime_handshake(mut self) -> Self {
        self.realtime_connector = Some(Arc::new(SdkRealtimeConnector::new()));
        self
    }

    /// Sets a custom realtime connector.
    pub fn realtime_connector(mut self, connector: impl RealtimeConnector) -> Self {
        self.realtime_connector = Some(Arc::new(connector));
        self
    }

    /// Sets a shared realtime connector.
    pub fn shared_realtime_connector(mut self, connector: Arc<dyn RealtimeConnector>) -> Self {
        self.realtime_connector = Some(connector);
        self
    }

    /// Disables realtime handshake on connect.
    pub fn without_realtime_handshake(mut self) -> Self {
        self.realtime_connector = None;
        self
    }

    /// Builds an SDK-backed backend.
    pub fn build(self) -> Result<SdkBackend, SdkBackendBuildError> {
        let api = ApiClient::try_new_with_identity(self.api_base_url, self.identity.clone())?;
        Ok(SdkBackend {
            api,
            realtime_url: self.realtime_url,
            identity: self.identity,
            store: self.store,
            realtime_connector: self.realtime_connector,
        })
    }
}

/// Production-facing backend composed from `inline-sdk` and a client store.
#[derive(Clone)]
pub struct SdkBackend {
    api: ApiClient,
    realtime_url: String,
    identity: ClientIdentity,
    store: Arc<dyn ClientStore>,
    realtime_connector: Option<Arc<dyn RealtimeConnector>>,
}

impl fmt::Debug for SdkBackend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SdkBackend")
            .field("api", &self.api)
            .field("realtime_url", &redacted_url_for_debug(&self.realtime_url))
            .field("identity", &self.identity)
            .field("store", &"<client-store>")
            .field(
                "realtime_connector",
                &self
                    .realtime_connector
                    .as_ref()
                    .map(|_| "<realtime-connector>"),
            )
            .finish()
    }
}

impl SdkBackend {
    /// Starts an SDK backend builder.
    pub fn builder() -> SdkBackendBuilder {
        SdkBackendBuilder::default()
    }

    /// Returns the configured API client.
    pub fn api_client(&self) -> &ApiClient {
        &self.api
    }

    /// Returns the configured realtime URL.
    pub fn realtime_url(&self) -> &str {
        &self.realtime_url
    }

    /// Returns the configured client identity.
    pub fn identity(&self) -> &ClientIdentity {
        &self.identity
    }

    /// Returns the shared store.
    pub fn store(&self) -> Arc<dyn ClientStore> {
        self.store.clone()
    }

    /// Returns whether connect will perform a realtime handshake.
    pub fn realtime_handshake_enabled(&self) -> bool {
        self.realtime_connector.is_some()
    }

    async fn require_session(&self) -> BackendResult<StoredSession> {
        self.store
            .load_session()
            .await
            .map_err(store_error_to_backend)?
            .ok_or_else(|| {
                BackendError::new(ClientErrorCategory::AuthRequired, "client is not connected")
            })
    }

    async fn connect_realtime(&self, session: &StoredSession) -> BackendResult<RealtimeClient> {
        RealtimeClient::connect_with_identity(
            &self.realtime_url,
            session.auth.access_token().expose_secret(),
            self.identity.clone(),
        )
        .await
        .map_err(realtime_error_to_backend)
    }

    async fn connect_with_auth(
        &self,
        request: ConnectRequest,
    ) -> BackendResult<ClientStatusSnapshot> {
        if let Some(connector) = &self.realtime_connector {
            connector
                .connect(RealtimeConnectRequest::new(
                    self.realtime_url.clone(),
                    request.auth.access_token().clone(),
                    self.identity.clone(),
                ))
                .await?;
        }
        self.store
            .save_session(StoredSession {
                auth: request.auth,
                account_namespace: request.account_namespace,
            })
            .await
            .map_err(store_error_to_backend)?;
        Ok(ClientStatusSnapshot::current(
            crate::ClientStatus::Connected,
        ))
    }

    fn auth_metadata(
        &self,
        kind: AuthContactKind,
        contact: &str,
        device_name: Option<&str>,
    ) -> AuthMetadata {
        let device_id = format!(
            "inline-client-{:016x}",
            stable_hash(&format!("{}:{contact}", kind.as_str()))
        );
        let metadata = AuthMetadata::new(device_id, self.identity.clone());
        match device_name
            .map(str::trim)
            .filter(|device_name| !device_name.is_empty())
        {
            Some(device_name) => metadata.with_device_name(device_name),
            None => metadata.with_device_name(self.identity.client_type()),
        }
    }

    async fn resume_stored_session(&self) -> BackendResult<ClientStatusSnapshot> {
        let Some(session) = self
            .store
            .load_session()
            .await
            .map_err(store_error_to_backend)?
        else {
            return Ok(ClientStatusSnapshot::current(
                crate::ClientStatus::AuthRequired,
            ));
        };

        if let Some(connector) = &self.realtime_connector {
            connector
                .connect(RealtimeConnectRequest::new(
                    self.realtime_url.clone(),
                    session.auth.access_token().clone(),
                    self.identity.clone(),
                ))
                .await?;
        }
        Ok(ClientStatusSnapshot::current(
            crate::ClientStatus::Connected,
        ))
    }
}

impl ClientBackend for SdkBackend {
    fn auth_start(
        &self,
        request: AuthStartRequest,
    ) -> BoxFuture<'static, BackendResult<AuthStartResult>> {
        let backend = self.clone();
        Box::pin(async move {
            let contact = request.contact.trim().to_owned();
            if contact.is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "auth contact must not be empty",
                ));
            }
            let metadata =
                backend.auth_metadata(request.kind, &contact, request.device_name.as_deref());
            let result = match request.kind {
                AuthContactKind::Email => backend
                    .api
                    .send_email_code(&contact, &metadata)
                    .await
                    .map_err(api_error_to_backend)?,
                AuthContactKind::Phone => backend
                    .api
                    .send_sms_code(&contact, &metadata)
                    .await
                    .map_err(api_error_to_backend)?,
            };
            Ok(AuthStartResult {
                existing_user: result.existing_user,
                needs_invite_code: result.needs_invite_code,
                challenge_token: result.challenge_token,
            })
        })
    }

    fn auth_verify(
        &self,
        request: AuthVerifyRequest,
    ) -> BoxFuture<'static, BackendResult<AuthVerifyResult>> {
        let backend = self.clone();
        Box::pin(async move {
            let contact = request.contact.trim().to_owned();
            let code = request.code.trim().to_owned();
            if contact.is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "auth contact must not be empty",
                ));
            }
            if code.is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "verification code must not be empty",
                ));
            }

            let metadata =
                backend.auth_metadata(request.kind, &contact, request.device_name.as_deref());
            let result = match request.kind {
                AuthContactKind::Email => backend
                    .api
                    .verify_email_code(
                        &contact,
                        &code,
                        request.challenge_token.as_deref(),
                        &metadata,
                    )
                    .await
                    .map_err(api_error_to_backend)?,
                AuthContactKind::Phone => backend
                    .api
                    .verify_sms_code(&contact, &code, &metadata)
                    .await
                    .map_err(api_error_to_backend)?,
            };
            let token = AuthToken::try_new(result.token).map_err(|error| {
                BackendError::new(ClientErrorCategory::ProtocolMismatch, error.to_string())
            })?;
            let account_namespace = request
                .account_namespace
                .map(|namespace| namespace.trim().to_owned())
                .filter(|namespace| !namespace.is_empty())
                .unwrap_or_else(|| result.user_id.to_string());
            let status = backend
                .connect_with_auth(
                    ConnectRequest::new(AuthCredential::AccessToken { token })
                        .with_account_namespace(account_namespace.clone()),
                )
                .await?;
            Ok(AuthVerifyResult {
                user_id: InlineId::new(result.user_id),
                account_namespace,
                status,
            })
        })
    }

    fn resume_session(&self) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>> {
        let backend = self.clone();
        Box::pin(async move { backend.resume_stored_session().await })
    }

    fn connect(
        &self,
        request: ConnectRequest,
    ) -> BoxFuture<'static, BackendResult<ClientStatusSnapshot>> {
        let backend = self.clone();
        Box::pin(async move { backend.connect_with_auth(request).await })
    }

    fn logout(&self) -> BoxFuture<'static, BackendResult<()>> {
        let backend = self.clone();
        Box::pin(async move {
            backend
                .store
                .clear_session()
                .await
                .map_err(store_error_to_backend)
        })
    }

    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, BackendResult<DialogsPage>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let live: BackendResult<DialogsPage> = async {
                let mut realtime = backend.connect_realtime(&session).await?;
                let result = realtime
                    .call(proto::GetChatsInput {})
                    .await
                    .map_err(realtime_error_to_backend)?;
                let page = dialogs_page_from_get_chats(&result, request.clone())?;
                for dialog in &page.dialogs {
                    backend
                        .store
                        .record_dialog(dialog.clone())
                        .await
                        .map_err(store_error_to_backend)?;
                }
                backend
                    .store
                    .record_users(page.users.clone())
                    .await
                    .map_err(store_error_to_backend)?;
                for message in result.messages {
                    let record = message_record_from_proto_message(message, None, None);
                    backend
                        .store
                        .record_message(record)
                        .await
                        .map_err(store_error_to_backend)?;
                }
                backend
                    .store
                    .dialogs(request.clone())
                    .await
                    .map_err(store_error_to_backend)
            }
            .await;
            match live {
                Ok(page) => Ok(page),
                Err(error) => {
                    log::warn!(
                        "Inline realtime dialog sync failed; serving cached dialogs: {}",
                        error
                    );
                    backend
                        .store
                        .dialogs(request)
                        .await
                        .map_err(store_error_to_backend)
                }
            }
        })
    }

    fn history(&self, request: HistoryRequest) -> BoxFuture<'static, BackendResult<HistoryPage>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            if request.before_message_id.is_some() && request.after_message_id.is_some() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "history request cannot specify both before_message_id and after_message_id",
                ));
            }
            let limit = request.limit.unwrap_or(50).max(1);
            let live: BackendResult<HistoryPage> = async {
                let mut realtime = backend.connect_realtime(&session).await?;
                let fetch_limit = limit.saturating_add(1).min(i32::MAX as u32) as i32;
                let result = realtime
                    .call(history_input_for_request(&request, fetch_limit))
                    .await
                    .map_err(realtime_error_to_backend)?;
                let mut records = result
                    .messages
                    .into_iter()
                    .map(|message| {
                        message_record_from_proto_message(message, Some(request.chat_id), None)
                    })
                    .collect::<Vec<_>>();
                records.sort_by_key(|message| (message.timestamp, message.message_id.get()));
                let has_more = records.len() > limit as usize;
                if has_more {
                    records.truncate(limit as usize);
                }
                for message in &records {
                    backend
                        .store
                        .record_message(message.clone())
                        .await
                        .map_err(store_error_to_backend)?;
                }
                Ok(HistoryPage {
                    messages: records,
                    users: Vec::new(),
                    has_more,
                    next_cursor: None,
                })
            }
            .await;
            match live {
                Ok(page) => Ok(page),
                Err(error) => {
                    log::warn!(
                        "Inline realtime history sync failed; serving cached history for chat {}: {}",
                        request.chat_id.get(),
                        error
                    );
                    backend
                        .store
                        .history(request)
                        .await
                        .map_err(store_error_to_backend)
                }
            }
        })
    }

    fn chat_participants(
        &self,
        request: ChatParticipantsRequest,
    ) -> BoxFuture<'static, BackendResult<ChatParticipantsPage>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            let result = realtime
                .call(proto::GetChatParticipantsInput {
                    chat_id: request.chat_id.get(),
                })
                .await
                .map_err(realtime_error_to_backend)?;
            let page = chat_participants_page_from_proto(result);
            backend
                .store
                .record_users(page.users.clone())
                .await
                .map_err(store_error_to_backend)?;
            Ok(page)
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
            let session = backend.require_session().await?;
            let result = backend
                .api
                .create_private_chat(
                    session.auth.access_token().expose_secret(),
                    request.user_id.get(),
                )
                .await
                .map_err(api_error_to_backend)?;
            let (created, user) = created_chat_from_private_chat_result(
                result.chat,
                result.dialog,
                result.user,
                request.user_id,
            )?;
            backend
                .store
                .record_dialog(DialogRecord {
                    chat_id: created.chat_id,
                    peer_user_id: Some(request.user_id),
                    title: created.title.clone(),
                    last_message_id: None,
                    synced_through_message_id: None,
                    unread_count: Some(0),
                })
                .await
                .map_err(store_error_to_backend)?;
            if let Some(user) = user {
                backend
                    .store
                    .record_users(vec![user])
                    .await
                    .map_err(store_error_to_backend)?;
            }
            Ok(created)
        })
    }

    fn create_thread(
        &self,
        request: CreateThreadRequest,
    ) -> BoxFuture<'static, BackendResult<CreatedChat>> {
        let backend = self.clone();
        Box::pin(async move {
            validate_create_participants(&request.participants)?;
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            let result = realtime
                .call(proto::CreateChatInput {
                    title: trimmed_option(request.title),
                    space_id: request.space_id.map(InlineId::get),
                    description: trimmed_option(request.description),
                    emoji: trimmed_option(request.emoji),
                    is_public: request.is_public,
                    participants: request
                        .participants
                        .into_iter()
                        .map(|participant| proto::InputChatParticipant {
                            user_id: participant.user_id.get(),
                        })
                        .collect(),
                    reserved_chat_id: None,
                })
                .await
                .map_err(realtime_error_to_backend)?;
            let created = created_chat_from_proto(result.chat, result.dialog, None, None, None)?;
            backend
                .store
                .record_dialog(DialogRecord {
                    chat_id: created.chat_id,
                    peer_user_id: None,
                    title: created.title.clone(),
                    last_message_id: None,
                    synced_through_message_id: None,
                    unread_count: Some(0),
                })
                .await
                .map_err(store_error_to_backend)?;
            Ok(created)
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
            validate_create_participants(&request.participants)?;
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            let result = realtime
                .call(proto::CreateSubthreadInput {
                    parent_chat_id: request.parent_chat_id.get(),
                    parent_message_id: request.parent_message_id.map(InlineId::get),
                    title: trimmed_option(request.title),
                    description: trimmed_option(request.description),
                    emoji: trimmed_option(request.emoji),
                    participants: request
                        .participants
                        .into_iter()
                        .map(|participant| proto::InputChatParticipant {
                            user_id: participant.user_id.get(),
                        })
                        .collect(),
                })
                .await
                .map_err(realtime_error_to_backend)?;
            let created = created_chat_from_proto(
                result.chat,
                result.dialog,
                result.anchor_message,
                Some(request.parent_chat_id),
                request.parent_message_id,
            )?;
            backend
                .store
                .record_dialog(DialogRecord {
                    chat_id: created.chat_id,
                    peer_user_id: None,
                    title: created.title.clone(),
                    last_message_id: None,
                    synced_through_message_id: None,
                    unread_count: Some(0),
                })
                .await
                .map_err(store_error_to_backend)?;
            Ok(created)
        })
    }

    fn send_text(
        &self,
        request: SendTextRequest,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            if request.text.trim().is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "message text must not be empty",
                ));
            }

            let session = backend.require_session().await?;
            let initial_chat_id = chat_id_for_peer(request.peer);
            let random_id = request
                .random_id
                .unwrap_or_else(|| random_id_for_request(&request));
            let transaction_id = transaction_id_for_send(&request, random_id);
            let identity = TransactionIdentity::new(
                transaction_id.clone(),
                request.external_id.clone(),
                random_id,
            );

            if let Some(existing) = backend
                .store
                .transaction(transaction_id.clone())
                .await
                .map_err(store_error_to_backend)?
            {
                return Ok(outcome_from_stored_transaction(existing, initial_chat_id));
            }

            backend
                .store
                .record_transaction(
                    StoredTransaction::new(identity.clone(), TransactionState::Queued)
                        .with_chat_id(initial_chat_id),
                )
                .await
                .map_err(store_error_to_backend)?;

            let mut realtime = match RealtimeClient::connect_with_identity(
                &backend.realtime_url,
                session.auth.access_token().expose_secret(),
                backend.identity.clone(),
            )
            .await
            {
                Ok(realtime) => realtime,
                Err(error) => {
                    let backend_error = realtime_error_to_backend(error);
                    backend
                        .record_failed_transaction(identity, initial_chat_id, backend_error.clone())
                        .await?;
                    return Err(backend_error);
                }
            };

            backend
                .store
                .record_transaction(
                    StoredTransaction::new(identity.clone(), TransactionState::Sent)
                        .with_chat_id(initial_chat_id),
                )
                .await
                .map_err(store_error_to_backend)?;

            let input = proto::SendMessageInput {
                peer_id: Some(input_peer_for_client_peer(request.peer)),
                message: Some(request.text.clone()),
                reply_to_msg_id: request.reply_to_message_id.map(InlineId::get),
                random_id: Some(random_id.get()),
                media: None,
                temporary_send_date: Some(now_seconds()),
                is_sticker: None,
                has_link: None,
                entities: None,
                parse_markdown: Some(false),
                send_mode: None,
                actions: None,
            };
            let send_result = match realtime.call(input).await {
                Ok(result) => result,
                Err(error) => {
                    let backend_error = realtime_error_to_backend(error);
                    backend
                        .record_failed_transaction(identity, initial_chat_id, backend_error.clone())
                        .await?;
                    return Err(backend_error);
                }
            };

            let applied =
                apply_send_message_updates(&request, identity, initial_chat_id, send_result);
            if let Some(message) = &applied.message {
                backend
                    .store
                    .record_message(message.clone())
                    .await
                    .map_err(store_error_to_backend)?;
            }
            backend
                .store
                .record_transaction(applied.transaction.clone())
                .await
                .map_err(store_error_to_backend)?;

            Ok(SendTextOutcome::with_state(
                MessageMutation {
                    transaction: applied.transaction.identity,
                    message_id: applied.message_id,
                },
                applied.chat_id,
                applied.message_id,
                applied.message,
                applied.transaction.state,
                applied.transaction.failure,
            ))
        })
    }

    fn send_media(
        &self,
        request: UploadRequest,
        bytes: Vec<u8>,
    ) -> BoxFuture<'static, BackendResult<SendTextOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            if bytes.is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "media bytes must not be empty",
                ));
            }

            let session = backend.require_session().await?;
            let initial_chat_id = chat_id_for_peer(request.peer);
            let random_id = request
                .random_id
                .unwrap_or_else(|| random_id_for_upload_request(&request, bytes.len()));
            let transaction_id = transaction_id_for_upload(&request, random_id);
            let identity = TransactionIdentity::new(
                transaction_id.clone(),
                request.external_id.clone(),
                random_id,
            );

            if let Some(existing) = backend
                .store
                .transaction(transaction_id.clone())
                .await
                .map_err(store_error_to_backend)?
            {
                return Ok(outcome_from_stored_transaction(existing, initial_chat_id));
            }

            backend
                .store
                .record_transaction(
                    StoredTransaction::new(identity.clone(), TransactionState::Queued)
                        .with_chat_id(initial_chat_id),
                )
                .await
                .map_err(store_error_to_backend)?;

            let upload_input = upload_input_for_request(&request, bytes);
            let upload = match backend
                .api
                .upload_file_bytes(session.auth.access_token().expose_secret(), upload_input)
                .await
            {
                Ok(upload) => upload,
                Err(error) => {
                    let backend_error = api_error_to_backend(error);
                    backend
                        .record_failed_transaction(identity, initial_chat_id, backend_error.clone())
                        .await?;
                    return Err(backend_error);
                }
            };
            let media = match input_media_from_upload(&upload) {
                Ok(media) => media,
                Err(error) => {
                    backend
                        .record_failed_transaction(identity, initial_chat_id, error.clone())
                        .await?;
                    return Err(error);
                }
            };

            let mut realtime = match backend.connect_realtime(&session).await {
                Ok(realtime) => realtime,
                Err(error) => {
                    backend
                        .record_failed_transaction(identity, initial_chat_id, error.clone())
                        .await?;
                    return Err(error);
                }
            };

            backend
                .store
                .record_transaction(
                    StoredTransaction::new(identity.clone(), TransactionState::Sent)
                        .with_chat_id(initial_chat_id),
                )
                .await
                .map_err(store_error_to_backend)?;

            let input = proto::SendMessageInput {
                peer_id: Some(input_peer_for_client_peer(request.peer)),
                message: request.caption.clone(),
                reply_to_msg_id: request.reply_to_message_id.map(InlineId::get),
                random_id: Some(random_id.get()),
                media: Some(media),
                temporary_send_date: Some(now_seconds()),
                is_sticker: None,
                has_link: None,
                entities: None,
                parse_markdown: Some(false),
                send_mode: None,
                actions: None,
            };
            let send_result = match realtime.call(input).await {
                Ok(result) => result,
                Err(error) => {
                    let backend_error = realtime_error_to_backend(error);
                    backend
                        .record_failed_transaction(identity, initial_chat_id, backend_error.clone())
                        .await?;
                    return Err(backend_error);
                }
            };

            let applied =
                apply_upload_message_updates(&request, identity, initial_chat_id, send_result);
            if let Some(message) = &applied.message {
                backend
                    .store
                    .record_message(message.clone())
                    .await
                    .map_err(store_error_to_backend)?;
            }
            backend
                .store
                .record_transaction(applied.transaction.clone())
                .await
                .map_err(store_error_to_backend)?;

            Ok(SendTextOutcome::with_state(
                MessageMutation {
                    transaction: applied.transaction.identity,
                    message_id: applied.message_id,
                },
                applied.chat_id,
                applied.message_id,
                applied.message,
                applied.transaction.state,
                applied.transaction.failure,
            ))
        })
    }

    fn edit_message(
        &self,
        request: EditMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            if request.text.trim().is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "message text must not be empty",
                ));
            }
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            let result = realtime
                .call(proto::EditMessageInput {
                    message_id: request.message_id.get(),
                    peer_id: Some(input_peer_for_chat(request.chat_id)),
                    text: request.text,
                    entities: None,
                    parse_markdown: Some(false),
                    actions: None,
                })
                .await
                .map_err(realtime_error_to_backend)?;
            let events = backend
                .apply_updates(result.updates, Some(request.chat_id), None)
                .await?;
            Ok(OperationOutcome::with_events(events))
        })
    }

    fn delete_message(
        &self,
        request: DeleteMessageRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            let result = realtime
                .call(proto::DeleteMessagesInput {
                    message_ids: vec![request.message_id.get()],
                    peer_id: Some(input_peer_for_chat(request.chat_id)),
                })
                .await
                .map_err(realtime_error_to_backend)?;
            let mut events = backend
                .apply_updates(result.updates, Some(request.chat_id), None)
                .await?;
            if !events.iter().any(|event| {
                matches!(
                    event,
                    ClientEvent::MessageDeleted {
                        chat_id,
                        message_id
                    } if *chat_id == request.chat_id && *message_id == request.message_id
                )
            }) {
                events.push(ClientEvent::MessageDeleted {
                    chat_id: request.chat_id,
                    message_id: request.message_id,
                });
            }
            Ok(OperationOutcome::with_events(events))
        })
    }

    fn react(&self, request: ReactRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            let reaction = request.reaction.trim().to_owned();
            if reaction.is_empty() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "reaction must not be empty",
                ));
            }
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            let updates = if request.remove {
                realtime
                    .call(proto::DeleteReactionInput {
                        emoji: reaction.clone(),
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                        message_id: request.message_id.get(),
                    })
                    .await
                    .map_err(realtime_error_to_backend)?
                    .updates
            } else {
                realtime
                    .call(proto::AddReactionInput {
                        emoji: reaction.clone(),
                        message_id: request.message_id.get(),
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                    })
                    .await
                    .map_err(realtime_error_to_backend)?
                    .updates
            };
            let mut events = backend
                .apply_updates(updates, Some(request.chat_id), None)
                .await?;
            if !events.iter().any(|event| {
                matches!(
                    event,
                    ClientEvent::ReactionChanged {
                        chat_id,
                        message_id,
                        ..
                    } if *chat_id == request.chat_id && *message_id == request.message_id
                )
            }) {
                events.push(ClientEvent::ReactionChanged {
                    chat_id: request.chat_id,
                    message_id: request.message_id,
                    user_id: InlineId::new(0),
                    reaction,
                    removed: request.remove,
                });
            }
            Ok(OperationOutcome::with_events(events))
        })
    }

    fn read(&self, request: ReadRequest) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            let result = realtime
                .call(proto::ReadMessagesInput {
                    peer_id: Some(input_peer_for_chat(request.chat_id)),
                    max_id: request.max_message_id.map(InlineId::get),
                })
                .await
                .map_err(realtime_error_to_backend)?;
            let mut events = backend
                .apply_updates(result.updates, Some(request.chat_id), None)
                .await?;
            if !events.iter().any(|event| {
                matches!(event, ClientEvent::ReadStateChanged { chat_id } if *chat_id == request.chat_id)
            }) {
                events.push(ClientEvent::ReadStateChanged {
                    chat_id: request.chat_id,
                });
            }
            Ok(OperationOutcome::with_events(events))
        })
    }

    fn typing(
        &self,
        request: TypingRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let mut realtime = backend.connect_realtime(&session).await?;
            realtime
                .call(proto::SendComposeActionInput {
                    peer_id: Some(input_peer_for_chat(request.chat_id)),
                    action: request
                        .is_typing
                        .then_some(proto::update_compose_action::ComposeAction::Typing as i32),
                })
                .await
                .map_err(realtime_error_to_backend)?;
            Ok(OperationOutcome::empty())
        })
    }
}

impl SdkBackend {
    async fn record_failed_transaction(
        &self,
        identity: TransactionIdentity,
        chat_id: InlineId,
        error: BackendError,
    ) -> BackendResult<()> {
        self.store
            .record_transaction(
                StoredTransaction::new(identity, TransactionState::Failed)
                    .with_chat_id(chat_id)
                    .with_failure(error.into()),
            )
            .await
            .map_err(store_error_to_backend)
    }

    async fn apply_updates(
        &self,
        updates: Vec<proto::Update>,
        fallback_chat_id: Option<InlineId>,
        transaction: Option<TransactionIdentity>,
    ) -> BackendResult<Vec<ClientEvent>> {
        let mut events = Vec::new();
        for update in updates {
            match update.update {
                Some(proto::update::Update::NewMessage(update)) => {
                    if let Some(message) = update.message {
                        let record =
                            message_record_from_proto_message(message, fallback_chat_id, None);
                        self.store
                            .record_message(record.clone())
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::MessageStored { message: record });
                    }
                }
                Some(proto::update::Update::EditMessage(update)) => {
                    if let Some(message) = update.message {
                        let record =
                            message_record_from_proto_message(message, fallback_chat_id, None);
                        self.store
                            .record_message(record.clone())
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::MessageStored { message: record });
                    }
                }
                Some(proto::update::Update::DeleteMessages(update)) => {
                    let chat_id = update
                        .peer_id
                        .as_ref()
                        .and_then(chat_id_from_peer)
                        .or(fallback_chat_id);
                    if let Some(chat_id) = chat_id {
                        for message_id in update.message_ids {
                            events.push(ClientEvent::MessageDeleted {
                                chat_id,
                                message_id: InlineId::new(message_id),
                            });
                        }
                    }
                }
                Some(proto::update::Update::UpdateReaction(update)) => {
                    if let Some(reaction) = update.reaction {
                        events.push(ClientEvent::ReactionChanged {
                            chat_id: InlineId::new(reaction.chat_id),
                            message_id: InlineId::new(reaction.message_id),
                            user_id: InlineId::new(reaction.user_id),
                            reaction: reaction.emoji,
                            removed: false,
                        });
                    }
                }
                Some(proto::update::Update::DeleteReaction(update)) => {
                    events.push(ClientEvent::ReactionChanged {
                        chat_id: InlineId::new(update.chat_id),
                        message_id: InlineId::new(update.message_id),
                        user_id: InlineId::new(update.user_id),
                        reaction: update.emoji,
                        removed: true,
                    });
                }
                Some(proto::update::Update::UpdateReadMaxId(update)) => {
                    let chat_id = update
                        .peer_id
                        .as_ref()
                        .and_then(chat_id_from_peer)
                        .or(fallback_chat_id);
                    if let Some(chat_id) = chat_id {
                        events.push(ClientEvent::ReadStateChanged { chat_id });
                    }
                }
                Some(proto::update::Update::UpdateComposeAction(update)) => {
                    let chat_id = update
                        .peer_id
                        .as_ref()
                        .and_then(chat_id_from_peer)
                        .or(fallback_chat_id);
                    if let Some(chat_id) = chat_id {
                        events.push(ClientEvent::Typing {
                            chat_id,
                            user_id: InlineId::new(update.user_id),
                            is_typing: update.action
                                == proto::update_compose_action::ComposeAction::Typing as i32,
                        });
                    }
                }
                Some(proto::update::Update::UpdateMessageId(update)) => {
                    if let (Some(chat_id), Some(transaction)) =
                        (fallback_chat_id, transaction.as_ref())
                        && update.random_id == transaction.random_id.get()
                    {
                        events.push(ClientEvent::MessageUpserted {
                            chat_id,
                            message_id: InlineId::new(update.message_id),
                        });
                    }
                }
                _ => {}
            }
        }
        Ok(events)
    }
}

fn store_error_to_backend(error: StoreError) -> BackendError {
    BackendError::new(error.category, error.message)
}

fn dialogs_page_from_get_chats(
    result: &proto::GetChatsResult,
    request: DialogsRequest,
) -> BackendResult<DialogsPage> {
    let users_by_id = result
        .users
        .iter()
        .map(|user| (user.id, user))
        .collect::<HashMap<_, _>>();
    let start = request
        .cursor
        .as_deref()
        .map(str::trim)
        .filter(|cursor| !cursor.is_empty())
        .map(|cursor| {
            cursor.parse::<usize>().map_err(|_| {
                BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "invalid pagination cursor",
                )
            })
        })
        .transpose()?
        .unwrap_or(0);
    let limit = request.limit.unwrap_or(100).max(1) as usize;

    let mut dialogs = result
        .chats
        .iter()
        .map(|chat| {
            let dialog = dialog_for_chat(result, chat);
            DialogRecord {
                chat_id: InlineId::new(chat.id),
                peer_user_id: dialog_peer_user_id(dialog, chat),
                title: Some(chat_display_name_from_proto(chat, &users_by_id)),
                last_message_id: chat.last_msg_id.map(InlineId::new),
                synced_through_message_id: None,
                unread_count: dialog
                    .and_then(|dialog| dialog.unread_count)
                    .and_then(|count| u32::try_from(count).ok()),
            }
        })
        .collect::<Vec<_>>();
    let total = dialogs.len();
    if start >= dialogs.len() {
        dialogs.clear();
    } else {
        dialogs = dialogs.into_iter().skip(start).take(limit).collect();
    }
    Ok(DialogsPage {
        dialogs,
        users: result.users.iter().map(user_record_from_proto).collect(),
        next_cursor: (start + limit < total).then(|| (start + limit).to_string()),
    })
}

fn dialog_for_chat<'a>(
    result: &'a proto::GetChatsResult,
    chat: &proto::Chat,
) -> Option<&'a proto::Dialog> {
    result.dialogs.iter().find(|dialog| {
        dialog.chat_id == Some(chat.id)
            || dialog
                .peer
                .as_ref()
                .zip(chat.peer_id.as_ref())
                .is_some_and(|(dialog_peer, chat_peer)| dialog_peer == chat_peer)
    })
}

fn dialog_peer_user_id(dialog: Option<&proto::Dialog>, chat: &proto::Chat) -> Option<InlineId> {
    dialog
        .and_then(|dialog| dialog.peer.as_ref())
        .or(chat.peer_id.as_ref())
        .and_then(user_id_from_peer)
        .map(InlineId::new)
}

fn chat_display_name_from_proto(
    chat: &proto::Chat,
    users_by_id: &HashMap<i64, &proto::User>,
) -> String {
    let mut name = chat
        .peer_id
        .as_ref()
        .and_then(user_id_from_peer)
        .and_then(|user_id| users_by_id.get(&user_id))
        .and_then(|user| user_display_name_from_proto(user))
        .unwrap_or_else(|| {
            let title = chat.title.trim();
            if title.is_empty() {
                format!("Chat {}", chat.id)
            } else {
                title.to_owned()
            }
        });
    if let Some(emoji) = chat
        .emoji
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        name = format!("{emoji} {name}");
    }
    name
}

fn user_record_from_proto(user: &proto::User) -> UserRecord {
    UserRecord {
        user_id: InlineId::new(user.id),
        display_name: user_display_name_from_proto(user),
        username: non_empty_option(user.username.as_deref()),
        first_name: non_empty_option(user.first_name.as_deref()),
        last_name: non_empty_option(user.last_name.as_deref()),
        avatar_url: user
            .profile_photo
            .as_ref()
            .and_then(|photo| non_empty_option(photo.cdn_url.as_deref()))
            .or_else(|| {
                user.bot_avatar
                    .as_ref()
                    .and_then(|avatar| non_empty_option(avatar.cdn_url.as_deref()))
            }),
        is_bot: user.bot,
    }
}

fn chat_participants_page_from_proto(
    result: proto::GetChatParticipantsResult,
) -> ChatParticipantsPage {
    let mut seen = std::collections::HashSet::new();
    let mut participants = Vec::new();
    for participant in result.participants {
        if seen.insert(participant.user_id) {
            participants.push(ChatParticipantRecord {
                user_id: InlineId::new(participant.user_id),
                date: Some(participant.date),
            });
        }
    }
    participants.sort_by_key(|participant| participant.user_id.get());
    ChatParticipantsPage {
        participants,
        users: result.users.iter().map(user_record_from_proto).collect(),
    }
}

fn validate_create_participants(participants: &[ChatCreateParticipant]) -> BackendResult<()> {
    if participants
        .iter()
        .any(|participant| participant.user_id.get() <= 0)
    {
        return Err(BackendError::new(
            ClientErrorCategory::InvalidInput,
            "participant user_id must be positive",
        ));
    }
    Ok(())
}

fn created_chat_from_private_chat_result(
    chat: Value,
    dialog: Value,
    user: Value,
    user_id: InlineId,
) -> BackendResult<(CreatedChat, Option<UserRecord>)> {
    let chat_id = api_i64_field(&chat, &["id", "chatId", "chat_id"])
        .or_else(|| api_i64_field(&dialog, &["chatId", "chat_id"]))
        .ok_or_else(|| {
            BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "create_private_chat result did not include a chat id",
            )
        })?;
    let user = user_record_from_api_value(&user).or(Some(UserRecord {
        user_id,
        display_name: None,
        username: None,
        first_name: None,
        last_name: None,
        avatar_url: None,
        is_bot: None,
    }));
    let title = api_string_field(&chat, &["title"])
        .or_else(|| user.as_ref().and_then(user_display_name_from_record));
    Ok((
        CreatedChat {
            chat_id: InlineId::new(chat_id),
            title,
            parent_chat_id: None,
            parent_message_id: None,
        },
        user,
    ))
}

fn created_chat_from_proto(
    chat: Option<proto::Chat>,
    dialog: Option<proto::Dialog>,
    anchor_message: Option<proto::Message>,
    parent_chat_id: Option<InlineId>,
    parent_message_id: Option<InlineId>,
) -> BackendResult<CreatedChat> {
    let chat_id = chat
        .as_ref()
        .map(|chat| chat.id)
        .or_else(|| dialog.as_ref().and_then(|dialog| dialog.chat_id))
        .ok_or_else(|| {
            BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "create chat result did not include a chat id",
            )
        })?;
    let title = chat
        .as_ref()
        .and_then(|chat| trimmed_option(Some(chat.title.clone())));
    let parent_chat_id = parent_chat_id.or_else(|| {
        chat.as_ref()
            .and_then(|chat| chat.parent_chat_id)
            .map(InlineId::new)
    });
    let parent_message_id = parent_message_id
        .or_else(|| {
            chat.as_ref()
                .and_then(|chat| chat.parent_message_id)
                .map(InlineId::new)
        })
        .or_else(|| anchor_message.map(|message| InlineId::new(message.id)));

    Ok(CreatedChat {
        chat_id: InlineId::new(chat_id),
        title,
        parent_chat_id,
        parent_message_id,
    })
}

fn user_record_from_api_value(value: &Value) -> Option<UserRecord> {
    let user_id = api_i64_field(value, &["id", "userId", "user_id"])?;
    Some(UserRecord {
        user_id: InlineId::new(user_id),
        display_name: api_string_field(value, &["displayName", "display_name", "name"]),
        username: api_string_field(value, &["username"]),
        first_name: api_string_field(value, &["firstName", "first_name"]),
        last_name: api_string_field(value, &["lastName", "last_name"]),
        avatar_url: api_string_field(value, &["avatarUrl", "avatar_url"])
            .or_else(|| api_nested_string_field(value, "profilePhoto", &["cdnUrl", "cdn_url"]))
            .or_else(|| api_nested_string_field(value, "profile_photo", &["cdnUrl", "cdn_url"]))
            .or_else(|| api_nested_string_field(value, "botAvatar", &["cdnUrl", "cdn_url"]))
            .or_else(|| api_nested_string_field(value, "bot_avatar", &["cdnUrl", "cdn_url"])),
        is_bot: api_bool_field(value, &["isBot", "is_bot", "bot"]),
    })
}

fn user_display_name_from_record(user: &UserRecord) -> Option<String> {
    user.display_name
        .clone()
        .or_else(|| {
            let first = user.first_name.as_deref().unwrap_or_default().trim();
            let last = user.last_name.as_deref().unwrap_or_default().trim();
            let full = [first, last]
                .into_iter()
                .filter(|part| !part.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            (!full.is_empty()).then_some(full)
        })
        .or_else(|| user.username.clone())
}

fn api_i64_field(value: &Value, fields: &[&str]) -> Option<i64> {
    fields
        .iter()
        .find_map(|field| value.get(*field).and_then(value_as_i64))
}

fn api_bool_field(value: &Value, fields: &[&str]) -> Option<bool> {
    fields
        .iter()
        .find_map(|field| value.get(*field).and_then(Value::as_bool))
}

fn api_string_field(value: &Value, fields: &[&str]) -> Option<String> {
    fields
        .iter()
        .find_map(|field| value.get(*field).and_then(value_as_string))
}

fn api_nested_string_field(value: &Value, field: &str, nested_fields: &[&str]) -> Option<String> {
    value
        .get(field)
        .and_then(|nested| api_string_field(nested, nested_fields))
}

fn value_as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().and_then(|value| i64::try_from(value).ok()))
        .or_else(|| value.as_str()?.trim().parse().ok())
}

fn value_as_string(value: &Value) -> Option<String> {
    value
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn trimmed_option(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn user_display_name_from_proto(user: &proto::User) -> Option<String> {
    if let Some(bot_name) = user
        .bot_avatar
        .as_ref()
        .and_then(|avatar| non_empty_option(Some(&avatar.display_name)))
    {
        return Some(bot_name);
    }
    let first = user.first_name.as_deref().unwrap_or_default().trim();
    let last = user.last_name.as_deref().unwrap_or_default().trim();
    let full = [first, last]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if !full.is_empty() {
        return Some(full);
    }
    non_empty_option(user.username.as_deref())
}

fn user_id_from_peer(peer: &proto::Peer) -> Option<i64> {
    match &peer.r#type {
        Some(proto::peer::Type::User(user)) => Some(user.user_id),
        _ => None,
    }
}

fn non_empty_option(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn realtime_error_to_backend(error: RealtimeError) -> BackendError {
    match error {
        RealtimeError::InvalidUrl { message, .. } => {
            BackendError::new(ClientErrorCategory::InvalidInput, message)
        }
        RealtimeError::Timeout { .. } => {
            BackendError::new(ClientErrorCategory::Timeout, error.to_string())
        }
        RealtimeError::ConnectionError { .. } | RealtimeError::RpcError { .. } => {
            BackendError::new(ClientErrorCategory::AuthExpired, error.to_string())
        }
        RealtimeError::ConnectionClosed | RealtimeError::WebSocket(_) => {
            BackendError::new(ClientErrorCategory::Network, error.to_string())
        }
        RealtimeError::InvalidHeaderValue { .. }
        | RealtimeError::Protocol(_)
        | RealtimeError::MissingResult
        | RealtimeError::UnexpectedResult { .. } => {
            BackendError::new(ClientErrorCategory::ProtocolMismatch, error.to_string())
        }
        _ => BackendError::new(ClientErrorCategory::Internal, error.to_string()),
    }
}

fn api_error_to_backend(error: ApiError) -> BackendError {
    let rendered = error.to_string();
    match error {
        ApiError::InvalidBaseUrl { message, .. } | ApiError::InvalidInput { message } => {
            BackendError::new(ClientErrorCategory::InvalidInput, message)
        }
        ApiError::Status { status, .. } if status == 401 || status == 403 => {
            BackendError::new(ClientErrorCategory::AuthExpired, rendered)
        }
        ApiError::Api {
            status: Some(401) | Some(403),
            ..
        } => BackendError::new(ClientErrorCategory::AuthExpired, rendered),
        ApiError::Http(_) | ApiError::Status { .. } => {
            BackendError::new(ClientErrorCategory::Network, rendered)
        }
        ApiError::Json(_) => BackendError::new(ClientErrorCategory::ProtocolMismatch, rendered),
        ApiError::Io(_) | ApiError::Api { .. } => {
            BackendError::new(ClientErrorCategory::Internal, rendered)
        }
        _ => BackendError::new(ClientErrorCategory::Internal, rendered),
    }
}

fn input_peer_for_client_peer(peer: PeerRef) -> proto::InputPeer {
    proto::InputPeer {
        r#type: Some(match peer {
            PeerRef::User { user_id } => proto::input_peer::Type::User(proto::InputPeerUser {
                user_id: user_id.get(),
            }),
            PeerRef::Chat { chat_id } => proto::input_peer::Type::Chat(proto::InputPeerChat {
                chat_id: chat_id.get(),
            }),
            PeerRef::Thread { thread_id } => proto::input_peer::Type::Chat(proto::InputPeerChat {
                chat_id: thread_id.get(),
            }),
        }),
    }
}

fn input_peer_for_chat(chat_id: InlineId) -> proto::InputPeer {
    proto::InputPeer {
        r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
            chat_id: chat_id.get(),
        })),
    }
}

fn history_input_for_request(
    request: &HistoryRequest,
    fetch_limit: i32,
) -> proto::GetChatHistoryInput {
    if let Some(after) = request.after_message_id {
        return proto::GetChatHistoryInput {
            peer_id: Some(input_peer_for_chat(request.chat_id)),
            offset_id: None,
            limit: Some(fetch_limit),
            mode: Some(proto::GetChatHistoryMode::HistoryModeNewer as i32),
            anchor_id: None,
            before_id: None,
            after_id: Some(after.get()),
            before_limit: None,
            after_limit: None,
            include_anchor: None,
        };
    }

    proto::GetChatHistoryInput {
        peer_id: Some(input_peer_for_chat(request.chat_id)),
        offset_id: request.before_message_id.map(InlineId::get),
        limit: Some(fetch_limit),
        mode: None,
        anchor_id: None,
        before_id: None,
        after_id: None,
        before_limit: None,
        after_limit: None,
        include_anchor: None,
    }
}

fn chat_id_from_peer(peer: &proto::Peer) -> Option<InlineId> {
    match &peer.r#type {
        Some(proto::peer::Type::Chat(chat)) => Some(InlineId::new(chat.chat_id)),
        Some(proto::peer::Type::User(user)) => Some(InlineId::new(user.user_id)),
        None => None,
    }
}

fn chat_id_for_peer(peer: PeerRef) -> InlineId {
    match peer {
        PeerRef::User { user_id } => user_id,
        PeerRef::Chat { chat_id } => chat_id,
        PeerRef::Thread { thread_id } => thread_id,
    }
}

fn transaction_id_for_send(request: &SendTextRequest, random_id: RandomId) -> TransactionId {
    let stable = request
        .external_id
        .as_ref()
        .map(|external| stable_hash(&format!("{}:{}", external.source(), external.id())))
        .unwrap_or_else(|| random_id.get() as u64);
    TransactionId::try_new(format!("sdk-send-{stable:016x}"))
        .expect("generated transaction ID should be valid")
}

fn random_id_for_request(request: &SendTextRequest) -> RandomId {
    let seed = request
        .external_id
        .as_ref()
        .map(|external| format!("{}:{}:{}", external.source(), external.id(), request.text))
        .unwrap_or_else(|| format!("{}:{}", now_seconds(), request.text));
    RandomId::new((stable_hash(&seed) & 0x7fff_ffff_ffff_ffff) as i64)
}

fn transaction_id_for_upload(request: &UploadRequest, random_id: RandomId) -> TransactionId {
    let stable = request
        .external_id
        .as_ref()
        .map(|external| stable_hash(&format!("{}:{}", external.source(), external.id())))
        .unwrap_or_else(|| random_id.get() as u64);
    TransactionId::try_new(format!("sdk-upload-{stable:016x}"))
        .expect("generated transaction ID should be valid")
}

fn random_id_for_upload_request(request: &UploadRequest, size_bytes: usize) -> RandomId {
    let seed = request
        .external_id
        .as_ref()
        .map(|external| {
            format!(
                "{}:{}:{}",
                external.source(),
                external.id(),
                request.caption.as_deref().unwrap_or_default()
            )
        })
        .unwrap_or_else(|| {
            format!(
                "{}:{}:{}:{}",
                now_seconds(),
                request.file_name.as_deref().unwrap_or_default(),
                request.caption.as_deref().unwrap_or_default(),
                size_bytes
            )
        });
    RandomId::new((stable_hash(&seed) & 0x7fff_ffff_ffff_ffff) as i64)
}

fn upload_input_for_request(request: &UploadRequest, bytes: Vec<u8>) -> UploadFileBytesInput {
    let file_name = request
        .file_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| default_upload_file_name(request));
    let file_type = upload_file_type_for_request(request);
    let mut input = UploadFileBytesInput::new(bytes, file_name, file_type);
    if let Some(mime_type) = request
        .mime_type
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        input = input.with_mime_type(mime_type);
    }
    if file_type == UploadFileType::Video
        && let Some(metadata) = upload_video_metadata_for_request(request)
    {
        input = input.with_video_metadata(metadata);
    }
    input
}

fn upload_file_type_for_request(request: &UploadRequest) -> UploadFileType {
    match request.kind {
        MediaKind::Photo => UploadFileType::Photo,
        MediaKind::Video if upload_video_metadata_for_request(request).is_some() => {
            UploadFileType::Video
        }
        MediaKind::Video | MediaKind::Document | MediaKind::Voice => UploadFileType::Document,
    }
}

fn upload_video_metadata_for_request(request: &UploadRequest) -> Option<UploadVideoMetadata> {
    let width = i32::try_from(request.width?)
        .ok()
        .filter(|value| *value > 0)?;
    let height = i32::try_from(request.height?)
        .ok()
        .filter(|value| *value > 0)?;
    let duration = duration_ms_to_seconds_i32(request.duration_ms?)?;
    Some(UploadVideoMetadata::new(width, height, duration))
}

fn duration_ms_to_seconds_i32(duration_ms: u64) -> Option<i32> {
    if duration_ms == 0 {
        return None;
    }
    let seconds = duration_ms.saturating_add(999) / 1_000;
    i32::try_from(seconds).ok().filter(|value| *value > 0)
}

fn default_upload_file_name(request: &UploadRequest) -> String {
    let extension = match request.kind {
        MediaKind::Photo => extension_for_mime(request.mime_type.as_deref(), "jpg"),
        MediaKind::Video => extension_for_mime(request.mime_type.as_deref(), "mp4"),
        MediaKind::Voice => extension_for_mime(request.mime_type.as_deref(), "ogg"),
        MediaKind::Document => "bin",
    };
    format!("inline-upload.{}", extension.trim_start_matches('.'))
}

fn extension_for_mime(mime_type: Option<&str>, fallback: &'static str) -> &'static str {
    match mime_type
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "video/webm" => "webm",
        "audio/mpeg" => "mp3",
        "audio/mp4" | "audio/aac" => "m4a",
        _ => fallback,
    }
}

fn input_media_from_upload(upload: &UploadFileResult) -> BackendResult<proto::InputMedia> {
    if let Some(photo_id) = upload.photo_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Photo(proto::InputMediaPhoto {
                photo_id,
            })),
        });
    }
    if let Some(video_id) = upload.video_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Video(proto::InputMediaVideo {
                video_id,
            })),
        });
    }
    if let Some(document_id) = upload.document_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Document(
                proto::InputMediaDocument { document_id },
            )),
        });
    }
    Err(BackendError::new(
        ClientErrorCategory::ProtocolMismatch,
        "uploadFile response did not include a media id",
    ))
}

fn stable_hash(value: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[derive(Debug)]
struct AppliedSendMessage {
    transaction: StoredTransaction,
    message: Option<MessageRecord>,
    chat_id: InlineId,
    message_id: Option<InlineId>,
}

fn apply_send_message_updates(
    request: &SendTextRequest,
    identity: TransactionIdentity,
    fallback_chat_id: InlineId,
    result: proto::SendMessageResult,
) -> AppliedSendMessage {
    let mut final_message: Option<proto::Message> = None;
    let mut final_message_id: Option<InlineId> = None;
    for update in result.updates {
        match update.update {
            Some(proto::update::Update::NewMessage(update)) => {
                if let Some(message) = update.message {
                    final_message_id = Some(InlineId::new(message.id));
                    final_message = Some(message);
                }
            }
            Some(proto::update::Update::UpdateMessageId(update))
                if update.random_id == identity.random_id.get() =>
            {
                final_message_id = Some(InlineId::new(update.message_id));
            }
            _ => {}
        }
    }

    let state = if final_message_id.is_some() {
        TransactionState::Completed
    } else {
        TransactionState::Acked
    };
    let mut identity = identity;
    if let Some(message_id) = final_message_id {
        identity = identity.with_final_message_id(message_id);
    }
    let message =
        final_message.map(|message| message_record_from_proto(message, request, identity.clone()));
    let chat_id = message
        .as_ref()
        .map(|message| message.chat_id)
        .unwrap_or(fallback_chat_id);
    let mut transaction = StoredTransaction::new(identity, state).with_chat_id(chat_id);
    if let Some(message_id) = final_message_id {
        transaction = transaction.with_message_id(message_id);
    }

    AppliedSendMessage {
        transaction,
        message,
        chat_id,
        message_id: final_message_id,
    }
}

fn apply_upload_message_updates(
    request: &UploadRequest,
    identity: TransactionIdentity,
    fallback_chat_id: InlineId,
    result: proto::SendMessageResult,
) -> AppliedSendMessage {
    let mut final_message: Option<proto::Message> = None;
    let mut final_message_id: Option<InlineId> = None;
    for update in result.updates {
        match update.update {
            Some(proto::update::Update::NewMessage(update)) => {
                if let Some(message) = update.message {
                    final_message_id = Some(InlineId::new(message.id));
                    final_message = Some(message);
                }
            }
            Some(proto::update::Update::UpdateMessageId(update))
                if update.random_id == identity.random_id.get() =>
            {
                final_message_id = Some(InlineId::new(update.message_id));
            }
            _ => {}
        }
    }

    let state = if final_message_id.is_some() {
        TransactionState::Completed
    } else {
        TransactionState::Acked
    };
    let mut identity = identity;
    if let Some(message_id) = final_message_id {
        identity = identity.with_final_message_id(message_id);
    }
    let message = final_message.map(|message| {
        message_record_from_proto_message(
            message,
            Some(chat_id_for_peer(request.peer)),
            Some(identity.clone()),
        )
    });
    let chat_id = message
        .as_ref()
        .map(|message| message.chat_id)
        .unwrap_or(fallback_chat_id);
    let mut transaction = StoredTransaction::new(identity, state).with_chat_id(chat_id);
    if let Some(message_id) = final_message_id {
        transaction = transaction.with_message_id(message_id);
    }

    AppliedSendMessage {
        transaction,
        message,
        chat_id,
        message_id: final_message_id,
    }
}

fn message_record_from_proto(
    message: proto::Message,
    request: &SendTextRequest,
    transaction: TransactionIdentity,
) -> MessageRecord {
    message_record_from_proto_message(
        message,
        Some(chat_id_for_peer(request.peer)),
        Some(transaction),
    )
}

fn message_record_from_proto_message(
    message: proto::Message,
    fallback_chat_id: Option<InlineId>,
    transaction: Option<TransactionIdentity>,
) -> MessageRecord {
    let chat_id = if message.chat_id != 0 {
        InlineId::new(message.chat_id)
    } else if let Some(peer) = &message.peer_id {
        chat_id_from_peer(peer).unwrap_or_else(|| fallback_chat_id.unwrap_or(InlineId::new(0)))
    } else {
        fallback_chat_id.unwrap_or(InlineId::new(0))
    };
    let content = content_from_proto_message(&message);
    MessageRecord {
        chat_id,
        message_id: InlineId::new(message.id),
        sender_id: InlineId::new(message.from_id),
        timestamp: message.date,
        is_outgoing: message.out,
        content,
        reply_to_message_id: message.reply_to_msg_id.map(InlineId::new),
        transaction,
    }
}

fn content_from_proto_message(message: &proto::Message) -> MessageContent {
    match &message.media {
        None => match &message.message {
            Some(text) => MessageContent::Text { text: text.clone() },
            None => MessageContent::Unsupported {
                reason: "empty message content".to_owned(),
            },
        },
        Some(media) => media_content_from_proto(media, message.message.clone()),
    }
}

fn media_content_from_proto(
    media: &proto::MessageMedia,
    caption: Option<String>,
) -> MessageContent {
    match &media.media {
        Some(proto::message_media::Media::Photo(photo)) => {
            if let Some(photo) = &photo.photo {
                let (url, size_bytes, width, height) = best_photo_size(photo);
                MessageContent::Media {
                    kind: MediaKind::Photo,
                    file_id: photo.id.to_string(),
                    url,
                    mime_type: photo_mime_type(photo),
                    file_name: None,
                    caption,
                    size_bytes,
                    width,
                    height,
                    duration_ms: None,
                }
            } else {
                empty_media_content(MediaKind::Photo, caption)
            }
        }
        Some(proto::message_media::Media::Video(video)) => {
            if let Some(video) = &video.video {
                MessageContent::Media {
                    kind: MediaKind::Video,
                    file_id: video.id.to_string(),
                    url: video.cdn_url.clone(),
                    mime_type: Some("video/mp4".to_owned()),
                    file_name: None,
                    caption,
                    size_bytes: positive_u64(video.size),
                    width: positive_u32(video.w),
                    height: positive_u32(video.h),
                    duration_ms: seconds_to_milliseconds(video.duration),
                }
            } else {
                empty_media_content(MediaKind::Video, caption)
            }
        }
        Some(proto::message_media::Media::Document(document)) => {
            if let Some(document) = &document.document {
                MessageContent::Media {
                    kind: MediaKind::Document,
                    file_id: document.id.to_string(),
                    url: document.cdn_url.clone(),
                    mime_type: non_empty_string(&document.mime_type),
                    file_name: non_empty_string(&document.file_name),
                    caption,
                    size_bytes: positive_u64(document.size),
                    width: None,
                    height: None,
                    duration_ms: None,
                }
            } else {
                empty_media_content(MediaKind::Document, caption)
            }
        }
        Some(proto::message_media::Media::Voice(voice)) => {
            if let Some(voice) = &voice.voice {
                MessageContent::Media {
                    kind: MediaKind::Voice,
                    file_id: voice.id.to_string(),
                    url: voice.cdn_url.clone(),
                    mime_type: non_empty_string(&voice.mime_type),
                    file_name: None,
                    caption,
                    size_bytes: positive_u64(voice.size),
                    width: None,
                    height: None,
                    duration_ms: seconds_to_milliseconds(voice.duration),
                }
            } else {
                empty_media_content(MediaKind::Voice, caption)
            }
        }
        Some(proto::message_media::Media::Nudge(_)) => MessageContent::Unsupported {
            reason: "nudge messages are not supported by inline-client yet".to_owned(),
        },
        None => MessageContent::Unsupported {
            reason: "empty media message".to_owned(),
        },
    }
}

fn empty_media_content(kind: MediaKind, caption: Option<String>) -> MessageContent {
    MessageContent::Media {
        kind,
        file_id: String::new(),
        url: None,
        mime_type: None,
        file_name: None,
        caption,
        size_bytes: None,
        width: None,
        height: None,
        duration_ms: None,
    }
}

fn best_photo_size(
    photo: &proto::Photo,
) -> (Option<String>, Option<u64>, Option<u32>, Option<u32>) {
    let mut best: Option<(&proto::PhotoSize, i64)> = None;
    for size in &photo.sizes {
        if size.cdn_url.is_none() {
            continue;
        }
        let area = i64::from(size.w) * i64::from(size.h);
        if best.is_none_or(|(_, best_area)| area > best_area) {
            best = Some((size, area));
        }
    }
    if let Some((size, _)) = best {
        return (
            size.cdn_url.clone(),
            positive_u64(size.size),
            positive_u32(size.w),
            positive_u32(size.h),
        );
    }
    (None, None, None, None)
}

fn photo_mime_type(photo: &proto::Photo) -> Option<String> {
    match photo.format {
        1 => Some("image/jpeg".to_owned()),
        2 => Some("image/png".to_owned()),
        _ => None,
    }
}

fn positive_u64(value: i32) -> Option<u64> {
    u64::try_from(value).ok().filter(|value| *value > 0)
}

fn positive_u32(value: i32) -> Option<u32> {
    u32::try_from(value).ok().filter(|value| *value > 0)
}

fn seconds_to_milliseconds(seconds: i32) -> Option<u64> {
    positive_u64(seconds).map(|seconds| seconds.saturating_mul(1_000))
}

fn non_empty_string(value: &str) -> Option<String> {
    (!value.is_empty()).then(|| value.to_owned())
}

fn outcome_from_stored_transaction(
    transaction: StoredTransaction,
    fallback_chat_id: InlineId,
) -> SendTextOutcome {
    let message_id = transaction
        .message_id
        .or(transaction.identity.final_message_id);
    SendTextOutcome::with_state(
        MessageMutation {
            transaction: transaction.identity.clone(),
            message_id,
        },
        transaction.chat_id.unwrap_or(fallback_chat_id),
        message_id,
        None,
        transaction.state,
        transaction.failure,
    )
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or_default()
}

fn redacted_url_for_debug(url: &str) -> String {
    let without_fragment = url.split('#').next().unwrap_or(url);
    let without_query = without_fragment
        .split('?')
        .next()
        .unwrap_or(without_fragment);
    match without_query.split_once("://") {
        Some((scheme, rest)) => {
            let host_and_path = rest.rsplit_once('@').map_or(rest, |(_, tail)| tail);
            format!("{scheme}://{host_and_path}")
        }
        None => without_query.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        AuthCredential, AuthToken, ClientBackend, DialogRecord, DialogsRequest, ExternalId,
        FakeRealtimeConnector, HistoryRequest, InlineId, RandomId, SendTextRequest,
        StoredTransaction,
    };

    use super::*;

    fn connect_request() -> ConnectRequest {
        ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new("secret-token").unwrap(),
        })
        .with_account_namespace("team")
    }

    #[test]
    fn sdk_backend_debug_redacts_realtime_url_credentials() {
        let backend = SdkBackend::builder()
            .realtime_url("wss://user:secret@api.inline.chat/realtime?token=secret#frag")
            .build()
            .unwrap();

        let rendered = format!("{backend:?}");
        assert!(rendered.contains("wss://api.inline.chat/realtime"));
        assert!(!rendered.contains("secret"));
        assert!(!rendered.contains("token="));
    }

    #[test]
    fn sdk_backend_defaults_use_production_endpoints() {
        let backend = SdkBackend::builder().build().unwrap();

        assert_eq!(
            backend.api_client().base_url(),
            "https://api.inline.chat/v1"
        );
        assert_eq!(backend.realtime_url(), "wss://api.inline.chat/realtime");
    }

    #[tokio::test]
    async fn sdk_backend_connect_persists_session() {
        let store = InMemoryStore::new();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();

        let status = backend.connect(connect_request()).await.unwrap();

        assert_eq!(status.status, crate::ClientStatus::Connected);
        let session = store.load_session().await.unwrap().unwrap();
        assert_eq!(session.account_namespace.as_deref(), Some("team"));
        let rendered = format!("{session:?}");
        assert!(!rendered.contains("secret-token"));
    }

    #[tokio::test]
    async fn sdk_backend_connect_can_perform_realtime_handshake() {
        let store = InMemoryStore::new();
        let realtime = FakeRealtimeConnector::new();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_connector(realtime.clone())
            .realtime_url("wss://api.inline.chat/realtime")
            .build()
            .unwrap();

        assert!(backend.realtime_handshake_enabled());
        backend.connect(connect_request()).await.unwrap();

        let attempts = realtime.attempts();
        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].realtime_url, "wss://api.inline.chat/realtime");
        assert!(store.load_session().await.unwrap().is_some());
    }

    #[tokio::test]
    async fn sdk_backend_does_not_persist_session_when_realtime_handshake_fails() {
        let store = InMemoryStore::new();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_connector(FakeRealtimeConnector::failing(BackendError::new(
                ClientErrorCategory::Network,
                "offline",
            )))
            .build()
            .unwrap();

        let err = backend.connect(connect_request()).await.unwrap_err();

        assert_eq!(err.category, ClientErrorCategory::Network);
        assert!(store.load_session().await.unwrap().is_none());
    }

    #[tokio::test]
    async fn sdk_backend_resume_without_session_reports_auth_required() {
        let backend = SdkBackend::builder().build().unwrap();

        let status = backend.resume_session().await.unwrap();

        assert_eq!(status.status, crate::ClientStatus::AuthRequired);
    }

    #[tokio::test]
    async fn sdk_backend_resume_uses_stored_session() {
        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        let realtime = FakeRealtimeConnector::new();
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_connector(realtime.clone())
            .realtime_url("wss://api.inline.chat/realtime")
            .build()
            .unwrap();

        let status = backend.resume_session().await.unwrap();

        assert_eq!(status.status, crate::ClientStatus::Connected);
        let attempts = realtime.attempts();
        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0].realtime_url, "wss://api.inline.chat/realtime");
    }

    #[tokio::test]
    async fn sdk_backend_reads_dialogs_from_store_after_connect() {
        let store = InMemoryStore::new();
        store.upsert_dialog(DialogRecord {
            chat_id: InlineId::new(9),
            peer_user_id: Some(InlineId::new(10)),
            title: Some("general".to_owned()),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
        });
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_url("not-a-websocket-url")
            .build()
            .unwrap();

        backend.connect(connect_request()).await.unwrap();
        let dialogs = backend.dialogs(DialogsRequest::default()).await.unwrap();

        assert_eq!(dialogs.dialogs.len(), 1);
        assert_eq!(dialogs.dialogs[0].chat_id, InlineId::new(9));
    }

    #[test]
    fn dialogs_page_from_get_chats_uses_user_records() {
        let result = proto::GetChatsResult {
            dialogs: vec![proto::Dialog {
                peer: Some(proto::Peer {
                    r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 42 })),
                }),
                chat_id: Some(7),
                unread_count: Some(3),
                ..Default::default()
            }],
            chats: vec![proto::Chat {
                id: 7,
                title: "Direct chat fallback".to_owned(),
                last_msg_id: Some(99),
                emoji: Some("*".to_owned()),
                peer_id: Some(proto::Peer {
                    r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 42 })),
                }),
                ..Default::default()
            }],
            users: vec![proto::User {
                id: 42,
                first_name: Some("Ada".to_owned()),
                last_name: Some("Lovelace".to_owned()),
                username: Some("ada".to_owned()),
                profile_photo: Some(proto::UserProfilePhoto {
                    cdn_url: Some("https://cdn.inline.test/ada.jpg".to_owned()),
                    ..Default::default()
                }),
                bot: Some(false),
                ..Default::default()
            }],
            ..Default::default()
        };

        let page = dialogs_page_from_get_chats(
            &result,
            DialogsRequest {
                limit: Some(10),
                cursor: None,
            },
        )
        .unwrap();

        assert_eq!(page.dialogs.len(), 1);
        assert_eq!(page.dialogs[0].chat_id, InlineId::new(7));
        assert_eq!(page.dialogs[0].title.as_deref(), Some("* Ada Lovelace"));
        assert_eq!(page.dialogs[0].peer_user_id, Some(InlineId::new(42)));
        assert_eq!(page.dialogs[0].last_message_id, Some(InlineId::new(99)));
        assert_eq!(page.dialogs[0].unread_count, Some(3));
        assert_eq!(page.users.len(), 1);
        assert_eq!(page.users[0].user_id, InlineId::new(42));
        assert_eq!(page.users[0].display_name.as_deref(), Some("Ada Lovelace"));
        assert_eq!(
            page.users[0].avatar_url.as_deref(),
            Some("https://cdn.inline.test/ada.jpg")
        );
        assert_eq!(page.users[0].is_bot, Some(false));
    }

    #[test]
    fn chat_participants_page_uses_direct_participants() {
        let page = chat_participants_page_from_proto(proto::GetChatParticipantsResult {
            participants: vec![proto::ChatParticipant {
                user_id: 10,
                date: 100,
            }],
            users: vec![proto::User {
                id: 10,
                first_name: Some("Ada".to_owned()),
                ..Default::default()
            }],
        });

        assert_eq!(page.participants.len(), 1);
        assert_eq!(page.participants[0].user_id, InlineId::new(10));
        assert_eq!(page.participants[0].date, Some(100));
        assert_eq!(page.users.len(), 1);
    }

    #[tokio::test]
    async fn sdk_backend_requires_session_for_history() {
        let backend = SdkBackend::builder().build().unwrap();

        let err = backend
            .history(HistoryRequest {
                chat_id: InlineId::new(1),
                limit: Some(10),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .expect_err("history should require connect");

        assert_eq!(err.category, ClientErrorCategory::AuthRequired);
    }

    #[tokio::test]
    async fn sdk_backend_send_text_requires_session() {
        let backend = SdkBackend::builder().build().unwrap();

        let err = backend
            .send_text(SendTextRequest::new(
                crate::PeerRef::Chat {
                    chat_id: InlineId::new(1),
                },
                "hello",
            ))
            .await
            .expect_err("send_text should require connect");

        assert_eq!(err.category, ClientErrorCategory::AuthRequired);
    }

    #[tokio::test]
    async fn sdk_backend_send_text_rejects_empty_text_before_network() {
        let backend = SdkBackend::builder().build().unwrap();

        let err = backend
            .send_text(SendTextRequest::new(
                crate::PeerRef::Chat {
                    chat_id: InlineId::new(1),
                },
                " ",
            ))
            .await
            .expect_err("empty message should fail before auth or network");

        assert_eq!(err.category, ClientErrorCategory::InvalidInput);
    }

    #[tokio::test]
    async fn sdk_backend_send_text_returns_existing_transaction_without_network() {
        let store = InMemoryStore::new();
        let request = SendTextRequest {
            peer: crate::PeerRef::Chat {
                chat_id: InlineId::new(7),
            },
            text: "hello".to_owned(),
            external_id: Some(ExternalId::try_new("host-event", "event-1").unwrap()),
            random_id: Some(RandomId::new(99)),
            reply_to_message_id: None,
        };
        let transaction_id = transaction_id_for_send(&request, request.random_id.unwrap());
        let identity = TransactionIdentity::new(
            transaction_id.clone(),
            request.external_id.clone(),
            request.random_id.unwrap(),
        )
        .with_final_message_id(InlineId::new(11));
        store.save_session(connect_session()).await.unwrap();
        store
            .record_transaction(
                StoredTransaction::new(identity, TransactionState::Completed)
                    .with_chat_id(InlineId::new(7))
                    .with_message_id(InlineId::new(11)),
            )
            .await
            .unwrap();
        let backend = SdkBackend::builder().store(store).build().unwrap();

        let outcome = backend.send_text(request).await.unwrap();

        assert_eq!(outcome.message_id, Some(InlineId::new(11)));
        assert_eq!(outcome.state, TransactionState::Completed);
        assert_eq!(outcome.mutation.transaction.transaction_id, transaction_id);
    }

    #[test]
    fn media_content_from_proto_preserves_document_descriptor() {
        let content = media_content_from_proto(
            &proto::MessageMedia {
                media: Some(proto::message_media::Media::Document(
                    proto::MessageDocument {
                        document: Some(proto::Document {
                            id: 55,
                            file_name: "report.pdf".to_owned(),
                            mime_type: "application/pdf".to_owned(),
                            size: 12_345,
                            cdn_url: Some("https://cdn.inline.test/report.pdf".to_owned()),
                            ..Default::default()
                        }),
                    },
                )),
            },
            Some("quarterly report".to_owned()),
        );

        match content {
            MessageContent::Media {
                kind,
                file_id,
                url,
                mime_type,
                file_name,
                caption,
                size_bytes,
                width,
                height,
                duration_ms,
            } => {
                assert_eq!(kind, MediaKind::Document);
                assert_eq!(file_id, "55");
                assert_eq!(url.as_deref(), Some("https://cdn.inline.test/report.pdf"));
                assert_eq!(mime_type.as_deref(), Some("application/pdf"));
                assert_eq!(file_name.as_deref(), Some("report.pdf"));
                assert_eq!(caption.as_deref(), Some("quarterly report"));
                assert_eq!(size_bytes, Some(12_345));
                assert_eq!(width, None);
                assert_eq!(height, None);
                assert_eq!(duration_ms, None);
            }
            other => panic!("expected media content, got {other:?}"),
        }
    }

    #[test]
    fn media_content_from_proto_picks_largest_photo_descriptor() {
        let content = media_content_from_proto(
            &proto::MessageMedia {
                media: Some(proto::message_media::Media::Photo(proto::MessagePhoto {
                    photo: Some(proto::Photo {
                        id: 9,
                        format: 2,
                        sizes: vec![
                            proto::PhotoSize {
                                w: 20,
                                h: 20,
                                size: 100,
                                cdn_url: Some("https://cdn.inline.test/small.png".to_owned()),
                                ..Default::default()
                            },
                            proto::PhotoSize {
                                w: 200,
                                h: 200,
                                size: 500,
                                cdn_url: None,
                                ..Default::default()
                            },
                            proto::PhotoSize {
                                w: 50,
                                h: 50,
                                size: 200,
                                cdn_url: Some("https://cdn.inline.test/large.png".to_owned()),
                                ..Default::default()
                            },
                        ],
                        ..Default::default()
                    }),
                })),
            },
            None,
        );

        match content {
            MessageContent::Media {
                kind,
                file_id,
                url,
                mime_type,
                size_bytes,
                width,
                height,
                ..
            } => {
                assert_eq!(kind, MediaKind::Photo);
                assert_eq!(file_id, "9");
                assert_eq!(url.as_deref(), Some("https://cdn.inline.test/large.png"));
                assert_eq!(mime_type.as_deref(), Some("image/png"));
                assert_eq!(size_bytes, Some(200));
                assert_eq!(width, Some(50));
                assert_eq!(height, Some(50));
            }
            other => panic!("expected media content, got {other:?}"),
        }
    }

    #[test]
    fn upload_input_for_video_without_complete_metadata_falls_back_to_document() {
        let request = UploadRequest {
            peer: crate::PeerRef::Chat {
                chat_id: InlineId::new(7),
            },
            kind: MediaKind::Video,
            file_name: Some("clip.mp4".to_owned()),
            mime_type: Some("video/mp4".to_owned()),
            size_bytes: Some(4),
            caption: None,
            width: Some(640),
            height: None,
            duration_ms: Some(1_500),
            external_id: None,
            random_id: None,
            reply_to_message_id: None,
        };

        let input = upload_input_for_request(&request, vec![1, 2, 3, 4]);

        assert_eq!(input.file_type, UploadFileType::Document);
        assert_eq!(input.file_name, "clip.mp4");
        assert_eq!(input.mime_type.as_deref(), Some("video/mp4"));
        assert_eq!(input.video_metadata, None);
    }

    #[test]
    fn upload_input_for_video_with_complete_metadata_uses_video() {
        let request = UploadRequest {
            peer: crate::PeerRef::Chat {
                chat_id: InlineId::new(7),
            },
            kind: MediaKind::Video,
            file_name: Some("clip.mp4".to_owned()),
            mime_type: Some("video/mp4".to_owned()),
            size_bytes: Some(4),
            caption: None,
            width: Some(640),
            height: Some(480),
            duration_ms: Some(1_500),
            external_id: None,
            random_id: None,
            reply_to_message_id: None,
        };

        let input = upload_input_for_request(&request, vec![1, 2, 3, 4]);

        assert_eq!(input.file_type, UploadFileType::Video);
        assert_eq!(
            input.video_metadata,
            Some(UploadVideoMetadata::new(640, 480, 2))
        );
    }

    #[test]
    fn history_input_for_after_message_id_uses_newer_mode() {
        let input = history_input_for_request(
            &HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(20),
                before_message_id: None,
                after_message_id: Some(InlineId::new(10)),
            },
            21,
        );

        assert_eq!(input.after_id, Some(10));
        assert_eq!(
            input.mode,
            Some(proto::GetChatHistoryMode::HistoryModeNewer as i32)
        );
        assert_eq!(input.offset_id, None);
        assert_eq!(input.limit, Some(21));
    }

    #[test]
    fn apply_send_message_updates_extracts_final_message() {
        let request = SendTextRequest {
            peer: crate::PeerRef::Chat {
                chat_id: InlineId::new(7),
            },
            text: "hello".to_owned(),
            external_id: Some(ExternalId::try_new("host-event", "event-1").unwrap()),
            random_id: Some(RandomId::new(99)),
            reply_to_message_id: None,
        };
        let identity = TransactionIdentity::new(
            TransactionId::try_new("txn").unwrap(),
            request.external_id.clone(),
            request.random_id.unwrap(),
        );
        let result = proto::SendMessageResult {
            updates: vec![proto::Update {
                seq: Some(1),
                date: Some(1),
                update: Some(proto::update::Update::NewMessage(proto::UpdateNewMessage {
                    message: Some(proto::Message {
                        id: 11,
                        from_id: 2,
                        peer_id: None,
                        chat_id: 7,
                        message: Some("hello".to_owned()),
                        out: true,
                        date: 123,
                        mentioned: None,
                        reply_to_msg_id: None,
                        media: None,
                        edit_date: None,
                        grouped_id: None,
                        attachments: None,
                        reactions: None,
                        is_sticker: None,
                        has_link: None,
                        entities: None,
                        send_mode: None,
                        fwd_from: None,
                        replies: None,
                        actions: None,
                        rev: None,
                    }),
                })),
            }],
        };

        let applied = apply_send_message_updates(&request, identity, InlineId::new(7), result);

        assert_eq!(applied.message_id, Some(InlineId::new(11)));
        assert_eq!(applied.transaction.state, TransactionState::Completed);
        assert_eq!(applied.message.unwrap().message_id, InlineId::new(11));
    }

    fn connect_session() -> StoredSession {
        StoredSession {
            auth: AuthCredential::AccessToken {
                token: AuthToken::try_new("secret-token").unwrap(),
            },
            account_namespace: Some("team".to_owned()),
        }
    }
}

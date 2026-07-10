//! SDK-backed production backend.
//!
//! This backend owns the configured `inline-sdk` clients, durable store,
//! multiplexed realtime session, bucket sync, and transaction state behind the
//! native client API.

use std::{
    collections::{HashMap, HashSet},
    fmt,
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

use futures_util::future::BoxFuture;
use inline_sdk::{
    ApiClient, ApiError, AuthMetadata, ClientIdentity, RealtimeError, RealtimeEvent,
    RealtimeEventReceiver, RealtimeSession, RpcRequest, UploadFileBytesInput, UploadFileResult,
    UploadFileType, UploadVideoMetadata, proto,
};
use serde_json::Value;
use tokio::sync::{Mutex, Notify};

use crate::backend::retry_after_seconds_from_message;
use crate::sync::{SyncHost, SyncManager};
use crate::{
    AccountStateSnapshot, AddChatParticipantRequest, AuthContactKind, AuthCredential,
    AuthStartRequest, AuthStartResult, AuthToken, AuthVerifyRequest, AuthVerifyResult,
    BackendError, BackendResult, ChatCreateParticipant, ChatParticipantRecord,
    ChatParticipantsPage, ChatParticipantsRequest, ChatStateSnapshot, ClientBackend,
    ClientErrorCategory, ClientEvent, ClientEventDelivery, ClientStatusSnapshot, ClientStore,
    ConnectRequest, CreateDmRequest, CreateReplyThreadRequest, CreateThreadRequest, CreatedChat,
    DeleteChatRequest, DeleteMessageRequest, DialogFollowMode, DialogNotificationMode,
    DialogRecord, DialogsOrder, DialogsPage, DialogsRequest, EditMessageRequest, HistoryPage,
    HistoryRequest, InMemoryStore, InlineId, MediaKind, MessageContent, MessageMutation,
    MessageRecord, NotificationMode, OperationOutcome, PeerRef, RandomId, ReactRequest,
    ReadRequest, RealtimeConnectRequest, RealtimeConnector, RemoveChatParticipantRequest,
    SendTextOutcome, SendTextRequest, SetMarkedUnreadRequest, SpaceMemberRecord, SpaceMemberRole,
    SpaceRecord, StoreError, StoredReaction, StoredReadState, StoredSession, StoredTransaction,
    SyncConfig, TransactionId, TransactionIdentity, TransactionState, TypingRequest,
    UpdateChatInfoRequest, UpdateDialogNotificationsRequest, UploadRequest, UserRecord,
    UserSettingsRecord, VERSION,
};

const DEFAULT_API_BASE_URL: &str = "https://api.inline.chat/v1";
const DEFAULT_REALTIME_URL: &str = "wss://api.inline.chat/realtime";
const CHAT_REPAIR_HISTORY_LIMIT: i32 = 50;

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
    sync_config: SyncConfig,
    realtime_handshake: bool,
    realtime_connector: Option<Arc<dyn RealtimeConnector>>,
}

impl fmt::Debug for SdkBackendBuilder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SdkBackendBuilder")
            .field("api_base_url", &self.api_base_url)
            .field("realtime_url", &redacted_url_for_debug(&self.realtime_url))
            .field("identity", &self.identity)
            .field("store", &"<client-store>")
            .field("sync_config", &self.sync_config)
            .field("realtime_handshake", &self.realtime_handshake)
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
            sync_config: SyncConfig::default(),
            realtime_handshake: false,
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

    /// Sets Inline update discovery and bucket catch-up policy.
    pub fn sync_config(mut self, config: SyncConfig) -> Self {
        self.sync_config = config;
        self
    }

    /// Enables realtime handshake using the SDK realtime connector.
    pub fn enable_realtime_handshake(mut self) -> Self {
        self.realtime_handshake = true;
        self.realtime_connector = None;
        self
    }

    /// Sets a custom realtime connector.
    pub fn realtime_connector(mut self, connector: impl RealtimeConnector) -> Self {
        self.realtime_handshake = true;
        self.realtime_connector = Some(Arc::new(connector));
        self
    }

    /// Sets a shared realtime connector.
    pub fn shared_realtime_connector(mut self, connector: Arc<dyn RealtimeConnector>) -> Self {
        self.realtime_handshake = true;
        self.realtime_connector = Some(connector);
        self
    }

    /// Disables realtime handshake on connect.
    pub fn without_realtime_handshake(mut self) -> Self {
        self.realtime_handshake = false;
        self.realtime_connector = None;
        self
    }

    /// Builds an SDK-backed backend.
    pub fn build(self) -> Result<SdkBackend, SdkBackendBuildError> {
        let api = ApiClient::try_new_with_identity(self.api_base_url, self.identity.clone())?;
        let sync = Arc::new(SyncManager::new(self.store.clone(), self.sync_config));
        Ok(SdkBackend {
            api,
            realtime_url: self.realtime_url,
            identity: self.identity,
            store: self.store,
            sync,
            sync_required: Arc::new(AtomicBool::new(true)),
            realtime_handshake: self.realtime_handshake,
            realtime_connector: self.realtime_connector,
            realtime: Arc::new(Mutex::new(None)),
            realtime_events: Arc::new(Mutex::new(None)),
            in_flight_deliveries: Arc::new(StdMutex::new(HashSet::new())),
            client_event_notify: Arc::new(Notify::new()),
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
    sync: Arc<SyncManager>,
    sync_required: Arc<AtomicBool>,
    realtime_handshake: bool,
    realtime_connector: Option<Arc<dyn RealtimeConnector>>,
    realtime: Arc<Mutex<Option<RealtimeSession>>>,
    realtime_events: Arc<Mutex<Option<RealtimeEventReceiver>>>,
    in_flight_deliveries: Arc<StdMutex<HashSet<u64>>>,
    client_event_notify: Arc<Notify>,
}

impl fmt::Debug for SdkBackend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SdkBackend")
            .field("api", &self.api)
            .field("realtime_url", &redacted_url_for_debug(&self.realtime_url))
            .field("identity", &self.identity)
            .field("store", &"<client-store>")
            .field("sync_required", &self.sync_required.load(Ordering::Relaxed))
            .field("realtime_handshake", &self.realtime_handshake)
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
        self.realtime_handshake
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

    async fn call_realtime<R>(
        &self,
        session: &StoredSession,
        request: R,
    ) -> BackendResult<R::Response>
    where
        R: RpcRequest,
    {
        let realtime = self.ensure_realtime(session).await?;
        match realtime.call(request).await {
            Ok(response) => Ok(response),
            Err(error) => {
                if realtime_error_closes_session(&error) {
                    self.clear_realtime().await;
                }
                Err(realtime_error_to_backend(error))
            }
        }
    }

    async fn ensure_realtime(&self, session: &StoredSession) -> BackendResult<RealtimeSession> {
        let mut realtime = self.realtime.lock().await;
        if let Some(existing) = realtime.as_ref()
            && !existing.is_closed()
        {
            return Ok(existing.clone());
        }

        let connected = RealtimeSession::connect_with_identity(
            &self.realtime_url,
            session.auth.access_token().expose_secret(),
            self.identity.clone(),
        )
        .await
        .map_err(realtime_error_to_backend)?;
        let receiver = connected.subscribe();
        *self.realtime_events.lock().await = Some(receiver);
        *realtime = Some(connected.clone());
        Ok(connected)
    }

    async fn install_realtime(&self, realtime: RealtimeSession) {
        let receiver = realtime.subscribe();
        *self.realtime.lock().await = Some(realtime);
        *self.realtime_events.lock().await = Some(receiver);
    }

    async fn clear_realtime(&self) {
        *self.realtime.lock().await = None;
        *self.realtime_events.lock().await = None;
        self.sync_required.store(true, Ordering::Release);
    }

    async fn receive_realtime_event(
        &self,
        session: &StoredSession,
    ) -> BackendResult<RealtimeEvent> {
        self.ensure_realtime(session).await?;
        let mut receiver = self.realtime_events.lock().await;
        let Some(events) = receiver.as_mut() else {
            return Err(BackendError::new(
                ClientErrorCategory::Internal,
                "realtime event receiver was not initialized",
            ));
        };
        match events.recv().await {
            Ok(event) => Ok(event),
            Err(error) => {
                self.sync_required.store(true, Ordering::Release);
                drop(receiver);
                if realtime_error_closes_session(&error) {
                    self.clear_realtime().await;
                }
                Err(realtime_error_to_backend(error))
            }
        }
    }

    async fn connect_with_auth(
        &self,
        request: ConnectRequest,
    ) -> BackendResult<ClientStatusSnapshot> {
        let existing_session = self
            .store
            .load_session()
            .await
            .map_err(store_error_to_backend)?;
        let next_namespace = normalized_account_namespace(request.account_namespace.as_deref());
        let account_changed = existing_session.as_ref().is_none_or(|session| {
            normalized_account_namespace(session.account_namespace.as_deref()) != next_namespace
        });
        let connected = if self.realtime_handshake {
            if let Some(connector) = &self.realtime_connector {
                connector
                    .connect(RealtimeConnectRequest::new(
                        self.realtime_url.clone(),
                        request.auth.access_token().clone(),
                        self.identity.clone(),
                    ))
                    .await?;
                None
            } else {
                Some(
                    RealtimeSession::connect_with_identity(
                        &self.realtime_url,
                        request.auth.access_token().expose_secret(),
                        self.identity.clone(),
                    )
                    .await
                    .map_err(realtime_error_to_backend)?,
                )
            }
        } else {
            None
        };
        self.clear_realtime().await;
        if account_changed {
            self.store
                .clear_account_data()
                .await
                .map_err(store_error_to_backend)?;
            self.in_flight_deliveries
                .lock()
                .expect("client event delivery claims poisoned")
                .clear();
        }
        self.store
            .save_session(StoredSession {
                auth: request.auth,
                account_namespace: request.account_namespace,
            })
            .await
            .map_err(store_error_to_backend)?;
        if let Some(connected) = connected {
            self.install_realtime(connected).await;
        }
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
            self.clear_realtime().await;
            return Ok(ClientStatusSnapshot::current(
                crate::ClientStatus::AuthRequired,
            ));
        };

        self.clear_realtime().await;
        if self.realtime_handshake {
            if let Some(connector) = &self.realtime_connector {
                connector
                    .connect(RealtimeConnectRequest::new(
                        self.realtime_url.clone(),
                        session.auth.access_token().clone(),
                        self.identity.clone(),
                    ))
                    .await?;
            } else {
                let connected = RealtimeSession::connect_with_identity(
                    &self.realtime_url,
                    session.auth.access_token().expose_secret(),
                    self.identity.clone(),
                )
                .await
                .map_err(realtime_error_to_backend)?;
                self.install_realtime(connected).await;
            }
        }
        Ok(ClientStatusSnapshot::current(
            crate::ClientStatus::Connected,
        ))
    }

    async fn claim_pending_client_events(&self) -> BackendResult<Vec<ClientEventDelivery>> {
        let pending = self
            .store
            .pending_client_events()
            .await
            .map_err(store_error_to_backend)?;
        let mut in_flight = self
            .in_flight_deliveries
            .lock()
            .expect("client event delivery claims poisoned");
        Ok(pending
            .into_iter()
            .filter(|delivery| {
                delivery
                    .delivery_id
                    .is_none_or(|delivery_id| in_flight.insert(delivery_id))
            })
            .collect())
    }

    fn mark_deliveries_in_flight(&self, deliveries: &[ClientEventDelivery]) {
        let mut in_flight = self
            .in_flight_deliveries
            .lock()
            .expect("client event delivery claims poisoned");
        in_flight.extend(
            deliveries
                .iter()
                .filter_map(|delivery| delivery.delivery_id),
        );
    }

    async fn receive_next_event_deliveries(&self) -> BackendResult<Vec<ClientEventDelivery>> {
        let pending = self.claim_pending_client_events().await?;
        if !pending.is_empty() {
            return Ok(pending);
        }

        let session = self.require_session().await?;
        if self.sync_required.load(Ordering::Acquire) {
            let deliveries = self.sync.discover(self).await?;
            self.sync_required.store(false, Ordering::Release);
            self.mark_deliveries_in_flight(&deliveries);
            if !deliveries.is_empty() {
                return Ok(deliveries);
            }
            let pending = self.claim_pending_client_events().await?;
            if !pending.is_empty() {
                return Ok(pending);
            }
        }
        loop {
            let realtime_event = tokio::select! {
                _ = self.client_event_notify.notified() => {
                    let pending = self.claim_pending_client_events().await?;
                    if !pending.is_empty() {
                        return Ok(pending);
                    }
                    continue;
                }
                event = self.receive_realtime_event(&session) => event?,
            };
            match realtime_event {
                RealtimeEvent::Updates(updates) => {
                    let deliveries = match self.sync.process_realtime(self, updates).await {
                        Ok(deliveries) => deliveries,
                        Err(error) => {
                            self.sync_required.store(true, Ordering::Release);
                            return Err(error);
                        }
                    };
                    self.mark_deliveries_in_flight(&deliveries);
                    if !deliveries.is_empty() {
                        return Ok(deliveries);
                    }
                }
                RealtimeEvent::Ack { .. } | RealtimeEvent::Pong { .. } => {}
                _ => {}
            }
        }
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
            let session = backend
                .store
                .load_session()
                .await
                .map_err(store_error_to_backend)?;
            backend.clear_realtime().await;
            if let Some(session) = session
                && let Err(error) = backend
                    .api
                    .logout(session.auth.access_token().expose_secret())
                    .await
            {
                log::warn!("Inline remote session logout failed; clearing local session: {error}");
            }
            backend
                .store
                .clear_session()
                .await
                .map_err(store_error_to_backend)?;
            backend
                .store
                .clear_account_data()
                .await
                .map_err(store_error_to_backend)?;
            backend
                .in_flight_deliveries
                .lock()
                .expect("client event delivery claims poisoned")
                .clear();
            Ok(())
        })
    }

    fn dialogs(&self, request: DialogsRequest) -> BoxFuture<'static, BackendResult<DialogsPage>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let result = backend
                .call_realtime(&session, proto::GetChatsInput {})
                .await?;
            backend.apply_get_chats_snapshot(result).await?;
            backend
                .store
                .dialogs(request)
                .await
                .map_err(store_error_to_backend)
        })
    }

    fn cached_dialogs(
        &self,
        request: DialogsRequest,
    ) -> BoxFuture<'static, BackendResult<DialogsPage>> {
        let backend = self.clone();
        Box::pin(async move {
            backend
                .store
                .dialogs(request)
                .await
                .map_err(store_error_to_backend)
        })
    }

    fn account_state(&self) -> BoxFuture<'static, BackendResult<AccountStateSnapshot>> {
        let backend = self.clone();
        Box::pin(async move {
            let deleted_chat_ids = backend
                .store
                .deleted_chat_ids()
                .await
                .map_err(store_error_to_backend)?;
            Ok(AccountStateSnapshot { deleted_chat_ids })
        })
    }

    fn chat_state(
        &self,
        chat_id: InlineId,
    ) -> BoxFuture<'static, BackendResult<ChatStateSnapshot>> {
        let backend = self.clone();
        Box::pin(async move {
            let dialog = backend
                .store
                .dialog(chat_id)
                .await
                .map_err(store_error_to_backend)?;
            let deleted = backend
                .store
                .deleted_chat_ids()
                .await
                .map_err(store_error_to_backend)?
                .contains(&chat_id);
            let deleted_message_ids = backend
                .store
                .deleted_message_ids(chat_id)
                .await
                .map_err(store_error_to_backend)?;
            let reactions = backend
                .store
                .reactions_for_chat(chat_id)
                .await
                .map_err(store_error_to_backend)?;
            let reaction_snapshot_message_ids = backend
                .store
                .reaction_snapshot_message_ids(chat_id)
                .await
                .map_err(store_error_to_backend)?;
            let read_state = backend
                .store
                .read_state(chat_id)
                .await
                .map_err(store_error_to_backend)?;
            let participants = backend
                .store
                .chat_participants(chat_id)
                .await
                .map_err(store_error_to_backend)?;
            let participants_complete = backend
                .store
                .chat_participants_complete(chat_id)
                .await
                .map_err(store_error_to_backend)?;
            Ok(ChatStateSnapshot {
                chat_id,
                dialog,
                deleted,
                deleted_message_ids,
                reactions,
                reaction_snapshot_message_ids,
                read_state,
                participants,
                participants_complete,
            })
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
            let fetch_limit = limit.saturating_add(1).min(i32::MAX as u32) as i32;
            let result = backend
                .call_realtime(&session, history_input_for_request(&request, fetch_limit))
                .await?;
            let mut records = Vec::with_capacity(result.messages.len());
            for message in result.messages {
                records.push(
                    backend
                        .record_proto_message(message, Some(request.chat_id), None)
                        .await?,
                );
            }
            let (records, has_more) = crate::store::select_history_window(
                records,
                limit as usize,
                request.before_message_id,
                request.after_message_id,
            );
            Ok(HistoryPage {
                messages: records,
                users: Vec::new(),
                has_more,
                next_cursor: None,
            })
        })
    }

    fn cached_history(
        &self,
        request: HistoryRequest,
    ) -> BoxFuture<'static, BackendResult<HistoryPage>> {
        let backend = self.clone();
        Box::pin(async move {
            backend
                .store
                .history(request)
                .await
                .map_err(store_error_to_backend)
        })
    }

    fn chat_participants(
        &self,
        request: ChatParticipantsRequest,
    ) -> BoxFuture<'static, BackendResult<ChatParticipantsPage>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let result = backend
                .call_realtime(
                    &session,
                    proto::GetChatParticipantsInput {
                        chat_id: request.chat_id.get(),
                    },
                )
                .await?;
            let page = chat_participants_page_from_proto(result);
            backend
                .store
                .record_users(page.users.clone())
                .await
                .map_err(store_error_to_backend)?;
            backend
                .store
                .record_chat_participants(request.chat_id, page.participants.clone())
                .await
                .map_err(store_error_to_backend)?;
            Ok(page)
        })
    }

    fn add_chat_participant(
        &self,
        request: AddChatParticipantRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            validate_chat_and_user_ids(request.chat_id, request.user_id)?;
            let session = backend.require_session().await?;
            let result = backend
                .call_realtime(
                    &session,
                    proto::AddChatParticipantInput {
                        chat_id: request.chat_id.get(),
                        user_id: Some(request.user_id.get()),
                        group_id: None,
                    },
                )
                .await?;
            let participant = result.participant.ok_or_else(|| {
                BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "add chat participant result did not include the participant",
                )
            })?;
            backend
                .store
                .record_chat_participant(
                    request.chat_id,
                    ChatParticipantRecord {
                        user_id: InlineId::new(participant.user_id),
                        date: Some(participant.date),
                    },
                )
                .await
                .map_err(store_error_to_backend)?;
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
            validate_chat_and_user_ids(request.chat_id, request.user_id)?;
            let session = backend.require_session().await?;
            backend
                .call_realtime(
                    &session,
                    proto::RemoveChatParticipantInput {
                        chat_id: request.chat_id.get(),
                        user_id: Some(request.user_id.get()),
                        group_id: None,
                    },
                )
                .await?;
            backend
                .store
                .remove_chat_participant(request.chat_id, request.user_id)
                .await
                .map_err(store_error_to_backend)?;
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
            if request.chat_id.get() <= 0 {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "chat_id must be positive",
                ));
            }
            if request.title.is_none() && request.emoji.is_none() {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "at least one chat info field must be provided",
                ));
            }
            let title = request.title.map(|title| title.trim().to_owned());
            if title.as_deref().is_some_and(str::is_empty) {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "chat title must not be empty",
                ));
            }
            let emoji = request.emoji.map(|emoji| emoji.trim().to_owned());
            let session = backend.require_session().await?;
            let result = backend
                .call_realtime(
                    &session,
                    proto::UpdateChatInfoInput {
                        chat_id: request.chat_id.get(),
                        title,
                        emoji,
                    },
                )
                .await?;
            let chat = result.chat.ok_or_else(|| {
                BackendError::new(
                    ClientErrorCategory::ProtocolMismatch,
                    "update chat info result did not include the chat",
                )
            })?;
            Ok(OperationOutcome::with_events(
                backend.record_chat_update(chat, None, None).await?,
            ))
        })
    }

    fn delete_chat(
        &self,
        request: DeleteChatRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            if request.chat_id.get() <= 0 {
                return Err(BackendError::new(
                    ClientErrorCategory::InvalidInput,
                    "chat_id must be positive",
                ));
            }
            let session = backend.require_session().await?;
            backend
                .call_realtime(
                    &session,
                    proto::DeleteChatInput {
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                    },
                )
                .await?;
            backend
                .store
                .remove_dialog(request.chat_id)
                .await
                .map_err(store_error_to_backend)?;
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
                    ..DialogRecord::new(created.chat_id)
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
            let result = backend
                .call_realtime(
                    &session,
                    proto::CreateChatInput {
                        title: trimmed_option(request.title),
                        space_id: request.space_id.map(InlineId::get),
                        description: trimmed_option(request.description),
                        emoji: trimmed_option(request.emoji),
                        is_public: request.is_public,
                        participants: request
                            .participants
                            .into_iter()
                            .map(|participant| proto::InputChatParticipant {
                                user_id: Some(participant.user_id.get()),
                                group_id: None,
                            })
                            .collect(),
                        reserved_chat_id: None,
                    },
                )
                .await?;
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
                    ..DialogRecord::new(created.chat_id)
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
            let result = backend
                .call_realtime(
                    &session,
                    proto::CreateSubthreadInput {
                        parent_chat_id: request.parent_chat_id.get(),
                        parent_message_id: request.parent_message_id.map(InlineId::get),
                        title: trimmed_option(request.title),
                        description: trimmed_option(request.description),
                        emoji: trimmed_option(request.emoji),
                        participants: request
                            .participants
                            .into_iter()
                            .map(|participant| proto::InputChatParticipant {
                                user_id: Some(participant.user_id.get()),
                                group_id: None,
                            })
                            .collect(),
                    },
                )
                .await?;
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
                    ..DialogRecord::new(created.chat_id)
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
            let new_identity = TransactionIdentity::new(
                transaction_id.clone(),
                request.external_id.clone(),
                random_id,
            );
            let existing = backend
                .store
                .transaction(transaction_id.clone())
                .await
                .map_err(store_error_to_backend)?;
            if let Some(existing) = existing.as_ref()
                && !stored_transaction_needs_retry(existing)
            {
                return Ok(outcome_from_stored_transaction(
                    existing.clone(),
                    initial_chat_id,
                ));
            }
            let identity = existing
                .map(|transaction| transaction.identity)
                .unwrap_or(new_identity);

            if backend
                .store
                .transaction(transaction_id)
                .await
                .map_err(store_error_to_backend)?
                .is_none()
            {
                backend
                    .store
                    .record_transaction(
                        StoredTransaction::new(identity.clone(), TransactionState::Queued)
                            .with_chat_id(initial_chat_id),
                    )
                    .await
                    .map_err(store_error_to_backend)?;
            }

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
            let send_result = match backend.call_realtime(&session, input).await {
                Ok(result) => result,
                Err(backend_error) => {
                    backend
                        .record_transaction_error(
                            identity,
                            initial_chat_id,
                            TransactionState::Sent,
                            backend_error.clone(),
                        )
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
                    state: None,
                    failure: None,
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
            let new_identity = TransactionIdentity::new(
                transaction_id.clone(),
                request.external_id.clone(),
                random_id,
            );
            let existing = backend
                .store
                .transaction(transaction_id.clone())
                .await
                .map_err(store_error_to_backend)?;
            if let Some(existing) = existing.as_ref()
                && !stored_transaction_needs_retry(existing)
            {
                return Ok(outcome_from_stored_transaction(
                    existing.clone(),
                    initial_chat_id,
                ));
            }
            let identity = existing
                .map(|transaction| transaction.identity)
                .unwrap_or(new_identity);

            if backend
                .store
                .transaction(transaction_id)
                .await
                .map_err(store_error_to_backend)?
                .is_none()
            {
                backend
                    .store
                    .record_transaction(
                        StoredTransaction::new(identity.clone(), TransactionState::Queued)
                            .with_chat_id(initial_chat_id),
                    )
                    .await
                    .map_err(store_error_to_backend)?;
            }

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
                        .record_transaction_error(
                            identity,
                            initial_chat_id,
                            TransactionState::Queued,
                            backend_error.clone(),
                        )
                        .await?;
                    return Err(backend_error);
                }
            };
            let media = match input_media_from_upload(&upload) {
                Ok(media) => media,
                Err(error) => {
                    backend
                        .record_transaction_error(
                            identity,
                            initial_chat_id,
                            TransactionState::Failed,
                            error.clone(),
                        )
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
            let send_result = match backend.call_realtime(&session, input).await {
                Ok(result) => result,
                Err(backend_error) => {
                    backend
                        .record_transaction_error(
                            identity,
                            initial_chat_id,
                            TransactionState::Sent,
                            backend_error.clone(),
                        )
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
                    state: None,
                    failure: None,
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
            let result = backend
                .call_realtime(
                    &session,
                    proto::EditMessageInput {
                        message_id: request.message_id.get(),
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                        text: request.text,
                        entities: None,
                        parse_markdown: Some(false),
                        actions: None,
                    },
                )
                .await?;
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
            let result = backend
                .call_realtime(
                    &session,
                    proto::DeleteMessagesInput {
                        message_ids: vec![request.message_id.get()],
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                    },
                )
                .await?;
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
            let updates = if request.remove {
                backend
                    .call_realtime(
                        &session,
                        proto::DeleteReactionInput {
                            emoji: reaction.clone(),
                            peer_id: Some(input_peer_for_chat(request.chat_id)),
                            message_id: request.message_id.get(),
                        },
                    )
                    .await?
                    .updates
            } else {
                backend
                    .call_realtime(
                        &session,
                        proto::AddReactionInput {
                            emoji: reaction.clone(),
                            message_id: request.message_id.get(),
                            peer_id: Some(input_peer_for_chat(request.chat_id)),
                        },
                    )
                    .await?
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
            let result = backend
                .call_realtime(
                    &session,
                    proto::ReadMessagesInput {
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                        max_id: request.max_message_id.map(InlineId::get),
                    },
                )
                .await?;
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

    fn set_marked_unread(
        &self,
        request: SetMarkedUnreadRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let updates = if request.unread {
                backend
                    .call_realtime(
                        &session,
                        proto::MarkAsUnreadInput {
                            peer_id: Some(input_peer_for_chat(request.chat_id)),
                        },
                    )
                    .await?
                    .updates
            } else {
                backend
                    .call_realtime(
                        &session,
                        proto::ReadMessagesInput {
                            peer_id: Some(input_peer_for_chat(request.chat_id)),
                            max_id: None,
                        },
                    )
                    .await?
                    .updates
            };
            let mut events = backend
                .apply_updates(updates, Some(request.chat_id), None)
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

    fn update_dialog_notifications(
        &self,
        request: UpdateDialogNotificationsRequest,
    ) -> BoxFuture<'static, BackendResult<OperationOutcome>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            let result = backend
                .call_realtime(
                    &session,
                    proto::UpdateDialogNotificationSettingsInput {
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                        notification_settings: request.mode.map(|mode| {
                            proto::DialogNotificationSettings {
                                mode: Some(dialog_notification_mode_to_proto(mode) as i32),
                            }
                        }),
                    },
                )
                .await?;
            let mut events = backend
                .apply_updates(result.updates, Some(request.chat_id), None)
                .await?;
            backend
                .mutate_dialog(request.chat_id, |dialog| {
                    dialog.notification_mode = request.mode;
                })
                .await?;
            if !events.iter().any(|event| {
                matches!(event, ClientEvent::ChatUpserted { chat_id } if *chat_id == request.chat_id)
            }) {
                events.push(ClientEvent::ChatUpserted {
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
            backend
                .call_realtime(
                    &session,
                    proto::SendComposeActionInput {
                        peer_id: Some(input_peer_for_chat(request.chat_id)),
                        action: request
                            .is_typing
                            .then_some(proto::update_compose_action::ComposeAction::Typing as i32),
                    },
                )
                .await?;
            Ok(OperationOutcome::empty())
        })
    }

    fn receive_events(&self) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>> {
        let backend = self.clone();
        Box::pin(async move {
            let deliveries = backend.receive_next_event_deliveries().await?;
            let mut events = Vec::with_capacity(deliveries.len());
            for delivery in deliveries {
                if let Some(delivery_id) = delivery.delivery_id {
                    let acknowledgement = backend
                        .store
                        .acknowledge_client_event(delivery_id)
                        .await
                        .map_err(store_error_to_backend);
                    backend
                        .in_flight_deliveries
                        .lock()
                        .expect("client event delivery claims poisoned")
                        .remove(&delivery_id);
                    backend.client_event_notify.notify_one();
                    if let Err(error) = acknowledgement {
                        log::error!(
                            "failed to acknowledge legacy Inline client event delivery: {error}"
                        );
                    }
                }
                events.push(delivery.event);
            }
            Ok(events)
        })
    }

    fn receive_event_deliveries(
        &self,
    ) -> BoxFuture<'static, BackendResult<Vec<ClientEventDelivery>>> {
        let backend = self.clone();
        Box::pin(async move { backend.receive_next_event_deliveries().await })
    }

    fn stage_client_events(
        &self,
        events: Vec<ClientEvent>,
    ) -> BoxFuture<'static, BackendResult<Vec<ClientEventDelivery>>> {
        let backend = self.clone();
        Box::pin(async move {
            let deliveries = backend
                .store
                .append_client_events(events)
                .await
                .map_err(store_error_to_backend)?;
            backend.mark_deliveries_in_flight(&deliveries);
            Ok(deliveries)
        })
    }

    fn acknowledge_event_delivery(
        &self,
        delivery_id: u64,
    ) -> BoxFuture<'static, BackendResult<()>> {
        let backend = self.clone();
        Box::pin(async move {
            let acknowledgement = backend
                .store
                .acknowledge_client_event(delivery_id)
                .await
                .map_err(store_error_to_backend);
            backend
                .in_flight_deliveries
                .lock()
                .expect("client event delivery claims poisoned")
                .remove(&delivery_id);
            backend.client_event_notify.notify_one();
            acknowledgement
        })
    }

    fn release_event_delivery(&self, delivery_id: u64) {
        self.in_flight_deliveries
            .lock()
            .expect("client event delivery claims poisoned")
            .remove(&delivery_id);
        self.client_event_notify.notify_one();
    }

    fn reset_event_delivery_claims(&self) -> BoxFuture<'static, BackendResult<()>> {
        let backend = self.clone();
        Box::pin(async move {
            backend
                .in_flight_deliveries
                .lock()
                .expect("client event delivery claims poisoned")
                .clear();
            backend.client_event_notify.notify_one();
            Ok(())
        })
    }
}

impl SyncHost for SdkBackend {
    fn get_updates_state(
        &self,
        date: i64,
    ) -> BoxFuture<'static, BackendResult<proto::GetUpdatesStateResult>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            backend
                .call_realtime(
                    &session,
                    proto::GetUpdatesStateInput {
                        date,
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                    },
                )
                .await
        })
    }

    fn get_updates(
        &self,
        input: proto::GetUpdatesInput,
    ) -> BoxFuture<'static, BackendResult<proto::GetUpdatesResult>> {
        let backend = self.clone();
        Box::pin(async move {
            let session = backend.require_session().await?;
            backend.call_realtime(&session, input).await
        })
    }

    fn apply_sync_batch(
        &self,
        updates: Vec<proto::Update>,
        sidecars: Option<proto::UpdateSidecars>,
    ) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>> {
        let backend = self.clone();
        Box::pin(async move {
            let mut events = if let Some(sidecars) = sidecars {
                backend.apply_sidecars(sidecars).await?
            } else {
                Vec::new()
            };
            events.extend(backend.apply_updates(updates, None, None).await?);
            Ok(events)
        })
    }

    fn repair_bucket(
        &self,
        key: crate::SyncBucketKey,
    ) -> BoxFuture<'static, BackendResult<Vec<ClientEvent>>> {
        let backend = self.clone();
        Box::pin(async move {
            match key {
                crate::SyncBucketKey::User => backend.repair_user_bucket().await,
                crate::SyncBucketKey::Space { space_id } => {
                    backend.repair_space_bucket(space_id).await
                }
                crate::SyncBucketKey::Chat { peer } => backend.repair_chat_bucket(peer).await,
            }
        })
    }
}

impl SdkBackend {
    async fn repair_user_bucket(&self) -> BackendResult<Vec<ClientEvent>> {
        let session = self.require_session().await?;
        let chats = self
            .call_realtime(&session, proto::GetChatsInput {})
            .await?;
        let me = self.call_realtime(&session, proto::GetMeInput {}).await?;
        let settings = self
            .call_realtime(&session, proto::GetUserSettingsInput {})
            .await?;
        let user = me.user.ok_or_else(|| {
            BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "user bucket snapshot did not include the current user",
            )
        })?;
        let settings = settings.user_settings.ok_or_else(|| {
            BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "user bucket snapshot did not include user settings",
            )
        })?;

        let mut events = self.apply_get_chats_snapshot(chats).await?;
        let user = user_record_from_proto(&user);
        self.store
            .record_users(vec![user.clone()])
            .await
            .map_err(store_error_to_backend)?;
        self.store
            .record_user_settings(user_settings_record_from_proto(&settings))
            .await
            .map_err(store_error_to_backend)?;
        events.push(ClientEvent::UserUpserted {
            user_id: user.user_id,
        });
        events.push(ClientEvent::UserSettingsChanged {});
        Ok(events)
    }

    async fn repair_space_bucket(&self, space_id: InlineId) -> BackendResult<Vec<ClientEvent>> {
        let session = self.require_session().await?;
        let chats = self
            .call_realtime(&session, proto::GetChatsInput {})
            .await?;
        let space_is_current = chats.spaces.iter().any(|space| space.id == space_id.get());
        let mut events = self.apply_get_chats_snapshot(chats).await?;
        if space_is_current {
            let settings = self
                .call_realtime(
                    &session,
                    proto::GetSpaceSettingsInput {
                        space_id: space_id.get(),
                    },
                )
                .await?
                .settings
                .ok_or_else(|| {
                    BackendError::new(
                        ClientErrorCategory::ProtocolMismatch,
                        "space settings snapshot did not include settings",
                    )
                })?;
            let mut space = self
                .store
                .space(space_id)
                .await
                .map_err(store_error_to_backend)?
                .ok_or_else(|| {
                    BackendError::new(
                        ClientErrorCategory::ProtocolMismatch,
                        "space settings snapshot did not resolve to a stored space",
                    )
                })?;
            space.grid_enabled = Some(settings.grid_enabled);
            self.store
                .record_space(space)
                .await
                .map_err(store_error_to_backend)?;
            events.push(ClientEvent::SpaceUpserted { space_id });
        }
        events.extend(
            self.repair_space_members(&session, space_id, space_is_current)
                .await?,
        );
        Ok(events)
    }

    async fn repair_space_members(
        &self,
        session: &StoredSession,
        space_id: InlineId,
        space_is_current: bool,
    ) -> BackendResult<Vec<ClientEvent>> {
        let members = if space_is_current {
            Some(
                self.call_realtime(
                    session,
                    proto::GetSpaceMembersInput {
                        space_id: space_id.get(),
                    },
                )
                .await?,
            )
        } else {
            None
        };
        let previous_members = self
            .store
            .space_members(space_id)
            .await
            .map_err(store_error_to_backend)?;
        let (current_members, users) = if let Some(result) = members {
            (
                result
                    .members
                    .iter()
                    .map(space_member_record_from_proto)
                    .collect::<Vec<_>>(),
                result
                    .users
                    .iter()
                    .map(user_record_from_proto)
                    .collect::<Vec<_>>(),
            )
        } else {
            (Vec::new(), Vec::new())
        };
        self.store
            .record_users(users.clone())
            .await
            .map_err(store_error_to_backend)?;
        self.store
            .record_space_members(space_id, current_members.clone())
            .await
            .map_err(store_error_to_backend)?;

        let mut events = users
            .into_iter()
            .map(|user| ClientEvent::UserUpserted {
                user_id: user.user_id,
            })
            .collect::<Vec<_>>();
        let current_ids = current_members
            .iter()
            .map(|member| member.user_id)
            .collect::<HashSet<_>>();
        events.extend(
            current_members
                .into_iter()
                .map(|member| ClientEvent::SpaceMemberChanged {
                    space_id,
                    user_id: member.user_id,
                    removed: false,
                }),
        );
        events.extend(
            previous_members
                .into_iter()
                .filter(|member| !current_ids.contains(&member.user_id))
                .map(|member| ClientEvent::SpaceMemberChanged {
                    space_id,
                    user_id: member.user_id,
                    removed: true,
                }),
        );
        Ok(events)
    }

    async fn repair_chat_bucket(
        &self,
        peer: crate::SyncBucketPeer,
    ) -> BackendResult<Vec<ClientEvent>> {
        let session = self.require_session().await?;
        let peer_id = input_peer_for_sync_bucket_peer(peer);
        let chat_result = match self
            .call_realtime(
                &session,
                proto::GetChatInput {
                    peer_id: Some(peer_id.clone()),
                },
            )
            .await
        {
            Ok(result) => result,
            Err(error) if error.category == ClientErrorCategory::NotFound => {
                let Some(chat_id) = self.stored_chat_id_for_sync_peer(peer).await? else {
                    return Ok(Vec::new());
                };
                self.store
                    .remove_dialog(chat_id)
                    .await
                    .map_err(store_error_to_backend)?;
                return Ok(vec![ClientEvent::ChatDeleted { chat_id }]);
            }
            Err(error) => return Err(error),
        };
        let chat = chat_result.chat.ok_or_else(|| {
            BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "chat bucket snapshot did not include the chat",
            )
        })?;
        let chat_id = InlineId::new(chat.id);
        let participants = self
            .call_realtime(
                &session,
                proto::GetChatParticipantsInput {
                    chat_id: chat_id.get(),
                },
            )
            .await?;
        let history = self.fetch_chat_repair_history(&session, peer_id).await?;

        let dialog = chat_result.dialog;
        let read_state = dialog
            .as_ref()
            .and_then(|dialog| read_state_from_proto_dialog(chat_id, dialog));
        let pinned_message_ids = chat_result
            .pinned_message_ids
            .into_iter()
            .map(InlineId::new)
            .collect::<Vec<_>>();
        let mut events = self.record_chat_update(chat, dialog, None).await?;
        self.mutate_dialog(chat_id, |dialog| {
            dialog.pinned_message_ids = pinned_message_ids;
        })
        .await?;

        let participant_page = chat_participants_page_from_proto(participants);
        self.store
            .record_users(participant_page.users.clone())
            .await
            .map_err(store_error_to_backend)?;
        self.store
            .record_chat_participants(chat_id, participant_page.participants)
            .await
            .map_err(store_error_to_backend)?;
        events.extend(
            participant_page
                .users
                .into_iter()
                .map(|user| ClientEvent::UserUpserted {
                    user_id: user.user_id,
                }),
        );
        events.push(ClientEvent::ChatParticipantsChanged { chat_id });

        for message in history {
            let record = self
                .record_proto_message(message, Some(chat_id), None)
                .await?;
            events.push(ClientEvent::MessageStored { message: record });
        }
        if let Some(read_state) = read_state {
            self.store
                .record_read_state(read_state)
                .await
                .map_err(store_error_to_backend)?;
            events.push(ClientEvent::ReadStateChanged { chat_id });
        }
        Ok(events)
    }

    async fn fetch_chat_repair_history(
        &self,
        session: &StoredSession,
        peer_id: proto::InputPeer,
    ) -> BackendResult<Vec<proto::Message>> {
        let result = self
            .call_realtime(
                session,
                proto::GetChatHistoryInput {
                    peer_id: Some(peer_id),
                    offset_id: None,
                    limit: Some(CHAT_REPAIR_HISTORY_LIMIT),
                    mode: Some(proto::GetChatHistoryMode::HistoryModeLatest as i32),
                    anchor_id: None,
                    before_id: None,
                    after_id: None,
                    before_limit: None,
                    after_limit: None,
                    include_anchor: None,
                },
            )
            .await?;
        if result.messages.len() > CHAT_REPAIR_HISTORY_LIMIT as usize {
            return Err(BackendError::new(
                ClientErrorCategory::ProtocolMismatch,
                "chat repair history exceeded the requested page size",
            ));
        }
        Ok(result.messages)
    }

    async fn apply_get_chats_snapshot(
        &self,
        result: proto::GetChatsResult,
    ) -> BackendResult<Vec<ClientEvent>> {
        let dialogs = dialog_records_from_get_chats(&result);
        let live_ids = dialogs
            .iter()
            .map(|dialog| dialog.chat_id)
            .collect::<HashSet<_>>();
        let read_states = result
            .chats
            .iter()
            .filter_map(|chat| {
                dialog_for_chat(&result, chat)
                    .and_then(|dialog| read_state_from_proto_dialog(InlineId::new(chat.id), dialog))
            })
            .collect::<Vec<_>>();
        let users = result
            .users
            .iter()
            .map(user_record_from_proto)
            .collect::<Vec<_>>();
        let spaces = result
            .spaces
            .iter()
            .map(space_record_from_proto)
            .collect::<Vec<_>>();

        self.merge_live_dialogs(dialogs).await?;
        self.store
            .record_users(users.clone())
            .await
            .map_err(store_error_to_backend)?;
        for space in &spaces {
            self.store
                .record_space(space.clone())
                .await
                .map_err(store_error_to_backend)?;
        }
        for read_state in &read_states {
            self.store
                .record_read_state(*read_state)
                .await
                .map_err(store_error_to_backend)?;
        }

        let mut events = live_ids
            .into_iter()
            .map(|chat_id| ClientEvent::ChatUpserted { chat_id })
            .collect::<Vec<_>>();
        events.extend(users.into_iter().map(|user| ClientEvent::UserUpserted {
            user_id: user.user_id,
        }));
        events.extend(spaces.into_iter().map(|space| ClientEvent::SpaceUpserted {
            space_id: space.space_id,
        }));
        events.extend(
            read_states
                .into_iter()
                .map(|state| ClientEvent::ReadStateChanged {
                    chat_id: state.chat_id,
                }),
        );
        for message in result.messages {
            let record = self.record_proto_message(message, None, None).await?;
            events.push(ClientEvent::MessageStored { message: record });
        }
        Ok(events)
    }

    async fn stored_chat_id_for_sync_peer(
        &self,
        peer: crate::SyncBucketPeer,
    ) -> BackendResult<Option<InlineId>> {
        match peer {
            crate::SyncBucketPeer::Chat { chat_id } => Ok(Some(chat_id)),
            crate::SyncBucketPeer::User { user_id } => {
                let dialogs = self
                    .store
                    .dialogs(DialogsRequest {
                        limit: Some(u32::MAX),
                        cursor: None,
                        order: DialogsOrder::StableChatId,
                    })
                    .await
                    .map_err(store_error_to_backend)?;
                Ok(dialogs
                    .dialogs
                    .into_iter()
                    .find(|dialog| dialog.peer_user_id == Some(user_id))
                    .map(|dialog| dialog.chat_id))
            }
        }
    }

    async fn apply_sidecars(
        &self,
        sidecars: proto::UpdateSidecars,
    ) -> BackendResult<Vec<ClientEvent>> {
        let mut users = Vec::with_capacity(sidecars.users.len());
        for user in &sidecars.users {
            let mut record = user_record_from_proto(user);
            if user.min == Some(true)
                && let Some(existing) = self
                    .store
                    .user(record.user_id)
                    .await
                    .map_err(store_error_to_backend)?
            {
                record.display_name = record.display_name.or(existing.display_name);
                record.username = record.username.or(existing.username);
                record.first_name = record.first_name.or(existing.first_name);
                record.last_name = record.last_name.or(existing.last_name);
                record.avatar_url = record.avatar_url.or(existing.avatar_url);
                record.is_bot = record.is_bot.or(existing.is_bot);
            }
            users.push(record);
        }
        self.store
            .record_users(users.clone())
            .await
            .map_err(store_error_to_backend)?;

        let users_by_id = sidecars
            .users
            .iter()
            .map(|user| (user.id, user))
            .collect::<HashMap<_, _>>();
        for chat in &sidecars.chats {
            let dialog = sidecars.dialogs.iter().find(|dialog| {
                dialog.chat_id == Some(chat.id)
                    || dialog
                        .peer
                        .as_ref()
                        .zip(chat.peer_id.as_ref())
                        .is_some_and(|(dialog_peer, chat_peer)| dialog_peer == chat_peer)
            });
            let existing = self
                .store
                .dialog(InlineId::new(chat.id))
                .await
                .map_err(store_error_to_backend)?;
            self.store
                .record_dialog(DialogRecord {
                    chat_id: InlineId::new(chat.id),
                    peer_user_id: dialog_peer_user_id(dialog, chat)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.peer_user_id)),
                    title: Some(chat_title_from_proto(chat, &users_by_id)),
                    emoji: chat_emoji_from_proto(chat)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.emoji.clone())),
                    last_message_id: chat
                        .last_msg_id
                        .map(InlineId::new)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.last_message_id)),
                    synced_through_message_id: existing
                        .as_ref()
                        .and_then(|dialog| dialog.synced_through_message_id),
                    unread_count: dialog
                        .and_then(|dialog| dialog.unread_count)
                        .and_then(|count| u32::try_from(count).ok())
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.unread_count)),
                    space_id: dialog
                        .and_then(|dialog| dialog.space_id)
                        .or(chat.space_id)
                        .map(InlineId::new)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.space_id)),
                    is_public: chat
                        .is_public
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.is_public)),
                    archived: dialog
                        .and_then(|dialog| dialog.archived)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.archived)),
                    pinned: dialog
                        .and_then(|dialog| dialog.pinned)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.pinned)),
                    open: dialog
                        .and_then(|dialog| dialog.open)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.open)),
                    chat_list_hidden: dialog
                        .and_then(|dialog| dialog.chat_list_hidden)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.chat_list_hidden)),
                    order: dialog
                        .and_then(|dialog| dialog.order.clone())
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.order.clone())),
                    pinned_order: dialog
                        .and_then(|dialog| dialog.pinned_order.clone())
                        .or_else(|| {
                            existing
                                .as_ref()
                                .and_then(|dialog| dialog.pinned_order.clone())
                        }),
                    notification_mode: dialog
                        .and_then(dialog_notification_mode_from_proto)
                        .or_else(|| {
                            existing
                                .as_ref()
                                .and_then(|dialog| dialog.notification_mode)
                        }),
                    follow_mode: dialog
                        .and_then(dialog_follow_mode_from_proto)
                        .or_else(|| existing.as_ref().and_then(|dialog| dialog.follow_mode)),
                    ..existing.unwrap_or_else(|| DialogRecord::new(InlineId::new(chat.id)))
                })
                .await
                .map_err(store_error_to_backend)?;
        }

        let mut events = users
            .into_iter()
            .map(|user| ClientEvent::UserUpserted {
                user_id: user.user_id,
            })
            .collect::<Vec<_>>();
        events.extend(
            sidecars
                .chats
                .into_iter()
                .map(|chat| ClientEvent::ChatUpserted {
                    chat_id: InlineId::new(chat.id),
                }),
        );
        for space in sidecars.spaces {
            let mut record = space_record_from_proto(&space);
            if record.grid_enabled.is_none()
                && let Some(existing) = self
                    .store
                    .space(record.space_id)
                    .await
                    .map_err(store_error_to_backend)?
            {
                record.grid_enabled = existing.grid_enabled;
            }
            self.store
                .record_space(record.clone())
                .await
                .map_err(store_error_to_backend)?;
            events.push(ClientEvent::SpaceUpserted {
                space_id: record.space_id,
            });
        }
        Ok(events)
    }

    async fn record_chat_update(
        &self,
        chat: proto::Chat,
        dialog: Option<proto::Dialog>,
        user: Option<proto::User>,
    ) -> BackendResult<Vec<ClientEvent>> {
        let user_record = user.as_ref().map(user_record_from_proto);
        if let Some(user) = user_record.as_ref() {
            self.store
                .record_users(vec![user.clone()])
                .await
                .map_err(store_error_to_backend)?;
        }
        let existing = self
            .store
            .dialog(InlineId::new(chat.id))
            .await
            .map_err(store_error_to_backend)?;
        let users_by_id = user
            .as_ref()
            .map(|user| HashMap::from([(user.id, user)]))
            .unwrap_or_default();
        let record = DialogRecord {
            chat_id: InlineId::new(chat.id),
            peer_user_id: dialog_peer_user_id(dialog.as_ref(), &chat)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.peer_user_id)),
            title: Some(chat_title_from_proto(&chat, &users_by_id)),
            emoji: chat_emoji_from_proto(&chat),
            last_message_id: chat
                .last_msg_id
                .map(InlineId::new)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.last_message_id)),
            synced_through_message_id: existing
                .as_ref()
                .and_then(|dialog| dialog.synced_through_message_id),
            unread_count: dialog
                .as_ref()
                .and_then(|dialog| dialog.unread_count)
                .and_then(|count| u32::try_from(count).ok())
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.unread_count)),
            space_id: dialog
                .as_ref()
                .and_then(|dialog| dialog.space_id)
                .or(chat.space_id)
                .map(InlineId::new)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.space_id)),
            is_public: chat
                .is_public
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.is_public)),
            archived: dialog
                .as_ref()
                .and_then(|dialog| dialog.archived)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.archived)),
            pinned: dialog
                .as_ref()
                .and_then(|dialog| dialog.pinned)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.pinned)),
            open: dialog
                .as_ref()
                .and_then(|dialog| dialog.open)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.open)),
            chat_list_hidden: dialog
                .as_ref()
                .and_then(|dialog| dialog.chat_list_hidden)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.chat_list_hidden)),
            order: dialog
                .as_ref()
                .and_then(|dialog| dialog.order.clone())
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.order.clone())),
            pinned_order: dialog
                .as_ref()
                .and_then(|dialog| dialog.pinned_order.clone())
                .or_else(|| {
                    existing
                        .as_ref()
                        .and_then(|dialog| dialog.pinned_order.clone())
                }),
            notification_mode: dialog
                .as_ref()
                .and_then(dialog_notification_mode_from_proto)
                .or_else(|| {
                    existing
                        .as_ref()
                        .and_then(|dialog| dialog.notification_mode)
                }),
            follow_mode: dialog
                .as_ref()
                .and_then(dialog_follow_mode_from_proto)
                .or_else(|| existing.as_ref().and_then(|dialog| dialog.follow_mode)),
            ..existing
                .clone()
                .unwrap_or_else(|| DialogRecord::new(InlineId::new(chat.id)))
        };
        self.store
            .record_dialog(record.clone())
            .await
            .map_err(store_error_to_backend)?;

        let mut events = vec![ClientEvent::ChatUpserted {
            chat_id: record.chat_id,
        }];
        if let Some(user) = user_record {
            events.push(ClientEvent::UserUpserted {
                user_id: user.user_id,
            });
        }
        Ok(events)
    }

    async fn resolve_chat_id(
        &self,
        peer: Option<&proto::Peer>,
        fallback: Option<InlineId>,
    ) -> BackendResult<Option<InlineId>> {
        let Some(peer) = peer else {
            return Ok(fallback);
        };
        match peer.r#type.as_ref() {
            Some(proto::peer::Type::Chat(chat)) => Ok(Some(InlineId::new(chat.chat_id))),
            Some(proto::peer::Type::User(user)) => {
                let dialogs = self
                    .store
                    .dialogs(DialogsRequest {
                        limit: Some(u32::MAX),
                        cursor: None,
                        order: DialogsOrder::StableChatId,
                    })
                    .await
                    .map_err(store_error_to_backend)?;
                Ok(dialogs
                    .dialogs
                    .into_iter()
                    .find(|dialog| dialog.peer_user_id == Some(InlineId::new(user.user_id)))
                    .map(|dialog| dialog.chat_id)
                    .or(fallback))
            }
            None => Ok(fallback),
        }
    }

    async fn mutate_dialog(
        &self,
        chat_id: InlineId,
        mutate: impl FnOnce(&mut DialogRecord),
    ) -> BackendResult<()> {
        let mut dialog = self
            .store
            .dialog(chat_id)
            .await
            .map_err(store_error_to_backend)?
            .unwrap_or_else(|| DialogRecord::new(chat_id));
        mutate(&mut dialog);
        self.store
            .record_dialog(dialog)
            .await
            .map_err(store_error_to_backend)
    }

    async fn merge_live_dialogs(&self, dialogs: Vec<DialogRecord>) -> BackendResult<()> {
        for dialog in dialogs {
            self.store
                .record_dialog(dialog)
                .await
                .map_err(store_error_to_backend)?;
        }
        Ok(())
    }

    async fn record_proto_message(
        &self,
        message: proto::Message,
        fallback_chat_id: Option<InlineId>,
        transaction: Option<TransactionIdentity>,
    ) -> BackendResult<MessageRecord> {
        let reaction_snapshot = reaction_snapshot_from_proto_message(&message, fallback_chat_id);
        let record = message_record_from_proto_message(message, fallback_chat_id, transaction);
        self.store
            .record_message(record.clone())
            .await
            .map_err(store_error_to_backend)?;
        if let Some(reactions) = reaction_snapshot {
            self.store
                .replace_message_reactions(record.chat_id, record.message_id, reactions)
                .await
                .map_err(store_error_to_backend)?;
        }
        Ok(record)
    }

    async fn record_transaction_error(
        &self,
        identity: TransactionIdentity,
        chat_id: InlineId,
        retry_state: TransactionState,
        error: BackendError,
    ) -> BackendResult<()> {
        let state = if retryable_transaction_category(error.category) {
            retry_state
        } else {
            TransactionState::Failed
        };
        self.store
            .record_transaction(
                StoredTransaction::new(identity, state)
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
            let seq = update.seq.unwrap_or_default();
            match update.update {
                Some(proto::update::Update::NewMessage(update)) => {
                    if let Some(message) = update.message {
                        let record = self
                            .record_proto_message(message, fallback_chat_id, None)
                            .await?;
                        events.push(ClientEvent::MessageStored { message: record });
                    }
                }
                Some(proto::update::Update::EditMessage(update)) => {
                    if let Some(message) = update.message {
                        let record = self
                            .record_proto_message(message, fallback_chat_id, None)
                            .await?;
                        events.push(ClientEvent::MessageStored { message: record });
                    }
                }
                Some(proto::update::Update::DeleteMessages(update)) => {
                    let chat_id = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?
                        .ok_or_else(|| {
                            BackendError::new(
                                ClientErrorCategory::ProtocolMismatch,
                                "delete update did not resolve to a stored chat",
                            )
                        })?;
                    for message_id in update.message_ids {
                        let message_id = InlineId::new(message_id);
                        self.store
                            .record_message_deleted(chat_id, message_id)
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::MessageDeleted {
                            chat_id,
                            message_id,
                        });
                    }
                }
                Some(proto::update::Update::UpdateReaction(update)) => {
                    if let Some(reaction) = update.reaction {
                        let stored = StoredReaction {
                            chat_id: InlineId::new(reaction.chat_id),
                            message_id: InlineId::new(reaction.message_id),
                            user_id: InlineId::new(reaction.user_id),
                            reaction: reaction.emoji,
                        };
                        self.store
                            .record_reaction(stored.clone())
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::ReactionChanged {
                            chat_id: stored.chat_id,
                            message_id: stored.message_id,
                            user_id: stored.user_id,
                            reaction: stored.reaction,
                            removed: false,
                        });
                    }
                }
                Some(proto::update::Update::DeleteReaction(update)) => {
                    let stored = StoredReaction {
                        chat_id: InlineId::new(update.chat_id),
                        message_id: InlineId::new(update.message_id),
                        user_id: InlineId::new(update.user_id),
                        reaction: update.emoji,
                    };
                    self.store
                        .remove_reaction(stored.clone())
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::ReactionChanged {
                        chat_id: stored.chat_id,
                        message_id: stored.message_id,
                        user_id: stored.user_id,
                        reaction: stored.reaction,
                        removed: true,
                    });
                }
                Some(proto::update::Update::UpdateReadMaxId(update)) => {
                    let chat_id = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?;
                    if let Some(chat_id) = chat_id {
                        self.store
                            .record_read_state(StoredReadState {
                                chat_id,
                                read_max_id: Some(InlineId::new(update.read_max_id)),
                                unread_count: u32::try_from(update.unread_count).ok(),
                                marked_unread: false,
                            })
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::ReadStateChanged { chat_id });
                    }
                }
                Some(proto::update::Update::MarkAsUnread(update)) => {
                    if let Some(chat_id) = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?
                    {
                        let current = self
                            .store
                            .read_state(chat_id)
                            .await
                            .map_err(store_error_to_backend)?;
                        self.store
                            .record_read_state(StoredReadState {
                                chat_id,
                                read_max_id: current.and_then(|state| state.read_max_id),
                                unread_count: current.and_then(|state| state.unread_count),
                                marked_unread: update.unread_mark,
                            })
                            .await
                            .map_err(store_error_to_backend)?;
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
                Some(proto::update::Update::NewChat(update)) => {
                    if let Some(chat) = update.chat {
                        events.extend(self.record_chat_update(chat, None, update.user).await?);
                    }
                }
                Some(proto::update::Update::ChatOpen(update)) => {
                    if let Some(chat) = update.chat {
                        events.extend(
                            self.record_chat_update(chat, update.dialog, update.user)
                                .await?,
                        );
                    }
                }
                Some(proto::update::Update::ChatMoved(update)) => {
                    if let Some(chat) = update.chat {
                        events.extend(self.record_chat_update(chat, None, None).await?);
                    }
                }
                Some(proto::update::Update::ChatInfo(update)) => {
                    let chat_id = InlineId::new(update.chat_id);
                    let mut dialog = self
                        .store
                        .dialog(chat_id)
                        .await
                        .map_err(store_error_to_backend)?
                        .unwrap_or(DialogRecord {
                            chat_id,
                            peer_user_id: None,
                            title: None,
                            last_message_id: None,
                            synced_through_message_id: None,
                            unread_count: None,
                            ..DialogRecord::new(chat_id)
                        });
                    if let Some(title) = update.title {
                        dialog.title = trimmed_option(Some(title));
                    }
                    if let Some(emoji) = update.emoji {
                        dialog.emoji = non_empty_option(Some(&emoji));
                    }
                    self.store
                        .record_dialog(dialog)
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::ChatUpserted { chat_id });
                }
                Some(proto::update::Update::ChatVisibility(update)) => {
                    let chat_id = InlineId::new(update.chat_id);
                    self.mutate_dialog(chat_id, |dialog| {
                        dialog.is_public = Some(update.is_public);
                    })
                    .await?;
                    events.push(ClientEvent::ChatUpserted { chat_id });
                }
                Some(proto::update::Update::DialogArchived(update)) => {
                    let chat_id = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?
                        .ok_or_else(|| unresolved_update_peer("dialog archived"))?;
                    self.mutate_dialog(chat_id, |dialog| {
                        dialog.archived = Some(update.archived);
                    })
                    .await?;
                    events.push(ClientEvent::ChatUpserted { chat_id });
                }
                Some(proto::update::Update::DialogNotificationSettings(update)) => {
                    let chat_id = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?
                        .ok_or_else(|| unresolved_update_peer("dialog notification settings"))?;
                    let mode = update
                        .notification_settings
                        .as_ref()
                        .and_then(dialog_notification_mode_from_settings);
                    self.mutate_dialog(chat_id, |dialog| {
                        dialog.notification_mode = mode;
                    })
                    .await?;
                    events.push(ClientEvent::ChatUpserted { chat_id });
                }
                Some(proto::update::Update::DialogFollowMode(update)) => {
                    let chat_id = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?
                        .ok_or_else(|| unresolved_update_peer("dialog follow mode"))?;
                    let mode = update.follow_mode.and_then(dialog_follow_mode_from_value);
                    self.mutate_dialog(chat_id, |dialog| {
                        dialog.follow_mode = mode;
                    })
                    .await?;
                    events.push(ClientEvent::ChatUpserted { chat_id });
                }
                Some(proto::update::Update::PinnedMessages(update)) => {
                    let chat_id = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?
                        .ok_or_else(|| unresolved_update_peer("pinned messages"))?;
                    let message_ids = update
                        .message_ids
                        .into_iter()
                        .map(InlineId::new)
                        .collect::<Vec<_>>();
                    self.mutate_dialog(chat_id, |dialog| {
                        dialog.pinned_message_ids = message_ids;
                    })
                    .await?;
                    events.push(ClientEvent::ChatUpserted { chat_id });
                }
                Some(proto::update::Update::MessageAttachment(update)) => {
                    let chat_id = (update.chat_id > 0)
                        .then(|| InlineId::new(update.chat_id))
                        .or(self
                            .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                            .await?)
                        .ok_or_else(|| unresolved_update_peer("message attachment"))?;
                    events.push(ClientEvent::MessageUpserted {
                        chat_id,
                        message_id: InlineId::new(update.message_id),
                    });
                }
                Some(proto::update::Update::ClearChatHistory(update)) => {
                    let chat_ids = match update.target {
                        Some(proto::update_clear_chat_history::Target::PeerId(peer)) => vec![
                            self.resolve_chat_id(Some(&peer), fallback_chat_id)
                                .await?
                                .ok_or_else(|| unresolved_update_peer("clear history"))?,
                        ],
                        Some(proto::update_clear_chat_history::Target::SpaceId(space_id)) => self
                            .store
                            .chat_ids_in_space(InlineId::new(space_id))
                            .await
                            .map_err(store_error_to_backend)?,
                        None => {
                            return Err(BackendError::new(
                                ClientErrorCategory::ProtocolMismatch,
                                "clear history update had no target",
                            ));
                        }
                    };
                    for chat_id in chat_ids {
                        self.store
                            .clear_chat_messages(chat_id, update.before_date)
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::ChatHistoryCleared {
                            chat_id,
                            before_date: update.before_date,
                        });
                    }
                    for deleted_chat_id in update.deleted_chat_ids {
                        let chat_id = InlineId::new(deleted_chat_id);
                        self.store
                            .remove_dialog(chat_id)
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::ChatDeleted { chat_id });
                    }
                    for changed_chat_id in update
                        .orphaned_chat_ids
                        .into_iter()
                        .chain(update.detached_chat_ids)
                    {
                        events.push(ClientEvent::ChatUpserted {
                            chat_id: InlineId::new(changed_chat_id),
                        });
                    }
                }
                Some(proto::update::Update::DeleteChat(update)) => {
                    if let Some(chat_id) = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?
                    {
                        self.store
                            .remove_dialog(chat_id)
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::ChatDeleted { chat_id });
                    }
                }
                Some(proto::update::Update::ParticipantAdd(update)) => {
                    let chat_id = InlineId::new(update.chat_id);
                    if let Some(participant) = update.participant {
                        self.store
                            .record_chat_participant(
                                chat_id,
                                ChatParticipantRecord {
                                    user_id: InlineId::new(participant.user_id),
                                    date: Some(participant.date),
                                },
                            )
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::ChatParticipantsChanged { chat_id });
                    }
                }
                Some(proto::update::Update::ParticipantDelete(update)) => {
                    let chat_id = InlineId::new(update.chat_id);
                    self.store
                        .remove_chat_participant(chat_id, InlineId::new(update.user_id))
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::ChatParticipantsChanged { chat_id });
                }
                Some(proto::update::Update::ParticipantGroupAdd(update)) => {
                    let chat_id = InlineId::new(update.chat_id);
                    if update.group_participant.is_none() {
                        return Err(BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "participant group add update had no group participant",
                        ));
                    }
                    events.push(ClientEvent::ChatParticipantsChanged { chat_id });
                }
                Some(proto::update::Update::ParticipantGroupDelete(update)) => {
                    let chat_id = InlineId::new(update.chat_id);
                    if update.group_id <= 0 {
                        return Err(BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "participant group delete update had an invalid group ID",
                        ));
                    }
                    events.push(ClientEvent::ChatParticipantsChanged { chat_id });
                }
                Some(proto::update::Update::SpaceMemberAdd(update)) => {
                    let member = update.member.ok_or_else(|| {
                        BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "space member add update had no member",
                        )
                    })?;
                    if let Some(user) = update.user {
                        let user = user_record_from_proto(&user);
                        self.store
                            .record_users(vec![user.clone()])
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::UserUpserted {
                            user_id: user.user_id,
                        });
                    }
                    let member = space_member_record_from_proto(&member);
                    self.store
                        .record_space_member(member.clone())
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::SpaceMemberChanged {
                        space_id: member.space_id,
                        user_id: member.user_id,
                        removed: false,
                    });
                }
                Some(proto::update::Update::SpaceMemberDelete(update)) => {
                    let space_id = InlineId::new(update.space_id);
                    let user_id = InlineId::new(update.user_id);
                    self.store
                        .remove_space_member(space_id, user_id)
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::SpaceMemberChanged {
                        space_id,
                        user_id,
                        removed: true,
                    });
                }
                Some(proto::update::Update::SpaceMemberUpdate(update)) => {
                    let member = update.member.ok_or_else(|| {
                        BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "space member update had no member",
                        )
                    })?;
                    let member = space_member_record_from_proto(&member);
                    self.store
                        .record_space_member(member.clone())
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::SpaceMemberChanged {
                        space_id: member.space_id,
                        user_id: member.user_id,
                        removed: false,
                    });
                }
                Some(proto::update::Update::JoinSpace(update)) => {
                    let space = update.space.ok_or_else(|| {
                        BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "join space update had no space",
                        )
                    })?;
                    let space = space_record_from_proto(&space);
                    self.store
                        .record_space(space.clone())
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::SpaceUpserted {
                        space_id: space.space_id,
                    });
                    if let Some(member) = update.member {
                        let member = space_member_record_from_proto(&member);
                        self.store
                            .record_space_member(member.clone())
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::SpaceMemberChanged {
                            space_id: member.space_id,
                            user_id: member.user_id,
                            removed: false,
                        });
                    }
                }
                Some(proto::update::Update::SpaceSettings(update)) => {
                    let settings = update.settings.ok_or_else(|| {
                        BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "space settings update had no settings",
                        )
                    })?;
                    let space_id = InlineId::new(if settings.space_id != 0 {
                        settings.space_id
                    } else {
                        update.space_id
                    });
                    let mut space = self
                        .store
                        .space(space_id)
                        .await
                        .map_err(store_error_to_backend)?
                        .ok_or_else(|| {
                            BackendError::new(
                                ClientErrorCategory::ProtocolMismatch,
                                "space settings update did not resolve to a stored space",
                            )
                        })?;
                    space.grid_enabled = Some(settings.grid_enabled);
                    self.store
                        .record_space(space)
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::SpaceUpserted { space_id });
                }
                Some(proto::update::Update::UpdateUserSettings(update)) => {
                    let settings = update.settings.ok_or_else(|| {
                        BackendError::new(
                            ClientErrorCategory::ProtocolMismatch,
                            "user settings update had no settings",
                        )
                    })?;
                    self.store
                        .record_user_settings(user_settings_record_from_proto(&settings))
                        .await
                        .map_err(store_error_to_backend)?;
                    events.push(ClientEvent::UserSettingsChanged {});
                }
                Some(proto::update::Update::MessageActionInvoked(update)) => {
                    events.push(ClientEvent::MessageActionInvoked {
                        interaction_id: InlineId::new(update.interaction_id),
                        chat_id: InlineId::new(update.chat_id),
                        message_id: InlineId::new(update.message_id),
                        actor_user_id: InlineId::new(update.actor_user_id),
                        action_id: update.action_id,
                        data: update.data,
                    });
                }
                Some(proto::update::Update::MessageActionAnswered(update)) => {
                    let toast = update.ui.and_then(|ui| match ui.kind {
                        Some(proto::message_action_response_ui::Kind::Toast(toast)) => {
                            trimmed_option(Some(toast.text))
                        }
                        None => None,
                    });
                    events.push(ClientEvent::MessageActionAnswered {
                        interaction_id: InlineId::new(update.interaction_id),
                        toast,
                    });
                }
                Some(proto::update::Update::UpdatedUser(update)) => {
                    if let Some(user) = update.user {
                        let record = user_record_from_proto(&user);
                        self.store
                            .record_users(vec![record.clone()])
                            .await
                            .map_err(store_error_to_backend)?;
                        events.push(ClientEvent::UserUpserted {
                            user_id: record.user_id,
                        });
                    }
                }
                Some(proto::update::Update::ChatSkipPts(_)) => {}
                Some(proto::update::Update::UpdateUserStatus(update)) => {
                    let status = update.status.as_ref();
                    let is_online = status.and_then(|status| {
                        match proto::user_status::Status::try_from(status.online).ok()? {
                            proto::user_status::Status::Online => Some(true),
                            proto::user_status::Status::Offline => Some(false),
                            proto::user_status::Status::Unknown => None,
                        }
                    });
                    events.push(ClientEvent::UserStatusChanged {
                        user_id: InlineId::new(update.user_id),
                        is_online,
                        last_online: status
                            .and_then(|status| status.last_online.as_ref())
                            .and_then(|last_online| last_online.date),
                    });
                }
                Some(proto::update::Update::BotPresence(update)) => {
                    let state = update.state.as_ref();
                    let kind = state
                        .and_then(|state| {
                            proto::bot_presence_state::Kind::try_from(state.kind).ok()
                        })
                        .map(|kind| kind.as_str_name().to_owned())
                        .unwrap_or_else(|| "KIND_UNSPECIFIED".to_owned());
                    let chat_id = self
                        .resolve_chat_id(update.peer_id.as_ref(), fallback_chat_id)
                        .await?;
                    events.push(ClientEvent::BotPresenceChanged {
                        bot_user_id: InlineId::new(update.bot_user_id),
                        chat_id,
                        kind,
                        comment: state.and_then(|state| trimmed_option(state.comment.clone())),
                        avatar_changed: update.avatar_changed,
                    });
                }
                Some(proto::update::Update::NewMessageNotification(update)) => {
                    if let Some(message) = update.message {
                        let message =
                            message_record_from_proto_message(message, fallback_chat_id, None);
                        let reason =
                            proto::update_new_message_notification::Reason::try_from(update.reason)
                                .map(|reason| reason.as_str_name().to_owned())
                                .unwrap_or_else(|_| "REASON_UNSPECIFIED".to_owned());
                        events.push(ClientEvent::NewMessageNotification { message, reason });
                    }
                }
                Some(other) => {
                    let kind = update_kind(&other);
                    return Err(BackendError::new(
                        ClientErrorCategory::Unsupported,
                        format!("Inline update is not implemented: {kind}"),
                    ));
                }
                None if seq > 0 => {
                    return Err(BackendError::new(
                        ClientErrorCategory::ProtocolMismatch,
                        "sequenced Inline update had no payload",
                    ));
                }
                None => {}
            }
        }
        Ok(events)
    }
}

fn store_error_to_backend(error: StoreError) -> BackendError {
    BackendError::new(error.category, error.message)
}

fn unresolved_update_peer(kind: &str) -> BackendError {
    BackendError::new(
        ClientErrorCategory::ProtocolMismatch,
        format!("{kind} update did not resolve to a stored chat"),
    )
}

fn update_kind(update: &proto::update::Update) -> &'static str {
    use proto::update::Update;
    match update {
        Update::NewMessage(_) => "new_message",
        Update::EditMessage(_) => "edit_message",
        Update::UpdateMessageId(_) => "update_message_id",
        Update::DeleteMessages(_) => "delete_messages",
        Update::UpdateComposeAction(_) => "update_compose_action",
        Update::UpdateUserStatus(_) => "update_user_status",
        Update::MessageAttachment(_) => "message_attachment",
        Update::UpdateReaction(_) => "update_reaction",
        Update::DeleteReaction(_) => "delete_reaction",
        Update::ParticipantAdd(_) => "participant_add",
        Update::ParticipantDelete(_) => "participant_delete",
        Update::NewChat(_) => "new_chat",
        Update::DeleteChat(_) => "delete_chat",
        Update::SpaceMemberAdd(_) => "space_member_add",
        Update::SpaceMemberDelete(_) => "space_member_delete",
        Update::JoinSpace(_) => "join_space",
        Update::UpdateReadMaxId(_) => "update_read_max_id",
        Update::UpdateUserSettings(_) => "update_user_settings",
        Update::NewMessageNotification(_) => "new_message_notification",
        Update::MarkAsUnread(_) => "mark_as_unread",
        Update::ChatSkipPts(_) => "chat_skip_pts",
        Update::ChatHasNewUpdates(_) => "chat_has_new_updates",
        Update::SpaceHasNewUpdates(_) => "space_has_new_updates",
        Update::SpaceMemberUpdate(_) => "space_member_update",
        Update::ChatVisibility(_) => "chat_visibility",
        Update::DialogArchived(_) => "dialog_archived",
        Update::ChatInfo(_) => "chat_info",
        Update::PinnedMessages(_) => "pinned_messages",
        Update::ChatMoved(_) => "chat_moved",
        Update::DialogNotificationSettings(_) => "dialog_notification_settings",
        Update::ChatOpen(_) => "chat_open",
        Update::MessageActionInvoked(_) => "message_action_invoked",
        Update::MessageActionAnswered(_) => "message_action_answered",
        Update::ClearChatHistory(_) => "clear_chat_history",
        Update::BotPresence(_) => "bot_presence",
        Update::DialogFollowMode(_) => "dialog_follow_mode",
        Update::UpdatedUser(_) => "updated_user",
        Update::ParticipantGroupAdd(_) => "participant_group_add",
        Update::ParticipantGroupDelete(_) => "participant_group_delete",
        Update::SpaceSettings(_) => "space_settings",
    }
}

#[cfg(test)]
fn dialogs_page_from_get_chats(
    result: &proto::GetChatsResult,
    request: DialogsRequest,
) -> BackendResult<DialogsPage> {
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

    let mut dialogs = dialog_records_from_get_chats(result);
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

fn dialog_records_from_get_chats(result: &proto::GetChatsResult) -> Vec<DialogRecord> {
    let users_by_id = result
        .users
        .iter()
        .map(|user| (user.id, user))
        .collect::<HashMap<_, _>>();
    result
        .chats
        .iter()
        .map(|chat| {
            let dialog = dialog_for_chat(result, chat);
            DialogRecord {
                chat_id: InlineId::new(chat.id),
                peer_user_id: dialog_peer_user_id(dialog, chat),
                title: Some(chat_title_from_proto(chat, &users_by_id)),
                emoji: chat_emoji_from_proto(chat),
                last_message_id: chat.last_msg_id.map(InlineId::new),
                synced_through_message_id: None,
                unread_count: dialog
                    .and_then(|dialog| dialog.unread_count)
                    .and_then(|count| u32::try_from(count).ok()),
                space_id: dialog
                    .and_then(|dialog| dialog.space_id)
                    .or(chat.space_id)
                    .map(InlineId::new),
                is_public: chat.is_public,
                archived: dialog.and_then(|dialog| dialog.archived),
                pinned: dialog.and_then(|dialog| dialog.pinned),
                open: dialog.and_then(|dialog| dialog.open),
                chat_list_hidden: dialog.and_then(|dialog| dialog.chat_list_hidden),
                order: dialog.and_then(|dialog| dialog.order.clone()),
                pinned_order: dialog.and_then(|dialog| dialog.pinned_order.clone()),
                notification_mode: dialog.and_then(dialog_notification_mode_from_proto),
                follow_mode: dialog.and_then(dialog_follow_mode_from_proto),
                ..DialogRecord::new(InlineId::new(chat.id))
            }
        })
        .collect()
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

fn read_state_from_proto_dialog(
    chat_id: InlineId,
    dialog: &proto::Dialog,
) -> Option<StoredReadState> {
    if dialog.read_max_id.is_none() && dialog.unread_count.is_none() && dialog.unread_mark.is_none()
    {
        return None;
    }
    Some(StoredReadState {
        chat_id,
        read_max_id: dialog.read_max_id.map(InlineId::new),
        unread_count: dialog
            .unread_count
            .and_then(|count| u32::try_from(count).ok()),
        marked_unread: dialog.unread_mark.unwrap_or(false),
    })
}

fn dialog_peer_user_id(dialog: Option<&proto::Dialog>, chat: &proto::Chat) -> Option<InlineId> {
    dialog
        .and_then(|dialog| dialog.peer.as_ref())
        .or(chat.peer_id.as_ref())
        .and_then(user_id_from_peer)
        .map(InlineId::new)
}

fn dialog_notification_mode_from_proto(dialog: &proto::Dialog) -> Option<DialogNotificationMode> {
    dialog
        .notification_settings
        .as_ref()
        .and_then(dialog_notification_mode_from_settings)
}

fn dialog_notification_mode_from_settings(
    settings: &proto::DialogNotificationSettings,
) -> Option<DialogNotificationMode> {
    match proto::dialog_notification_settings::Mode::try_from(settings.mode?).ok()? {
        proto::dialog_notification_settings::Mode::All => Some(DialogNotificationMode::All),
        proto::dialog_notification_settings::Mode::Mentions => {
            Some(DialogNotificationMode::Mentions)
        }
        proto::dialog_notification_settings::Mode::None => Some(DialogNotificationMode::None),
        proto::dialog_notification_settings::Mode::Unspecified => None,
    }
}

fn dialog_notification_mode_to_proto(
    mode: DialogNotificationMode,
) -> proto::dialog_notification_settings::Mode {
    match mode {
        DialogNotificationMode::All => proto::dialog_notification_settings::Mode::All,
        DialogNotificationMode::Mentions => proto::dialog_notification_settings::Mode::Mentions,
        DialogNotificationMode::None => proto::dialog_notification_settings::Mode::None,
    }
}

fn dialog_follow_mode_from_proto(dialog: &proto::Dialog) -> Option<DialogFollowMode> {
    dialog.follow_mode.and_then(dialog_follow_mode_from_value)
}

fn dialog_follow_mode_from_value(value: i32) -> Option<DialogFollowMode> {
    match proto::DialogFollowMode::try_from(value).ok()? {
        proto::DialogFollowMode::Following => Some(DialogFollowMode::Following),
        proto::DialogFollowMode::Unfollowed => Some(DialogFollowMode::Unfollowed),
        proto::DialogFollowMode::Unspecified => None,
    }
}

fn chat_title_from_proto(chat: &proto::Chat, users_by_id: &HashMap<i64, &proto::User>) -> String {
    chat.peer_id
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
        })
}

fn chat_emoji_from_proto(chat: &proto::Chat) -> Option<String> {
    non_empty_option(chat.emoji.as_deref())
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

fn space_record_from_proto(space: &proto::Space) -> SpaceRecord {
    SpaceRecord {
        space_id: InlineId::new(space.id),
        name: space.name.clone(),
        creator: space.creator,
        date: space.date,
        is_public: space.is_public,
        grid_enabled: None,
    }
}

fn space_member_record_from_proto(member: &proto::Member) -> SpaceMemberRecord {
    SpaceMemberRecord {
        space_id: InlineId::new(member.space_id),
        user_id: InlineId::new(member.user_id),
        role: member
            .role
            .and_then(|role| match proto::member::Role::try_from(role).ok()? {
                proto::member::Role::Owner => Some(SpaceMemberRole::Owner),
                proto::member::Role::Admin => Some(SpaceMemberRole::Admin),
                proto::member::Role::Member => Some(SpaceMemberRole::Member),
            }),
        date: member.date,
        can_access_public_chats: member.can_access_public_chats,
    }
}

fn user_settings_record_from_proto(settings: &proto::UserSettings) -> UserSettingsRecord {
    let notifications = settings.notification_settings.as_ref();
    UserSettingsRecord {
        notification_mode: notifications
            .and_then(|settings| settings.mode)
            .and_then(
                |mode| match proto::notification_settings::Mode::try_from(mode).ok()? {
                    proto::notification_settings::Mode::All => Some(NotificationMode::All),
                    proto::notification_settings::Mode::None => Some(NotificationMode::None),
                    proto::notification_settings::Mode::Mentions => {
                        Some(NotificationMode::Mentions)
                    }
                    proto::notification_settings::Mode::ImportantOnly => {
                        Some(NotificationMode::ImportantOnly)
                    }
                    proto::notification_settings::Mode::OnlyMentions => {
                        Some(NotificationMode::OnlyMentions)
                    }
                    proto::notification_settings::Mode::Unspecified => None,
                },
            ),
        silent: notifications.and_then(|settings| settings.silent),
        zen_mode_requires_mention: notifications
            .and_then(|settings| settings.zen_mode_requires_mention),
        zen_mode_uses_default_rules: notifications
            .and_then(|settings| settings.zen_mode_uses_default_rules),
        zen_mode_custom_rules: notifications
            .and_then(|settings| settings.zen_mode_custom_rules.clone()),
        disable_dm_notifications: notifications
            .and_then(|settings| settings.disable_dm_notifications),
    }
}

fn chat_participants_page_from_proto(
    result: proto::GetChatParticipantsResult,
) -> ChatParticipantsPage {
    let mut seen = std::collections::HashSet::new();
    let mut participants = Vec::new();
    for participant in &result.participants {
        if seen.insert(participant.user_id) {
            participants.push(ChatParticipantRecord {
                user_id: InlineId::new(participant.user_id),
                date: Some(participant.date),
            });
        }
    }
    let groups_by_id = result
        .groups
        .iter()
        .map(|group| (group.id, group))
        .collect::<HashMap<_, _>>();
    for grant in &result.group_participants {
        let group = groups_by_id.get(&grant.group_id);
        for user_id in group.into_iter().flat_map(|group| group.user_ids.iter()) {
            if seen.insert(*user_id) {
                participants.push(ChatParticipantRecord {
                    user_id: InlineId::new(*user_id),
                    date: Some(grant.date),
                });
            }
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

fn validate_chat_and_user_ids(chat_id: InlineId, user_id: InlineId) -> BackendResult<()> {
    if chat_id.get() <= 0 || user_id.get() <= 0 {
        return Err(BackendError::new(
            ClientErrorCategory::InvalidInput,
            "chat_id and user_id must be positive",
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

fn normalized_account_namespace(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
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
        RealtimeError::ConnectionError { .. } => {
            BackendError::new(ClientErrorCategory::AuthExpired, error.to_string())
        }
        RealtimeError::RpcError {
            code,
            error_name,
            friendly,
            ..
        } if code == 420 || code == 429 || is_rate_limit_error_name(&error_name) => {
            rate_limited_backend_error(friendly)
        }
        RealtimeError::RpcError {
            error_name,
            friendly,
            ..
        } if error_name == "UNAUTHENTICATED" => {
            BackendError::new(ClientErrorCategory::AuthExpired, friendly)
        }
        RealtimeError::RpcError { friendly, .. } => {
            BackendError::new(ClientErrorCategory::Internal, friendly)
        }
        RealtimeError::ConnectionClosed
        | RealtimeError::EventLagged { .. }
        | RealtimeError::WebSocket(_) => {
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

fn realtime_error_closes_session(error: &RealtimeError) -> bool {
    matches!(
        error,
        RealtimeError::ConnectionClosed
            | RealtimeError::ConnectionError { .. }
            | RealtimeError::WebSocket(_)
    )
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
        ApiError::Status {
            status: 420 | 429, ..
        } => rate_limited_backend_error(rendered),
        ApiError::Api {
            status: Some(401) | Some(403),
            ..
        } => BackendError::new(ClientErrorCategory::AuthExpired, rendered),
        ApiError::Api {
            status: Some(420) | Some(429),
            ..
        } => rate_limited_backend_error(rendered),
        ApiError::Api { ref error, .. } if is_rate_limit_error_name(error) => {
            rate_limited_backend_error(rendered)
        }
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

fn rate_limited_backend_error(message: String) -> BackendError {
    let retry_after_seconds = retry_after_seconds_from_message(&message);
    let error = BackendError::new(ClientErrorCategory::RateLimited, message);
    match retry_after_seconds {
        Some(seconds) => error.with_retry_after_seconds(seconds),
        None => error,
    }
}

fn is_rate_limit_error_name(name: &str) -> bool {
    matches!(
        name.trim().to_ascii_uppercase().as_str(),
        "RATE_LIMIT" | "RATE_LIMITED" | "FLOOD_WAIT"
    )
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

fn input_peer_for_sync_bucket_peer(peer: crate::SyncBucketPeer) -> proto::InputPeer {
    let r#type = match peer {
        crate::SyncBucketPeer::User { user_id } => {
            proto::input_peer::Type::User(proto::InputPeerUser {
                user_id: user_id.get(),
            })
        }
        crate::SyncBucketPeer::Chat { chat_id } => {
            proto::input_peer::Type::Chat(proto::InputPeerChat {
                chat_id: chat_id.get(),
            })
        }
    };
    proto::InputPeer {
        r#type: Some(r#type),
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

fn reaction_snapshot_from_proto_message(
    message: &proto::Message,
    fallback_chat_id: Option<InlineId>,
) -> Option<Vec<StoredReaction>> {
    let snapshot = message.reactions.as_ref()?;
    let chat_id = if message.chat_id != 0 {
        InlineId::new(message.chat_id)
    } else if let Some(peer) = &message.peer_id {
        chat_id_from_peer(peer).unwrap_or_else(|| fallback_chat_id.unwrap_or(InlineId::new(0)))
    } else {
        fallback_chat_id.unwrap_or(InlineId::new(0))
    };
    Some(
        snapshot
            .reactions
            .iter()
            .filter(|reaction| !reaction.emoji.trim().is_empty())
            .map(|reaction| StoredReaction {
                chat_id: if reaction.chat_id != 0 {
                    InlineId::new(reaction.chat_id)
                } else {
                    chat_id
                },
                message_id: if reaction.message_id != 0 {
                    InlineId::new(reaction.message_id)
                } else {
                    InlineId::new(message.id)
                },
                user_id: InlineId::new(reaction.user_id),
                reaction: reaction.emoji.clone(),
            })
            .collect(),
    )
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
            state: None,
            failure: None,
        },
        transaction.chat_id.unwrap_or(fallback_chat_id),
        message_id,
        None,
        transaction.state,
        transaction.failure,
    )
}

fn stored_transaction_needs_retry(transaction: &StoredTransaction) -> bool {
    match transaction.state {
        TransactionState::Queued | TransactionState::Sent | TransactionState::Acked => true,
        TransactionState::Failed => transaction
            .failure
            .as_ref()
            .is_some_and(|failure| retryable_transaction_category(failure.category)),
        TransactionState::Completed | TransactionState::Cancelled => false,
    }
}

fn retryable_transaction_category(category: ClientErrorCategory) -> bool {
    matches!(
        category,
        ClientErrorCategory::AuthRequired
            | ClientErrorCategory::AuthExpired
            | ClientErrorCategory::ReloginRequired
            | ClientErrorCategory::Network
            | ClientErrorCategory::Timeout
            | ClientErrorCategory::RateLimited
            | ClientErrorCategory::Internal
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
    use futures_util::{SinkExt, StreamExt};
    use prost::Message;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    use tokio_tungstenite::accept_async;
    use tokio_tungstenite::tungstenite::Message as WsMessage;

    use crate::{
        AuthCredential, AuthToken, ClientBackend, ClientStatus, DialogRecord, DialogsRequest,
        ExternalId, FakeRealtimeConnector, HistoryRequest, InlineClient, InlineId, RandomId,
        SendTextRequest, StoredTransaction,
    };

    use super::*;

    fn connect_request() -> ConnectRequest {
        ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new("secret-token").unwrap(),
        })
        .with_account_namespace("team")
    }

    fn test_message_record(message_id: i64) -> MessageRecord {
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

    #[test]
    fn proto_message_reaction_snapshot_preserves_complete_empty_and_nonempty_sets() {
        let mut message = proto::Message {
            id: 11,
            chat_id: 7,
            reactions: Some(proto::MessageReactions { reactions: vec![] }),
            ..Default::default()
        };
        assert_eq!(
            reaction_snapshot_from_proto_message(&message, None),
            Some(Vec::new())
        );

        message.reactions = Some(proto::MessageReactions {
            reactions: vec![proto::Reaction {
                emoji: "👍".to_owned(),
                user_id: 2,
                message_id: 11,
                chat_id: 7,
                ..Default::default()
            }],
        });
        assert_eq!(
            reaction_snapshot_from_proto_message(&message, None),
            Some(vec![StoredReaction {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(11),
                user_id: InlineId::new(2),
                reaction: "👍".to_owned(),
            }])
        );
    }

    #[tokio::test]
    async fn live_dialog_merge_preserves_chats_omitted_by_visibility_filter() {
        let store = InMemoryStore::new();
        store
            .record_dialog(DialogRecord::new(InlineId::new(7)))
            .await
            .unwrap();
        let mut hidden_dialog = DialogRecord::new(InlineId::new(8));
        hidden_dialog.chat_list_hidden = Some(true);
        store.record_dialog(hidden_dialog).await.unwrap();
        let removed_message = MessageRecord {
            chat_id: InlineId::new(8),
            ..test_message_record(10)
        };
        store.record_message(removed_message.clone()).await.unwrap();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();

        backend
            .merge_live_dialogs(vec![DialogRecord::new(InlineId::new(7))])
            .await
            .unwrap();

        assert!(store.deleted_chat_ids().await.unwrap().is_empty());
        assert!(
            store
                .deleted_message_ids(InlineId::new(8))
                .await
                .unwrap()
                .is_empty()
        );
        let preserved = store.dialog(InlineId::new(8)).await.unwrap().unwrap();
        assert_eq!(preserved.chat_list_hidden, Some(true));
        assert_eq!(
            store
                .history(HistoryRequest {
                    chat_id: InlineId::new(8),
                    limit: None,
                    before_message_id: None,
                    after_message_id: None,
                })
                .await
                .unwrap()
                .messages,
            vec![removed_message]
        );
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
    async fn released_event_delivery_claim_can_be_replayed_without_restart() {
        let store = InMemoryStore::new();
        let event = ClientEvent::MessageDeleted {
            chat_id: InlineId::new(7),
            message_id: InlineId::new(11),
        };
        store
            .append_client_events(vec![event.clone()])
            .await
            .unwrap();
        let backend = SdkBackend::builder().store(store).build().unwrap();

        let first = backend.receive_event_deliveries().await.unwrap();
        let delivery_id = first[0].delivery_id.unwrap();
        backend.release_event_delivery(delivery_id);
        let replayed = backend.receive_event_deliveries().await.unwrap();

        assert_eq!(replayed[0].delivery_id, Some(delivery_id));
        assert_eq!(replayed[0].event, event);
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
    async fn live_dialog_failure_does_not_masquerade_as_cached_success() {
        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        store.upsert_dialog(DialogRecord {
            chat_id: InlineId::new(9),
            peer_user_id: Some(InlineId::new(10)),
            title: Some("general".to_owned()),
            last_message_id: None,
            synced_through_message_id: None,
            unread_count: Some(0),
            ..DialogRecord::new(InlineId::new(9))
        });
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_url("not-a-websocket-url")
            .build()
            .unwrap();

        backend.connect(connect_request()).await.unwrap();
        let error = backend
            .dialogs(DialogsRequest::default())
            .await
            .unwrap_err();
        assert_eq!(error.category, ClientErrorCategory::InvalidInput);
        let dialogs = backend
            .cached_dialogs(DialogsRequest::default())
            .await
            .unwrap();

        assert_eq!(dialogs.dialogs.len(), 1);
        assert_eq!(dialogs.dialogs[0].chat_id, InlineId::new(9));
    }

    #[tokio::test]
    async fn cached_dialogs_reads_durable_state_without_session_or_network() {
        let store = InMemoryStore::new();
        store
            .record_dialog(DialogRecord {
                title: Some("cached".to_owned()),
                ..DialogRecord::new(InlineId::new(9))
            })
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_url("not-a-websocket-url")
            .build()
            .unwrap();

        let dialogs = backend
            .cached_dialogs(DialogsRequest::default())
            .await
            .unwrap();

        assert_eq!(dialogs.dialogs.len(), 1);
        assert_eq!(dialogs.dialogs[0].title.as_deref(), Some("cached"));
    }

    #[tokio::test]
    async fn live_participant_failure_does_not_fall_back_to_cached_snapshot() {
        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_url("not-a-websocket-url")
            .build()
            .unwrap();
        let request = ChatParticipantsRequest {
            chat_id: InlineId::new(7),
        };

        assert!(backend.chat_participants(request.clone()).await.is_err());

        store
            .record_chat_participants(
                InlineId::new(7),
                vec![ChatParticipantRecord {
                    user_id: InlineId::new(42),
                    date: Some(10),
                }],
            )
            .await
            .unwrap();
        assert!(backend.chat_participants(request).await.is_err());
        let cached = backend.chat_state(InlineId::new(7)).await.unwrap();
        assert_eq!(cached.participants.len(), 1);
        assert_eq!(cached.participants[0].user_id, InlineId::new(42));
    }

    #[tokio::test]
    async fn live_history_failure_does_not_masquerade_as_cached_success() {
        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        store
            .record_message(MessageRecord {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(11),
                sender_id: InlineId::new(42),
                timestamp: 100,
                is_outgoing: false,
                content: MessageContent::Text {
                    text: "cached".to_owned(),
                },
                reply_to_message_id: None,
                transaction: None,
            })
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_url("not-a-websocket-url")
            .build()
            .unwrap();
        let request = HistoryRequest {
            chat_id: InlineId::new(7),
            limit: Some(10),
            before_message_id: None,
            after_message_id: None,
        };

        let error = backend.history(request.clone()).await.unwrap_err();
        assert_eq!(error.category, ClientErrorCategory::InvalidInput);
        let cached = backend.cached_history(request).await.unwrap();
        assert_eq!(cached.messages.len(), 1);
        assert_eq!(cached.messages[0].message_id, InlineId::new(11));
    }

    #[tokio::test]
    async fn sdk_backend_clears_account_data_when_namespace_changes_or_logs_out() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api_addr = listener.local_addr().unwrap();
        let logout_server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = vec![0; 4096];
            let read = stream.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(&request[..read]);
            assert!(request.starts_with("POST /v1/logout HTTP/1.1"));
            assert!(request.contains("authorization: Bearer secret-token"));
            let body = r#"{"ok":true,"result":null}"#;
            stream
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
        });
        let store = InMemoryStore::new();
        store
            .save_session(StoredSession {
                auth: AuthCredential::AccessToken {
                    token: AuthToken::try_new("old-token").unwrap(),
                },
                account_namespace: Some("old-account".to_owned()),
            })
            .await
            .unwrap();
        store
            .record_dialog(DialogRecord::new(InlineId::new(9)))
            .await
            .unwrap();
        store
            .save_sync_bucket_state(
                crate::SyncBucketKey::User,
                crate::SyncBucketState { seq: 9, date: 9 },
            )
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .api_base_url(format!("http://{api_addr}/v1"))
            .store(store.clone())
            .build()
            .unwrap();

        backend.connect(connect_request()).await.unwrap();

        assert!(store.dialog(InlineId::new(9)).await.unwrap().is_none());
        assert_eq!(
            store
                .sync_bucket_state(crate::SyncBucketKey::User)
                .await
                .unwrap(),
            crate::SyncBucketState::default()
        );
        assert_eq!(
            store
                .load_session()
                .await
                .unwrap()
                .unwrap()
                .account_namespace
                .as_deref(),
            Some("team")
        );

        store
            .record_dialog(DialogRecord::new(InlineId::new(10)))
            .await
            .unwrap();
        backend.logout().await.unwrap();
        logout_server.await.unwrap();
        assert!(store.load_session().await.unwrap().is_none());
        assert!(store.dialog(InlineId::new(10)).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn sdk_backend_reuses_realtime_connection_for_multiple_rpc_calls() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();

            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let get_chats = read_test_client_message(&mut ws).await;
            match &get_chats.body {
                Some(proto::client_message::Body::RpcCall(call)) => {
                    assert_eq!(call.method, proto::Method::GetChats as i32);
                }
                other => panic!("expected getChats RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 2,
                    body: Some(proto::server_protocol_message::Body::RpcResult(
                        proto::RpcResult {
                            req_msg_id: get_chats.id,
                            result: Some(proto::rpc_result::Result::GetChats(
                                proto::GetChatsResult::default(),
                            )),
                        },
                    )),
                },
            )
            .await;

            let history = read_test_client_message(&mut ws).await;
            match &history.body {
                Some(proto::client_message::Body::RpcCall(call)) => {
                    assert_eq!(call.method, proto::Method::GetChatHistory as i32);
                }
                other => panic!("expected getChatHistory RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 3,
                    body: Some(proto::server_protocol_message::Body::RpcResult(
                        proto::RpcResult {
                            req_msg_id: history.id,
                            result: Some(proto::rpc_result::Result::GetChatHistory(
                                proto::GetChatHistoryResult::default(),
                            )),
                        },
                    )),
                },
            )
            .await;
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();

        let dialogs = backend.dialogs(DialogsRequest::default()).await.unwrap();
        assert!(dialogs.dialogs.is_empty());
        let history = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            backend.history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(10),
                before_message_id: None,
                after_message_id: None,
            }),
        )
        .await
        .expect("history should use the existing websocket")
        .unwrap();
        assert!(history.messages.is_empty());
        tokio::time::timeout(std::time::Duration::from_secs(3), server)
            .await
            .expect("server should observe both RPCs on one websocket")
            .unwrap();
    }

    #[tokio::test]
    async fn inline_client_runner_allows_concurrent_rpcs_on_one_realtime_session() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let first = read_test_client_message(&mut ws).await;
            let second = tokio::time::timeout(
                std::time::Duration::from_secs(1),
                read_test_client_message(&mut ws),
            )
            .await
            .expect("runner should issue the second RPC before the first completes");
            for (id, request) in [(2, first), (3, second)] {
                send_test_server_message(
                    &mut ws,
                    rpc_result_message(
                        id,
                        request.id,
                        proto::rpc_result::Result::GetChats(proto::GetChatsResult::default()),
                    ),
                )
                .await;
            }
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();
        let client = InlineClient::builder()
            .backend(backend)
            .initial_status(ClientStatus::Connected)
            .build()
            .spawn();

        let (first, second) = tokio::join!(
            client.dialogs(DialogsRequest::default()),
            client.dialogs(DialogsRequest::default())
        );
        assert!(first.unwrap().dialogs.is_empty());
        assert!(second.unwrap().dialogs.is_empty());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn inline_client_runner_bounds_in_flight_rpcs() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let first = read_test_client_message(&mut ws).await;
            assert!(
                tokio::time::timeout(
                    std::time::Duration::from_millis(50),
                    read_test_client_message(&mut ws),
                )
                .await
                .is_err(),
                "runner issued a second RPC above its configured in-flight limit"
            );
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    2,
                    first.id,
                    proto::rpc_result::Result::GetChats(proto::GetChatsResult::default()),
                ),
            )
            .await;

            let second = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    3,
                    second.id,
                    proto::rpc_result::Result::GetChats(proto::GetChatsResult::default()),
                ),
            )
            .await;
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        let backend = SdkBackend::builder()
            .store(store)
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();
        let client = InlineClient::builder()
            .backend(backend)
            .initial_status(ClientStatus::Connected)
            .max_concurrent_requests(1)
            .build()
            .spawn();

        let (first, second) = tokio::join!(
            client.dialogs(DialogsRequest::default()),
            client.dialogs(DialogsRequest::default())
        );
        assert!(first.unwrap().dialogs.is_empty());
        assert!(second.unwrap().dialogs.is_empty());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn chat_management_rpcs_use_one_session_and_commit_durable_state() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();

            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let add = read_test_client_message(&mut ws).await;
            match &add.body {
                Some(proto::client_message::Body::RpcCall(call)) => match &call.input {
                    Some(proto::rpc_call::Input::AddChatParticipant(input)) => {
                        assert_eq!((input.chat_id, input.user_id), (7, Some(42)));
                    }
                    other => panic!("expected add participant input, got {other:?}"),
                },
                other => panic!("expected add participant RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    2,
                    add.id,
                    proto::rpc_result::Result::AddChatParticipant(
                        proto::AddChatParticipantResult {
                            participant: Some(proto::ChatParticipant {
                                user_id: 42,
                                date: 123,
                            }),
                            ..Default::default()
                        },
                    ),
                ),
            )
            .await;

            let remove = read_test_client_message(&mut ws).await;
            match &remove.body {
                Some(proto::client_message::Body::RpcCall(call)) => match &call.input {
                    Some(proto::rpc_call::Input::RemoveChatParticipant(input)) => {
                        assert_eq!((input.chat_id, input.user_id), (7, Some(42)));
                    }
                    other => panic!("expected remove participant input, got {other:?}"),
                },
                other => panic!("expected remove participant RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    3,
                    remove.id,
                    proto::rpc_result::Result::RemoveChatParticipant(
                        proto::RemoveChatParticipantResult {},
                    ),
                ),
            )
            .await;

            let update = read_test_client_message(&mut ws).await;
            match &update.body {
                Some(proto::client_message::Body::RpcCall(call)) => match &call.input {
                    Some(proto::rpc_call::Input::UpdateChatInfo(input)) => {
                        assert_eq!(input.chat_id, 7);
                        assert_eq!(input.title.as_deref(), Some("Renamed"));
                        assert_eq!(input.emoji.as_deref(), Some("✨"));
                    }
                    other => panic!("expected update chat info input, got {other:?}"),
                },
                other => panic!("expected update chat info RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    4,
                    update.id,
                    proto::rpc_result::Result::UpdateChatInfo(proto::UpdateChatInfoResult {
                        chat: Some(proto::Chat {
                            id: 7,
                            title: "Renamed".to_owned(),
                            emoji: Some("✨".to_owned()),
                            ..Default::default()
                        }),
                    }),
                ),
            )
            .await;

            let mark = read_test_client_message(&mut ws).await;
            match &mark.body {
                Some(proto::client_message::Body::RpcCall(call)) => match &call.input {
                    Some(proto::rpc_call::Input::MarkAsUnread(input)) => {
                        assert_eq!(
                            test_chat_id_from_input_peer(input.peer_id.as_ref()),
                            Some(7)
                        );
                    }
                    other => panic!("expected mark unread input, got {other:?}"),
                },
                other => panic!("expected mark unread RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    5,
                    mark.id,
                    proto::rpc_result::Result::MarkAsUnread(proto::MarkAsUnreadResult::default()),
                ),
            )
            .await;

            let clear_mark = read_test_client_message(&mut ws).await;
            match &clear_mark.body {
                Some(proto::client_message::Body::RpcCall(call)) => match &call.input {
                    Some(proto::rpc_call::Input::ReadMessages(input)) => {
                        assert_eq!(
                            test_chat_id_from_input_peer(input.peer_id.as_ref()),
                            Some(7)
                        );
                        assert_eq!(input.max_id, None);
                    }
                    other => panic!("expected read messages input, got {other:?}"),
                },
                other => panic!("expected read messages RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    7,
                    clear_mark.id,
                    proto::rpc_result::Result::ReadMessages(proto::ReadMessagesResult::default()),
                ),
            )
            .await;

            let notifications = read_test_client_message(&mut ws).await;
            match &notifications.body {
                Some(proto::client_message::Body::RpcCall(call)) => match &call.input {
                    Some(proto::rpc_call::Input::UpdateDialogNotificationSettings(input)) => {
                        assert_eq!(
                            test_chat_id_from_input_peer(input.peer_id.as_ref()),
                            Some(7)
                        );
                        assert_eq!(
                            input
                                .notification_settings
                                .as_ref()
                                .and_then(|settings| settings.mode),
                            Some(proto::dialog_notification_settings::Mode::None as i32)
                        );
                    }
                    other => panic!("expected notification settings input, got {other:?}"),
                },
                other => panic!("expected notification settings RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    7,
                    notifications.id,
                    proto::rpc_result::Result::UpdateDialogNotificationSettings(
                        proto::UpdateDialogNotificationSettingsResult::default(),
                    ),
                ),
            )
            .await;

            let delete = read_test_client_message(&mut ws).await;
            match &delete.body {
                Some(proto::client_message::Body::RpcCall(call)) => match &call.input {
                    Some(proto::rpc_call::Input::DeleteChat(input)) => {
                        assert_eq!(
                            test_chat_id_from_input_peer(input.peer_id.as_ref()),
                            Some(7)
                        );
                    }
                    other => panic!("expected delete chat input, got {other:?}"),
                },
                other => panic!("expected delete chat RPC, got {other:?}"),
            }
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    8,
                    delete.id,
                    proto::rpc_result::Result::DeleteChat(proto::DeleteChatResult {}),
                ),
            )
            .await;
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        store
            .record_dialog(DialogRecord::new(InlineId::new(7)))
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();

        backend
            .add_chat_participant(AddChatParticipantRequest {
                chat_id: InlineId::new(7),
                user_id: InlineId::new(42),
            })
            .await
            .unwrap();
        assert_eq!(
            store
                .chat_participants(InlineId::new(7))
                .await
                .unwrap()
                .len(),
            1
        );
        backend
            .remove_chat_participant(RemoveChatParticipantRequest {
                chat_id: InlineId::new(7),
                user_id: InlineId::new(42),
            })
            .await
            .unwrap();
        assert!(
            store
                .chat_participants(InlineId::new(7))
                .await
                .unwrap()
                .is_empty()
        );
        backend
            .update_chat_info(UpdateChatInfoRequest {
                chat_id: InlineId::new(7),
                title: Some(" Renamed ".to_owned()),
                emoji: Some(" ✨ ".to_owned()),
            })
            .await
            .unwrap();
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .title
                .as_deref(),
            Some("Renamed")
        );
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .emoji
                .as_deref(),
            Some("✨")
        );
        backend
            .set_marked_unread(SetMarkedUnreadRequest {
                chat_id: InlineId::new(7),
                unread: true,
            })
            .await
            .unwrap();
        backend
            .set_marked_unread(SetMarkedUnreadRequest {
                chat_id: InlineId::new(7),
                unread: false,
            })
            .await
            .unwrap();
        backend
            .update_dialog_notifications(UpdateDialogNotificationsRequest {
                chat_id: InlineId::new(7),
                mode: Some(DialogNotificationMode::None),
            })
            .await
            .unwrap();
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .notification_mode,
            Some(DialogNotificationMode::None)
        );
        backend
            .delete_chat(DeleteChatRequest {
                chat_id: InlineId::new(7),
            })
            .await
            .unwrap();
        assert_eq!(
            store.deleted_chat_ids().await.unwrap(),
            vec![InlineId::new(7)]
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn sdk_backend_recovers_hint_only_updates_on_the_multiplexed_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let state = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    2,
                    state.id,
                    proto::rpc_result::Result::GetUpdatesState(proto::GetUpdatesStateResult {
                        date: 100,
                        updates_found: Some(true),
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                    }),
                ),
            )
            .await;

            let user_bucket = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    3,
                    user_bucket.id,
                    proto::rpc_result::Result::GetUpdates(proto::GetUpdatesResult {
                        updates: Vec::new(),
                        seq: 1,
                        date: 100,
                        r#final: Some(true),
                        result_type: proto::get_updates_result::ResultType::Empty as i32,
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                        ..Default::default()
                    }),
                ),
            )
            .await;

            let peer = proto::Peer {
                r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 7 })),
            };
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 10,
                    body: Some(proto::server_protocol_message::Body::Message(
                        proto::ServerMessage {
                            payload: Some(proto::server_message::Payload::Update(
                                proto::UpdatesPayload {
                                    updates: vec![proto::Update {
                                        seq: None,
                                        date: None,
                                        update: Some(proto::update::Update::ChatHasNewUpdates(
                                            proto::UpdateChatHasNewUpdates {
                                                chat_id: 7,
                                                update_seq: 2,
                                                peer_id: Some(peer.clone()),
                                            },
                                        )),
                                    }],
                                },
                            )),
                        },
                    )),
                },
            )
            .await;
            let ack = read_test_client_message(&mut ws).await;
            assert!(matches!(
                ack.body,
                Some(proto::client_message::Body::Ack(proto::Ack { msg_id: 10 }))
            ));

            let chat_bucket = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    4,
                    chat_bucket.id,
                    proto::rpc_result::Result::GetUpdates(proto::GetUpdatesResult {
                        updates: vec![proto::Update {
                            seq: Some(2),
                            date: Some(101),
                            update: Some(proto::update::Update::NewMessage(
                                proto::UpdateNewMessage {
                                    message: Some(proto::Message {
                                        id: 11,
                                        from_id: 2,
                                        peer_id: Some(peer),
                                        chat_id: 7,
                                        message: Some("recovered".to_owned()),
                                        date: 101,
                                        ..Default::default()
                                    }),
                                },
                            )),
                        }],
                        seq: 2,
                        date: 101,
                        r#final: Some(true),
                        result_type: proto::get_updates_result::ResultType::Slice as i32,
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                        ..Default::default()
                    }),
                ),
            )
            .await;
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        store
            .save_sync_bucket_state(
                crate::SyncBucketKey::User,
                crate::SyncBucketState { seq: 1, date: 100 },
            )
            .await
            .unwrap();
        store
            .save_sync_bucket_state(
                crate::SyncBucketKey::Chat {
                    peer: crate::SyncBucketPeer::Chat {
                        chat_id: InlineId::new(7),
                    },
                },
                crate::SyncBucketState { seq: 1, date: 100 },
            )
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();

        let events =
            tokio::time::timeout(std::time::Duration::from_secs(3), backend.receive_events())
                .await
                .unwrap()
                .unwrap();

        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::MessageStored { message }
                if message.chat_id == InlineId::new(7)
                    && message.message_id == InlineId::new(11)
        )));
        assert_eq!(
            store
                .sync_bucket_state(crate::SyncBucketKey::Chat {
                    peer: crate::SyncBucketPeer::Chat {
                        chat_id: InlineId::new(7),
                    },
                })
                .await
                .unwrap(),
            crate::SyncBucketState { seq: 2, date: 101 }
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn sdk_backend_repairs_cold_chat_bucket_after_too_long() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let _ = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let state = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    2,
                    state.id,
                    proto::rpc_result::Result::GetUpdatesState(proto::GetUpdatesStateResult {
                        date: 100,
                        updates_found: Some(true),
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                    }),
                ),
            )
            .await;
            let user_bucket = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    3,
                    user_bucket.id,
                    proto::rpc_result::Result::GetUpdates(proto::GetUpdatesResult {
                        updates: Vec::new(),
                        seq: 1,
                        date: 100,
                        r#final: Some(true),
                        result_type: proto::get_updates_result::ResultType::Empty as i32,
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                        ..Default::default()
                    }),
                ),
            )
            .await;

            let peer = proto::Peer {
                r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 7 })),
            };
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 10,
                    body: Some(proto::server_protocol_message::Body::Message(
                        proto::ServerMessage {
                            payload: Some(proto::server_message::Payload::Update(
                                proto::UpdatesPayload {
                                    updates: vec![proto::Update {
                                        seq: None,
                                        date: None,
                                        update: Some(proto::update::Update::ChatHasNewUpdates(
                                            proto::UpdateChatHasNewUpdates {
                                                chat_id: 7,
                                                update_seq: 500,
                                                peer_id: Some(peer.clone()),
                                            },
                                        )),
                                    }],
                                },
                            )),
                        },
                    )),
                },
            )
            .await;
            let _ack = read_test_client_message(&mut ws).await;

            let bucket = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    4,
                    bucket.id,
                    proto::rpc_result::Result::GetUpdates(proto::GetUpdatesResult {
                        updates: Vec::new(),
                        seq: 400,
                        date: 101,
                        r#final: Some(false),
                        result_type: proto::get_updates_result::ResultType::TooLong as i32,
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                        ..Default::default()
                    }),
                ),
            )
            .await;

            let get_chat = read_test_client_message(&mut ws).await;
            assert!(matches!(
                &get_chat.body,
                Some(proto::client_message::Body::RpcCall(proto::RpcCall {
                    method,
                    input: Some(proto::rpc_call::Input::GetChat(_)),
                })) if *method == proto::Method::GetChat as i32
            ));
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    5,
                    get_chat.id,
                    proto::rpc_result::Result::GetChat(proto::GetChatResult {
                        chat: Some(proto::Chat {
                            id: 7,
                            title: "Repaired".to_owned(),
                            peer_id: Some(peer.clone()),
                            ..Default::default()
                        }),
                        dialog: Some(proto::Dialog {
                            chat_id: Some(7),
                            peer: Some(peer.clone()),
                            ..Default::default()
                        }),
                        pinned_message_ids: vec![11],
                        anchor_message: None,
                    }),
                ),
            )
            .await;

            let participants = read_test_client_message(&mut ws).await;
            assert!(matches!(
                &participants.body,
                Some(proto::client_message::Body::RpcCall(proto::RpcCall {
                    method,
                    input: Some(proto::rpc_call::Input::GetChatParticipants(_)),
                })) if *method == proto::Method::GetChatParticipants as i32
            ));
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    6,
                    participants.id,
                    proto::rpc_result::Result::GetChatParticipants(
                        proto::GetChatParticipantsResult::default(),
                    ),
                ),
            )
            .await;

            let history = read_test_client_message(&mut ws).await;
            assert!(matches!(
                &history.body,
                Some(proto::client_message::Body::RpcCall(proto::RpcCall {
                    method,
                    input: Some(proto::rpc_call::Input::GetChatHistory(_)),
                })) if *method == proto::Method::GetChatHistory as i32
            ));
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    6,
                    history.id,
                    proto::rpc_result::Result::GetChatHistory(proto::GetChatHistoryResult {
                        messages: vec![proto::Message {
                            id: 11,
                            chat_id: 7,
                            peer_id: Some(peer),
                            message: Some("snapshot".to_owned()),
                            date: 101,
                            ..Default::default()
                        }],
                    }),
                ),
            )
            .await;

            let remaining = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    7,
                    remaining.id,
                    proto::rpc_result::Result::GetUpdates(proto::GetUpdatesResult {
                        updates: Vec::new(),
                        seq: 500,
                        date: 102,
                        r#final: Some(true),
                        result_type: proto::get_updates_result::ResultType::Empty as i32,
                        skipped_sequences: (401..=500)
                            .map(|seq| proto::SyncSkippedSequence {
                                seq,
                                reason: proto::sync_skipped_sequence::Reason::IrrelevantToBucket
                                    as i32,
                            })
                            .collect(),
                        core_sync_schema_revision: crate::CORE_SYNC_SCHEMA_REVISION,
                        ..Default::default()
                    }),
                ),
            )
            .await;
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        store
            .save_sync_bucket_state(
                crate::SyncBucketKey::User,
                crate::SyncBucketState { seq: 1, date: 100 },
            )
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();

        let events =
            tokio::time::timeout(std::time::Duration::from_secs(3), backend.receive_events())
                .await
                .unwrap()
                .unwrap();

        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::MessageStored { message } if message.message_id == InlineId::new(11)
        )));
        let dialog = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
        assert_eq!(dialog.title.as_deref(), Some("Repaired"));
        assert_eq!(dialog.pinned_message_ids, vec![InlineId::new(11)]);
        assert_eq!(
            store
                .sync_bucket_state(crate::SyncBucketKey::Chat {
                    peer: crate::SyncBucketPeer::Chat {
                        chat_id: InlineId::new(7),
                    },
                })
                .await
                .unwrap(),
            crate::SyncBucketState {
                seq: 500,
                date: 102
            }
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn sdk_backend_user_snapshot_rebuilds_authoritative_account_state() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let chats = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    2,
                    chats.id,
                    proto::rpc_result::Result::GetChats(proto::GetChatsResult::default()),
                ),
            )
            .await;
            let me = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    3,
                    me.id,
                    proto::rpc_result::Result::GetMe(proto::GetMeResult {
                        user: Some(proto::User {
                            id: 42,
                            first_name: Some("Ada".to_owned()),
                            ..Default::default()
                        }),
                    }),
                ),
            )
            .await;
            let settings = read_test_client_message(&mut ws).await;
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    4,
                    settings.id,
                    proto::rpc_result::Result::GetUserSettings(proto::GetUserSettingsResult {
                        user_settings: Some(proto::UserSettings::default()),
                    }),
                ),
            )
            .await;
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        store
            .record_dialog(DialogRecord::new(InlineId::new(7)))
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();

        let events = backend.repair_user_bucket().await.unwrap();

        assert!(!events.iter().any(|event| matches!(
            event,
            ClientEvent::ChatDeleted { chat_id } if *chat_id == InlineId::new(7)
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::UserUpserted { user_id } if *user_id == InlineId::new(42)
        )));
        assert!(
            events
                .iter()
                .any(|event| matches!(event, ClientEvent::UserSettingsChanged {}))
        );
        assert!(store.deleted_chat_ids().await.unwrap().is_empty());
        assert!(store.dialog(InlineId::new(7)).await.unwrap().is_some());
        assert!(store.user_settings().await.unwrap().is_some());
        server.await.unwrap();
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
                order: DialogsOrder::RecentActivity,
            },
        )
        .unwrap();

        assert_eq!(page.dialogs.len(), 1);
        assert_eq!(page.dialogs[0].chat_id, InlineId::new(7));
        assert_eq!(page.dialogs[0].title.as_deref(), Some("Ada Lovelace"));
        assert_eq!(page.dialogs[0].emoji.as_deref(), Some("*"));
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
            ..Default::default()
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

    #[tokio::test]
    async fn sdk_backend_retries_uncertain_stored_send_with_same_random_id() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = accept_async(stream).await.unwrap();
            let init = read_test_client_message(&mut ws).await;
            assert!(matches!(
                init.body,
                Some(proto::client_message::Body::ConnectionInit(_))
            ));
            send_test_server_message(
                &mut ws,
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen {},
                    )),
                },
            )
            .await;

            let send = read_test_client_message(&mut ws).await;
            let input = match &send.body {
                Some(proto::client_message::Body::RpcCall(proto::RpcCall {
                    method,
                    input: Some(proto::rpc_call::Input::SendMessage(input)),
                })) if *method == proto::Method::SendMessage as i32 => input,
                other => panic!("expected sendMessage retry, got {other:?}"),
            };
            assert_eq!(input.random_id, Some(99));
            send_test_server_message(
                &mut ws,
                rpc_result_message(
                    2,
                    send.id,
                    proto::rpc_result::Result::SendMessage(proto::SendMessageResult {
                        updates: vec![proto::Update {
                            seq: None,
                            date: None,
                            update: Some(proto::update::Update::UpdateMessageId(
                                proto::UpdateMessageId {
                                    message_id: 11,
                                    random_id: 99,
                                },
                            )),
                        }],
                    }),
                ),
            )
            .await;
        });

        let store = InMemoryStore::new();
        store.save_session(connect_session()).await.unwrap();
        let request = SendTextRequest {
            peer: crate::PeerRef::Chat {
                chat_id: InlineId::new(7),
            },
            text: "hello".to_owned(),
            external_id: Some(ExternalId::try_new("host-event", "event-1").unwrap()),
            random_id: Some(RandomId::new(99)),
            reply_to_message_id: None,
        };
        let transaction_id = transaction_id_for_send(&request, RandomId::new(99));
        let identity = TransactionIdentity::new(
            transaction_id.clone(),
            request.external_id.clone(),
            RandomId::new(99),
        );
        store
            .record_transaction(
                StoredTransaction::new(identity, TransactionState::Sent)
                    .with_chat_id(InlineId::new(7))
                    .with_failure(crate::ClientFailure::new(
                        ClientErrorCategory::Timeout,
                        "send result timed out",
                    )),
            )
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .store(store.clone())
            .realtime_url(format!("ws://{addr}/realtime"))
            .without_realtime_handshake()
            .build()
            .unwrap();

        let outcome = backend.send_text(request).await.unwrap();

        assert_eq!(outcome.state, TransactionState::Completed);
        assert_eq!(outcome.message_id, Some(InlineId::new(11)));
        assert_eq!(outcome.mutation.transaction.transaction_id, transaction_id);
        assert_eq!(
            store
                .transaction(transaction_id)
                .await
                .unwrap()
                .unwrap()
                .state,
            TransactionState::Completed
        );
        server.await.unwrap();
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
    fn history_input_for_before_message_id_uses_offset_id() {
        let input = history_input_for_request(
            &HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(20),
                before_message_id: Some(InlineId::new(30)),
                after_message_id: None,
            },
            21,
        );

        assert_eq!(input.offset_id, Some(30));
        assert_eq!(input.mode, None);
        assert_eq!(input.after_id, None);
        assert_eq!(input.limit, Some(21));
    }

    #[test]
    fn normalize_live_history_latest_keeps_newest_messages() {
        let records = (1..=4).rev().map(test_message_record).collect::<Vec<_>>();

        let (records, has_more) = crate::store::select_history_window(records, 3, None, None);

        assert!(has_more);
        assert_eq!(
            records
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(2), InlineId::new(3), InlineId::new(4)]
        );
    }

    #[test]
    fn normalize_live_history_newer_keeps_oldest_checkpoint_window() {
        let records = vec![
            test_message_record(8),
            test_message_record(7),
            test_message_record(6),
            test_message_record(5),
        ];

        let (records, has_more) =
            crate::store::select_history_window(records, 3, None, Some(InlineId::new(4)));

        assert!(has_more);
        assert_eq!(
            records
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(5), InlineId::new(6), InlineId::new(7)]
        );
    }

    #[test]
    fn normalize_live_history_older_keeps_newest_messages_below_cursor() {
        let records = vec![
            test_message_record(3),
            test_message_record(2),
            test_message_record(1),
        ];

        let (records, has_more) =
            crate::store::select_history_window(records, 2, Some(InlineId::new(4)), None);

        assert!(has_more);
        assert_eq!(
            records
                .iter()
                .map(|message| message.message_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(2), InlineId::new(3)]
        );
    }

    #[test]
    fn history_window_membership_uses_message_id_before_timestamp_ordering() {
        let mut records = (1..=4).map(test_message_record).collect::<Vec<_>>();
        records[0].timestamp = 10_000;
        records[3].timestamp = 1;

        let (latest, latest_has_more) =
            crate::store::select_history_window(records.clone(), 3, None, None);
        let (older, older_has_more) =
            crate::store::select_history_window(records, 2, Some(InlineId::new(4)), None);

        assert!(latest_has_more);
        assert_eq!(
            latest
                .iter()
                .map(|message| message.message_id.get())
                .collect::<Vec<_>>(),
            vec![4, 2, 3]
        );
        assert!(older_has_more);
        assert_eq!(
            older
                .iter()
                .map(|message| message.message_id.get())
                .collect::<Vec<_>>(),
            vec![2, 3]
        );
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
                        service_message: None,
                    }),
                })),
            }],
        };

        let applied = apply_send_message_updates(&request, identity, InlineId::new(7), result);

        assert_eq!(applied.message_id, Some(InlineId::new(11)));
        assert_eq!(applied.transaction.state, TransactionState::Completed);
        assert_eq!(applied.message.unwrap().message_id, InlineId::new(11));
    }

    #[tokio::test]
    async fn apply_updates_persists_lossless_message_state_before_emitting() {
        let store = InMemoryStore::new();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
        let peer = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 7 })),
        };
        let updates = vec![
            proto::Update {
                seq: Some(1),
                date: Some(10),
                update: Some(proto::update::Update::NewMessage(proto::UpdateNewMessage {
                    message: Some(proto::Message {
                        id: 11,
                        from_id: 2,
                        peer_id: Some(peer.clone()),
                        chat_id: 7,
                        message: Some("hello".to_owned()),
                        date: 10,
                        ..Default::default()
                    }),
                })),
            },
            proto::Update {
                seq: Some(2),
                date: Some(11),
                update: Some(proto::update::Update::UpdateReaction(
                    proto::UpdateReaction {
                        reaction: Some(proto::Reaction {
                            emoji: "👍".to_owned(),
                            user_id: 2,
                            message_id: 11,
                            chat_id: 7,
                            date: 11,
                        }),
                    },
                )),
            },
            proto::Update {
                seq: Some(3),
                date: Some(12),
                update: Some(proto::update::Update::UpdateReadMaxId(
                    proto::UpdateReadMaxId {
                        peer_id: Some(peer.clone()),
                        read_max_id: 11,
                        unread_count: 1,
                    },
                )),
            },
            proto::Update {
                seq: Some(4),
                date: Some(13),
                update: Some(proto::update::Update::ParticipantAdd(
                    proto::UpdateChatParticipantAdd {
                        chat_id: 7,
                        participant: Some(proto::ChatParticipant {
                            user_id: 2,
                            date: 13,
                        }),
                    },
                )),
            },
            proto::Update {
                seq: Some(5),
                date: Some(14),
                update: Some(proto::update::Update::DeleteReaction(
                    proto::UpdateDeleteReaction {
                        emoji: "👍".to_owned(),
                        chat_id: 7,
                        message_id: 11,
                        user_id: 2,
                    },
                )),
            },
            proto::Update {
                seq: Some(6),
                date: Some(15),
                update: Some(proto::update::Update::DeleteMessages(
                    proto::UpdateDeleteMessages {
                        message_ids: vec![11],
                        peer_id: Some(peer),
                    },
                )),
            },
        ];

        let events = backend.apply_updates(updates, None, None).await.unwrap();

        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::MessageDeleted { chat_id, message_id }
                if *chat_id == InlineId::new(7) && *message_id == InlineId::new(11)
        )));
        assert!(
            store
                .message_deleted(InlineId::new(7), InlineId::new(11))
                .await
                .unwrap()
        );
        assert!(
            store
                .reactions(InlineId::new(7), InlineId::new(11))
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store.read_state(InlineId::new(7)).await.unwrap(),
            Some(StoredReadState {
                chat_id: InlineId::new(7),
                read_max_id: Some(InlineId::new(11)),
                unread_count: Some(1),
                marked_unread: false,
            })
        );
        assert_eq!(
            store.chat_participants(InlineId::new(7)).await.unwrap(),
            vec![ChatParticipantRecord {
                user_id: InlineId::new(2),
                date: Some(13),
            }]
        );
    }

    #[tokio::test]
    async fn apply_updates_persists_dialog_metadata_and_attachment_invalidation() {
        let store = InMemoryStore::new();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
        let peer = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 7 })),
        };
        store
            .record_dialog(DialogRecord::new(InlineId::new(7)))
            .await
            .unwrap();
        let updates = vec![
            proto::Update {
                update: Some(proto::update::Update::ChatInfo(proto::UpdateChatInfo {
                    chat_id: 7,
                    title: Some("General".to_owned()),
                    emoji: None,
                    untitled: None,
                })),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::ChatInfo(proto::UpdateChatInfo {
                    chat_id: 7,
                    title: None,
                    emoji: Some("✨".to_owned()),
                    untitled: None,
                })),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::ChatVisibility(
                    proto::UpdateChatVisibility {
                        chat_id: 7,
                        is_public: true,
                    },
                )),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::DialogArchived(
                    proto::UpdateDialogArchived {
                        peer_id: Some(peer.clone()),
                        archived: true,
                    },
                )),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::DialogNotificationSettings(
                    proto::UpdateDialogNotificationSettings {
                        peer_id: Some(peer.clone()),
                        notification_settings: Some(proto::DialogNotificationSettings {
                            mode: Some(proto::dialog_notification_settings::Mode::Mentions as i32),
                        }),
                    },
                )),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::DialogFollowMode(
                    proto::UpdateDialogFollowMode {
                        peer_id: Some(peer.clone()),
                        follow_mode: Some(proto::DialogFollowMode::Following as i32),
                    },
                )),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::PinnedMessages(
                    proto::UpdatePinnedMessages {
                        peer_id: Some(peer.clone()),
                        message_ids: vec![11, 10],
                    },
                )),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::MessageAttachment(
                    proto::UpdateMessageAttachment {
                        attachment: None,
                        message_id: 11,
                        peer_id: Some(peer),
                        chat_id: 7,
                    },
                )),
                ..Default::default()
            },
        ];

        let events = backend.apply_updates(updates, None, None).await.unwrap();
        let dialog = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
        assert_eq!(dialog.title.as_deref(), Some("General"));
        assert_eq!(dialog.emoji.as_deref(), Some("✨"));
        assert_eq!(dialog.is_public, Some(true));
        assert_eq!(dialog.archived, Some(true));
        assert_eq!(
            dialog.notification_mode,
            Some(DialogNotificationMode::Mentions)
        );
        assert_eq!(dialog.follow_mode, Some(DialogFollowMode::Following));
        assert_eq!(
            dialog.pinned_message_ids,
            vec![InlineId::new(11), InlineId::new(10)]
        );
        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::MessageUpserted { chat_id, message_id }
                if *chat_id == InlineId::new(7) && *message_id == InlineId::new(11)
        )));
    }

    #[tokio::test]
    async fn apply_updates_rejects_still_unsupported_lossless_update() {
        let backend = SdkBackend::builder().build().unwrap();
        let update = proto::Update {
            seq: Some(1),
            date: Some(10),
            update: Some(proto::update::Update::ChatHasNewUpdates(
                proto::UpdateChatHasNewUpdates::default(),
            )),
        };

        let error = backend
            .apply_updates(vec![update], None, None)
            .await
            .unwrap_err();

        assert_eq!(error.category, ClientErrorCategory::Unsupported);
        assert!(error.message.contains("chat_has_new_updates"));
    }

    #[tokio::test]
    async fn apply_updates_clears_history_and_applies_reply_thread_side_effects() {
        let store = InMemoryStore::new();
        for chat_id in [7, 8, 9] {
            store
                .record_dialog(DialogRecord::new(InlineId::new(chat_id)))
                .await
                .unwrap();
        }
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
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
        let peer = proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 7 })),
        };
        let update = proto::Update {
            seq: Some(1),
            date: Some(201),
            update: Some(proto::update::Update::ClearChatHistory(
                proto::UpdateClearChatHistory {
                    target: Some(proto::update_clear_chat_history::Target::PeerId(peer)),
                    before_date: Some(150),
                    delete_reply_threads: true,
                    deleted_chat_ids: vec![8],
                    orphaned_chat_ids: vec![9],
                    detached_chat_ids: Vec::new(),
                },
            )),
        };

        let events = backend
            .apply_updates(vec![update], None, None)
            .await
            .unwrap();

        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::ChatHistoryCleared { chat_id, before_date: Some(150) }
                if *chat_id == InlineId::new(7)
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::ChatDeleted { chat_id } if *chat_id == InlineId::new(8)
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::ChatUpserted { chat_id } if *chat_id == InlineId::new(9)
        )));
        assert!(store.dialog(InlineId::new(8)).await.unwrap().is_none());
        let history = store
            .history(HistoryRequest {
                chat_id: InlineId::new(7),
                limit: Some(10),
                before_message_id: None,
                after_message_id: None,
            })
            .await
            .unwrap();
        assert_eq!(history.messages[0].message_id, InlineId::new(11));
    }

    #[tokio::test]
    async fn apply_updates_persists_spaces_members_and_user_settings() {
        let store = InMemoryStore::new();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
        let member = |user_id| proto::Member {
            id: user_id,
            space_id: 5,
            user_id,
            role: Some(proto::member::Role::Member as i32),
            date: 100 + user_id,
            can_access_public_chats: true,
        };
        let updates = vec![
            proto::Update {
                update: Some(proto::update::Update::JoinSpace(proto::UpdateJoinSpace {
                    space: Some(proto::Space {
                        id: 5,
                        name: "Engineering".to_owned(),
                        creator: true,
                        date: 100,
                        is_public: Some(false),
                    }),
                    member: Some(member(2)),
                })),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::SpaceMemberAdd(
                    proto::UpdateSpaceMemberAdd {
                        member: Some(member(3)),
                        user: Some(proto::User {
                            id: 3,
                            first_name: Some("Ada".to_owned()),
                            ..Default::default()
                        }),
                    },
                )),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::SpaceMemberDelete(
                    proto::UpdateSpaceMemberDelete {
                        space_id: 5,
                        user_id: 3,
                    },
                )),
                ..Default::default()
            },
            proto::Update {
                update: Some(proto::update::Update::UpdateUserSettings(
                    proto::UpdateUserSettings {
                        settings: Some(proto::UserSettings {
                            notification_settings: Some(proto::NotificationSettings {
                                mode: Some(proto::notification_settings::Mode::Mentions as i32),
                                silent: Some(true),
                                ..Default::default()
                            }),
                        }),
                    },
                )),
                ..Default::default()
            },
        ];

        let events = backend.apply_updates(updates, None, None).await.unwrap();

        assert_eq!(
            store.space(InlineId::new(5)).await.unwrap().unwrap().name,
            "Engineering"
        );
        assert_eq!(
            store.space_members(InlineId::new(5)).await.unwrap(),
            vec![SpaceMemberRecord {
                space_id: InlineId::new(5),
                user_id: InlineId::new(2),
                role: Some(SpaceMemberRole::Member),
                date: 102,
                can_access_public_chats: true,
            }]
        );
        assert_eq!(
            store
                .user_settings()
                .await
                .unwrap()
                .unwrap()
                .notification_mode,
            Some(NotificationMode::Mentions)
        );
        assert!(events.iter().any(|event| matches!(
            event,
            ClientEvent::SpaceUpserted { space_id } if *space_id == InlineId::new(5)
        )));
        assert!(
            events
                .iter()
                .any(|event| matches!(event, ClientEvent::UserSettingsChanged { .. }))
        );
    }

    #[test]
    fn rest_rate_limit_errors_keep_category_and_retry_hint() {
        let error = api_error_to_backend(ApiError::Status {
            status: 420,
            message: "retry after 23 seconds".to_owned(),
            body: None,
        });

        assert_eq!(error.category, ClientErrorCategory::RateLimited);
        assert_eq!(error.retry_after_seconds, Some(23));
    }

    fn connect_session() -> StoredSession {
        StoredSession {
            auth: AuthCredential::AccessToken {
                token: AuthToken::try_new("secret-token").unwrap(),
            },
            account_namespace: Some("team".to_owned()),
        }
    }

    fn test_chat_id_from_input_peer(peer: Option<&proto::InputPeer>) -> Option<i64> {
        match peer?.r#type.as_ref()? {
            proto::input_peer::Type::Chat(chat) => Some(chat.chat_id),
            proto::input_peer::Type::Self_(_) | proto::input_peer::Type::User(_) => None,
        }
    }

    async fn read_test_client_message(
        ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    ) -> proto::ClientMessage {
        match ws.next().await.unwrap().unwrap() {
            WsMessage::Binary(data) => proto::ClientMessage::decode(&*data).unwrap(),
            other => panic!("expected binary client message, got {other:?}"),
        }
    }

    async fn send_test_server_message(
        ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
        message: proto::ServerProtocolMessage,
    ) {
        ws.send(WsMessage::Binary(message.encode_to_vec().into()))
            .await
            .unwrap();
    }

    fn rpc_result_message(
        id: u64,
        request_id: u64,
        result: proto::rpc_result::Result,
    ) -> proto::ServerProtocolMessage {
        proto::ServerProtocolMessage {
            id,
            body: Some(proto::server_protocol_message::Body::RpcResult(
                proto::RpcResult {
                    req_msg_id: request_id,
                    result: Some(result),
                },
            )),
        }
    }
}

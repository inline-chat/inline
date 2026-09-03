use std::collections::{HashMap, HashSet};
use std::future::Future;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use agent_client_protocol::schema::{ProtocolVersion, v1 as acp};
use agent_client_protocol::{Agent, Client, ConnectTo, ConnectionTo, Responder};
use base64::Engine;
use futures_util::future::{BoxFuture, FutureExt, Shared};
use inline_agent_bridge::{
    AgentDriver, AgentEvent, AgentEventReceiver, AgentEventSender, ApplyTiming, ApprovalDecision,
    ApprovalRequest, AuthenticationRequired, DriverCapabilities, DriverCommand, DriverError,
    DriverFuture, DriverResult, DriverSettingsCatalog, HostToolConfiguration, InputAttachment,
    InputAttachmentKind, OutputAttachment, OutputAttachmentKind, ProviderSessionId, QuestionAnswer,
    ResumeSessionSpec, SessionReplay, SessionSpec, StartedTurn, SteeringSupport, TurnId, TurnInput,
    TurnOptions, TurnOutcome, TurnTiming,
};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio::sync::{oneshot, watch};

use crate::elicitation::{ElicitationField, answer_response, normalize_form};
use crate::host_tools::AcpHostToolProxy;
use crate::mapping::{
    ToolCallSnapshots, available_commands, permission_command, permission_options,
    permission_summary, select_config_id, session_modes, session_update_events, settings_catalog,
    turn_outcome,
};

const CONNECTION_TIMEOUT: Duration = Duration::from_secs(15);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_FINAL_AGENT_TEXT_BYTES: usize = 64 * 1024;
const TRUNCATED_AGENT_TEXT_MARKER: &str = "\n[additional agent output omitted]";
const MAX_PENDING_APPROVALS: usize = 32;
const MAX_PENDING_APPROVALS_PER_SESSION: usize = 8;
const MAX_PENDING_ELICITATIONS: usize = 32;
const MAX_PENDING_ELICITATIONS_PER_SESSION: usize = 8;
const MAX_RETAINED_PERMISSION_OPTIONS: usize = 7;
const MAX_RETAINED_PERMISSION_OPTION_ID_BYTES: usize = 128;
const MAX_RETAINED_PERMISSION_OPTION_LABEL_CHARS: usize = 80;
const MAX_PROVIDER_SESSION_ID_BYTES: usize = 256;
const MAX_NATIVE_PROMPT_MEDIA_BYTES: usize = 20 * 1024 * 1024;
const MAX_NATIVE_OUTPUT_IMAGE_BYTES: usize = 20 * 1024 * 1024;

async fn acp_prompt_blocks(
    input: TurnInput,
    capabilities: &acp::PromptCapabilities,
) -> DriverResult<Vec<acp::ContentBlock>> {
    let mut blocks = vec![acp::ContentBlock::Text(acp::TextContent::new(input.text))];
    for attachment in input.attachments {
        match attachment.kind {
            InputAttachmentKind::Image if capabilities.image => {
                if let Some((data, mime_type, local_uri)) =
                    acp_local_media(&attachment, "image").await?
                {
                    blocks.push(acp::ContentBlock::Image(
                        acp::ImageContent::new(data, mime_type).uri(local_uri),
                    ));
                    // Keep a separate baseline resource link as well. Some ACP
                    // adapters forward image bytes to the selected model but
                    // drop ImageContent.uri; the resource link guarantees the
                    // agent can still use the same local bytes as a file.
                    blocks.push(acp_resource_link(attachment));
                } else {
                    blocks.push(acp_resource_link(attachment));
                }
            }
            InputAttachmentKind::Audio if capabilities.audio => {
                if let Some((data, mime_type, _)) = acp_local_media(&attachment, "audio").await? {
                    blocks.push(acp::ContentBlock::Audio(acp::AudioContent::new(
                        data, mime_type,
                    )));
                    // ACP AudioContent has no URI field. Keep the mandatory
                    // baseline resource link as the host-local file reference.
                    blocks.push(acp_resource_link(attachment));
                } else {
                    blocks.push(acp_resource_link(attachment));
                }
            }
            _ => blocks.push(acp_resource_link(attachment)),
        }
    }
    Ok(blocks)
}

async fn acp_local_media(
    attachment: &InputAttachment,
    expected_top_level_type: &'static str,
) -> DriverResult<Option<(String, String, String)>> {
    let Some(local_uri) = attachment.local_uri.as_deref() else {
        return Ok(None);
    };
    let Some(mime_type) = attachment
        .mime_type
        .as_deref()
        .and_then(normalized_mime_type)
        .filter(|mime_type| mime_type.starts_with(&format!("{expected_top_level_type}/")))
    else {
        return Ok(None);
    };
    let url = url::Url::parse(local_uri).map_err(|_| {
        DriverError::Rejected(format!(
            "ACP local {expected_top_level_type} attachment URL is invalid"
        ))
    })?;
    if url.scheme() != "file" {
        return Err(DriverError::Rejected(format!(
            "ACP local {expected_top_level_type} attachment must use a file URL"
        )));
    }
    let path = url.to_file_path().map_err(|_| {
        DriverError::Rejected(format!(
            "ACP local {expected_top_level_type} attachment path is invalid"
        ))
    })?;
    let metadata = tokio::fs::symlink_metadata(&path).await.map_err(|error| {
        DriverError::Transient(format!(
            "inspect ACP local {expected_top_level_type} attachment: {error}"
        ))
    })?;
    if !metadata.file_type().is_file()
        || usize::try_from(metadata.len()).map_or(true, |size| {
            size == 0 || size > MAX_NATIVE_PROMPT_MEDIA_BYTES
        })
    {
        return Err(DriverError::Rejected(format!(
            "ACP local {expected_top_level_type} attachment is not a bounded regular file"
        )));
    }
    let bytes = tokio::fs::read(&path).await.map_err(|error| {
        DriverError::Transient(format!(
            "read ACP local {expected_top_level_type} attachment: {error}"
        ))
    })?;
    if bytes.len() as u64 != metadata.len() {
        return Err(DriverError::Transient(format!(
            "ACP local {expected_top_level_type} attachment changed while reading"
        )));
    }
    log::trace!(
        target: "inline_agent_driver_acp::media",
        "phase=native_prompt_media kind={expected_top_level_type:?} byte_count={} mime_type={mime_type:?}",
        bytes.len()
    );
    Ok(Some((
        base64::engine::general_purpose::STANDARD.encode(bytes),
        mime_type.to_string(),
        local_uri.to_string(),
    )))
}

fn normalized_mime_type(value: &str) -> Option<&str> {
    let mime_type = value.split(';').next()?.trim();
    (!mime_type.is_empty()
        && mime_type
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'+' | b'.' | b'-')))
    .then_some(mime_type)
}

fn acp_resource_link(attachment: InputAttachment) -> acp::ContentBlock {
    let uri = attachment
        .local_uri
        .clone()
        .unwrap_or_else(|| attachment.uri.clone());
    let name = attachment
        .file_name
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| format!("Inline {:?} attachment", attachment.kind).to_lowercase());
    let size = attachment
        .size_bytes
        .and_then(|size| i64::try_from(size).ok());
    acp::ContentBlock::ResourceLink(
        acp::ResourceLink::new(name, uri)
            .mime_type(attachment.mime_type)
            .size(size)
            .description("Untrusted media attached to the Inline user message"),
    )
}
#[cfg(not(test))]
const AMBIGUOUS_EPOCH_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(7);
#[cfg(test)]
const AMBIGUOUS_EPOCH_SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(500);
#[cfg(not(test))]
const CANCEL_COMPLETION_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(test)]
const CANCEL_COMPLETION_TIMEOUT: Duration = Duration::from_millis(500);

#[derive(Debug)]
struct ActiveTurn {
    turn_id: TurnId,
    sender: AgentEventSender,
    text: String,
    separate_next_agent_message: bool,
    tool_calls: ToolCallSnapshots,
}

type ActiveTurns = Arc<StdMutex<HashMap<String, ActiveTurn>>>;

#[derive(Debug)]
struct PendingApproval {
    session_id: String,
    options: Vec<acp::PermissionOption>,
    responder: Responder<acp::RequestPermissionResponse>,
    completion: oneshot::Sender<()>,
}

type PendingApprovals = Arc<StdMutex<HashMap<String, PendingApproval>>>;

#[derive(Debug)]
struct PendingElicitation {
    session_id: String,
    fields: Vec<ElicitationField>,
    responder: Responder<acp::CreateElicitationResponse>,
    completion: oneshot::Sender<()>,
}

type PendingElicitations = Arc<StdMutex<HashMap<String, PendingElicitation>>>;

#[derive(Clone, Debug)]
struct SessionMetadata {
    cwd: PathBuf,
    config_options: Vec<acp::SessionConfigOption>,
    modes: Option<acp::SessionModeState>,
    commands: Vec<DriverCommand>,
}

#[derive(Debug, Default)]
struct SessionRegistry {
    sessions: HashMap<String, SessionMetadata>,
    prewarmed_by_cwd: HashMap<PathBuf, String>,
    prewarming_by_cwd: HashMap<PathBuf, SessionPrewarm>,
}

type Sessions = Arc<StdMutex<SessionRegistry>>;
type SessionPrewarm = Shared<BoxFuture<'static, DriverResult<String>>>;
type HostTools = Arc<StdMutex<Option<AcpHostToolProxy>>>;

struct SessionMcpAttachment {
    proxy: AcpHostToolProxy,
    capability: String,
    server: acp::McpServer,
    armed: bool,
}

impl SessionMcpAttachment {
    fn servers(&self) -> Vec<acp::McpServer> {
        vec![self.server.clone()]
    }

    fn bind(mut self, session_id: ProviderSessionId) {
        self.proxy.bind_session(&self.capability, session_id);
        self.armed = false;
    }
}

impl Drop for SessionMcpAttachment {
    fn drop(&mut self) {
        if self.armed {
            self.proxy.revoke(&self.capability);
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ConnectionLifecycle {
    shutdown: Arc<StdMutex<Option<oneshot::Sender<()>>>>,
    pub(crate) completion: watch::Receiver<Option<Result<(), String>>>,
}

struct AmbiguousMutationGuard {
    shutdown: Arc<StdMutex<Option<oneshot::Sender<()>>>>,
    armed: bool,
}

impl AmbiguousMutationGuard {
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for AmbiguousMutationGuard {
    fn drop(&mut self) {
        if self.armed
            && let Some(shutdown) = self
                .shutdown
                .lock()
                .expect("ACP shutdown state poisoned")
                .take()
        {
            let _ = shutdown.send(());
        }
    }
}

impl ConnectionLifecycle {
    fn guard_mutating_request(&self) -> AmbiguousMutationGuard {
        AmbiguousMutationGuard {
            shutdown: Arc::clone(&self.shutdown),
            armed: true,
        }
    }

    async fn shutdown(&self) -> DriverResult<()> {
        if let Some(shutdown) = self
            .shutdown
            .lock()
            .expect("ACP shutdown state poisoned")
            .take()
        {
            let _ = shutdown.send(());
        }
        let mut completion = self.completion.clone();
        tokio::time::timeout(AMBIGUOUS_EPOCH_SHUTDOWN_TIMEOUT, async move {
            loop {
                if let Some(result) = completion.borrow().clone() {
                    return result.map_err(DriverError::ProcessExited);
                }
                completion.changed().await.map_err(|_| {
                    DriverError::ProcessExited("ACP connection supervisor exited".to_string())
                })?;
            }
        })
        .await
        .map_err(|_| DriverError::ProcessExited("ACP connection shutdown timed out".to_string()))?
    }
}

#[derive(Clone)]
pub struct AcpDriver {
    connection: ConnectionTo<Agent>,
    capabilities: DriverCapabilities,
    prompt_capabilities: acp::PromptCapabilities,
    resume_mode: ResumeMode,
    default_permission_mode: Option<Arc<str>>,
    active_turns: ActiveTurns,
    approvals: PendingApprovals,
    elicitations: PendingElicitations,
    sessions: Sessions,
    host_tools: HostTools,
    pub(crate) lifecycle: ConnectionLifecycle,
    sequence: Arc<AtomicU64>,
    epoch: Arc<str>,
    auth_methods: Arc<[String]>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ResumeMode {
    Unsupported,
    Resume,
    Load,
}

impl std::fmt::Debug for AcpDriver {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AcpDriver")
            .field("capabilities", &self.capabilities)
            .finish_non_exhaustive()
    }
}

impl AcpDriver {
    pub(crate) fn disable_durable_session_resume(&mut self) {
        self.resume_mode = ResumeMode::Unsupported;
        self.capabilities.resume_session = false;
    }

    pub(crate) fn set_default_permission_mode(&mut self, mode: impl Into<Arc<str>>) {
        self.default_permission_mode = Some(mode.into());
    }

    /// Connects the driver to an already constructed ACP client transport.
    ///
    /// The normal bridge path uses [`crate::spawn_acp_driver`]. This transport
    /// seam exists for conformance harnesses and future non-stdio ACP endpoints.
    pub async fn connect_transport(
        transport: impl ConnectTo<Client>,
        bridge_version: &str,
    ) -> DriverResult<Self> {
        Self::connect_transport_with_output_cache(transport, bridge_version, None).await
    }

    pub(crate) async fn connect_transport_with_output_cache(
        transport: impl ConnectTo<Client>,
        bridge_version: &str,
        output_cache_dir: Option<PathBuf>,
    ) -> DriverResult<Self> {
        let active_turns = Arc::new(StdMutex::new(HashMap::new()));
        let approvals = Arc::new(StdMutex::new(HashMap::new()));
        let elicitations = Arc::new(StdMutex::new(HashMap::new()));
        let sequence = Arc::new(AtomicU64::new(1));
        let sessions = Arc::new(StdMutex::new(SessionRegistry::default()));
        let host_tools = Arc::new(StdMutex::new(None));
        let epoch: Arc<str> = uuid::Uuid::new_v4().simple().to_string().into();
        let (connection_tx, connection_rx) = oneshot::channel();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let (completion_tx, completion_rx) = watch::channel(None);

        let notification_turns = active_turns.clone();
        let notification_sessions = sessions.clone();
        let notification_output_cache = output_cache_dir.clone();
        let permission_turns = active_turns.clone();
        let permission_approvals = approvals.clone();
        let permission_sequence = sequence.clone();
        let permission_epoch = epoch.clone();
        let elicitation_turns = active_turns.clone();
        let pending_elicitations = elicitations.clone();
        let elicitation_sequence = sequence.clone();
        let elicitation_epoch = epoch.clone();
        let lifecycle_turns = active_turns.clone();
        let lifecycle_approvals = approvals.clone();
        let lifecycle_elicitations = elicitations.clone();
        tokio::spawn(async move {
            let result = Client
                .builder()
                .name("inline-agent-bridge")
                .on_receive_notification(
                    async move |notification: acp::SessionNotification, _connection| {
                        handle_session_update(
                            &notification_turns,
                            &notification_sessions,
                            notification_output_cache.as_deref(),
                            notification,
                        )
                        .await;
                        Ok(())
                    },
                    agent_client_protocol::on_receive_notification!(),
                )
                .on_receive_request(
                    async move |request: acp::RequestPermissionRequest, responder, _connection| {
                        handle_permission_request(
                            &permission_turns,
                            &permission_approvals,
                            &permission_sequence,
                            &permission_epoch,
                            request,
                            responder,
                        );
                        Ok(())
                    },
                    agent_client_protocol::on_receive_request!(),
                )
                .on_receive_request(
                    async move |request: acp::CreateElicitationRequest, responder, _connection| {
                        handle_elicitation_request(
                            &elicitation_turns,
                            &pending_elicitations,
                            &elicitation_sequence,
                            &elicitation_epoch,
                            request,
                            responder,
                        );
                        Ok(())
                    },
                    agent_client_protocol::on_receive_request!(),
                )
                .connect_with(transport, async move |connection| {
                    connection_tx.send(connection.clone()).map_err(|_| {
                        agent_client_protocol::Error::internal_error()
                            .data("Inline dropped the ACP connection receiver")
                    })?;
                    tokio::select! {
                        _ = shutdown_rx => Ok(()),
                        () = connection.incoming_closed() => {
                            Err(agent_client_protocol::Error::internal_error()
                                .data("ACP transport closed"))
                        }
                    }
                })
                .await;
            let result = result.map_err(|error| error.to_string());
            fail_all_turns(
                &lifecycle_turns,
                &lifecycle_approvals,
                &lifecycle_elicitations,
                result.as_ref().err(),
            );
            let _ = completion_tx.send(Some(result));
        });

        let connection = tokio::time::timeout(CONNECTION_TIMEOUT, connection_rx)
            .await
            .map_err(|_| DriverError::Unavailable("ACP connection setup timed out".to_string()))?
            .map_err(|_| {
                DriverError::Unavailable("ACP transport closed before connection setup".to_string())
            })?;
        let initialize = acp::InitializeRequest::new(ProtocolVersion::V1)
            .client_capabilities(
                acp::ClientCapabilities::new()
                    .session(
                        acp::ClientSessionCapabilities::new()
                            .config_options(acp::SessionConfigOptionsCapabilities::new()),
                    )
                    .elicitation(
                        acp::ElicitationCapabilities::new()
                            .form(acp::ElicitationFormCapabilities::new()),
                    ),
            )
            .client_info(acp::Implementation::new(
                "inline-agent-bridge",
                bridge_version,
            ));
        let response = request_with_timeout(
            "initialize",
            &[],
            connection.send_request(initialize).block_task(),
        )
        .await?;
        if response.protocol_version != ProtocolVersion::V1 {
            let _ = shutdown_tx.send(());
            return Err(DriverError::Protocol(format!(
                "ACP agent negotiated unsupported protocol version {}",
                response.protocol_version
            )));
        }
        let resume_mode = resume_mode(&response.agent_capabilities);
        let capabilities = map_capabilities(&response.agent_capabilities);
        let prompt_capabilities = response.agent_capabilities.prompt_capabilities.clone();
        log::trace!(
            target: "inline_agent_driver_acp::protocol",
            "phase=initialized prompt_image={} prompt_audio={} embedded_context={}",
            prompt_capabilities.image,
            prompt_capabilities.audio,
            prompt_capabilities.embedded_context
        );
        let auth_methods = response
            .auth_methods
            .iter()
            .map(|method| safe_auth_method_name(method.name()))
            .collect::<Vec<_>>()
            .into();
        Ok(Self {
            connection,
            capabilities,
            prompt_capabilities,
            resume_mode,
            default_permission_mode: None,
            active_turns,
            approvals,
            elicitations,
            sessions,
            host_tools,
            lifecycle: ConnectionLifecycle {
                shutdown: Arc::new(StdMutex::new(Some(shutdown_tx))),
                completion: completion_rx,
            },
            sequence,
            epoch,
            auth_methods,
        })
    }

    fn next_id(&self, kind: &str) -> String {
        format!(
            "acp-{kind}-{}-{}",
            self.epoch,
            self.sequence.fetch_add(1, Ordering::Relaxed)
        )
    }

    fn session_mcp_attachment(&self) -> DriverResult<Option<SessionMcpAttachment>> {
        let proxy = self
            .host_tools
            .lock()
            .expect("ACP host tools poisoned")
            .clone();
        let Some(proxy) = proxy else {
            return Ok(None);
        };
        let (server, capability) = proxy.session_server()?;
        Ok(Some(SessionMcpAttachment {
            proxy,
            capability,
            server,
            armed: true,
        }))
    }

    async fn create_session(&self, cwd: PathBuf) -> DriverResult<String> {
        let attachment = self.session_mcp_attachment()?;
        let request = acp::NewSessionRequest::new(cwd.clone()).mcp_servers(
            attachment
                .as_ref()
                .map_or_else(Vec::new, SessionMcpAttachment::servers),
        );
        let response = mutating_request_with_timeout(
            &self.lifecycle,
            REQUEST_TIMEOUT,
            "session/new",
            self.connection.send_request(request).block_task(),
            |error| acp_request_error(error, &self.auth_methods),
        )
        .await?;
        let session_id = response.session_id.to_string();
        validate_provider_session_id(&session_id)?;
        let provider_session_id = ProviderSessionId::new(session_id.clone())
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        if let Some(attachment) = attachment {
            attachment.bind(provider_session_id);
        }
        self.record_session(
            session_id.clone(),
            cwd,
            response.config_options.unwrap_or_default(),
            response.modes,
        );
        Ok(session_id)
    }

    fn prewarm_session(&self, cwd: PathBuf) -> SessionPrewarm {
        let mut sessions = self.sessions.lock().expect("ACP session registry poisoned");
        if let Some(prewarming) = sessions.prewarming_by_cwd.get(&cwd) {
            return prewarming.clone();
        }

        let driver = self.clone();
        let task_cwd = cwd.clone();
        let prewarming = async move {
            let session_id = driver.create_session(task_cwd.clone()).await?;
            driver
                .sessions
                .lock()
                .expect("ACP session registry poisoned")
                .prewarmed_by_cwd
                .insert(task_cwd, session_id.clone());
            Ok(session_id)
        }
        .boxed()
        .shared();
        sessions
            .prewarming_by_cwd
            .insert(cwd.clone(), prewarming.clone());
        drop(sessions);

        // Settings presentation has a much shorter deadline than ACP session
        // creation. Keep the mutation owned and polled after the caller times
        // out; dropping it would correctly terminate the ambiguous ACP epoch.
        let cleanup = prewarming.clone();
        let cleanup_sessions = Arc::clone(&self.sessions);
        tokio::spawn(async move {
            if cleanup.await.is_err() {
                cleanup_sessions
                    .lock()
                    .expect("ACP session registry poisoned")
                    .prewarming_by_cwd
                    .remove(&cwd);
            }
        });
        prewarming
    }

    fn record_session(
        &self,
        session_id: String,
        cwd: PathBuf,
        config_options: Vec<acp::SessionConfigOption>,
        modes: Option<acp::SessionModeState>,
    ) {
        let modes = session_modes(&config_options, modes.as_ref());
        let mut sessions = self.sessions.lock().expect("ACP session registry poisoned");
        if let Some(session) = sessions.sessions.get_mut(&session_id) {
            session.cwd = cwd;
            session.config_options = config_options;
            session.modes = modes;
        } else {
            sessions.sessions.insert(
                session_id,
                SessionMetadata {
                    cwd,
                    config_options,
                    modes,
                    commands: Vec::new(),
                },
            );
        }
    }

    async fn apply_config_option(
        &self,
        session_id: &str,
        category: acp::SessionConfigOptionCategory,
        value: &str,
    ) -> DriverResult<()> {
        let config_id = {
            let sessions = self.sessions.lock().expect("ACP session registry poisoned");
            let session = sessions.sessions.get(session_id).ok_or_else(|| {
                DriverError::InvalidSession("ACP session metadata is unavailable".to_string())
            })?;
            select_config_id(&session.config_options, category, value).ok_or_else(|| {
                DriverError::Rejected(format!(
                    "ACP agent did not offer the selected setting `{value}`"
                ))
            })?
        };
        let response = mutating_request_with_timeout(
            &self.lifecycle,
            REQUEST_TIMEOUT,
            "session/set_config_option",
            self.connection
                .send_request(acp::SetSessionConfigOptionRequest::new(
                    acp::SessionId::new(session_id.to_string()),
                    config_id,
                    acp::SessionConfigOptionValue::value_id(value.to_string()),
                ))
                .block_task(),
            |error| acp_request_error(error, &self.auth_methods),
        )
        .await?;
        if let Some(session) = self
            .sessions
            .lock()
            .expect("ACP session registry poisoned")
            .sessions
            .get_mut(session_id)
        {
            session.modes = session_modes(&response.config_options, session.modes.as_ref());
            session.config_options = response.config_options;
        }
        Ok(())
    }

    async fn apply_session_mode(&self, session_id: &str, value: &str) -> DriverResult<()> {
        let (mode_id, already_selected) = {
            let sessions = self.sessions.lock().expect("ACP session registry poisoned");
            let session = sessions.sessions.get(session_id).ok_or_else(|| {
                DriverError::InvalidSession("ACP session metadata is unavailable".to_string())
            })?;
            let modes = session.modes.as_ref().ok_or_else(|| {
                DriverError::Rejected("ACP agent did not advertise permission modes".to_string())
            })?;
            let mode_id = modes
                .available_modes
                .iter()
                .find(|mode| mode.id.to_string() == value)
                .map(|mode| mode.id.clone())
                .ok_or_else(|| {
                    DriverError::Rejected(format!(
                        "ACP agent did not offer the selected permission mode `{value}`"
                    ))
                })?;
            let already_selected = modes.current_mode_id == mode_id;
            (mode_id, already_selected)
        };
        if already_selected {
            return Ok(());
        }
        mutating_request_with_timeout(
            &self.lifecycle,
            REQUEST_TIMEOUT,
            "session/set_mode",
            self.connection
                .send_request(acp::SetSessionModeRequest::new(
                    acp::SessionId::new(session_id.to_string()),
                    mode_id.clone(),
                ))
                .block_task(),
            |error| acp_request_error(error, &self.auth_methods),
        )
        .await?;
        if let Some(modes) = self
            .sessions
            .lock()
            .expect("ACP session registry poisoned")
            .sessions
            .get_mut(session_id)
            .and_then(|session| session.modes.as_mut())
        {
            modes.current_mode_id = mode_id;
        }
        Ok(())
    }

    fn effective_permission_mode(
        &self,
        session_id: &str,
        selected: Option<&str>,
    ) -> DriverResult<Option<String>> {
        if let Some(selected) = selected {
            return Ok(Some(selected.to_string()));
        }
        let Some(default) = self.default_permission_mode.as_deref() else {
            return Ok(None);
        };
        let sessions = self.sessions.lock().expect("ACP session registry poisoned");
        let session = sessions.sessions.get(session_id).ok_or_else(|| {
            DriverError::InvalidSession("ACP session metadata is unavailable".to_string())
        })?;
        Ok(session
            .modes
            .as_ref()
            .filter(|modes| {
                modes
                    .available_modes
                    .iter()
                    .any(|mode| mode.id.to_string() == default)
            })
            .map(|_| default.to_string()))
    }
}

impl AgentDriver for AcpDriver {
    fn capabilities(&self) -> DriverCapabilities {
        self.capabilities.clone()
    }

    fn configure_host_tools(&self, configuration: HostToolConfiguration) -> DriverResult<()> {
        let active_turns = Arc::clone(&self.active_turns);
        let proxy = AcpHostToolProxy::bind(
            configuration,
            Arc::new(move |session_id| {
                active_turns
                    .lock()
                    .expect("ACP active turns poisoned")
                    .get(session_id.as_str())
                    .map(|turn| turn.turn_id.clone())
            }),
        )?;
        let mut host_tools = self.host_tools.lock().expect("ACP host tools poisoned");
        if host_tools.is_some() {
            return Err(DriverError::Rejected(
                "ACP host tools are already configured".to_string(),
            ));
        }
        *host_tools = Some(proxy);
        Ok(())
    }

    fn settings_catalog<'a>(&'a self, cwd: &'a Path) -> DriverFuture<'a, DriverSettingsCatalog> {
        Box::pin(async move {
            if let Some(catalog) = {
                let sessions = self.sessions.lock().expect("ACP session registry poisoned");
                sessions
                    .sessions
                    .values()
                    .find(|session| session.cwd == cwd)
                    .map(|session| {
                        settings_catalog(
                            &session.config_options,
                            session.modes.as_ref(),
                            self.default_permission_mode.as_deref(),
                        )
                    })
            } {
                return Ok(catalog);
            }
            let cwd = cwd.to_path_buf();
            let session_id = self.prewarm_session(cwd.clone()).await?;
            let catalog = {
                let sessions = self.sessions.lock().expect("ACP session registry poisoned");
                settings_catalog(
                    &sessions
                        .sessions
                        .get(&session_id)
                        .expect("new ACP session was not recorded")
                        .config_options,
                    sessions
                        .sessions
                        .get(&session_id)
                        .expect("new ACP session was not recorded")
                        .modes
                        .as_ref(),
                    self.default_permission_mode.as_deref(),
                )
            };
            Ok(catalog)
        })
    }

    fn session_commands<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
    ) -> DriverFuture<'a, Vec<DriverCommand>> {
        Box::pin(async move {
            self.sessions
                .lock()
                .expect("ACP session registry poisoned")
                .sessions
                .get(session_id.as_str())
                .map(|session| session.commands.clone())
                .ok_or_else(|| {
                    DriverError::InvalidSession("ACP session metadata is unavailable".to_string())
                })
        })
    }

    fn start_session<'a>(&'a self, spec: SessionSpec) -> DriverFuture<'a, ProviderSessionId> {
        Box::pin(async move {
            let (prewarmed, prewarming) = {
                let mut sessions = self.sessions.lock().expect("ACP session registry poisoned");
                (
                    sessions.prewarmed_by_cwd.remove(&spec.cwd),
                    sessions.prewarming_by_cwd.get(&spec.cwd).cloned(),
                )
            };
            let session_id = match (prewarmed, prewarming) {
                (Some(session_id), _) => session_id,
                (None, Some(prewarming)) => prewarming.await?,
                // Keep direct first-turn creation on the same owned task path
                // as settings prewarm. Claude's ACP adapter acknowledges
                // `session/new` before its fresh-session prompt consumer is
                // ready; sending `session/prompt` immediately from this caller
                // can then wedge forever. The owned prewarm task gives the
                // adapter's post-new-session work a scheduling boundary without
                // adding an arbitrary sleep or creating a second session.
                (None, None) => self.prewarm_session(spec.cwd.clone()).await?,
            };
            let mut sessions = self.sessions.lock().expect("ACP session registry poisoned");
            sessions.prewarmed_by_cwd.remove(&spec.cwd);
            sessions.prewarming_by_cwd.remove(&spec.cwd);
            ProviderSessionId::new(session_id)
                .map_err(|error| DriverError::Protocol(error.to_string()))
        })
    }

    fn resume_session<'a>(&'a self, spec: ResumeSessionSpec) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            if !matches!(spec.replay, SessionReplay::None) {
                return Err(DriverError::Unsupported("ACP session replay cursor"));
            }
            validate_provider_session_id(spec.session_id.as_str())?;
            let session_id = acp::SessionId::new(spec.session_id.to_string());
            match self.resume_mode {
                ResumeMode::Resume => {
                    let attachment = self.session_mcp_attachment()?;
                    let request = acp::ResumeSessionRequest::new(session_id, spec.cwd.clone())
                        .mcp_servers(
                            attachment
                                .as_ref()
                                .map_or_else(Vec::new, SessionMcpAttachment::servers),
                        );
                    self.record_session(
                        spec.session_id.to_string(),
                        spec.cwd.clone(),
                        Vec::new(),
                        None,
                    );
                    let response = match mutating_request_with_timeout(
                        &self.lifecycle,
                        REQUEST_TIMEOUT,
                        "session/resume",
                        self.connection.send_request(request).block_task(),
                        |error| acp_resume_error(error, &self.auth_methods),
                    )
                    .await
                    {
                        Ok(response) => response,
                        Err(error) => {
                            self.sessions
                                .lock()
                                .expect("ACP session registry poisoned")
                                .sessions
                                .remove(spec.session_id.as_str());
                            return Err(error);
                        }
                    };
                    self.record_session(
                        spec.session_id.to_string(),
                        spec.cwd,
                        response.config_options.unwrap_or_default(),
                        response.modes,
                    );
                    if let Some(attachment) = attachment {
                        attachment.bind(spec.session_id);
                    }
                    Ok(())
                }
                ResumeMode::Load => {
                    let attachment = self.session_mcp_attachment()?;
                    let request = acp::LoadSessionRequest::new(session_id, spec.cwd.clone())
                        .mcp_servers(
                            attachment
                                .as_ref()
                                .map_or_else(Vec::new, SessionMcpAttachment::servers),
                        );
                    self.record_session(
                        spec.session_id.to_string(),
                        spec.cwd.clone(),
                        Vec::new(),
                        None,
                    );
                    let response = match mutating_request_with_timeout(
                        &self.lifecycle,
                        REQUEST_TIMEOUT,
                        "session/load",
                        self.connection.send_request(request).block_task(),
                        |error| acp_resume_error(error, &self.auth_methods),
                    )
                    .await
                    {
                        Ok(response) => response,
                        Err(error) => {
                            self.sessions
                                .lock()
                                .expect("ACP session registry poisoned")
                                .sessions
                                .remove(spec.session_id.as_str());
                            return Err(error);
                        }
                    };
                    self.record_session(
                        spec.session_id.to_string(),
                        spec.cwd,
                        response.config_options.unwrap_or_default(),
                        response.modes,
                    );
                    if let Some(attachment) = attachment {
                        attachment.bind(spec.session_id);
                    }
                    Ok(())
                }
                ResumeMode::Unsupported => Err(DriverError::Unsupported("ACP session resume")),
            }
        })
    }

    fn start_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        input: TurnInput,
        options: TurnOptions,
    ) -> DriverFuture<'a, StartedTurn> {
        Box::pin(async move {
            let session_key = session_id.to_string();
            if let Some(cwd) = options.cwd.as_ref() {
                let sessions = self.sessions.lock().expect("ACP session registry poisoned");
                let session = sessions.sessions.get(&session_key).ok_or_else(|| {
                    DriverError::InvalidSession("ACP session metadata is unavailable".to_string())
                })?;
                if &session.cwd != cwd {
                    return Err(DriverError::Rejected(
                        "ACP workspace changes require a new session".to_string(),
                    ));
                }
            }
            if let Some(model) = options.model.as_deref() {
                self.apply_config_option(
                    &session_key,
                    acp::SessionConfigOptionCategory::Model,
                    model,
                )
                .await?;
            }
            if let Some(reasoning) = options.reasoning.as_deref() {
                self.apply_config_option(
                    &session_key,
                    acp::SessionConfigOptionCategory::ThoughtLevel,
                    reasoning,
                )
                .await?;
            }
            if let Some(permissions) =
                self.effective_permission_mode(&session_key, options.permissions.as_deref())?
            {
                self.apply_session_mode(&session_key, &permissions).await?;
            }
            let prompt_blocks = acp_prompt_blocks(input, &self.prompt_capabilities).await?;
            let turn_id = TurnId::new(self.next_id("turn"))
                .map_err(|error| DriverError::Protocol(error.to_string()))?;
            let (sender, events) = AgentEventReceiver::default_channel();
            sender.send(Ok(AgentEvent::TurnStarted {
                turn_id: turn_id.clone(),
            }));
            {
                let mut active = self.active_turns.lock().expect("ACP active turns poisoned");
                if active.contains_key(&session_key) {
                    return Err(DriverError::Rejected(
                        "ACP session already has an active turn".to_string(),
                    ));
                }
                active.insert(
                    session_key.clone(),
                    ActiveTurn {
                        turn_id: turn_id.clone(),
                        sender,
                        text: String::new(),
                        separate_next_agent_message: false,
                        tool_calls: ToolCallSnapshots::new(),
                    },
                );
            }
            let connection = self.connection.clone();
            let active_turns = self.active_turns.clone();
            let approvals = self.approvals.clone();
            let elicitations = self.elicitations.clone();
            let auth_methods = self.auth_methods.clone();
            let prompt =
                acp::PromptRequest::new(acp::SessionId::new(session_key.clone()), prompt_blocks);
            tokio::spawn(async move {
                let result = connection.send_request(prompt).block_task().await;
                finish_turn(
                    &active_turns,
                    &approvals,
                    &elicitations,
                    &session_key,
                    &auth_methods,
                    result,
                );
            });
            Ok(StartedTurn { turn_id, events })
        })
    }

    fn steer_turn<'a>(
        &'a self,
        _session_id: &'a ProviderSessionId,
        _turn_id: &'a TurnId,
        _input: TurnInput,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async { Err(DriverError::Unsupported("ACP steering")) })
    }

    fn cancel_turn<'a>(
        &'a self,
        session_id: &'a ProviderSessionId,
        turn_id: &'a TurnId,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            let started_at = std::time::Instant::now();
            let session_key = session_id.to_string();
            let matches = self
                .active_turns
                .lock()
                .expect("ACP active turns poisoned")
                .get(&session_key)
                .is_some_and(|turn| &turn.turn_id == turn_id);
            if !matches {
                log::trace!(
                    target: "inline_agent_driver_acp::turn",
                    "phase=cancel_confirmed session_id={:?} turn_id={:?} already_terminal=true elapsed_ms={}",
                    session_id.as_str(),
                    turn_id.as_str(),
                    started_at.elapsed().as_millis()
                );
                return Ok(());
            }
            log::trace!(
                target: "inline_agent_driver_acp::turn",
                "phase=cancel_started session_id={:?} turn_id={:?}",
                session_id.as_str(),
                turn_id.as_str()
            );
            cancel_pending_approvals(&self.approvals, Some(&session_key));
            cancel_pending_elicitations(&self.elicitations, Some(&session_key));
            self.connection
                .send_notification(acp::CancelNotification::new(session_key))
                .map_err(|error| acp_request_error(error, &self.auth_methods))?;
            let confirmed = tokio::time::timeout(CANCEL_COMPLETION_TIMEOUT, async {
                loop {
                    let active = self
                        .active_turns
                        .lock()
                        .expect("ACP active turns poisoned")
                        .get(session_id.as_str())
                        .is_some_and(|turn| &turn.turn_id == turn_id);
                    if !active {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            })
            .await
            .is_ok();
            if confirmed {
                log::trace!(
                    target: "inline_agent_driver_acp::turn",
                    "phase=cancel_confirmed session_id={:?} turn_id={:?} already_terminal=false elapsed_ms={}",
                    session_id.as_str(),
                    turn_id.as_str(),
                    started_at.elapsed().as_millis()
                );
                return Ok(());
            }
            let _ = self.lifecycle.shutdown().await;
            Err(DriverError::ProcessExited(
                "ACP cancellation was not confirmed; provider epoch stopped".to_string(),
            ))
        })
    }

    fn compact_session<'a>(&'a self, _session_id: &'a ProviderSessionId) -> DriverFuture<'a, ()> {
        Box::pin(async { Err(DriverError::Unsupported("ACP session compact")) })
    }

    fn resolve_approval<'a>(
        &'a self,
        approval_id: &'a str,
        decision: ApprovalDecision,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            let (pending, outcome, cancel_turn) = {
                let mut approvals = self.approvals.lock().expect("ACP approvals poisoned");
                let pending = approvals.get(approval_id).ok_or_else(|| {
                    DriverError::Rejected("ACP approval is no longer active".to_string())
                })?;
                let cancel_turn = matches!(decision, ApprovalDecision::CancelTurn);
                let outcome = approval_outcome(&pending.options, decision)?;
                let pending = approvals
                    .remove(approval_id)
                    .expect("validated ACP approval disappeared");
                (pending, outcome, cancel_turn)
            };
            let _ = pending.completion.send(());
            let session_id = pending.session_id.clone();
            let response = pending
                .responder
                .respond(acp::RequestPermissionResponse::new(outcome))
                .map_err(|error| acp_request_error(error, &self.auth_methods));
            let cancel = if cancel_turn {
                self.connection
                    .send_notification(acp::CancelNotification::new(session_id))
                    .map_err(|error| acp_request_error(error, &self.auth_methods))
            } else {
                Ok(())
            };
            response.and(cancel)
        })
    }

    fn resolve_question<'a>(
        &'a self,
        request_id: &'a str,
        answers: Vec<QuestionAnswer>,
    ) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            let (pending, response) = {
                let mut elicitations = self
                    .elicitations
                    .lock()
                    .expect("ACP elicitation map poisoned");
                let pending = elicitations.get(request_id).ok_or_else(|| {
                    DriverError::Rejected("ACP question is no longer active".to_string())
                })?;
                let response = answer_response(&pending.fields, answers)?;
                let pending = elicitations
                    .remove(request_id)
                    .expect("validated ACP elicitation disappeared");
                (pending, response)
            };
            let _ = pending.completion.send(());
            pending
                .responder
                .respond(response)
                .map_err(|error| acp_request_error(error, &self.auth_methods))
        })
    }

    fn shutdown<'a>(&'a self) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            cancel_pending_approvals(&self.approvals, None);
            cancel_pending_elicitations(&self.elicitations, None);
            self.host_tools
                .lock()
                .expect("ACP host tools poisoned")
                .take();
            self.lifecycle.shutdown().await
        })
    }
}

fn validate_provider_session_id(session_id: &str) -> DriverResult<()> {
    if session_id.trim().is_empty()
        || session_id.len() > MAX_PROVIDER_SESSION_ID_BYTES
        || session_id.chars().any(char::is_control)
    {
        return Err(DriverError::Protocol(
            "ACP provider returned an invalid session identity".to_string(),
        ));
    }
    Ok(())
}

fn map_capabilities(capabilities: &acp::AgentCapabilities) -> DriverCapabilities {
    DriverCapabilities {
        resume_session: resume_mode(capabilities) != ResumeMode::Unsupported,
        compact_session: false,
        cancel_turn: true,
        settings_catalog: true,
        settings_catalog_starts_session: true,
        session_commands: true,
        steering: SteeringSupport::Unsupported,
        settings_apply_timing: ApplyTiming::NextTurn,
        approvals: vec![
            inline_agent_bridge::ApprovalOption::ApproveOnce,
            inline_agent_bridge::ApprovalOption::ApproveForSession,
            inline_agent_bridge::ApprovalOption::Reject,
            inline_agent_bridge::ApprovalOption::CancelTurn,
        ],
        // Stdio MCP is mandatory for stable ACP v1. Inline attaches the same
        // bridge-owned catalog used by native drivers at session setup.
        host_tools: inline_agent_bridge::HostToolTransport::Mcp,
    }
}

fn resume_mode(capabilities: &acp::AgentCapabilities) -> ResumeMode {
    if capabilities.session_capabilities.resume.is_some() {
        ResumeMode::Resume
    } else if capabilities.load_session {
        ResumeMode::Load
    } else {
        ResumeMode::Unsupported
    }
}

async fn handle_session_update(
    active_turns: &ActiveTurns,
    sessions: &Sessions,
    output_cache_dir: Option<&Path>,
    notification: acp::SessionNotification,
) {
    let session_key = notification.session_id.to_string();
    if let acp::SessionUpdate::ConfigOptionUpdate(update) = &notification.update
        && let Some(session) = sessions
            .lock()
            .expect("ACP session registry poisoned")
            .sessions
            .get_mut(&session_key)
    {
        session.modes = session_modes(&update.config_options, session.modes.as_ref());
        session.config_options.clone_from(&update.config_options);
    }
    if let acp::SessionUpdate::AvailableCommandsUpdate(update) = &notification.update
        && let Some(session) = sessions
            .lock()
            .expect("ACP session registry poisoned")
            .sessions
            .get_mut(&session_key)
    {
        session.commands = available_commands(&update.available_commands);
    }
    if let acp::SessionUpdate::CurrentModeUpdate(update) = &notification.update
        && let Some(modes) = sessions
            .lock()
            .expect("ACP session registry poisoned")
            .sessions
            .get_mut(&session_key)
            .and_then(|session| session.modes.as_mut())
        && modes
            .available_modes
            .iter()
            .any(|mode| mode.id == update.current_mode_id)
    {
        modes.current_mode_id = update.current_mode_id.clone();
    }
    let output_attachment = if active_turns
        .lock()
        .expect("ACP active turns poisoned")
        .contains_key(&session_key)
    {
        match (&notification.update, output_cache_dir) {
            (acp::SessionUpdate::AgentMessageChunk(chunk), Some(cache_dir)) => {
                match &chunk.content {
                    acp::ContentBlock::Image(image) => {
                        match materialize_acp_output_image(image, cache_dir).await {
                            Ok(attachment) => Some(attachment),
                            Err(error) => {
                                log::warn!(
                                    target: "inline_agent_driver_acp::media",
                                    "phase=native_output_rejected kind=\"image\" reason={:?}",
                                    error
                                );
                                None
                            }
                        }
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    } else {
        None
    };
    let mut active = active_turns.lock().expect("ACP active turns poisoned");
    let Some(turn) = active.get_mut(&session_key) else {
        return;
    };
    if let Some(attachment) = output_attachment {
        turn.sender.send(Ok(AgentEvent::OutputAttachment {
            turn_id: turn.turn_id.clone(),
            attachment,
        }));
        return;
    }
    let mut separator = None;
    match &notification.update {
        acp::SessionUpdate::AgentMessageChunk(chunk) => {
            if let acp::ContentBlock::Text(text) = &chunk.content {
                if turn.separate_next_agent_message
                    && !turn.text.is_empty()
                    && !turn.text.ends_with(char::is_whitespace)
                    && !text.text.starts_with(char::is_whitespace)
                {
                    append_bounded_agent_text(&mut turn.text, "\n\n");
                    separator = Some("\n\n");
                }
                append_bounded_agent_text(&mut turn.text, &text.text);
                turn.separate_next_agent_message = false;
            }
        }
        acp::SessionUpdate::ToolCall(_) | acp::SessionUpdate::ToolCallUpdate(_) => {
            turn.separate_next_agent_message = !turn.text.is_empty();
        }
        _ => {}
    }
    if let Some(text) = separator {
        turn.sender.send(Ok(AgentEvent::AgentTextDelta {
            turn_id: turn.turn_id.clone(),
            text: text.to_string(),
        }));
    }
    for event in session_update_events(&turn.turn_id, &mut turn.tool_calls, notification.update) {
        if !turn.sender.send(Ok(event)) {
            break;
        }
    }
}

async fn materialize_acp_output_image(
    image: &acp::ImageContent,
    cache_dir: &Path,
) -> DriverResult<OutputAttachment> {
    let encoded = image.data.trim();
    let maximum_encoded_bytes = MAX_NATIVE_OUTPUT_IMAGE_BYTES.div_ceil(3) * 4;
    if encoded.is_empty() || encoded.len() > maximum_encoded_bytes {
        return Err(DriverError::Rejected(
            "ACP output image is outside the bridge size limit".to_string(),
        ));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded.as_bytes())
        .map_err(|_| DriverError::Rejected("ACP output image is not valid base64".to_string()))?;
    if bytes.is_empty() || bytes.len() > MAX_NATIVE_OUTPUT_IMAGE_BYTES {
        return Err(DriverError::Rejected(
            "ACP output image is outside the bridge size limit".to_string(),
        ));
    }
    let mime_type = normalized_mime_type(&image.mime_type)
        .and_then(|mime_type| {
            acp_output_image_extension(mime_type, &bytes).map(|ext| (mime_type, ext))
        })
        .ok_or_else(|| {
            DriverError::Rejected("ACP output image format is unsupported".to_string())
        })?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    tokio::fs::create_dir_all(cache_dir)
        .await
        .map_err(|error| DriverError::Transient(format!("create ACP output cache: {error}")))?;
    #[cfg(unix)]
    {
        tokio::fs::set_permissions(cache_dir, std::fs::Permissions::from_mode(0o700))
            .await
            .map_err(|error| DriverError::Transient(format!("secure ACP output cache: {error}")))?;
    }
    let path = cache_dir.join(format!("{digest}.{}", mime_type.1));
    match tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .await
    {
        Ok(mut file) => {
            #[cfg(unix)]
            file.set_permissions(std::fs::Permissions::from_mode(0o600))
                .await
                .map_err(|error| {
                    DriverError::Transient(format!("secure ACP output image: {error}"))
                })?;
            file.write_all(&bytes).await.map_err(|error| {
                DriverError::Transient(format!("write ACP output image: {error}"))
            })?;
            file.flush().await.map_err(|error| {
                DriverError::Transient(format!("flush ACP output image: {error}"))
            })?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let existing = tokio::fs::read(&path).await.map_err(|error| {
                DriverError::Transient(format!("verify ACP output image: {error}"))
            })?;
            if existing != bytes {
                return Err(DriverError::Protocol(
                    "ACP output cache digest collision".to_string(),
                ));
            }
        }
        Err(error) => {
            return Err(DriverError::Transient(format!(
                "create ACP output image: {error}"
            )));
        }
    }
    log::trace!(
        target: "inline_agent_driver_acp::media",
        "phase=native_output_materialized kind=\"image\" byte_count={} mime_type={:?}",
        bytes.len(),
        mime_type.0
    );
    Ok(OutputAttachment {
        id: format!("acp-image-{digest}"),
        kind: OutputAttachmentKind::Image,
        path,
        mime_type: mime_type.0.to_string(),
        file_name: format!("generated-image.{}", mime_type.1),
        size_bytes: bytes.len() as u64,
        sha256: digest,
    })
}

fn acp_output_image_extension(mime_type: &str, bytes: &[u8]) -> Option<&'static str> {
    match mime_type {
        "image/png" if bytes.starts_with(b"\x89PNG\r\n\x1a\n") => Some("png"),
        "image/jpeg" if bytes.starts_with(b"\xff\xd8\xff") => Some("jpg"),
        "image/webp"
            if bytes.len() >= 12
                && bytes.starts_with(b"RIFF")
                && bytes.get(8..12) == Some(b"WEBP") =>
        {
            Some("webp")
        }
        "image/gif" if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") => Some("gif"),
        _ => None,
    }
}

fn append_bounded_agent_text(target: &mut String, chunk: &str) {
    if target.ends_with(TRUNCATED_AGENT_TEXT_MARKER) {
        return;
    }
    let remaining = MAX_FINAL_AGENT_TEXT_BYTES.saturating_sub(target.len());
    if chunk.len() <= remaining {
        target.push_str(chunk);
        return;
    }
    let mut boundary = remaining.min(chunk.len());
    while boundary > 0 && !chunk.is_char_boundary(boundary) {
        boundary -= 1;
    }
    target.push_str(&chunk[..boundary]);
    target.push_str(TRUNCATED_AGENT_TEXT_MARKER);
}

fn handle_permission_request(
    active_turns: &ActiveTurns,
    approvals: &PendingApprovals,
    sequence: &AtomicU64,
    epoch: &str,
    request: acp::RequestPermissionRequest,
    responder: Responder<acp::RequestPermissionResponse>,
) {
    let session_key = request.session_id.to_string();
    let active = active_turns.lock().expect("ACP active turns poisoned");
    let Some(turn) = active.get(&session_key) else {
        let _ = responder.respond(acp::RequestPermissionResponse::new(
            acp::RequestPermissionOutcome::Cancelled,
        ));
        return;
    };
    let turn_id = turn.turn_id.clone();
    let sender = turn.sender.clone();
    drop(active);
    let summary = permission_summary(&request);
    let command = permission_command(&request);
    let options = bounded_permission_options(request.options);
    let approval_id = format!(
        "acp-approval-{epoch}-{}",
        sequence.fetch_add(1, Ordering::Relaxed)
    );
    let cancellation = responder.cancellation();
    let (completion_tx, completion_rx) = oneshot::channel();
    let event_turn_id = turn_id.clone();
    let event = AgentEvent::ApprovalRequested(ApprovalRequest {
        approval_id: approval_id.clone(),
        turn_id,
        summary,
        command,
        cwd: None,
        options: permission_options(&options),
    });
    let mut pending_approvals = approvals.lock().expect("ACP approvals poisoned");
    if pending_approvals.len() >= MAX_PENDING_APPROVALS
        || pending_approvals
            .values()
            .filter(|pending| pending.session_id == session_key)
            .count()
            >= MAX_PENDING_APPROVALS_PER_SESSION
    {
        drop(pending_approvals);
        let _ = responder.respond(acp::RequestPermissionResponse::new(
            acp::RequestPermissionOutcome::Cancelled,
        ));
        return;
    }
    pending_approvals.insert(
        approval_id.clone(),
        PendingApproval {
            session_id: session_key,
            options,
            responder,
            completion: completion_tx,
        },
    );
    drop(pending_approvals);
    if !sender.send(Ok(event)) {
        if let Some(pending) = approvals
            .lock()
            .expect("ACP approvals poisoned")
            .remove(&approval_id)
        {
            let _ = pending.completion.send(());
            let _ = pending
                .responder
                .respond(acp::RequestPermissionResponse::new(
                    acp::RequestPermissionOutcome::Cancelled,
                ));
        }
        return;
    }
    let approvals = approvals.clone();
    let sender = sender.clone();
    tokio::spawn(async move {
        tokio::select! {
            () = cancellation.cancelled() => {
                if let Some(pending) = approvals
                    .lock()
                    .expect("ACP approvals poisoned")
                    .remove(&approval_id)
                {
                    let _ = pending.responder.respond_with_error(
                        agent_client_protocol::Error::request_cancelled(),
                    );
                    let _ = sender.send(Ok(AgentEvent::ApprovalClosed {
                        turn_id: event_turn_id,
                        approval_id,
                    }));
                }
            }
            _ = completion_rx => {}
        }
    });
}

fn bounded_permission_options(options: Vec<acp::PermissionOption>) -> Vec<acp::PermissionOption> {
    let allow_once_count = options
        .iter()
        .filter(|option| option.kind == acp::PermissionOptionKind::AllowOnce)
        .count();
    let allow_always_count = options
        .iter()
        .filter(|option| option.kind == acp::PermissionOptionKind::AllowAlways)
        .count();
    let reject_count = options
        .iter()
        .filter(|option| {
            matches!(
                option.kind,
                acp::PermissionOptionKind::RejectOnce | acp::PermissionOptionKind::RejectAlways
            )
        })
        .count();
    let preserve_provider_label = options
        .iter()
        .filter(|option| match option.kind {
            acp::PermissionOptionKind::AllowOnce => allow_once_count > 1,
            acp::PermissionOptionKind::AllowAlways => allow_always_count > 1,
            acp::PermissionOptionKind::RejectOnce | acp::PermissionOptionKind::RejectAlways => {
                reject_count > 1
            }
            _ => true,
        })
        .map(|option| option.option_id.to_string())
        .collect::<HashSet<_>>();
    options
        .into_iter()
        .filter_map(|option| {
            let option_id = option.option_id.to_string();
            if option_id.trim().is_empty()
                || option_id.len() > MAX_RETAINED_PERMISSION_OPTION_ID_BYTES
                || option_id.chars().any(char::is_control)
            {
                return None;
            }
            let name = match option.kind {
                _ if preserve_provider_label.contains(&option_id) => option
                    .name
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .chars()
                    .take(MAX_RETAINED_PERMISSION_OPTION_LABEL_CHARS)
                    .collect(),
                acp::PermissionOptionKind::AllowOnce => "Allow once".to_string(),
                acp::PermissionOptionKind::AllowAlways => "Allow for session".to_string(),
                acp::PermissionOptionKind::RejectOnce | acp::PermissionOptionKind::RejectAlways => {
                    "Reject".to_string()
                }
                _ => option
                    .name
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .chars()
                    .take(MAX_RETAINED_PERMISSION_OPTION_LABEL_CHARS)
                    .collect(),
            };
            if name.is_empty() {
                return None;
            }
            Some(acp::PermissionOption::new(
                option.option_id,
                name,
                option.kind,
            ))
        })
        .take(MAX_RETAINED_PERMISSION_OPTIONS)
        .collect()
}

fn handle_elicitation_request(
    active_turns: &ActiveTurns,
    elicitations: &PendingElicitations,
    sequence: &AtomicU64,
    epoch: &str,
    request: acp::CreateElicitationRequest,
    responder: Responder<acp::CreateElicitationResponse>,
) {
    let acp::ElicitationMode::Form(form) = request.mode else {
        let _ = responder.respond(acp::CreateElicitationResponse::new(
            acp::ElicitationAction::Cancel,
        ));
        return;
    };
    let acp::ElicitationScope::Session(scope) = form.scope else {
        let _ = responder.respond(acp::CreateElicitationResponse::new(
            acp::ElicitationAction::Cancel,
        ));
        return;
    };
    let session_key = scope.session_id.to_string();
    let active = active_turns.lock().expect("ACP active turns poisoned");
    let Some(turn) = active.get(&session_key) else {
        let _ = responder.respond(acp::CreateElicitationResponse::new(
            acp::ElicitationAction::Cancel,
        ));
        return;
    };
    let turn_id = turn.turn_id.clone();
    let sender = turn.sender.clone();
    drop(active);

    let request_id = format!(
        "acp-question-{epoch}-{}",
        sequence.fetch_add(1, Ordering::Relaxed)
    );
    let normalized = match normalize_form(
        request_id.clone(),
        turn_id,
        &request.message,
        form.requested_schema,
    ) {
        Ok(normalized) => normalized,
        Err(error) => {
            log::warn!(
                target: "inline_agent_driver_acp::elicitation",
                "phase=unsupported_form error={error}"
            );
            let _ = responder.respond(acp::CreateElicitationResponse::new(
                acp::ElicitationAction::Cancel,
            ));
            return;
        }
    };
    let cancellation = responder.cancellation();
    let (completion_tx, completion_rx) = oneshot::channel();
    let event = AgentEvent::QuestionRequested(normalized.request);
    let mut pending = elicitations.lock().expect("ACP elicitation map poisoned");
    if pending.len() >= MAX_PENDING_ELICITATIONS
        || pending
            .values()
            .filter(|pending| pending.session_id == session_key)
            .count()
            >= MAX_PENDING_ELICITATIONS_PER_SESSION
    {
        drop(pending);
        let _ = responder.respond(acp::CreateElicitationResponse::new(
            acp::ElicitationAction::Cancel,
        ));
        return;
    }
    pending.insert(
        request_id.clone(),
        PendingElicitation {
            session_id: session_key,
            fields: normalized.fields,
            responder,
            completion: completion_tx,
        },
    );
    drop(pending);
    if !sender.send(Ok(event)) {
        if let Some(pending) = elicitations
            .lock()
            .expect("ACP elicitation map poisoned")
            .remove(&request_id)
        {
            let _ = pending.completion.send(());
            let _ = pending
                .responder
                .respond(acp::CreateElicitationResponse::new(
                    acp::ElicitationAction::Cancel,
                ));
        }
        return;
    }
    let elicitations = elicitations.clone();
    tokio::spawn(async move {
        tokio::select! {
            () = cancellation.cancelled() => {
                if let Some(pending) = elicitations
                    .lock()
                    .expect("ACP elicitation map poisoned")
                    .remove(&request_id)
                {
                    let _ = pending.responder.respond_with_error(
                        agent_client_protocol::Error::request_cancelled(),
                    );
                }
            }
            _ = completion_rx => {}
        }
    });
}

fn finish_turn(
    active_turns: &ActiveTurns,
    approvals: &PendingApprovals,
    elicitations: &PendingElicitations,
    session_key: &str,
    auth_methods: &[String],
    result: Result<acp::PromptResponse, agent_client_protocol::Error>,
) {
    cancel_pending_approvals(approvals, Some(session_key));
    cancel_pending_elicitations(elicitations, Some(session_key));
    let Some(turn) = active_turns
        .lock()
        .expect("ACP active turns poisoned")
        .remove(session_key)
    else {
        return;
    };
    if !turn.text.is_empty() {
        turn.sender.send(Ok(AgentEvent::AgentTextCompleted {
            turn_id: turn.turn_id.clone(),
            text: turn.text,
        }));
    }
    let (outcome, error) = match result {
        Ok(response) => (turn_outcome(response.stop_reason), None),
        Err(error) if error.code == acp::ErrorCode::RequestCancelled => {
            (TurnOutcome::Interrupted, None)
        }
        Err(error) if error.code == acp::ErrorCode::AuthRequired => {
            let authentication = auth_required(auth_methods);
            (
                TurnOutcome::AuthenticationRequired,
                Some(authentication.message),
            )
        }
        Err(error) => (TurnOutcome::Failed, Some(error.to_string())),
    };
    turn.sender.send(Ok(AgentEvent::TurnCompleted {
        turn_id: turn.turn_id,
        outcome,
        error,
        timing: TurnTiming::default(),
    }));
}

fn cancel_pending_approvals(approvals: &PendingApprovals, session_id: Option<&str>) {
    let mut approvals = approvals.lock().expect("ACP approvals poisoned");
    let ids = approvals
        .iter()
        .filter(|(_, pending)| session_id.is_none_or(|session_id| pending.session_id == session_id))
        .map(|(id, _)| id.clone())
        .collect::<Vec<_>>();
    for id in ids {
        if let Some(pending) = approvals.remove(&id) {
            let _ = pending.completion.send(());
            let _ = pending
                .responder
                .respond(acp::RequestPermissionResponse::new(
                    acp::RequestPermissionOutcome::Cancelled,
                ));
        }
    }
}

fn cancel_pending_elicitations(elicitations: &PendingElicitations, session_id: Option<&str>) {
    let mut elicitations = elicitations.lock().expect("ACP elicitation map poisoned");
    let ids = elicitations
        .iter()
        .filter(|(_, pending)| session_id.is_none_or(|session_id| pending.session_id == session_id))
        .map(|(id, _)| id.clone())
        .collect::<Vec<_>>();
    for id in ids {
        if let Some(pending) = elicitations.remove(&id) {
            let _ = pending.completion.send(());
            let _ = pending
                .responder
                .respond(acp::CreateElicitationResponse::new(
                    acp::ElicitationAction::Cancel,
                ));
        }
    }
}

fn fail_all_turns(
    active_turns: &ActiveTurns,
    approvals: &PendingApprovals,
    elicitations: &PendingElicitations,
    error: Option<&String>,
) {
    cancel_pending_approvals(approvals, None);
    cancel_pending_elicitations(elicitations, None);
    let turns = active_turns
        .lock()
        .expect("ACP active turns poisoned")
        .drain()
        .map(|(_, turn)| turn)
        .collect::<Vec<_>>();
    for turn in turns {
        turn.sender.send(Ok(AgentEvent::TurnCompleted {
            turn_id: turn.turn_id,
            outcome: TurnOutcome::ConnectionLost,
            error: Some(
                error
                    .cloned()
                    .unwrap_or_else(|| "ACP connection closed".to_string()),
            ),
            timing: TurnTiming::default(),
        }));
    }
}

fn approval_outcome(
    options: &[acp::PermissionOption],
    decision: ApprovalDecision,
) -> DriverResult<acp::RequestPermissionOutcome> {
    if matches!(decision, ApprovalDecision::CancelTurn) {
        return Ok(acp::RequestPermissionOutcome::Cancelled);
    }
    let selected = options.iter().find(|option| match &decision {
        ApprovalDecision::ApproveOnce => option.kind == acp::PermissionOptionKind::AllowOnce,
        ApprovalDecision::ApproveForSession => {
            option.kind == acp::PermissionOptionKind::AllowAlways
        }
        ApprovalDecision::Reject => matches!(
            option.kind,
            acp::PermissionOptionKind::RejectOnce | acp::PermissionOptionKind::RejectAlways
        ),
        ApprovalDecision::ProviderChoice { option_id } => {
            option.option_id.to_string() == *option_id
        }
        ApprovalDecision::CancelTurn => false,
    });
    let selected = selected.ok_or_else(|| {
        DriverError::Rejected("ACP agent did not offer that approval choice".to_string())
    })?;
    Ok(acp::RequestPermissionOutcome::Selected(
        acp::SelectedPermissionOutcome::new(selected.option_id.clone()),
    ))
}

fn acp_request_error(error: agent_client_protocol::Error, auth_methods: &[String]) -> DriverError {
    match error.code {
        acp::ErrorCode::AuthRequired => {
            DriverError::AuthenticationRequired(auth_required(auth_methods))
        }
        acp::ErrorCode::RequestCancelled => DriverError::Transient("request cancelled".to_string()),
        _ => DriverError::Rejected(error.to_string()),
    }
}

fn acp_resume_error(error: agent_client_protocol::Error, auth_methods: &[String]) -> DriverError {
    match error.code {
        acp::ErrorCode::ResourceNotFound | acp::ErrorCode::InvalidParams => {
            DriverError::InvalidSession(error.to_string())
        }
        _ => acp_request_error(error, auth_methods),
    }
}

fn auth_required(auth_methods: &[String]) -> AuthenticationRequired {
    let methods = if auth_methods.is_empty() {
        String::new()
    } else {
        format!(" Available method(s): {}.", auth_methods.join(", "))
    };
    AuthenticationRequired {
        message: format!(
            "The local ACP agent requires authentication. Run its login flow on this computer, then retry.{methods}"
        ),
    }
}

fn safe_auth_method_name(value: &str) -> String {
    if !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b' ' | b'.' | b'_' | b'-'))
    {
        value.to_string()
    } else {
        "provider login".to_string()
    }
}

async fn request_with_timeout<T>(
    operation: &'static str,
    auth_methods: &[String],
    request: impl Future<Output = Result<T, agent_client_protocol::Error>>,
) -> DriverResult<T> {
    tokio::time::timeout(REQUEST_TIMEOUT, request)
        .await
        .map_err(|_| DriverError::Transient(format!("ACP {operation} timed out")))?
        .map_err(|error| acp_request_error(error, auth_methods))
}

async fn mutating_request_with_timeout<T, M>(
    lifecycle: &ConnectionLifecycle,
    timeout: Duration,
    operation: &'static str,
    request: impl Future<Output = Result<T, agent_client_protocol::Error>>,
    map_error: M,
) -> DriverResult<T>
where
    M: FnOnce(agent_client_protocol::Error) -> DriverError,
{
    // A caller may impose a shorter presentation deadline and drop this
    // future after the request was dispatched. Dropping an armed guard ends
    // the entire connection epoch because the provider outcome is then
    // unknowable. Known completions disarm it.
    let mut cancellation_guard = lifecycle.guard_mutating_request();
    match tokio::time::timeout(timeout, request).await {
        Ok(Ok(response)) => {
            cancellation_guard.disarm();
            Ok(response)
        }
        Ok(Err(error)) => {
            cancellation_guard.disarm();
            Err(map_error(error))
        }
        Err(_) => {
            let _ = lifecycle.shutdown().await;
            Err(DriverError::ProcessExited(format!(
                "ACP {operation} timed out with an unknown provider outcome"
            )))
        }
    }
}

#[cfg(test)]
async fn request_with_timeout_after<T>(
    timeout: Duration,
    operation: &'static str,
    request: impl Future<Output = Result<T, agent_client_protocol::Error>>,
) -> DriverResult<T> {
    tokio::time::timeout(timeout, request)
        .await
        .map_err(|_| DriverError::Transient(format!("ACP {operation} timed out")))?
        .map_err(|error| acp_request_error(error, &[]))
}

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;
    use inline_agent_bridge::ApprovalOption;

    use super::*;

    #[tokio::test]
    async fn attachments_are_sent_as_standard_acp_resource_links() {
        let blocks = acp_prompt_blocks(
            TurnInput {
                text: "Inspect the file".to_string(),
                attachments: vec![InputAttachment {
                    kind: inline_agent_bridge::InputAttachmentKind::File,
                    uri: "https://cdn.inline.chat/report.pdf".to_string(),
                    local_uri: None,
                    mime_type: Some("application/pdf".to_string()),
                    file_name: Some("report.pdf".to_string()),
                    size_bytes: Some(42),
                    width: None,
                    height: None,
                    duration_ms: None,
                }],
                client_message_id: Some("message-1".to_string()),
            },
            &acp::PromptCapabilities::new(),
        )
        .await
        .expect("prompt blocks");
        assert!(matches!(
            blocks.as_slice(),
            [acp::ContentBlock::Text(_), acp::ContentBlock::ResourceLink(link)]
                if link.name == "report.pdf"
                    && link.uri == "https://cdn.inline.chat/report.pdf"
                    && link.mime_type.as_deref() == Some("application/pdf")
                    && link.size == Some(42)
        ));
    }

    #[tokio::test]
    async fn acp_prefers_the_bridge_materialized_file_uri() {
        let blocks = acp_prompt_blocks(
            TurnInput {
                text: "Inspect the file".to_string(),
                attachments: vec![InputAttachment {
                    kind: inline_agent_bridge::InputAttachmentKind::File,
                    uri: "https://cdn.inline.chat/report.pdf".to_string(),
                    local_uri: Some("file:///private/cache/report.pdf".to_string()),
                    mime_type: Some("application/pdf".to_string()),
                    file_name: Some("report.pdf".to_string()),
                    size_bytes: Some(42),
                    width: None,
                    height: None,
                    duration_ms: None,
                }],
                client_message_id: Some("message-1".to_string()),
            },
            &acp::PromptCapabilities::new(),
        )
        .await
        .expect("prompt blocks");
        assert!(matches!(
            blocks.as_slice(),
            [acp::ContentBlock::Text(_), acp::ContentBlock::ResourceLink(link)]
                if link.uri == "file:///private/cache/report.pdf"
        ));
    }

    #[tokio::test]
    async fn advertised_image_capability_uses_native_content_with_local_uri() {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("image.png");
        tokio::fs::write(&path, b"abc").await.expect("image");
        let local_uri = url::Url::from_file_path(&path)
            .expect("file URL")
            .to_string();
        let blocks = acp_prompt_blocks(
            TurnInput {
                text: "Inspect the image".to_string(),
                attachments: vec![InputAttachment {
                    kind: InputAttachmentKind::Image,
                    uri: "https://cdn.inline.chat/image.png".to_string(),
                    local_uri: Some(local_uri.clone()),
                    mime_type: Some("image/png".to_string()),
                    file_name: Some("image.png".to_string()),
                    size_bytes: Some(3),
                    width: Some(1),
                    height: Some(1),
                    duration_ms: None,
                }],
                client_message_id: Some("message-1".to_string()),
            },
            &acp::PromptCapabilities::new().image(true),
        )
        .await
        .expect("prompt blocks");
        assert!(matches!(
            blocks.as_slice(),
            [
                acp::ContentBlock::Text(_),
                acp::ContentBlock::Image(image),
                acp::ContentBlock::ResourceLink(link)
            ]
                if image.data == "YWJj"
                    && image.mime_type == "image/png"
                    && image.uri.as_deref() == Some(local_uri.as_str())
                    && link.uri == local_uri
        ));
    }

    #[tokio::test]
    async fn advertised_audio_capability_keeps_native_audio_and_local_resource() {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("voice.m4a");
        tokio::fs::write(&path, b"abc").await.expect("audio");
        let local_uri = url::Url::from_file_path(&path)
            .expect("file URL")
            .to_string();
        let blocks = acp_prompt_blocks(
            TurnInput {
                text: "Review the voice message".to_string(),
                attachments: vec![InputAttachment {
                    kind: InputAttachmentKind::Audio,
                    uri: "https://cdn.inline.chat/voice.m4a".to_string(),
                    local_uri: Some(local_uri.clone()),
                    mime_type: Some("audio/mp4".to_string()),
                    file_name: Some("voice.m4a".to_string()),
                    size_bytes: Some(3),
                    width: None,
                    height: None,
                    duration_ms: Some(1_000),
                }],
                client_message_id: Some("message-1".to_string()),
            },
            &acp::PromptCapabilities::new().audio(true),
        )
        .await
        .expect("prompt blocks");
        assert!(matches!(
            blocks.as_slice(),
            [
                acp::ContentBlock::Text(_),
                acp::ContentBlock::Audio(audio),
                acp::ContentBlock::ResourceLink(link)
            ] if audio.data == "YWJj"
                && audio.mime_type == "audio/mp4"
                && link.uri == local_uri
        ));
    }

    #[tokio::test]
    async fn native_agent_image_becomes_a_verified_output_attachment() {
        let cache = tempfile::tempdir().expect("cache");
        let bytes = b"\x89PNG\r\n\x1a\ninline-test";
        let image = acp::ImageContent::new(
            base64::engine::general_purpose::STANDARD.encode(bytes),
            "image/png",
        );

        let attachment = materialize_acp_output_image(&image, cache.path())
            .await
            .expect("output attachment");

        assert_eq!(attachment.kind, OutputAttachmentKind::Image);
        assert_eq!(attachment.mime_type, "image/png");
        assert_eq!(attachment.file_name, "generated-image.png");
        assert_eq!(attachment.size_bytes, bytes.len() as u64);
        assert_eq!(
            tokio::fs::read(&attachment.path).await.expect("bytes"),
            bytes
        );
        assert_eq!(attachment.sha256, format!("{:x}", Sha256::digest(bytes)));
    }

    #[test]
    fn final_agent_text_is_bounded_at_the_driver_boundary() {
        let mut text = String::new();
        append_bounded_agent_text(&mut text, &"x".repeat(MAX_FINAL_AGENT_TEXT_BYTES * 2));
        append_bounded_agent_text(&mut text, "ignored after truncation");

        assert!(text.len() <= MAX_FINAL_AGENT_TEXT_BYTES + TRUNCATED_AGENT_TEXT_MARKER.len());
        assert!(text.ends_with(TRUNCATED_AGENT_TEXT_MARKER));
        assert!(!text.contains("ignored after truncation"));
    }

    #[tokio::test]
    async fn tool_activity_separates_distinct_agent_messages() {
        let active_turns = ActiveTurns::default();
        let sessions = Sessions::default();
        let (sender, _events) = AgentEventReceiver::default_channel();
        active_turns.lock().expect("turns").insert(
            "session-1".to_string(),
            ActiveTurn {
                turn_id: TurnId::new("turn-1").expect("turn"),
                sender,
                text: String::new(),
                separate_next_agent_message: false,
                tool_calls: ToolCallSnapshots::new(),
            },
        );

        for update in [
            acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(acp::ContentBlock::Text(
                acp::TextContent::new("Before."),
            ))),
            acp::SessionUpdate::ToolCall(acp::ToolCall::new("tool-1", "Read the project")),
            acp::SessionUpdate::AgentMessageChunk(acp::ContentChunk::new(acp::ContentBlock::Text(
                acp::TextContent::new("After."),
            ))),
        ] {
            handle_session_update(
                &active_turns,
                &sessions,
                None,
                acp::SessionNotification::new("session-1", update),
            )
            .await;
        }

        assert_eq!(
            active_turns
                .lock()
                .expect("turns")
                .get("session-1")
                .expect("active turn")
                .text,
            "Before.\n\nAfter."
        );
    }

    #[test]
    fn capability_mapping_is_strictly_advertisement_driven() {
        let none = map_capabilities(&acp::AgentCapabilities::new());
        assert!(!none.resume_session);
        assert!(none.cancel_turn);
        assert!(none.settings_catalog_starts_session);
        assert!(none.session_commands);
        assert_eq!(none.steering, SteeringSupport::Unsupported);

        let advertised = map_capabilities(&acp::AgentCapabilities::new().session_capabilities(
            acp::SessionCapabilities::new().resume(acp::SessionResumeCapabilities::new()),
        ));
        assert!(advertised.resume_session);
        assert!(map_capabilities(&acp::AgentCapabilities::new().load_session(true)).resume_session);
    }

    #[tokio::test]
    async fn available_command_updates_are_session_owned_without_an_active_turn() {
        let active_turns = ActiveTurns::default();
        let sessions = Sessions::default();
        sessions.lock().expect("sessions").sessions.insert(
            "session-1".to_string(),
            SessionMetadata {
                cwd: PathBuf::from("/workspace"),
                config_options: Vec::new(),
                modes: None,
                commands: Vec::new(),
            },
        );
        handle_session_update(
            &active_turns,
            &sessions,
            None,
            acp::SessionNotification::new(
                "session-1",
                acp::SessionUpdate::AvailableCommandsUpdate(acp::AvailableCommandsUpdate::new(
                    vec![acp::AvailableCommand::new(
                        "research_codebase",
                        "Research the selected project",
                    )],
                )),
            ),
        )
        .await;
        let commands = sessions
            .lock()
            .expect("sessions")
            .sessions
            .get("session-1")
            .expect("session")
            .commands
            .clone();
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].name, "research_codebase");
    }

    #[tokio::test]
    async fn current_mode_updates_only_accept_advertised_session_modes() {
        let active_turns = ActiveTurns::default();
        let sessions = Sessions::default();
        sessions.lock().expect("sessions").sessions.insert(
            "session-1".to_string(),
            SessionMetadata {
                cwd: PathBuf::from("/workspace"),
                config_options: Vec::new(),
                modes: Some(acp::SessionModeState::new(
                    "default",
                    vec![
                        acp::SessionMode::new("default", "Manual"),
                        acp::SessionMode::new("bypassPermissions", "Bypass Permissions"),
                    ],
                )),
                commands: Vec::new(),
            },
        );
        for mode in ["bypassPermissions", "unadvertised"] {
            handle_session_update(
                &active_turns,
                &sessions,
                None,
                acp::SessionNotification::new(
                    "session-1",
                    acp::SessionUpdate::CurrentModeUpdate(acp::CurrentModeUpdate::new(mode)),
                ),
            )
            .await;
        }
        let current = sessions
            .lock()
            .expect("sessions")
            .sessions
            .get("session-1")
            .and_then(|session| session.modes.as_ref())
            .expect("modes")
            .current_mode_id
            .to_string();
        assert_eq!(current, "bypassPermissions");
    }

    #[tokio::test]
    async fn connection_epoch_loss_is_a_typed_terminal_outcome() {
        let active_turns = ActiveTurns::default();
        let approvals = PendingApprovals::default();
        let elicitations = PendingElicitations::default();
        let (sender, mut events) = AgentEventReceiver::default_channel();
        let turn_id = TurnId::new("turn-1").expect("turn");
        active_turns.lock().expect("turns").insert(
            "session-1".to_string(),
            ActiveTurn {
                turn_id: turn_id.clone(),
                sender,
                text: String::new(),
                separate_next_agent_message: false,
                tool_calls: ToolCallSnapshots::new(),
            },
        );

        fail_all_turns(
            &active_turns,
            &approvals,
            &elicitations,
            Some(&"ACP transport closed".to_string()),
        );

        assert!(matches!(
            events.next().await,
            Some(Ok(AgentEvent::TurnCompleted {
                turn_id: completed,
                outcome: TurnOutcome::ConnectionLost,
                ..
            })) if completed == turn_id
        ));
        assert!(active_turns.lock().expect("turns").is_empty());
    }

    #[test]
    fn approval_mapping_preserves_exact_provider_choice() {
        let options = bounded_permission_options(vec![
            acp::PermissionOption::new(
                "exit-plan-auto",
                "Yes, and use auto mode",
                acp::PermissionOptionKind::AllowAlways,
            ),
            acp::PermissionOption::new(
                "exit-plan-default",
                "Yes, manually approve edits",
                acp::PermissionOptionKind::AllowAlways,
            ),
        ]);
        assert!(matches!(
            permission_options(&options).as_slice(),
            [
                ApprovalOption::ProviderChoice { option_id, label },
                ApprovalOption::ProviderChoice { .. },
                ApprovalOption::CancelTurn,
            ] if option_id == "exit-plan-auto" && label == "Yes, and use auto mode"
        ));
        let outcome = approval_outcome(
            &options,
            ApprovalDecision::ProviderChoice {
                option_id: "exit-plan-default".to_string(),
            },
        )
        .expect("provider choice");
        assert!(matches!(
            outcome,
            acp::RequestPermissionOutcome::Selected(selected)
                if selected.option_id.to_string() == "exit-plan-default"
        ));
    }

    #[test]
    fn retained_permission_options_are_count_and_byte_bounded() {
        let mut options = (0..(MAX_RETAINED_PERMISSION_OPTIONS + 4))
            .map(|index| {
                acp::PermissionOption::new(
                    format!("option-{index}"),
                    format!("Provider choice {index}"),
                    acp::PermissionOptionKind::AllowOnce,
                )
            })
            .collect::<Vec<_>>();
        options.insert(
            0,
            acp::PermissionOption::new(
                "x".repeat(MAX_RETAINED_PERMISSION_OPTION_ID_BYTES + 1),
                "oversized",
                acp::PermissionOptionKind::AllowOnce,
            ),
        );

        let bounded = bounded_permission_options(options);
        assert_eq!(bounded.len(), MAX_RETAINED_PERMISSION_OPTIONS);
        assert!(bounded.iter().all(|option| {
            option.option_id.to_string().len() <= MAX_RETAINED_PERMISSION_OPTION_ID_BYTES
                && option.name.len() <= MAX_RETAINED_PERMISSION_OPTION_LABEL_CHARS
        }));
    }

    #[tokio::test]
    async fn request_timeout_is_bounded_and_names_the_operation() {
        let result: DriverResult<()> = request_with_timeout_after(
            Duration::from_millis(5),
            "session/new",
            std::future::pending(),
        )
        .await;
        assert_eq!(
            result,
            Err(DriverError::Transient(
                "ACP session/new timed out".to_string()
            ))
        );
    }

    #[tokio::test]
    async fn ambiguous_mutating_timeout_stops_the_connection_epoch() {
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let (completion_tx, completion_rx) = watch::channel(None);
        let stopped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let observed = stopped.clone();
        tokio::spawn(async move {
            let _ = shutdown_rx.await;
            observed.store(true, std::sync::atomic::Ordering::Release);
            let _ = completion_tx.send(Some(Ok(())));
        });
        let lifecycle = ConnectionLifecycle {
            shutdown: Arc::new(StdMutex::new(Some(shutdown_tx))),
            completion: completion_rx,
        };

        let result: DriverResult<()> = mutating_request_with_timeout(
            &lifecycle,
            Duration::from_millis(5),
            "session/new",
            std::future::pending::<Result<(), agent_client_protocol::Error>>(),
            |_| DriverError::Protocol("unexpected response".to_string()),
        )
        .await;
        assert!(matches!(result, Err(DriverError::ProcessExited(_))));
        assert!(stopped.load(std::sync::atomic::Ordering::Acquire));
    }

    #[tokio::test]
    async fn ambiguous_timeout_does_not_wait_forever_for_epoch_shutdown() {
        let (shutdown_tx, _shutdown_rx) = oneshot::channel();
        let (_completion_tx, completion_rx) = watch::channel(None);
        let lifecycle = ConnectionLifecycle {
            shutdown: Arc::new(StdMutex::new(Some(shutdown_tx))),
            completion: completion_rx,
        };

        let result: DriverResult<()> = tokio::time::timeout(
            Duration::from_secs(1),
            mutating_request_with_timeout(
                &lifecycle,
                Duration::from_millis(5),
                "session/new",
                std::future::pending::<Result<(), agent_client_protocol::Error>>(),
                |_| DriverError::Protocol("unexpected response".to_string()),
            ),
        )
        .await
        .expect("ambiguous shutdown must remain bounded");
        assert!(matches!(result, Err(DriverError::ProcessExited(_))));
    }

    #[tokio::test]
    async fn dropping_a_dispatched_mutation_ends_the_connection_epoch() {
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let (_completion_tx, completion_rx) = watch::channel(None);
        let lifecycle = ConnectionLifecycle {
            shutdown: Arc::new(StdMutex::new(Some(shutdown_tx))),
            completion: completion_rx,
        };

        let outer = tokio::time::timeout(
            Duration::from_millis(10),
            mutating_request_with_timeout(
                &lifecycle,
                Duration::from_secs(1),
                "session/new",
                std::future::pending::<Result<(), agent_client_protocol::Error>>(),
                |_| DriverError::Protocol("unexpected provider error".to_string()),
            ),
        )
        .await;
        assert!(outer.is_err(), "the outer catalog deadline must fire first");
        tokio::time::timeout(Duration::from_millis(100), &mut shutdown_rx)
            .await
            .expect("dropping the mutation must signal epoch shutdown")
            .expect("shutdown sender must remain live until cancellation");
    }

    #[test]
    fn auth_required_error_is_actionable_and_sanitized() {
        let authentication = auth_required(&[safe_auth_method_name("Claude login")]);
        assert_eq!(
            authentication.message,
            "The local ACP agent requires authentication. Run its login flow on this computer, then retry. Available method(s): Claude login."
        );
        assert!(
            !auth_required(&[safe_auth_method_name("token=$SECRET")])
                .message
                .contains("SECRET")
        );
    }

    #[test]
    fn classifies_the_acp_auth_required_code_without_inspecting_its_message() {
        let error = agent_client_protocol::Error::new(
            i32::from(acp::ErrorCode::AuthRequired),
            "arbitrary provider wording",
        );
        assert!(matches!(
            acp_request_error(error, &[]),
            DriverError::AuthenticationRequired(AuthenticationRequired { message })
                if message == "The local ACP agent requires authentication. Run its login flow on this computer, then retry."
        ));
    }
}

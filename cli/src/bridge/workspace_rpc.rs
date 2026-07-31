//! Host-local workspace registration for the macOS Inline app.
//!
//! The independently installed bridge cannot use InlineMac's app-group Data
//! Vault. Instead, it owns an ephemeral `127.0.0.1` listener for one service
//! epoch. Every request proves possession of a random per-epoch capability and
//! is scoped to one configured bridge host and bot. This is deliberately not a
//! general network API: it accepts neither non-loopback connections nor paths
//! through Inline's settings/mutation transport.

use super::*;
#[cfg(target_os = "macos")]
use std::net::Ipv4Addr;
#[cfg(target_os = "macos")]
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
#[cfg(target_os = "macos")]
use tokio::net::TcpListener;
#[cfg(target_os = "macos")]
use tokio::net::TcpStream;

#[cfg(target_os = "macos")]
const WORKSPACE_RPC_VERSION: u32 = 1;
#[cfg(target_os = "macos")]
const MAX_RPC_BYTES: usize = 8 * 1024;
#[cfg(target_os = "macos")]
const RPC_TIMEOUT: Duration = Duration::from_secs(3);
#[cfg(target_os = "macos")]
const MAX_CONCURRENT_HANDLERS: usize = 8;
#[cfg(target_os = "macos")]
const CAPABILITY_BYTES: usize = 32;

/// The only endpoint data carried through the owner-authorized bot-settings
/// document. The capability is opaque and valid only until this service exits.
#[derive(Clone)]
pub(super) struct WorkspacePickerEndpoint {
    pub(super) port: u16,
    pub(super) capability: String,
}

impl std::fmt::Debug for WorkspacePickerEndpoint {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WorkspacePickerEndpoint")
            .field("port", &self.port)
            .field("capability", &"<redacted>")
            .finish()
    }
}

#[cfg(target_os = "macos")]
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceRegistrationRequest {
    version: u32,
    action: WorkspaceRegistrationAction,
    host_installation_id: String,
    bot_user_id: i64,
    capability: String,
    path: Option<PathBuf>,
}

#[cfg(target_os = "macos")]
impl std::fmt::Debug for WorkspaceRegistrationRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WorkspaceRegistrationRequest")
            .field("version", &self.version)
            .field("action", &self.action)
            .field("host_installation_id", &self.host_installation_id)
            .field("bot_user_id", &self.bot_user_id)
            .field("capability", &"<redacted>")
            .field("path", &self.path.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

#[cfg(target_os = "macos")]
#[derive(Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum WorkspaceRegistrationAction {
    Probe,
    Register,
}

#[cfg(target_os = "macos")]
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceRegistrationResponse {
    version: u32,
    status: String,
    workspace_id: Option<String>,
    display_name: Option<String>,
    parent_hint: Option<String>,
    detail: Option<String>,
}

#[cfg(target_os = "macos")]
impl WorkspaceRegistrationResponse {
    fn available() -> Self {
        Self {
            version: WORKSPACE_RPC_VERSION,
            status: "available".to_string(),
            workspace_id: None,
            display_name: None,
            parent_hint: None,
            detail: None,
        }
    }

    fn registered(record: &inline_agent_bridge::WorkspaceRecord) -> Self {
        Self {
            version: WORKSPACE_RPC_VERSION,
            status: "registered".to_string(),
            workspace_id: Some(record.workspace_id.to_string()),
            display_name: Some(record.display_name.clone()),
            parent_hint: record.parent_hint.clone(),
            detail: None,
        }
    }

    fn failed(status: &str, detail: impl Into<String>) -> Self {
        Self {
            version: WORKSPACE_RPC_VERSION,
            status: status.to_string(),
            workspace_id: None,
            display_name: None,
            parent_hint: None,
            detail: Some(safe_diagnostic(&detail.into())),
        }
    }
}

pub(super) struct WorkspaceRegistrar {
    #[cfg(target_os = "macos")]
    endpoint: WorkspacePickerEndpoint,
    #[cfg(target_os = "macos")]
    task: tokio::task::JoinHandle<()>,
}

impl WorkspaceRegistrar {
    /// Returns `None` off macOS. The Mac client must probe the exact endpoint
    /// before it enables its folder panel, so stale settings after a service
    /// restart simply show the existing remote-host fallback.
    pub(super) async fn bind(
        paths: &BridgePaths,
        account: AccountBridgeConfig,
    ) -> Result<Option<Self>, Box<dyn std::error::Error>> {
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (paths, account);
            return Ok(None);
        }

        #[cfg(target_os = "macos")]
        {
            let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
            let address = listener.local_addr()?;
            if !address.ip().is_loopback() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrNotAvailable,
                    "workspace registrar did not bind loopback",
                )
                .into());
            }
            let endpoint = WorkspacePickerEndpoint {
                port: address.port(),
                capability: random_capability(),
            };
            let endpoint_for_task = endpoint.clone();
            let paths = paths.clone();
            let permits = Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT_HANDLERS));
            let task = tokio::spawn(async move {
                loop {
                    let Ok((stream, peer)) = listener.accept().await else {
                        break;
                    };
                    if !peer.ip().is_loopback() {
                        continue;
                    }
                    let Ok(permit) = permits.clone().try_acquire_owned() else {
                        continue;
                    };
                    let account = account.clone();
                    let paths = paths.clone();
                    let endpoint = endpoint_for_task.clone();
                    tokio::spawn(async move {
                        let _permit = permit;
                        let _ = handle_connection(stream, &paths, &account, &endpoint).await;
                    });
                }
            });
            Ok(Some(Self { endpoint, task }))
        }
    }

    pub(super) fn endpoint(&self) -> WorkspacePickerEndpoint {
        #[cfg(target_os = "macos")]
        {
            self.endpoint.clone()
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = self;
            unreachable!("workspace picker endpoints exist only on macOS")
        }
    }

    pub(super) async fn close(self) {
        #[cfg(target_os = "macos")]
        {
            self.task.abort();
            let _ = self.task.await;
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = self;
        }
    }
}

/// Exercises the same private endpoint used by InlineMac without exposing its
/// capability in debug output. A missing path performs a read-only probe;
/// otherwise the path is registered and the new opaque workspace ID is
/// returned.
#[cfg(target_os = "macos")]
pub(super) async fn call_workspace_picker(
    endpoint: &WorkspacePickerEndpoint,
    host_installation_id: &str,
    bot_user_id: i64,
    path: Option<PathBuf>,
) -> Result<Option<String>, Box<dyn std::error::Error>> {
    if endpoint.port < 1024
        || endpoint.capability.len() < CAPABILITY_BYTES
        || endpoint.capability.len() > 128
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "workspace picker endpoint is invalid",
        )
        .into());
    }
    let action = if path.is_some() {
        WorkspaceRegistrationAction::Register
    } else {
        WorkspaceRegistrationAction::Probe
    };
    let request = WorkspaceRegistrationRequest {
        version: WORKSPACE_RPC_VERSION,
        action,
        host_installation_id: host_installation_id.to_string(),
        bot_user_id,
        capability: endpoint.capability.clone(),
        path,
    };
    let mut bytes = serde_json::to_vec(&request)?;
    if bytes.len() >= MAX_RPC_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "workspace picker request is too large",
        )
        .into());
    }
    bytes.push(b'\n');

    let mut stream = tokio::time::timeout(
        RPC_TIMEOUT,
        TcpStream::connect((Ipv4Addr::LOCALHOST, endpoint.port)),
    )
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "workspace picker timed out"))??;
    tokio::time::timeout(RPC_TIMEOUT, stream.write_all(&bytes))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "workspace picker timed out"))??;

    let mut response_bytes = Vec::with_capacity(MAX_RPC_BYTES.min(1024));
    let read = tokio::time::timeout(RPC_TIMEOUT, async {
        BufReader::new(stream)
            .take((MAX_RPC_BYTES + 1) as u64)
            .read_until(b'\n', &mut response_bytes)
            .await
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "workspace picker timed out"))??;
    if read == 0 || response_bytes.len() > MAX_RPC_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "workspace picker returned an invalid response",
        )
        .into());
    }
    let response: WorkspaceRegistrationResponse = serde_json::from_slice(&response_bytes)?;
    if response.version != WORKSPACE_RPC_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "workspace picker protocol version is unsupported",
        )
        .into());
    }
    match response.status.as_str() {
        "available" => Ok(None),
        "registered" => response.workspace_id.map(Some).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "workspace picker omitted the workspace ID",
            )
            .into()
        }),
        _ => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            response
                .detail
                .unwrap_or_else(|| "workspace picker rejected the request".to_string()),
        )
        .into()),
    }
}

/// Registers a workspace without a running endpoint. This powers the local
/// CLI escape hatch and deliberately uses the same validation/registration
/// path as the macOS endpoint.
pub(super) fn register_workspace(
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    host_installation_id: &str,
    bot_user_id: i64,
    path: PathBuf,
) -> Result<inline_agent_bridge::WorkspaceRecord, Box<dyn std::error::Error>> {
    if account.host_installation_id != host_installation_id {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "workspace request is for a different bridge host",
        )
        .into());
    }
    let provider = account
        .providers
        .iter()
        .find(|candidate| candidate.bot_user_id == bot_user_id)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                "workspace request does not match a configured agent bot",
            )
        })?;
    let canonical = validate_workspace_choice(canonical_workspace(&path)?)?;
    let installation_id = InstallationId::new(provider.installation_id.clone())?;
    let workspace_id = workspace_id(&canonical)?;
    let store = BridgeStore::open(paths.provider_paths(provider).bridge_db)?;
    let now = now_seconds();
    store.put_installation(&InstallationRecord {
        installation_id: installation_id.clone(),
        provider_id: ProviderId::new(provider.provider_id.clone())?,
        display_name: provider.display_name.clone(),
        created_at: now,
        updated_at: now,
    })?;
    Ok(store.select_workspace(&installation_id, &workspace_id, &canonical, now_seconds())?)
}

#[cfg(target_os = "macos")]
fn random_capability() -> String {
    let mut bytes = [0_u8; CAPABILITY_BYTES];
    OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(target_os = "macos")]
fn constant_time_eq(expected: &str, actual: &str) -> bool {
    if expected.len() != actual.len() {
        return false;
    }
    let mut difference = 0_u8;
    for (expected, actual) in expected.bytes().zip(actual.bytes()) {
        difference |= expected ^ actual;
    }
    difference == 0
}

#[cfg(target_os = "macos")]
async fn handle_connection(
    stream: TcpStream,
    paths: &BridgePaths,
    account: &AccountBridgeConfig,
    endpoint: &WorkspacePickerEndpoint,
) -> io::Result<()> {
    let peer = stream.peer_addr()?;
    if !peer.ip().is_loopback() {
        return Ok(());
    }
    let (reader, mut writer) = stream.into_split();
    let reader = BufReader::new(reader);
    let mut request_bytes = Vec::with_capacity(MAX_RPC_BYTES.min(1024));
    let response = match tokio::time::timeout(RPC_TIMEOUT, async {
        reader
            .take((MAX_RPC_BYTES + 1) as u64)
            .read_until(b'\n', &mut request_bytes)
            .await
    })
    .await
    {
        Ok(Ok(read)) if read > 0 && request_bytes.len() <= MAX_RPC_BYTES => {
            match serde_json::from_slice::<WorkspaceRegistrationRequest>(&request_bytes) {
                Ok(request) if request.version != WORKSPACE_RPC_VERSION => {
                    WorkspaceRegistrationResponse::failed(
                        "unsupported_version",
                        "unsupported workspace RPC version",
                    )
                }
                Ok(request)
                    if !constant_time_eq(&endpoint.capability, &request.capability)
                        || account.host_installation_id != request.host_installation_id =>
                {
                    WorkspaceRegistrationResponse::failed(
                        "unauthorized",
                        "workspace request rejected",
                    )
                }
                Ok(request) if request.action == WorkspaceRegistrationAction::Probe => {
                    if account
                        .providers
                        .iter()
                        .any(|provider| provider.bot_user_id == request.bot_user_id)
                    {
                        WorkspaceRegistrationResponse::available()
                    } else {
                        WorkspaceRegistrationResponse::failed(
                            "unauthorized",
                            "workspace request rejected",
                        )
                    }
                }
                Ok(request) if request.action == WorkspaceRegistrationAction::Register => {
                    match request.path {
                        Some(path) => match register_workspace(
                            paths,
                            account,
                            &request.host_installation_id,
                            request.bot_user_id,
                            path,
                        ) {
                            Ok(record) => WorkspaceRegistrationResponse::registered(&record),
                            Err(error) => {
                                WorkspaceRegistrationResponse::failed("rejected", error.to_string())
                            }
                        },
                        None => WorkspaceRegistrationResponse::failed(
                            "invalid_request",
                            "missing folder path",
                        ),
                    }
                }
                Ok(_) => WorkspaceRegistrationResponse::failed(
                    "invalid_request",
                    "workspace request was invalid",
                ),
                Err(_) => WorkspaceRegistrationResponse::failed(
                    "invalid_request",
                    "workspace request was malformed",
                ),
            }
        }
        _ => WorkspaceRegistrationResponse::failed(
            "invalid_request",
            "workspace request was invalid or timed out",
        ),
    };
    let mut bytes = serde_json::to_vec(&response)?;
    bytes.push(b'\n');
    tokio::time::timeout(RPC_TIMEOUT, async {
        writer.write_all(&bytes).await?;
        writer.shutdown().await
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "workspace response timed out"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn account() -> AccountBridgeConfig {
        AccountBridgeConfig {
            version: ACCOUNT_CONFIG_VERSION,
            owner_user_id: 7,
            host_installation_id: "host-123".to_string(),
            host_label: "Mo's Mac".to_string(),
            api_base_url: "https://api.inline.chat".to_string(),
            realtime_url: "wss://api.inline.chat".to_string(),
            service_label: "test".to_string(),
            service_binary: PathBuf::from("/tmp/inline"),
            provider_path: String::new(),
            superseded_service_labels: Vec::new(),
            operator_user_ids: vec![7],
            owner_control_cursor_seeded: true,
            providers: vec![ProviderInstallationConfig {
                installation_id: "codex-7".to_string(),
                provider_id: "codex".to_string(),
                bot_user_id: 17,
                bot_username: "mo_codex".to_string(),
                dm_chat_id: Some(1),
                workspace: PathBuf::from("/tmp"),
                greeting_sent: true,
                accept_messages_after: 0,
                initial_cursor_seeded: true,
                display_name: "Mo's Codex".to_string(),
                managed_avatar_digest: None,
                managed_avatar_file_unique_id: None,
                executable: PathBuf::from("/bin/true"),
                provider_runtime: None,
                provider_path: String::new(),
                state_dir: PathBuf::from("unused"),
            }],
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn capabilities_are_high_entropy_and_compared_without_early_byte_exit() {
        let first = random_capability();
        let second = random_capability();
        assert_eq!(first.len(), CAPABILITY_BYTES * 2);
        assert_ne!(first, second);
        assert!(constant_time_eq(&first, &first));
        let replacement = if first.starts_with('0') { '1' } else { '0' };
        assert!(!constant_time_eq(
            &first,
            &format!("{replacement}{}", &first[1..])
        ));
        assert!(!constant_time_eq(&first, "short"));
    }

    #[test]
    fn registration_requires_exact_host_bot_and_provider_mapping() {
        let directory = tempdir().expect("tempdir");
        let root = directory.path().join("bridge");
        let paths = BridgePaths::from_root(root.clone(), root.join("bin/inline"));
        let mut account = account();
        account.providers[0].state_dir = root.join("providers/codex");
        ensure_private_dir(&account.providers[0].state_dir).expect("state dir");
        let project = directory.path().join("project");
        fs::create_dir(&project).expect("project");

        let registered = register_workspace(&paths, &account, "host-123", 17, project)
            .expect("exact mapping registers");
        assert!(registered.workspace_id.as_str().starts_with("workspace-"));
        assert!(
            register_workspace(
                &paths,
                &account,
                "other-host",
                17,
                directory.path().to_path_buf(),
            )
            .is_err()
        );
        assert!(
            register_workspace(
                &paths,
                &account,
                "host-123",
                18,
                directory.path().to_path_buf(),
            )
            .is_err()
        );
    }

    #[test]
    fn root_and_home_are_not_valid_workspace_choices() {
        assert!(validate_workspace_choice(PathBuf::from("/")).is_err());
        if let Some(home) = env::var_os("HOME")
            && let Ok(home) = fs::canonicalize(home)
        {
            assert!(validate_workspace_choice(home).is_err());
        }
    }

    #[test]
    fn workspace_capability_and_path_debug_are_redacted() {
        let endpoint = WorkspacePickerEndpoint {
            port: 4321,
            capability: "picker-secret".to_string(),
        };
        let endpoint_debug = format!("{endpoint:?}");
        assert!(endpoint_debug.contains("<redacted>"));
        assert!(!endpoint_debug.contains("picker-secret"));

        let request = WorkspaceRegistrationRequest {
            version: WORKSPACE_RPC_VERSION,
            action: WorkspaceRegistrationAction::Register,
            host_installation_id: "host-test".to_string(),
            bot_user_id: 42,
            capability: "request-secret".to_string(),
            path: Some(PathBuf::from("/private/project")),
        };
        let request_debug = format!("{request:?}");
        assert!(request_debug.contains("<redacted>"));
        assert!(!request_debug.contains("request-secret"));
        assert!(!request_debug.contains("/private/project"));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn endpoint_is_loopback_capability_scoped_and_rejects_stale_or_wrong_authority() {
        let directory = tempdir().expect("tempdir");
        let root = directory.path().join("bridge");
        let paths = BridgePaths::from_root(root.clone(), root.join("bin/inline"));
        let mut account = account();
        account.providers[0].state_dir = root.join("providers/codex");
        ensure_private_dir(&account.providers[0].state_dir).expect("state dir");
        let project = directory.path().join("project");
        fs::create_dir(&project).expect("project");
        let registrar = WorkspaceRegistrar::bind(&paths, account.clone())
            .await
            .expect("bind")
            .expect("mac endpoint");
        let endpoint = registrar.endpoint();
        assert!(endpoint.port > 0);
        assert_eq!(endpoint.capability.len(), CAPABILITY_BYTES * 2);

        assert_eq!(
            call_workspace_picker(&endpoint, "host-123", 17, None)
                .await
                .expect("probe"),
            None
        );
        let wrong_capability = WorkspacePickerEndpoint {
            port: endpoint.port,
            capability: random_capability(),
        };
        assert!(
            call_workspace_picker(&wrong_capability, "host-123", 17, None)
                .await
                .is_err()
        );
        assert!(
            call_workspace_picker(&endpoint, "other-host", 17, None)
                .await
                .is_err()
        );
        assert!(
            call_workspace_picker(&endpoint, "host-123", 18, None)
                .await
                .is_err()
        );
        let workspace_id = call_workspace_picker(&endpoint, "host-123", 17, Some(project.clone()))
            .await
            .expect("register")
            .expect("workspace id");
        assert!(workspace_id.starts_with("workspace-"));

        let stale_endpoint = endpoint;
        registrar.close().await;
        let replacement = WorkspaceRegistrar::bind(&paths, account)
            .await
            .expect("replacement bind")
            .expect("replacement endpoint");
        assert!(
            call_workspace_picker(&stale_endpoint, "host-123", 17, None)
                .await
                .is_err()
        );
        assert_eq!(
            call_workspace_picker(&replacement.endpoint(), "host-123", 17, None)
                .await
                .expect("replacement probe"),
            None
        );
        replacement.close().await;
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn endpoint_bounds_oversized_requests_before_deserialization() {
        let directory = tempdir().expect("tempdir");
        let root = directory.path().join("bridge");
        let paths = BridgePaths::from_root(root.clone(), root.join("bin/inline"));
        let registrar = WorkspaceRegistrar::bind(&paths, account())
            .await
            .expect("bind")
            .expect("mac endpoint");
        let endpoint = registrar.endpoint();
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, endpoint.port))
            .await
            .expect("connect loopback");
        let oversized = vec![b'x'; MAX_RPC_BYTES + 1];
        stream.write_all(&oversized).await.expect("write oversized");
        let mut response = Vec::new();
        BufReader::new(stream)
            .read_until(b'\n', &mut response)
            .await
            .expect("read response");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&response).expect("json")["status"],
            "invalid_request"
        );
        registrar.close().await;
    }
}

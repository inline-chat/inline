//! Stable ACP stdio-MCP adapter for bridge-owned host tools.
//!
//! ACP agents must support stdio MCP servers. The agent launches this same
//! Inline executable in a hidden MCP mode, and that tiny child proxies bounded
//! tool calls to an epoch-local loopback listener. The listener alone owns the
//! shared [`HostToolConfiguration`], provider session mapping, and active-turn
//! resolver, so the child receives no Inline credential or durable state.

use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use agent_client_protocol::schema::v1 as acp;
use inline_agent_bridge::{
    DriverError, DriverResult, HostToolCall, HostToolConfiguration, HostToolResult, HostToolSpec,
    ProviderSessionId, TurnId,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, watch};

const PROXY_VERSION: u32 = 1;
const MCP_SERVER_NAME: &str = "inline";
const ENDPOINT_ENV: &str = "INLINE_ACP_MCP_PORT";
const CAPABILITY_ENV: &str = "INLINE_ACP_MCP_CAPABILITY";
const MAX_PROXY_BYTES: usize = 256 * 1024;
const MAX_MCP_MESSAGE_BYTES: usize = 256 * 1024;
const MAX_TOOL_ARGUMENT_BYTES: usize = 32 * 1024;
const MAX_TOOL_RESULT_CHARS: usize = 16_000;
const MAX_CALL_ID_BYTES: usize = 256;
const MAX_SESSION_CAPABILITIES: usize = 4_096;
const MAX_CONCURRENT_PROXY_CALLS: usize = 16;
const PROXY_IO_TIMEOUT: Duration = Duration::from_secs(25);
const HOST_TOOL_TIMEOUT: Duration = Duration::from_secs(20);
const CURRENT_MCP_PROTOCOL_VERSION: &str = "2025-06-18";
const SUPPORTED_MCP_PROTOCOL_VERSIONS: [&str; 3] =
    [CURRENT_MCP_PROTOCOL_VERSION, "2025-03-26", "2024-11-05"];

type TurnResolver = Arc<dyn Fn(&ProviderSessionId) -> Option<TurnId> + Send + Sync>;

#[derive(Clone)]
pub(crate) struct AcpHostToolProxy {
    inner: Arc<AcpHostToolProxyInner>,
}

struct AcpHostToolProxyInner {
    endpoint: SocketAddr,
    executable: PathBuf,
    sessions: Arc<StdMutex<HashMap<String, Option<ProviderSessionId>>>>,
    shutdown: watch::Sender<bool>,
}

impl Drop for AcpHostToolProxyInner {
    fn drop(&mut self) {
        self.sessions
            .lock()
            .expect("ACP host-tool capabilities poisoned")
            .clear();
        let _ = self.shutdown.send(true);
    }
}

impl std::fmt::Debug for AcpHostToolProxy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AcpHostToolProxy")
            .field("endpoint", &self.inner.endpoint)
            .field("executable", &self.inner.executable)
            .field("capabilities", &"<redacted>")
            .finish()
    }
}

impl AcpHostToolProxy {
    pub(crate) fn bind(
        configuration: HostToolConfiguration,
        resolve_turn: TurnResolver,
    ) -> DriverResult<Self> {
        if configuration.specs.is_empty() {
            return Err(DriverError::Protocol(
                "Inline host tool catalog cannot be empty".to_string(),
            ));
        }
        let executable = std::env::current_exe().map_err(|error| {
            DriverError::Unavailable(format!("Inline MCP executable is unavailable: {error}"))
        })?;
        if !executable.is_absolute() {
            return Err(DriverError::Protocol(
                "Inline MCP executable path is not absolute".to_string(),
            ));
        }
        let runtime = tokio::runtime::Handle::try_current().map_err(|_| {
            DriverError::Unavailable("Inline MCP proxy requires an async runtime".to_string())
        })?;
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|error| {
            DriverError::Unavailable(format!("Inline MCP proxy could not bind: {error}"))
        })?;
        listener.set_nonblocking(true).map_err(|error| {
            DriverError::Unavailable(format!("Inline MCP proxy could not start: {error}"))
        })?;
        let endpoint = listener.local_addr().map_err(|error| {
            DriverError::Unavailable(format!("Inline MCP proxy address is unavailable: {error}"))
        })?;
        if !endpoint.ip().is_loopback() {
            return Err(DriverError::Protocol(
                "Inline MCP proxy did not bind to loopback".to_string(),
            ));
        }
        let listener = TcpListener::from_std(listener).map_err(|error| {
            DriverError::Unavailable(format!("Inline MCP proxy could not start: {error}"))
        })?;
        let sessions = Arc::new(StdMutex::new(HashMap::new()));
        let state = ProxyState {
            configuration,
            sessions: Arc::clone(&sessions),
            resolve_turn,
        };
        let (shutdown, shutdown_rx) = watch::channel(false);
        runtime.spawn(run_proxy_listener(listener, state, shutdown_rx));
        Ok(Self {
            inner: Arc::new(AcpHostToolProxyInner {
                endpoint,
                executable,
                sessions,
                shutdown,
            }),
        })
    }

    pub(crate) fn session_server(&self) -> DriverResult<(acp::McpServer, String)> {
        let capability = random_capability();
        {
            let mut sessions = self
                .inner
                .sessions
                .lock()
                .expect("ACP host-tool capabilities poisoned");
            if sessions.len() >= MAX_SESSION_CAPABILITIES {
                return Err(DriverError::Rejected(
                    "too many active ACP Inline tool sessions".to_string(),
                ));
            }
            sessions.insert(capability.clone(), None);
        }
        let server = acp::McpServerStdio::new(MCP_SERVER_NAME, self.inner.executable.clone())
            .args(vec!["bridge".to_string(), "inline-tools-mcp".to_string()])
            .env(vec![
                acp::EnvVariable::new(ENDPOINT_ENV, self.inner.endpoint.port().to_string()),
                acp::EnvVariable::new(CAPABILITY_ENV, capability.clone()),
            ]);
        Ok((acp::McpServer::Stdio(server), capability))
    }

    pub(crate) fn bind_session(&self, capability: &str, session_id: ProviderSessionId) {
        let mut sessions = self
            .inner
            .sessions
            .lock()
            .expect("ACP host-tool capabilities poisoned");
        sessions.retain(|token, existing| {
            token == capability || existing.as_ref() != Some(&session_id)
        });
        if let Some(entry) = sessions.get_mut(capability) {
            *entry = Some(session_id);
        }
    }

    pub(crate) fn revoke(&self, capability: &str) {
        self.inner
            .sessions
            .lock()
            .expect("ACP host-tool capabilities poisoned")
            .remove(capability);
    }
}

fn random_capability() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

#[derive(Clone)]
struct ProxyState {
    configuration: HostToolConfiguration,
    sessions: Arc<StdMutex<HashMap<String, Option<ProviderSessionId>>>>,
    resolve_turn: TurnResolver,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProxyRequest {
    version: u32,
    capability: String,
    #[serde(flatten)]
    action: ProxyAction,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum ProxyAction {
    List,
    Call {
        call_id: String,
        tool_name: String,
        arguments: Value,
    },
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProxyResponse {
    version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    specs: Option<Vec<HostToolSpec>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<HostToolResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl ProxyResponse {
    fn specs(specs: Vec<HostToolSpec>) -> Self {
        Self {
            version: PROXY_VERSION,
            specs: Some(specs),
            result: None,
            error: None,
        }
    }

    fn result(result: HostToolResult) -> Self {
        Self {
            version: PROXY_VERSION,
            specs: None,
            result: Some(result),
            error: None,
        }
    }

    fn error(message: impl Into<String>) -> Self {
        Self {
            version: PROXY_VERSION,
            specs: None,
            result: None,
            error: Some(message.into()),
        }
    }
}

async fn run_proxy_listener(
    listener: TcpListener,
    state: ProxyState,
    mut shutdown: watch::Receiver<bool>,
) {
    let permits = Arc::new(Semaphore::new(MAX_CONCURRENT_PROXY_CALLS));
    loop {
        tokio::select! {
            biased;
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            accepted = listener.accept() => {
                let Ok((stream, peer)) = accepted else { break };
                if !peer.ip().is_loopback() {
                    continue;
                }
                let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
                    continue;
                };
                let state = state.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let _ = handle_proxy_connection(stream, state).await;
                });
            }
        }
    }
}

async fn handle_proxy_connection(mut stream: TcpStream, state: ProxyState) -> io::Result<()> {
    let request = tokio::time::timeout(PROXY_IO_TIMEOUT, async {
        let mut bytes = Vec::new();
        (&mut stream)
            .take((MAX_PROXY_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .await?;
        if bytes.len() > MAX_PROXY_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Inline MCP proxy request is too large",
            ));
        }
        serde_json::from_slice::<ProxyRequest>(&bytes)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid proxy request"))
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "proxy request timed out"))??;
    let response = handle_proxy_request(request, &state).await;
    let bytes = serde_json::to_vec(&response)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid proxy response"))?;
    tokio::time::timeout(PROXY_IO_TIMEOUT, async {
        stream.write_all(&bytes).await?;
        stream.shutdown().await
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "proxy response timed out"))?
}

async fn handle_proxy_request(request: ProxyRequest, state: &ProxyState) -> ProxyResponse {
    if request.version != PROXY_VERSION
        || request.capability.len() != 64
        || !request
            .capability
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        return ProxyResponse::error("Inline MCP capability is invalid.");
    }
    let session_id = state
        .sessions
        .lock()
        .expect("ACP host-tool capabilities poisoned")
        .get(&request.capability)
        .cloned();
    let Some(session_id) = session_id else {
        return ProxyResponse::error("Inline MCP capability is unavailable.");
    };
    match request.action {
        ProxyAction::List => ProxyResponse::specs(state.configuration.specs.clone()),
        ProxyAction::Call {
            call_id,
            tool_name,
            arguments,
        } => {
            let Some(session_id) = session_id else {
                return ProxyResponse::result(HostToolResult::failure(
                    "Inline tools are not ready for this provider session.",
                ));
            };
            if call_id.is_empty()
                || call_id.len() > MAX_CALL_ID_BYTES
                || call_id.chars().any(char::is_control)
                || !state
                    .configuration
                    .specs
                    .iter()
                    .any(|spec| spec.name == tool_name)
                || !arguments.is_object()
                || serde_json::to_vec(&arguments)
                    .map_or(true, |value| value.len() > MAX_TOOL_ARGUMENT_BYTES)
            {
                return ProxyResponse::result(HostToolResult::failure(
                    "Inline tool call is invalid.",
                ));
            }
            let Some(turn_id) = (state.resolve_turn)(&session_id) else {
                return ProxyResponse::result(HostToolResult::failure(
                    "Inline tools are only available during an active turn.",
                ));
            };
            let result = tokio::time::timeout(
                HOST_TOOL_TIMEOUT,
                state.configuration.handler.call(HostToolCall {
                    call_id,
                    session_id,
                    turn_id,
                    tool_name,
                    arguments,
                }),
            )
            .await;
            match result {
                Ok(mut result) => {
                    result.content = result.content.chars().take(MAX_TOOL_RESULT_CHARS).collect();
                    ProxyResponse::result(result)
                }
                Err(_) => {
                    ProxyResponse::result(HostToolResult::failure("Inline tool call timed out."))
                }
            }
        }
    }
}

/// Runs the hidden stdio MCP child used by stable ACP agents.
///
/// Endpoint data is accepted only through the two explicit environment values
/// placed on the ACP session's MCP declaration. Errors never include either
/// value, and stdout is reserved for MCP JSON-RPC frames.
pub async fn run_inline_tools_mcp() -> Result<(), Box<dyn std::error::Error>> {
    let port = std::env::var(ENDPOINT_ENV)
        .map_err(|_| io::Error::new(io::ErrorKind::PermissionDenied, "missing MCP endpoint"))?
        .parse::<u16>()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid MCP endpoint"))?;
    if port == 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid MCP endpoint").into());
    }
    let capability = std::env::var(CAPABILITY_ENV)
        .map_err(|_| io::Error::new(io::ErrorKind::PermissionDenied, "missing MCP capability"))?;
    if capability.len() != 64 || !capability.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(
            io::Error::new(io::ErrorKind::PermissionDenied, "invalid MCP capability").into(),
        );
    }
    run_mcp_stdio(SocketAddr::from((Ipv4Addr::LOCALHOST, port)), capability).await
}

async fn run_mcp_stdio(
    endpoint: SocketAddr,
    capability: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let stdin = tokio::io::stdin();
    let mut lines = BufReader::new(stdin).lines();
    let mut stdout = tokio::io::stdout();
    let mut initialized = false;
    while let Some(line) = lines.next_line().await? {
        if line.len() > MAX_MCP_MESSAGE_BYTES {
            return Err(
                io::Error::new(io::ErrorKind::InvalidData, "MCP frame is too large").into(),
            );
        }
        let message = match serde_json::from_str::<Value>(&line) {
            Ok(Value::Object(message)) => Value::Object(message),
            _ => {
                let response = json_rpc_error(Value::Null, -32700, "Parse error");
                write_mcp_response(&mut stdout, &response).await?;
                continue;
            }
        };
        if let Some(response) =
            handle_mcp_message(message, endpoint, &capability, &mut initialized).await
        {
            write_mcp_response(&mut stdout, &response).await?;
        }
    }
    Ok(())
}

async fn write_mcp_response(stdout: &mut tokio::io::Stdout, response: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(response)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid MCP response"))?;
    bytes.push(b'\n');
    stdout.write_all(&bytes).await?;
    stdout.flush().await
}

async fn handle_mcp_message(
    message: Value,
    endpoint: SocketAddr,
    capability: &str,
    initialized: &mut bool,
) -> Option<Value> {
    let id = message.get("id").cloned();
    if message.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return id.map(|id| json_rpc_error(id, -32600, "Invalid Request"));
    }
    let Some(method) = message.get("method").and_then(Value::as_str) else {
        return id.map(|id| json_rpc_error(id, -32600, "Invalid Request"));
    };
    if id.is_none() {
        if method == "notifications/initialized" {
            *initialized = true;
        }
        return None;
    }
    let id = id.unwrap_or(Value::Null);
    match method {
        "initialize" => {
            let requested = message
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .filter(|value| SUPPORTED_MCP_PROTOCOL_VERSIONS.contains(value))
                .unwrap_or(CURRENT_MCP_PROTOCOL_VERSION);
            Some(json_rpc_result(
                id,
                json!({
                    "protocolVersion": requested,
                    "capabilities": { "tools": { "listChanged": false } },
                    "serverInfo": {
                        "name": "inline-agent-tools",
                        "version": env!("CARGO_PKG_VERSION")
                    },
                    "instructions": "Use these tools for the current authorized Inline conversation."
                }),
            ))
        }
        "ping" => Some(json_rpc_result(id, json!({}))),
        "tools/list" if *initialized => {
            let request = ProxyRequest {
                version: PROXY_VERSION,
                capability: capability.to_string(),
                action: ProxyAction::List,
            };
            match call_proxy(endpoint, &request).await {
                Ok(response) => match response.specs {
                    Some(specs) => Some(json_rpc_result(
                        id,
                        json!({
                            "tools": specs.into_iter().map(mcp_tool).collect::<Vec<_>>()
                        }),
                    )),
                    None => Some(json_rpc_error(
                        id,
                        -32000,
                        response
                            .error
                            .as_deref()
                            .unwrap_or("Inline tools are unavailable"),
                    )),
                },
                Err(_) => Some(json_rpc_error(id, -32000, "Inline tools are unavailable")),
            }
        }
        "tools/call" if *initialized => {
            let Some(tool_name) = message.pointer("/params/name").and_then(Value::as_str) else {
                return Some(json_rpc_error(id, -32602, "Invalid tool call"));
            };
            let arguments = message
                .pointer("/params/arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let call_id = match serde_json::to_string(&id) {
                Ok(value) if value.len() <= MAX_CALL_ID_BYTES.saturating_sub(4) => {
                    format!("mcp:{value}")
                }
                _ => return Some(json_rpc_error(id, -32602, "Invalid tool call")),
            };
            let request = ProxyRequest {
                version: PROXY_VERSION,
                capability: capability.to_string(),
                action: ProxyAction::Call {
                    call_id,
                    tool_name: tool_name.to_string(),
                    arguments,
                },
            };
            match call_proxy(endpoint, &request).await {
                Ok(response) => match response.result {
                    Some(result) => Some(json_rpc_result(
                        id,
                        json!({
                            "content": [{ "type": "text", "text": result.content }],
                            "isError": !result.success
                        }),
                    )),
                    None => Some(json_rpc_result(
                        id,
                        json!({
                            "content": [{
                                "type": "text",
                                "text": response.error.unwrap_or_else(|| "Inline tool failed.".to_string())
                            }],
                            "isError": true
                        }),
                    )),
                },
                Err(_) => Some(json_rpc_result(
                    id,
                    json!({
                        "content": [{ "type": "text", "text": "Inline tool is unavailable." }],
                        "isError": true
                    }),
                )),
            }
        }
        "tools/list" | "tools/call" => {
            Some(json_rpc_error(id, -32002, "MCP server is not initialized"))
        }
        _ => Some(json_rpc_error(id, -32601, "Method not found")),
    }
}

fn mcp_tool(spec: HostToolSpec) -> Value {
    json!({
        "name": spec.name,
        "description": spec.description,
        "inputSchema": spec.input_schema,
        "annotations": { "readOnlyHint": spec.read_only }
    })
}

async fn call_proxy(endpoint: SocketAddr, request: &ProxyRequest) -> io::Result<ProxyResponse> {
    let bytes = serde_json::to_vec(request)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid proxy request"))?;
    if bytes.len() > MAX_PROXY_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "proxy request is too large",
        ));
    }
    tokio::time::timeout(PROXY_IO_TIMEOUT, async {
        let mut stream = TcpStream::connect(endpoint).await?;
        if !stream.peer_addr()?.ip().is_loopback() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "proxy endpoint is not loopback",
            ));
        }
        stream.write_all(&bytes).await?;
        stream.shutdown().await?;
        let mut response = Vec::new();
        (&mut stream)
            .take((MAX_PROXY_BYTES + 1) as u64)
            .read_to_end(&mut response)
            .await?;
        if response.len() > MAX_PROXY_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "proxy response is too large",
            ));
        }
        let response: ProxyResponse = serde_json::from_slice(&response)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid proxy response"))?;
        if response.version != PROXY_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported proxy response",
            ));
        }
        Ok(response)
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "proxy call timed out"))?
}

fn json_rpc_result(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn json_rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::{HostToolFuture, HostToolHandler};

    #[derive(Debug)]
    struct EchoHandler;

    impl HostToolHandler for EchoHandler {
        fn call<'a>(&'a self, call: HostToolCall) -> HostToolFuture<'a> {
            Box::pin(async move {
                HostToolResult::success(format!(
                    "{}:{}:{}",
                    call.session_id.as_str(),
                    call.turn_id.as_str(),
                    call.tool_name
                ))
            })
        }
    }

    fn configuration() -> HostToolConfiguration {
        HostToolConfiguration {
            specs: vec![HostToolSpec {
                name: "get_current_context".to_string(),
                description: "Get context.".to_string(),
                input_schema: json!({ "type": "object", "additionalProperties": false }),
                read_only: true,
            }],
            handler: Arc::new(EchoHandler),
        }
    }

    #[tokio::test]
    async fn session_capability_maps_mcp_call_to_provider_session_and_turn() {
        let session_id = ProviderSessionId::new("session-1").expect("session");
        let turn_id = TurnId::new("turn-1").expect("turn");
        let expected_session = session_id.clone();
        let expected_turn = turn_id.clone();
        let proxy = AcpHostToolProxy::bind(
            configuration(),
            Arc::new(move |session| (session == &expected_session).then(|| expected_turn.clone())),
        )
        .expect("bind proxy");
        let (server, capability) = proxy.session_server().expect("session server");
        let acp::McpServer::Stdio(server) = server else {
            panic!("expected stdio MCP server")
        };
        assert_eq!(server.name, MCP_SERVER_NAME);
        assert!(server.command.is_absolute());
        assert_eq!(server.args, ["bridge", "inline-tools-mcp"]);
        assert!(server.env.iter().any(|value| value.name == ENDPOINT_ENV));
        assert!(
            server
                .env
                .iter()
                .any(|value| value.name == CAPABILITY_ENV && value.value == capability)
        );

        proxy.bind_session(&capability, session_id);
        let response = call_proxy(
            proxy.inner.endpoint,
            &ProxyRequest {
                version: PROXY_VERSION,
                capability,
                action: ProxyAction::Call {
                    call_id: "call-1".to_string(),
                    tool_name: "get_current_context".to_string(),
                    arguments: json!({}),
                },
            },
        )
        .await
        .expect("proxy call");
        let result = response.result.expect("tool result");
        assert!(result.success);
        assert_eq!(result.content, "session-1:turn-1:get_current_context");
    }

    #[tokio::test]
    async fn mcp_surface_requires_initialization_and_preserves_tool_annotations() {
        let proxy =
            AcpHostToolProxy::bind(configuration(), Arc::new(|_| None)).expect("bind proxy");
        let (_, capability) = proxy.session_server().expect("session server");
        let mut initialized = false;
        let before = handle_mcp_message(
            json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }),
            proxy.inner.endpoint,
            &capability,
            &mut initialized,
        )
        .await
        .expect("response");
        assert_eq!(before["error"]["code"], -32002);

        let initialize = handle_mcp_message(
            json!({
                "jsonrpc": "2.0",
                "id": 2,
                "method": "initialize",
                "params": { "protocolVersion": "2025-03-26" }
            }),
            proxy.inner.endpoint,
            &capability,
            &mut initialized,
        )
        .await
        .expect("initialize response");
        assert_eq!(initialize["result"]["protocolVersion"], "2025-03-26");
        assert!(!initialized);
        assert!(
            handle_mcp_message(
                json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }),
                proxy.inner.endpoint,
                &capability,
                &mut initialized,
            )
            .await
            .is_none()
        );
        assert!(initialized);

        let listed = handle_mcp_message(
            json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/list" }),
            proxy.inner.endpoint,
            &capability,
            &mut initialized,
        )
        .await
        .expect("list response");
        assert_eq!(listed["result"]["tools"][0]["name"], "get_current_context");
        assert_eq!(
            listed["result"]["tools"][0]["annotations"]["readOnlyHint"],
            true
        );
    }

    #[tokio::test]
    async fn mcp_surface_rejects_invalid_json_rpc_and_negotiates_a_supported_version() {
        let proxy =
            AcpHostToolProxy::bind(configuration(), Arc::new(|_| None)).expect("bind proxy");
        let (_, capability) = proxy.session_server().expect("session server");
        let mut initialized = false;

        let invalid = handle_mcp_message(
            json!({ "jsonrpc": "1.0", "id": 1, "method": "ping" }),
            proxy.inner.endpoint,
            &capability,
            &mut initialized,
        )
        .await
        .expect("invalid request response");
        assert_eq!(invalid["error"]["code"], -32600);

        let initialize = handle_mcp_message(
            json!({
                "jsonrpc": "2.0",
                "id": 2,
                "method": "initialize",
                "params": { "protocolVersion": "2099-01-01" }
            }),
            proxy.inner.endpoint,
            &capability,
            &mut initialized,
        )
        .await
        .expect("initialize response");
        assert_eq!(
            initialize["result"]["protocolVersion"],
            CURRENT_MCP_PROTOCOL_VERSION
        );
    }

    #[tokio::test]
    async fn tool_call_fails_closed_without_bound_session_or_active_turn() {
        let proxy =
            AcpHostToolProxy::bind(configuration(), Arc::new(|_| None)).expect("bind proxy");
        let (_, capability) = proxy.session_server().expect("session server");
        let pending = handle_proxy_request(
            ProxyRequest {
                version: PROXY_VERSION,
                capability: capability.clone(),
                action: ProxyAction::Call {
                    call_id: "call-1".to_string(),
                    tool_name: "get_current_context".to_string(),
                    arguments: json!({}),
                },
            },
            &ProxyState {
                configuration: configuration(),
                sessions: Arc::clone(&proxy.inner.sessions),
                resolve_turn: Arc::new(|_| None),
            },
        )
        .await;
        assert!(
            pending
                .result
                .expect("pending result")
                .content
                .contains("not ready")
        );

        proxy.bind_session(
            &capability,
            ProviderSessionId::new("session-1").expect("session"),
        );
        let idle = call_proxy(
            proxy.inner.endpoint,
            &ProxyRequest {
                version: PROXY_VERSION,
                capability,
                action: ProxyAction::Call {
                    call_id: "call-2".to_string(),
                    tool_name: "get_current_context".to_string(),
                    arguments: json!({}),
                },
            },
        )
        .await
        .expect("idle result")
        .result
        .expect("tool result");
        assert!(!idle.success);
        assert!(idle.content.contains("active turn"));
    }
}

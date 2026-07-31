use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use thiserror::Error;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::time::timeout;

const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
// A supported 20 MiB native image becomes about 27 MiB as a base64 data URL,
// and Codex may include that input in a thread/resume response. Keep the peer
// bounded while making its frame contract internally consistent with the
// driver's image limit.
const MAX_INCOMING_FRAME_BYTES: usize = 32 * 1024 * 1024;

pub type PeerResult<T> = Result<T, PeerError>;

#[derive(Clone, Debug, PartialEq)]
pub enum IncomingMessage {
    Notification {
        method: String,
        params: Value,
    },
    ServerRequest {
        id: Value,
        method: String,
        params: Value,
    },
}

#[derive(Debug, Error)]
pub enum PeerError {
    #[error("Codex app-server I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Codex app-server sent malformed JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Codex app-server peer closed")]
    Closed,
    #[error("Codex app-server rejected the request: {0}")]
    Remote(RemoteError),
    #[error("Codex app-server sent an invalid message: {0}")]
    InvalidMessage(String),
    #[error("Codex app-server incoming stream was already claimed")]
    IncomingAlreadyClaimed,
    #[error("Codex app-server request timed out: {0}")]
    Timeout(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteError {
    pub code: Option<i64>,
    pub message: String,
}

impl std::fmt::Display for RemoteError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.code {
            Some(code) => write!(formatter, "{} ({code})", self.message),
            None => formatter.write_str(&self.message),
        }
    }
}

type Pending = Arc<StdMutex<HashMap<u64, oneshot::Sender<PeerResult<Value>>>>>;

pub struct CodexPeer<W> {
    writer: Arc<Mutex<W>>,
    pending: Pending,
    next_request_id: Arc<AtomicU64>,
    incoming_rx: Arc<StdMutex<Option<mpsc::Receiver<IncomingMessage>>>>,
}

impl<W> Clone for CodexPeer<W> {
    fn clone(&self) -> Self {
        Self {
            writer: self.writer.clone(),
            pending: self.pending.clone(),
            next_request_id: self.next_request_id.clone(),
            incoming_rx: self.incoming_rx.clone(),
        }
    }
}

impl<W> std::fmt::Debug for CodexPeer<W> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodexPeer")
            .field("writer", &"<async writer>")
            .field(
                "pending_requests",
                &self.pending.lock().map(|map| map.len()).ok(),
            )
            .finish()
    }
}

impl<W> CodexPeer<W>
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    pub fn new<R>(reader: R, writer: W, incoming_capacity: usize) -> Self
    where
        R: AsyncRead + Unpin + Send + 'static,
    {
        let pending = Arc::new(StdMutex::new(HashMap::new()));
        let (incoming_tx, incoming_rx) = mpsc::channel(incoming_capacity.max(1));
        tokio::spawn(read_loop(reader, pending.clone(), incoming_tx));
        Self {
            writer: Arc::new(Mutex::new(writer)),
            pending,
            next_request_id: Arc::new(AtomicU64::new(1)),
            incoming_rx: Arc::new(StdMutex::new(Some(incoming_rx))),
        }
    }

    pub fn take_incoming(&self) -> PeerResult<mpsc::Receiver<IncomingMessage>> {
        self.incoming_rx
            .lock()
            .expect("Codex incoming receiver poisoned")
            .take()
            .ok_or(PeerError::IncomingAlreadyClaimed)
    }

    pub async fn request(&self, method: &str, params: Value) -> PeerResult<Value> {
        self.request_with_timeout(method, params, DEFAULT_REQUEST_TIMEOUT)
            .await
    }

    pub async fn request_with_timeout(
        &self,
        method: &str,
        params: Value,
        request_timeout: Duration,
    ) -> PeerResult<Value> {
        let id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let started_at = Instant::now();
        log::trace!(
            target: "inline_agent_driver_codex::rpc",
            "phase=request_started method={:?} rpc_id={id}",
            trace_protocol_method(method)
        );
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .expect("Codex pending map poisoned")
            .insert(id, tx);
        let exchange = async {
            self.write_message(&json!({ "method": method, "id": id, "params": params }))
                .await?;
            rx.await.map_err(|_| PeerError::Closed)?
        };
        match timeout(request_timeout, exchange).await {
            Ok(result) => {
                log::trace!(
                    target: "inline_agent_driver_codex::rpc",
                    "phase=request_finished method={:?} rpc_id={id} outcome={} elapsed_ms={}",
                    trace_protocol_method(method),
                    result.as_ref().map_or_else(peer_error_kind, |_| "ok"),
                    started_at.elapsed().as_millis()
                );
                if result.is_err() {
                    self.pending
                        .lock()
                        .expect("Codex pending map poisoned")
                        .remove(&id);
                }
                result
            }
            Err(_) => {
                log::warn!(
                    target: "inline_agent_driver_codex::rpc",
                    "phase=request_finished method={:?} rpc_id={id} outcome=timeout elapsed_ms={}",
                    trace_protocol_method(method),
                    started_at.elapsed().as_millis()
                );
                self.pending
                    .lock()
                    .expect("Codex pending map poisoned")
                    .remove(&id);
                Err(PeerError::Timeout(method.to_string()))
            }
        }
    }

    pub async fn notify(&self, method: &str, params: Value) -> PeerResult<()> {
        self.write_message(&json!({ "method": method, "params": params }))
            .await
    }

    pub async fn respond(&self, id: Value, result: Value) -> PeerResult<()> {
        self.write_message(&json!({ "id": id, "result": result }))
            .await
    }

    pub async fn respond_error(&self, id: Value, code: i64, message: &str) -> PeerResult<()> {
        self.write_message(&json!({
            "id": id,
            "error": { "code": code, "message": message }
        }))
        .await
    }

    async fn write_message(&self, message: &Value) -> PeerResult<()> {
        let mut payload = serde_json::to_vec(message)?;
        payload.push(b'\n');
        let mut writer = self.writer.lock().await;
        writer.write_all(&payload).await?;
        writer.flush().await?;
        Ok(())
    }
}

async fn read_loop<R>(reader: R, pending: Pending, incoming_tx: mpsc::Sender<IncomingMessage>)
where
    R: AsyncRead + Unpin + Send + 'static,
{
    let mut reader = BufReader::new(reader);
    loop {
        let frame = match read_bounded_frame(&mut reader).await {
            Ok(Some(frame)) => frame,
            Ok(None) => {
                close_pending(&pending, || PeerError::Closed);
                break;
            }
            Err(error) => {
                let message = error.to_string();
                close_pending(&pending, || {
                    PeerError::InvalidMessage(format!("read failed: {message}"))
                });
                break;
            }
        };
        let value: Value = match serde_json::from_slice(&frame) {
            Ok(value) => value,
            Err(error) => {
                let message = error.to_string();
                close_pending(&pending, || {
                    PeerError::InvalidMessage(format!("malformed JSON: {message}"))
                });
                break;
            }
        };
        if route_response(&pending, &value) {
            continue;
        }
        let Some(method) = value.get("method").and_then(Value::as_str) else {
            close_pending(&pending, || {
                PeerError::InvalidMessage("message has neither response nor method".to_string())
            });
            break;
        };
        let params = value.get("params").cloned().unwrap_or(Value::Null);
        let incoming = match value.get("id") {
            Some(id) => IncomingMessage::ServerRequest {
                id: id.clone(),
                method: method.to_string(),
                params,
            },
            None => IncomingMessage::Notification {
                method: method.to_string(),
                params,
            },
        };
        log::trace!(
            target: "inline_agent_driver_codex::rpc",
            "phase=provider_frame kind={} method={:?}",
            if value.get("id").is_some() {
                "request"
            } else {
                "notification"
            },
            trace_protocol_method(method)
        );
        if let Err(error) = incoming_tx.try_send(incoming) {
            let message = match error {
                mpsc::error::TrySendError::Full(_) => {
                    "incoming notification queue overflowed".to_string()
                }
                mpsc::error::TrySendError::Closed(_) => {
                    "incoming notification consumer closed".to_string()
                }
            };
            close_pending(&pending, || PeerError::InvalidMessage(message.clone()));
            break;
        }
    }
}

fn peer_error_kind(error: &PeerError) -> &'static str {
    match error {
        PeerError::Io(_) => "io_error",
        PeerError::Json(_) => "json_error",
        PeerError::Closed => "closed",
        PeerError::Remote(_) => "remote_error",
        PeerError::InvalidMessage(_) => "invalid_message",
        PeerError::IncomingAlreadyClaimed => "incoming_already_claimed",
        PeerError::Timeout(_) => "timeout",
    }
}

fn trace_protocol_method(method: &str) -> String {
    method
        .chars()
        .take(96)
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '/' | '_' | '-' | '.') {
                character
            } else {
                '?'
            }
        })
        .collect()
}

async fn read_bounded_frame<R>(reader: &mut R) -> std::io::Result<Option<Vec<u8>>>
where
    R: AsyncBufRead + Unpin,
{
    let mut frame = Vec::new();
    loop {
        let buffer = reader.fill_buf().await?;
        if buffer.is_empty() {
            return if frame.is_empty() {
                Ok(None)
            } else {
                Ok(Some(frame))
            };
        }
        let consumed = buffer
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(buffer.len(), |index| index + 1);
        if frame.len().saturating_add(consumed) > MAX_INCOMING_FRAME_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Codex app-server frame exceeded the input limit",
            ));
        }
        frame.extend_from_slice(&buffer[..consumed]);
        reader.consume(consumed);
        if frame.last() == Some(&b'\n') {
            frame.pop();
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            return Ok(Some(frame));
        }
    }
}

fn route_response(pending: &Pending, value: &Value) -> bool {
    let Some(id) = value.get("id").and_then(Value::as_u64) else {
        return false;
    };
    if value.get("method").is_some() {
        return false;
    }
    let Some(tx) = pending
        .lock()
        .expect("Codex pending map poisoned")
        .remove(&id)
    else {
        return true;
    };
    let response = if let Some(result) = value.get("result") {
        Ok(result.clone())
    } else if let Some(error) = value.get("error") {
        Err(PeerError::Remote(remote_error(error)))
    } else {
        Err(PeerError::InvalidMessage(format!(
            "response {id} has neither result nor error"
        )))
    };
    let _ = tx.send(response);
    true
}

fn remote_error(error: &Value) -> RemoteError {
    let code = error.get("code").and_then(Value::as_i64);
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown error")
        .to_string();
    RemoteError { code, message }
}

fn close_pending(make_error_map: &Pending, make_error: impl Fn() -> PeerError) {
    let pending = std::mem::take(&mut *make_error_map.lock().expect("Codex pending map poisoned"));
    for (_, tx) in pending {
        let _ = tx.send(Err(make_error()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_method_is_bounded_and_cannot_inject_log_fields() {
        let method = format!(
            "turn/completed\nsecret=must-not-be-a-field{}",
            "x".repeat(200)
        );
        let safe = trace_protocol_method(&method);
        assert!(safe.len() <= 96);
        assert!(!safe.contains('\n'));
        assert!(!safe.contains('='));
        assert!(safe.starts_with("turn/completed?secret?"));
    }

    #[tokio::test]
    async fn correlates_response_and_routes_notifications() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 8);
        let mut incoming = peer.take_incoming().expect("incoming stream");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let request: Value = serde_json::from_str(
                &lines
                    .next_line()
                    .await
                    .expect("read request")
                    .expect("request line"),
            )
            .expect("request json");
            assert_eq!(request["method"], "initialize");
            writer
                .write_all(b"{\"id\":1,\"result\":{\"userAgent\":\"codex\"}}\n")
                .await
                .expect("write response");
            writer
                .write_all(
                    b"{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"t1\"}}}\n",
                )
                .await
                .expect("write notification");
        });
        let response = peer
            .request("initialize", json!({}))
            .await
            .expect("initialize response");
        assert_eq!(response["userAgent"], "codex");
        assert!(matches!(
            incoming.recv().await,
            Some(IncomingMessage::Notification { method, .. }) if method == "thread/started"
        ));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn routes_server_request_without_waiting_for_answer() {
        let (client, mut server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 8);
        let mut incoming = peer.take_incoming().expect("incoming stream");
        server
            .write_all(b"{\"method\":\"item/commandExecution/requestApproval\",\"id\":\"approval-1\",\"params\":{\"turnId\":\"turn-1\"}}\n")
            .await
            .expect("write request");
        assert!(matches!(
            incoming.recv().await,
            Some(IncomingMessage::ServerRequest { id, method, .. })
                if id == "approval-1" && method == "item/commandExecution/requestApproval"
        ));
    }

    #[tokio::test]
    async fn frames_fragmented_and_coalesced_json_lines() {
        let (client, mut server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 8);
        let mut incoming = peer.take_incoming().expect("incoming stream");

        server
            .write_all(b"{\"method\":\"first\",\"params\":{")
            .await
            .expect("first fragment");
        tokio::task::yield_now().await;
        server
            .write_all(b"\"value\":1}}\n{\"method\":\"second\",\"params\":{\"value\":2}}\n")
            .await
            .expect("remaining and coalesced frames");

        assert!(matches!(
            incoming.recv().await,
            Some(IncomingMessage::Notification { method, params })
                if method == "first" && params["value"] == 1
        ));
        assert!(matches!(
            incoming.recv().await,
            Some(IncomingMessage::Notification { method, params })
                if method == "second" && params["value"] == 2
        ));
    }

    #[tokio::test]
    async fn rejects_an_oversized_incoming_frame_before_json_parsing() {
        let mut bytes = vec![b'x'; MAX_INCOMING_FRAME_BYTES + 1];
        bytes.push(b'\n');
        let mut reader = BufReader::new(bytes.as_slice());

        let error = read_bounded_frame(&mut reader)
            .await
            .expect_err("oversized frame must fail closed");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn malformed_frame_fails_an_outstanding_request() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("request read");
            writer
                .write_all(b"not-json\n")
                .await
                .expect("malformed response");
        });
        assert!(matches!(
            peer.request("initialize", json!({})).await,
            Err(PeerError::InvalidMessage(message)) if message.contains("malformed JSON")
        ));
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn request_timeout_removes_the_pending_waiter() {
        let (client, mut server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let request =
            peer.request_with_timeout("thread/start", json!({}), Duration::from_millis(10));
        let mut line = String::new();
        let read = tokio::io::AsyncReadExt::read_to_string(&mut server, &mut line);
        tokio::pin!(read);
        tokio::pin!(request);
        tokio::select! {
            result = &mut request => assert!(matches!(result, Err(PeerError::Timeout(method)) if method == "thread/start")),
            _ = &mut read => panic!("server unexpectedly closed before timeout"),
        }
        assert!(peer.pending.lock().expect("pending map").is_empty());
    }

    #[tokio::test]
    async fn request_timeout_includes_a_stalled_write() {
        let (client, _server) = tokio::io::duplex(1);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);

        let result = peer
            .request_with_timeout(
                "turn/interrupt",
                json!({ "payload": "large-enough-to-fill-the-pipe" }),
                Duration::from_millis(10),
            )
            .await;

        assert!(matches!(
            result,
            Err(PeerError::Timeout(method)) if method == "turn/interrupt"
        ));
        assert!(peer.pending.lock().expect("pending map").is_empty());
    }

    #[tokio::test]
    async fn response_routing_is_not_blocked_by_a_bounded_notification_burst() {
        let (client, server) = tokio::io::duplex(64 * 1024);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 128);
        let _incoming = peer.take_incoming().expect("incoming stream");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("request read");
            for index in 0..100 {
                writer
                    .write_all(
                        format!("{{\"method\":\"noise\",\"params\":{{\"index\":{index}}}}}\n")
                            .as_bytes(),
                    )
                    .await
                    .expect("noise notification");
            }
            writer
                .write_all(b"{\"id\":1,\"result\":{\"ok\":true}}\n")
                .await
                .expect("response");
        });
        let response = peer
            .request("test", json!({}))
            .await
            .expect("response after notification burst");
        assert_eq!(response["ok"], true);
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn incoming_overflow_fails_an_outstanding_request_instead_of_growing_unbounded() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let _incoming = peer.take_incoming().expect("incoming stream");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("request read");
            writer
                .write_all(b"{\"method\":\"noise\",\"params\":{}}\n")
                .await
                .expect("first notification");
            writer
                .write_all(b"{\"method\":\"noise\",\"params\":{}}\n")
                .await
                .expect("overflow notification");
        });
        assert!(matches!(
            peer.request("test", json!({})).await,
            Err(PeerError::InvalidMessage(message)) if message.contains("queue overflowed")
        ));
        server_task.await.expect("server task");
    }
}

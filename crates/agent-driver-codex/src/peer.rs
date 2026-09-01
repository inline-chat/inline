use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use thiserror::Error;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::timeout;

const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
const DEFAULT_WRITE_TIMEOUT: Duration = Duration::from_secs(30);
// A supported 20 MiB native image becomes about 27 MiB as a base64 data URL,
// and Codex may include that input in a thread/resume response. Keep the peer
// bounded while making its frame contract internally consistent with the
// driver's image limit.
const MAX_INCOMING_FRAME_BYTES: usize = 32 * 1024 * 1024;

pub type PeerResult<T> = Result<T, PeerError>;

#[derive(Clone, Debug, PartialEq)]
pub enum IncomingMessage {
    Notification {
        wire_sequence: u64,
        method: String,
        params: Value,
    },
    ServerRequest {
        wire_sequence: u64,
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

#[derive(Debug)]
struct SequencedResponse {
    value: Value,
    wire_sequence: u64,
}

type Pending = Arc<StdMutex<HashMap<u64, oneshot::Sender<PeerResult<SequencedResponse>>>>>;

struct OutgoingFrame {
    payload: Vec<u8>,
    completed: oneshot::Sender<Result<(), String>>,
}

struct PendingRequestGuard {
    pending: Pending,
    closed: Arc<AtomicBool>,
    close_tx: watch::Sender<bool>,
    id: u64,
    close_on_drop: bool,
}

impl PendingRequestGuard {
    fn disarm(&mut self) {
        self.close_on_drop = false;
    }
}

impl Drop for PendingRequestGuard {
    fn drop(&mut self) {
        self.pending
            .lock()
            .expect("Codex pending map poisoned")
            .remove(&self.id);
        if self.close_on_drop {
            close_peer(&self.closed, &self.pending, &self.close_tx, || {
                PeerError::Closed
            });
        }
    }
}

pub struct CodexPeer<W> {
    writer_tx: mpsc::Sender<OutgoingFrame>,
    pending: Pending,
    closed: Arc<AtomicBool>,
    close_tx: watch::Sender<bool>,
    next_request_id: Arc<AtomicU64>,
    incoming_rx: Arc<StdMutex<Option<mpsc::Receiver<IncomingMessage>>>>,
    _writer: std::marker::PhantomData<fn() -> W>,
}

impl<W> Clone for CodexPeer<W> {
    fn clone(&self) -> Self {
        Self {
            writer_tx: self.writer_tx.clone(),
            pending: self.pending.clone(),
            closed: self.closed.clone(),
            close_tx: self.close_tx.clone(),
            next_request_id: self.next_request_id.clone(),
            incoming_rx: self.incoming_rx.clone(),
            _writer: std::marker::PhantomData,
        }
    }
}

impl<W> std::fmt::Debug for CodexPeer<W> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodexPeer")
            .field("writer", &"<framed writer task>")
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
        let closed = Arc::new(AtomicBool::new(false));
        let incoming_capacity = incoming_capacity.max(1);
        let (incoming_tx, incoming_rx) = mpsc::channel(incoming_capacity);
        let (writer_tx, writer_rx) = mpsc::channel(64);
        let (close_tx, close_rx) = watch::channel(false);
        tokio::spawn(read_loop(
            reader,
            pending.clone(),
            closed.clone(),
            close_tx.clone(),
            close_rx.clone(),
            incoming_tx,
            incoming_capacity.min(16).div_ceil(4).max(1),
        ));
        tokio::spawn(write_loop(
            writer,
            writer_rx,
            pending.clone(),
            closed.clone(),
            close_tx.clone(),
            close_rx,
        ));
        Self {
            writer_tx,
            pending,
            closed,
            close_tx,
            next_request_id: Arc::new(AtomicU64::new(1)),
            incoming_rx: Arc::new(StdMutex::new(Some(incoming_rx))),
            _writer: std::marker::PhantomData,
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
        self.request_with_wire_sequence_and_timeout(method, params, request_timeout)
            .await
            .map(|response| response.value)
    }

    pub(crate) async fn request_with_wire_sequence(
        &self,
        method: &str,
        params: Value,
    ) -> PeerResult<(Value, u64)> {
        self.request_with_wire_sequence_and_timeout(method, params, DEFAULT_REQUEST_TIMEOUT)
            .await
            .map(|response| (response.value, response.wire_sequence))
    }

    async fn request_with_wire_sequence_and_timeout(
        &self,
        method: &str,
        params: Value,
        request_timeout: Duration,
    ) -> PeerResult<SequencedResponse> {
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
        // An outer deadline may cancel this future before the peer's own
        // timeout fires. Always remove the waiter when the request future is
        // dropped so a slow catalog/control call cannot leak pending state.
        let mut pending_guard = PendingRequestGuard {
            pending: self.pending.clone(),
            closed: self.closed.clone(),
            close_tx: self.close_tx.clone(),
            id,
            close_on_drop: true,
        };
        let exchange = async {
            self.write_message(&json!({ "method": method, "id": id, "params": params }))
                .await?;
            // Only after the complete frame has been written may a read-only
            // catalog request be abandoned without invalidating an active turn.
            // Partial writes and mutations still fail closed: their outcome is
            // ambiguous. Late catalog replies are ignored by response routing.
            if matches!(
                method,
                "account/read"
                    | "thread/list"
                    | "thread/read"
                    | "thread/turns/list"
                    | "thread/items/list"
                    | "project/list"
                    | "model/list"
                    | "permissionProfile/list"
            ) {
                pending_guard.disarm();
            }
            rx.await.map_err(|_| PeerError::Closed)?
        };
        match timeout(request_timeout, exchange).await {
            Ok(result) => {
                pending_guard.disarm();
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
                if pending_guard.close_on_drop {
                    close_peer(&self.closed, &self.pending, &self.close_tx, || {
                        PeerError::Timeout(method.to_string())
                    });
                }
                pending_guard.disarm();
                log::warn!(
                    target: "inline_agent_driver_codex::rpc",
                    "phase=request_finished method={:?} rpc_id={id} outcome=timeout elapsed_ms={}",
                    trace_protocol_method(method),
                    started_at.elapsed().as_millis()
                );
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
        self.write_message_with_timeout(message, DEFAULT_WRITE_TIMEOUT)
            .await
    }

    async fn write_message_with_timeout(
        &self,
        message: &Value,
        write_timeout: Duration,
    ) -> PeerResult<()> {
        if self.closed.load(Ordering::Acquire) {
            return Err(PeerError::Closed);
        }
        let mut payload = serde_json::to_vec(message)?;
        payload.push(b'\n');
        let (completed, result) = oneshot::channel();
        let exchange = async {
            self.writer_tx
                .send(OutgoingFrame { payload, completed })
                .await
                .map_err(|_| PeerError::Closed)?;
            result
                .await
                .map_err(|_| PeerError::Closed)?
                .map_err(|message| PeerError::Io(std::io::Error::other(message)))
        };
        match timeout(write_timeout, exchange).await {
            Ok(result) => result,
            Err(_) => {
                close_peer(&self.closed, &self.pending, &self.close_tx, || {
                    PeerError::Timeout("write".to_string())
                });
                Err(PeerError::Timeout("write".to_string()))
            }
        }
    }
}

async fn write_loop<W>(
    mut writer: W,
    mut frames: mpsc::Receiver<OutgoingFrame>,
    pending: Pending,
    closed: Arc<AtomicBool>,
    close_tx: watch::Sender<bool>,
    mut close_rx: watch::Receiver<bool>,
) where
    W: AsyncWrite + Unpin + Send + 'static,
{
    loop {
        let frame = tokio::select! {
            _ = close_rx.wait_for(|closed| *closed) => break,
            frame = frames.recv() => {
                let Some(frame) = frame else { break };
                frame
            }
        };
        if closed.load(Ordering::Acquire) {
            let _ = frame.completed.send(Err("peer closed".to_string()));
            while let Ok(frame) = frames.try_recv() {
                let _ = frame.completed.send(Err("peer closed".to_string()));
            }
            return;
        }
        let result = tokio::select! {
            _ = close_rx.wait_for(|closed| *closed) => {
                let _ = frame.completed.send(Err("peer closed".to_string()));
                break;
            }
            result = async {
                writer.write_all(&frame.payload).await?;
                writer.flush().await
            } => result,
        };
        match result {
            Ok(()) => {
                let _ = frame.completed.send(Ok(()));
            }
            Err(error) => {
                let message = error.to_string();
                let _ = frame.completed.send(Err(message.clone()));
                closed.store(true, Ordering::Release);
                let _ = close_tx.send(true);
                close_pending(&pending, || {
                    PeerError::Io(std::io::Error::other(message.clone()))
                });
                while let Ok(frame) = frames.try_recv() {
                    let _ = frame.completed.send(Err(message.clone()));
                }
                return;
            }
        }
    }
    closed.store(true, Ordering::Release);
    let _ = close_tx.send(true);
    close_pending(&pending, || PeerError::Closed);
}

async fn read_loop<R>(
    reader: R,
    pending: Pending,
    closed: Arc<AtomicBool>,
    close_tx: watch::Sender<bool>,
    mut close_rx: watch::Receiver<bool>,
    incoming_tx: mpsc::Sender<IncomingMessage>,
    critical_reserve: usize,
) where
    R: AsyncRead + Unpin + Send + 'static,
{
    let mut reader = BufReader::new(reader);
    let mut wire_sequence = 0u64;
    loop {
        let frame = match tokio::select! {
            _ = close_rx.wait_for(|closed| *closed) => break,
            frame = read_bounded_frame(&mut reader) => frame,
        } {
            Ok(Some(frame)) => frame,
            Ok(None) => {
                close_peer(&closed, &pending, &close_tx, || PeerError::Closed);
                break;
            }
            Err(error) => {
                let message = error.to_string();
                close_peer(&closed, &pending, &close_tx, || {
                    PeerError::InvalidMessage(format!("read failed: {message}"))
                });
                break;
            }
        };
        let value: Value = match serde_json::from_slice(&frame) {
            Ok(value) => value,
            Err(error) => {
                let message = error.to_string();
                close_peer(&closed, &pending, &close_tx, || {
                    PeerError::InvalidMessage(format!("malformed JSON: {message}"))
                });
                break;
            }
        };
        let Some(next_wire_sequence) = wire_sequence.checked_add(1) else {
            close_peer(&closed, &pending, &close_tx, || {
                PeerError::InvalidMessage("provider frame sequence exhausted".to_string())
            });
            break;
        };
        wire_sequence = next_wire_sequence;
        if route_response(&pending, &value, wire_sequence) {
            continue;
        }
        let Some(method) = value.get("method").and_then(Value::as_str) else {
            close_peer(&closed, &pending, &close_tx, || {
                PeerError::InvalidMessage("message has neither response nor method".to_string())
            });
            break;
        };
        let params = value.get("params").cloned().unwrap_or(Value::Null);
        let incoming = match value.get("id") {
            Some(id) => IncomingMessage::ServerRequest {
                wire_sequence,
                id: id.clone(),
                method: method.to_string(),
                params,
            },
            None => IncomingMessage::Notification {
                wire_sequence,
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
        if matches!(
            &incoming,
            IncomingMessage::Notification { method, .. }
                if notification_is_drop_safe(method)
                    && incoming_tx.capacity() <= critical_reserve
        ) {
            log::warn!(
                target: "inline_agent_driver_codex::rpc",
                "phase=provider_frame_dropped kind=ignored_notification reason=critical_capacity_reserved"
            );
            continue;
        }
        if let Err(error) = incoming_tx.try_send(incoming) {
            let message = match error {
                mpsc::error::TrySendError::Full(IncomingMessage::Notification {
                    method, ..
                }) if notification_is_drop_safe(&method) => {
                    log::warn!(
                        target: "inline_agent_driver_codex::rpc",
                        "phase=provider_frame_dropped kind=ignored_notification method={:?} reason=queue_full",
                        trace_protocol_method(&method)
                    );
                    continue;
                }
                mpsc::error::TrySendError::Full(_) => {
                    "incoming notification queue overflowed".to_string()
                }
                mpsc::error::TrySendError::Closed(_) => {
                    "incoming notification consumer closed".to_string()
                }
            };
            close_peer(&closed, &pending, &close_tx, || {
                PeerError::InvalidMessage(message.clone())
            });
            break;
        }
    }
}

fn close_peer(
    closed: &AtomicBool,
    pending: &Pending,
    close_tx: &watch::Sender<bool>,
    make_error: impl Fn() -> PeerError,
) {
    closed.store(true, Ordering::Release);
    let _ = close_tx.send(true);
    close_pending(pending, make_error);
}

fn notification_is_drop_safe(method: &str) -> bool {
    matches!(
        method,
        "account/rateLimits/updated" | "thread/tokenUsage/updated"
    )
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

pub(crate) async fn read_bounded_frame<R>(reader: &mut R) -> std::io::Result<Option<Vec<u8>>>
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

fn route_response(pending: &Pending, value: &Value, wire_sequence: u64) -> bool {
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
        Ok(SequencedResponse {
            value: result.clone(),
            wire_sequence,
        })
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
            Some(IncomingMessage::Notification { method, params, .. })
                if method == "first" && params["value"] == 1
        ));
        assert!(matches!(
            incoming.recv().await,
            Some(IncomingMessage::Notification { method, params, .. })
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
    async fn malformed_input_cancels_a_partial_writer_and_closes_the_stream() {
        let (client, mut server) = tokio::io::duplex(8);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let mut incoming = peer.take_incoming().expect("incoming stream");
        let request_peer = peer.clone();
        let request = tokio::spawn(async move {
            request_peer
                .request_with_timeout(
                    "thread/list",
                    json!({ "payload": "large-enough-to-leave-the-framed-writer-blocked" }),
                    Duration::from_secs(1),
                )
                .await
        });
        let mut first_byte = [0u8; 1];
        tokio::io::AsyncReadExt::read_exact(&mut server, &mut first_byte)
            .await
            .expect("partial request");
        server
            .write_all(b"{not-json}\n")
            .await
            .expect("malformed frame");

        timeout(Duration::from_secs(1), request)
            .await
            .expect("request must be released")
            .expect("request task")
            .expect_err("malformed input must fail the request");
        assert!(peer.closed.load(Ordering::Acquire));
        assert!(matches!(
            timeout(Duration::from_secs(1), incoming.recv()).await,
            Ok(None)
        ));
    }

    #[tokio::test]
    async fn incoming_overflow_cancels_a_partial_writer_and_closes_the_stream() {
        let (client, mut server) = tokio::io::duplex(8);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let mut incoming = peer.take_incoming().expect("incoming stream");
        let request_peer = peer.clone();
        let request = tokio::spawn(async move {
            request_peer
                .request_with_timeout(
                    "thread/list",
                    json!({ "payload": "large-enough-to-leave-the-framed-writer-blocked" }),
                    Duration::from_secs(1),
                )
                .await
        });
        let mut first_byte = [0u8; 1];
        tokio::io::AsyncReadExt::read_exact(&mut server, &mut first_byte)
            .await
            .expect("partial request");
        for turn_id in ["turn-1", "turn-2"] {
            server
                .write_all(
                    format!(
                        "{{\"method\":\"turn/started\",\"params\":{{\"turn\":{{\"id\":\"{turn_id}\"}}}}}}\n"
                    )
                    .as_bytes(),
                )
                .await
                .expect("critical notification");
        }

        timeout(Duration::from_secs(1), request)
            .await
            .expect("request must be released")
            .expect("request task")
            .expect_err("overflow must fail the request");
        assert!(peer.closed.load(Ordering::Acquire));
        assert!(incoming.recv().await.is_some());
        assert!(matches!(
            timeout(Duration::from_secs(1), incoming.recv()).await,
            Ok(None)
        ));
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
        let mut incoming = peer.take_incoming().expect("incoming");

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
        assert!(matches!(
            timeout(Duration::from_secs(1), incoming.recv()).await,
            Ok(None)
        ));
    }

    #[tokio::test]
    async fn stalled_server_response_write_closes_the_peer_at_its_deadline() {
        let (client, _server) = tokio::io::duplex(1);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);

        let result = peer
            .write_message_with_timeout(
                &json!({ "id": "approval", "result": { "payload": "large" } }),
                Duration::from_millis(10),
            )
            .await;

        assert!(matches!(result, Err(PeerError::Timeout(kind)) if kind == "write"));
        assert!(peer.closed.load(Ordering::Acquire));
        assert!(matches!(
            peer.notify("initialized", json!({})).await,
            Err(PeerError::Closed)
        ));
    }

    #[tokio::test]
    async fn timed_out_partial_write_closes_the_peer_before_another_request() {
        let (client, _server) = tokio::io::duplex(8);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);

        assert!(matches!(
            peer.request_with_timeout(
                "thread/list",
                json!({ "payload": "large-enough-to-stall-after-a-partial-write" }),
                Duration::from_millis(10),
            )
            .await,
            Err(PeerError::Timeout(method)) if method == "thread/list"
        ));

        assert!(peer.closed.load(Ordering::Acquire));
        assert!(matches!(
            peer.request_with_timeout("model/list", json!({}), Duration::from_secs(1))
                .await,
            Err(PeerError::Closed)
        ));
    }

    #[tokio::test]
    async fn cancelled_mutation_closes_the_peer_and_removes_the_pending_waiter() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let mut incoming = peer.take_incoming().expect("incoming");
        let request_peer = peer.clone();
        let request =
            tokio::spawn(async move { request_peer.request("thread/start", json!({})).await });
        let (reader, _writer) = tokio::io::split(server);
        let mut lines = BufReader::new(reader).lines();
        assert!(lines.next_line().await.expect("request read").is_some());

        request.abort();
        let _ = request.await;
        assert!(peer.pending.lock().expect("pending map").is_empty());
        assert!(peer.closed.load(Ordering::Acquire));
        assert!(matches!(
            peer.notify("initialized", json!({})).await,
            Err(PeerError::Closed)
        ));
        assert!(matches!(
            timeout(Duration::from_secs(1), incoming.recv()).await,
            Ok(None)
        ));
    }

    #[tokio::test]
    async fn catalog_deadlines_preserve_turn_events_and_ignore_late_replies() {
        for method in [
            "account/read",
            "thread/turns/list",
            "thread/items/list",
            "project/list",
            "thread/list",
            "thread/read",
            "model/list",
            "permissionProfile/list",
        ] {
            for outer_deadline in [false, true] {
                let (client, server) = tokio::io::duplex(4096);
                let (client_reader, client_writer) = tokio::io::split(client);
                let peer = CodexPeer::new(client_reader, client_writer, 8);
                let mut incoming = peer.take_incoming().expect("incoming stream");
                let (reader, mut writer) = tokio::io::split(server);
                let mut lines = BufReader::new(reader).lines();
                let deadline = Duration::from_millis(20);
                let request = async {
                    if outer_deadline {
                        assert!(
                            timeout(deadline, peer.request(method, json!({})))
                                .await
                                .is_err()
                        );
                    } else {
                        assert!(matches!(
                            peer.request_with_timeout(method, json!({}), deadline).await,
                            Err(PeerError::Timeout(name)) if name == method
                        ));
                    }
                };
                let (_, line) = tokio::join!(request, lines.next_line());
                let sent: Value = serde_json::from_str(&line.unwrap().unwrap()).unwrap();
                assert_eq!(sent["method"], method);
                assert!(peer.pending.lock().expect("pending map").is_empty());
                assert!(
                    !peer.closed.load(Ordering::Acquire),
                    "{method}, outer={outer_deadline}"
                );

                // A discarded reply must not consume or close the active turn's
                // event stream, nor interfere with the next control request.
                writer.write_all(b"{\"id\":1,\"result\":{\"late\":true}}\n{\"method\":\"turn/completed\",\"params\":{\"turnId\":\"active\"}}\n")
                    .await.expect("late reply and turn notification");
                assert!(matches!(
                    timeout(Duration::from_secs(1), incoming.recv()).await,
                    Ok(Some(IncomingMessage::Notification { method, .. })) if method == "turn/completed"
                ));
                let server_reply = async {
                    let next: Value =
                        serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
                    assert_eq!(next["method"], "turn/interrupt");
                    writer
                        .write_all(b"{\"id\":2,\"result\":{\"ok\":true}}\n")
                        .await
                        .unwrap();
                };
                let (result, _) = tokio::join!(
                    peer.request_with_timeout("turn/interrupt", json!({}), Duration::from_secs(1)),
                    server_reply
                );
                assert_eq!(result.unwrap(), json!({"ok": true}));
            }
        }
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
    async fn ignored_notification_overflow_does_not_kill_an_outstanding_request() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let _incoming = peer.take_incoming().expect("incoming stream");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("request read");
            writer
                .write_all(b"{\"method\":\"account/rateLimits/updated\",\"params\":{}}\n")
                .await
                .expect("first notification");
            writer
                .write_all(b"{\"method\":\"account/rateLimits/updated\",\"params\":{}}\n")
                .await
                .expect("overflow notification");
            writer
                .write_all(b"{\"id\":1,\"result\":{\"ok\":true}}\n")
                .await
                .expect("response");
        });
        let response = peer.request("test", json!({})).await.expect("response");
        assert_eq!(response["ok"], true);
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn critical_capacity_is_reserved_after_drop_safe_noise() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 2);
        let _incoming = peer.take_incoming().expect("incoming stream");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("request read");
            for _ in 0..2 {
                writer
                    .write_all(b"{\"method\":\"account/rateLimits/updated\",\"params\":{}}\n")
                    .await
                    .expect("noise notification");
            }
            writer
                .write_all(
                    b"{\"method\":\"turn/completed\",\"params\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"completed\"}}}\n",
                )
                .await
                .expect("critical notification");
            writer
                .write_all(b"{\"id\":1,\"result\":{\"ok\":true}}\n")
                .await
                .expect("response");
        });
        assert_eq!(
            peer.request("test", json!({}))
                .await
                .expect("response after reserved critical delivery")["ok"],
            true
        );
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn server_request_capacity_is_reserved_after_drop_safe_noise() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 2);
        let _incoming = peer.take_incoming().expect("incoming stream");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("request read");
            for _ in 0..2 {
                writer
                    .write_all(b"{\"method\":\"account/rateLimits/updated\",\"params\":{}}\n")
                    .await
                    .expect("noise notification");
            }
            writer
                .write_all(b"{\"id\":\"approval-1\",\"method\":\"item/commandExecution/requestApproval\",\"params\":{}}\n")
                .await
                .expect("server request");
            writer
                .write_all(b"{\"id\":1,\"result\":{\"ok\":true}}\n")
                .await
                .expect("response");
        });
        assert_eq!(
            peer.request("test", json!({}))
                .await
                .expect("response after reserved request delivery")["ok"],
            true
        );
        server_task.await.expect("server task");
    }

    #[tokio::test]
    async fn critical_notification_overflow_fails_closed() {
        let (client, server) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let peer = CodexPeer::new(client_reader, client_writer, 1);
        let _incoming = peer.take_incoming().expect("incoming stream");
        let server_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(server);
            let mut lines = BufReader::new(reader).lines();
            let _ = lines.next_line().await.expect("request read");
            for turn_id in ["turn-1", "turn-2"] {
                writer
                    .write_all(
                        format!(
                            "{{\"method\":\"turn/started\",\"params\":{{\"turn\":{{\"id\":\"{turn_id}\"}}}}}}\n"
                        )
                        .as_bytes(),
                    )
                    .await
                    .expect("critical notification");
            }
        });
        assert!(matches!(
            peer.request("test", json!({})).await,
            Err(PeerError::InvalidMessage(message)) if message.contains("queue overflowed")
        ));
        server_task.await.expect("server task");
    }
}

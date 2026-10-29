//! The control-protocol client: a Rust port of the Agent SDKs' `Query`.
//!
//! One [`ClaudeClient`] owns one CLI process. Its reader task routes control
//! responses to waiting requests, answers the CLI's own requests through a
//! [`ControlHandler`] (and in-process MCP servers), honours
//! `control_cancel_request`, and forwards every other frame, unchanged, as a
//! [`ClientEvent`].
//!
//! Lifetime: a supervisor task alone owns the child. When the last public
//! handle drops (including a `connect` cancelled mid-initialize), stdin
//! closes and the supervisor escalates to SIGTERM and SIGKILL after the
//! grace period, then reaps the process. The reader holds no process handle.
//!
//! Events go through a bounded queue. A consumer that stops reading never
//! stalls control responses: frames overflow into a bounded backlog, partial
//! message chunks are dropped first, and anything else lost is reported as a
//! [`ClientEvent::Gap`] the consumer repairs from the session store.

use std::collections::{HashMap, VecDeque};
use std::process::ExitStatus;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::process::Child;
use tokio::sync::{Notify, mpsc, oneshot, watch};

use crate::control::{
    IncomingRequest, InitializeRequest, InitializeResponse, InterruptReceipt, request,
};
use crate::input::UserMessage;
use crate::mcp::{BoxFuture, SdkMcpServer, rpc_error};
use crate::options::LaunchOptions;
use crate::transport::{self, BoxReader, BoxWriter, StderrTail};
use crate::wire::{self, CliMessage, Frame, MessageKind, ResultMessage, StartupFailure};

/// Answers the CLI's control requests other than `mcp_message`.
///
/// The returned value is the success payload; `Err` sends an error response.
/// `cancel` fires when the CLI withdraws the request (for example an approval
/// that became moot after an interrupt); the reply is then not sent.
pub trait ControlHandler: Send + Sync + 'static {
    fn handle(&self, call: IncomingCall, cancel: CancelSignal) -> BoxFuture<Result<Value, String>>;
}

/// One control request from the CLI.
#[derive(Clone, Debug)]
pub struct IncomingCall {
    /// The CLI's request id; answers and cancellations name it.
    pub request_id: String,
    pub request: IncomingRequest,
    /// The native `request` object.
    pub raw: Value,
}

/// Refuses everything: permission asks are denied, dialogs left unanswered.
#[derive(Clone, Copy, Debug, Default)]
pub struct RefuseAll;

impl ControlHandler for RefuseAll {
    fn handle(
        &self,
        call: IncomingCall,
        _cancel: CancelSignal,
    ) -> BoxFuture<Result<Value, String>> {
        Box::pin(async move {
            match call.request {
                IncomingRequest::CanUseTool(permission) => Ok(
                    crate::control::PermissionDecision::deny("No approver is attached")
                        .to_value(&permission.input),
                ),
                IncomingRequest::Elicitation(_) => Ok(json!({"action": "decline"})),
                IncomingRequest::HookCallback(hook) => Err(format!(
                    "No hook callback found for ID: {}",
                    hook.callback_id
                )),
                IncomingRequest::UserDialog(dialog) => Err(format!(
                    "dialog kind {} is not supported",
                    dialog.dialog_kind
                )),
                IncomingRequest::McpMessage { server_name, .. } => {
                    Err(format!("SDK MCP server {server_name} is not registered"))
                }
                IncomingRequest::Other { subtype, .. } => {
                    Err(format!("Unsupported control request subtype: {subtype}"))
                }
            }
        })
    }
}

/// Fires when the CLI withdraws a request.
#[derive(Clone, Debug)]
pub struct CancelSignal {
    receiver: watch::Receiver<bool>,
}

impl CancelSignal {
    pub fn is_cancelled(&self) -> bool {
        *self.receiver.borrow()
    }

    /// Resolves once cancelled (never, if the request completes first).
    pub async fn cancelled(&mut self) {
        while !*self.receiver.borrow_and_update() {
            if self.receiver.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        }
    }
}

/// Client tuning.
#[derive(Clone)]
pub struct ClientConfig {
    pub handler: Arc<dyn ControlHandler>,
    pub mcp_servers: Vec<(String, Arc<dyn SdkMcpServer>)>,
    pub request_timeout: Duration,
    /// MCP servers may take a while to start.
    pub initialize_timeout: Duration,
    /// After stdin closes, how long the CLI gets to exit before each signal.
    pub shutdown_grace: Duration,
    /// Events the consumer may leave unread before frames overflow.
    pub event_capacity: usize,
    /// Overflowed frames kept before they are dropped behind a gap.
    pub event_backlog: usize,
    /// A stdin write that takes longer has an unknown outcome.
    pub write_timeout: Duration,
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self {
            handler: Arc::new(RefuseAll),
            mcp_servers: Vec::new(),
            request_timeout: Duration::from_secs(60),
            initialize_timeout: Duration::from_secs(60),
            shutdown_grace: Duration::from_secs(5),
            event_capacity: 1024,
            event_backlog: 16 * 1024,
            write_timeout: Duration::from_secs(30),
        }
    }
}

/// Everything the client reports, in stdout order.
#[derive(Clone, Debug)]
pub enum ClientEvent {
    Message(CliMessage),
    /// A JSON-looking stdout line that did not parse.
    Malformed {
        line: String,
        error: String,
    },
    /// The CLI withdrew a request the handler was answering.
    RequestCancelled {
        request_id: String,
    },
    /// The consumer fell behind: `lost` frames were dropped (repair from the
    /// session store) and `partial` streaming chunks were skipped (their
    /// complete messages still arrive).
    Gap {
        lost: u64,
        partial: u64,
    },
    /// The process is gone; nothing follows.
    Exited(ExitReport),
}

/// How the process ended.
#[derive(Clone, Debug, Default)]
pub struct ExitReport {
    pub status: Option<ExitStatus>,
    pub stderr_tail: String,
    /// The last result frame, if it was an error.
    pub last_error_result: Option<ResultMessage>,
    pub read_error: Option<String>,
}

impl ExitReport {
    pub fn startup_failure(&self) -> Option<StartupFailure> {
        self.last_error_result
            .as_ref()?
            .startup_failure_reason
            .as_deref()
            .map(StartupFailure::parse)
    }

    /// One line for logs and notices.
    pub fn describe(&self) -> String {
        if let Some(result) = &self.last_error_result {
            return format!(
                "Claude Code returned an error result: {}",
                result.error_text()
            );
        }
        if let Some(error) = &self.read_error {
            return format!("Claude Code output could not be read: {error}");
        }
        match self.status {
            Some(status) if status.success() => "Claude Code exited".to_string(),
            Some(status) => {
                let stderr = self.stderr_tail.trim();
                if stderr.is_empty() {
                    format!("Claude Code exited with {status}")
                } else {
                    let last = stderr.lines().last().unwrap_or(stderr);
                    format!("Claude Code exited with {status}: {last}")
                }
            }
            None => "Claude Code exited".to_string(),
        }
    }
}

/// Why a control request failed.
#[derive(Clone, Debug, PartialEq, thiserror::Error)]
pub enum ControlError {
    #[error("control request {subtype} timed out")]
    Timeout { subtype: String },
    #[error("Claude Code refused {subtype}: {message}")]
    Refused { subtype: String, message: String },
    /// Nothing was written: the request never reached the CLI.
    #[error("Claude Code is not running: {0}")]
    Closed(String),
    /// The request may or may not have reached the CLI (a failed or stalled
    /// write, or the process ended before answering). Never retried
    /// automatically.
    #[error("delivery to Claude Code is unknown: {0}")]
    Unknown(String),
    #[error("control response for {subtype} was malformed: {message}")]
    Malformed { subtype: String, message: String },
}

/// Why a session could not start.
#[derive(Debug, thiserror::Error)]
pub enum ConnectError {
    #[error("Claude Code could not be started: {0}")]
    Spawn(#[source] std::io::Error),
    #[error("Claude Code did not initialize: {error}")]
    Initialize {
        error: ControlError,
        exit: Option<Box<ExitReport>>,
    },
}

impl ConnectError {
    /// The CLI's typed startup failure, when it reported one.
    pub fn startup_failure(&self) -> Option<StartupFailure> {
        match self {
            Self::Initialize {
                exit: Some(exit), ..
            } => exit.startup_failure(),
            _ => None,
        }
    }
}

/// What a waiting request receives: the CLI's answer, or the process ended.
enum Settled {
    Answered(Result<Value, String>),
    Closed(String),
}

type Pending = oneshot::Sender<Settled>;

/// State shared by the public handles, the reader and request handlers.
/// It holds no process handle: only the supervisor owns the child.
struct Inner {
    writer: tokio::sync::Mutex<Option<BoxWriter>>,
    pending: Mutex<HashMap<String, Pending>>,
    inflight: Mutex<HashMap<String, watch::Sender<bool>>>,
    counter: AtomicU64,
    closed: AtomicBool,
    pid: Option<u32>,
    stderr: StderrTail,
    session_state: watch::Sender<Option<String>>,
    exit: watch::Sender<Option<ExitReport>>,
    /// `Some(status)` once the supervisor reaped the child (`Some(None)`
    /// when there was no child or its status could not be read).
    reaped: watch::Sender<Option<Option<ExitStatus>>>,
    /// Asks the supervisor to shut the process down.
    shutdown: Notify,
    config: ClientConfig,
    servers: HashMap<String, Arc<dyn SdkMcpServer>>,
}

impl Inner {
    async fn write_json(&self, value: &Value) -> Result<(), ControlError> {
        let line = value.to_string();
        let mut writer = self.writer.lock().await;
        let Some(stream) = writer.as_mut() else {
            return Err(ControlError::Closed("stdin is closed".into()));
        };
        match tokio::time::timeout(
            self.config.write_timeout,
            transport::write_line(stream, &line),
        )
        .await
        {
            Ok(Ok(())) => Ok(()),
            // Part of the line may have reached the CLI.
            Ok(Err(error)) => {
                *writer = None;
                Err(ControlError::Unknown(error.to_string()))
            }
            Err(_) => {
                *writer = None;
                Err(ControlError::Unknown("stdin write stalled".into()))
            }
        }
    }

    fn begin_shutdown(&self) {
        self.closed.store(true, Ordering::Release);
        self.shutdown.notify_one();
    }
}

/// Dropped with the last public handle: closes stdin and has the supervisor
/// end the process.
struct Owner {
    inner: Arc<Inner>,
}

impl Drop for Owner {
    fn drop(&mut self) {
        if let Ok(mut writer) = self.inner.writer.try_lock() {
            writer.take();
        }
        self.inner.begin_shutdown();
    }
}

/// A handle to one running CLI process. Cheap to clone; the process lives
/// as long as any clone does.
#[derive(Clone)]
pub struct ClaudeClient {
    owner: Arc<Owner>,
}

/// Events from one client, in order.
pub type EventReceiver = mpsc::Receiver<ClientEvent>;

impl ClaudeClient {
    fn inner(&self) -> &Arc<Inner> {
        &self.owner.inner
    }

    /// Spawns the CLI and starts reading. Call [`Self::initialize`] next.
    pub fn spawn(
        options: &LaunchOptions,
        config: ClientConfig,
    ) -> std::io::Result<(Self, EventReceiver)> {
        let spawned = transport::spawn(&options.command())?;
        let pid = spawned.child.id();
        Ok(Self::start(
            spawned.stdout,
            spawned.stdin,
            Some(spawned.child),
            pid,
            spawned.stderr,
            config,
        ))
    }

    /// Spawns, initializes and returns the catalogs. A startup failure the
    /// CLI reports is carried in the error. Cancelling this future ends the
    /// process.
    pub async fn connect(
        options: &LaunchOptions,
        config: ClientConfig,
        initialize: &InitializeRequest,
    ) -> Result<(Self, EventReceiver, InitializeResponse), ConnectError> {
        let (client, events) = Self::spawn(options, config).map_err(ConnectError::Spawn)?;
        match client.initialize(initialize).await {
            Ok(response) => Ok((client, events, response)),
            Err(error) => {
                let exit = client.close().await.map(Box::new);
                Err(ConnectError::Initialize { error, exit })
            }
        }
    }

    /// Runs the protocol over arbitrary streams (tests, recorded fixtures).
    pub fn from_streams(
        reader: BoxReader,
        writer: BoxWriter,
        config: ClientConfig,
    ) -> (Self, EventReceiver) {
        Self::start(reader, writer, None, None, StderrTail::default(), config)
    }

    fn start(
        reader: BoxReader,
        writer: BoxWriter,
        child: Option<Child>,
        pid: Option<u32>,
        stderr: StderrTail,
        config: ClientConfig,
    ) -> (Self, EventReceiver) {
        let (events, receiver) = mpsc::channel(config.event_capacity.max(1));
        let servers = config.mcp_servers.iter().cloned().collect();
        let inner = Arc::new(Inner {
            writer: tokio::sync::Mutex::new(Some(writer)),
            pending: Mutex::default(),
            inflight: Mutex::default(),
            counter: AtomicU64::new(0),
            closed: AtomicBool::new(false),
            pid,
            stderr,
            session_state: watch::channel(None).0,
            exit: watch::channel(None).0,
            reaped: watch::channel(None).0,
            shutdown: Notify::new(),
            config,
            servers,
        });
        match child {
            Some(child) => {
                tokio::spawn(supervise(inner.clone(), child));
            }
            None => {
                inner.reaped.send_replace(Some(None));
            }
        }
        let sink = EventSink::new(events, &inner.config);
        tokio::spawn(read_loop(inner.clone(), reader, sink));
        (
            Self {
                owner: Arc::new(Owner { inner }),
            },
            receiver,
        )
    }

    pub fn pid(&self) -> Option<u32> {
        self.inner().pid
    }

    /// The latest `session_state_changed` state: `idle`, `running` or
    /// `requires_action`; `None` until the CLI reports one.
    pub fn session_state(&self) -> watch::Receiver<Option<String>> {
        self.inner().session_state.subscribe()
    }

    /// `Some` once the process is gone.
    pub fn exit(&self) -> watch::Receiver<Option<ExitReport>> {
        self.inner().exit.subscribe()
    }

    pub fn is_closed(&self) -> bool {
        self.inner().closed.load(Ordering::Acquire) || self.inner().exit.borrow().is_some()
    }

    pub fn stderr_tail(&self) -> String {
        self.inner().stderr.text()
    }

    /// Writes one user message. `Closed` means it was not written;
    /// `Unknown` means it may have reached the CLI.
    pub async fn send(&self, message: &UserMessage) -> Result<(), ControlError> {
        self.write_json(&message.to_value()).await
    }

    /// Writes any stdin frame verbatim.
    pub async fn write_json(&self, value: &Value) -> Result<(), ControlError> {
        self.inner().write_json(value).await
    }

    /// Sends a control request and waits for its response payload. Once the
    /// request is written, losing the process makes the outcome unknown.
    pub async fn request(&self, body: Value, timeout: Duration) -> Result<Value, ControlError> {
        let inner = self.inner();
        let subtype = body
            .get("subtype")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        if let Some(exit) = inner.exit.borrow().as_ref() {
            return Err(ControlError::Closed(exit.describe()));
        }
        let counter = inner.counter.fetch_add(1, Ordering::Relaxed) + 1;
        let request_id = format!(
            "req_{counter}_{}",
            &uuid::Uuid::new_v4().simple().to_string()[..8]
        );
        let (sender, receiver) = oneshot::channel();
        lock(&inner.pending).insert(request_id.clone(), sender);
        let envelope =
            json!({"type": "control_request", "request_id": request_id, "request": body});
        if let Err(error) = inner.write_json(&envelope).await {
            lock(&inner.pending).remove(&request_id);
            return Err(error);
        }
        match tokio::time::timeout(timeout, receiver).await {
            Ok(Ok(Settled::Answered(Ok(response)))) => Ok(response),
            Ok(Ok(Settled::Answered(Err(message)))) => {
                Err(ControlError::Refused { subtype, message })
            }
            Ok(Ok(Settled::Closed(reason))) => Err(ControlError::Unknown(reason)),
            Ok(Err(_)) => Err(ControlError::Unknown("the reader stopped".into())),
            Err(_) => {
                lock(&inner.pending).remove(&request_id);
                let _ = inner
                    .write_json(
                        &json!({"type": "control_cancel_request", "request_id": request_id}),
                    )
                    .await;
                Err(ControlError::Timeout { subtype })
            }
        }
    }

    fn timeout(&self) -> Duration {
        self.inner().config.request_timeout
    }

    pub async fn initialize(
        &self,
        initialize: &InitializeRequest,
    ) -> Result<InitializeResponse, ControlError> {
        let mut body = initialize.to_value();
        if !self.inner().servers.is_empty() {
            let mut names: Vec<&String> = self.inner().servers.keys().collect();
            names.sort();
            body["sdkMcpServers"] = json!(names);
        }
        let response = self
            .request(body, self.inner().config.initialize_timeout)
            .await?;
        serde_json::from_value(response).map_err(|error| ControlError::Malformed {
            subtype: "initialize".into(),
            message: error.to_string(),
        })
    }

    /// Stops the current turn. With `cancel_queued`, queued user messages are
    /// cancelled too (and listed in the receipt) instead of running next.
    pub async fn interrupt(&self, cancel_queued: bool) -> Result<InterruptReceipt, ControlError> {
        let response = self
            .request(request::interrupt(cancel_queued), self.timeout())
            .await?;
        Ok(serde_json::from_value(response).unwrap_or_default())
    }

    pub async fn set_model(&self, model: Option<&str>) -> Result<Value, ControlError> {
        self.request(request::set_model(model), self.timeout())
            .await
    }

    pub async fn set_permission_mode(&self, mode: &str) -> Result<Value, ControlError> {
        self.request(request::set_permission_mode(mode), self.timeout())
            .await
    }

    pub async fn set_max_thinking_tokens(
        &self,
        tokens: Option<u64>,
    ) -> Result<Value, ControlError> {
        self.request(request::set_max_thinking_tokens(tokens), self.timeout())
            .await
    }

    pub async fn get_context_usage(&self) -> Result<Value, ControlError> {
        self.request(request::get_context_usage(), self.timeout())
            .await
    }

    pub async fn mcp_status(&self) -> Result<Value, ControlError> {
        self.request(request::mcp_status(), self.timeout()).await
    }

    pub async fn mcp_toggle(&self, server: &str, enabled: bool) -> Result<Value, ControlError> {
        self.request(request::mcp_toggle(server, enabled), self.timeout())
            .await
    }

    pub async fn mcp_reconnect(&self, server: &str) -> Result<Value, ControlError> {
        self.request(request::mcp_reconnect(server), self.timeout())
            .await
    }

    pub async fn rewind_files(
        &self,
        user_message_id: &str,
        dry_run: bool,
    ) -> Result<Value, ControlError> {
        self.request(
            request::rewind_files(user_message_id, dry_run),
            self.timeout(),
        )
        .await
    }

    pub async fn stop_task(&self, task_id: &str) -> Result<Value, ControlError> {
        self.request(request::stop_task(task_id), self.timeout())
            .await
    }

    pub async fn cancel_async_message(&self, message_uuid: &str) -> Result<Value, ControlError> {
        self.request(request::cancel_async_message(message_uuid), self.timeout())
            .await
    }

    pub async fn rename_session(
        &self,
        title: &str,
        session_id: Option<&str>,
    ) -> Result<Value, ControlError> {
        self.request(request::rename_session(title, session_id), self.timeout())
            .await
    }

    pub async fn background_tasks(&self, tool_use_id: Option<&str>) -> Result<Value, ControlError> {
        self.request(request::background_tasks(tool_use_id), self.timeout())
            .await
    }

    /// Closes stdin. The CLI finishes what it owes and exits.
    pub async fn end_input(&self) {
        self.inner().writer.lock().await.take();
    }

    /// Closes stdin, then has the supervisor wait for exit, escalating to
    /// SIGTERM and SIGKILL after the grace period, and returns the report.
    pub async fn close(&self) -> Option<ExitReport> {
        self.end_input().await;
        self.inner().begin_shutdown();
        let grace = self.inner().config.shutdown_grace;
        self.wait_exit(grace * 3 + Duration::from_secs(2)).await
    }

    /// Waits up to `timeout` for the exit report.
    pub async fn wait_exit(&self, timeout: Duration) -> Option<ExitReport> {
        let mut exit = self.inner().exit.subscribe();
        let wait = async {
            loop {
                if let Some(report) = exit.borrow_and_update().clone() {
                    return Some(report);
                }
                if exit.changed().await.is_err() {
                    return None;
                }
            }
        };
        tokio::time::timeout(timeout, wait).await.ok().flatten()
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// The only owner of the child: reaps it when it exits on its own, or shuts
/// it down (stdin closed, then SIGTERM and SIGKILL to its group) when asked.
async fn supervise(inner: Arc<Inner>, mut child: Child) {
    let status = tokio::select! {
        status = child.wait() => status.ok(),
        () = inner.shutdown.notified() => {
            inner.writer.lock().await.take();
            transport::shut_down(&mut child, inner.config.shutdown_grace).await.ok()
        }
    };
    inner.reaped.send_replace(Some(status));
}

/// Bounded delivery to the consumer that never blocks the reader: the
/// reader appends to a capped queue and a forwarder task feeds the channel
/// as the consumer reads.
struct EventSink {
    queue: Arc<EventQueue>,
}

struct EventQueue {
    state: Mutex<QueueState>,
    ready: Notify,
    cap: usize,
}

#[derive(Default)]
struct QueueState {
    items: VecDeque<ClientEvent>,
    lost: u64,
    partial: u64,
    closed: bool,
}

fn is_partial(event: &ClientEvent) -> bool {
    matches!(event, ClientEvent::Message(message) if matches!(message.kind, MessageKind::StreamEvent(_)))
}

impl EventSink {
    fn new(sender: mpsc::Sender<ClientEvent>, config: &ClientConfig) -> Self {
        let queue = Arc::new(EventQueue {
            state: Mutex::new(QueueState::default()),
            ready: Notify::new(),
            cap: config.event_backlog.max(1),
        });
        tokio::spawn(forward(queue.clone(), sender));
        Self { queue }
    }

    fn push(&mut self, event: ClientEvent) {
        let mut state = lock(&self.queue.state);
        if state.items.len() >= self.queue.cap {
            if is_partial(&event) {
                // The complete assistant message carries the same content.
                state.partial += 1;
                return;
            }
            if let Some(index) = state.items.iter().position(is_partial) {
                state.items.remove(index);
                state.partial += 1;
            } else {
                state.lost += state.items.len() as u64;
                state.items.clear();
            }
        }
        state.items.push_back(event);
        drop(state);
        self.queue.ready.notify_one();
    }

    /// Queues the last event and lets the forwarder drain and end.
    async fn finish(mut self, last: ClientEvent) {
        self.push(last);
        lock(&self.queue.state).closed = true;
        self.queue.ready.notify_one();
    }
}

async fn forward(queue: Arc<EventQueue>, sender: mpsc::Sender<ClientEvent>) {
    loop {
        let next = {
            let mut state = lock(&queue.state);
            if state.lost > 0 || state.partial > 0 {
                let gap = ClientEvent::Gap {
                    lost: state.lost,
                    partial: state.partial,
                };
                state.lost = 0;
                state.partial = 0;
                Some(gap)
            } else if let Some(event) = state.items.pop_front() {
                Some(event)
            } else if state.closed {
                return;
            } else {
                None
            }
        };
        match next {
            Some(event) => {
                if sender.send(event).await.is_err() {
                    return;
                }
            }
            None => queue.ready.notified().await,
        }
    }
}

async fn read_loop(inner: Arc<Inner>, mut reader: BoxReader, mut sink: EventSink) {
    let mut line = Vec::new();
    let mut last_error_result: Option<ResultMessage> = None;
    let mut read_error = None;
    loop {
        match transport::read_line(&mut reader, &mut line).await {
            Ok(false) => break,
            Ok(true) => {}
            Err(error) => {
                read_error = Some(error.to_string());
                break;
            }
        }
        let frame = match wire::parse_line(&line) {
            Ok(Some(frame)) => frame,
            Ok(None) => continue,
            Err(error) => {
                sink.push(ClientEvent::Malformed {
                    line: String::from_utf8_lossy(&line).trim_end().to_string(),
                    error: error.to_string(),
                });
                continue;
            }
        };
        match frame {
            Frame::ControlResponse(response) => {
                if let Some(sender) = lock(&inner.pending).remove(&response.request_id) {
                    let _ = sender.send(Settled::Answered(response.outcome));
                }
            }
            Frame::ControlRequest {
                request_id,
                request,
            } => spawn_request_handler(inner.clone(), request_id, request),
            Frame::ControlCancel { request_id } => {
                if let Some(cancel) = lock(&inner.inflight).remove(&request_id) {
                    let _ = cancel.send(true);
                    sink.push(ClientEvent::RequestCancelled { request_id });
                }
            }
            Frame::KeepAlive => {}
            Frame::Message(message) => {
                match &message.kind {
                    MessageKind::SessionState(state) => {
                        inner.session_state.send_replace(Some(state.state.clone()));
                    }
                    MessageKind::Result(result) => {
                        last_error_result = result.is_error.then(|| result.clone());
                    }
                    _ => {}
                }
                sink.push(ClientEvent::Message(message));
            }
        }
    }

    // stdout ended: the session is over even if the process lingers.
    inner.writer.lock().await.take();
    inner.begin_shutdown();
    let mut reaped = inner.reaped.subscribe();
    let wait = inner.config.shutdown_grace * 3 + Duration::from_secs(2);
    let status = tokio::time::timeout(wait, async {
        loop {
            if let Some(status) = *reaped.borrow_and_update() {
                return status;
            }
            if reaped.changed().await.is_err() {
                return None;
            }
        }
    })
    .await
    .ok()
    .flatten();
    let report = ExitReport {
        status,
        stderr_tail: inner.stderr.text(),
        last_error_result,
        read_error,
    };
    for (_, sender) in lock(&inner.pending).drain() {
        let _ = sender.send(Settled::Closed(report.describe()));
    }
    for (_, cancel) in lock(&inner.inflight).drain() {
        let _ = cancel.send(true);
    }
    inner.exit.send_replace(Some(report.clone()));
    sink.finish(ClientEvent::Exited(report)).await;
}

fn spawn_request_handler(inner: Arc<Inner>, request_id: String, request: Value) {
    let (cancel_sender, cancel_receiver) = watch::channel(false);
    lock(&inner.inflight).insert(request_id.clone(), cancel_sender);
    let cancel = CancelSignal {
        receiver: cancel_receiver,
    };
    tokio::spawn(async move {
        let parsed = IncomingRequest::parse(&request);
        let outcome = match parsed {
            IncomingRequest::McpMessage {
                server_name,
                message,
            } => Ok(answer_mcp(&inner, &server_name, message).await),
            other => {
                let mut cancelled = cancel.clone();
                let call = IncomingCall {
                    request_id: request_id.clone(),
                    request: other,
                    raw: request.clone(),
                };
                let handler = inner.config.handler.handle(call, cancel.clone());
                tokio::select! {
                    outcome = handler => outcome,
                    () = cancelled.cancelled() => {
                        lock(&inner.inflight).remove(&request_id);
                        return;
                    }
                }
            }
        };
        if lock(&inner.inflight).remove(&request_id).is_none() {
            // Withdrawn while the answer was being produced.
            return;
        }
        let response = match outcome {
            Ok(payload) => json!({
                "type": "control_response",
                "response": {"subtype": "success", "request_id": request_id, "response": payload}
            }),
            Err(error) => json!({
                "type": "control_response",
                "response": {"subtype": "error", "request_id": request_id, "error": error}
            }),
        };
        if let Err(error) = inner.write_json(&response).await {
            log::debug!("control response not delivered: {error}");
        }
    });
}

async fn answer_mcp(inner: &Inner, server_name: &str, message: Value) -> Value {
    let id = message.get("id").cloned().unwrap_or(Value::Null);
    let response = match inner.servers.get(server_name) {
        Some(server) => server.handle(message).await,
        None => Some(rpc_error(
            id,
            -32601,
            &format!("Server '{server_name}' not found"),
        )),
    };
    // A notification gets no JSON-RPC reply, but its control request still
    // expects an acknowledgement.
    json!({"mcp_response": response.unwrap_or_else(|| json!({"jsonrpc": "2.0", "result": {}}))})
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines};

    use super::*;
    use crate::control::PermissionDecision;
    use crate::mcp::{ToolDefinition, ToolOutput, ToolServer};

    struct FakeCli {
        to_client: DuplexStream,
        from_client: Lines<BufReader<DuplexStream>>,
    }

    impl FakeCli {
        async fn write(&mut self, value: Value) {
            self.to_client
                .write_all(format!("{value}\n").as_bytes())
                .await
                .unwrap();
        }

        async fn read(&mut self) -> Value {
            let line = self.from_client.next_line().await.unwrap().unwrap();
            serde_json::from_str(&line).unwrap()
        }
    }

    fn harness(config: ClientConfig) -> (ClaudeClient, EventReceiver, FakeCli) {
        let (client_out, cli_in) = tokio::io::duplex(1 << 20);
        let (cli_out, client_in) = tokio::io::duplex(1 << 20);
        let (client, events) = ClaudeClient::from_streams(
            Box::new(BufReader::new(client_in)),
            Box::new(client_out),
            config,
        );
        let fake = FakeCli {
            to_client: cli_out,
            from_client: BufReader::new(cli_in).lines(),
        };
        (client, events, fake)
    }

    #[tokio::test]
    async fn requests_resolve_by_request_id() {
        let (client, _events, mut cli) = harness(ClientConfig::default());
        let interrupt = tokio::spawn({
            let client = client.clone();
            async move { client.interrupt(true).await }
        });
        let request = cli.read().await;
        assert_eq!(request["type"], json!("control_request"));
        assert_eq!(
            request["request"],
            json!({"subtype": "interrupt", "cancel_queued": true})
        );
        cli.write(json!({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": request["request_id"],
                "response": {"still_queued": [], "cancelled": ["l1"]}}
        }))
        .await;
        let receipt = interrupt.await.unwrap().unwrap();
        assert_eq!(receipt.cancelled.unwrap(), ["l1"]);
    }

    #[tokio::test]
    async fn error_responses_are_refusals() {
        let (client, _events, mut cli) = harness(ClientConfig::default());
        let call = tokio::spawn({
            let client = client.clone();
            async move { client.set_model(Some("nope")).await }
        });
        let request = cli.read().await;
        cli.write(json!({
            "type": "control_response",
            "response": {"subtype": "error", "request_id": request["request_id"], "error": "bad model"}
        }))
        .await;
        assert_eq!(
            call.await.unwrap(),
            Err(ControlError::Refused {
                subtype: "set_model".into(),
                message: "bad model".into()
            })
        );
    }

    struct Approver;

    impl ControlHandler for Approver {
        fn handle(
            &self,
            call: IncomingCall,
            mut cancel: CancelSignal,
        ) -> BoxFuture<Result<Value, String>> {
            Box::pin(async move {
                let IncomingRequest::CanUseTool(permission) = call.request else {
                    return Err("unexpected".into());
                };
                if permission.tool_name == "Wait" {
                    cancel.cancelled().await;
                    return Err("cancelled".into());
                }
                Ok(PermissionDecision::allow().to_value(&permission.input))
            })
        }
    }

    #[tokio::test]
    async fn can_use_tool_is_answered_and_cancel_suppresses_the_reply() {
        let config = ClientConfig {
            handler: Arc::new(Approver),
            ..ClientConfig::default()
        };
        let (_client, mut events, mut cli) = harness(config);
        cli.write(json!({"type": "control_request", "request_id": "w1",
            "request": {"subtype": "can_use_tool", "tool_name": "Wait", "input": {}}}))
            .await;
        cli.write(json!({"type": "control_cancel_request", "request_id": "w1"}))
            .await;
        cli.write(json!({"type": "control_request", "request_id": "c1",
            "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "ls"}}}))
            .await;
        let response = cli.read().await;
        assert_eq!(response["response"]["request_id"], json!("c1"));
        assert_eq!(
            response["response"]["response"],
            json!({"behavior": "allow", "updatedInput": {"command": "ls"}})
        );
        match events.recv().await.unwrap() {
            ClientEvent::RequestCancelled { request_id } => assert_eq!(request_id, "w1"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[tokio::test]
    async fn mcp_messages_reach_in_process_servers() {
        let server = ToolServer::new(
            "inline",
            "0",
            vec![ToolDefinition {
                name: "echo".into(),
                description: String::new(),
                input_schema: json!({"type": "object"}),
                annotations: None,
            }],
            |_tool: String, arguments: Value| async move { ToolOutput::text(arguments.to_string()) },
        );
        let config = ClientConfig {
            mcp_servers: vec![("inline".into(), Arc::new(server) as Arc<dyn SdkMcpServer>)],
            ..ClientConfig::default()
        };
        let (_client, _events, mut cli) = harness(config);
        cli.write(
            json!({"type": "control_request", "request_id": "m1", "request": {
            "subtype": "mcp_message", "server_name": "inline",
            "message": {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                "params": {"name": "echo", "arguments": {"a": 1}}}}}),
        )
        .await;
        let response = cli.read().await;
        assert_eq!(
            response["response"]["response"]["mcp_response"]["result"]["content"][0]["text"],
            json!("{\"a\":1}")
        );
        cli.write(
            json!({"type": "control_request", "request_id": "m2", "request": {
            "subtype": "mcp_message", "server_name": "missing",
            "message": {"jsonrpc": "2.0", "id": 5, "method": "tools/list"}}}),
        )
        .await;
        let response = cli.read().await;
        assert_eq!(
            response["response"]["response"]["mcp_response"]["error"]["code"],
            json!(-32601)
        );
    }

    #[tokio::test]
    async fn messages_flow_in_order_and_exit_fails_pending_requests() {
        let (client, mut events, mut cli) = harness(ClientConfig::default());
        cli.write(
            json!({"type": "system", "subtype": "session_state_changed", "state": "running"}),
        )
        .await;
        cli.write(
            json!({"type": "result", "subtype": "success", "is_error": true,
            "startup_failure_reason": "cli_version_too_old", "errors": ["too old"]}),
        )
        .await;
        let pending = tokio::spawn({
            let client = client.clone();
            async move { client.get_context_usage().await }
        });
        let _ = cli.read().await;
        drop(cli);

        let mut kinds = Vec::new();
        while let Some(event) = events.recv().await {
            match event {
                ClientEvent::Message(message) => kinds.push(message.message_type().to_string()),
                ClientEvent::Exited(report) => {
                    assert_eq!(
                        report.startup_failure(),
                        Some(StartupFailure::CliVersionTooOld)
                    );
                    break;
                }
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(kinds, ["system", "result"]);
        assert_eq!(client.session_state().borrow().as_deref(), Some("running"));
        // Written, then the process went away: the outcome is unknown.
        assert!(matches!(
            pending.await.unwrap(),
            Err(ControlError::Unknown(_))
        ));
    }

    fn fast() -> ClientConfig {
        ClientConfig {
            shutdown_grace: Duration::from_millis(200),
            ..ClientConfig::default()
        }
    }

    /// A stand-in CLI: a shell script that ignores Claude's arguments.
    fn fake_cli(dir: &std::path::Path, body: &str) -> LaunchOptions {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join("fake-claude");
        std::fs::write(
            &path,
            format!(
                "#!/bin/sh\n[ -n \"$FAKE_PROBE\" ] && exit 0\necho $$ > \"$PID_FILE\"\n{body}\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        // A parallel test's fork can briefly hold the script open for writing
        // (Linux ETXTBSY). Once one exec succeeds no writer is left.
        for _ in 0..100 {
            match std::process::Command::new(&path)
                .env("FAKE_PROBE", "1")
                .status()
            {
                Err(error) if error.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                result => {
                    result.unwrap();
                    break;
                }
            }
        }
        let mut options = LaunchOptions::new(&path, dir);
        options
            .env
            .push(("PID_FILE".into(), dir.join("pid").into_os_string()));
        options
    }

    async fn pid_of(dir: &std::path::Path) -> u32 {
        for _ in 0..100 {
            if let Ok(text) = std::fs::read_to_string(dir.join("pid"))
                && let Ok(pid) = text.trim().parse()
            {
                return pid;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("fake CLI never started");
    }

    fn alive(pid: u32) -> bool {
        unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
    }

    async fn gone(pid: u32) -> bool {
        for _ in 0..100 {
            if !alive(pid) {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        false
    }

    #[tokio::test]
    async fn dropping_the_last_handle_ends_even_a_stubborn_process() {
        let dir = tempfile::tempdir().unwrap();
        // Ignores stdin EOF and SIGTERM: only SIGKILL ends it.
        let options = fake_cli(dir.path(), "trap '' TERM\nexec sleep 30");
        let (client, events) = ClaudeClient::spawn(&options, fast()).unwrap();
        let pid = pid_of(dir.path()).await;
        assert!(alive(pid));
        let second = client.clone();
        drop(client);
        assert!(alive(pid), "a remaining handle keeps the process");
        drop(second);
        drop(events);
        assert!(gone(pid).await, "process {pid} outlived its last handle");
    }

    #[tokio::test]
    async fn cancelling_initialize_leaves_no_process() {
        let dir = tempfile::tempdir().unwrap();
        let options = fake_cli(dir.path(), "exec sleep 30");
        let attempt = tokio::time::timeout(
            Duration::from_millis(300),
            ClaudeClient::connect(&options, fast(), &InitializeRequest::default()),
        )
        .await;
        assert!(attempt.is_err(), "initialize never answers");
        let pid = pid_of(dir.path()).await;
        assert!(
            gone(pid).await,
            "process {pid} survived a cancelled connect"
        );
    }

    #[tokio::test]
    async fn losing_stdout_ends_the_session_and_the_process() {
        let dir = tempfile::tempdir().unwrap();
        let options = fake_cli(dir.path(), "exec >&-\nexec sleep 30");
        let (client, mut events) = ClaudeClient::spawn(&options, fast()).unwrap();
        let pid = pid_of(dir.path()).await;
        let exited = tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(event) = events.recv().await {
                if let ClientEvent::Exited(report) = event {
                    return Some(report);
                }
            }
            None
        })
        .await
        .expect("exit reported")
        .expect("exit event");
        assert!(exited.status.is_some(), "the supervisor reaped it");
        assert!(gone(pid).await);
        assert!(client.is_closed());
        assert!(matches!(
            client.get_context_usage().await,
            Err(ControlError::Closed(_))
        ));
    }

    #[tokio::test]
    async fn a_stalled_consumer_never_blocks_control_responses() {
        let config = ClientConfig {
            event_capacity: 4,
            event_backlog: 8,
            ..ClientConfig::default()
        };
        let (client, mut events, mut cli) = harness(config);
        for index in 0..40 {
            cli.write(json!({"type": "stream_event", "uuid": format!("s{index}"), "session_id": "s",
                "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "x"}}}))
                .await;
            cli.write(json!({"type": "assistant", "uuid": format!("a{index}"),
                "message": {"id": format!("m{index}"), "content": []}}))
                .await;
        }
        let request = tokio::spawn({
            let client = client.clone();
            async move { client.mcp_status().await }
        });
        let sent = cli.read().await;
        cli.write(
            json!({"type": "control_response", "response": {"subtype": "success",
            "request_id": sent["request_id"], "response": {"mcpServers": []}}}),
        )
        .await;
        let answer = tokio::time::timeout(Duration::from_secs(5), request)
            .await
            .expect("control response arrived while the consumer stalled")
            .unwrap();
        assert!(answer.is_ok());

        // The consumer catches up: bounded delivery plus an explicit gap.
        let mut messages = 0;
        let mut gaps = Vec::new();
        cli.write(json!({"type": "keep_alive"})).await;
        while let Ok(Some(event)) =
            tokio::time::timeout(Duration::from_millis(300), events.recv()).await
        {
            match event {
                ClientEvent::Message(_) => messages += 1,
                ClientEvent::Gap { lost, partial } => gaps.push((lost, partial)),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert!(messages <= 4 + 8 + 1, "{messages} messages retained");
        let lost: u64 = gaps.iter().map(|gap| gap.0).sum();
        let partial: u64 = gaps.iter().map(|gap| gap.1).sum();
        assert!(partial > 0, "partial chunks are dropped first: {gaps:?}");
        assert_eq!(
            messages as u64 + lost + partial,
            80,
            "every frame is delivered or counted"
        );
    }

    #[tokio::test]
    async fn delivery_is_closed_before_writing_and_unknown_after() {
        let (client, _events, mut cli) = harness(ClientConfig::default());
        let pending = tokio::spawn({
            let client = client.clone();
            async move { client.interrupt(false).await }
        });
        let _ = cli.read().await;
        drop(cli);
        assert!(matches!(
            pending.await.unwrap(),
            Err(ControlError::Unknown(_))
        ));

        let (client, _events, _cli) = harness(ClientConfig::default());
        client.end_input().await;
        assert!(matches!(
            client.interrupt(false).await,
            Err(ControlError::Closed(_))
        ));
        assert!(matches!(
            client.send(&UserMessage::text("hi")).await,
            Err(ControlError::Closed(_))
        ));
    }
}

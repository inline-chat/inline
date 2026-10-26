//! Lab harness: the real `claude` against the fake Messages API, with an
//! isolated config dir, recording every frame as evidence.
//!
//! Labs run only when `CLAUDE_LAB_BIN` names a `claude` executable:
//!
//! ```text
//! CLAUDE_LAB_BIN=/opt/homebrew/bin/claude CLAUDE_LAB_OUT=/tmp/lab \
//!   cargo test -p inline-agent-driver-claude --test claude_lab -- --ignored --test-threads=1
//! ```

#![allow(dead_code)]

pub mod fake_messages;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use inline_agent_driver_claude::mcp::BoxFuture;
use inline_agent_driver_claude::client::IncomingCall;
use inline_agent_driver_claude::control::IncomingRequest;
use inline_agent_driver_claude::{
    CancelSignal, ClaudeClient, ClaudeVersion, ClientConfig, ClientEvent, ControlHandler,
    InitializeRequest, InitializeResponse, LaunchOptions, PermissionDecision, PermissionRequest,
    SessionStart,
};
use serde_json::{Value, json};
use tokio::sync::Notify;

pub use fake_messages::FakeMessages;

pub type Policy = Arc<dyn Fn(&PermissionRequest) -> PermissionDecision + Send + Sync>;

/// Everything one scenario observed, in order.
#[derive(Clone, Default)]
pub struct Recorder {
    entries: Arc<Mutex<Vec<Value>>>,
    events: Arc<Mutex<Vec<ClientEvent>>>,
    changed: Arc<Notify>,
    started: Arc<Mutex<Option<Instant>>>,
}

impl Recorder {
    fn elapsed_ms(&self) -> u128 {
        let mut started = self.started.lock().unwrap();
        started.get_or_insert_with(Instant::now).elapsed().as_millis()
    }

    pub fn note(&self, direction: &str, value: Value) {
        let entry = json!({"t_ms": self.elapsed_ms() as u64, "dir": direction, "frame": value});
        self.entries.lock().unwrap().push(entry);
        self.changed.notify_waiters();
    }

    fn push_event(&self, event: ClientEvent) {
        let frame = match &event {
            ClientEvent::Message(message) => message.raw.clone(),
            ClientEvent::Malformed { line, error } => {
                json!({"lab": "malformed", "line": line, "error": error})
            }
            ClientEvent::RequestCancelled { request_id } => {
                json!({"lab": "request_cancelled", "request_id": request_id})
            }
            ClientEvent::Exited(report) => json!({
                "lab": "exited",
                "status": report.status.map(|status| status.to_string()),
                "describe": report.describe(),
                "stderr_tail": report.stderr_tail,
            }),
        };
        self.events.lock().unwrap().push(event);
        self.note("in", frame);
    }

    pub fn frames(&self) -> Vec<Value> {
        self.entries
            .lock()
            .unwrap()
            .iter()
            .filter(|entry| entry["dir"] == "in")
            .map(|entry| entry["frame"].clone())
            .collect()
    }

    pub fn entries(&self) -> Vec<Value> {
        self.entries.lock().unwrap().clone()
    }

    /// Frames of one type (and subtype, when given).
    pub fn of(&self, kind: &str, subtype: Option<&str>) -> Vec<Value> {
        self.frames()
            .into_iter()
            .filter(|frame| frame["type"] == kind)
            .filter(|frame| subtype.is_none_or(|subtype| frame["subtype"] == subtype))
            .collect()
    }

    pub fn results(&self) -> Vec<Value> {
        self.of("result", None)
    }

    pub fn lifecycle(&self, uuid: &str) -> Vec<String> {
        self.of("command_lifecycle", None)
            .into_iter()
            .filter(|frame| frame["command_uuid"] == uuid)
            .filter_map(|frame| frame["state"].as_str().map(str::to_string))
            .collect()
    }

    /// Waits until `predicate` holds over the recorded frames.
    pub async fn wait_for(
        &self,
        what: &str,
        timeout: Duration,
        predicate: impl Fn(&[Value]) -> bool,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let notified = self.changed.notified();
            if predicate(&self.frames()) {
                return true;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                eprintln!("lab: timed out waiting for {what}");
                self.note("lab", json!({"timeout": what}));
                return false;
            }
            let _ = tokio::time::timeout(remaining, notified).await;
        }
    }

    pub async fn wait_results(&self, count: usize, timeout: Duration) -> bool {
        self.wait_for(&format!("{count} results"), timeout, |frames| {
            frames.iter().filter(|frame| frame["type"] == "result").count() >= count
        })
        .await
    }
}

/// Answers permission asks with a policy and records every request.
struct LabHandler {
    recorder: Recorder,
    policy: Policy,
}

impl ControlHandler for LabHandler {
    fn handle(&self, call: IncomingCall, _cancel: CancelSignal) -> BoxFuture<Result<Value, String>> {
        let recorder = self.recorder.clone();
        let policy = self.policy.clone();
        Box::pin(async move {
            match call.request {
                IncomingRequest::CanUseTool(permission) => {
                    let decision = policy(&permission);
                    let response = decision.to_value(&permission.input);
                    recorder.note(
                        "control",
                        json!({"can_use_tool": permission.raw, "answer": response}),
                    );
                    Ok(response)
                }
                other => {
                    recorder.note("control", json!({"unhandled": format!("{other:?}")}));
                    Err("not handled in the lab".into())
                }
            }
        })
    }
}

pub struct Lab {
    pub name: String,
    pub bin: PathBuf,
    pub version: ClaudeVersion,
    pub help: String,
    pub api: FakeMessages,
    pub config_dir: tempfile::TempDir,
    pub work_dir: tempfile::TempDir,
    pub recorder: Recorder,
    out: Option<PathBuf>,
}

impl Lab {
    /// `None` (scenario skipped) unless `CLAUDE_LAB_BIN` is set.
    pub async fn start(name: &str) -> Option<Self> {
        let bin = PathBuf::from(std::env::var_os("CLAUDE_LAB_BIN")?);
        let version_output = std::process::Command::new(&bin)
            .arg("--version")
            .output()
            .expect("claude --version");
        let version = ClaudeVersion::parse(&String::from_utf8_lossy(&version_output.stdout))
            .expect("claude version");
        let help = std::process::Command::new(&bin)
            .arg("--help")
            .output()
            .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
            .unwrap_or_default();
        let lab = Self {
            name: name.to_string(),
            bin,
            version,
            help,
            api: FakeMessages::start().await,
            config_dir: tempfile::tempdir().expect("config dir"),
            work_dir: tempfile::tempdir().expect("work dir"),
            recorder: Recorder::default(),
            out: std::env::var_os("CLAUDE_LAB_OUT").map(PathBuf::from),
        };
        eprintln!("lab {name}: claude {} at {}", lab.version, lab.bin.display());
        Some(lab)
    }

    /// The CLI's name for "ask before running tools".
    pub fn ask_mode(&self) -> &'static str {
        if self.help.contains("\"manual\"") {
            "manual"
        } else {
            "default"
        }
    }

    pub fn options(&self, session: SessionStart) -> LaunchOptions {
        let mut options = LaunchOptions::new(&self.bin, self.work_dir.path());
        options.session = session;
        options.bare = true;
        options.model = Some("claude-sonnet-4-5".into());
        options.env = vec![
            ("ANTHROPIC_BASE_URL".into(), self.api.base_url.clone().into()),
            ("ANTHROPIC_API_KEY".into(), "sk-ant-lab-dummy".into()),
            ("CLAUDE_CONFIG_DIR".into(), self.config_dir.path().into()),
            ("DISABLE_AUTOUPDATER".into(), "1".into()),
            ("DISABLE_TELEMETRY".into(), "1".into()),
            ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(), "1".into()),
            ("DISABLE_ERROR_REPORTING".into(), "1".into()),
        ];
        options
    }

    pub async fn connect(
        &self,
        options: &LaunchOptions,
        policy: Policy,
        initialize: InitializeRequest,
    ) -> (ClaudeClient, InitializeResponse) {
        self.recorder.note(
            "lab",
            json!({"launch": options.cli_arguments(), "version": self.version.to_string()}),
        );
        let config = ClientConfig {
            handler: Arc::new(LabHandler {
                recorder: self.recorder.clone(),
                policy,
            }),
            ..ClientConfig::default()
        };
        let (client, mut events) =
            ClaudeClient::spawn(options, config).expect("spawn claude");
        let recorder = self.recorder.clone();
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                recorder.push_event(event);
            }
        });
        let response = match client.initialize(&initialize).await {
            Ok(response) => response,
            Err(error) => {
                let exit = client.wait_exit(Duration::from_secs(3)).await;
                self.save();
                panic!(
                    "initialize failed: {error}; exit: {:?}; stderr: {}",
                    exit.map(|exit| exit.describe()),
                    client.stderr_tail()
                );
            }
        };
        self.recorder.note(
            "lab",
            json!({"initialize": {
                "claude_code_version": response.claude_code_version,
                "models": response.models.iter().map(|model| &model.value).collect::<Vec<_>>(),
                "commands": response.commands.len(),
                "agents": response.agents.iter().map(|agent| &agent.name).collect::<Vec<_>>(),
                "output_style": response.output_style,
            }}),
        );
        (client, response)
    }

    pub async fn send(&self, client: &ClaudeClient, message: &inline_agent_driver_claude::UserMessage) {
        self.recorder.note("out", message.to_value());
        client.send(message).await.expect("send user message");
    }

    pub fn note(&self, value: Value) {
        self.recorder.note("lab", value);
    }

    /// Writes the evidence files.
    pub fn save(&self) {
        let Some(out) = &self.out else {
            return;
        };
        let directory = out.join(self.version.to_string());
        std::fs::create_dir_all(&directory).expect("lab out dir");
        let frames: String = self
            .recorder
            .entries()
            .iter()
            .map(|entry| format!("{entry}\n"))
            .collect();
        std::fs::write(directory.join(format!("{}.jsonl", self.name)), frames).expect("frames");
        let api: Vec<Value> = self.api.served().iter().map(|served| served.summary()).collect();
        std::fs::write(
            directory.join(format!("{}.api.json", self.name)),
            serde_json::to_string_pretty(&api).unwrap(),
        )
        .expect("api log");
    }

    pub fn projects_dir(&self) -> PathBuf {
        self.config_dir.path().join("projects")
    }
}

pub fn allow_all() -> Policy {
    Arc::new(|_request: &PermissionRequest| PermissionDecision::allow())
}

pub fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

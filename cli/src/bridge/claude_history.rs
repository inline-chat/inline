//! Read-only access to Claude Code's local session-history SDK.
//!
//! This intentionally does not parse `~/.claude`, create ACP sessions, or claim
//! that an imported transcript can resume the original Claude session.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use inline_agent_driver_acp::should_scrub_acp_environment_name;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::*;

const PAGE_SIZE: usize = 6;
const SHOW_MORE_LABEL: &str = "Show More";
const MAX_HELPER_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
const HELPER_TIMEOUT: Duration = Duration::from_secs(20);
const PICKER_TTL_SECONDS: i64 = 10 * 60;
const MAX_PICKERS: usize = 32;
const MAX_CONCURRENT_IMPORTS: usize = 1;
const MAX_INLINE_TEXT_UTF16: usize = 12_000;
const MAX_INLINE_TEXT_BYTES: usize = 20_000;
const MAX_IMPORT_PREFIX_LENGTH: usize = "Claude (continued)\n\n".len();
const MAX_BUTTON_TEXT_UTF16: usize = 64;
const MAX_IMPORTED_MESSAGES: usize = 500;
const IMPORT_LEASE_SECONDS: i64 = 30 * 60;

// Run from `--eval` so the installed bridge needs no mutable helper file. The
// request, including local paths and the private Claude session ID, travels on
// stdin rather than argv and the response is never logged.
const HELPER_SOURCE: &str = r#"
import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

const readStdin = async () => {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 64 * 1024) throw new Error("request_too_large");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
};

const exactDirectory = (candidate, expected) => {
  if (candidate === undefined || candidate === null || candidate === "") return true;
  if (typeof candidate !== "string") return false;
  try { return realpathSync.native(candidate) === expected; } catch { return false; }
};

const markerTags = [
  "command-name", "command-message", "command-args",
  "local-command-stdout", "local-command-stderr",
];
const stripLocalCommandMetadata = (value) => {
  let text = value;
  for (const tag of markerTags) {
    const open = `<${tag}>`;
    const close = `</${tag}>`;
    for (;;) {
      const start = text.indexOf(open);
      if (start < 0) break;
      const end = text.indexOf(close, start + open.length);
      if (end < 0) break;
      text = text.slice(0, start) + text.slice(end + close.length);
    }
  }
  return text;
};

const textContent = (content) => {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block && block.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n");
};

const cleanText = (value) => value
  .replaceAll("\u0000", "")
  .replace(/\r\n?/g, "\n")
  .trim();

try {
  const request = await readStdin();
  const expected = realpathSync.native(request.workspace);
  const sdk = await import(pathToFileURL(request.sdkPath).href);
  if (request.operation === "list") {
    const sessions = await sdk.listSessions({
      dir: expected,
      limit: 120,
      offset: 0,
      includeWorktrees: false,
      includeProgrammatic: false,
    });
    const items = sessions
      .filter((session) => exactDirectory(session.cwd, expected))
      .map((session) => ({
        sessionId: session.sessionId,
        title: session.customTitle || session.summary || "Claude session",
        updatedAt: Number(session.lastModified) || 0,
      }))
      .filter((session) => typeof session.sessionId === "string" && session.sessionId.length > 0)
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, 120);
    process.stdout.write(JSON.stringify({ kind: "list", sessions: items }));
  } else if (request.operation === "transcript") {
    const info = await sdk.getSessionInfo(request.sessionId, { dir: expected });
    if (!info || !exactDirectory(info.cwd, expected)) throw new Error("wrong_workspace");
    const turns = [];
    let totalCharacters = 0;
    let totalJsonBytes = 128;
    let limitTruncated = false;
    let nonTextOmitted = false;
    const records = await sdk.getSessionMessages(request.sessionId, {
      dir: expected,
      limit: 2001,
      offset: 0,
      includeSystemMessages: false,
    });
    if (!Array.isArray(records)) throw new Error("invalid_messages");
    if (records.length > 2000) limitTruncated = true;
    for (const record of records.slice(0, 2000)) {
        if (record.type !== "user" && record.type !== "assistant") continue;
        if (record.parent_tool_use_id || record.parentToolUseId) continue;
        const message = record.message;
        if (!message || (message.role !== "user" && message.role !== "assistant")) continue;
        if (message.model === "<synthetic>") continue;
        if (Array.isArray(message.content) &&
            message.content.some((block) => block && block.type !== "text")) {
          nonTextOmitted = true;
        }
        let text = textContent(message.content);
        if (message.role === "user") text = stripLocalCommandMetadata(text);
        text = cleanText(text);
        if (!text) continue;
        const turn = { role: message.role, text };
        const turnJsonBytes = Buffer.byteLength(JSON.stringify(turn), "utf8") + 1;
        if (totalCharacters + text.length > 4 * 1024 * 1024 ||
            totalJsonBytes + turnJsonBytes > 7 * 1024 * 1024 ||
            turns.length >= 2000) {
          limitTruncated = true;
          break;
        }
        totalCharacters += text.length;
        totalJsonBytes += turnJsonBytes;
        turns.push(turn);
    }
    process.stdout.write(JSON.stringify({
      kind: "transcript",
      turns,
      limitTruncated,
      nonTextOmitted,
    }));
  } else {
    throw new Error("unsupported_operation");
  }
} catch {
  process.stdout.write(JSON.stringify({ kind: "error", code: "history_unavailable" }));
  process.exitCode = 1;
}
"#;

#[derive(Clone, Debug)]
pub(super) struct ClaudeHistoryReader {
    node: PathBuf,
    sdk_module: PathBuf,
}

#[derive(Clone, Debug)]
pub(super) struct ClaudeHistoryRuntime {
    reader: ClaudeHistoryReader,
    registry: Arc<Mutex<ClaudeHistoryRegistry>>,
    import_permits: Arc<Semaphore>,
    import_tasks: Arc<Mutex<Vec<tokio::task::JoinHandle<()>>>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ClaudeSessionSummary {
    // This identifier must remain local. UI callbacks carry only a request
    // token and an ordinal into a bridge-owned snapshot.
    pub session_id: String,
    pub title: String,
    pub updated_at: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ClaudeTranscriptRole {
    User,
    Assistant,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ClaudeTranscriptTurn {
    pub role: ClaudeTranscriptRole,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ClaudeTranscript {
    pub turns: Vec<ClaudeTranscriptTurn>,
    pub limit_truncated: bool,
    pub non_text_omitted: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ClaudeHistoryCommand {
    Sessions,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ClaudeSessionPage<'a> {
    pub items: &'a [ClaudeSessionSummary],
    pub start: usize,
    pub page: usize,
    pub has_back: bool,
    pub has_more: bool,
    pub show_more_label: Option<&'static str>,
}

#[derive(Debug, Default)]
struct ClaudeHistoryRegistry {
    pickers: HashMap<String, ClaudeHistoryPicker>,
}

#[derive(Clone, Debug)]
struct ClaudeHistoryPicker {
    installation_id: InstallationId,
    owner_user_id: i64,
    chat_id: i64,
    message_id: Option<i64>,
    workspace_id: WorkspaceId,
    workspace: PathBuf,
    workspace_label: String,
    sessions: Vec<ClaudeSessionSummary>,
    created_at: i64,
    expires_at: i64,
    state: ClaudeHistoryPickerState,
    transcript: Option<Arc<ClaudeTranscript>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ClaudeHistoryPickerState {
    Pending,
    Importing {
        thread_id: Option<i64>,
        session_index: usize,
    },
    Retry {
        thread_id: i64,
        session_index: usize,
    },
    Opened(i64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ClaudeHistoryThreadState {
    Importing,
    Incomplete,
}

#[derive(Clone, Debug)]
struct ClaudeHistoryImport {
    token: String,
    installation_id: InstallationId,
    chat_id: i64,
    message_id: i64,
    workspace_id: WorkspaceId,
    workspace: PathBuf,
    workspace_label: String,
    session: ClaudeSessionSummary,
    session_index: usize,
    thread_id: Option<i64>,
    transcript: Option<Arc<ClaudeTranscript>>,
    _permit: Arc<OwnedSemaphorePermit>,
}

#[derive(Clone, Debug)]
enum ClaudeHistoryClaim {
    Page(ClaudeHistoryPicker),
    Import(ClaudeHistoryImport),
    Opened(i64),
    Importing,
    Unauthorized,
    Stale,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub(super) enum ClaudeHistoryCallbackAction {
    Open { index: usize },
    Page { page: usize },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct ClaudeHistoryCallback {
    pub version: u32,
    pub token: String,
    pub action: ClaudeHistoryCallbackAction,
}

#[derive(Debug, thiserror::Error)]
pub(super) enum ClaudeHistoryError {
    #[error("the verified Claude history SDK is unavailable")]
    SdkUnavailable,
    #[error("the Claude history helper could not start")]
    HelperUnavailable,
    #[error("the Claude history helper timed out")]
    Timeout,
    #[error("the Claude history response exceeded its safety bound")]
    ResponseTooLarge,
    #[error("the Claude history response was invalid")]
    InvalidResponse,
    #[error("Claude history is unavailable")]
    HistoryUnavailable,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HelperRequest<'a> {
    operation: &'static str,
    sdk_path: &'a Path,
    workspace: &'a Path,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<&'a str>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum HelperResponse {
    List {
        sessions: Vec<HelperSession>,
    },
    Transcript {
        turns: Vec<HelperTurn>,
        #[serde(rename = "limitTruncated")]
        limit_truncated: bool,
        #[serde(rename = "nonTextOmitted")]
        non_text_omitted: bool,
    },
    Error {
        code: String,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperSession {
    session_id: String,
    title: String,
    updated_at: i64,
}

#[derive(Deserialize)]
struct HelperTurn {
    role: String,
    text: String,
}

impl ClaudeHistoryReader {
    pub(super) fn from_adapter_executable(
        adapter_executable: &Path,
    ) -> Result<Self, ClaudeHistoryError> {
        let adapter_executable = std::fs::canonicalize(adapter_executable)
            .map_err(|_| ClaudeHistoryError::SdkUnavailable)?;
        let package_root = adapter_executable
            .parent()
            .and_then(Path::parent)
            .filter(|path| {
                path.file_name()
                    .is_some_and(|name| name == "claude-agent-acp")
            })
            .filter(|path| {
                path.parent()
                    .and_then(Path::file_name)
                    .is_some_and(|name| name == "@agentclientprotocol")
            })
            .ok_or(ClaudeHistoryError::SdkUnavailable)?;
        let node_modules = package_root
            .parent()
            .and_then(Path::parent)
            .ok_or(ClaudeHistoryError::SdkUnavailable)?;
        let sdk_module =
            std::fs::canonicalize(node_modules.join("@anthropic-ai/claude-agent-sdk/sdk.mjs"))
                .map_err(|_| ClaudeHistoryError::SdkUnavailable)?;
        if !sdk_module.starts_with(node_modules) {
            return Err(ClaudeHistoryError::SdkUnavailable);
        }
        let node = resolve_executable(Path::new("node"))
            .map_err(|_| ClaudeHistoryError::HelperUnavailable)?;
        Ok(Self { node, sdk_module })
    }

    pub(super) async fn list(
        &self,
        workspace: &Path,
    ) -> Result<Vec<ClaudeSessionSummary>, ClaudeHistoryError> {
        let response = self
            .run(HelperRequest {
                operation: "list",
                sdk_path: &self.sdk_module,
                workspace,
                session_id: None,
            })
            .await?;
        let HelperResponse::List { sessions } = response else {
            return Err(ClaudeHistoryError::InvalidResponse);
        };
        let mut sessions = sessions
            .into_iter()
            .filter_map(|session| {
                let session_id = bounded_private_id(&session.session_id)?;
                let title = sanitized_history_title(&session.title, 120)
                    .unwrap_or_else(|| "Claude session".to_string());
                Some(ClaudeSessionSummary {
                    session_id,
                    title,
                    updated_at: session.updated_at.max(0),
                })
            })
            .take(120)
            .collect::<Vec<_>>();
        sessions.sort_by_key(|session| std::cmp::Reverse(session.updated_at));
        Ok(sessions)
    }

    pub(super) async fn transcript(
        &self,
        workspace: &Path,
        session_id: &str,
    ) -> Result<ClaudeTranscript, ClaudeHistoryError> {
        let session_id =
            bounded_private_id(session_id).ok_or(ClaudeHistoryError::HistoryUnavailable)?;
        let response = self
            .run(HelperRequest {
                operation: "transcript",
                sdk_path: &self.sdk_module,
                workspace,
                session_id: Some(&session_id),
            })
            .await?;
        let HelperResponse::Transcript {
            turns,
            limit_truncated,
            non_text_omitted,
        } = response
        else {
            return Err(ClaudeHistoryError::InvalidResponse);
        };
        let turns = turns
            .into_iter()
            .filter_map(|turn| {
                let role = match turn.role.as_str() {
                    "user" => ClaudeTranscriptRole::User,
                    "assistant" => ClaudeTranscriptRole::Assistant,
                    _ => return None,
                };
                let text = sanitized_multiline_text(&turn.text, 4 * 1024 * 1024)?;
                Some(ClaudeTranscriptTurn { role, text })
            })
            .take(2000)
            .collect();
        Ok(ClaudeTranscript {
            turns,
            limit_truncated,
            non_text_omitted,
        })
    }

    async fn run(&self, request: HelperRequest<'_>) -> Result<HelperResponse, ClaudeHistoryError> {
        let input =
            serde_json::to_vec(&request).map_err(|_| ClaudeHistoryError::InvalidResponse)?;
        let mut command = tokio::process::Command::new(&self.node);
        command
            .args(["--input-type=module", "--eval", HELPER_SOURCE])
            .current_dir(request.workspace)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        for (name, _) in std::env::vars_os() {
            if should_scrub_acp_environment_name(&name, "claude-history") {
                command.env_remove(name);
            }
        }
        // SDK 0.3.220 otherwise skips content before its compaction boundary
        // for JSONL files over 5 MiB. The existing timeout and output bounds
        // are the safety boundary for this read-only import instead.
        command.env("CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP", "1");
        let mut child = command
            .spawn()
            .map_err(|_| ClaudeHistoryError::HelperUnavailable)?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or(ClaudeHistoryError::HelperUnavailable)?;
        stdin
            .write_all(&input)
            .await
            .map_err(|_| ClaudeHistoryError::HelperUnavailable)?;
        stdin
            .shutdown()
            .await
            .map_err(|_| ClaudeHistoryError::HelperUnavailable)?;
        drop(stdin);
        let stdout = child
            .stdout
            .take()
            .ok_or(ClaudeHistoryError::HelperUnavailable)?;
        let (status, stdout, response_too_large) = tokio::time::timeout(HELPER_TIMEOUT, async {
            let (status, output) = tokio::join!(child.wait(), read_helper_output(stdout));
            let status = status.map_err(|_| ClaudeHistoryError::HelperUnavailable)?;
            let (output, too_large) = output?;
            Ok::<_, ClaudeHistoryError>((status, output, too_large))
        })
        .await
        .map_err(|_| ClaudeHistoryError::Timeout)??;
        if response_too_large {
            return Err(ClaudeHistoryError::ResponseTooLarge);
        }
        let response = serde_json::from_slice::<HelperResponse>(&stdout)
            .map_err(|_| ClaudeHistoryError::InvalidResponse)?;
        if !status.success() {
            return match response {
                HelperResponse::Error { code } => {
                    let _ = sanitized_text(&code, 64);
                    Err(ClaudeHistoryError::HistoryUnavailable)
                }
                _ => Err(ClaudeHistoryError::InvalidResponse),
            };
        }
        match response {
            HelperResponse::Error { code } => {
                let _ = sanitized_text(&code, 64);
                Err(ClaudeHistoryError::HistoryUnavailable)
            }
            response => Ok(response),
        }
    }
}

async fn read_helper_output<R: AsyncRead + Unpin>(
    mut output: R,
) -> Result<(Vec<u8>, bool), ClaudeHistoryError> {
    let mut retained = Vec::new();
    let mut too_large = false;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = output
            .read(&mut buffer)
            .await
            .map_err(|_| ClaudeHistoryError::HelperUnavailable)?;
        if count == 0 {
            break;
        }
        if !too_large && retained.len().saturating_add(count) <= MAX_HELPER_OUTPUT_BYTES {
            retained.extend_from_slice(&buffer[..count]);
        } else {
            too_large = true;
            retained.clear();
        }
    }
    Ok((retained, too_large))
}

impl ClaudeHistoryRuntime {
    pub(super) fn from_adapter_executable(
        adapter_executable: &Path,
    ) -> Result<Self, ClaudeHistoryError> {
        Ok(Self {
            reader: ClaudeHistoryReader::from_adapter_executable(adapter_executable)?,
            registry: Arc::new(Mutex::new(ClaudeHistoryRegistry::default())),
            import_permits: Arc::new(Semaphore::new(MAX_CONCURRENT_IMPORTS)),
            import_tasks: Arc::new(Mutex::new(Vec::new())),
        })
    }

    fn insert_picker(&self, token: String, mut picker: ClaudeHistoryPicker) -> bool {
        let mut registry = self
            .registry
            .lock()
            .expect("Claude history registry poisoned");
        registry.prune(now_seconds());
        if registry.pickers.len() >= MAX_PICKERS
            && let Some(oldest) = registry
                .pickers
                .iter()
                .filter(|(_, picker)| {
                    !matches!(
                        picker.state,
                        ClaudeHistoryPickerState::Importing { .. }
                            | ClaudeHistoryPickerState::Retry { .. }
                    )
                })
                .min_by_key(|(_, picker)| picker.created_at)
                .map(|(token, _)| token.clone())
        {
            registry.pickers.remove(&oldest);
        }
        if registry.pickers.len() >= MAX_PICKERS {
            return false;
        }
        picker.message_id = None;
        registry.pickers.insert(token, picker);
        true
    }

    fn attach_picker_message(&self, token: &str, message_id: i64) -> bool {
        let mut registry = self
            .registry
            .lock()
            .expect("Claude history registry poisoned");
        let Some(picker) = registry.pickers.get_mut(token) else {
            return false;
        };
        picker.message_id = Some(message_id);
        true
    }

    fn remove_picker(&self, token: &str) {
        self.registry
            .lock()
            .expect("Claude history registry poisoned")
            .pickers
            .remove(token);
    }

    #[allow(clippy::too_many_arguments)]
    fn claim(
        &self,
        callback: &ClaudeHistoryCallback,
        installation_id: &InstallationId,
        owner_user_id: i64,
        actor_user_id: i64,
        chat_id: i64,
        message_id: i64,
        workspace_id: Option<&WorkspaceId>,
        workspace: Option<&Path>,
        permit: Option<OwnedSemaphorePermit>,
        now: i64,
    ) -> ClaudeHistoryClaim {
        let mut registry = self
            .registry
            .lock()
            .expect("Claude history registry poisoned");
        registry.prune(now);
        let Some(picker) = registry.pickers.get_mut(&callback.token) else {
            return ClaudeHistoryClaim::Stale;
        };
        if picker.expires_at <= now {
            return ClaudeHistoryClaim::Stale;
        }
        if picker.installation_id != *installation_id
            || picker.owner_user_id != owner_user_id
            || actor_user_id != owner_user_id
        {
            return ClaudeHistoryClaim::Unauthorized;
        }
        if picker.chat_id != chat_id
            || picker.message_id != Some(message_id)
            || workspace_id != Some(&picker.workspace_id)
            || workspace != Some(picker.workspace.as_path())
        {
            return ClaudeHistoryClaim::Stale;
        }
        match picker.state {
            ClaudeHistoryPickerState::Opened(thread_id) => {
                return ClaudeHistoryClaim::Opened(thread_id);
            }
            ClaudeHistoryPickerState::Importing { .. } => {
                return ClaudeHistoryClaim::Importing;
            }
            ClaudeHistoryPickerState::Pending | ClaudeHistoryPickerState::Retry { .. } => {}
        }
        match callback.action {
            ClaudeHistoryCallbackAction::Page { page } => {
                if matches!(picker.state, ClaudeHistoryPickerState::Retry { .. }) {
                    return ClaudeHistoryClaim::Stale;
                }
                if claude_session_page(&picker.sessions, page).is_none() {
                    ClaudeHistoryClaim::Stale
                } else {
                    ClaudeHistoryClaim::Page(picker.clone())
                }
            }
            ClaudeHistoryCallbackAction::Open { index } => {
                let Some(permit) = permit else {
                    return ClaudeHistoryClaim::Importing;
                };
                let Some(session) = picker.sessions.get(index).cloned() else {
                    return ClaudeHistoryClaim::Stale;
                };
                let thread_id = match picker.state {
                    ClaudeHistoryPickerState::Retry {
                        thread_id,
                        session_index,
                    } if session_index == index => Some(thread_id),
                    ClaudeHistoryPickerState::Retry { .. } => {
                        return ClaudeHistoryClaim::Stale;
                    }
                    ClaudeHistoryPickerState::Pending => None,
                    ClaudeHistoryPickerState::Importing { .. }
                    | ClaudeHistoryPickerState::Opened(_) => {
                        unreachable!("terminal states returned above")
                    }
                };
                picker.state = ClaudeHistoryPickerState::Importing {
                    thread_id,
                    session_index: index,
                };
                ClaudeHistoryClaim::Import(ClaudeHistoryImport {
                    token: callback.token.clone(),
                    installation_id: picker.installation_id.clone(),
                    chat_id,
                    message_id,
                    workspace_id: picker.workspace_id.clone(),
                    workspace: picker.workspace.clone(),
                    workspace_label: picker.workspace_label.clone(),
                    session,
                    session_index: index,
                    thread_id,
                    transcript: picker.transcript.clone(),
                    _permit: Arc::new(permit),
                })
            }
        }
    }

    fn set_import_thread(&self, token: &str, thread_id: i64) {
        let mut registry = self
            .registry
            .lock()
            .expect("Claude history registry poisoned");
        if let Some(picker) = registry.pickers.get_mut(token)
            && let ClaudeHistoryPickerState::Importing { session_index, .. } = picker.state
        {
            picker.state = ClaudeHistoryPickerState::Importing {
                thread_id: Some(thread_id),
                session_index,
            };
        }
    }

    fn set_import_transcript(&self, token: &str, transcript: Arc<ClaudeTranscript>) {
        let mut registry = self
            .registry
            .lock()
            .expect("Claude history registry poisoned");
        if let Some(picker) = registry.pickers.get_mut(token)
            && matches!(picker.state, ClaudeHistoryPickerState::Importing { .. })
        {
            picker.transcript = Some(transcript);
        }
    }

    fn track_import(&self, task: tokio::task::JoinHandle<()>) {
        let mut tasks = self
            .import_tasks
            .lock()
            .expect("Claude history import task registry poisoned");
        tasks.retain(|task| !task.is_finished());
        tasks.push(task);
    }

    pub(super) async fn cancel_imports(&self, store: &BridgeStore) {
        let tasks = {
            let mut tasks = self
                .import_tasks
                .lock()
                .expect("Claude history import task registry poisoned");
            std::mem::take(&mut *tasks)
        };
        for task in &tasks {
            task.abort();
        }
        for task in tasks {
            if let Err(error) = task.await
                && !error.is_cancelled()
            {
                eprintln!(
                    "Claude session import task failed: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
        }

        let incomplete = {
            let mut registry = self
                .registry
                .lock()
                .expect("Claude history registry poisoned");
            let now = now_seconds();
            registry
                .pickers
                .iter_mut()
                .filter_map(|(token, picker)| {
                    let ClaudeHistoryPickerState::Importing {
                        thread_id: Some(thread_id),
                        session_index,
                    } = picker.state
                    else {
                        return None;
                    };
                    picker.expires_at = now.saturating_add(PICKER_TTL_SECONDS);
                    picker.state = ClaudeHistoryPickerState::Retry {
                        thread_id,
                        session_index,
                    };
                    Some((picker.installation_id.clone(), thread_id, token.clone()))
                })
                .collect::<Vec<_>>()
        };
        for (installation_id, thread_id, token) in incomplete {
            if let Err(error) = store.mark_history_import_incomplete(
                &installation_id,
                thread_id,
                &token,
                now_seconds(),
            ) {
                eprintln!(
                    "Claude history import guard could not be marked incomplete during shutdown: {}",
                    safe_diagnostic(&error.to_string())
                );
            }
        }
    }

    fn thread_state(&self, thread_id: i64) -> Option<ClaudeHistoryThreadState> {
        let now = now_seconds();
        self.registry
            .lock()
            .expect("Claude history registry poisoned")
            .pickers
            .values()
            .find_map(|picker| match picker.state {
                ClaudeHistoryPickerState::Importing {
                    thread_id: Some(importing_thread_id),
                    ..
                } if importing_thread_id == thread_id => Some(ClaudeHistoryThreadState::Importing),
                ClaudeHistoryPickerState::Retry {
                    thread_id: incomplete_thread_id,
                    ..
                } if incomplete_thread_id == thread_id && picker.expires_at > now => {
                    Some(ClaudeHistoryThreadState::Incomplete)
                }
                _ => None,
            })
    }

    fn fail_import(&self, token: &str) -> Option<i64> {
        let mut registry = self
            .registry
            .lock()
            .expect("Claude history registry poisoned");
        let picker = registry.pickers.get_mut(token)?;
        match picker.state {
            ClaudeHistoryPickerState::Importing {
                thread_id: Some(thread_id),
                session_index,
            } => {
                picker.expires_at = now_seconds().saturating_add(PICKER_TTL_SECONDS);
                picker.state = ClaudeHistoryPickerState::Retry {
                    thread_id,
                    session_index,
                };
                Some(thread_id)
            }
            ClaudeHistoryPickerState::Importing {
                thread_id: None, ..
            } => {
                picker.state = ClaudeHistoryPickerState::Pending;
                None
            }
            _ => None,
        }
    }

    fn mark_opened(&self, token: &str, thread_id: i64) {
        let mut registry = self
            .registry
            .lock()
            .expect("Claude history registry poisoned");
        if let Some(picker) = registry.pickers.get_mut(token) {
            picker.state = ClaudeHistoryPickerState::Opened(thread_id);
        }
    }
}

impl ClaudeHistoryRegistry {
    fn prune(&mut self, now: i64) {
        self.pickers.retain(|_, picker| {
            picker.expires_at > now
                || matches!(picker.state, ClaudeHistoryPickerState::Importing { .. })
        });
    }
}

pub(super) async fn handle_claude_history_command(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    if claude_history_command_for_provider(
        &route.provider_id,
        &record.direction.text,
        &route.bot_username,
    )
    .is_none()
    {
        return Ok(false);
    }
    let command = parse_command(&record.direction.text, &route.bot_username)
        .expect("history command was already parsed")
        .expect("history command exists");
    if !ensure_history_command_started(&route.store, record)? {
        return Ok(true);
    }
    let result = handle_claude_history_command_inner(bot, record, route, &command).await;
    match result {
        Ok(()) => {
            route.store.complete_inbound(&record.event_id)?;
            Ok(true)
        }
        Err(error) => {
            route
                .store
                .fail_inbound(&record.event_id, "Claude history command failed")?;
            Err(error)
        }
    }
}

pub(super) async fn handle_active_claude_history_command(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    if claude_history_command_for_provider(
        &route.provider_id,
        &record.direction.text,
        &route.bot_username,
    )
    .is_none()
    {
        return Ok(false);
    }
    send_history_reply(
        bot,
        record,
        "Open session history after the current Claude turn finishes.",
        "turn-active",
    )
    .await?;
    Ok(true)
}

pub(super) async fn handle_claude_history_import_thread_message(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let ClientEvent::MessageStored { message } = event else {
        return Ok(false);
    };
    if !route.allows(message.sender_id.get()) {
        return Ok(false);
    }
    if route.provider_id.as_str() != "claude" {
        return Ok(false);
    }
    let state = claude_history_thread_state(
        &route.store,
        &route.installation_id,
        route.claude_history.as_ref(),
        message.chat_id.get(),
        now_seconds(),
    )?;
    let Some(state) = state else {
        return Ok(false);
    };
    let owner = message.sender_id.get() == route.owner_user_id;
    let text = match (state, owner) {
        (ClaudeHistoryThreadState::Importing, true) => {
            "The Claude history import is still running. Wait for the end-of-transcript message before replying here. If it does not finish or the session picker is gone, run /sessions again; replies are disabled in this partial import."
        }
        (ClaudeHistoryThreadState::Incomplete, true) => {
            "This Claude history import is incomplete. Use Retry Import from the session picker within ten minutes. If the picker is gone, run /sessions again; replies are disabled in this partial import."
        }
        (ClaudeHistoryThreadState::Importing, false) => {
            "The Claude history import is still running, so replies are disabled here. Ask the bot owner to wait for completion or run /sessions again."
        }
        (ClaudeHistoryThreadState::Incomplete, false) => {
            "This Claude history import is incomplete, so replies are disabled here. Ask the bot owner to retry it or run /sessions again."
        }
    };
    let event_id = format!(
        "claude-import-guard-{}-{}",
        message.chat_id, message.message_id
    );
    send_text_reply(
        bot,
        message.chat_id.get(),
        message.message_id.get(),
        text,
        &event_id,
        BridgeNotificationClass::RoutineStatus,
    )
    .await?;
    Ok(true)
}

fn claude_history_thread_state(
    store: &BridgeStore,
    installation_id: &InstallationId,
    history: Option<&ClaudeHistoryRuntime>,
    thread_id: i64,
    now: i64,
) -> Result<Option<ClaudeHistoryThreadState>, StoreError> {
    Ok(store
        .history_import_state(installation_id, thread_id, now)?
        .map(|state| match state {
            HistoryImportState::Importing => ClaudeHistoryThreadState::Importing,
            HistoryImportState::Incomplete => ClaudeHistoryThreadState::Incomplete,
        })
        .or_else(|| history.and_then(|history| history.thread_state(thread_id))))
}

async fn handle_claude_history_command_inner(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
    command: &CommandInvocation,
) -> Result<(), Box<dyn std::error::Error>> {
    if !command.arguments.is_empty() {
        return send_history_reply(
            bot,
            record,
            &format!("/{} doesn’t take arguments.", command.name),
            "usage",
        )
        .await;
    }
    if record.sender_user_id != route.owner_user_id {
        return send_history_reply(
            bot,
            record,
            "Only the bot owner can import local Claude sessions.",
            "owner-only",
        )
        .await;
    }
    if record.binding.chat_id != route.owner_dm_chat_id {
        return send_history_reply(
            bot,
            record,
            "Open this bot’s private DM and use /sessions there. Local Claude history can’t be listed in shared chats or reply threads.",
            "private-dm-only",
        )
        .await;
    }
    if route.provider_id.as_str() != "claude" {
        return send_history_reply(
            bot,
            record,
            "Local session history is currently available only for Claude Code bots.",
            "claude-only",
        )
        .await;
    }
    let Some(history) = route.claude_history.as_ref() else {
        return send_history_reply(
            bot,
            record,
            "Claude session history is unavailable. Run setup again to repair the pinned Claude adapter.",
            "unavailable",
        )
        .await;
    };
    let workspace = match verified_history_workspace(route, record.binding.chat_id) {
        Ok(Some(workspace)) => workspace,
        Ok(None) | Err(StoreError::WorkspaceUnavailable { .. }) => {
            return send_history_reply(
                bot,
                record,
                "The selected project is unavailable. Choose a project with /folder and try again.",
                "workspace-unavailable",
            )
            .await;
        }
        Err(error) => return Err(error.into()),
    };
    let sessions = match history.reader.list(&workspace.path).await {
        Ok(sessions) => sessions,
        Err(_) => {
            return send_history_reply(
                bot,
                record,
                "I couldn’t read local Claude session history for this project.",
                "read-failed",
            )
            .await;
        }
    };
    if sessions.is_empty() {
        return send_history_reply(
            bot,
            record,
            "No local Claude Code sessions were found for this project.",
            "empty",
        )
        .await;
    }
    let token = generate_control_token();
    let now = now_seconds();
    let workspace_label =
        sanitized_text(&workspace.display_name, 80).unwrap_or_else(|| "this project".to_string());
    let picker = ClaudeHistoryPicker {
        installation_id: route.installation_id.clone(),
        owner_user_id: route.owner_user_id,
        chat_id: record.binding.chat_id,
        message_id: None,
        workspace_id: workspace.workspace_id,
        workspace: workspace.path,
        workspace_label,
        sessions,
        created_at: now,
        expires_at: now.saturating_add(PICKER_TTL_SECONDS),
        state: ClaudeHistoryPickerState::Pending,
        transcript: None,
    };
    let (text, actions) = picker_card(&token, &picker, 0)?;
    if !history.insert_picker(token.clone(), picker) {
        return send_history_reply(
            bot,
            record,
            "Too many Claude session pickers are active. Finish or let an older import expire, then try again.",
            "picker-capacity",
        )
        .await;
    }
    let reconcile_text = text.clone();
    let reconcile_actions = actions.clone();
    let mut message = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(record.binding.chat_id),
        },
        text,
    );
    message.reply_to_message_id = Some(InlineId::new(record.message_id));
    message.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("{}-claude-history", record.event_id),
    )?);
    message.random_id = Some(interaction_random_id("claude-history", &token));
    message.parse_markdown = true;
    message.notification_mode = SendNotificationMode::Silent;
    let mutation = match send_interactive_text_with_retry(
        bot,
        SendInteractiveTextRequest { message, actions },
    )
    .await
    {
        Ok(mutation) => mutation,
        Err(error) => {
            history.remove_picker(&token);
            return Err(error);
        }
    };
    let message_id = mutation.message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "Claude history picker has no message identity",
        )
    })?;
    if !history.attach_picker_message(&token, message_id.get()) {
        return Err(io::Error::other("Claude history picker expired before publication").into());
    }
    // A redelivered inbound command can resolve to the original SDK
    // transaction even though this process generated a fresh callback token.
    // Reconcile the visible card before completing the inbound event so its
    // callbacks always point at the current local registry.
    if let Err(error) = edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(record.binding.chat_id),
                message_id,
                text: reconcile_text,
                external_id: None,
                parse_markdown: true,
            },
            actions: reconcile_actions,
        },
    )
    .await
    {
        history.remove_picker(&token);
        return Err(error);
    }
    Ok(())
}

pub(super) async fn handle_claude_history_action(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    if route.provider_id.as_str() != "claude" {
        return Ok(false);
    }
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id,
        action_id,
        data,
        ..
    } = event
    else {
        return Ok(false);
    };
    let Some(callback) = parse_claude_history_callback(action_id, data) else {
        return Ok(false);
    };
    let Some(history) = route.claude_history.as_ref() else {
        answer_history_action(
            bot,
            *interaction_id,
            "This session picker is no longer active.",
        )
        .await?;
        return Ok(true);
    };
    let current_workspace = match verified_history_workspace(route, chat_id.get()) {
        Ok(workspace) => workspace,
        Err(StoreError::WorkspaceUnavailable { .. }) => None,
        Err(error) => return Err(error.into()),
    };
    let permit = match callback.action {
        ClaudeHistoryCallbackAction::Open { .. } => {
            match history.import_permits.clone().try_acquire_owned() {
                Ok(permit) => Some(permit),
                Err(_) => {
                    answer_history_action(
                        bot,
                        *interaction_id,
                        "Another Claude history import is still running.",
                    )
                    .await?;
                    return Ok(true);
                }
            }
        }
        ClaudeHistoryCallbackAction::Page { .. } => None,
    };
    let claim = history.claim(
        &callback,
        &route.installation_id,
        route.owner_user_id,
        actor_user_id.get(),
        chat_id.get(),
        message_id.get(),
        current_workspace
            .as_ref()
            .map(|workspace| &workspace.workspace_id),
        current_workspace
            .as_ref()
            .map(|workspace| workspace.path.as_path()),
        permit,
        now_seconds(),
    );
    match claim {
        ClaudeHistoryClaim::Page(picker) => {
            let ClaudeHistoryCallbackAction::Page { page } = callback.action else {
                unreachable!("page claim preserves callback action")
            };
            let (text, actions) = picker_card(&callback.token, &picker, page)?;
            answer_history_action(bot, *interaction_id, "Updated").await?;
            edit_interactive_message_with_retry(
                bot,
                EditInteractiveMessageRequest {
                    message: EditMessageRequest {
                        chat_id: *chat_id,
                        message_id: *message_id,
                        text,
                        external_id: None,
                        parse_markdown: true,
                    },
                    actions,
                },
            )
            .await?;
        }
        ClaudeHistoryClaim::Import(import) => {
            if let Err(error) = answer_history_action(bot, *interaction_id, "Importing…").await {
                history.fail_import(&import.token);
                return Err(error);
            }
            let bot = bot.clone();
            let history = history.clone();
            let task_history = history.clone();
            let store = route.store.clone();
            let task = tokio::spawn(async move {
                let detail = match import_claude_history(&bot, &task_history, &store, &import).await
                {
                    Ok(()) => return,
                    Err(error) => safe_diagnostic(&error.to_string()),
                };
                let retry_thread_id = task_history.fail_import(&import.token);
                if let Some(thread_id) = retry_thread_id {
                    if let Err(error) = store.mark_history_import_incomplete(
                        &import.installation_id,
                        thread_id,
                        &import.token,
                        now_seconds(),
                    ) {
                        eprintln!(
                            "Claude history import guard could not be marked incomplete: {}",
                            safe_diagnostic(&error.to_string())
                        );
                    }
                    let _ = send_import_text(
                        &bot,
                        thread_id,
                        "Import stopped before the transcript was complete. Retry Import is available from the session picker for ten minutes. If the picker is gone, run /sessions again; replies are disabled in this partial import.",
                        &import.token,
                        "failure",
                    )
                    .await;
                }
                let _ = edit_history_failure(&bot, &import, retry_thread_id).await;
                eprintln!("Claude session import failed: {detail}");
            });
            history.track_import(task);
        }
        ClaudeHistoryClaim::Opened(thread_id) => {
            answer_history_action(bot, *interaction_id, "Already imported").await?;
            edit_history_opened(bot, chat_id.get(), message_id.get(), thread_id, false).await?;
        }
        ClaudeHistoryClaim::Importing => {
            answer_history_action(bot, *interaction_id, "Import already in progress").await?;
        }
        ClaudeHistoryClaim::Unauthorized => {
            answer_history_action(
                bot,
                *interaction_id,
                "Only the bot owner can import this session.",
            )
            .await?;
        }
        ClaudeHistoryClaim::Stale => {
            answer_history_action(
                bot,
                *interaction_id,
                "This session picker is no longer active.",
            )
            .await?;
        }
    }
    Ok(true)
}

pub(super) async fn handle_active_claude_history_action(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    if route.provider_id.as_str() != "claude" {
        return Ok(false);
    }
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        action_id,
        data,
        ..
    } = event
    else {
        return Ok(false);
    };
    if parse_claude_history_callback(action_id, data).is_none() {
        return Ok(false);
    }
    answer_history_action(
        bot,
        *interaction_id,
        "Open session history after the current Claude turn finishes.",
    )
    .await?;
    Ok(true)
}

async fn import_claude_history(
    bot: &InlineClient,
    history: &ClaudeHistoryRuntime,
    store: &BridgeStore,
    import: &ClaudeHistoryImport,
) -> Result<(), Box<dyn std::error::Error>> {
    let transcript = match import.transcript.as_ref() {
        Some(transcript) => transcript.clone(),
        None => {
            let transcript = Arc::new(
                history
                    .reader
                    .transcript(&import.workspace, &import.session.session_id)
                    .await?,
            );
            history.set_import_transcript(&import.token, transcript.clone());
            transcript
        }
    };
    let thread_id = match import.thread_id {
        Some(thread_id) => thread_id,
        None => {
            let title = format!("Claude · {}", truncate(&import.session.title, 90));
            // Anchored reply-thread creation is server-idempotent for the
            // parent chat/message pair, so a retry resolves the same thread.
            let thread_id = bot
                .create_reply_thread(CreateReplyThreadRequest {
                    parent_chat_id: InlineId::new(import.chat_id),
                    parent_message_id: Some(InlineId::new(import.message_id)),
                    title: Some(title),
                    description: Some(
                        "Read-only import from local Claude Code history".to_string(),
                    ),
                    emoji: None,
                    participants: Vec::new(),
                })
                .await?
                .chat_id
                .get();
            history.set_import_thread(&import.token, thread_id);
            thread_id
        }
    };
    bind_import_thread(store, import, thread_id)?;
    send_import_text(
        bot,
        thread_id,
        &format!(
            "Imported the current Claude Code conversation branch to Inline — read-only\n\nProject: {}\nLast active: {}\n\nEvery entry below is posted by this bot and labelled You or Claude. Tool and attachment blocks are omitted, and sensitive-looking credentials and local paths are redacted. Replies here start a fresh Claude run; they do not resume or modify the original local session.",
            import.workspace_label,
            history_date(import.session.updated_at),
        ),
        &import.token,
        "banner",
    )
    .await?;
    let mut published = 0_usize;
    let mut publication_truncated = transcript.limit_truncated;
    'turns: for (turn_index, turn) in transcript.turns.iter().enumerate() {
        let label = match turn.role {
            ClaudeTranscriptRole::User => "You",
            ClaudeTranscriptRole::Assistant => "Claude",
        };
        for (chunk_index, chunk) in text_chunks(
            &turn.text,
            MAX_INLINE_TEXT_UTF16.saturating_sub(MAX_IMPORT_PREFIX_LENGTH),
            MAX_INLINE_TEXT_BYTES.saturating_sub(MAX_IMPORT_PREFIX_LENGTH),
        )
        .into_iter()
        .enumerate()
        {
            if published >= MAX_IMPORTED_MESSAGES {
                publication_truncated = true;
                break 'turns;
            }
            let continued = if chunk_index > 0 { " (continued)" } else { "" };
            send_import_text(
                bot,
                thread_id,
                &format!("{label}{continued}\n\n{chunk}"),
                &import.token,
                &format!("turn-{turn_index}-{chunk_index}"),
            )
            .await?;
            published += 1;
        }
    }
    let footer = if publication_truncated && transcript.non_text_omitted {
        "End of imported conversation branch. Some messages exceeded the safe import limit, and tool or attachment blocks were omitted. Sensitive-looking credentials and local paths were redacted."
    } else if publication_truncated {
        "End of imported conversation branch. Some messages were omitted because this local session exceeded the safe import limit. Sensitive-looking credentials and local paths were redacted."
    } else if transcript.non_text_omitted {
        "End of imported conversation branch. Tool or attachment blocks were omitted, and sensitive-looking credentials and local paths were redacted."
    } else {
        "End of imported conversation branch. Sensitive-looking credentials and local paths were redacted."
    };
    send_import_text(bot, thread_id, footer, &import.token, "footer").await?;
    if !store.complete_history_import(
        &import.installation_id,
        thread_id,
        &import.token,
        now_seconds(),
    )? {
        return Err(io::Error::other("Claude history import guard was not completed").into());
    }
    history.mark_opened(&import.token, thread_id);
    if let Err(error) = edit_history_opened(
        bot,
        import.chat_id,
        import.message_id,
        thread_id,
        publication_truncated,
    )
    .await
    {
        // The footer is the committed completion marker. A failed cosmetic
        // picker edit must never rewrite a complete import as Retry.
        eprintln!(
            "Claude session import completed but the picker could not be updated: {}",
            safe_diagnostic(&error.to_string())
        );
    }
    Ok(())
}

fn bind_import_thread(
    store: &BridgeStore,
    import: &ClaudeHistoryImport,
    thread_id: i64,
) -> Result<(), StoreError> {
    let source = BindingKey {
        installation_id: import.installation_id.clone(),
        chat_id: import.chat_id,
        workspace_id: import.workspace_id.clone(),
    };
    let target = BindingKey {
        installation_id: import.installation_id.clone(),
        chat_id: thread_id,
        workspace_id: import.workspace_id.clone(),
    };
    let now = now_seconds();
    let _ = store.chat_settings(&source, now)?;
    store.begin_history_import_thread(
        &source,
        target.chat_id,
        &import.token,
        now,
        now.saturating_add(IMPORT_LEASE_SECONDS),
    )?;
    Ok(())
}

async fn send_import_text(
    bot: &InlineClient,
    chat_id: i64,
    text: &str,
    token: &str,
    suffix: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(chat_id),
        },
        text,
    );
    request.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("claude-import-{token}-{suffix}"),
    )?);
    request.random_id = Some(interaction_random_id(
        "claude-import",
        &format!("{token}-{suffix}"),
    ));
    request.parse_markdown = false;
    request.notification_mode = SendNotificationMode::Silent;
    send_text_with_retry(bot, request).await?;
    Ok(())
}

async fn edit_history_opened(
    bot: &InlineClient,
    chat_id: i64,
    message_id: i64,
    thread_id: i64,
    truncated: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let note = if truncated {
        " The safe import limit was reached."
    } else {
        ""
    };
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(chat_id),
                message_id: InlineId::new(message_id),
                text: format!(
                    "Imported a read-only copy into [Open thread](inline://thread?id={thread_id}).{note} Replies there start a fresh run and do not resume the original session."
                ),
                external_id: None,
                parse_markdown: true,
            },
            actions: MessageActions::default(),
        },
    )
    .await
}

async fn edit_history_failure(
    bot: &InlineClient,
    import: &ClaudeHistoryImport,
    thread_id: Option<i64>,
) -> Result<(), Box<dyn std::error::Error>> {
    let (text, link) = match thread_id {
        Some(thread_id) => (
            "The import stopped before the transcript was complete. Retry continues publishing into the same thread; it will not create another one.",
            format!(" [Open partial thread](inline://thread?id={thread_id})."),
        ),
        None => (
            "I couldn’t read or start importing that local Claude transcript. You can try again while this picker remains active.",
            String::new(),
        ),
    };
    let retry = MessageActionButton {
        action_id: "bridge_claude_history_retry".to_string(),
        text: "Retry Import".to_string(),
        kind: MessageActionKind::Callback {
            data: claude_history_callback_data(
                &import.token,
                ClaudeHistoryCallbackAction::Open {
                    index: import.session_index,
                },
            )?,
        },
    };
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(import.chat_id),
                message_id: InlineId::new(import.message_id),
                text: format!("{text}{link}"),
                external_id: None,
                parse_markdown: thread_id.is_some(),
            },
            actions: MessageActions {
                rows: vec![MessageActionRow {
                    actions: vec![retry],
                }],
            },
        },
    )
    .await
}

async fn answer_history_action(
    bot: &InlineClient,
    interaction_id: InlineId,
    toast: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
        interaction_id,
        toast: Some(toast.to_string()),
    })
    .await?;
    Ok(())
}

async fn send_history_reply(
    bot: &InlineClient,
    record: &InboundRecord,
    text: &str,
    suffix: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(record.binding.chat_id),
        },
        text,
    );
    request.reply_to_message_id = Some(InlineId::new(record.message_id));
    request.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("{}-claude-history-{suffix}", record.event_id),
    )?);
    request.notification_mode = SendNotificationMode::Silent;
    send_text_with_retry(bot, request).await?;
    Ok(())
}

fn picker_card(
    token: &str,
    picker: &ClaudeHistoryPicker,
    page_index: usize,
) -> Result<(String, MessageActions), Box<dyn std::error::Error>> {
    let page = claude_session_page(&picker.sessions, page_index)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid history page"))?;
    let page_count = picker.sessions.len().div_ceil(PAGE_SIZE);
    let text = format!(
        "Recent Claude Code sessions for **{}** — page {} of {}. Opening one uploads the visible You/Claude messages from its current conversation branch into a private Inline reply thread. Tool and attachment blocks are omitted, and sensitive-looking local details are redacted. It does not resume the original session.",
        markdown_escape(&picker.workspace_label),
        page.page + 1,
        page_count,
    );
    let mut rows = page
        .items
        .iter()
        .enumerate()
        .map(|(offset, session)| {
            let index = page.start + offset;
            Ok(MessageActionRow {
                actions: vec![MessageActionButton {
                    action_id: format!("bridge_claude_history_open_{index}"),
                    text: picker_button_text(session),
                    kind: MessageActionKind::Callback {
                        data: claude_history_callback_data(
                            token,
                            ClaudeHistoryCallbackAction::Open { index },
                        )?,
                    },
                }],
            })
        })
        .collect::<Result<Vec<_>, serde_json::Error>>()?;
    let mut navigation = Vec::new();
    if page.has_back {
        navigation.push(MessageActionButton {
            action_id: "bridge_claude_history_back".to_string(),
            text: "Back".to_string(),
            kind: MessageActionKind::Callback {
                data: claude_history_callback_data(
                    token,
                    ClaudeHistoryCallbackAction::Page {
                        page: page.page - 1,
                    },
                )?,
            },
        });
    }
    if page.has_more {
        navigation.push(MessageActionButton {
            action_id: "bridge_claude_history_more".to_string(),
            text: page.show_more_label.unwrap_or(SHOW_MORE_LABEL).to_string(),
            kind: MessageActionKind::Callback {
                data: claude_history_callback_data(
                    token,
                    ClaudeHistoryCallbackAction::Page {
                        page: page.page + 1,
                    },
                )?,
            },
        });
    }
    if !navigation.is_empty() {
        rows.push(MessageActionRow {
            actions: navigation,
        });
    }
    Ok((text, MessageActions { rows }))
}

fn picker_button_text(session: &ClaudeSessionSummary) -> String {
    let suffix = format!(" · {}", history_date(session.updated_at));
    let title_limit = MAX_BUTTON_TEXT_UTF16.saturating_sub(suffix.encode_utf16().count());
    format!("{}{}", truncate_utf16(&session.title, title_limit), suffix)
}

fn history_date(timestamp: i64) -> String {
    let date = if timestamp >= 100_000_000_000 {
        DateTime::<Utc>::from_timestamp_millis(timestamp)
    } else {
        DateTime::<Utc>::from_timestamp(timestamp, 0)
    };
    date.map(|date| date.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "date unknown".to_string())
}

fn markdown_escape(value: &str) -> String {
    value
        .chars()
        .flat_map(|character| {
            if matches!(character, '\\' | '*' | '_' | '[' | ']' | '(' | ')' | '`') {
                vec!['\\', character]
            } else {
                vec![character]
            }
        })
        .collect()
}

fn text_chunks(text: &str, maximum_utf16: usize, maximum_bytes: usize) -> Vec<String> {
    if text.is_empty() || maximum_utf16 == 0 || maximum_bytes == 0 {
        return Vec::new();
    }
    let mut chunks = Vec::new();
    let mut current = String::new();
    let mut current_utf16 = 0_usize;
    let mut current_bytes = 0_usize;
    for character in text.chars() {
        let character_utf16 = character.len_utf16();
        let character_bytes = character.len_utf8();
        if !current.is_empty()
            && (current_utf16.saturating_add(character_utf16) > maximum_utf16
                || current_bytes.saturating_add(character_bytes) > maximum_bytes)
        {
            chunks.push(std::mem::take(&mut current));
            current_utf16 = 0;
            current_bytes = 0;
        }
        current.push(character);
        current_utf16 = current_utf16.saturating_add(character_utf16);
        current_bytes = current_bytes.saturating_add(character_bytes);
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    chunks
}

fn ensure_history_command_started(
    store: &BridgeStore,
    record: &InboundRecord,
) -> Result<bool, Box<dyn std::error::Error>> {
    match store.get_inbound(&record.event_id)? {
        Some(existing) if existing.state == InboundState::Started => Ok(true),
        Some(existing) if existing.state == InboundState::Accepted => {
            Ok(store.start_inbound(&record.event_id, now_seconds())?)
        }
        Some(_) => Ok(false),
        None => {
            if !store.accept_inbound(record)? {
                return Ok(false);
            }
            Ok(store.start_inbound(&record.event_id, now_seconds())?)
        }
    }
}

pub(super) fn claude_history_command(
    text: &str,
    bot_username: &str,
) -> Option<ClaudeHistoryCommand> {
    let command: CommandInvocation = parse_command(text, bot_username).ok()??;
    if command.explicit_target && !command.targets_this_bot {
        return None;
    }
    matches!(command.name.as_str(), "sessions" | "open").then_some(ClaudeHistoryCommand::Sessions)
}

fn claude_history_command_for_provider(
    provider_id: &ProviderId,
    text: &str,
    bot_username: &str,
) -> Option<ClaudeHistoryCommand> {
    (provider_id.as_str() == "claude")
        .then(|| claude_history_command(text, bot_username))
        .flatten()
}

pub(super) fn claude_session_page(
    sessions: &[ClaudeSessionSummary],
    page: usize,
) -> Option<ClaudeSessionPage<'_>> {
    let start = page.checked_mul(PAGE_SIZE)?;
    if start >= sessions.len() && !(page == 0 && sessions.is_empty()) {
        return None;
    }
    let end = start.saturating_add(PAGE_SIZE).min(sessions.len());
    Some(ClaudeSessionPage {
        items: &sessions[start..end],
        start,
        page,
        has_back: page > 0,
        has_more: end < sessions.len(),
        show_more_label: (end < sessions.len()).then_some(SHOW_MORE_LABEL),
    })
}

pub(super) fn claude_history_callback_data(
    token: &str,
    action: ClaudeHistoryCallbackAction,
) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(&ClaudeHistoryCallback {
        version: 1,
        token: token.to_string(),
        action,
    })
}

fn parse_claude_history_callback(action_id: &str, data: &[u8]) -> Option<ClaudeHistoryCallback> {
    if !action_id.starts_with("bridge_claude_history_") {
        return None;
    }
    serde_json::from_slice::<ClaudeHistoryCallback>(data)
        .ok()
        .filter(|callback| callback.version == 1)
}

fn verified_history_workspace(
    route: &InboundRoute,
    chat_id: i64,
) -> Result<Option<WorkspaceRecord>, StoreError> {
    let Some(workspace) = route
        .store
        .bound_chat_workspace(&route.installation_id, chat_id)?
    else {
        return Ok(None);
    };
    route
        .store
        .verified_workspace(
            &route.installation_id,
            &workspace.workspace_id,
            now_seconds(),
        )
        .map(Some)
}

fn bounded_private_id(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control))
        .then(|| value.to_string())
}

fn sanitized_text(value: &str, maximum: usize) -> Option<String> {
    let value = value
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let value = value.chars().take(maximum).collect::<String>();
    (!value.is_empty()).then_some(value)
}

fn sanitized_history_title(value: &str, maximum: usize) -> Option<String> {
    let value = sanitize_visible_transcript(value)?;
    sanitized_text(&value, maximum)
}

fn sanitized_multiline_text(value: &str, maximum: usize) -> Option<String> {
    let value = sanitize_visible_transcript(value)?;
    let value = value.chars().take(maximum).collect::<String>();
    let value = value.trim().to_string();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn fake_reader() -> (tempfile::TempDir, ClaudeHistoryReader, PathBuf) {
        let root = tempfile::tempdir().expect("temp root");
        let package = root
            .path()
            .join("node_modules/@agentclientprotocol/claude-agent-acp");
        let adapter = package.join("dist/index.js");
        fs::create_dir_all(adapter.parent().expect("adapter parent")).expect("adapter dirs");
        fs::write(&adapter, "// fixture").expect("adapter fixture");
        let sdk = root
            .path()
            .join("node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs");
        fs::create_dir_all(sdk.parent().expect("sdk parent")).expect("sdk dirs");
        fs::write(
            &sdk,
            r#"
export async function listSessions(options) {
  return [
    { sessionId: "older", summary: " Older\n title ", lastModified: 10, cwd: options.dir },
    { sessionId: "legacy", summary: "Legacy session", lastModified: 15 },
    { sessionId: "newer", customTitle: "Fix /Users/alice/private TOKEN=hidden", lastModified: 20, cwd: options.dir },
    { sessionId: "wrong", summary: "Wrong folder", lastModified: 30, cwd: options.dir + "-other" },
    ...(options.includeProgrammatic === false ? [] : [
      { sessionId: "programmatic", summary: "Headless", lastModified: 40, cwd: options.dir },
    ]),
  ];
}
export async function getSessionInfo(sessionId) {
  return { sessionId, cwd: process.cwd() };
}
export async function getSessionMessages(_sessionId, options) {
  if (process.env.CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP !== "1") {
    throw new Error("precompact skip was not disabled");
  }
  if (_sessionId === "escaped") {
    return [{
      type: "assistant",
      message: { role: "assistant", content: "\"".repeat(3_800_000) },
    }];
  }
  if (_sessionId === "overflow") {
    const remaining = Math.max(0, 2001 - options.offset);
    return Array.from({ length: Math.min(options.limit, remaining) }, () => ({
      type: "assistant",
      message: { role: "assistant", content: "bounded turn" },
    }));
  }
  if (options.offset > 0) return [];
  return [
    { type: "user", message: { role: "user", content: [
      { type: "text", text: "<command-name>/model</command-name> hello\nAuthorization: Bearer historical-secret\n/Users/alice/private\nhttps://example.com/file?signature=hidden" },
      { type: "image", source: {} },
    ] } },
    { type: "assistant", message: { role: "assistant", content: [
      { type: "thinking", thinking: "private" },
      { type: "text", text: "world" },
      { type: "tool_use", name: "Bash" },
    ] } },
    { type: "system", message: { role: "system", content: "hidden" } },
  ];
}
"#,
        )
        .expect("sdk fixture");
        let reader = ClaudeHistoryReader::from_adapter_executable(&adapter).expect("reader");
        let workspace = root.path().join("workspace");
        fs::create_dir(&workspace).expect("workspace");
        (root, reader, workspace)
    }

    #[tokio::test]
    async fn sdk_reader_filters_exact_workspace_sorts_and_sanitizes() {
        let (_root, reader, workspace) = fake_reader();
        let sessions = reader.list(&workspace).await.expect("session list");
        assert_eq!(
            sessions,
            vec![
                ClaudeSessionSummary {
                    session_id: "newer".to_string(),
                    title: "Fix [local-path] TOKEN= [redacted]".to_string(),
                    updated_at: 20,
                },
                ClaudeSessionSummary {
                    session_id: "legacy".to_string(),
                    title: "Legacy session".to_string(),
                    updated_at: 15,
                },
                ClaudeSessionSummary {
                    session_id: "older".to_string(),
                    title: "Older title".to_string(),
                    updated_at: 10,
                },
            ]
        );
    }

    #[tokio::test]
    async fn helper_output_is_bounded_while_streaming() {
        let output = tokio::io::repeat(1).take((MAX_HELPER_OUTPUT_BYTES + 1) as u64);
        let (retained, too_large) = read_helper_output(output).await.expect("helper output");
        assert!(too_large);
        assert!(retained.is_empty());
    }

    #[tokio::test]
    async fn transcript_keeps_only_visible_top_level_user_and_assistant_text() {
        let (_root, reader, workspace) = fake_reader();
        let transcript = reader
            .transcript(&workspace, "newer")
            .await
            .expect("transcript");
        assert_eq!(
            transcript.turns,
            vec![
                ClaudeTranscriptTurn {
                    role: ClaudeTranscriptRole::User,
                    text: "hello\nAuthorization: [redacted]\n[local-path]\nhttps://example.com/file?[redacted]".to_string(),
                },
                ClaudeTranscriptTurn {
                    role: ClaudeTranscriptRole::Assistant,
                    text: "world".to_string(),
                },
            ]
        );
        assert!(!transcript.limit_truncated);
        assert!(transcript.non_text_omitted);
        let imported = transcript
            .turns
            .iter()
            .map(|turn| turn.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        for secret in ["historical-secret", "/Users/alice", "signature=hidden"] {
            assert!(!imported.contains(secret));
        }
    }

    #[tokio::test]
    async fn transcript_marks_an_exact_two_thousand_record_page_limit_as_truncated() {
        let (_root, reader, workspace) = fake_reader();
        let transcript = reader
            .transcript(&workspace, "overflow")
            .await
            .expect("transcript");
        assert_eq!(transcript.turns.len(), 2000);
        assert!(transcript.limit_truncated);
        assert!(!transcript.non_text_omitted);
    }

    #[tokio::test]
    async fn transcript_json_budget_accounts_for_escaping_before_stdout() {
        let (_root, reader, workspace) = fake_reader();
        let transcript = reader
            .transcript(&workspace, "escaped")
            .await
            .expect("bounded transcript");
        assert!(transcript.turns.is_empty());
        assert!(transcript.limit_truncated);
    }

    #[test]
    fn imported_thread_binds_the_selected_workspace_and_inherits_parent_settings() {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("claude-test").expect("installation");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: ProviderId::new("claude").expect("provider"),
                display_name: "Claude".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        let workspace = tempfile::tempdir().expect("workspace");
        let workspace_id = WorkspaceId::new("workspace-test").expect("workspace id");
        store
            .select_workspace(&installation_id, &workspace_id, workspace.path(), 1)
            .expect("select workspace");
        store
            .bind_chat_workspace(&installation_id, 9, &workspace_id, 1)
            .expect("bind parent");
        let source = BindingKey {
            installation_id: installation_id.clone(),
            chat_id: 9,
            workspace_id: workspace_id.clone(),
        };
        let mut settings = store.chat_settings(&source, 1).expect("parent settings");
        settings.permissions = Some("default".to_string());
        settings.verbose = true;
        store
            .update_chat_settings(settings.revision, &settings, 2)
            .expect("update settings");
        let import = ClaudeHistoryImport {
            token: "opaque".to_string(),
            installation_id: installation_id.clone(),
            chat_id: 9,
            message_id: 11,
            workspace_id: workspace_id.clone(),
            workspace: workspace.path().to_path_buf(),
            workspace_label: "workspace".to_string(),
            session: ClaudeSessionSummary {
                session_id: "private-session".to_string(),
                title: "Session".to_string(),
                updated_at: 1,
            },
            session_index: 0,
            thread_id: None,
            transcript: None,
            _permit: Arc::new(
                Arc::new(Semaphore::new(1))
                    .try_acquire_owned()
                    .expect("import permit"),
            ),
        };

        bind_import_thread(&store, &import, 42).expect("bind imported thread");

        let bound = store
            .bound_chat_workspace(&installation_id, 42)
            .expect("child binding")
            .expect("bound child");
        assert_eq!(bound.workspace_id, workspace_id);
        let child = store
            .chat_settings(
                &BindingKey {
                    installation_id,
                    chat_id: 42,
                    workspace_id: bound.workspace_id,
                },
                3,
            )
            .expect("child settings");
        assert_eq!(child.permissions.as_deref(), Some("default"));
        assert!(child.verbose);
        assert_eq!(
            store
                .history_import_state(&child.binding.installation_id, 42, now_seconds())
                .expect("durable import guard"),
            Some(HistoryImportState::Importing)
        );
    }

    #[test]
    fn recreated_bridge_still_blocks_a_partial_import_thread() {
        let root = tempfile::tempdir().expect("root");
        let database = root.path().join("bridge.sqlite");
        let workspace = root.path().join("workspace");
        fs::create_dir(&workspace).expect("workspace");
        let installation_id = InstallationId::new("claude-test").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-test").expect("workspace id");
        {
            let store = BridgeStore::open(&database).expect("store");
            store
                .put_installation(&InstallationRecord {
                    installation_id: installation_id.clone(),
                    provider_id: ProviderId::new("claude").expect("provider"),
                    display_name: "Claude".to_string(),
                    created_at: 1,
                    updated_at: 1,
                })
                .expect("installation");
            store
                .select_workspace(&installation_id, &workspace_id, &workspace, 1)
                .expect("workspace");
            let source = BindingKey {
                installation_id: installation_id.clone(),
                chat_id: 9,
                workspace_id: workspace_id.clone(),
            };
            store.chat_settings(&source, 1).expect("source settings");
            store
                .begin_history_import_thread(&source, 42, "opaque", 10, 20)
                .expect("begin import");
        }

        let recreated = BridgeStore::open(&database).expect("recreated store");
        assert_eq!(
            claude_history_thread_state(&recreated, &installation_id, None, 42, 11)
                .expect("active guard"),
            Some(ClaudeHistoryThreadState::Importing)
        );
        assert_eq!(
            claude_history_thread_state(&recreated, &installation_id, None, 42, 20)
                .expect("abandoned guard"),
            Some(ClaudeHistoryThreadState::Incomplete)
        );
    }

    #[tokio::test]
    async fn shutdown_cancels_import_tasks_and_marks_created_threads_incomplete() {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("claude-test").expect("installation");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: ProviderId::new("claude").expect("provider"),
                display_name: "Claude".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        let workspace = tempfile::tempdir().expect("workspace");
        let workspace_id = WorkspaceId::new("workspace-test").expect("workspace id");
        store
            .select_workspace(&installation_id, &workspace_id, workspace.path(), 1)
            .expect("workspace");
        let source = BindingKey {
            installation_id: installation_id.clone(),
            chat_id: 9,
            workspace_id: workspace_id.clone(),
        };
        store.chat_settings(&source, 1).expect("source settings");
        store
            .begin_history_import_thread(&source, 42, "opaque", 10, i64::MAX)
            .expect("begin import");

        let runtime = ClaudeHistoryRuntime {
            reader: ClaudeHistoryReader {
                node: PathBuf::from("/bin/false"),
                sdk_module: PathBuf::from("/tmp/sdk.mjs"),
            },
            registry: Arc::new(Mutex::new(ClaudeHistoryRegistry::default())),
            import_permits: Arc::new(Semaphore::new(MAX_CONCURRENT_IMPORTS)),
            import_tasks: Arc::new(Mutex::new(Vec::new())),
        };
        runtime.registry.lock().expect("registry").pickers.insert(
            "opaque".to_string(),
            ClaudeHistoryPicker {
                installation_id: installation_id.clone(),
                owner_user_id: 7,
                chat_id: 9,
                message_id: Some(11),
                workspace_id,
                workspace: workspace.path().to_path_buf(),
                workspace_label: "workspace".to_string(),
                sessions: Vec::new(),
                created_at: 10,
                expires_at: i64::MAX,
                state: ClaudeHistoryPickerState::Importing {
                    thread_id: Some(42),
                    session_index: 0,
                },
                transcript: None,
            },
        );
        runtime.track_import(tokio::spawn(std::future::pending::<()>()));

        runtime.cancel_imports(&store).await;

        assert!(runtime.import_tasks.lock().expect("tasks").is_empty());
        assert_eq!(
            store
                .history_import_state(&installation_id, 42, 11)
                .expect("state"),
            Some(HistoryImportState::Incomplete)
        );
        assert_eq!(
            runtime.thread_state(42),
            Some(ClaudeHistoryThreadState::Incomplete)
        );
    }

    #[test]
    fn aliases_are_target_aware_and_leave_argument_validation_to_the_handler() {
        assert_eq!(
            claude_history_command("/sessions", "claude_bot"),
            Some(ClaudeHistoryCommand::Sessions)
        );
        assert_eq!(
            claude_history_command("/open@claude_bot", "claude_bot"),
            Some(ClaudeHistoryCommand::Sessions)
        );
        assert_eq!(
            claude_history_command("/sessions 2", "claude_bot"),
            Some(ClaudeHistoryCommand::Sessions)
        );
        assert_eq!(
            claude_history_command("/sessions@other_bot", "claude_bot"),
            None
        );
        assert_eq!(
            claude_history_command_for_provider(
                &ProviderId::new("codex").expect("provider"),
                "/open",
                "codex_bot",
            ),
            None,
            "history aliases must not shadow another provider's command surface"
        );
    }

    #[test]
    fn pagination_is_six_per_page_with_exact_more_label_seam() {
        let sessions = (0..13)
            .map(|index| ClaudeSessionSummary {
                session_id: format!("private-{index}"),
                title: format!("Session {index}"),
                updated_at: 13 - index,
            })
            .collect::<Vec<_>>();
        let first = claude_session_page(&sessions, 0).expect("first page");
        assert_eq!(first.items.len(), 6);
        assert!(!first.has_back);
        assert!(first.has_more);
        let second = claude_session_page(&sessions, 1).expect("second page");
        assert_eq!(second.items.len(), 6);
        assert!(second.has_back);
        assert!(second.has_more);
        let last = claude_session_page(&sessions, 2).expect("last page");
        assert_eq!(last.items.len(), 1);
        assert!(last.has_back);
        assert!(!last.has_more);
        assert_eq!(first.show_more_label, Some("Show More"));
        assert_eq!(second.show_more_label, Some("Show More"));
        assert_eq!(last.show_more_label, None);
    }

    #[test]
    fn callback_payload_is_opaque() {
        let data = claude_history_callback_data(
            "opaque-token",
            ClaudeHistoryCallbackAction::Open { index: 6 },
        )
        .expect("callback");
        let text = std::str::from_utf8(&data).expect("utf8");
        assert!(text.contains("opaque-token"));
        assert!(text.contains("\"index\":6"));
        assert!(!text.contains("session-id"));
        assert!(!text.contains("/Users/"));
        assert!(parse_claude_history_callback("bridge_claude_history_open_6", &data).is_some());
        assert!(parse_claude_history_callback("bridge_approval_0", &data).is_none());
    }

    #[test]
    fn picker_registry_refuses_to_exceed_its_hard_bound() {
        let runtime = ClaudeHistoryRuntime {
            reader: ClaudeHistoryReader {
                node: PathBuf::from("/bin/false"),
                sdk_module: PathBuf::from("/tmp/sdk.mjs"),
            },
            registry: Arc::new(Mutex::new(ClaudeHistoryRegistry::default())),
            import_permits: Arc::new(Semaphore::new(MAX_CONCURRENT_IMPORTS)),
            import_tasks: Arc::new(Mutex::new(Vec::new())),
        };
        let installation_id = InstallationId::new("claude-test").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-test").expect("workspace");
        let make_picker = |index: usize| ClaudeHistoryPicker {
            installation_id: installation_id.clone(),
            owner_user_id: 7,
            chat_id: 9,
            message_id: Some(index as i64 + 1),
            workspace_id: workspace_id.clone(),
            workspace: PathBuf::from("/tmp/project"),
            workspace_label: "project".to_string(),
            sessions: Vec::new(),
            created_at: index as i64,
            expires_at: now_seconds().saturating_add(PICKER_TTL_SECONDS),
            state: ClaudeHistoryPickerState::Retry {
                thread_id: index as i64 + 100,
                session_index: 0,
            },
            transcript: None,
        };
        for index in 0..MAX_PICKERS {
            assert!(runtime.insert_picker(format!("token-{index}"), make_picker(index)));
        }
        assert!(!runtime.insert_picker("overflow".to_string(), make_picker(MAX_PICKERS)));
        assert_eq!(
            runtime.registry.lock().expect("registry").pickers.len(),
            MAX_PICKERS
        );
    }

    #[test]
    fn retry_state_reuses_created_thread_and_only_opens_after_completion() {
        let runtime = ClaudeHistoryRuntime {
            reader: ClaudeHistoryReader {
                node: PathBuf::from("/bin/false"),
                sdk_module: PathBuf::from("/tmp/sdk.mjs"),
            },
            registry: Arc::new(Mutex::new(ClaudeHistoryRegistry::default())),
            import_permits: Arc::new(Semaphore::new(MAX_CONCURRENT_IMPORTS)),
            import_tasks: Arc::new(Mutex::new(Vec::new())),
        };
        let installation_id = InstallationId::new("claude-test").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-test").expect("workspace");
        let workspace = PathBuf::from("/tmp/project");
        runtime.registry.lock().expect("registry").pickers.insert(
            "opaque".to_string(),
            ClaudeHistoryPicker {
                installation_id: installation_id.clone(),
                owner_user_id: 7,
                chat_id: 9,
                message_id: Some(11),
                workspace_id: workspace_id.clone(),
                workspace: workspace.clone(),
                workspace_label: "project".to_string(),
                sessions: vec![ClaudeSessionSummary {
                    session_id: "private-session".to_string(),
                    title: "Session".to_string(),
                    updated_at: 1,
                }],
                created_at: 1,
                expires_at: 1_000,
                state: ClaudeHistoryPickerState::Pending,
                transcript: None,
            },
        );
        let callback = ClaudeHistoryCallback {
            version: 1,
            token: "opaque".to_string(),
            action: ClaudeHistoryCallbackAction::Open { index: 0 },
        };
        let claim = runtime.claim(
            &callback,
            &installation_id,
            7,
            7,
            9,
            11,
            Some(&workspace_id),
            Some(&workspace),
            Some(
                Arc::new(Semaphore::new(1))
                    .try_acquire_owned()
                    .expect("import permit"),
            ),
            10,
        );
        let ClaudeHistoryClaim::Import(first) = claim else {
            panic!("pending picker should start import");
        };
        assert_eq!(first.thread_id, None);
        assert_eq!(runtime.fail_import("opaque"), None);
        let claim = runtime.claim(
            &callback,
            &installation_id,
            7,
            7,
            9,
            11,
            Some(&workspace_id),
            Some(&workspace),
            Some(
                Arc::new(Semaphore::new(1))
                    .try_acquire_owned()
                    .expect("import permit"),
            ),
            10,
        );
        let ClaudeHistoryClaim::Import(first) = claim else {
            panic!("pre-publication failure should restore the pending picker");
        };
        assert_eq!(first.thread_id, None);
        runtime.set_import_thread("opaque", 42);
        assert_eq!(
            runtime.thread_state(42),
            Some(ClaudeHistoryThreadState::Importing)
        );
        assert_eq!(runtime.fail_import("opaque"), Some(42));
        assert_eq!(
            runtime.thread_state(42),
            Some(ClaudeHistoryThreadState::Incomplete)
        );
        {
            let mut registry = runtime.registry.lock().expect("registry");
            let picker = registry.pickers.get_mut("opaque").expect("picker");
            assert!(picker.expires_at > now_seconds());
            picker.expires_at = now_seconds().saturating_sub(1);
        }
        assert_eq!(runtime.thread_state(42), None);
        runtime
            .registry
            .lock()
            .expect("registry")
            .pickers
            .get_mut("opaque")
            .expect("picker")
            .expires_at = now_seconds().saturating_add(PICKER_TTL_SECONDS);

        let wrong_session = ClaudeHistoryCallback {
            version: 1,
            token: "opaque".to_string(),
            action: ClaudeHistoryCallbackAction::Open { index: 1 },
        };
        assert!(matches!(
            runtime.claim(
                &wrong_session,
                &installation_id,
                7,
                7,
                9,
                11,
                Some(&workspace_id),
                Some(&workspace),
                Some(
                    Arc::new(Semaphore::new(1))
                        .try_acquire_owned()
                        .expect("import permit"),
                ),
                11,
            ),
            ClaudeHistoryClaim::Stale
        ));
        let page_callback = ClaudeHistoryCallback {
            version: 1,
            token: "opaque".to_string(),
            action: ClaudeHistoryCallbackAction::Page { page: 0 },
        };
        assert!(matches!(
            runtime.claim(
                &page_callback,
                &installation_id,
                7,
                7,
                9,
                11,
                Some(&workspace_id),
                Some(&workspace),
                None,
                11,
            ),
            ClaudeHistoryClaim::Stale
        ));

        let retry = runtime.claim(
            &callback,
            &installation_id,
            7,
            7,
            9,
            11,
            Some(&workspace_id),
            Some(&workspace),
            Some(
                Arc::new(Semaphore::new(1))
                    .try_acquire_owned()
                    .expect("import permit"),
            ),
            11,
        );
        let ClaudeHistoryClaim::Import(retry) = retry else {
            panic!("failed publication should be retryable");
        };
        assert_eq!(retry.thread_id, Some(42));
        runtime.mark_opened("opaque", 42);
        assert_eq!(runtime.thread_state(42), None);
        assert!(matches!(
            runtime.claim(
                &callback,
                &installation_id,
                7,
                7,
                9,
                11,
                Some(&workspace_id),
                Some(&workspace),
                Some(
                    Arc::new(Semaphore::new(1))
                        .try_acquire_owned()
                        .expect("import permit"),
                ),
                12,
            ),
            ClaudeHistoryClaim::Opened(42)
        ));
    }

    #[test]
    fn claims_validate_owner_chat_and_workspace() {
        let runtime = ClaudeHistoryRuntime {
            reader: ClaudeHistoryReader {
                node: PathBuf::from("/bin/false"),
                sdk_module: PathBuf::from("/tmp/sdk.mjs"),
            },
            registry: Arc::new(Mutex::new(ClaudeHistoryRegistry::default())),
            import_permits: Arc::new(Semaphore::new(MAX_CONCURRENT_IMPORTS)),
            import_tasks: Arc::new(Mutex::new(Vec::new())),
        };
        let installation_id = InstallationId::new("claude-test").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-test").expect("workspace");
        let workspace = PathBuf::from("/tmp/project");
        runtime.registry.lock().expect("registry").pickers.insert(
            "opaque".to_string(),
            ClaudeHistoryPicker {
                installation_id: installation_id.clone(),
                owner_user_id: 7,
                chat_id: 9,
                message_id: Some(11),
                workspace_id: workspace_id.clone(),
                workspace: workspace.clone(),
                workspace_label: "project".to_string(),
                sessions: Vec::new(),
                created_at: 1,
                expires_at: 1_000,
                state: ClaudeHistoryPickerState::Pending,
                transcript: None,
            },
        );
        let callback = ClaudeHistoryCallback {
            version: 1,
            token: "opaque".to_string(),
            action: ClaudeHistoryCallbackAction::Page { page: 0 },
        };
        assert!(matches!(
            runtime.claim(
                &callback,
                &installation_id,
                7,
                8,
                9,
                11,
                Some(&workspace_id),
                Some(&workspace),
                None,
                10,
            ),
            ClaudeHistoryClaim::Unauthorized
        ));
        assert!(matches!(
            runtime.claim(
                &callback,
                &installation_id,
                7,
                7,
                10,
                11,
                Some(&workspace_id),
                Some(&workspace),
                None,
                10,
            ),
            ClaudeHistoryClaim::Stale
        ));
        let other_workspace = WorkspaceId::new("other-workspace").expect("workspace");
        assert!(matches!(
            runtime.claim(
                &callback,
                &installation_id,
                7,
                7,
                9,
                11,
                Some(&other_workspace),
                Some(&workspace),
                None,
                10,
            ),
            ClaudeHistoryClaim::Stale
        ));
    }

    #[test]
    fn text_chunks_bound_utf16_and_utf8_without_splitting_astral_scalars() {
        let input = "😀".repeat(7_000);
        let prefix = "Claude (continued)\n\n";
        let chunks = text_chunks(
            &input,
            MAX_INLINE_TEXT_UTF16 - prefix.encode_utf16().count(),
            MAX_INLINE_TEXT_BYTES - prefix.len(),
        );
        assert_eq!(chunks.concat(), input);
        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|chunk| {
            format!("{prefix}{chunk}").encode_utf16().count() <= MAX_INLINE_TEXT_UTF16
                && format!("{prefix}{chunk}").len() <= MAX_INLINE_TEXT_BYTES
        }));
    }

    #[test]
    fn picker_button_labels_fit_the_server_utf16_limit() {
        for session in [
            ClaudeSessionSummary {
                session_id: "private-ascii".to_string(),
                title: "a".repeat(80),
                updated_at: 1_700_000_000,
            },
            ClaudeSessionSummary {
                session_id: "private-emoji".to_string(),
                title: "😀".repeat(40),
                updated_at: i64::MAX,
            },
        ] {
            let label = picker_button_text(&session);
            assert!(!label.is_empty());
            assert!(label.encode_utf16().count() <= MAX_BUTTON_TEXT_UTF16);
        }
    }
}

use std::collections::HashMap;
use std::path::PathBuf;

use agent_client_protocol::schema::v1::{
    ContentBlock, PermissionOption, PermissionOptionKind, PlanEntryStatus,
    RequestPermissionRequest, SessionUpdate, StopReason, ToolCall, ToolCallContent,
    ToolCallLocation, ToolCallStatus, ToolCallUpdate, ToolKind,
};
use inline_agent_bridge::{
    ActivityDetail, ActivitySemanticKind, ActivityStatus, ActivityTextStream, ActivityUpsert,
    AgentEvent, ApprovalOption, DriverCommand, DriverModelOption, DriverSettingOption,
    DriverSettingsCatalog, FileChange, PlanStep, PlanStepStatus, TurnId, TurnOutcome,
    native_tool_activity, sanitize_visible_command,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

// Safety valves only: a harness has no such limits, so these sit far past what
// a real plan or tool run reaches.
const MAX_PLAN_STEPS: usize = 1_024;
const MAX_PLAN_TEXT_CHARS: usize = 8_192;
const MAX_PERMISSION_OPTIONS: usize = 7;
const MAX_PROVIDER_OPTION_ID_BYTES: usize = 128;
const MAX_PROVIDER_OPTION_LABEL_CHARS: usize = 80;
const MAX_RETAINED_TOOL_CALLS: usize = 4_096;
const MAX_RETAINED_TOOL_CALL_ID_BYTES: usize = 256;
const MAX_RETAINED_TOOL_LOCATIONS: usize = 256;
const MAX_RETAINED_TOOL_PATH_BYTES: usize = 1_024;
pub(crate) type ToolCallSnapshots = HashMap<String, ToolCall>;

/// What one ACP tool call said beyond its semantic label, for bridge v2 rows
/// the way a native harness reports them. Legacy sessions never collect this.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct ToolDetail {
    pub(crate) provider_title: String,
    #[serde(default)]
    pub(crate) raw_input: Value,
    #[serde(default)]
    pub(crate) cwd: Option<PathBuf>,
    #[serde(default)]
    pub(crate) output: Option<String>,
    #[serde(default)]
    pub(crate) error: Option<String>,
    #[serde(default)]
    pub(crate) exit_code: Option<i32>,
    #[serde(default)]
    pub(crate) locations: Vec<PathBuf>,
    #[serde(default)]
    pub(crate) diffs: Vec<ToolDiff>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ToolDiff {
    pub(crate) path: PathBuf,
    pub(crate) old_text: Option<String>,
    pub(crate) new_text: String,
}

/// One open run of reasoning text.
#[derive(Debug)]
struct OpenThought {
    activity_id: String,
    message_id: Option<String>,
    text: String,
}

/// Per-turn (or per-child) state for mapping an ACP update stream.
#[derive(Debug, Default)]
pub(crate) struct StreamState {
    pub(crate) tool_calls: ToolCallSnapshots,
    details: Option<HashMap<String, ToolDetail>>,
    thought: Option<OpenThought>,
    thoughts: u64,
}

impl StreamState {
    /// `rich` collects tool details for a bridge v2 session.
    pub(crate) fn new(rich: bool) -> Self {
        Self {
            details: rich.then(HashMap::new),
            ..Self::default()
        }
    }

    /// Whether this stream belongs to a bridge v2 session.
    pub(crate) fn is_rich(&self) -> bool {
        self.details.is_some()
    }

    /// Ends the open reasoning run, if any.
    pub(crate) fn close_thought(&mut self, turn_id: &TurnId) -> Option<AgentEvent> {
        let thought = self.thought.take()?;
        let text = thought.text;
        let activity = ActivityUpsert::new(
            thought.activity_id,
            ActivitySemanticKind::Think,
            ActivityStatus::Completed,
            "Thinking",
        )?
        .with_reasoning_content([text]);
        Some(AgentEvent::ActivityUpsert {
            turn_id: turn_id.clone(),
            activity,
        })
    }

    fn thought_events(
        &mut self,
        turn_id: &TurnId,
        chunk: agent_client_protocol::schema::v1::ContentChunk,
    ) -> Vec<AgentEvent> {
        let ContentBlock::Text(text) = chunk.content else {
            return Vec::new();
        };
        if text.text.is_empty() {
            return Vec::new();
        }
        let message_id = chunk.message_id.map(|id| id.to_string());
        let mut events = Vec::new();
        // A new message id is a new reasoning block, as in the native streams.
        if self
            .thought
            .as_ref()
            .is_some_and(|open| message_id.is_some() && open.message_id != message_id)
        {
            events.extend(self.close_thought(turn_id));
        }
        if self.thought.is_none() {
            self.thoughts += 1;
            let activity_id = format!("{turn_id}:thought:{}", self.thoughts);
            if let Some(activity) = ActivityUpsert::new(
                activity_id.clone(),
                ActivitySemanticKind::Think,
                ActivityStatus::InProgress,
                "Thinking",
            ) {
                events.push(AgentEvent::ActivityUpsert {
                    turn_id: turn_id.clone(),
                    activity,
                });
            }
            self.thought = Some(OpenThought {
                activity_id,
                message_id,
                text: String::new(),
            });
        }
        let open = self.thought.as_mut().expect("thought just opened");
        open.text.push_str(&text.text);
        events.push(AgentEvent::ActivityTextDelta {
            turn_id: turn_id.clone(),
            activity_id: open.activity_id.clone(),
            stream: ActivityTextStream::Summary,
            index: None,
            delta: text.text,
        });
        events
    }

    fn merge_detail(&mut self, update: &SessionUpdate) {
        let Some(details) = self.details.as_mut() else {
            return;
        };
        match update {
            SessionUpdate::ToolCall(call) => {
                let detail = details.entry(call.tool_call_id.to_string()).or_default();
                detail.merge(
                    Some(call.title.as_str()),
                    call.raw_input.as_ref(),
                    Some(call.locations.as_slice()),
                    Some(call.content.as_slice()),
                    call.raw_output.as_ref(),
                    call.status,
                );
            }
            SessionUpdate::ToolCallUpdate(update) => {
                let detail = details.entry(update.tool_call_id.to_string()).or_default();
                let fields = &update.fields;
                detail.merge(
                    fields.title.as_deref(),
                    fields.raw_input.as_ref(),
                    fields.locations.as_deref(),
                    fields.content.as_deref(),
                    fields.raw_output.as_ref(),
                    fields.status.unwrap_or(ToolCallStatus::InProgress),
                );
            }
            _ => {}
        }
    }

    /// Carries the collected detail on the activity event itself, so a later
    /// update cannot race it. Finished calls drop their retained detail.
    fn attach_details(&mut self, events: &mut [AgentEvent]) {
        let Some(details) = self.details.as_mut() else {
            return;
        };
        for event in events {
            let AgentEvent::ActivityUpsert { activity, .. } = event else {
                continue;
            };
            let finished = !matches!(
                activity.status,
                ActivityStatus::Pending | ActivityStatus::InProgress
            );
            let detail = if finished {
                details.remove(&activity.activity_id)
            } else {
                details.get(&activity.activity_id).cloned()
            };
            if let Some(payload) = detail.and_then(|detail| serde_json::to_string(&detail).ok()) {
                activity.verbose_payload = Some(payload);
            }
        }
    }
}

impl ToolDetail {
    fn merge(
        &mut self,
        title: Option<&str>,
        raw_input: Option<&Value>,
        locations: Option<&[ToolCallLocation]>,
        content: Option<&[ToolCallContent]>,
        raw_output: Option<&Value>,
        status: ToolCallStatus,
    ) {
        if let Some(title) = title.filter(|title| !title.trim().is_empty()) {
            self.provider_title = title.to_owned();
        }
        // A pending call reports `{}` until the model finishes its arguments.
        if let Some(raw_input) = raw_input.filter(|raw| !is_empty_object(raw)) {
            self.raw_input = raw_input.clone();
            self.cwd = ["cwd", "workdir"]
                .iter()
                .find_map(|key| raw_input.get(*key).and_then(Value::as_str))
                .map(PathBuf::from);
        }
        if let Some(locations) = locations.filter(|locations| !locations.is_empty()) {
            self.locations = locations
                .iter()
                .map(|location| location.path.clone())
                .collect();
        }
        if let Some(content) = content {
            let diffs = content
                .iter()
                .filter_map(|content| match content {
                    ToolCallContent::Diff(diff) => Some(ToolDiff {
                        path: diff.path.clone(),
                        old_text: diff.old_text.clone(),
                        new_text: diff.new_text.clone(),
                    }),
                    _ => None,
                })
                .collect::<Vec<_>>();
            if !diffs.is_empty() {
                self.diffs = diffs;
            }
        }
        let text = content
            .into_iter()
            .flatten()
            .filter_map(|content| match content {
                ToolCallContent::Content(content) => match &content.content {
                    ContentBlock::Text(text) if !text.text.is_empty() => Some(text.text.as_str()),
                    _ => None,
                },
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n");
        let text = (!text.is_empty())
            .then_some(text)
            .or_else(|| raw_output.and_then(raw_output_text));
        if status == ToolCallStatus::Failed {
            self.error = raw_output
                .and_then(|raw| raw.get("error"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or(text)
                .or_else(|| self.error.take());
        } else if text.is_some() {
            self.output = text;
        }
        if let Some(exit_code) = raw_output.and_then(raw_output_exit_code) {
            self.exit_code = Some(exit_code);
        }
    }

    /// The file changes of this call: the protocol's diffs, or what the raw
    /// input says when the agent reports none.
    pub(crate) fn file_diffs(&self) -> Vec<ToolDiff> {
        if !self.diffs.is_empty() {
            return self.diffs.clone();
        }
        let Some(path) = self.path().or_else(|| self.locations.first().cloned()) else {
            return Vec::new();
        };
        let text = |keys: &[&str]| {
            keys.iter()
                .find_map(|key| self.raw_input.get(*key).and_then(Value::as_str))
                .map(str::to_owned)
        };
        match (
            text(&["oldString", "old_string"]),
            text(&["newString", "new_string"]),
            text(&["content"]),
        ) {
            (Some(old_text), Some(new_text), _) => vec![ToolDiff {
                path,
                old_text: Some(old_text),
                new_text,
            }],
            (None, _, Some(new_text)) => vec![ToolDiff {
                path,
                old_text: None,
                new_text,
            }],
            _ => Vec::new(),
        }
    }

    pub(crate) fn path(&self) -> Option<PathBuf> {
        ["path", "filePath", "file_path"]
            .iter()
            .find_map(|key| self.raw_input.get(*key).and_then(Value::as_str))
            .map(PathBuf::from)
    }

    /// The tool's short name, without a provider-rendered argument suffix.
    pub(crate) fn tool_name(&self) -> String {
        self.provider_title
            .split(':')
            .next()
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
    }
}

fn is_empty_object(value: &Value) -> bool {
    value.as_object().is_some_and(serde_json::Map::is_empty)
}

fn raw_output_text(raw: &Value) -> Option<String> {
    if let Some(text) = raw.as_str() {
        return Some(text.to_owned());
    }
    ["output", "stdout", "content", "text"]
        .iter()
        .find_map(|key| raw.get(*key).and_then(Value::as_str))
        .map(str::to_owned)
}

fn raw_output_exit_code(raw: &Value) -> Option<i32> {
    ["exit", "exitCode", "exit_code"]
        .iter()
        .find_map(|key| {
            raw.get("metadata")
                .and_then(|metadata| metadata.get(*key))
                .or_else(|| raw.get(*key))
                .and_then(Value::as_i64)
        })
        .and_then(|code| i32::try_from(code).ok())
}

/// A zero-context unified diff of one edit, for the chat's diff view.
pub(crate) fn unified_diff(old_text: Option<&str>, new_text: &str) -> String {
    let old_lines = old_text.map_or_else(Vec::new, |text| text.lines().collect::<Vec<_>>());
    let new_lines = new_text.lines().collect::<Vec<_>>();
    let prefix = old_lines
        .iter()
        .zip(&new_lines)
        .take_while(|(old, new)| old == new)
        .count();
    let suffix = old_lines[prefix..]
        .iter()
        .rev()
        .zip(new_lines[prefix..].iter().rev())
        .take_while(|(old, new)| old == new)
        .count();
    let removed = &old_lines[prefix..old_lines.len() - suffix];
    let added = &new_lines[prefix..new_lines.len() - suffix];
    let mut diff = format!(
        "@@ -{},{} +{},{} @@\n",
        prefix + 1,
        removed.len(),
        prefix + 1,
        added.len()
    );
    for line in removed {
        diff.push('-');
        diff.push_str(line);
        diff.push('\n');
    }
    for line in added {
        diff.push('+');
        diff.push_str(line);
        diff.push('\n');
    }
    diff
}

/// Maps one update of a turn or child stream.
pub(crate) fn stream_events(
    turn_id: &TurnId,
    stream: &mut StreamState,
    update: SessionUpdate,
) -> Vec<AgentEvent> {
    if let SessionUpdate::AgentThoughtChunk(chunk) = update {
        return stream.thought_events(turn_id, chunk);
    }
    let mut events = Vec::new();
    if matches!(
        update,
        SessionUpdate::AgentMessageChunk(_)
            | SessionUpdate::ToolCall(_)
            | SessionUpdate::ToolCallUpdate(_)
            | SessionUpdate::Plan(_)
    ) {
        events.extend(stream.close_thought(turn_id));
    }
    stream.merge_detail(&update);
    let mapped_from = events.len();
    events.extend(session_update_events(
        turn_id,
        &mut stream.tool_calls,
        update,
    ));
    stream.attach_details(&mut events[mapped_from..]);
    events
}

pub(crate) fn available_commands(
    commands: &[agent_client_protocol::schema::v1::AvailableCommand],
) -> Vec<DriverCommand> {
    DriverCommand::catalog(commands.iter().filter_map(|command| {
        let input_hint = match command.input.as_ref() {
            Some(agent_client_protocol::schema::v1::AvailableCommandInput::Unstructured(input)) => {
                Some(input.hint.as_str())
            }
            _ => None,
        };
        DriverCommand::new(&command.name, &command.description, input_hint)
    }))
}

pub(crate) fn permission_options(options: &[PermissionOption]) -> Vec<ApprovalOption> {
    let mut mapped = options
        .iter()
        .filter_map(|option| match option.kind {
            _ if requires_provider_choice(options, option) => safe_provider_option(option),
            PermissionOptionKind::AllowOnce => Some(ApprovalOption::ApproveOnce),
            PermissionOptionKind::AllowAlways => Some(ApprovalOption::ApproveForSession),
            PermissionOptionKind::RejectOnce | PermissionOptionKind::RejectAlways => {
                Some(ApprovalOption::Reject)
            }
            _ => safe_provider_option(option),
        })
        .take(MAX_PERMISSION_OPTIONS)
        .collect::<Vec<_>>();
    mapped.push(ApprovalOption::CancelTurn);
    mapped
}

fn requires_provider_choice(options: &[PermissionOption], option: &PermissionOption) -> bool {
    match option.kind {
        PermissionOptionKind::AllowOnce => {
            options
                .iter()
                .filter(|candidate| candidate.kind == PermissionOptionKind::AllowOnce)
                .count()
                > 1
        }
        PermissionOptionKind::AllowAlways => {
            options
                .iter()
                .filter(|candidate| candidate.kind == PermissionOptionKind::AllowAlways)
                .count()
                > 1
        }
        PermissionOptionKind::RejectOnce | PermissionOptionKind::RejectAlways => {
            options
                .iter()
                .filter(|candidate| {
                    matches!(
                        candidate.kind,
                        PermissionOptionKind::RejectOnce | PermissionOptionKind::RejectAlways
                    )
                })
                .count()
                > 1
        }
        _ => true,
    }
}

fn safe_provider_option(option: &PermissionOption) -> Option<ApprovalOption> {
    let option_id = option.option_id.to_string();
    if option_id.trim().is_empty()
        || option_id.len() > MAX_PROVIDER_OPTION_ID_BYTES
        || option_id.chars().any(char::is_control)
    {
        return None;
    }
    let label = option
        .name
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MAX_PROVIDER_OPTION_LABEL_CHARS)
        .collect::<String>();
    if label.is_empty() {
        return None;
    }
    Some(ApprovalOption::ProviderChoice { option_id, label })
}

pub(crate) fn permission_summary(request: &RequestPermissionRequest) -> String {
    match request.tool_call.fields.kind {
        Some(ToolKind::Read) => "Read project files",
        Some(ToolKind::Edit) => "Edit project files",
        Some(ToolKind::Delete) => "Delete project files",
        Some(ToolKind::Move) => "Move project files",
        Some(ToolKind::Search) => "Search the project",
        Some(ToolKind::Execute) => "Run a command",
        Some(ToolKind::Think) => "Continue reasoning",
        Some(ToolKind::Fetch) => "Fetch external content",
        Some(ToolKind::SwitchMode) => "Change agent mode",
        Some(ToolKind::Other) => "Use an agent tool",
        _ => "Use an agent tool",
    }
    .to_string()
}

pub(crate) fn permission_command(request: &RequestPermissionRequest) -> Option<String> {
    let fields = &request.tool_call.fields;
    command_preview(fields.raw_input.as_ref()).or_else(|| {
        matches!(fields.kind, Some(ToolKind::Execute))
            .then(|| fields.title.as_deref().and_then(command_title_preview))
            .flatten()
    })
}

fn command_preview(raw: Option<&serde_json::Value>) -> Option<String> {
    let raw = raw?;
    for key in ["command", "cmd"] {
        if let Some(command) = raw.get(key).and_then(serde_json::Value::as_str)
            && !command.trim().is_empty()
        {
            return sanitize_visible_command(command);
        }
    }
    None
}

fn command_title_preview(title: &str) -> Option<String> {
    let generic = title
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase();
    if matches!(
        generic.as_str(),
        "bash" | "command" | "execute" | "run command" | "running command" | "shell" | "terminal"
    ) {
        return None;
    }
    sanitize_visible_command(title)
}

pub(crate) fn session_update_events(
    turn_id: &TurnId,
    tool_calls: &mut ToolCallSnapshots,
    update: SessionUpdate,
) -> Vec<AgentEvent> {
    match update {
        SessionUpdate::AgentMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) if !text.text.is_empty() => {
                vec![AgentEvent::AgentTextDelta {
                    turn_id: turn_id.clone(),
                    text: text.text,
                }]
            }
            ContentBlock::Image(_) => vec![activity(turn_id, "Received an image.")],
            ContentBlock::Audio(_) => vec![activity(turn_id, "Received audio.")],
            ContentBlock::ResourceLink(_) | ContentBlock::Resource(_) => {
                vec![activity(turn_id, "Referenced a resource.")]
            }
            _ => Vec::new(),
        },
        // Reasoning has its own lifecycle in `stream_events`.
        SessionUpdate::AgentThoughtChunk(_) => Vec::new(),
        SessionUpdate::ToolCall(call) => {
            let mut events = if let Some(activity) = activity_upsert(&call) {
                vec![AgentEvent::ActivityUpsert {
                    turn_id: turn_id.clone(),
                    activity,
                }]
            } else {
                vec![activity(turn_id, "Agent tool activity.")]
            };
            append_completed_file_changes(turn_id, &call, &mut events);
            retain_tool_call(tool_calls, call);
            events
        }
        SessionUpdate::ToolCallUpdate(update) => tool_update_events(turn_id, tool_calls, update),
        SessionUpdate::Plan(plan) => vec![AgentEvent::PlanUpdated {
            turn_id: turn_id.clone(),
            explanation: None,
            steps: plan
                .entries
                .into_iter()
                .take(MAX_PLAN_STEPS)
                .filter_map(|entry| {
                    let text = entry
                        .content
                        .split_whitespace()
                        .collect::<Vec<_>>()
                        .join(" ")
                        .chars()
                        .take(MAX_PLAN_TEXT_CHARS)
                        .collect::<String>();
                    if text.is_empty() {
                        return None;
                    }
                    let status = match entry.status {
                        PlanEntryStatus::Pending => PlanStepStatus::Pending,
                        PlanEntryStatus::InProgress => PlanStepStatus::InProgress,
                        PlanEntryStatus::Completed => PlanStepStatus::Completed,
                        _ => return None,
                    };
                    Some(PlanStep { text, status })
                })
                .collect(),
        }],
        // Session facts reach bridge v2 as signals, not turn events. A user
        // chunk only echoes this client's prompt or replays history on load.
        SessionUpdate::AvailableCommandsUpdate(_)
        | SessionUpdate::CurrentModeUpdate(_)
        | SessionUpdate::ConfigOptionUpdate(_)
        | SessionUpdate::SessionInfoUpdate(_)
        | SessionUpdate::UsageUpdate(_)
        | SessionUpdate::UserMessageChunk(_) => Vec::new(),
        _ => Vec::new(),
    }
}

fn tool_update_events(
    turn_id: &TurnId,
    tool_calls: &mut ToolCallSnapshots,
    update: ToolCallUpdate,
) -> Vec<AgentEvent> {
    let mut events = Vec::new();
    let has_legacy_title = update
        .fields
        .title
        .as_deref()
        .is_some_and(|title| !title.trim().is_empty());
    let tool_call_id = update.tool_call_id.to_string();
    let snapshot = if let Some(mut existing) = tool_calls.get(&tool_call_id).cloned() {
        existing.update(update.fields);
        Some(existing)
    } else {
        ToolCall::try_from(update).ok()
    };
    if let Some(activity) = snapshot.as_ref().and_then(activity_upsert) {
        events.push(AgentEvent::ActivityUpsert {
            turn_id: turn_id.clone(),
            activity,
        });
    } else if has_legacy_title {
        // An incomplete ACP patch can still carry useful provider progress, but
        // must not fabricate a replaceable structured snapshot or expose the
        // provider's raw title, which can contain a rendered command.
        events.push(activity(turn_id, "Agent tool activity."));
    }
    if let Some(snapshot) = snapshot.as_ref() {
        append_completed_file_changes(turn_id, snapshot, &mut events);
    }
    if let Some(snapshot) = snapshot {
        retain_tool_call(tool_calls, snapshot);
    }
    events
}

fn retain_tool_call(tool_calls: &mut ToolCallSnapshots, mut call: ToolCall) {
    let tool_call_id = call.tool_call_id.to_string();
    if tool_call_id.trim().is_empty()
        || tool_call_id.len() > MAX_RETAINED_TOOL_CALL_ID_BYTES
        || tool_call_id.chars().any(char::is_control)
    {
        return;
    }
    if matches!(
        call.status,
        ToolCallStatus::Completed | ToolCallStatus::Failed
    ) {
        tool_calls.remove(&tool_call_id);
        return;
    }
    if !tool_calls.contains_key(&tool_call_id) && tool_calls.len() >= MAX_RETAINED_TOOL_CALLS {
        return;
    }

    let presentation = native_tool_activity(&call.title, activity_kind(call.kind));
    let command = if presentation.kind == ActivitySemanticKind::Execute {
        command_preview(call.raw_input.as_ref()).or_else(|| command_title_preview(&call.title))
    } else {
        None
    };
    call.title = display_tool_title(&call.title, presentation.title);
    call.content.clear();
    // Retain only the already-sanitized, bounded command preview so a later
    // status-only patch can keep verbose progress useful without retaining the
    // provider's raw tool payload.
    call.raw_input = command.map(|command| serde_json::json!({ "command": command }));
    call.raw_output = None;
    call.meta = None;
    call.locations.retain(|location| {
        location.path.is_absolute()
            && location.path.as_os_str().as_encoded_bytes().len() <= MAX_RETAINED_TOOL_PATH_BYTES
    });
    call.locations.truncate(MAX_RETAINED_TOOL_LOCATIONS);
    for location in &mut call.locations {
        location.meta = None;
    }
    tool_calls.insert(tool_call_id, call);
}

fn append_completed_file_changes(turn_id: &TurnId, call: &ToolCall, events: &mut Vec<AgentEvent>) {
    if call.status != ToolCallStatus::Completed {
        return;
    }
    append_file_changes(
        turn_id,
        Some(call.kind),
        &call.content,
        &call.locations,
        events,
    );
}

fn append_file_changes(
    turn_id: &TurnId,
    kind: Option<ToolKind>,
    content: &[ToolCallContent],
    locations: &[ToolCallLocation],
    events: &mut Vec<AgentEvent>,
) {
    let mut files = content
        .iter()
        .filter_map(|content| match content {
            ToolCallContent::Diff(diff) => Some(FileChange {
                path: diff.path.clone(),
                summary: None,
            }),
            _ => None,
        })
        .collect::<Vec<_>>();
    if matches!(
        kind,
        Some(ToolKind::Edit | ToolKind::Delete | ToolKind::Move)
    ) {
        for location in locations {
            if !files.iter().any(|file| file.path == location.path) {
                files.push(FileChange {
                    path: location.path.clone(),
                    summary: None,
                });
            }
        }
    }
    if !files.is_empty() {
        events.push(AgentEvent::FilesChanged {
            turn_id: turn_id.clone(),
            files,
        });
    }
}

fn activity(turn_id: &TurnId, summary: impl Into<String>) -> AgentEvent {
    AgentEvent::Activity {
        turn_id: turn_id.clone(),
        summary: summary.into(),
    }
}

fn activity_upsert(call: &ToolCall) -> Option<ActivityUpsert> {
    let presentation = native_tool_activity(&call.title, activity_kind(call.kind));
    ActivityUpsert::new(
        call.tool_call_id.to_string(),
        presentation.kind,
        activity_status(call.status),
        display_tool_title(&call.title, presentation.title),
    )
    // ACP's raw title, input, output, and content can carry sensitive tool data.
    // Only semantic labels, structured status/locations, and the bridge's
    // sanitized bounded command preview reach chat progress.
    .map(|activity| {
        let activity = if presentation.kind == ActivitySemanticKind::Execute {
            match command_preview(call.raw_input.as_ref())
                .or_else(|| command_title_preview(&call.title))
            {
                Some(command) => activity
                    .with_detail(&command)
                    .with_details([ActivityDetail::code("Ran", command)]),
                None => activity,
            }
        } else if presentation.kind == ActivitySemanticKind::Edit {
            let details = call
                .locations
                .iter()
                .filter(|location| {
                    location.path.is_absolute()
                        && location.path.as_os_str().as_encoded_bytes().len()
                            <= MAX_RETAINED_TOOL_PATH_BYTES
                })
                .take(MAX_RETAINED_TOOL_LOCATIONS)
                .map(|location| {
                    ActivityDetail::code("File", location.path.to_string_lossy().into_owned())
                });
            activity.with_details(details)
        } else {
            activity
        };
        activity.with_paths(call.locations.iter().map(|location| location.path.clone()))
    })
}

fn display_tool_title(provider_title: &str, semantic_title: &str) -> String {
    // Generic tool identities are useful, but provider-rendered arguments may
    // contain secrets. Retain only a short identifier, never its title suffix.
    let name = provider_title.split(':').next().unwrap_or_default();
    if semantic_title == "Using an agent tool"
        && !name.is_empty()
        && name.len() <= 96
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
    {
        name.to_owned()
    } else {
        semantic_title.to_owned()
    }
}

fn activity_kind(kind: ToolKind) -> ActivitySemanticKind {
    match kind {
        ToolKind::Read => ActivitySemanticKind::Read,
        ToolKind::Edit => ActivitySemanticKind::Edit,
        ToolKind::Delete => ActivitySemanticKind::Delete,
        ToolKind::Move => ActivitySemanticKind::Move,
        ToolKind::Search => ActivitySemanticKind::Search,
        ToolKind::Execute => ActivitySemanticKind::Execute,
        ToolKind::Think => ActivitySemanticKind::Think,
        ToolKind::Fetch => ActivitySemanticKind::Fetch,
        ToolKind::SwitchMode | ToolKind::Other => ActivitySemanticKind::Other,
        _ => ActivitySemanticKind::Other,
    }
}

fn activity_status(status: ToolCallStatus) -> ActivityStatus {
    match status {
        ToolCallStatus::Pending => ActivityStatus::Pending,
        ToolCallStatus::InProgress => ActivityStatus::InProgress,
        ToolCallStatus::Completed => ActivityStatus::Completed,
        ToolCallStatus::Failed => ActivityStatus::Failed,
        _ => ActivityStatus::Pending,
    }
}

pub(crate) fn turn_outcome(reason: StopReason) -> TurnOutcome {
    match reason {
        StopReason::EndTurn => TurnOutcome::Completed,
        StopReason::MaxTokens => TurnOutcome::TokenLimit,
        StopReason::MaxTurnRequests => TurnOutcome::TurnLimit,
        StopReason::Cancelled => TurnOutcome::Interrupted,
        StopReason::Refusal => TurnOutcome::Failed,
        _ => TurnOutcome::Failed,
    }
}

pub(crate) fn settings_catalog(
    options: &[agent_client_protocol::schema::v1::SessionConfigOption],
    modes: Option<&agent_client_protocol::schema::v1::SessionModeState>,
    default_permissions: Option<&str>,
) -> DriverSettingsCatalog {
    use agent_client_protocol::schema::v1::SessionConfigOptionCategory as Category;

    let reasoning_option = options
        .iter()
        .find(|option| matches!(option.category, Some(Category::ThoughtLevel)));
    let reasoning = reasoning_option
        .and_then(select_setting)
        .unwrap_or_default();
    let default_reasoning = reasoning_option.and_then(current_select_value);
    let models = options
        .iter()
        .find(|option| matches!(option.category, Some(Category::Model)))
        .and_then(|option| {
            let current = current_select_value(option);
            select_setting(option).map(|models| {
                models
                    .into_iter()
                    .map(|model| DriverModelOption {
                        is_default: current.as_deref() == Some(model.value.as_str()),
                        reasoning: reasoning.clone(),
                        default_reasoning: default_reasoning.clone(),
                        value: model.value,
                        label: model.label,
                        description: model.description,
                    })
                    .collect()
            })
        })
        .unwrap_or_default();
    let permissions = modes
        .map(|modes| {
            modes
                .available_modes
                .iter()
                .map(|mode| DriverSettingOption {
                    value: mode.id.to_string(),
                    label: mode.name.clone(),
                    description: mode.description.clone(),
                    disabled: false,
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let default_permissions = default_permissions
        .filter(|default| permissions.iter().any(|option| option.value == *default))
        .map(str::to_string);
    DriverSettingsCatalog {
        models,
        permissions,
        default_permissions,
    }
}

pub(crate) fn session_modes(
    options: &[agent_client_protocol::schema::v1::SessionConfigOption],
    fallback: Option<&agent_client_protocol::schema::v1::SessionModeState>,
) -> Option<agent_client_protocol::schema::v1::SessionModeState> {
    use agent_client_protocol::schema::v1::{
        SessionConfigOptionCategory as Category, SessionMode, SessionModeState,
    };

    let Some(option) = options
        .iter()
        .find(|option| matches!(option.category, Some(Category::Mode)))
    else {
        return fallback.cloned();
    };
    let current = current_select_value(option)?;
    let available_modes = select_setting(option)?
        .into_iter()
        .map(|option| SessionMode::new(option.value, option.label).description(option.description))
        .collect::<Vec<_>>();
    available_modes
        .iter()
        .any(|mode| mode.id.to_string() == current)
        .then(|| SessionModeState::new(current, available_modes))
}

pub(crate) fn select_config_id(
    options: &[agent_client_protocol::schema::v1::SessionConfigOption],
    category: agent_client_protocol::schema::v1::SessionConfigOptionCategory,
    value: &str,
) -> Option<agent_client_protocol::schema::v1::SessionConfigId> {
    options
        .iter()
        .find(|option| option.category.as_ref() == Some(&category))
        .filter(|option| {
            select_setting(option)
                .is_some_and(|values| values.iter().any(|candidate| candidate.value == value))
        })
        .map(|option| option.id.clone())
}

/// The current value of one select category, with its label.
pub(crate) fn current_choice(
    options: &[agent_client_protocol::schema::v1::SessionConfigOption],
    category: agent_client_protocol::schema::v1::SessionConfigOptionCategory,
) -> Option<DriverSettingOption> {
    let option = options
        .iter()
        .find(|option| option.category.as_ref() == Some(&category))?;
    let current = current_select_value(option)?;
    select_setting(option)?
        .into_iter()
        .find(|choice| choice.value == current)
}

/// OpenCode prefixes a child's tool titles with the child's title.
pub(crate) fn strip_child_title(update: &mut SessionUpdate, child_title: &str) {
    let prefix = format!("{child_title}: ");
    let title = match update {
        SessionUpdate::ToolCall(call) => Some(&mut call.title),
        SessionUpdate::ToolCallUpdate(update) => update.fields.title.as_mut(),
        _ => None,
    };
    if let Some(title) = title
        && let Some(stripped) = title.strip_prefix(&prefix)
    {
        *title = stripped.to_owned();
    }
}

fn current_select_value(
    option: &agent_client_protocol::schema::v1::SessionConfigOption,
) -> Option<String> {
    match &option.kind {
        agent_client_protocol::schema::v1::SessionConfigKind::Select(select) => {
            Some(select.current_value.to_string())
        }
        _ => None,
    }
}

fn select_setting(
    option: &agent_client_protocol::schema::v1::SessionConfigOption,
) -> Option<Vec<DriverSettingOption>> {
    use agent_client_protocol::schema::v1::{SessionConfigKind, SessionConfigSelectOptions};
    let SessionConfigKind::Select(select) = &option.kind else {
        return None;
    };
    let values = match &select.options {
        SessionConfigSelectOptions::Ungrouped(options) => options
            .iter()
            .map(|option| (option, None))
            .collect::<Vec<_>>(),
        SessionConfigSelectOptions::Grouped(groups) => groups
            .iter()
            .flat_map(|group| {
                group
                    .options
                    .iter()
                    .map(move |option| (option, Some(group.name.as_str())))
            })
            .collect::<Vec<_>>(),
        _ => Vec::new(),
    };
    Some(
        values
            .into_iter()
            .map(|(value, group)| DriverSettingOption {
                value: value.value.to_string(),
                label: group.map_or_else(
                    || value.name.clone(),
                    |group| format!("{group} · {}", value.name),
                ),
                description: value.description.clone(),
                disabled: false,
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use agent_client_protocol::schema::v1::{
        AvailableCommand, AvailableCommandInput, PermissionOption, PermissionOptionKind, Plan,
        PlanEntry, PlanEntryPriority, PlanEntryStatus, SessionMode, SessionModeState, TextContent,
        ToolCall, ToolCallLocation, ToolCallStatus, ToolCallUpdate, ToolCallUpdateFields, ToolKind,
        UnstructuredCommandInput,
    };

    use super::*;

    #[test]
    fn maps_standard_permission_kinds_without_losing_provider_ids() {
        let options = vec![
            PermissionOption::new("once", "Allow once", PermissionOptionKind::AllowOnce),
            PermissionOption::new("always", "Always allow", PermissionOptionKind::AllowAlways),
            PermissionOption::new("deny", "Deny", PermissionOptionKind::RejectOnce),
        ];
        assert_eq!(
            permission_options(&options),
            vec![
                ApprovalOption::ApproveOnce,
                ApprovalOption::ApproveForSession,
                ApprovalOption::Reject,
                ApprovalOption::CancelTurn,
            ]
        );
    }

    #[test]
    fn preserves_distinct_claude_choices_that_share_an_acp_kind() {
        let options = vec![
            PermissionOption::new(
                "exit-plan-auto",
                "Yes, and use auto mode",
                PermissionOptionKind::AllowAlways,
            ),
            PermissionOption::new(
                "exit-plan-default",
                "Yes, manually approve edits",
                PermissionOptionKind::AllowAlways,
            ),
            PermissionOption::new("reject", "No", PermissionOptionKind::RejectOnce),
        ];
        assert_eq!(
            permission_options(&options),
            vec![
                ApprovalOption::ProviderChoice {
                    option_id: "exit-plan-auto".to_string(),
                    label: "Yes, and use auto mode".to_string(),
                },
                ApprovalOption::ProviderChoice {
                    option_id: "exit-plan-default".to_string(),
                    label: "Yes, manually approve edits".to_string(),
                },
                ApprovalOption::Reject,
                ApprovalOption::CancelTurn,
            ]
        );
    }

    #[test]
    fn maps_only_safe_bounded_provider_commands() {
        let commands = available_commands(&[
            AvailableCommand::new("research_codebase", "Research the selected project").input(
                AvailableCommandInput::Unstructured(UnstructuredCommandInput::new("topic")),
            ),
            AvailableCommand::new("Bad Command", "Unsafe name"),
            AvailableCommand::new("research_codebase", "Duplicate"),
        ]);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].name, "research_codebase");
        assert_eq!(commands[0].input_hint.as_deref(), Some("topic"));
    }

    #[test]
    fn maps_agent_text_to_a_provider_neutral_delta() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::AgentMessageChunk(agent_client_protocol::schema::v1::ContentChunk::new(
                ContentBlock::Text(TextContent::new("hello")),
            )),
        );
        assert_eq!(
            events,
            vec![AgentEvent::AgentTextDelta {
                turn_id,
                text: "hello".to_string(),
            }]
        );
    }

    #[test]
    fn read_locations_are_not_reported_as_file_changes() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCall(
                ToolCall::new("tool-1", "Reading a file")
                    .kind(ToolKind::Read)
                    .locations(vec![ToolCallLocation::new("/tmp/read.rs")]),
            ),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.kind == ActivitySemanticKind::Read
                    && activity.status == ActivityStatus::Pending
                    && activity.paths == [std::path::PathBuf::from("/tmp/read.rs")]
        ));
    }

    #[test]
    fn edit_locations_are_reported_only_after_completion() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCall(
                ToolCall::new("tool-1", "Editing a file")
                    .kind(ToolKind::Edit)
                    .locations(vec![ToolCallLocation::new("/tmp/edit.rs")]),
            ),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.kind == ActivitySemanticKind::Edit
                    && activity.status == ActivityStatus::Pending
                    && activity.details == [ActivityDetail::code("File", "/tmp/edit.rs")]
        ));

        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "tool-1",
                ToolCallUpdateFields::new().status(ToolCallStatus::Completed),
            )),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }, AgentEvent::FilesChanged { files, .. }]
                if files[0].path == std::path::Path::new("/tmp/edit.rs")
                    && activity.kind == ActivitySemanticKind::Edit
                    && activity.status == ActivityStatus::Completed
        ));
    }

    #[test]
    fn failed_or_cancelled_edits_do_not_claim_file_changes() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        for status in [ToolCallStatus::Failed, ToolCallStatus::InProgress] {
            let mut tool_calls = ToolCallSnapshots::new();
            let events = session_update_events(
                &turn_id,
                &mut tool_calls,
                SessionUpdate::ToolCall(
                    ToolCall::new("tool-1", "Editing a file")
                        .kind(ToolKind::Edit)
                        .status(status)
                        .locations(vec![ToolCallLocation::new("/tmp/edit.rs")]),
                ),
            );
            assert!(
                events
                    .iter()
                    .all(|event| !matches!(event, AgentEvent::FilesChanged { .. }))
            );
        }
    }

    #[test]
    fn malformed_tool_identity_does_not_expose_raw_provider_title() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let raw_title = "private\u{1b}[31m provider detail";
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCall(ToolCall::new("x".repeat(300), raw_title)),
        );
        assert_eq!(
            events,
            vec![AgentEvent::Activity {
                turn_id,
                summary: "Agent tool activity.".to_string(),
            }]
        );
        assert!(tool_calls.is_empty());
    }

    #[test]
    fn execute_title_is_exposed_only_as_a_sanitized_command_preview() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let raw_title = "cargo test --token must-not-appear";
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCall(
                ToolCall::new("tool-1", raw_title)
                    .kind(ToolKind::Execute)
                    .status(ToolCallStatus::InProgress),
            ),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.title == "Running command"
                    && activity.detail.as_deref() == Some("cargo test --token [redacted]")
        ));
        assert_eq!(tool_calls["tool-1"].title, "Running command");
        assert_eq!(
            tool_calls["tool-1"]
                .raw_input
                .as_ref()
                .and_then(|input| input.get("command"))
                .and_then(serde_json::Value::as_str),
            Some("cargo test --token [redacted]")
        );
    }

    #[test]
    fn inferred_amp_shell_commands_keep_their_preview_on_status_only_completion() {
        let turn = TurnId::new("amp-turn").unwrap();
        let mut calls = ToolCallSnapshots::new();
        session_update_events(
            &turn,
            &mut calls,
            SessionUpdate::ToolCall(
                ToolCall::new("shell", "shell_command: ls -la")
                    .kind(ToolKind::Other)
                    .raw_input(serde_json::json!({ "command": "ls -la", "workdir": "/tmp" })),
            ),
        );
        let events = session_update_events(
            &turn,
            &mut calls,
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "shell",
                agent_client_protocol::schema::v1::ToolCallUpdateFields::new()
                    .status(ToolCallStatus::Completed),
            )),
        );
        assert!(
            matches!(events.as_slice(), [AgentEvent::ActivityUpsert { activity, .. }]
            if activity.kind == ActivitySemanticKind::Execute && activity.detail.as_deref() == Some("ls -la"))
        );
    }

    #[test]
    fn generic_tool_identity_excludes_provider_argument_suffixes() {
        assert_eq!(
            display_tool_title("inspect_project: private content", "Using an agent tool"),
            "inspect_project"
        );
        assert_eq!(
            display_tool_title("private content", "Using an agent tool"),
            "Using an agent tool"
        );
    }

    #[test]
    fn execute_activity_retains_only_a_sanitized_command_preview_across_updates() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCall(
                ToolCall::new("tool-1", "Bash")
                    .kind(ToolKind::Execute)
                    .status(ToolCallStatus::InProgress)
                    .raw_input(serde_json::json!({
                        "command": "TOKEN=private deploy --api-key secret src/main.rs"
                    })),
            ),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.detail.as_deref()
                    == Some("TOKEN=[redacted] deploy --api-key [redacted] src/main.rs")
                    && activity.details == [ActivityDetail::code(
                        "Ran",
                        "TOKEN=[redacted] deploy --api-key [redacted] src/main.rs"
                    )]
        ));
        let retained = tool_calls["tool-1"]
            .raw_input
            .as_ref()
            .expect("sanitized command preview");
        assert_eq!(
            retained.get("command").and_then(serde_json::Value::as_str),
            Some("TOKEN=[redacted] deploy --api-key [redacted] src/main.rs")
        );
        assert!(!retained.to_string().contains("private"));
        assert!(!retained.to_string().contains("secret"));

        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "tool-1",
                ToolCallUpdateFields::new().status(ToolCallStatus::Completed),
            )),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.status == ActivityStatus::Completed
                    && activity.detail.as_deref()
                        == Some("TOKEN=[redacted] deploy --api-key [redacted] src/main.rs")
        ));
    }

    #[test]
    fn advertised_session_modes_become_permission_settings() {
        let modes = SessionModeState::new(
            "default",
            vec![
                SessionMode::new("default", "Manual")
                    .description("Ask before sensitive operations"),
                SessionMode::new("bypassPermissions", "Bypass Permissions")
                    .description("Run tools without approval prompts"),
            ],
        );
        let catalog = settings_catalog(&[], Some(&modes), Some("bypassPermissions"));
        assert_eq!(catalog.permissions.len(), 2);
        assert_eq!(catalog.permissions[0].value, "default");
        assert_eq!(catalog.permissions[0].label, "Manual");
        assert_eq!(catalog.permissions[1].value, "bypassPermissions");
        assert_eq!(
            catalog.default_permissions.as_deref(),
            Some("bypassPermissions")
        );
        assert_eq!(
            catalog.permissions[1].description.as_deref(),
            Some("Run tools without approval prompts")
        );
        let unavailable = settings_catalog(&[], None, Some("bypassPermissions"));
        assert!(unavailable.permissions.is_empty());
        assert_eq!(unavailable.default_permissions, None);
    }

    #[test]
    fn mode_config_options_replace_stale_legacy_mode_state() {
        use agent_client_protocol::schema::v1::{
            SessionConfigOption, SessionConfigOptionCategory, SessionConfigSelectOption,
        };

        let legacy = SessionModeState::new(
            "auto",
            vec![
                SessionMode::new("default", "Manual"),
                SessionMode::new("auto", "Auto"),
            ],
        );
        let config = SessionConfigOption::select(
            "mode",
            "Mode",
            "default",
            vec![SessionConfigSelectOption::new("default", "Manual")],
        )
        .category(SessionConfigOptionCategory::Mode);

        let reconciled = session_modes(&[config], Some(&legacy)).expect("mode state");
        assert_eq!(reconciled.current_mode_id.to_string(), "default");
        assert_eq!(reconciled.available_modes.len(), 1);
        assert_eq!(reconciled.available_modes[0].id.to_string(), "default");
    }

    #[test]
    fn native_tool_names_map_to_human_activity_without_exposing_identifiers() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCall(
                ToolCall::new("tool-1", "search_web")
                    .kind(ToolKind::Other)
                    .status(ToolCallStatus::InProgress),
            ),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.kind == ActivitySemanticKind::Search
                    && activity.title == "Searching the web"
                    && activity.detail.is_none()
        ));
        assert_eq!(tool_calls["tool-1"].title, "Searching the web");
    }

    #[test]
    fn retained_tool_state_is_count_bounded_and_payload_free() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        for index in 0..=MAX_RETAINED_TOOL_CALLS {
            session_update_events(
                &turn_id,
                &mut tool_calls,
                SessionUpdate::ToolCall(
                    ToolCall::new(format!("tool-{index}"), "x".repeat(1_000))
                        .status(ToolCallStatus::InProgress)
                        .raw_input(serde_json::json!({ "token": "must-not-be-retained" }))
                        .raw_output(serde_json::json!({ "secret": "must-not-be-retained" })),
                ),
            );
        }

        assert_eq!(tool_calls.len(), MAX_RETAINED_TOOL_CALLS);
        assert!(tool_calls.values().all(|call| {
            call.raw_input.is_none()
                && call.raw_output.is_none()
                && call.content.is_empty()
                && call.meta.is_none()
                && call.title == "Using an agent tool"
        }));
    }

    #[test]
    fn tool_call_updates_emit_complete_replaceable_snapshots() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCall(
                ToolCall::new("tool-1", "Run focused checks")
                    .kind(ToolKind::Execute)
                    .status(ToolCallStatus::Pending)
                    .locations(vec![ToolCallLocation::new("/workspace")]),
            ),
        );
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "tool-1",
                ToolCallUpdateFields::new()
                    .title("Run bridge tests")
                    .status(ToolCallStatus::Completed),
            )),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }]
                if activity.activity_id == "tool-1"
                    && activity.kind == ActivitySemanticKind::Execute
                    && activity.status == ActivityStatus::Completed
                    && activity.title == "Running command"
                    && activity.paths == [std::path::PathBuf::from("/workspace")]
                    && activity.detail.as_deref() == Some("Run focused checks")
        ));
    }

    #[test]
    fn incomplete_first_acp_patch_does_not_invent_an_activity_snapshot() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "tool-1",
                ToolCallUpdateFields::new().status(ToolCallStatus::InProgress),
            )),
        );
        assert!(events.is_empty());
    }

    #[test]
    fn maps_stable_acp_plan_as_a_replace_all_snapshot() {
        let turn_id = TurnId::new("turn-1").expect("turn id");
        let mut tool_calls = ToolCallSnapshots::new();
        let events = session_update_events(
            &turn_id,
            &mut tool_calls,
            SessionUpdate::Plan(Plan::new(vec![
                PlanEntry::new(
                    "Inspect",
                    PlanEntryPriority::High,
                    PlanEntryStatus::Completed,
                ),
                PlanEntry::new(
                    "Implement",
                    PlanEntryPriority::Medium,
                    PlanEntryStatus::InProgress,
                ),
            ])),
        );
        assert_eq!(
            events,
            vec![AgentEvent::PlanUpdated {
                turn_id,
                explanation: None,
                steps: vec![
                    PlanStep {
                        text: "Inspect".to_string(),
                        status: PlanStepStatus::Completed,
                    },
                    PlanStep {
                        text: "Implement".to_string(),
                        status: PlanStepStatus::InProgress,
                    },
                ],
            }]
        );
    }

    fn thought(text: &str, message: &str) -> SessionUpdate {
        SessionUpdate::AgentThoughtChunk(
            agent_client_protocol::schema::v1::ContentChunk::new(ContentBlock::Text(
                TextContent::new(text),
            ))
            .message_id(agent_client_protocol::schema::v1::MessageId::new(
                message.to_string(),
            )),
        )
    }

    #[test]
    fn thought_text_flows_as_one_reasoning_activity_per_block() {
        let turn = TurnId::new("turn-1").unwrap();
        let mut stream = StreamState::new(true);
        let first = stream_events(&turn, &mut stream, thought("let me ", "m1"));
        assert!(matches!(
            first.as_slice(),
            [
                AgentEvent::ActivityUpsert { activity, .. },
                AgentEvent::ActivityTextDelta { delta, stream: ActivityTextStream::Summary, .. },
            ] if activity.kind == ActivitySemanticKind::Think
                && activity.status == ActivityStatus::InProgress
                && delta == "let me "
        ));
        let second = stream_events(&turn, &mut stream, thought("think", "m1"));
        assert!(matches!(
            second.as_slice(),
            [AgentEvent::ActivityTextDelta { delta, .. }] if delta == "think"
        ));
        let next_block = stream_events(&turn, &mut stream, thought("again", "m2"));
        assert!(matches!(
            next_block.as_slice(),
            [
                AgentEvent::ActivityUpsert { activity, .. },
                AgentEvent::ActivityUpsert { activity: opened, .. },
                AgentEvent::ActivityTextDelta { .. },
            ] if activity.status == ActivityStatus::Completed
                && activity.reasoning_content == ["let me think"]
                && opened.activity_id != activity.activity_id
        ));
        let text = stream_events(
            &turn,
            &mut stream,
            SessionUpdate::AgentMessageChunk(agent_client_protocol::schema::v1::ContentChunk::new(
                ContentBlock::Text(TextContent::new("done")),
            )),
        );
        assert!(matches!(
            text.as_slice(),
            [
                AgentEvent::ActivityUpsert { activity, .. },
                AgentEvent::AgentTextDelta { .. },
            ] if activity.reasoning_content == ["again"]
        ));
        assert!(stream.close_thought(&turn).is_none());
    }

    #[test]
    fn tool_details_survive_status_only_updates_and_read_exit_codes() {
        let turn = TurnId::new("turn-1").unwrap();
        let mut stream = StreamState::new(true);
        stream_events(
            &turn,
            &mut stream,
            SessionUpdate::ToolCall(ToolCall::new("t1", "shell").kind(ToolKind::Execute)),
        );
        stream_events(
            &turn,
            &mut stream,
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "t1",
                ToolCallUpdateFields::new()
                    .title("false")
                    .status(ToolCallStatus::InProgress)
                    .raw_input(serde_json::json!({"command": "false", "cwd": "/w"})),
            )),
        );
        let events = stream_events(
            &turn,
            &mut stream,
            SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
                "t1",
                ToolCallUpdateFields::new()
                    .status(ToolCallStatus::Completed)
                    .content(vec![ToolCallContent::from("(no output)")])
                    .raw_output(serde_json::json!({"metadata": {"exit": 1}})),
            )),
        );
        let [AgentEvent::ActivityUpsert { activity, .. }] = events.as_slice() else {
            panic!("expected one snapshot");
        };
        let detail: ToolDetail =
            serde_json::from_str(activity.verbose_payload.as_deref().unwrap()).unwrap();
        assert_eq!(detail.exit_code, Some(1));
        assert_eq!(detail.output.as_deref(), Some("(no output)"));
        assert_eq!(detail.cwd, Some(PathBuf::from("/w")));
        assert_eq!(detail.raw_input["command"], "false");
        assert!(stream.details.as_ref().unwrap().is_empty());
    }

    #[test]
    fn legacy_streams_collect_no_tool_details() {
        let turn = TurnId::new("turn-1").unwrap();
        let mut stream = StreamState::new(false);
        let events = stream_events(
            &turn,
            &mut stream,
            SessionUpdate::ToolCall(
                ToolCall::new("t1", "read")
                    .kind(ToolKind::Read)
                    .raw_input(serde_json::json!({"path": "/a"})),
            ),
        );
        assert!(matches!(
            events.as_slice(),
            [AgentEvent::ActivityUpsert { activity, .. }] if activity.verbose_payload.is_none()
        ));
    }

    #[test]
    fn file_diffs_prefer_the_protocol_then_fall_back_to_raw_input() {
        let detail = ToolDetail {
            raw_input: serde_json::json!({"path": "/a", "oldString": "x", "newString": "y"}),
            ..ToolDetail::default()
        };
        assert_eq!(
            detail.file_diffs(),
            [ToolDiff {
                path: "/a".into(),
                old_text: Some("x".into()),
                new_text: "y".into(),
            }]
        );
        let write = ToolDetail {
            raw_input: serde_json::json!({"path": "/n", "content": "x\n"}),
            ..ToolDetail::default()
        };
        assert_eq!(unified_diff(None, "x\n"), "@@ -1,0 +1,1 @@\n+x\n");
        assert_eq!(write.file_diffs()[0].old_text, None);
        assert_eq!(
            unified_diff(Some("a\nb\nc\n"), "a\nB\nc\n"),
            "@@ -2,1 +2,1 @@\n-b\n+B\n"
        );
    }

    #[test]
    fn distinguishes_token_and_turn_limits_from_completion() {
        assert_eq!(turn_outcome(StopReason::EndTurn), TurnOutcome::Completed);
        assert_eq!(turn_outcome(StopReason::MaxTokens), TurnOutcome::TokenLimit);
        assert_eq!(
            turn_outcome(StopReason::MaxTurnRequests),
            TurnOutcome::TurnLimit
        );
    }
}

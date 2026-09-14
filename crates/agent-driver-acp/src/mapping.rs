use std::collections::HashMap;

use agent_client_protocol::schema::v1::{
    ContentBlock, PermissionOption, PermissionOptionKind, PlanEntryStatus,
    RequestPermissionRequest, SessionUpdate, StopReason, ToolCall, ToolCallContent,
    ToolCallLocation, ToolCallStatus, ToolCallUpdate, ToolKind,
};
use inline_agent_bridge::{
    ActivitySemanticKind, ActivityStatus, ActivityUpsert, AgentEvent, ApprovalOption,
    DriverCommand, DriverModelOption, DriverSettingOption, DriverSettingsCatalog, FileChange,
    PlanStep, PlanStepStatus, TurnId, TurnOutcome, native_tool_activity, sanitize_visible_command,
};

const MAX_PLAN_STEPS: usize = 32;
const MAX_PLAN_TEXT_CHARS: usize = 512;
const MAX_PERMISSION_OPTIONS: usize = 7;
const MAX_PROVIDER_OPTION_ID_BYTES: usize = 128;
const MAX_PROVIDER_OPTION_LABEL_CHARS: usize = 80;
const MAX_RETAINED_TOOL_CALLS: usize = 64;
const MAX_RETAINED_TOOL_CALL_ID_BYTES: usize = 256;
const MAX_RETAINED_TOOL_LOCATIONS: usize = 8;
const MAX_RETAINED_TOOL_PATH_BYTES: usize = 1_024;
pub(crate) type ToolCallSnapshots = HashMap<String, ToolCall>;

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
        "bash" | "command" | "execute" | "run command" | "running command" | "terminal"
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
        SessionUpdate::AgentThoughtChunk(_) => vec![activity(turn_id, "Thinking…")],
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

    let command = if activity_kind(call.kind) == ActivitySemanticKind::Execute {
        command_preview(call.raw_input.as_ref()).or_else(|| command_title_preview(&call.title))
    } else {
        None
    };
    call.title = native_tool_activity(&call.title, activity_kind(call.kind))
        .title
        .to_string();
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
        presentation.title,
    )
    // ACP's raw title, input, output, and content can carry sensitive tool data.
    // Only semantic labels, structured status/locations, and the bridge's
    // sanitized bounded command preview reach chat progress.
    .map(|activity| {
        let activity = if presentation.kind == ActivitySemanticKind::Execute {
            match command_preview(call.raw_input.as_ref())
                .or_else(|| command_title_preview(&call.title))
            {
                Some(command) => activity.with_detail(command),
                None => activity,
            }
        } else {
            activity
        };
        activity.with_paths(call.locations.iter().map(|location| location.path.clone()))
    })
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
        StopReason::EndTurn | StopReason::MaxTokens | StopReason::MaxTurnRequests => {
            TurnOutcome::Completed
        }
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
            AvailableCommand::new("Bad-Command", "Unsafe name"),
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
}

use std::collections::BTreeSet;
use std::path::{Component, Path};
use std::time::Duration;

use crate::{ActivitySemanticKind, FileChange};

pub const WORKING_STATUS: &str = "Working...";
pub const WORKING_CONTINUED_STATUS: &str = "Working... · continued";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PresentationUpdate {
    Edit(String),
    Final(String),
}

/// Controls whether an update observes the ordinary stream edit interval.
/// Attention and terminal states are intentionally provider-neutral: drivers
/// report facts and the bridge decides which Inline updates are urgent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum UpdatePriority {
    #[default]
    Ordinary,
    Attention,
    Terminal,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum VisibilityMode {
    #[default]
    Normal,
    Verbose,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivityKind {
    Looking,
    Editing,
    Executing,
    RunningChecks,
    WaitingForApproval,
    ChecksFailed,
    ActivityFailed,
    Stopping,
    Retrying,
}

/// Provider-neutral activity facts. Optional detail is only projected in
/// Verbose mode and is still sanitized and bounded before it reaches Inline.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SemanticActivity {
    pub kind: ActivityKind,
    pub target: Option<String>,
    pub file_count: Option<usize>,
    pub command: Option<String>,
    pub outcome: Option<String>,
    pub active_count: Option<usize>,
}

impl SemanticActivity {
    pub fn new(kind: ActivityKind) -> Self {
        Self {
            kind,
            target: None,
            file_count: None,
            command: None,
            outcome: None,
            active_count: None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct VisibilityPolicy;

impl VisibilityPolicy {
    pub fn render(&self, mode: VisibilityMode, activity: &SemanticActivity) -> String {
        if matches!(mode, VisibilityMode::Normal) {
            return WORKING_STATUS.to_string();
        }
        let base = match activity.kind {
            ActivityKind::Looking => "Looking through the code…".to_string(),
            ActivityKind::Editing => match activity.file_count {
                Some(1) => "Editing 1 file…".to_string(),
                Some(count) => format!("Editing {count} files…"),
                None => "Editing files…".to_string(),
            },
            ActivityKind::Executing => "Running a command…".to_string(),
            ActivityKind::RunningChecks => "Running focused checks…".to_string(),
            ActivityKind::WaitingForApproval => "Waiting for approval…".to_string(),
            ActivityKind::ChecksFailed => "Checks failed; checking the failure…".to_string(),
            ActivityKind::ActivityFailed => "A task failed; checking the failure…".to_string(),
            ActivityKind::Stopping => "Stopping…".to_string(),
            ActivityKind::Retrying => "Retrying…".to_string(),
        };
        let mut details = Vec::new();
        if let Some(target) = activity.target.as_deref().and_then(bounded_detail) {
            details.push(target);
        }
        if let Some(command) = activity
            .command
            .as_deref()
            .and_then(sanitize_visible_command)
        {
            details.push(markdown_code_span(&command));
        }
        if let Some(outcome) = activity.outcome.as_deref().and_then(bounded_detail) {
            details.push(outcome);
        }
        if details.is_empty() {
            base
        } else {
            format!("{} {}", base.trim_end_matches('…'), details.join(" · "))
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NativeToolActivity {
    pub kind: ActivitySemanticKind,
    pub title: &'static str,
}

/// Converts native tool identifiers or provider titles into bounded semantic
/// activity. The provider string is used only for classification and is never
/// returned, so tool arguments or provider-specific identifiers cannot cross
/// the visible activity boundary.
pub fn native_tool_activity(
    provider_label: &str,
    fallback_kind: ActivitySemanticKind,
) -> NativeToolActivity {
    let normalized = provider_label
        .chars()
        .take(128)
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character.to_ascii_lowercase()
            } else {
                ' '
            }
        })
        .collect::<String>();
    let words = normalized.split_whitespace().collect::<Vec<_>>();
    let has = |word: &str| words.contains(&word);

    if has("search") && (has("message") || has("messages")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Search,
            title: "Searching Inline messages",
        };
    }
    if has("current") && has("context") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Read,
            title: "Reading Inline context",
        };
    }
    if has("search") && (has("chat") || has("chats")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Search,
            title: "Searching Inline chats",
        };
    }
    if has("get") && (has("message") || has("messages") || has("history")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Read,
            title: "Reading Inline messages",
        };
    }
    if has("get") && has("chat") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Read,
            title: "Reading an Inline chat",
        };
    }
    if has("get") && (has("reaction") || has("reactions")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Read,
            title: "Reading message reactions",
        };
    }
    if has("list") && (has("pin") || has("pins")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Read,
            title: "Reading pinned messages",
        };
    }
    if has("create") && has("chat") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Creating an Inline chat",
        };
    }
    if has("add") && (has("reaction") || has("reactions")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Adding a reaction",
        };
    }
    if has("remove") && (has("reaction") || has("reactions")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Removing a reaction",
        };
    }
    if has("unpin") && (has("message") || has("messages")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Unpinning a message",
        };
    }
    if has("pin") && (has("message") || has("messages")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Pinning a message",
        };
    }
    if has("edit") && has("own") && (has("message") || has("messages")) {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Edit,
            title: "Editing an Inline message",
        };
    }
    if has("return") && has("attachment") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Returning an attachment",
        };
    }
    if has("update") && has("bot") && has("profile") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Updating the bot profile",
        };
    }
    if has("set") && has("presence") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Updating bot presence",
        };
    }
    if has("search") && has("web") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Search,
            title: "Searching the web",
        };
    }
    if has("switch") && has("mode") {
        return NativeToolActivity {
            kind: ActivitySemanticKind::Other,
            title: "Changing agent mode",
        };
    }

    if fallback_kind == ActivitySemanticKind::Other {
        if has("read") || has("open") || has("view") {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Read,
                title: "Reading files",
            };
        }
        if has("write") || has("edit") || has("patch") || has("apply") {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Edit,
                title: "Updating files",
            };
        }
        if has("delete") || has("remove") {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Delete,
                title: "Deleting files",
            };
        }
        if has("move") || has("rename") {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Move,
                title: "Moving files",
            };
        }
        if has("search") || has("grep") || has("glob") || has("find") || has("list") {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Search,
                title: "Searching the project",
            };
        }
        if has("fetch") || has("download") || has("browser") || has("url") || has("http") {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Fetch,
                title: "Fetching web content",
            };
        }
        if has("execute")
            || has("run")
            || has("shell")
            || has("bash")
            || has("terminal")
            || has("command")
        {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Execute,
                title: "Running command",
            };
        }
        if has("think") || has("plan") || has("reason") {
            return NativeToolActivity {
                kind: ActivitySemanticKind::Think,
                title: "Thinking",
            };
        }
    }

    NativeToolActivity {
        kind: fallback_kind,
        title: semantic_activity_title(fallback_kind),
    }
}

pub fn semantic_activity_title(kind: ActivitySemanticKind) -> &'static str {
    match kind {
        ActivitySemanticKind::Read => "Reading files",
        ActivitySemanticKind::Edit => "Updating files",
        ActivitySemanticKind::Delete => "Deleting files",
        ActivitySemanticKind::Move => "Moving files",
        ActivitySemanticKind::Search => "Searching the project",
        ActivitySemanticKind::Execute => "Running command",
        ActivitySemanticKind::Think => "Thinking",
        ActivitySemanticKind::Fetch => "Fetching web content",
        ActivitySemanticKind::Other => "Using an agent tool",
    }
}

/// Formats a provider turn duration using the compact convention used by
/// agent platforms: `59s`, `2m 05s`, or `1h 02m 09s`.
pub fn format_elapsed_compact(elapsed: Duration) -> String {
    let elapsed_seconds = elapsed.as_secs();
    if elapsed_seconds < 60 {
        return format!("{elapsed_seconds}s");
    }
    if elapsed_seconds < 3_600 {
        return format!("{}m {:02}s", elapsed_seconds / 60, elapsed_seconds % 60);
    }
    format!(
        "{}h {:02}m {:02}s",
        elapsed_seconds / 3_600,
        (elapsed_seconds % 3_600) / 60,
        elapsed_seconds % 60
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ValidationSummary {
    Passed(String),
    Failed(String),
    NotRun(String),
}

const MAX_VISIBLE_OUTPUT_BYTES: usize = 16 * 1024;
const MAX_DETAIL_BYTES: usize = 160;
const MAX_COMMAND_BYTES: usize = 512;
const MAX_CHANGED_FILES: usize = 8;
const OMITTED_OUTPUT_MARKER: &str = "\n\n[additional output omitted]";

#[derive(Clone, Debug)]
pub struct StreamingPresenter {
    source: String,
    visible: String,
    last_visible: String,
    last_edit_at_ms: u64,
    minimum_edit_interval_ms: u64,
}

impl StreamingPresenter {
    pub fn new(acknowledged_at_ms: u64, minimum_edit_interval_ms: u64) -> Self {
        Self {
            source: String::new(),
            visible: String::new(),
            last_visible: String::new(),
            last_edit_at_ms: acknowledged_at_ms,
            minimum_edit_interval_ms,
        }
    }

    pub fn push_delta(&mut self, now_ms: u64, delta: &str) -> Option<PresentationUpdate> {
        append_visible_output(&mut self.source, delta);
        self.refresh_visible();
        self.maybe_update(now_ms, UpdatePriority::Ordinary)
    }

    pub fn replace_snapshot(
        &mut self,
        now_ms: u64,
        snapshot: impl Into<String>,
    ) -> Option<PresentationUpdate> {
        self.replace_snapshot_with_priority(now_ms, snapshot, UpdatePriority::Ordinary)
    }

    pub fn replace_snapshot_with_priority(
        &mut self,
        now_ms: u64,
        snapshot: impl Into<String>,
        priority: UpdatePriority,
    ) -> Option<PresentationUpdate> {
        self.source = bounded_visible_output(&snapshot.into());
        self.refresh_visible();
        self.maybe_update(now_ms, priority)
    }

    /// Presents a temporary status without replacing the accumulated agent
    /// response. The next agent delta or terminal render restores the durable
    /// response, so approval and retry states cannot destroy streamed text.
    pub fn show_transient(
        &mut self,
        now_ms: u64,
        status: impl AsRef<str>,
        priority: UpdatePriority,
    ) -> Option<PresentationUpdate> {
        let status =
            bounded_visible_output(&stabilize_markdown(&sanitize_visible_text(status.as_ref())));
        if status.is_empty() || status == self.last_visible {
            return None;
        }
        if matches!(priority, UpdatePriority::Ordinary)
            && now_ms.saturating_sub(self.last_edit_at_ms) < self.minimum_edit_interval_ms
        {
            return None;
        }

        self.last_edit_at_ms = now_ms;
        self.last_visible.clone_from(&status);
        Some(match priority {
            UpdatePriority::Ordinary | UpdatePriority::Attention => {
                PresentationUpdate::Edit(status)
            }
            UpdatePriority::Terminal => PresentationUpdate::Final(status),
        })
    }

    pub fn flush(&mut self) -> Option<PresentationUpdate> {
        self.refresh_visible();
        if self.visible.is_empty() || self.visible == self.last_visible {
            return None;
        }
        self.last_visible.clone_from(&self.visible);
        Some(PresentationUpdate::Final(self.visible.clone()))
    }

    pub fn finalize(&mut self, final_text: impl Into<String>) -> PresentationUpdate {
        self.source = bounded_visible_output(&final_text.into());
        self.refresh_visible();
        self.last_visible.clone_from(&self.visible);
        PresentationUpdate::Final(self.visible.clone())
    }

    pub fn content(&self) -> &str {
        &self.visible
    }

    fn refresh_visible(&mut self) {
        self.visible = stabilize_markdown(&sanitize_visible_text(&self.source));
        self.visible = bounded_visible_output(&self.visible);
    }

    fn maybe_update(
        &mut self,
        now_ms: u64,
        priority: UpdatePriority,
    ) -> Option<PresentationUpdate> {
        if self.visible.is_empty() || self.visible == self.last_visible {
            return None;
        }
        if matches!(priority, UpdatePriority::Ordinary)
            && now_ms.saturating_sub(self.last_edit_at_ms) < self.minimum_edit_interval_ms
        {
            return None;
        }

        self.last_edit_at_ms = now_ms;
        self.last_visible.clone_from(&self.visible);
        Some(match priority {
            UpdatePriority::Ordinary | UpdatePriority::Attention => {
                PresentationUpdate::Edit(self.visible.clone())
            }
            UpdatePriority::Terminal => PresentationUpdate::Final(self.visible.clone()),
        })
    }
}

/// Produces the compact chat-native completion shape from provider-neutral
/// changed-file facts. Unsafe or non-relative paths are omitted.
pub fn render_completion_summary(
    introduction: &str,
    files: &[FileChange],
    validation: &ValidationSummary,
) -> String {
    let introduction = bounded_detail(introduction).unwrap_or_else(|| "Completed.".to_string());
    let mut output = introduction.trim_end_matches(['.', '!', '?']).to_string();
    output.push('.');

    let mut seen = BTreeSet::new();
    let safe_files = files
        .iter()
        .filter_map(|file| {
            let path = safe_relative_path(&file.path)?;
            seen.insert(path.clone())
                .then_some((path, file.summary.as_deref()))
        })
        .collect::<Vec<_>>();
    if !safe_files.is_empty() {
        output.push_str("\n\nChanged:\n");
        for (path, summary) in safe_files.iter().take(MAX_CHANGED_FILES) {
            output.push_str("- ");
            output.push_str(path);
            if let Some(summary) = summary.and_then(bounded_detail) {
                output.push_str(" — ");
                output.push_str(&summary);
            }
            output.push('\n');
        }
        if safe_files.len() > MAX_CHANGED_FILES {
            output.push_str(&format!(
                "- … and {} more\n",
                safe_files.len() - MAX_CHANGED_FILES
            ));
        }
        output.pop();
    }

    let (label, detail) = match validation {
        ValidationSummary::Passed(detail) => ("Checks", bounded_detail(detail)),
        ValidationSummary::Failed(detail) => ("Checks failed", bounded_detail(detail)),
        ValidationSummary::NotRun(detail) => ("Checks not run", bounded_detail(detail)),
    };
    output.push_str("\n\n");
    output.push_str(label);
    if let Some(detail) = detail {
        output.push_str(": ");
        output.push_str(detail.trim_end_matches('.'));
    }
    output.push('.');
    bounded_visible_output(&stabilize_markdown(&sanitize_visible_text(&output)))
}

fn safe_relative_path(path: &Path) -> Option<String> {
    if path.is_absolute() || path.as_os_str().is_empty() {
        return None;
    }
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return None;
    }
    bounded_detail(&path.to_string_lossy())
}

fn bounded_detail(value: &str) -> Option<String> {
    let flattened = sanitize_visible_text(value)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if flattened.is_empty() {
        return None;
    }
    Some(truncate_with_ellipsis(&flattened, MAX_DETAIL_BYTES))
}

pub fn sanitize_visible_command(value: &str) -> Option<String> {
    let flattened = sanitize_visible_text(value)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if flattened.is_empty() {
        return None;
    }
    Some(truncate_with_ellipsis(
        &redact_sensitive_command_arguments(&flattened),
        MAX_COMMAND_BYTES,
    ))
}

/// Sanitizes multiline provider text before it is copied into an Inline
/// transcript. This preserves line boundaries while applying the same
/// credential, signed-URL, and local-path redaction used for visible commands.
pub fn sanitize_visible_transcript(value: &str) -> Option<String> {
    sanitize_multiline_text(value, true)
}

/// Sanitizes diagnostic prose. Unlike command transcripts, a bare word such
/// as `token` is not an assignment: `No token found` must remain actionable.
/// Explicit assignments, headers, flags, URLs, and paths use the same scrubber.
pub fn sanitize_diagnostic_text(value: &str) -> Option<String> {
    sanitize_multiline_text(value, false)
}

fn sanitize_multiline_text(value: &str, redact_bare_values: bool) -> Option<String> {
    let sanitized = sanitize_visible_text(value);
    let redacted = sanitized
        .split('\n')
        .map(|line| redact_sensitive_transcript_line(line, redact_bare_values))
        .collect::<Vec<_>>()
        .join("\n");
    let redacted = redacted.trim();
    (!redacted.is_empty()).then(|| redacted.to_string())
}

fn redact_sensitive_transcript_line(line: &str, redact_bare_values: bool) -> String {
    let line = redact_command_arguments(line, redact_bare_values);
    for (separator_index, separator) in line
        .char_indices()
        .filter(|(_, character)| matches!(character, ':' | '='))
    {
        let name_end = line[..separator_index].trim_end().len();
        let name_start = line[..name_end]
            .char_indices()
            .rev()
            .find_map(|(index, character)| {
                matches!(character, ' ' | '\t' | '{' | '[' | '(' | ',')
                    .then_some(index + character.len_utf8())
            })
            .unwrap_or(0);
        let name = line[name_start..name_end].trim_matches(['\'', '"', '`']);
        if standalone_sensitive_assignment_name(name) {
            return format!("{}{} [redacted]", &line[..separator_index], separator);
        }
    }
    line
}

fn redact_sensitive_command_arguments(command: &str) -> String {
    redact_command_arguments(command, true)
}

fn redact_command_arguments(command: &str, redact_bare_values: bool) -> String {
    const SECRET_FLAGS: &[&str] = &[
        "--access-token",
        "--api-key",
        "--authorization",
        "--oauth2-bearer",
        "--password",
        "--proxy-user",
        "--refresh-token",
        "--secret",
        "--token",
        "--user",
        "-u",
    ];
    let mut output = Vec::new();
    let mut redact_next = false;
    let mut inspect_header_next = false;
    let mut redact_header_tail = 0_usize;
    let mut sensitive_key_waiting_for_separator = false;
    for token in shellish_command_words(command) {
        if redact_next || redact_header_tail > 0 {
            redact_next = false;
            redact_header_tail = redact_header_tail.saturating_sub(1);
            output.push("[redacted]".to_string());
            continue;
        }
        if sensitive_key_waiting_for_separator {
            sensitive_key_waiting_for_separator = false;
            let separator_token = token.trim_matches(['\'', '"', '`']);
            if let Some(separator) = separator_token
                .chars()
                .next()
                .filter(|separator| matches!(separator, ':' | '='))
            {
                let remainder =
                    separator_token[separator.len_utf8()..].trim_matches(['\'', '"', '`']);
                if remainder.is_empty() {
                    output.push(token);
                    redact_next = true;
                } else {
                    output.push(format!("{separator}[redacted]"));
                }
                continue;
            }
            if redact_bare_values {
                output.push("[redacted]".to_string());
                continue;
            }
        }
        if inspect_header_next {
            inspect_header_next = false;
            if sensitive_header_value(&token).is_some() {
                output.push("[redacted]".to_string());
                continue;
            }
        }
        let normalized = token.trim_matches(['\'', '"', '`']).to_ascii_lowercase();
        if SECRET_FLAGS.contains(&normalized.as_str()) {
            redact_next = true;
            output.push(token);
            continue;
        }
        if matches!(normalized.as_str(), "-h" | "--header") {
            inspect_header_next = true;
            output.push(token);
            continue;
        }
        if normalized.starts_with("-h")
            && !normalized.starts_with("--")
            && normalized.len() > 2
            && sensitive_header_value(&token[2..]).is_some()
        {
            output.push(format!("{}[redacted]", &token[..2]));
            continue;
        }
        if normalized.starts_with("-u") && !normalized.starts_with("--") && normalized.len() > 2 {
            output.push(format!("{}[redacted]", &token[..2]));
            continue;
        }
        let redacted_url = redact_url_credentials(&token);
        if redacted_url != token {
            output.push(redacted_url);
            continue;
        }
        if let Some((flag, value)) = token.split_once('=') {
            let normalized_flag = flag.trim_matches(['\'', '"', '`']).to_ascii_lowercase();
            if SECRET_FLAGS.contains(&normalized_flag.as_str())
                || sensitive_assignment_name(flag)
                || (normalized_flag == "--header" && sensitive_header_value(value).is_some())
            {
                output.push(format!("{flag}=[redacted]"));
                if value.trim_matches(['\'', '"', '`']).is_empty() {
                    redact_next = true;
                }
                continue;
            }
        }
        if standalone_sensitive_assignment_name(&token) {
            sensitive_key_waiting_for_separator = true;
            output.push(token);
            continue;
        }
        if let Some(tail) = sensitive_header_value(&token) {
            redact_header_tail = tail;
            output.push(if tail == 0 {
                "[redacted-header]".to_string()
            } else {
                token
            });
            continue;
        }
        let token = redact_url_credentials(&token);
        output.push(redact_absolute_local_path(&token));
    }
    output.join(" ")
}

fn sensitive_header_value(value: &str) -> Option<usize> {
    let normalized = value.trim_matches(['\'', '"', '`']).to_ascii_lowercase();
    for (name, trailing_words) in [
        ("authorization", 2),
        ("proxy-authorization", 2),
        ("cookie", 1),
        ("set-cookie", 1),
        ("password", 1),
        ("secret", 1),
        ("token", 1),
        ("access-token", 1),
        ("refresh-token", 1),
        ("api-key", 1),
        ("x-api-key", 1),
        ("x-auth-token", 1),
    ] {
        let prefix = format!("{name}:");
        if normalized == prefix {
            return Some(trailing_words);
        }
        if normalized.starts_with(&prefix) {
            let remainder = &normalized[prefix.len()..];
            if matches!(name, "authorization" | "proxy-authorization")
                && matches!(remainder, "basic" | "bearer" | "token")
            {
                return Some(1);
            }
            return Some(0);
        }
    }
    if let Some((name, remainder)) = normalized.split_once(':') {
        let name = name.trim_matches(|character| {
            matches!(character, '\'' | '"' | '`' | '{' | '[' | '(' | ',' | ' ')
        });
        let name = name.trim_end_matches(['\'', '"', '`']);
        if sensitive_assignment_name(name) {
            let remainder = remainder.trim_matches(|character| {
                matches!(character, '\'' | '"' | '`' | '}' | ']' | ')' | ',' | ' ')
            });
            return Some(usize::from(remainder.is_empty()));
        }
    }
    None
}

fn shellish_command_words(command: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in command.chars() {
        if escaped {
            word.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' {
            word.push(character);
            escaped = true;
            continue;
        }
        if let Some(active_quote) = quote {
            word.push(character);
            if character == active_quote {
                quote = None;
            }
            continue;
        }
        if matches!(character, '\'' | '"') {
            quote = Some(character);
            word.push(character);
        } else if character.is_whitespace() {
            if !word.is_empty() {
                words.push(std::mem::take(&mut word));
            }
        } else {
            word.push(character);
        }
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

fn redact_absolute_local_path(token: &str) -> String {
    if parse_url_span(token).is_some() {
        return token.to_string();
    }
    let boundary_before = |index: usize| {
        index == 0
            || token[..index].chars().next_back().is_some_and(|previous| {
                matches!(
                    previous,
                    '=' | ':' | '@' | '\'' | '"' | '`' | '(' | '[' | '{' | '>' | '<'
                )
            })
    };
    let path_start = token
        .find("file:///")
        .into_iter()
        .chain(
            token
                .match_indices("\\\\")
                .filter_map(|(index, _)| boundary_before(index).then_some(index)),
        )
        .chain(token.char_indices().filter_map(|(index, character)| {
            let suffix = &token[index..];
            ((character == '/' && boundary_before(index))
                || (character == '~' && suffix.starts_with("~/") && boundary_before(index))
                || (character.is_ascii_alphabetic()
                    && suffix
                        .as_bytes()
                        .get(1..3)
                        .is_some_and(|next| matches!(next, [b':', b'/'] | [b':', b'\\']))
                    && boundary_before(index)))
            .then_some(index)
        }))
        .min();
    let Some(path_start) = path_start else {
        return token.to_string();
    };
    let suffix_start = token[path_start..]
        .char_indices()
        .rev()
        .find_map(|(offset, character)| {
            (!matches!(character, '\'' | '"' | '`' | ')' | ']' | '}' | ',' | ';'))
                .then_some(path_start + offset + character.len_utf8())
        })
        .unwrap_or(path_start);
    format!(
        "{}[local-path]{}",
        &token[..path_start],
        &token[suffix_start..]
    )
}

fn sensitive_assignment_name(name: &str) -> bool {
    let normalized = name
        .trim_matches(['\'', '"', '`'])
        .replace('-', "_")
        .to_ascii_lowercase();
    let exact_or_suffix = [
        "access_token",
        "api_key",
        "authorization",
        "password",
        "refresh_token",
        "secret",
        "token",
    ]
    .iter()
    .any(|component| normalized == *component || normalized.ends_with(&format!("_{component}")));
    exact_or_suffix
        || normalized.contains("secret")
        || normalized.contains("password")
        || normalized.contains("credential")
        || normalized.ends_with("access_key")
        || normalized.ends_with("private_key")
        || normalized.ends_with("auth_token")
        || normalized.ends_with("cookie")
        || normalized.ends_with("otp")
}

fn standalone_sensitive_assignment_name(name: &str) -> bool {
    let name = name.trim_matches(|character| {
        matches!(
            character,
            '\'' | '"' | '`' | '{' | '}' | '[' | ']' | '(' | ')' | ',' | ' '
        )
    });
    !name.is_empty()
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '_' | '-'))
        && sensitive_assignment_name(name)
}

fn redact_url_credentials(token: &str) -> String {
    let Some((start, url_end, mut parsed)) = parse_url_span(token) else {
        return token.to_string();
    };
    if matches!(
        parsed.scheme(),
        "file" | "sqlite" | "vscode" | "vscode-insiders"
    ) {
        return format!("{}[local-path]{}", &token[..start], &token[url_end..]);
    }
    let sensitive = !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some();
    if !sensitive {
        return token.to_string();
    }
    let _ = parsed.set_username("");
    let _ = parsed.set_password(None);
    parsed.set_query(None);
    parsed.set_fragment(None);
    format!(
        "{}{}?[redacted]{}",
        &token[..start],
        parsed,
        &token[url_end..]
    )
}

fn parse_url_span(token: &str) -> Option<(usize, usize, url::Url)> {
    let delimiter = token.find("://")?;
    let mut start = delimiter;
    for (index, character) in token[..delimiter].char_indices().rev() {
        if character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.') {
            start = index;
        } else {
            break;
        }
    }
    if start == delimiter
        || !token[start..delimiter]
            .chars()
            .next()
            .is_some_and(|character| character.is_ascii_alphabetic())
    {
        return None;
    }
    let url_end = token[start..]
        .char_indices()
        .rev()
        .find_map(|(offset, character)| {
            (!matches!(character, '\'' | '"' | '`' | ')' | ']' | '}' | ',' | ';'))
                .then_some(start + offset + character.len_utf8())
        })
        .unwrap_or(start);
    let parsed = url::Url::parse(&token[start..url_end]).ok()?;
    Some((start, url_end, parsed))
}

fn markdown_code_span(value: &str) -> String {
    if value.contains('`') {
        format!("`` {value} ``")
    } else {
        format!("`{value}`")
    }
}

fn truncate_with_ellipsis(value: &str, maximum_bytes: usize) -> String {
    if value.len() <= maximum_bytes {
        return value.to_string();
    }
    let maximum_content = maximum_bytes.saturating_sub('…'.len_utf8());
    let boundary = previous_char_boundary(value, maximum_content);
    format!("{}…", value[..boundary].trim_end())
}

fn append_visible_output(target: &mut String, delta: &str) {
    if target.ends_with(OMITTED_OUTPUT_MARKER) {
        return;
    }
    if target.len().saturating_add(delta.len()) <= MAX_VISIBLE_OUTPUT_BYTES {
        target.push_str(delta);
        return;
    }

    let content_limit = MAX_VISIBLE_OUTPUT_BYTES.saturating_sub(OMITTED_OUTPUT_MARKER.len());
    if target.len() < content_limit {
        let remaining = content_limit - target.len();
        let boundary = previous_char_boundary(delta, remaining);
        target.push_str(&delta[..boundary]);
    } else {
        target.truncate(previous_char_boundary(target, content_limit));
    }
    target.push_str(OMITTED_OUTPUT_MARKER);
}

fn bounded_visible_output(value: &str) -> String {
    if value.len() <= MAX_VISIBLE_OUTPUT_BYTES {
        return value.to_string();
    }
    let content_limit = MAX_VISIBLE_OUTPUT_BYTES.saturating_sub(OMITTED_OUTPUT_MARKER.len());
    let boundary = previous_char_boundary(value, content_limit);
    format!("{}{}", &value[..boundary], OMITTED_OUTPUT_MARKER)
}

fn previous_char_boundary(value: &str, maximum: usize) -> usize {
    let mut boundary = maximum.min(value.len());
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    boundary
}

fn sanitize_visible_text(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\u{1b}' {
            match chars.next() {
                Some('[') => {
                    for control in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&control) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    let mut previous_escape = false;
                    for control in chars.by_ref() {
                        if control == '\u{7}' || (previous_escape && control == '\\') {
                            break;
                        }
                        previous_escape = control == '\u{1b}';
                    }
                }
                Some(_) | None => {}
            }
            continue;
        }
        match character {
            '\r' if chars.peek() == Some(&'\n') => {}
            '\n' | '\t' => output.push(character),
            control if control.is_control() => {}
            _ => output.push(character),
        }
    }
    output
}

fn stabilize_markdown(value: &str) -> String {
    let mut open_fence: Option<&str> = None;
    for line in value.lines() {
        let trimmed = line.trim_start();
        let marker = if trimmed.starts_with("```") {
            Some("```")
        } else if trimmed.starts_with("~~~") {
            Some("~~~")
        } else {
            None
        };
        if let Some(marker) = marker {
            open_fence = if open_fence == Some(marker) {
                None
            } else if open_fence.is_none() {
                Some(marker)
            } else {
                open_fence
            };
        }
    }
    match open_fence {
        Some(marker) => format!("{}\n{marker}", value.trim_end()),
        None => value.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[derive(Default)]
    struct FakeClock(u64);

    impl FakeClock {
        fn advance(&mut self, milliseconds: u64) -> u64 {
            self.0 += milliseconds;
            self.0
        }
    }

    #[test]
    fn coalesces_deltas_until_edit_interval_with_fake_clock() {
        let mut clock = FakeClock::default();
        let mut presenter = StreamingPresenter::new(clock.0, 750);
        assert_eq!(presenter.push_delta(clock.advance(100), "Hel"), None);
        assert_eq!(presenter.push_delta(clock.advance(400), "lo"), None);
        assert_eq!(
            presenter.push_delta(clock.advance(250), " world"),
            Some(PresentationUpdate::Edit("Hello world".to_string()))
        );
    }

    #[test]
    fn attention_and_terminal_states_bypass_throttle() {
        let mut presenter = StreamingPresenter::new(0, 750);
        assert_eq!(presenter.replace_snapshot(10, "Looking…"), None);
        assert_eq!(
            presenter.replace_snapshot_with_priority(
                11,
                "Waiting for approval…",
                UpdatePriority::Attention,
            ),
            Some(PresentationUpdate::Edit(
                "Waiting for approval…".to_string()
            ))
        );
        assert_eq!(
            presenter.replace_snapshot_with_priority(12, "Stopped.", UpdatePriority::Terminal),
            Some(PresentationUpdate::Final("Stopped.".to_string()))
        );
    }

    #[test]
    fn skips_unchanged_attention_snapshot() {
        let mut presenter = StreamingPresenter::new(0, 750);
        assert!(
            presenter
                .replace_snapshot_with_priority(1, "Waiting…", UpdatePriority::Attention)
                .is_some()
        );
        assert_eq!(
            presenter.replace_snapshot_with_priority(2, "Waiting…", UpdatePriority::Attention),
            None
        );
    }

    #[test]
    fn transient_status_does_not_replace_streamed_agent_content() {
        let mut presenter = StreamingPresenter::new(0, 0);
        assert_eq!(
            presenter.push_delta(1, "I found the issue."),
            Some(PresentationUpdate::Edit("I found the issue.".to_string()))
        );
        assert_eq!(
            presenter.show_transient(2, "Waiting for approval…", UpdatePriority::Attention),
            Some(PresentationUpdate::Edit(
                "Waiting for approval…".to_string()
            ))
        );
        assert_eq!(presenter.content(), "I found the issue.");
        assert_eq!(
            presenter.push_delta(3, " Applying the fix."),
            Some(PresentationUpdate::Edit(
                "I found the issue. Applying the fix.".to_string()
            ))
        );
    }

    #[test]
    fn normal_and_verbose_projection_have_stable_semantics() {
        let activity = SemanticActivity {
            kind: ActivityKind::RunningChecks,
            target: Some("crates/agent-bridge".to_string()),
            file_count: None,
            command: Some("cargo test".to_string()),
            outcome: None,
            active_count: None,
        };
        assert_eq!(
            VisibilityPolicy.render(VisibilityMode::Normal, &activity),
            "Working..."
        );
        assert_eq!(
            VisibilityPolicy.render(VisibilityMode::Verbose, &activity),
            "Running focused checks crates/agent-bridge · `cargo test`"
        );
    }

    #[test]
    fn visible_commands_redact_secret_flags_assignments_and_signed_urls() {
        let command = sanitize_visible_command(
            "TOKEN=private deploy --api-key secret --refresh-token=other /Users/alice/dev/inline/src/main.rs --cwd=/private/tmp/project file:///Users/alice/secret https://example.com/file?signature=private relative/path.rs",
        )
        .expect("visible command");
        assert!(command.contains("TOKEN=[redacted]"));
        assert!(command.contains("--api-key [redacted]"));
        assert!(command.contains("--refresh-token=[redacted]"));
        assert!(command.contains("https://example.com/file?[redacted]"));
        assert_eq!(command.matches("[local-path]").count(), 3);
        assert!(command.contains("relative/path.rs"));
        assert!(!command.contains("/Users/alice"));
        assert!(!command.contains("/private/tmp"));
        assert!(!command.contains("private"));
        assert!(!command.contains("other"));
    }

    #[test]
    fn visible_commands_redact_quoted_values_paths_and_common_secret_environment_names() {
        let command = sanitize_visible_command(
            "AWS_SECRET_ACCESS_KEY='private value' deploy --password \"two words\" --cwd '/Users/alice/My Project' relative/path.rs",
        )
        .expect("visible command");
        assert!(command.contains("AWS_SECRET_ACCESS_KEY=[redacted]"));
        assert!(command.contains("--password [redacted]"));
        assert!(command.contains("--cwd '[local-path]'"));
        assert!(command.contains("relative/path.rs"));
        for secret in [
            "private",
            "value",
            "two words",
            "/Users/alice",
            "My Project",
        ] {
            assert!(!command.contains(secret));
        }
    }

    #[test]
    fn visible_commands_and_transcripts_redact_sensitive_headers_and_host_paths() {
        let command = sanitize_visible_command(
            "curl -H 'Authorization: Bearer secret-token' -HAuthorization:compact-secret --header='Cookie: session=private' -u user:password --oauth2-bearer oauth-secret --client-secret client-secret-value --aws-secret-access-key aws-secret-value AWS_SECRET_ACCESS_KEY bare-secret-value C:\\Users\\mo\\secret.txt ~/private.txt https://example.com",
        )
        .expect("visible command");
        assert!(command.contains("-H [redacted]"));
        assert!(command.contains("-H[redacted]"));
        assert!(command.contains("--header=[redacted]"));
        assert!(command.contains("-u [redacted]"));
        assert!(command.contains("--oauth2-bearer [redacted]"));
        assert_eq!(command.matches("[local-path]").count(), 2);
        for secret in [
            "secret-token",
            "compact-secret",
            "session=private",
            "user:password",
            "oauth-secret",
            "client-secret-value",
            "aws-secret-value",
            "bare-secret-value",
            "C:\\Users",
            "~/private",
        ] {
            assert!(!command.contains(secret));
        }

        let transcript = sanitize_visible_transcript(
            "Request\nAuthorization: Bearer historical-secret\nAuthorization:Bearer compact-historical-secret\nCookie: a=secret; b=also-secret\nPassword: two secret words\nToken: token-value\nSecret: secret-value\nAPI-Key: key-value\nANTHROPIC_API_KEY: anthropic-secret\nAWS_SECRET_ACCESS_KEY: aws-secret\naccess_token: access-secret\n{\"api_key\": \"json secret words\", \"safe\": \"must-not-survive\"}\nANTHROPIC_API_KEY = \"toml-secret\"\n\"api_key\" : \"pretty-json-secret\"\nANTHROPIC_API_KEY= \"empty-inline-secret\"\nAWS_SECRET_ACCESS_KEY =\"attached-separator-secret\"\nFix /Users/alice/private TOKEN=hidden-after-path\ncwd:/Users/alice/dev/private\nfile=@/Users/alice/other\nUNC: \\\\server\\share\\private\nExtended: \\\\?\\C:\\Users\\alice\\private\nSQLite: sqlite:///Users/alice/private.db\nEditor: vscode://file/Users/alice/private.rs\nFTP: ftp://user:password@host/path\nDB: postgresql://user:password@localhost/private?sslsecret=hidden\nURL: https://example.com/file?signature=hidden",
        )
        .expect("visible transcript");
        assert_eq!(transcript.matches("Authorization: [redacted]").count(), 2);
        assert!(transcript.contains("Cookie: [redacted]"));
        assert!(transcript.contains("Password: [redacted]"));
        assert!(transcript.contains("Token: [redacted]"));
        assert!(transcript.contains("Secret: [redacted]"));
        assert!(transcript.contains("API-Key: [redacted]"));
        assert!(transcript.contains("ANTHROPIC_API_KEY: [redacted]"));
        assert!(transcript.contains("AWS_SECRET_ACCESS_KEY: [redacted]"));
        assert!(transcript.contains("access_token: [redacted]"));
        assert!(transcript.contains("{\"api_key\": [redacted]"));
        assert!(transcript.contains("ANTHROPIC_API_KEY = [redacted]"));
        assert!(transcript.contains("\"api_key\" : [redacted]"));
        assert!(transcript.contains("ANTHROPIC_API_KEY= [redacted]"));
        assert!(transcript.contains("AWS_SECRET_ACCESS_KEY = [redacted]"));
        assert!(transcript.contains("Fix [local-path] TOKEN= [redacted]"));
        assert!(transcript.contains("cwd:[local-path]"));
        assert!(transcript.contains("file=@[local-path]"));
        assert!(transcript.contains("UNC: [local-path]"));
        assert!(transcript.contains("Extended: [local-path]"));
        assert!(transcript.contains("SQLite: [local-path]"));
        assert!(transcript.contains("Editor: [local-path]"));
        assert!(transcript.contains("ftp://host/path?[redacted]"));
        assert!(
            transcript.contains("postgresql://localhost/private?[redacted]"),
            "{transcript}"
        );
        assert!(transcript.contains("https://example.com/file?[redacted]"));
        for secret in [
            "historical-secret",
            "compact-historical-secret",
            "also-secret",
            "secret words",
            "must-not-survive",
            "token-value",
            "secret-value",
            "key-value",
            "anthropic-secret",
            "aws-secret",
            "access-secret",
            "json-secret",
            "toml-secret",
            "pretty-json-secret",
            "empty-inline-secret",
            "attached-separator-secret",
            "hidden-after-path",
            "/Users/alice",
            "server\\share",
            "?\\C:\\Users",
            "user:password",
            "sslsecret=hidden",
            "signature=hidden",
        ] {
            assert!(!transcript.contains(secret));
        }
    }

    #[test]
    fn native_tool_identifiers_map_to_semantic_secret_free_activity() {
        assert_eq!(
            native_tool_activity("search_web", ActivitySemanticKind::Other),
            NativeToolActivity {
                kind: ActivitySemanticKind::Search,
                title: "Searching the web",
            }
        );
        assert_eq!(
            native_tool_activity("inline_get_current_context", ActivitySemanticKind::Other),
            NativeToolActivity {
                kind: ActivitySemanticKind::Read,
                title: "Reading Inline context",
            }
        );
        assert_eq!(
            native_tool_activity(
                "cargo test --token must-not-appear",
                ActivitySemanticKind::Execute,
            ),
            NativeToolActivity {
                kind: ActivitySemanticKind::Execute,
                title: "Running command",
            }
        );
        for (name, title) in [
            ("get_messages", "Reading Inline messages"),
            ("search_chats", "Searching Inline chats"),
            ("add_reaction", "Adding a reaction"),
            ("pin_message", "Pinning a message"),
            ("edit_own_message", "Editing an Inline message"),
            ("return_attachment", "Returning an attachment"),
            ("update_bot_profile", "Updating the bot profile"),
            ("set_presence", "Updating bot presence"),
        ] {
            assert_eq!(
                native_tool_activity(name, ActivitySemanticKind::Other).title,
                title
            );
        }
    }

    #[test]
    fn verbose_details_strip_ansi_flatten_lines_and_preserve_safe_bounded_commands() {
        let activity = SemanticActivity {
            kind: ActivityKind::Looking,
            target: Some("\u{1b}[31msrc/auth.rs\u{1b}[0m\nsecret".to_string()),
            file_count: None,
            command: Some(format!(
                "cargo test --token `{}` https://cdn.inline.chat/photo.png?X-Amz-Signature=private",
                "x".repeat(300)
            )),
            outcome: None,
            active_count: None,
        };
        let rendered = VisibilityPolicy.render(VisibilityMode::Verbose, &activity);
        assert!(!rendered.contains('\u{1b}'));
        assert!(!rendered.contains('\n'));
        assert!(rendered.contains("src/auth.rs secret"));
        assert!(rendered.contains("cargo test --token"));
        assert!(rendered.contains("[redacted]"));
        assert!(rendered.contains("https://cdn.inline.chat/photo.png?[redacted]"));
        assert!(!rendered.contains("X-Amz-Signature"));
        assert!(!rendered.contains(&"x".repeat(100)));
        assert!(rendered.len() < 700);
    }

    #[test]
    fn concurrent_activity_count_is_not_user_visible() {
        let mut activity = SemanticActivity::new(ActivityKind::Executing);
        activity.active_count = Some(3);
        assert_eq!(
            VisibilityPolicy.render(VisibilityMode::Normal, &activity),
            "Working..."
        );
        assert_eq!(
            VisibilityPolicy.render(VisibilityMode::Verbose, &activity),
            "Running a command…"
        );
    }

    #[test]
    fn compact_elapsed_format_matches_agent_convention() {
        assert_eq!(format_elapsed_compact(Duration::from_secs(59)), "59s");
        assert_eq!(format_elapsed_compact(Duration::from_secs(60)), "1m 00s");
        assert_eq!(format_elapsed_compact(Duration::from_secs(125)), "2m 05s");
        assert_eq!(
            format_elapsed_compact(Duration::from_secs(3_729)),
            "1h 02m 09s"
        );
    }

    #[test]
    fn streamed_markdown_ansi_and_unicode_are_safe() {
        let mut presenter = StreamingPresenter::new(0, 0);
        assert_eq!(
            presenter.push_delta(1, "\u{1b}[32m```rust\nlet crab = \"🦀\";\u{1b}[0m"),
            Some(PresentationUpdate::Edit(
                "```rust\nlet crab = \"🦀\";\n```".to_string()
            ))
        );
        assert!(!presenter.content().contains('\u{1b}'));
    }

    #[test]
    fn bounds_streamed_and_snapshot_output_without_splitting_utf8() {
        let mut presenter = StreamingPresenter::new(0, 0);
        presenter.push_delta(1, &"a".repeat(MAX_VISIBLE_OUTPUT_BYTES));
        presenter.push_delta(2, "🦀more output");
        assert!(presenter.content().len() <= MAX_VISIBLE_OUTPUT_BYTES);
        assert!(presenter.content().ends_with(OMITTED_OUTPUT_MARKER));

        presenter.replace_snapshot(3, "🦀".repeat(MAX_VISIBLE_OUTPUT_BYTES));
        assert!(presenter.content().len() <= MAX_VISIBLE_OUTPUT_BYTES);
        assert!(
            presenter
                .content()
                .is_char_boundary(presenter.content().len())
        );
        assert!(presenter.content().ends_with(OMITTED_OUTPUT_MARKER));
    }

    #[test]
    fn completion_summary_is_concise_and_omits_unsafe_paths() {
        let files = vec![
            FileChange {
                path: PathBuf::from("crates/agent-bridge/src/presentation.rs"),
                summary: Some("safe streaming output".to_string()),
            },
            FileChange {
                path: PathBuf::from("../outside.txt"),
                summary: Some("must not appear".to_string()),
            },
            FileChange {
                path: PathBuf::from("/tmp/private.txt"),
                summary: None,
            },
        ];
        assert_eq!(
            render_completion_summary(
                "Implemented presentation polish",
                &files,
                &ValidationSummary::Passed("focused tests passed".to_string()),
            ),
            "Implemented presentation polish.\n\nChanged:\n- crates/agent-bridge/src/presentation.rs — safe streaming output\n\nChecks: focused tests passed."
        );
    }
}

//! Claude Code's session store: `<config>/projects/<sanitized cwd>/<id>.jsonl`.
//!
//! A port of the Python Agent SDK's session helpers. Listing reads only the
//! head and tail of each file; history rebuilds the conversation chain from
//! `parentUuid` links the way the SDKs and the IDE do. Renames and forks write
//! the same entries the SDKs write, so the CLI, the desktop app and the
//! terminal picker all see them.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde_json::{Map, Value, json};

const LITE_READ_BUF_SIZE: u64 = 64 * 1024;
const MAX_SANITIZED_LENGTH: usize = 200;
const FIRST_PROMPT_CHARS: usize = 200;

/// Where Claude Code keeps sessions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionStore {
    config_dir: PathBuf,
}

/// One session in a listing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionInfo {
    pub session_id: String,
    /// The title, else the last prompt, else the first prompt.
    pub summary: String,
    /// A user rename wins over the CLI's generated title.
    pub custom_title: Option<String>,
    pub first_prompt: Option<String>,
    pub git_branch: Option<String>,
    pub cwd: Option<String>,
    pub tag: Option<String>,
    /// Milliseconds since the epoch.
    pub last_modified: u64,
    pub created_at: Option<String>,
    pub file_size: u64,
    pub path: PathBuf,
}

/// A user or assistant message on the conversation chain.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionMessage {
    pub message_type: String,
    pub uuid: String,
    pub session_id: String,
    pub message: Value,
    pub timestamp: Option<String>,
}

impl SessionStore {
    pub fn new(config_dir: impl Into<PathBuf>) -> Self {
        Self {
            config_dir: config_dir.into(),
        }
    }

    /// `CLAUDE_CONFIG_DIR` from `env` (as the CLI will see it), else the
    /// process environment, else `~/.claude`.
    pub fn resolve(env: &[(std::ffi::OsString, std::ffi::OsString)]) -> Option<Self> {
        let configured = env
            .iter()
            .rev()
            .find(|(name, _)| name == "CLAUDE_CONFIG_DIR")
            .map(|(_, value)| PathBuf::from(value))
            .or_else(|| std::env::var_os("CLAUDE_CONFIG_DIR").map(PathBuf::from))
            .filter(|path| !path.as_os_str().is_empty());
        let config_dir = match configured {
            Some(path) => path,
            None => PathBuf::from(std::env::var_os("HOME")?).join(".claude"),
        };
        Some(Self::new(config_dir))
    }

    pub fn projects_dir(&self) -> PathBuf {
        self.config_dir.join("projects")
    }

    /// The project directory for a working directory, tolerating the hash
    /// suffix mismatch the CLI's runtime produces for long paths.
    pub fn project_dir(&self, cwd: &Path) -> Option<PathBuf> {
        let canonical = canonical_text(cwd);
        let sanitized = sanitize_path(&canonical);
        let exact = self.projects_dir().join(&sanitized);
        if exact.is_dir() {
            return Some(exact);
        }
        if sanitized.chars().count() <= MAX_SANITIZED_LENGTH {
            return None;
        }
        let prefix: String = sanitized.chars().take(MAX_SANITIZED_LENGTH).collect();
        fs::read_dir(self.projects_dir())
            .ok()?
            .flatten()
            .map(|entry| entry.path())
            .find(|path| {
                path.is_dir()
                    && path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.starts_with(&format!("{prefix}-")))
            })
    }

    /// Sessions for a folder (and, when asked, its git worktrees), newest
    /// first; every project when `cwd` is `None`.
    pub fn list(
        &self,
        cwd: Option<&Path>,
        include_worktrees: bool,
        offset: usize,
        limit: Option<usize>,
    ) -> Vec<SessionInfo> {
        let mut sessions = Vec::new();
        match cwd {
            Some(cwd) => {
                let mut dirs: Vec<(PathBuf, String)> = Vec::new();
                let canonical = canonical_text(cwd);
                if let Some(dir) = self.project_dir(cwd) {
                    dirs.push((dir, canonical.clone()));
                }
                if include_worktrees {
                    for worktree in git_worktrees(cwd) {
                        if worktree == canonical {
                            continue;
                        }
                        if let Some(dir) = self.project_dir(Path::new(&worktree))
                            && !dirs.iter().any(|(existing, _)| existing == &dir)
                        {
                            dirs.push((dir, worktree));
                        }
                    }
                }
                for (dir, project_path) in dirs {
                    sessions.extend(read_sessions_from_dir(&dir, Some(&project_path)));
                }
            }
            None => {
                for entry in fs::read_dir(self.projects_dir())
                    .into_iter()
                    .flatten()
                    .flatten()
                {
                    if entry.path().is_dir() {
                        sessions.extend(read_sessions_from_dir(&entry.path(), None));
                    }
                }
            }
        }
        let mut by_id: HashMap<String, SessionInfo> = HashMap::new();
        for session in sessions {
            match by_id.get(&session.session_id) {
                Some(existing) if existing.last_modified >= session.last_modified => {}
                _ => {
                    by_id.insert(session.session_id.clone(), session);
                }
            }
        }
        let mut sessions: Vec<SessionInfo> = by_id.into_values().collect();
        sessions.sort_by(|a, b| {
            b.last_modified
                .cmp(&a.last_modified)
                .then_with(|| a.session_id.cmp(&b.session_id))
        });
        let sessions = sessions.into_iter().skip(offset);
        match limit {
            Some(limit) if limit > 0 => sessions.take(limit).collect(),
            _ => sessions.collect(),
        }
    }

    /// The session's file, searching `cwd`'s project (and worktrees) or,
    /// without one, every project.
    pub fn find(&self, session_id: &str, cwd: Option<&Path>) -> Option<PathBuf> {
        if !is_uuid(session_id) {
            return None;
        }
        let file_name = format!("{session_id}.jsonl");
        let non_empty = |dir: &Path| {
            let path = dir.join(&file_name);
            fs::metadata(&path)
                .ok()
                .filter(|metadata| metadata.len() > 0)
                .map(|_| path)
        };
        match cwd {
            Some(cwd) => {
                if let Some(found) = self.project_dir(cwd).and_then(|dir| non_empty(&dir)) {
                    return Some(found);
                }
                let canonical = canonical_text(cwd);
                git_worktrees(cwd)
                    .into_iter()
                    .filter(|worktree| worktree != &canonical)
                    .filter_map(|worktree| self.project_dir(Path::new(&worktree)))
                    .find_map(|dir| non_empty(&dir))
            }
            None => fs::read_dir(self.projects_dir())
                .ok()?
                .flatten()
                .filter(|entry| entry.path().is_dir())
                .find_map(|entry| non_empty(&entry.path())),
        }
    }

    pub fn info(&self, session_id: &str, cwd: Option<&Path>) -> Option<SessionInfo> {
        let path = self.find(session_id, cwd)?;
        let project = cwd.map(canonical_text);
        parse_info(session_id, &path, project.as_deref())
    }

    /// The visible conversation, oldest first.
    pub fn messages(
        &self,
        session_id: &str,
        cwd: Option<&Path>,
        offset: usize,
        limit: Option<usize>,
    ) -> io::Result<Vec<SessionMessage>> {
        let Some(path) = self.find(session_id, cwd) else {
            return Ok(Vec::new());
        };
        let content = fs::read_to_string(path)?;
        let entries = parse_transcript_entries(&content);
        let chain = build_conversation_chain(&entries);
        let messages = chain
            .into_iter()
            .filter(is_visible)
            .map(to_session_message)
            .skip(offset);
        Ok(match limit {
            Some(limit) if limit > 0 => messages.take(limit).collect(),
            _ => messages.collect(),
        })
    }

    /// Appends a `custom-title` entry, as `renameSession` does. The last one
    /// wins, so repeated renames are safe.
    pub fn rename(&self, session_id: &str, title: &str, cwd: Option<&Path>) -> io::Result<()> {
        let title = title.trim();
        if title.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "title must be non-empty",
            ));
        }
        let path = self.find(session_id, cwd).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("session {session_id} not found"),
            )
        })?;
        let line = json!({"type": "custom-title", "customTitle": title, "sessionId": session_id});
        let mut file = OpenOptions::new().append(true).open(path)?;
        file.write_all(format!("{line}\n").as_bytes())
    }

    /// Copies a session into a new id with fresh message uuids, optionally
    /// cut after `up_to_message` (inclusive), as `forkSession` does.
    pub fn fork(
        &self,
        session_id: &str,
        cwd: Option<&Path>,
        up_to_message: Option<&str>,
        title: Option<&str>,
    ) -> io::Result<String> {
        let path = self.find(session_id, cwd).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("session {session_id} not found"),
            )
        })?;
        let project_dir = path
            .parent()
            .ok_or_else(|| io::Error::other("session file has no parent"))?
            .to_path_buf();
        let content = fs::read_to_string(&path)?;
        let (forked_id, lines) = build_fork_lines(&content, session_id, up_to_message, title)?;
        let fork_path = project_dir.join(format!("{forked_id}.jsonl"));
        let mut file = create_new_private(&fork_path)?;
        file.write_all((lines.join("\n") + "\n").as_bytes())?;
        Ok(forked_id)
    }

    /// Ids of the session's subagent transcripts.
    pub fn subagents(&self, session_id: &str, cwd: Option<&Path>) -> Vec<String> {
        let Some(dir) = self.subagents_dir(session_id, cwd) else {
            return Vec::new();
        };
        collect_agent_files(&dir)
            .into_iter()
            .map(|(agent_id, _)| agent_id)
            .collect()
    }

    /// One subagent's conversation, oldest first.
    pub fn subagent_messages(
        &self,
        session_id: &str,
        agent_id: &str,
        cwd: Option<&Path>,
    ) -> io::Result<Vec<SessionMessage>> {
        let Some(dir) = self.subagents_dir(session_id, cwd) else {
            return Ok(Vec::new());
        };
        let Some((_, path)) = collect_agent_files(&dir)
            .into_iter()
            .find(|(id, _)| id == agent_id)
        else {
            return Ok(Vec::new());
        };
        let entries = parse_transcript_entries(&fs::read_to_string(path)?);
        Ok(build_linear_chain(&entries)
            .into_iter()
            .filter(|entry| matches!(entry_type(entry), "user" | "assistant"))
            .map(to_session_message)
            .collect())
    }

    fn subagents_dir(&self, session_id: &str, cwd: Option<&Path>) -> Option<PathBuf> {
        let path = self.find(session_id, cwd)?;
        Some(path.with_extension("").join("subagents"))
    }
}

/// Replaces every non-alphanumeric character with `-`; long paths are cut
/// and suffixed with a hash, as the CLI names project directories.
pub fn sanitize_path(name: &str) -> String {
    // The CLI works on UTF-16 code units: an astral character becomes two.
    let sanitized: String = name
        .chars()
        .flat_map(|c| {
            let replacement = if c.is_ascii_alphanumeric() { c } else { '-' };
            std::iter::repeat_n(
                replacement,
                if c.is_ascii_alphanumeric() {
                    1
                } else {
                    c.len_utf16()
                },
            )
        })
        .collect();
    if sanitized.chars().count() <= MAX_SANITIZED_LENGTH {
        return sanitized;
    }
    let prefix: String = sanitized.chars().take(MAX_SANITIZED_LENGTH).collect();
    format!("{prefix}-{}", simple_hash(name))
}

/// The JavaScript 32-bit string hash, in base 36.
fn simple_hash(text: &str) -> String {
    let mut hash: i32 = 0;
    for unit in text.encode_utf16() {
        hash = hash
            .wrapping_shl(5)
            .wrapping_sub(hash)
            .wrapping_add(i32::from(unit));
    }
    let mut value = hash.unsigned_abs() as u64;
    if value == 0 {
        return "0".into();
    }
    let digits = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = Vec::new();
    while value > 0 {
        out.push(digits[(value % 36) as usize]);
        value /= 36;
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

fn canonical_text(path: &Path) -> String {
    fs::canonicalize(path)
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

pub fn is_uuid(text: &str) -> bool {
    uuid::Uuid::parse_str(text).is_ok() && text.len() == 36
}

fn git_worktrees(cwd: &Path) -> Vec<String> {
    let output = std::process::Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(cwd)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.strip_prefix("worktree "))
        .map(str::to_string)
        .collect()
}

fn read_sessions_from_dir(dir: &Path, project_path: Option<&str>) -> Vec<SessionInfo> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let name = path.file_name()?.to_str()?;
            let session_id = name.strip_suffix(".jsonl")?;
            if !is_uuid(session_id) {
                return None;
            }
            parse_info(session_id, &path, project_path)
        })
        .collect()
}

struct Lite {
    head: String,
    tail: String,
    mtime: u64,
    size: u64,
}

fn read_lite(path: &Path) -> Option<Lite> {
    let mut file = File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    let size = metadata.len();
    if size == 0 {
        return None;
    }
    let mtime = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_millis() as u64);
    let mut head = vec![0; LITE_READ_BUF_SIZE.min(size) as usize];
    file.read_exact(&mut head).ok()?;
    let tail = if size <= LITE_READ_BUF_SIZE {
        head.clone()
    } else {
        let mut tail = vec![0; LITE_READ_BUF_SIZE as usize];
        file.seek(SeekFrom::Start(size - LITE_READ_BUF_SIZE)).ok()?;
        file.read_exact(&mut tail).ok()?;
        tail
    };
    Some(Lite {
        head: String::from_utf8_lossy(&head).into_owned(),
        tail: String::from_utf8_lossy(&tail).into_owned(),
        mtime,
        size,
    })
}

fn parse_info(session_id: &str, path: &Path, project_path: Option<&str>) -> Option<SessionInfo> {
    let lite = read_lite(path)?;
    let first_line = lite.head.lines().next().unwrap_or_default();
    if first_line.contains("\"isSidechain\":true") || first_line.contains("\"isSidechain\": true") {
        return None;
    }
    let custom_title = last_string_field(&lite.tail, "customTitle")
        .or_else(|| last_string_field(&lite.head, "customTitle"))
        .or_else(|| last_string_field(&lite.tail, "aiTitle"))
        .or_else(|| last_string_field(&lite.head, "aiTitle"))
        .filter(|title| !title.is_empty());
    let first_prompt = first_prompt(&lite.head).filter(|prompt| !prompt.is_empty());
    let summary = custom_title
        .clone()
        .or_else(|| last_string_field(&lite.tail, "lastPrompt"))
        .or_else(|| last_string_field(&lite.tail, "summary"))
        .or_else(|| first_prompt.clone())?;
    let tag = lite
        .tail
        .lines()
        .rev()
        .find(|line| line.starts_with("{\"type\":\"tag\""))
        .and_then(|line| last_string_field(line, "tag"));
    Some(SessionInfo {
        session_id: session_id.to_string(),
        summary,
        custom_title,
        first_prompt,
        git_branch: last_string_field(&lite.tail, "gitBranch")
            .or_else(|| first_string_field(&lite.head, "gitBranch")),
        cwd: first_string_field(&lite.head, "cwd").or_else(|| project_path.map(str::to_string)),
        tag,
        last_modified: lite.mtime,
        created_at: first_string_field(&lite.head, "timestamp"),
        file_size: lite.size,
        path: path.to_path_buf(),
    })
}

/// The first `"key":"value"` string in `text`, without a full parse (works
/// on lines cut by the head/tail window).
fn first_string_field(text: &str, key: &str) -> Option<String> {
    string_fields(text, key).into_iter().next()
}

fn last_string_field(text: &str, key: &str) -> Option<String> {
    string_fields(text, key).into_iter().last()
}

fn string_fields(text: &str, key: &str) -> Vec<String> {
    let mut found: Vec<(usize, String)> = Vec::new();
    for pattern in [format!("\"{key}\":\""), format!("\"{key}\": \"")] {
        let mut from = 0;
        while let Some(index) = text[from..].find(&pattern) {
            let start = from + index + pattern.len();
            let bytes = text.as_bytes();
            let mut cursor = start;
            let mut end = None;
            while cursor < bytes.len() {
                match bytes[cursor] {
                    b'\\' => cursor += 2,
                    b'"' => {
                        end = Some(cursor);
                        break;
                    }
                    _ => cursor += 1,
                }
            }
            let Some(end) = end else { break };
            let raw = &text[start..end];
            let value = serde_json::from_str::<String>(&format!("\"{raw}\""))
                .unwrap_or_else(|_| raw.to_string());
            found.push((start, value));
            from = end + 1;
        }
    }
    found.sort_by_key(|(position, _)| *position);
    found.into_iter().map(|(_, value)| value).collect()
}

fn first_prompt(head: &str) -> Option<String> {
    let mut command_fallback = None;
    for line in head.lines() {
        if !(line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")) {
            continue;
        }
        if line.contains("\"tool_result\"")
            || line.contains("\"isMeta\":true")
            || line.contains("\"isMeta\": true")
            || line.contains("\"isCompactSummary\":true")
            || line.contains("\"isCompactSummary\": true")
        {
            continue;
        }
        let Ok(entry) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if entry["type"] != "user" {
            continue;
        }
        let texts: Vec<&str> = match &entry["message"]["content"] {
            Value::String(text) => vec![text.as_str()],
            Value::Array(blocks) => blocks
                .iter()
                .filter(|block| block["type"] == "text")
                .filter_map(|block| block["text"].as_str())
                .collect(),
            _ => Vec::new(),
        };
        for raw in texts {
            let text = raw.replace('\n', " ");
            let text = text.trim();
            if text.is_empty() {
                continue;
            }
            if let Some(start) = text.find("<command-name>")
                && let Some(end) = text[start..].find("</command-name>")
            {
                command_fallback.get_or_insert_with(|| {
                    text[start + "<command-name>".len()..start + end].to_string()
                });
                continue;
            }
            if is_auto_generated_prompt(text) {
                continue;
            }
            if text.chars().count() > FIRST_PROMPT_CHARS {
                let cut: String = text.chars().take(FIRST_PROMPT_CHARS).collect();
                return Some(format!("{}…", cut.trim_end()));
            }
            return Some(text.to_string());
        }
    }
    command_fallback
}

fn is_auto_generated_prompt(text: &str) -> bool {
    let trimmed = text.trim_start();
    text.starts_with("<local-command-stdout>")
        || text.starts_with("<session-start-hook>")
        || text.starts_with("<tick>")
        || text.starts_with("<goal>")
        || text.starts_with("[Request interrupted by user")
        || (trimmed.starts_with("<ide_opened_file>")
            && text.trim_end().ends_with("</ide_opened_file>"))
        || (trimmed.starts_with("<ide_selection>") && text.trim_end().ends_with("</ide_selection>"))
}

type Entry = Map<String, Value>;

const TRANSCRIPT_TYPES: &[&str] = &["user", "assistant", "progress", "system", "attachment"];

fn parse_transcript_entries(content: &str) -> Vec<Entry> {
    content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter_map(|value| match value {
            Value::Object(map) => Some(map),
            _ => None,
        })
        .filter(|entry| {
            TRANSCRIPT_TYPES.contains(&entry_type(entry))
                && entry.get("uuid").is_some_and(Value::is_string)
        })
        .collect()
}

fn entry_type(entry: &Entry) -> &str {
    entry.get("type").and_then(Value::as_str).unwrap_or("")
}

fn uuid_of(entry: &Entry) -> &str {
    entry.get("uuid").and_then(Value::as_str).unwrap_or("")
}

fn parent_of(entry: &Entry) -> Option<&str> {
    entry
        .get("parentUuid")
        .and_then(Value::as_str)
        .filter(|parent| !parent.is_empty())
}

fn flag(entry: &Entry, key: &str) -> bool {
    entry.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn build_conversation_chain(entries: &[Entry]) -> Vec<Entry> {
    if entries.is_empty() {
        return Vec::new();
    }
    let by_uuid: HashMap<&str, &Entry> = entries
        .iter()
        .map(|entry| (uuid_of(entry), entry))
        .collect();
    let position: HashMap<&str, usize> = entries
        .iter()
        .enumerate()
        .map(|(index, entry)| (uuid_of(entry), index))
        .collect();
    let parents: HashSet<&str> = entries.iter().filter_map(parent_of).collect();

    let mut leaves: Vec<&Entry> = Vec::new();
    for terminal in entries
        .iter()
        .filter(|entry| !parents.contains(uuid_of(entry)))
    {
        let mut seen = HashSet::new();
        let mut current = Some(terminal);
        while let Some(entry) = current {
            if !seen.insert(uuid_of(entry)) {
                break;
            }
            if matches!(entry_type(entry), "user" | "assistant") {
                leaves.push(entry);
                break;
            }
            current = parent_of(entry).and_then(|parent| by_uuid.get(parent).copied());
        }
    }
    if leaves.is_empty() {
        return Vec::new();
    }
    let main: Vec<&Entry> = leaves
        .iter()
        .copied()
        .filter(|leaf| {
            !flag(leaf, "isSidechain") && leaf.get("teamName").is_none() && !flag(leaf, "isMeta")
        })
        .collect();
    let candidates = if main.is_empty() { &leaves } else { &main };
    let leaf = candidates
        .iter()
        .copied()
        .max_by_key(|entry| position.get(uuid_of(entry)).copied().unwrap_or(0))
        .expect("non-empty candidates");

    let mut chain: Vec<Entry> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut current = Some(leaf);
    while let Some(entry) = current {
        if !seen.insert(uuid_of(entry).to_string()) {
            break;
        }
        chain.push(entry.clone());
        current = parent_of(entry).and_then(|parent| by_uuid.get(parent).copied());
    }
    chain.reverse();
    recover_parallel_tool_results(entries, &by_uuid, chain, &mut seen)
}

fn assistant_message_id(entry: &Entry) -> Option<&str> {
    if entry_type(entry) != "assistant" {
        return None;
    }
    entry
        .get("message")
        .and_then(|message| message.get("id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
}

fn block_ids<'a>(entry: &'a Entry, block_type: &str, field: &str) -> Vec<&'a str> {
    entry
        .get("message")
        .and_then(|message| message.get("content"))
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter(|block| block["type"] == block_type)
                .filter_map(|block| block[field].as_str())
                .collect()
        })
        .unwrap_or_default()
}

fn is_tool_result_entry(entry: &Entry) -> bool {
    entry_type(entry) == "user"
        && parent_of(entry).is_some()
        && entry
            .get("message")
            .and_then(|message| message.get("content"))
            .and_then(Value::as_array)
            .is_some_and(|blocks| blocks.iter().any(|block| block["type"] == "tool_result"))
}

fn same_writer(a: &Entry, b: &Entry) -> bool {
    flag(a, "isSidechain") == flag(b, "isSidechain") && a.get("agentId") == b.get("agentId")
}

fn timestamp_of(entry: &Entry) -> &str {
    entry.get("timestamp").and_then(Value::as_str).unwrap_or("")
}

/// Puts back the tool calls and results of a parallel tool round that the
/// `parentUuid` walk left off the chain (the CLI writes one assistant entry
/// per content block, so parallel results fan out from different parents).
fn recover_parallel_tool_results(
    entries: &[Entry],
    by_uuid: &HashMap<&str, &Entry>,
    chain: Vec<Entry>,
    seen: &mut HashSet<String>,
) -> Vec<Entry> {
    let chain_assistants: Vec<&Entry> = chain
        .iter()
        .filter(|entry| entry_type(entry) == "assistant")
        .collect();
    let mut anchor: HashMap<String, String> = HashMap::new();
    for entry in &chain_assistants {
        if let Some(message_id) = assistant_message_id(entry) {
            anchor.insert(message_id.to_string(), uuid_of(entry).to_string());
        }
    }
    if anchor.is_empty() {
        return chain;
    }

    let mut siblings: HashMap<&str, Vec<&Entry>> = HashMap::new();
    let mut call_owner: HashMap<&str, Option<&Entry>> = HashMap::new();
    let mut results: Vec<&Entry> = Vec::new();
    for entry in entries {
        if let Some(message_id) = assistant_message_id(entry) {
            siblings.entry(message_id).or_default().push(entry);
            for call_id in block_ids(entry, "tool_use", "id") {
                match call_owner.get(call_id) {
                    None => {
                        call_owner.insert(call_id, Some(entry));
                    }
                    Some(owner) => {
                        let same = owner
                            .is_some_and(|owner| assistant_message_id(owner) == Some(message_id));
                        call_owner.insert(call_id, if same { Some(entry) } else { None });
                    }
                }
            }
        } else if is_tool_result_entry(entry) {
            results.push(entry);
        }
    }

    let mut results_by_assistant: HashMap<&str, Vec<&Entry>> = HashMap::new();
    for result in &results {
        if let Some(parent) = parent_of(result) {
            results_by_assistant.entry(parent).or_default().push(result);
        }
        if let Some(source) = result
            .get("sourceToolAssistantUUID")
            .and_then(Value::as_str)
            && let Some(source_entry) = by_uuid.get(source)
            && same_writer(result, source_entry)
        {
            results_by_assistant.entry(source).or_default().push(result);
        }
        for call_id in block_ids(result, "tool_result", "tool_use_id") {
            if let Some(Some(owner)) = call_owner.get(call_id)
                && same_writer(result, owner)
            {
                results_by_assistant
                    .entry(uuid_of(owner))
                    .or_default()
                    .push(result);
            }
        }
    }

    let file_position: HashMap<&str, usize> = entries
        .iter()
        .enumerate()
        .map(|(index, entry)| (uuid_of(entry), index))
        .collect();
    let answered_on_chain: HashSet<String> = chain
        .iter()
        .flat_map(|entry| block_ids(entry, "tool_result", "tool_use_id"))
        .map(str::to_string)
        .collect();

    let mut processed: HashSet<&str> = HashSet::new();
    let mut inserts: HashMap<String, Vec<Entry>> = HashMap::new();
    for assistant in &chain_assistants {
        let Some(message_id) = assistant_message_id(assistant) else {
            continue;
        };
        if !processed.insert(message_id) {
            continue;
        }
        let group = siblings
            .get(message_id)
            .cloned()
            .unwrap_or_else(|| vec![assistant]);
        let members: HashSet<&str> = group.iter().map(|member| uuid_of(member)).collect();
        let mut orphaned_siblings: Vec<&Entry> = group
            .iter()
            .copied()
            .filter(|member| !seen.contains(uuid_of(member)))
            .collect();
        let mut orphaned_results: Vec<&Entry> = Vec::new();
        let mut strays: Vec<&Entry> = Vec::new();
        let mut collected: HashSet<&str> = HashSet::new();
        for member in &group {
            for result in results_by_assistant
                .get(uuid_of(member))
                .into_iter()
                .flatten()
            {
                let id = uuid_of(result);
                if seen.contains(id) || !collected.insert(id) {
                    continue;
                }
                if parent_of(result).is_some_and(|parent| members.contains(parent)) {
                    orphaned_results.push(result);
                } else {
                    strays.push(result);
                }
            }
        }
        if !strays.is_empty() {
            let mut answered = answered_on_chain.clone();
            for result in &orphaned_results {
                answered.extend(
                    block_ids(result, "tool_result", "tool_use_id")
                        .into_iter()
                        .map(str::to_string),
                );
            }
            strays.sort_by_key(|entry| file_position.get(uuid_of(entry)).copied().unwrap_or(0));
            for result in strays {
                let call_ids = block_ids(result, "tool_result", "tool_use_id");
                let opens = call_ids.iter().any(|call_id| {
                    !answered.contains(*call_id)
                        && matches!(call_owner.get(call_id), Some(Some(owner)) if members.contains(uuid_of(owner)))
                });
                if opens {
                    answered.extend(call_ids.into_iter().map(str::to_string));
                    orphaned_results.push(result);
                }
            }
        }
        if orphaned_siblings.is_empty() && orphaned_results.is_empty() {
            continue;
        }
        orphaned_siblings.sort_by(|a, b| timestamp_of(a).cmp(timestamp_of(b)));
        orphaned_results.sort_by(|a, b| timestamp_of(a).cmp(timestamp_of(b)));
        let recovered: Vec<Entry> = orphaned_siblings
            .into_iter()
            .chain(orphaned_results)
            .map(|entry| {
                seen.insert(uuid_of(entry).to_string());
                entry.clone()
            })
            .collect();
        if let Some(anchor_uuid) = anchor.get(message_id) {
            inserts.insert(anchor_uuid.clone(), recovered);
        }
    }
    if inserts.is_empty() {
        return chain;
    }
    let mut out = Vec::with_capacity(chain.len());
    for entry in chain {
        let key = uuid_of(&entry).to_string();
        out.push(entry);
        if let Some(recovered) = inserts.remove(&key) {
            out.extend(recovered);
        }
    }
    out
}

fn build_linear_chain(entries: &[Entry]) -> Vec<Entry> {
    let by_uuid: HashMap<&str, &Entry> = entries
        .iter()
        .map(|entry| (uuid_of(entry), entry))
        .collect();
    let Some(leaf) = entries
        .iter()
        .rev()
        .find(|entry| matches!(entry_type(entry), "user" | "assistant"))
    else {
        return Vec::new();
    };
    let mut chain = Vec::new();
    let mut seen = HashSet::new();
    let mut current = Some(leaf);
    while let Some(entry) = current {
        if !seen.insert(uuid_of(entry)) {
            break;
        }
        chain.push(entry.clone());
        current = parent_of(entry).and_then(|parent| by_uuid.get(parent).copied());
    }
    chain.reverse();
    chain
}

fn is_visible(entry: &Entry) -> bool {
    matches!(entry_type(entry), "user" | "assistant")
        && !flag(entry, "isMeta")
        && !flag(entry, "isSidechain")
        && entry.get("teamName").is_none()
}

fn to_session_message(entry: Entry) -> SessionMessage {
    SessionMessage {
        message_type: entry_type(&entry).to_string(),
        uuid: uuid_of(&entry).to_string(),
        session_id: entry
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        timestamp: entry
            .get("timestamp")
            .and_then(Value::as_str)
            .map(str::to_string),
        message: entry.get("message").cloned().unwrap_or(Value::Null),
    }
}

fn collect_agent_files(dir: &Path) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            out.extend(collect_agent_files(&path));
        } else if let Some(name) = path.file_name().and_then(|name| name.to_str())
            && let Some(agent_id) = name
                .strip_prefix("agent-")
                .and_then(|rest| rest.strip_suffix(".jsonl"))
        {
            out.push((agent_id.to_string(), path.clone()));
        }
    }
    out
}

fn create_new_private(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn build_fork_lines(
    content: &str,
    session_id: &str,
    up_to_message: Option<&str>,
    title: Option<&str>,
) -> io::Result<(String, Vec<String>)> {
    let mut transcript: Vec<Entry> = Vec::new();
    let mut content_replacements: Vec<Value> = Vec::new();
    for line in content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let Ok(Value::Object(entry)) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let kind = entry_type(&entry);
        if ["user", "assistant", "attachment", "system", "progress"].contains(&kind)
            && entry.get("uuid").is_some_and(Value::is_string)
        {
            transcript.push(entry);
        } else if kind == "content-replacement"
            && entry.get("sessionId").and_then(Value::as_str) == Some(session_id)
            && let Some(Value::Array(replacements)) = entry.get("replacements")
        {
            content_replacements.extend(replacements.iter().cloned());
        }
    }
    transcript.retain(|entry| !flag(entry, "isSidechain"));
    if let Some(cutoff) = up_to_message {
        let index = transcript
            .iter()
            .position(|entry| uuid_of(entry) == cutoff)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("message {cutoff} not found"),
                )
            })?;
        transcript.truncate(index + 1);
    }
    let mapping: HashMap<String, String> = transcript
        .iter()
        .map(|entry| (uuid_of(entry).to_string(), uuid::Uuid::new_v4().to_string()))
        .collect();
    let by_uuid: HashMap<&str, &Entry> = transcript
        .iter()
        .map(|entry| (uuid_of(entry), entry))
        .collect();
    let writable: Vec<&Entry> = transcript
        .iter()
        .filter(|entry| entry_type(entry) != "progress")
        .collect();
    if writable.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("session {session_id} has no messages to fork"),
        ));
    }
    let forked_id = uuid::Uuid::new_v4().to_string();
    let now = iso_now();
    let mut lines = Vec::new();
    for (index, original) in writable.iter().enumerate() {
        let mut parent = parent_of(original);
        let mut new_parent = Value::Null;
        while let Some(parent_id) = parent {
            let Some(parent_entry) = by_uuid.get(parent_id) else {
                break;
            };
            if entry_type(parent_entry) != "progress" {
                new_parent = mapping.get(parent_id).map_or(Value::Null, |id| json!(id));
                break;
            }
            parent = parent_of(parent_entry);
        }
        let mut forked = (*original).clone();
        forked.insert("uuid".into(), json!(mapping[uuid_of(original)]));
        forked.insert("parentUuid".into(), new_parent);
        if let Some(logical) = original.get("logicalParentUuid").and_then(Value::as_str) {
            forked.insert(
                "logicalParentUuid".into(),
                mapping
                    .get(logical)
                    .map_or_else(|| json!(logical), |id| json!(id)),
            );
        }
        forked.insert("sessionId".into(), json!(forked_id));
        if index + 1 == writable.len() || !original.contains_key("timestamp") {
            forked.insert("timestamp".into(), json!(now));
        }
        forked.insert("isSidechain".into(), json!(false));
        forked.insert(
            "forkedFrom".into(),
            json!({"sessionId": session_id, "messageUuid": uuid_of(original)}),
        );
        for key in ["teamName", "agentName", "slug", "sourceToolAssistantUUID"] {
            forked.remove(key);
        }
        lines.push(Value::Object(forked).to_string());
    }
    if !content_replacements.is_empty() {
        lines.push(
            json!({"type": "content-replacement", "sessionId": forked_id,
                "replacements": content_replacements, "uuid": uuid::Uuid::new_v4().to_string(),
                "timestamp": now})
            .to_string(),
        );
    }
    let fork_title = title
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map_or_else(
            || {
                let derived = last_string_field(content, "customTitle")
                    .or_else(|| last_string_field(content, "aiTitle"))
                    .or_else(|| first_prompt(content))
                    .unwrap_or_else(|| "Forked session".into());
                format!("{derived} (fork)")
            },
            str::to_string,
        );
    lines.push(
        json!({"type": "custom-title", "sessionId": forked_id, "customTitle": fork_title,
            "uuid": uuid::Uuid::new_v4().to_string(), "timestamp": now})
        .to_string(),
    );
    Ok((forked_id, lines))
}

fn iso_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = now.as_secs() as i64;
    let millis = now.subsec_millis();
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    const S1: &str = "11111111-1111-4111-8111-111111111111";

    fn write_session(store: &SessionStore, cwd: &Path, id: &str, lines: &[Value]) -> PathBuf {
        let dir = store
            .projects_dir()
            .join(sanitize_path(&canonical_text(cwd)));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{id}.jsonl"));
        let body: String = lines.iter().map(|line| format!("{line}\n")).collect();
        fs::write(&path, body).unwrap();
        path
    }

    fn conversation() -> Vec<Value> {
        vec![
            json!({"type": "user", "uuid": "u1", "parentUuid": null, "sessionId": S1, "cwd": "/w",
                "timestamp": "2026-10-26T10:00:00.000Z", "gitBranch": "main",
                "message": {"role": "user", "content": "fix the build"}}),
            json!({"type": "assistant", "uuid": "a1", "parentUuid": "u1", "sessionId": S1,
                "message": {"id": "msg_1", "role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]}}),
            json!({"type": "assistant", "uuid": "a2", "parentUuid": "a1", "sessionId": S1,
                "message": {"id": "msg_1", "role": "assistant", "content": [{"type": "tool_use", "id": "t2", "name": "Read", "input": {}}]}}),
            json!({"type": "user", "uuid": "r1", "parentUuid": "a1", "sessionId": S1, "timestamp": "2026-10-26T10:00:01.000Z",
                "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}),
            json!({"type": "user", "uuid": "r2", "parentUuid": "a2", "sessionId": S1, "timestamp": "2026-10-26T10:00:02.000Z",
                "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t2", "content": "file"}]}}),
            json!({"type": "assistant", "uuid": "a3", "parentUuid": "r2", "sessionId": S1,
                "message": {"id": "msg_2", "role": "assistant", "content": [{"type": "text", "text": "done"}]}}),
            json!({"type": "ai-title", "aiTitle": "Fix the build", "sessionId": S1}),
        ]
    }

    #[test]
    fn sanitizes_like_the_cli() {
        assert_eq!(
            sanitize_path("/Users/mo/dev/inline"),
            "-Users-mo-dev-inline"
        );
        let long = format!("/{}", "a".repeat(300));
        let sanitized = sanitize_path(&long);
        assert!(sanitized.starts_with(&format!("-{}", "a".repeat(199))));
        assert_eq!(sanitized.chars().nth(200), Some('-'));
        assert_eq!(simple_hash(""), "0");
    }

    #[test]
    fn lists_sessions_with_titles_and_prompts() {
        let config = tempfile::tempdir().unwrap();
        let cwd = tempfile::tempdir().unwrap();
        let store = SessionStore::new(config.path());
        write_session(&store, cwd.path(), S1, &conversation());
        let sessions = store.list(Some(cwd.path()), false, 0, None);
        assert_eq!(sessions.len(), 1);
        let session = &sessions[0];
        assert_eq!(session.summary, "Fix the build");
        assert_eq!(session.first_prompt.as_deref(), Some("fix the build"));
        assert_eq!(session.git_branch.as_deref(), Some("main"));
        assert_eq!(
            session.created_at.as_deref(),
            Some("2026-10-26T10:00:00.000Z")
        );
        assert_eq!(store.list(None, false, 0, None).len(), 1);
    }

    #[test]
    fn history_keeps_parallel_tool_rounds_whole() {
        let config = tempfile::tempdir().unwrap();
        let cwd = tempfile::tempdir().unwrap();
        let store = SessionStore::new(config.path());
        write_session(&store, cwd.path(), S1, &conversation());
        let messages = store.messages(S1, Some(cwd.path()), 0, None).unwrap();
        let uuids: Vec<&str> = messages
            .iter()
            .map(|message| message.uuid.as_str())
            .collect();
        assert_eq!(uuids, ["u1", "a1", "a2", "r1", "r2", "a3"]);
    }

    #[test]
    fn rename_appends_a_custom_title_that_wins() {
        let config = tempfile::tempdir().unwrap();
        let cwd = tempfile::tempdir().unwrap();
        let store = SessionStore::new(config.path());
        write_session(&store, cwd.path(), S1, &conversation());
        store
            .rename(S1, "  Inline thread title ", Some(cwd.path()))
            .unwrap();
        let info = store.info(S1, Some(cwd.path())).unwrap();
        assert_eq!(info.custom_title.as_deref(), Some("Inline thread title"));
        assert!(store.rename(S1, "   ", Some(cwd.path())).is_err());
    }

    #[test]
    fn fork_remaps_ids_and_cuts_at_a_message() {
        let config = tempfile::tempdir().unwrap();
        let cwd = tempfile::tempdir().unwrap();
        let store = SessionStore::new(config.path());
        write_session(&store, cwd.path(), S1, &conversation());
        let forked = store.fork(S1, Some(cwd.path()), Some("a1"), None).unwrap();
        assert_ne!(forked, S1);
        let messages = store.messages(&forked, Some(cwd.path()), 0, None).unwrap();
        assert_eq!(messages.len(), 2);
        assert!(messages.iter().all(|message| message.session_id == forked));
        assert!(
            messages
                .iter()
                .all(|message| message.uuid != "u1" && message.uuid != "a1")
        );
        let info = store.info(&forked, Some(cwd.path())).unwrap();
        assert_eq!(info.custom_title.as_deref(), Some("Fix the build (fork)"));
        assert!(
            store
                .fork(S1, Some(cwd.path()), Some("missing"), None)
                .is_err()
        );
    }

    #[test]
    fn subagent_transcripts_are_listed_and_read() {
        let config = tempfile::tempdir().unwrap();
        let cwd = tempfile::tempdir().unwrap();
        let store = SessionStore::new(config.path());
        let path = write_session(&store, cwd.path(), S1, &conversation());
        let subagents = path.with_extension("").join("subagents");
        fs::create_dir_all(&subagents).unwrap();
        fs::write(
            subagents.join("agent-abc.jsonl"),
            format!(
                "{}\n{}\n",
                json!({"type": "user", "uuid": "s1", "parentUuid": null, "isSidechain": true, "message": {"role": "user", "content": "look"}}),
                json!({"type": "assistant", "uuid": "s2", "parentUuid": "s1", "isSidechain": true, "message": {"role": "assistant", "content": []}})
            ),
        )
        .unwrap();
        assert_eq!(store.subagents(S1, Some(cwd.path())), ["abc"]);
        assert_eq!(
            store
                .subagent_messages(S1, "abc", Some(cwd.path()))
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn iso_time_is_well_formed() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_752), (2026, 10, 26));
        let now = iso_now();
        assert_eq!(now.len(), 24);
        assert!(now.ends_with('Z'));
    }
}

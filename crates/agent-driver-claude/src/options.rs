//! How the user's installed `claude` is launched.
//!
//! The command follows the Agent SDKs' subprocess transport: stream-json in
//! and out, permission prompts routed to the host over stdio, and an explicit
//! permission mode (the SDKs' default for an omitted mode changed twice).
//! Everything else stays the harness's own default: Claude Code's system
//! prompt, the user's setting sources, plugins, MCP servers and CLAUDE.md.

use std::ffi::{OsStr, OsString};
use std::path::PathBuf;

/// Environment names that never reach the CLI.
const ALWAYS_REMOVE_ENVIRONMENT: &[&str] = &[
    "INLINE_TOKEN",
    "INLINE_SECRETS_PATH",
    "INLINE_DEVICE_ID",
    "DATABASE_URL",
    "REDIS_URL",
    "SENTRY_DSN",
    "SENTRY_AUTH_TOKEN",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "NPM_TOKEN",
    "BUN_AUTH_TOKEN",
    "YARN_NPM_AUTH_TOKEN",
    // A parent Claude Code session; the child must not think it is nested.
    "CLAUDECODE",
    // Set below for this host.
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_AGENT_SDK_CLIENT_APP",
];

/// Credential prefixes the CLI itself reads.
const PROVIDER_ENVIRONMENT_PREFIXES: &[&str] = &["ANTHROPIC_", "CLAUDE_", "AWS_", "GOOGLE_", "VERTEX_"];

/// The headless SDK entrypoint class the CLI knows (`sdk-cli`, `sdk-ts`,
/// `sdk-py`); Inline is a host of the same kind.
pub const DEFAULT_ENTRYPOINT: &str = "sdk-cli";

/// How the session starts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionStart {
    /// A new session with a host-chosen id.
    New { session_id: String },
    /// Continue an existing session under its own id.
    Resume { session_id: String },
    /// Copy an existing session into a new id, optionally cut at a message.
    Fork {
        session_id: String,
        at_message: Option<String>,
        new_session_id: Option<String>,
    },
    /// Let the CLI pick (a fresh random id).
    Fresh,
}

impl SessionStart {
    pub fn new_session() -> Self {
        Self::New {
            session_id: uuid::Uuid::new_v4().to_string(),
        }
    }
}

/// Wraps the CLI in Inline's crash-surviving process host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessHost {
    pub executable: PathBuf,
    pub lock_file: PathBuf,
    pub provider_id: String,
}

/// Everything needed to spawn one CLI process.
#[derive(Clone, Debug, PartialEq)]
pub struct LaunchOptions {
    /// The resolved `claude` executable.
    pub executable: PathBuf,
    pub cwd: PathBuf,
    pub session: SessionStart,
    /// Always passed. Values come from the CLI's own choices
    /// (`acceptEdits`, `auto`, `bypassPermissions`, `manual`/`default`,
    /// `dontAsk`, `plan`).
    pub permission_mode: String,
    /// Also lets the session switch to bypass permissions later.
    pub allow_dangerously_skip_permissions: bool,
    pub model: Option<String>,
    pub fallback_model: Option<String>,
    pub effort: Option<String>,
    /// `None` loads the user's sources as the terminal does.
    pub setting_sources: Option<Vec<String>>,
    pub settings: Option<String>,
    pub add_dirs: Vec<PathBuf>,
    pub append_system_prompt: Option<String>,
    /// An `--mcp-config` JSON document (in-process servers use `type: "sdk"`).
    pub mcp_config: Option<String>,
    pub include_partial_messages: bool,
    pub include_hook_events: bool,
    /// Re-emit each stdin user message on stdout once accepted.
    pub replay_user_messages: bool,
    /// Claude Code's brief mode: the `SendUserMessage` tool.
    pub brief: bool,
    /// Minimal mode (labs and CI): no hooks, plugins, keychain or CLAUDE.md.
    pub bare: bool,
    /// Display name for the session (`--name`).
    pub name: Option<String>,
    pub enable_file_checkpointing: bool,
    /// Extra flags for options this crate does not model: `(flag, value)`.
    pub extra_args: Vec<(String, Option<String>)>,
    pub env: Vec<(OsString, OsString)>,
    /// Names kept even if they look like secrets.
    pub env_allow: Vec<String>,
    pub entrypoint: String,
    /// `client-app/…` in the CLI's User-Agent.
    pub client_app: Option<String>,
    pub process_host: Option<ProcessHost>,
}

impl LaunchOptions {
    pub fn new(executable: impl Into<PathBuf>, cwd: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            cwd: cwd.into(),
            session: SessionStart::new_session(),
            permission_mode: "bypassPermissions".into(),
            allow_dangerously_skip_permissions: true,
            model: None,
            fallback_model: None,
            effort: None,
            setting_sources: None,
            settings: None,
            add_dirs: Vec::new(),
            append_system_prompt: None,
            mcp_config: None,
            include_partial_messages: true,
            include_hook_events: false,
            replay_user_messages: false,
            brief: false,
            bare: false,
            name: None,
            enable_file_checkpointing: false,
            extra_args: Vec::new(),
            env: Vec::new(),
            env_allow: Vec::new(),
            entrypoint: DEFAULT_ENTRYPOINT.into(),
            client_app: None,
            process_host: None,
        }
    }

    /// The session id this launch writes to, when the host chose it.
    pub fn target_session_id(&self) -> Option<&str> {
        match &self.session {
            SessionStart::New { session_id } | SessionStart::Resume { session_id } => {
                Some(session_id)
            }
            SessionStart::Fork { new_session_id, .. } => new_session_id.as_deref(),
            SessionStart::Fresh => None,
        }
    }

    /// The CLI arguments, without the executable.
    pub fn cli_arguments(&self) -> Vec<String> {
        let mut args: Vec<String> = [
            "--output-format",
            "stream-json",
            "--verbose",
            "--input-format",
            "stream-json",
            "--permission-prompt-tool",
            "stdio",
        ]
        .into_iter()
        .map(str::to_string)
        .collect();
        // Equals form throughout, so a value can never parse as another flag.
        args.push(format!("--permission-mode={}", self.permission_mode));
        if self.allow_dangerously_skip_permissions {
            args.push("--allow-dangerously-skip-permissions".into());
        }
        if let Some(model) = &self.model {
            args.push(format!("--model={model}"));
        }
        if let Some(fallback) = &self.fallback_model {
            args.push(format!("--fallback-model={fallback}"));
        }
        if let Some(effort) = &self.effort {
            args.push(format!("--effort={effort}"));
        }
        match &self.session {
            SessionStart::New { session_id } => args.push(format!("--session-id={session_id}")),
            SessionStart::Resume { session_id } => args.push(format!("--resume={session_id}")),
            SessionStart::Fork {
                session_id,
                at_message,
                new_session_id,
            } => {
                args.push(format!("--resume={session_id}"));
                args.push("--fork-session".into());
                if let Some(at) = at_message {
                    args.push(format!("--resume-session-at={at}"));
                }
                if let Some(new_id) = new_session_id {
                    args.push(format!("--session-id={new_id}"));
                }
            }
            SessionStart::Fresh => {}
        }
        if let Some(sources) = &self.setting_sources {
            args.push(format!("--setting-sources={}", sources.join(",")));
        }
        if let Some(settings) = &self.settings {
            args.push(format!("--settings={settings}"));
        }
        for dir in &self.add_dirs {
            args.push(format!("--add-dir={}", dir.to_string_lossy()));
        }
        if let Some(append) = &self.append_system_prompt {
            args.push(format!("--append-system-prompt={append}"));
        }
        if let Some(mcp) = &self.mcp_config {
            args.push(format!("--mcp-config={mcp}"));
        }
        if self.include_partial_messages {
            args.push("--include-partial-messages".into());
        }
        if self.include_hook_events {
            args.push("--include-hook-events".into());
        }
        if self.replay_user_messages {
            args.push("--replay-user-messages".into());
        }
        if self.brief {
            args.push("--brief".into());
        }
        if self.bare {
            args.push("--bare".into());
        }
        if let Some(name) = &self.name {
            args.push(format!("--name={name}"));
        }
        for (flag, value) in &self.extra_args {
            match value {
                Some(value) => args.push(format!("--{flag}={value}")),
                None => args.push(format!("--{flag}")),
            }
        }
        args
    }

    /// The full spawn: program, arguments, environment to set and to remove.
    pub fn command(&self) -> CommandSpec {
        let mut program = self.executable.clone().into_os_string();
        let mut args: Vec<OsString> = self.cli_arguments().into_iter().map(OsString::from).collect();
        if let Some(host) = &self.process_host {
            let mut hosted: Vec<OsString> = [
                "bridge",
                "provider-host",
                "--provider-id",
                host.provider_id.as_str(),
                "--lock-file",
            ]
            .into_iter()
            .map(OsString::from)
            .collect();
            hosted.push(host.lock_file.clone().into_os_string());
            hosted.push("--".into());
            hosted.push(program);
            hosted.append(&mut args);
            program = host.executable.clone().into_os_string();
            args = hosted;
        }

        let mut set: Vec<(OsString, OsString)> = vec![
            ("CLAUDE_CODE_ENTRYPOINT".into(), self.entrypoint.clone().into()),
            // Ask for session_state_changed frames: they say when the CLI owes
            // no further turn (background agents still running keep it busy).
            ("CLAUDE_CODE_SDK_READS_SESSION_STATE".into(), "1".into()),
            ("PWD".into(), self.cwd.clone().into_os_string()),
        ];
        if let Some(client_app) = &self.client_app {
            set.push(("CLAUDE_AGENT_SDK_CLIENT_APP".into(), client_app.into()));
        }
        if self.enable_file_checkpointing {
            set.push((
                "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING".into(),
                "true".into(),
            ));
        }
        for (name, value) in &self.env {
            set.retain(|(existing, _)| existing != name);
            set.push((name.clone(), value.clone()));
        }

        let explicit: Vec<&OsStr> = set.iter().map(|(name, _)| name.as_os_str()).collect();
        let mut remove: Vec<OsString> = std::env::vars_os()
            .map(|(name, _)| name)
            .filter(|name| !explicit.contains(&name.as_os_str()))
            .filter(|name| should_scrub_environment_name(name, &self.env_allow))
            .collect();
        for name in ALWAYS_REMOVE_ENVIRONMENT {
            let name = OsString::from(name);
            if !explicit.contains(&name.as_os_str()) && !remove.contains(&name) {
                remove.push(name);
            }
        }
        remove.sort();
        remove.dedup();

        CommandSpec {
            program,
            args,
            cwd: self.cwd.clone(),
            env_set: set,
            env_remove: remove,
        }
    }
}

/// A resolved spawn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: OsString,
    pub args: Vec<OsString>,
    pub cwd: PathBuf,
    pub env_set: Vec<(OsString, OsString)>,
    pub env_remove: Vec<OsString>,
}

/// Whether a host environment variable must not reach the CLI. The CLI's own
/// credential names (`ANTHROPIC_*`, `CLAUDE_*`, cloud provider auth) survive;
/// other secret-looking names and every `INLINE_*` name do not.
pub fn should_scrub_environment_name(name: &OsStr, allow: &[String]) -> bool {
    let Some(name) = name.to_str() else {
        return true;
    };
    let uppercase = name.to_ascii_uppercase();
    if ALWAYS_REMOVE_ENVIRONMENT.contains(&uppercase.as_str()) || uppercase.starts_with("INLINE_")
    {
        return true;
    }
    if allow.iter().any(|allowed| allowed.eq_ignore_ascii_case(name))
        || PROVIDER_ENVIRONMENT_PREFIXES
            .iter()
            .any(|prefix| uppercase.starts_with(prefix))
    {
        return false;
    }
    let components: Vec<_> = uppercase.split('_').collect();
    components.iter().any(|component| {
        matches!(
            *component,
            "TOKEN"
                | "SECRET"
                | "PASSWORD"
                | "PASSWD"
                | "CREDENTIAL"
                | "CREDENTIALS"
                | "KEY"
                | "DSN"
        )
    }) || uppercase.contains("API_KEY")
        || uppercase.contains("ACCESS_KEY")
        || uppercase.contains("PRIVATE_KEY")
        || uppercase.contains("CONNECTION_STRING")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_always_names_the_permission_mode_and_session() {
        let mut options = LaunchOptions::new("/opt/claude", "/work");
        options.session = SessionStart::New {
            session_id: "11111111-1111-4111-8111-111111111111".into(),
        };
        options.permission_mode = "manual".into();
        let args = options.cli_arguments();
        assert!(args.contains(&"--permission-mode=manual".to_string()));
        assert!(args.contains(&"--session-id=11111111-1111-4111-8111-111111111111".to_string()));
        assert!(args.windows(2).any(|pair| pair == ["--permission-prompt-tool", "stdio"]));
        assert!(args.windows(2).any(|pair| pair == ["--input-format", "stream-json"]));
        assert!(!args.iter().any(|arg| arg.starts_with("--system-prompt")));
        assert!(!args.iter().any(|arg| arg.starts_with("--setting-sources")));
    }

    #[test]
    fn fork_resumes_with_fork_session() {
        let mut options = LaunchOptions::new("/opt/claude", "/work");
        options.session = SessionStart::Fork {
            session_id: "a".into(),
            at_message: Some("m3".into()),
            new_session_id: Some("b".into()),
        };
        let args = options.cli_arguments();
        for expected in ["--resume=a", "--fork-session", "--resume-session-at=m3", "--session-id=b"] {
            assert!(args.contains(&expected.to_string()), "{expected}");
        }
        assert_eq!(options.target_session_id(), Some("b"));
    }

    #[test]
    fn process_host_wraps_the_cli() {
        let mut options = LaunchOptions::new("/opt/claude", "/work");
        options.process_host = Some(ProcessHost {
            executable: "/opt/inline".into(),
            lock_file: "/tmp/claude.lock".into(),
            provider_id: "claude".into(),
        });
        let command = options.command();
        assert_eq!(command.program, OsString::from("/opt/inline"));
        assert_eq!(command.args[..7], [
            "bridge",
            "provider-host",
            "--provider-id",
            "claude",
            "--lock-file",
            "/tmp/claude.lock",
            "--"
        ]
        .map(OsString::from));
        assert_eq!(command.args[7], OsString::from("/opt/claude"));
    }

    #[test]
    fn environment_keeps_claude_auth_and_drops_host_secrets() {
        for name in [
            "INLINE_TOKEN",
            "INLINE_ANYTHING",
            "GITHUB_TOKEN",
            "DATABASE_URL",
            "APP_PRIVATE_KEY",
            "CLAUDECODE",
            "SERVICE_PASSWORD",
        ] {
            assert!(should_scrub_environment_name(OsStr::new(name), &[]), "{name}");
        }
        for name in [
            "PATH",
            "HOME",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_BASE_URL",
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "AWS_ACCESS_KEY_ID",
            "SSH_AUTH_SOCK",
        ] {
            assert!(!should_scrub_environment_name(OsStr::new(name), &[]), "{name}");
        }
        assert!(!should_scrub_environment_name(
            OsStr::new("MY_TOOL_TOKEN"),
            &["MY_TOOL_TOKEN".into()]
        ));
    }

    #[test]
    fn explicit_environment_wins_over_defaults() {
        let mut options = LaunchOptions::new("/opt/claude", "/work");
        options.env.push(("CLAUDE_CODE_ENTRYPOINT".into(), "custom".into()));
        let command = options.command();
        let entrypoints: Vec<_> = command
            .env_set
            .iter()
            .filter(|(name, _)| name == "CLAUDE_CODE_ENTRYPOINT")
            .collect();
        assert_eq!(entrypoints.len(), 1);
        assert_eq!(entrypoints[0].1, OsString::from("custom"));
        assert!(!command.env_remove.contains(&OsString::from("CLAUDE_CODE_ENTRYPOINT")));
    }
}

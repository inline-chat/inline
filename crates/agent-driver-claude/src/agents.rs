//! Live Claude Code sessions on this machine (`claude agents --json`), for
//! telling whether a session is held by another client.

use std::time::Duration;

use serde::Deserialize;

use crate::options::CommandSpec;

/// One live session as `claude agents --json` reports it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct LiveSession {
    pub pid: Option<u32>,
    pub cwd: Option<String>,
    /// `interactive` (a terminal, the desktop app or an SDK host) or
    /// `background` (`claude --bg`).
    pub kind: String,
    pub session_id: String,
    pub name: Option<String>,
    /// `busy` or `idle`, when reported.
    pub status: Option<String>,
    pub started_at: Option<u64>,
}

/// Lists live sessions. `spec` supplies the program and environment of a
/// normal launch; its arguments are replaced.
pub async fn list_live_sessions(
    spec: &CommandSpec,
    include_completed: bool,
    timeout: Duration,
) -> std::io::Result<Vec<LiveSession>> {
    let mut command = tokio::process::Command::new(&spec.program);
    command
        .args(["agents", "--json"])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    if include_completed {
        command.arg("--all");
    }
    for name in &spec.env_remove {
        command.env_remove(name);
    }
    for (name, value) in &spec.env_set {
        command.env(name, value);
    }
    let output = tokio::time::timeout(timeout, command.output())
        .await
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "claude agents --json timed out")
        })??;
    if !output.status.success() {
        return Err(std::io::Error::other(format!(
            "claude agents --json failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    parse_live_sessions(&output.stdout)
}

pub fn parse_live_sessions(stdout: &[u8]) -> std::io::Result<Vec<LiveSession>> {
    serde_json::from_slice(stdout)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

/// The live session holding `session_id`, ignoring processes this bridge
/// owns.
pub fn holder<'a>(
    sessions: &'a [LiveSession],
    session_id: &str,
    own_pids: &[u32],
) -> Option<&'a LiveSession> {
    sessions.iter().find(|session| {
        session.session_id == session_id
            && !session.pid.is_some_and(|pid| own_pids.contains(&pid))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_agents_json_and_skips_own_processes() {
        let stdout = br#"[
          {"pid": 31528, "cwd": "/w", "kind": "interactive", "startedAt": 1793011861063,
           "sessionId": "9ecd1140-f695-46b9-aac5-5b7fe7aedd9a", "name": "hermes", "status": "busy"},
          {"pid": 4000, "cwd": "/w", "kind": "background", "sessionId": "s2", "future": true}
        ]"#;
        let sessions = parse_live_sessions(stdout).unwrap();
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].status.as_deref(), Some("busy"));
        assert_eq!(sessions[1].kind, "background");
        assert!(holder(&sessions, "9ecd1140-f695-46b9-aac5-5b7fe7aedd9a", &[]).is_some());
        assert!(holder(&sessions, "9ecd1140-f695-46b9-aac5-5b7fe7aedd9a", &[31528]).is_none());
        assert!(holder(&sessions, "missing", &[]).is_none());
    }
}

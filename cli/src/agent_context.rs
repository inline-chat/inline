//! Detects when the CLI runs inside a coding-agent harness, from the
//! environment markers those harnesses set. Detection list follows
//! Cloudflare's `cf` (`lib/agent-context.ts`), which links the evidence for
//! each variable.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct AgentHarness {
    pub(crate) id: &'static str,
}

/// Printed before root and group `--help` when an agent harness is detected,
/// so agents search instead of chaining nested help calls.
pub(crate) const DISCOVERY_HELP: &str = "\
=== AGENTS: COMMAND DISCOVERY ===
Do not explore commands by chaining nested --help calls. Start with:
  inline cli search \"<describe the task you want to accomplish>\"
It works offline and returns up to five JSON matches ({command, summary}).
Pick the best match instead of repeating similar searches, then run
`<command> --help` or `inline capabilities <command path> --compact` for exact flags.
Describe the action and resource type only; leave out names, IDs, and message text.
=== END AGENTS: COMMAND DISCOVERY ===

";

pub(crate) fn detect() -> Option<AgentHarness> {
    detect_from(|name| std::env::var(name).ok())
}

fn detect_from(env: impl Fn(&str) -> Option<String>) -> Option<AgentHarness> {
    let is = |name: &str, expected: &str| env(name).is_some_and(|value| value == expected);
    let set = |name: &str| {
        env(name).is_some_and(|value| {
            let value = value.trim().to_ascii_lowercase();
            !matches!(value.as_str(), "" | "0" | "false" | "no" | "off")
        })
    };

    let id = if is("CLAUDECODE", "1") {
        "claude-code"
    } else if set("CODEX_THREAD_ID") {
        "codex"
    } else if is("CURSOR_AGENT", "1") {
        "cursor-agent"
    } else if is("GEMINI_CLI", "1") {
        "gemini-cli"
    } else if set("AMP_CURRENT_THREAD_ID") {
        "amp"
    } else if is("OPENCODE", "1") {
        "opencode"
    } else if is("AUGMENT_AGENT", "1") {
        "auggie"
    } else if is("CRUSH", "1") {
        "crush"
    } else if is("COPILOT_AGENT", "1") {
        "copilot"
    } else if set("QWEN_CODE_SESSION_ID") {
        "qwen-code"
    } else if is("PI_CODING_AGENT", "true") {
        "pi"
    } else if set("OZ_RUN_ID") {
        "warp"
    } else if set("AI_AGENT") {
        "agent"
    } else {
        return None;
    };
    Some(AgentHarness { id })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detect_with(pairs: &[(&str, &str)]) -> Option<&'static str> {
        detect_from(|name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.to_string())
        })
        .map(|harness| harness.id)
    }

    #[test]
    fn detects_known_harnesses() {
        assert_eq!(detect_with(&[("CLAUDECODE", "1")]), Some("claude-code"));
        assert_eq!(detect_with(&[("CODEX_THREAD_ID", "abc")]), Some("codex"));
        assert_eq!(detect_with(&[("CURSOR_AGENT", "1")]), Some("cursor-agent"));
        assert_eq!(detect_with(&[("AI_AGENT", "something")]), Some("agent"));
    }

    #[test]
    fn ignores_absent_or_false_like_markers() {
        assert_eq!(detect_with(&[]), None);
        assert_eq!(detect_with(&[("CLAUDECODE", "0")]), None);
        assert_eq!(detect_with(&[("AI_AGENT", "false")]), None);
        assert_eq!(detect_with(&[("CODEX_THREAD_ID", " ")]), None);
    }
}

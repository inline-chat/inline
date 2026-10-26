//! Codex approval decisions with Codex's own labels.
//!
//! Inline offers exactly the decisions Codex advertises, labelled as the Codex
//! TUI labels them (`codex-rs/tui/src/bottom_pane/approval_overlay.rs` at
//! `rust-v0.164.0`). Each decision keeps its native value, which is sent back
//! verbatim as the response's `decision`.

use inline_agent_bridge::harness::{Decision, DecisionId, DecisionKind};
use serde_json::{Value, json};

/// Decisions for `item/commandExecution/requestApproval`, from `availableDecisions`.
///
/// Older app-servers omit `availableDecisions`; Codex then offers its legacy
/// default set (accept, accept for session, decline, cancel).
pub(crate) fn command_decisions(params: &Value) -> Vec<Decision> {
    let network = params
        .get("networkApprovalContext")
        .is_some_and(|value| !value.is_null());
    let extra_permissions = params
        .get("additionalPermissions")
        .is_some_and(|value| !value.is_null());
    let legacy;
    let available = match params.get("availableDecisions").and_then(Value::as_array) {
        Some(available) => available,
        None => {
            legacy = vec![
                json!("accept"),
                json!("acceptForSession"),
                json!("decline"),
                json!("cancel"),
            ];
            &legacy
        }
    };
    available
        .iter()
        .enumerate()
        .filter_map(|(index, native)| command_decision(index, native, network, extra_permissions))
        .collect()
}

fn command_decision(
    index: usize,
    native: &Value,
    network: bool,
    extra_permissions: bool,
) -> Option<Decision> {
    if let Some(name) = native.as_str() {
        let (label, kind, accepts_message) = match name {
            "accept" if network => ("Yes, just this once", DecisionKind::Accept, false),
            "accept" => ("Yes, proceed", DecisionKind::Accept, false),
            "acceptForSession" if network => (
                "Yes, and allow this host for this conversation",
                DecisionKind::AcceptForSession,
                false,
            ),
            "acceptForSession" if extra_permissions => (
                "Yes, and allow these permissions for this session",
                DecisionKind::AcceptForSession,
                false,
            ),
            "acceptForSession" => (
                "Yes, and don't ask again for this command in this session",
                DecisionKind::AcceptForSession,
                false,
            ),
            "decline" => (
                "No, continue without running it",
                DecisionKind::Decline,
                false,
            ),
            "cancel" => (
                "No, and tell Codex what to do differently",
                DecisionKind::Cancel,
                true,
            ),
            other => return Some(unknown_decision(index, other, native)),
        };
        return Some(decision(name, label, kind, accepts_message, native));
    }

    let object = native.as_object()?;
    if let Some(amendment) = object.get("acceptWithExecpolicyAmendment") {
        let command = amendment
            .get("execpolicy_amendment")
            .and_then(Value::as_array)?
            .iter()
            .map(|part| part.as_str().map(str::to_owned))
            .collect::<Option<Vec<_>>>()?;
        let prefix = strip_bash_lc_and_escape(&command);
        // The Codex TUI hides this choice when the prefix spans lines.
        if prefix.contains('\n') || prefix.contains('\r') {
            return None;
        }
        return Some(decision(
            &format!("acceptWithExecpolicyAmendment:{index}"),
            &format!("Yes, and don't ask again for commands that start with `{prefix}`"),
            DecisionKind::AcceptAndRemember,
            false,
            native,
        ));
    }
    if let Some(amendment) = object.get("applyNetworkPolicyAmendment") {
        let action = amendment
            .pointer("/network_policy_amendment/action")
            .and_then(Value::as_str)?;
        let (label, kind) = match action {
            "allow" => (
                "Yes, and allow this host in the future",
                DecisionKind::AcceptAndRemember,
            ),
            "deny" => (
                "No, and block this host in the future",
                DecisionKind::DeclineAndRemember,
            ),
            other => return Some(unknown_decision(index, other, native)),
        };
        return Some(decision(
            &format!("applyNetworkPolicyAmendment:{index}"),
            label,
            kind,
            false,
            native,
        ));
    }
    let name = object.keys().next()?.clone();
    Some(unknown_decision(index, &name, native))
}

/// Decisions for `item/fileChange/requestApproval`. Codex advertises no list
/// here; its TUI offers these three.
pub(crate) fn file_change_decisions() -> Vec<Decision> {
    vec![
        decision(
            "accept",
            "Yes, proceed",
            DecisionKind::Accept,
            false,
            &json!("accept"),
        ),
        decision(
            "acceptForSession",
            "Yes, and don't ask again for these files",
            DecisionKind::AcceptForSession,
            false,
            &json!("acceptForSession"),
        ),
        decision(
            "cancel",
            "No, and tell Codex what to do differently",
            DecisionKind::Cancel,
            true,
            &json!("cancel"),
        ),
    ]
}

/// Decisions for `item/permissions/requestApproval`, as the Codex TUI offers them.
/// The native value is the response; grants without `permissions` get the
/// requested profile filled in, deny grants nothing.
pub(crate) fn permissions_decisions() -> Vec<Decision> {
    vec![
        decision(
            "grantForTurn",
            "Yes, grant these permissions for this turn",
            DecisionKind::Accept,
            false,
            &json!({"scope": "turn"}),
        ),
        decision(
            "grantForTurnWithStrictAutoReview",
            "Yes, grant for this turn with strict auto review",
            DecisionKind::Accept,
            false,
            &json!({"scope": "turn", "strictAutoReview": true}),
        ),
        decision(
            "grantForSession",
            "Yes, grant these permissions for this session",
            DecisionKind::AcceptForSession,
            false,
            &json!({"scope": "session"}),
        ),
        decision(
            "deny",
            "No, continue without permissions",
            DecisionKind::Decline,
            false,
            &json!({"scope": "turn", "permissions": {}}),
        ),
    ]
}

/// Decisions for a URL-mode MCP elicitation, as the Codex TUI offers them.
pub(crate) fn elicitation_decisions() -> Vec<Decision> {
    vec![
        decision(
            "accept",
            "Yes, provide the requested info",
            DecisionKind::Accept,
            false,
            &json!("accept"),
        ),
        decision(
            "decline",
            "No, but continue without it",
            DecisionKind::Decline,
            false,
            &json!("decline"),
        ),
        decision(
            "cancel",
            "Cancel this request",
            DecisionKind::Cancel,
            false,
            &json!("cancel"),
        ),
    ]
}

fn decision(
    id: &str,
    label: &str,
    kind: DecisionKind,
    accepts_message: bool,
    native: &Value,
) -> Decision {
    Decision {
        id: DecisionId::new(id).expect("static decision id"),
        label: label.to_owned(),
        kind,
        description: None,
        accepts_message,
        native: native.clone(),
    }
}

fn unknown_decision(index: usize, name: &str, native: &Value) -> Decision {
    let id = DecisionId::new(format!("{name}:{index}"))
        .unwrap_or_else(|_| DecisionId::new(format!("decision:{index}")).expect("decision id"));
    Decision {
        id,
        label: name.to_owned(),
        kind: DecisionKind::Other,
        description: None,
        accepts_message: false,
        native: native.clone(),
    }
}

/// Codex TUI `strip_bash_lc_and_escape`: the script of `bash -lc <script>`,
/// otherwise the shell-escaped argv.
pub(crate) fn strip_bash_lc_and_escape(command: &[String]) -> String {
    if let [shell, flag, script] = command {
        let shell = shell.rsplit('/').next().unwrap_or(shell);
        if matches!(shell, "bash" | "zsh" | "sh") && matches!(flag.as_str(), "-lc" | "-c") {
            return script.clone();
        }
    }
    command
        .iter()
        .map(|part| shell_quote(part))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(part: &str) -> String {
    let safe = !part.is_empty()
        && part.chars().all(|character| {
            character.is_ascii_alphanumeric() || "_-+=/.,:@%^".contains(character)
        });
    if safe {
        part.to_owned()
    } else {
        format!("'{}'", part.replace('\'', "'\"'\"'"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn labels(decisions: &[Decision]) -> Vec<&str> {
        decisions
            .iter()
            .map(|decision| decision.label.as_str())
            .collect()
    }

    #[test]
    fn codex_0_164_union_keeps_every_advertised_decision_with_native_labels() {
        let decisions = command_decisions(&json!({
            "command": "cargo test",
            "availableDecisions": [
                "accept",
                {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["cargo", "test"]}},
                "cancel"
            ]
        }));
        assert_eq!(
            labels(&decisions),
            [
                "Yes, proceed",
                "Yes, and don't ask again for commands that start with `cargo test`",
                "No, and tell Codex what to do differently",
            ]
        );
        assert_eq!(decisions[1].kind, DecisionKind::AcceptAndRemember);
        assert_eq!(
            decisions[1].native,
            json!({"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["cargo", "test"]}})
        );
        assert!(decisions[2].accepts_message);
    }

    #[test]
    fn network_and_permission_contexts_change_labels_like_the_tui() {
        let decisions = command_decisions(&json!({
            "networkApprovalContext": {"host": "example.com", "protocol": "https"},
            "availableDecisions": [
                "accept",
                "acceptForSession",
                {"applyNetworkPolicyAmendment": {"network_policy_amendment": {"host": "example.com", "action": "allow"}}},
                {"applyNetworkPolicyAmendment": {"network_policy_amendment": {"host": "example.com", "action": "deny"}}},
                "decline"
            ]
        }));
        assert_eq!(
            labels(&decisions),
            [
                "Yes, just this once",
                "Yes, and allow this host for this conversation",
                "Yes, and allow this host in the future",
                "No, and block this host in the future",
                "No, continue without running it",
            ]
        );
        assert_eq!(decisions[3].kind, DecisionKind::DeclineAndRemember);
        let ids: std::collections::BTreeSet<_> = decisions
            .iter()
            .map(|decision| decision.id.clone())
            .collect();
        assert_eq!(ids.len(), decisions.len(), "decision ids are unique");
    }

    #[test]
    fn unknown_future_decisions_are_offered_with_their_native_name() {
        let decisions = command_decisions(&json!({
            "availableDecisions": ["accept", "acceptAlways", {"futureChoice": {"x": 1}}]
        }));
        assert_eq!(
            labels(&decisions),
            ["Yes, proceed", "acceptAlways", "futureChoice"]
        );
        assert_eq!(decisions[2].native, json!({"futureChoice": {"x": 1}}));
    }

    #[test]
    fn multiline_prefixes_are_hidden_and_legacy_requests_get_the_default_set() {
        let decisions = command_decisions(&json!({
            "availableDecisions": [
                {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["bash", "-lc", "a\nb"]}},
                "decline"
            ]
        }));
        assert_eq!(labels(&decisions), ["No, continue without running it"]);
        assert_eq!(command_decisions(&json!({})).len(), 4);
    }

    #[test]
    fn prefixes_follow_the_tui_shell_rendering() {
        assert_eq!(
            strip_bash_lc_and_escape(&["/bin/zsh".into(), "-lc".into(), "npm run x".into()]),
            "npm run x"
        );
        assert_eq!(
            strip_bash_lc_and_escape(&["git".into(), "commit".into(), "-m".into(), "a b".into()]),
            "git commit -m 'a b'"
        );
    }
}

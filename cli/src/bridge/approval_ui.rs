//! Approval cards, callbacks, and shared-thread status projection.

use super::*;

pub(super) fn approval_dispatch_chat_id(
    event: &ClientEvent,
    store: &BridgeStore,
) -> Result<Option<i64>, Box<dyn std::error::Error>> {
    let ClientEvent::MessageActionInvoked { chat_id, data, .. } = event else {
        return Ok(None);
    };
    let Ok(callback) = serde_json::from_slice::<ApprovalCallback>(data) else {
        return Ok(None);
    };
    if callback.version != 1 {
        return Ok(None);
    }
    let Some(record) = store.get_approval(&callback.token)? else {
        return Ok(None);
    };
    if record.action_chat_id != chat_id.get() {
        return Ok(None);
    }
    Ok(Some(record.origin_chat_id))
}

pub(super) async fn send_approval(
    bot: &InlineClient,
    chat_id: i64,
    request: &inline_agent_bridge::ApprovalRequest,
    provider_name: &str,
    host_label: &str,
    workspace_label: &str,
) -> Result<InlineId, Box<dyn std::error::Error>> {
    let token = approval_token(request);
    let actions = approval_actions(request, &token)?;
    if actions.rows.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Agent approval request did not offer a decision",
        )
        .into());
    }
    let mut message_request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(chat_id),
        },
        approval_prompt_text(request, provider_name, host_label, workspace_label),
    );
    message_request.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("approval-{token}"),
    )?);
    message_request.random_id = Some(interaction_random_id("approval", &token));
    message_request.notification_mode = BridgeNotificationClass::ActionRequired.notification_mode();
    let mutation = send_interactive_text_with_retry(
        bot,
        SendInteractiveTextRequest {
            message: message_request,
            actions,
        },
    )
    .await
    .map_err(|_| {
        io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "approval publication could not be confirmed",
        )
    })?;
    mutation.message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "approval publication completed without a message identity",
        )
        .into()
    })
}

fn approval_actions(
    request: &inline_agent_bridge::ApprovalRequest,
    token: &str,
) -> Result<MessageActions, serde_json::Error> {
    let mut buttons = Vec::new();
    for (index, option) in request.options.iter().take(8).enumerate() {
        let text = match option {
            ApprovalOption::ApproveOnce => "Approve once",
            ApprovalOption::ApproveForSession => "Allow for session",
            ApprovalOption::Reject => "Reject",
            ApprovalOption::CancelTurn => "Stop",
            ApprovalOption::ProviderChoice { label, .. } => label.as_str(),
        };
        let data = serde_json::to_vec(&ApprovalCallback {
            version: 1,
            token: token.to_string(),
            decision: CallbackDecision::Option { index },
        })?;
        buttons.push(MessageActionButton {
            action_id: format!("bridge_approval_{index}"),
            text: truncate_utf16(text, 64),
            kind: MessageActionKind::Callback { data },
        });
    }
    Ok(MessageActions {
        rows: buttons
            .chunks(2)
            .map(|actions| MessageActionRow {
                actions: actions.to_vec(),
            })
            .collect(),
    })
}

pub(super) fn approval_prompt_text(
    request: &inline_agent_bridge::ApprovalRequest,
    provider_name: &str,
    host_label: &str,
    workspace_label: &str,
) -> String {
    let provider = bounded_approval_label(provider_name, "Agent");
    let host = bounded_approval_label(host_label, "this computer");
    let workspace = bounded_approval_label(workspace_label, "the selected project");
    let mut text = format!(
        "{provider} on {host} needs approval in `{workspace}`. Only the bot owner can approve."
    );

    let summary = safe_diagnostic(&request.summary);
    let summary = sanitize_visible_transcript(&summary).unwrap_or_default();
    if !summary.is_empty() && summary != "[redacted provider diagnostic]" {
        text.push_str("\n\n");
        text.push_str(&truncate(&summary, 240));
    }
    if let Some(command) = request
        .command
        .as_deref()
        .and_then(sanitize_visible_command)
    {
        text.push_str("\n\nCommand: ");
        text.push_str(&markdown_code_span(&command));
    }
    text
}

fn bounded_approval_label(value: &str, fallback: &str) -> String {
    let value = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let value = value.replace('`', "'");
    if value.is_empty() {
        fallback.to_string()
    } else {
        truncate(&value, 80)
    }
}

pub(super) fn approval_resolution_text(decision: &ApprovalDecision) -> &'static str {
    match decision {
        ApprovalDecision::ApproveOnce => "Approved once.",
        ApprovalDecision::ApproveForSession => "Approved for this session.",
        ApprovalDecision::Reject => "Rejected.",
        ApprovalDecision::CancelTurn => "Stop requested.",
        ApprovalDecision::ProviderChoice { .. } => "Choice applied.",
    }
}

pub(super) fn approval_decisions(
    request: &inline_agent_bridge::ApprovalRequest,
) -> Vec<ApprovalDecision> {
    request
        .options
        .iter()
        .take(8)
        .map(|option| match option {
            ApprovalOption::ApproveOnce => ApprovalDecision::ApproveOnce,
            ApprovalOption::ApproveForSession => ApprovalDecision::ApproveForSession,
            ApprovalOption::Reject => ApprovalDecision::Reject,
            ApprovalOption::CancelTurn => ApprovalDecision::CancelTurn,
            ApprovalOption::ProviderChoice { option_id, .. } => ApprovalDecision::ProviderChoice {
                option_id: option_id.clone(),
            },
        })
        .collect()
}

pub(super) fn approval_token(request: &inline_agent_bridge::ApprovalRequest) -> String {
    let mut digest = Sha256::new();
    digest.update(request.turn_id.as_str().as_bytes());
    digest.update([0]);
    digest.update(request.approval_id.as_bytes());
    let digest = digest.finalize();
    digest[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) async fn clear_approval(
    bot: &InlineClient,
    chat_id: i64,
    message_id: InlineId,
    text: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(chat_id),
                message_id,
                text: text.to_string(),
                external_id: None,
                parse_markdown: true,
            },
            actions: MessageActions::default(),
        },
    )
    .await?;
    Ok(())
}

pub(super) async fn clear_shared_approval_status(
    bot: &InlineClient,
    approval: &ApprovalRecord,
    text: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let Some(message_id) = approval.origin_status_message_id else {
        return Ok(());
    };
    edit_message_with_retry(
        bot,
        EditMessageRequest {
            chat_id: InlineId::new(approval.origin_chat_id),
            message_id: InlineId::new(message_id),
            text: text.to_string(),
            external_id: None,
            parse_markdown: true,
        },
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> inline_agent_bridge::ApprovalRequest {
        inline_agent_bridge::ApprovalRequest {
            approval_id: "approval-1".to_string(),
            turn_id: inline_agent_bridge::TurnId::new("turn-1").expect("turn"),
            summary: "Run the focused test suite".to_string(),
            command: Some("cargo test -p inline-agent-bridge".to_string()),
            cwd: Some(PathBuf::from("/private/project")),
            options: vec![ApprovalOption::ApproveOnce, ApprovalOption::Reject],
        }
    }

    #[test]
    fn card_has_bounded_context_and_sanitized_command_without_absolute_cwd() {
        let mut request = request();
        request.command = Some(
            "TOKEN=private deploy --api-key secret /Users/alice/dev/inline https://example.com/run?signature=hidden"
                .to_string(),
        );
        request.summary =
            "Edit /Users/alice/private/project/src/lib.rs using https://user:opaque@example.com/run?signature=hidden"
                .to_string();
        let text = approval_prompt_text(&request, "Codex", "Mo's MacBook", "inline");
        assert!(text.contains("Codex on Mo's MacBook"));
        assert!(text.contains("in `inline`"));
        assert!(text.contains("Only the bot owner can approve."));
        assert!(text.contains("Edit [local-path] using https://example.com/run?[redacted]"));
        assert!(text.contains("TOKEN=[redacted]"));
        assert!(text.contains("--api-key [redacted]"));
        assert!(text.contains("https://example.com/run?[redacted]"));
        assert!(text.contains("[local-path]"));
        assert!(!text.contains("/Users/alice"));
        assert!(!text.contains("private"));
        assert!(!text.contains("secret"));
        assert!(!text.contains("hidden"));
        assert!(!text.contains("/private/project"));
    }

    #[test]
    fn resolution_copy_matches_the_selected_scope() {
        assert_eq!(
            approval_resolution_text(&ApprovalDecision::ApproveOnce),
            "Approved once."
        );
        assert_eq!(
            approval_resolution_text(&ApprovalDecision::ApproveForSession),
            "Approved for this session."
        );
        assert_eq!(
            approval_resolution_text(&ApprovalDecision::Reject),
            "Rejected."
        );
        assert_eq!(
            approval_resolution_text(&ApprovalDecision::CancelTurn),
            "Stop requested."
        );
    }

    #[test]
    fn approval_actions_preserve_session_scope_and_fit_mobile_rows() {
        let mut request = request();
        request.options = vec![
            ApprovalOption::ApproveForSession,
            ApprovalOption::ApproveOnce,
            ApprovalOption::Reject,
            ApprovalOption::CancelTurn,
        ];

        let actions = approval_actions(&request, "token").expect("approval actions");

        assert_eq!(actions.rows.len(), 2);
        assert!(actions.rows.iter().all(|row| row.actions.len() <= 2));
        assert_eq!(actions.rows[0].actions[0].text, "Allow for session");
    }
}

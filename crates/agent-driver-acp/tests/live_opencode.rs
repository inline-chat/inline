use std::path::PathBuf;
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::{
    AgentDriver, AgentEvent, ApprovalDecision, SessionSpec, TurnInput, TurnOptions, TurnOutcome,
};
use inline_agent_driver_acp::{AcpLaunchDescriptor, spawn_acp_driver};

const LIVE_TIMEOUT: Duration = Duration::from_secs(120);

/// Authenticated local smoke test for the native OpenCode ACP server.
///
/// This is ignored in normal CI because it requires an installed, logged-in
/// OpenCode CLI. Override the executable with `INLINE_ACP_OPENCODE_BIN`.
#[tokio::test]
#[ignore = "requires an installed and authenticated OpenCode CLI"]
async fn installed_opencode_completes_a_read_only_turn() {
    tokio::time::timeout(LIVE_TIMEOUT, async {
        let program = std::env::var_os("INLINE_ACP_OPENCODE_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("opencode"));
        let spawned = spawn_acp_driver(AcpLaunchDescriptor::opencode(program), "live-test")
            .await
            .expect("launch native OpenCode ACP server");
        let cwd = std::env::current_dir().expect("current directory");
        let catalog = spawned
            .driver
            .settings_catalog(&cwd)
            .await
            .expect("load OpenCode settings catalog");
        assert!(
            !catalog.models.is_empty(),
            "OpenCode returned no model choices"
        );
        let session = spawned
            .driver
            .start_session(SessionSpec { cwd })
            .await
            .expect("start OpenCode session");
        let mut turn = spawned
            .driver
            .start_turn(
                &session,
                TurnInput {
                    text: "Do not use tools. Reply with exactly: inline acp ready".to_string(),
                    attachments: Vec::new(),
                    client_message_id: Some("live-opencode-smoke".to_string()),
                },
                TurnOptions::default(),
            )
            .await
            .expect("start OpenCode turn");
        let mut completed_text = None;
        let mut outcome = None;
        while let Some(event) = turn.events.next().await {
            match event.expect("normalized OpenCode event") {
                AgentEvent::ApprovalRequested(request) => {
                    spawned
                        .driver
                        .resolve_approval(&request.approval_id, ApprovalDecision::Reject)
                        .await
                        .expect("reject unexpected OpenCode tool request");
                }
                AgentEvent::AgentTextCompleted { text, .. } => completed_text = Some(text),
                AgentEvent::TurnCompleted { outcome: value, .. } => {
                    outcome = Some(value);
                    break;
                }
                _ => {}
            }
        }
        assert_eq!(outcome, Some(TurnOutcome::Completed));
        assert!(
            completed_text
                .as_deref()
                .is_some_and(|text| text.to_ascii_lowercase().contains("inline acp ready")),
            "OpenCode did not return the expected completion: {completed_text:?}"
        );
        spawned
            .driver
            .shutdown()
            .await
            .expect("shutdown OpenCode ACP server");
    })
    .await
    .expect("live OpenCode ACP smoke test timed out");
}

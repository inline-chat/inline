use std::path::PathBuf;
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::{
    AgentDriver, AgentEvent, ApprovalDecision, HostToolCall, HostToolConfiguration, HostToolFuture,
    HostToolHandler, HostToolResult, HostToolSpec, ProcessHostConfig, SessionSpec, TurnInput,
    TurnOptions, TurnOutcome,
};
use inline_agent_driver_acp::{provider_support, spawn_acp_driver};

const LIVE_TIMEOUT: Duration = Duration::from_secs(180);

#[derive(Debug)]
struct NeverCalledHostToolHandler;

impl HostToolHandler for NeverCalledHostToolHandler {
    fn call<'a>(&'a self, _call: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(async { HostToolResult::failure("not called") })
    }
}

/// Authenticated local smoke test for Amp through its ACP adapter.
///
/// This is ignored in normal CI because it requires a built compatible adapter
/// and an installed, authenticated Amp CLI. Point `INLINE_ACP_AMP_BIN` at the
/// adapter entrypoint and `INLINE_ACP_AMP_CLI` at the exact Amp executable.
#[tokio::test]
#[ignore = "requires a compatible Amp ACP adapter and authenticated Amp CLI"]
async fn installed_amp_completes_a_direct_new_session_turn() {
    tokio::time::timeout(LIVE_TIMEOUT, async {
        let program = std::env::var_os("INLINE_ACP_AMP_BIN")
            .map(PathBuf::from)
            .expect("INLINE_ACP_AMP_BIN must name the compatible adapter entrypoint");
        let provider_runtime = std::env::var_os("INLINE_ACP_AMP_CLI")
            .map(PathBuf::from)
            .expect("INLINE_ACP_AMP_CLI must name the installed Amp executable");
        let mut descriptor = provider_support("amp")
            .expect("Amp support metadata")
            .launch_descriptor(Some(program));
        descriptor.provider_runtime = Some(provider_runtime);
        let process_host_root = tempfile::tempdir().expect("process host directory");
        if let Some(executable) = std::env::var_os("INLINE_ACP_PROCESS_HOST_BIN") {
            descriptor.process_host = Some(ProcessHostConfig {
                executable: PathBuf::from(executable),
                lock_file: process_host_root.path().join("provider.process.lock"),
            });
        }
        let spawned = spawn_acp_driver(descriptor, "live-test")
            .await
            .expect("launch Amp ACP adapter");
        if std::env::var_os("INLINE_ACP_WITH_HOST_TOOLS").is_some() {
            spawned
                .driver
                .configure_host_tools(HostToolConfiguration {
                    specs: vec![HostToolSpec {
                        name: "get_current_context".to_string(),
                        description: "Get current Inline context.".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "additionalProperties": false
                        }),
                        read_only: true,
                    }],
                    handler: std::sync::Arc::new(NeverCalledHostToolHandler),
                })
                .expect("configure Inline host tool fixture");
        }
        let cwd = std::env::current_dir().expect("current directory");
        let session = spawned
            .driver
            .start_session(SessionSpec { cwd })
            .await
            .expect("start Amp session");
        let mut turn = spawned
            .driver
            .start_turn(
                &session,
                TurnInput {
                    text: "Do not use tools. Reply with exactly: inline amp acp ready".to_string(),
                    attachments: Vec::new(),
                    client_message_id: Some("live-amp-smoke".to_string()),
                },
                TurnOptions::default(),
            )
            .await
            .expect("start Amp turn");
        let mut completed_text = None;
        let mut outcome = None;
        while let Some(event) = turn.events.next().await {
            match event.expect("normalized Amp event") {
                AgentEvent::ApprovalRequested(request) => {
                    spawned
                        .driver
                        .resolve_approval(&request.approval_id, ApprovalDecision::Reject)
                        .await
                        .expect("reject unexpected Amp tool request");
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
                .is_some_and(|text| text.to_ascii_lowercase().contains("inline amp acp ready")),
            "Amp did not return the expected completion: {completed_text:?}"
        );
        spawned
            .driver
            .shutdown()
            .await
            .expect("shutdown Amp ACP adapter");
    })
    .await
    .expect("live Amp ACP smoke test timed out");
}

//! Opt-in live smoke: two chats in one folder use isolated ACP/MCP bindings.
//! cargo run -p inline-agent-driver-acp --example acp_tools
use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{
    HostToolCall, HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult,
    HostToolSpec, TurnOutcome,
};
use inline_agent_driver_acp::{AcpLaunchDescriptor, IsolatedAcpHarness};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Default)]
struct Probe {
    sessions: Mutex<HashMap<String, String>>,
    calls: Mutex<Vec<String>>,
}
impl HostToolHandler for Probe {
    fn call<'a>(&'a self, call: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(async move {
            let expected = self
                .sessions
                .lock()
                .unwrap()
                .get(call.session_id.as_str())
                .cloned();
            if call.tool_name != "inline_probe"
                || expected.as_deref() != call.arguments.get("nonce").and_then(|v| v.as_str())
            {
                return HostToolResult::failure("wrong session binding");
            }
            self.calls.lock().unwrap().push(call.session_id.to_string());
            HostToolResult::success(format!("proof-{}", expected.unwrap()))
        })
    }
}
fn spec(folder: std::path::PathBuf) -> OpenSpec {
    OpenSpec {
        mode: OpenMode::Start,
        folder,
        settings: SettingsChange {
            model: if std::env::var("INLINE_ACP_TEST_PROVIDER").as_deref() == Ok("amp") {
                Some("low".into())
            } else {
                std::env::var("INLINE_ACP_OPENCODE_MODEL").ok()
            },
            ..Default::default()
        },
        instructions: None,
        title: None,
        after: None,
        output_mode: OutputMode::Detailed,
    }
}
async fn run(session: &dyn Session, nonce: &str) {
    let mut events = session.events();
    session.send(Input { id: InputId::new(nonce).unwrap(), content: InputContent::text(format!("Use only the inline_probe MCP tool, exactly once, with nonce {nonce}. Do not read files or run other tools. Reply with only the tool's returned proof string.")), delivery: Delivery::Turn, origin: Origin::Owner { user: UserId(1) } }).await.unwrap();
    let mut answer = String::new();
    loop {
        match events.next().await.expect("session stream ended").event {
            Event::Interaction(interaction) => {
                session
                    .control(Op::Answer {
                        interaction: interaction.id,
                        response: InteractionResponse::Cancel,
                        by: UserId(1),
                    })
                    .await
                    .unwrap();
            }
            Event::Item(Item {
                update:
                    ItemUpdate::Completed {
                        body: ItemBody::Message { text, .. },
                        ..
                    },
                ..
            }) => answer.push_str(&text),
            Event::Turn {
                phase: TurnPhase::Completed { outcome, error, .. },
                ..
            } => {
                assert_eq!(outcome, TurnOutcome::Completed, "{error:?}");
                break;
            }
            _ => {}
        }
    }
    assert!(
        answer.contains(&format!("proof-{nonce}")),
        "tool answer missing: {answer}"
    );
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args().skip(1).eq(["bridge", "inline-tools-mcp"]) {
        return inline_agent_driver_acp::run_inline_tools_mcp().await;
    }
    tokio::time::timeout(Duration::from_secs(180), async {
        let workspace = tempfile::tempdir().unwrap();
        let folder = workspace.path().canonicalize().unwrap();
        let tools = Arc::new(Probe::default());
        let mut descriptor = AcpLaunchDescriptor::opencode(std::env::var_os("INLINE_ACP_OPENCODE_BIN").unwrap_or_else(|| "opencode".into()));
        if std::env::var("INLINE_ACP_TEST_PROVIDER").as_deref() == Ok("amp") {
            descriptor = inline_agent_driver_acp::provider_support("amp").unwrap().launch_descriptor(Some(std::env::var_os("INLINE_ACP_AMP_BIN").expect("Amp adapter").into()));
            descriptor.provider_runtime = Some(std::env::var_os("INLINE_ACP_AMP_CLI").expect("Amp CLI").into());
        }
        if let Some(executable) = std::env::var_os("INLINE_ACP_PROCESS_HOST_BIN") {
            descriptor.process_host = Some(inline_agent_bridge::ProcessHostConfig {
                executable: executable.into(), lock_file: folder.join("provider.process.lock"), provider_id: descriptor.provider_id.to_string(),
            });
        }
        let harness = IsolatedAcpHarness::connect(descriptor, "live-tools", Some(HostToolConfiguration {
            specs: vec![HostToolSpec { name: "inline_probe".into(), description: "Returns a proof for this test session.".into(), input_schema: serde_json::json!({"type":"object","properties":{"nonce":{"type":"string"}},"required":["nonce"],"additionalProperties":false}), read_only: true }], handler: tools.clone(),
        })).await.unwrap();
        let first = harness.open(spec(folder.clone())).await.unwrap();
        let second = harness.open(spec(folder)).await.unwrap();
        tools.sessions.lock().unwrap().insert(first.key().session.to_string(), "alpha-731".into());
        tools.sessions.lock().unwrap().insert(second.key().session.to_string(), "beta-842".into());
        tokio::join!(run(first.as_ref(), "alpha-731"), run(second.as_ref(), "beta-842"));
        let calls = tools.calls.lock().unwrap().clone();
        assert!(calls.contains(&first.key().session.to_string()));
        assert!(calls.contains(&second.key().session.to_string()));
        assert_eq!(first.release().await.unwrap().outcome, ReleaseOutcome::NativeReleased);
        assert_eq!(second.release().await.unwrap().outcome, ReleaseOutcome::NativeReleased);
        harness.shutdown().await.unwrap();
        eprintln!("PASS: live ACP bridge v2, two simultaneous same-folder sessions, isolated MCP tools, native release");
    }).await.expect("live tool test timed out");
    Ok(())
}

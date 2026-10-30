use std::path::PathBuf;
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{ProcessHostConfig, TurnOutcome};
use inline_agent_driver_acp::{AcpLaunchDescriptor, IsolatedAcpHarness, require_opencode_v2};

const LIVE_TIMEOUT: Duration = Duration::from_secs(180);

async fn reply(session: &dyn Session, id: &str, text: &str) -> String {
    let mut events = session.events();
    session
        .send(Input {
            id: InputId::new(id).unwrap(),
            content: InputContent::text(text),
            origin: Origin::Owner { user: UserId(1) },
            delivery: Delivery::Turn,
        })
        .await
        .expect("start OpenCode v2 turn through the harness");
    let mut completed_text = String::new();
    let mut outcome = None;
    while let Some(envelope) = events.next().await {
        match envelope.event {
            Event::Interaction(interaction) => {
                session
                    .control(Op::Answer {
                        interaction: interaction.id,
                        response: InteractionResponse::Cancel,
                        by: UserId(1),
                    })
                    .await
                    .expect("reject unexpected interaction");
            }
            Event::Item(Item {
                update:
                    ItemUpdate::Completed {
                        body: ItemBody::Message { text, .. },
                        ..
                    },
                ..
            }) => completed_text.push_str(&text),
            Event::Turn {
                phase:
                    TurnPhase::Completed {
                        outcome: value,
                        error,
                        ..
                    },
                ..
            } => {
                assert!(error.is_none(), "OpenCode turn error: {error:?}");
                outcome = Some(value);
                break;
            }
            _ => {}
        }
    }
    assert_eq!(outcome, Some(TurnOutcome::Completed));
    completed_text
}

fn spec(mode: OpenMode, cwd: PathBuf) -> OpenSpec {
    OpenSpec {
        mode,
        folder: cwd,
        settings: SettingsChange {
            model: std::env::var("INLINE_ACP_OPENCODE_MODEL").ok(),
            ..Default::default()
        },
        instructions: None,
        title: None,
        after: None,
        output_mode: OutputMode::Detailed,
    }
}

async fn launch(descriptor: AcpLaunchDescriptor) -> IsolatedAcpHarness {
    let harness = IsolatedAcpHarness::connect(descriptor, "live-test", None)
        .await
        .expect("launch OpenCode ACP");
    let info = harness.describe();
    let version = require_opencode_v2(info.executable.version.as_deref().unwrap_or_default())
        .expect("running v2");
    eprintln!("OpenCode {version}: initialize accepted");
    harness
}

/// Uses a scratch workspace, never a real repository. Auth stays provider-owned.
/// Optional INLINE_ACP_PROCESS_HOST_BIN exercises the production process host.
#[tokio::test]
#[ignore = "requires an installed and authenticated OpenCode v2 CLI"]
async fn installed_opencode_v2_completes_and_resumes_across_processes() {
    tokio::time::timeout(LIVE_TIMEOUT, async {
        let program = std::env::var_os("INLINE_ACP_OPENCODE_BIN")
            .map(PathBuf::from).unwrap_or_else(|| PathBuf::from("opencode"));
        let workspace = tempfile::tempdir().expect("scratch workspace");
        let cwd = workspace.path().canonicalize().unwrap();
        let host_root = tempfile::tempdir().expect("process host directory");
        let mut descriptor = AcpLaunchDescriptor::opencode(program);
        if let Some(executable) = std::env::var_os("INLINE_ACP_PROCESS_HOST_BIN") {
            descriptor.process_host = Some(ProcessHostConfig {
                executable: PathBuf::from(executable),
                lock_file: host_root.path().join("provider.process.lock"),
                provider_id: "opencode".into(),
            });
        }
        let harness = launch(descriptor.clone()).await;
        let catalog = harness.catalog(CatalogScope { folder: Some(cwd.clone()), session: None }).await.expect("settings catalog");
        assert!(!catalog.models.is_empty(), "no model choices");
        if let Ok(model) = std::env::var("INLINE_ACP_OPENCODE_MODEL") {
            assert!(catalog.models.iter().any(|choice| choice.value == model), "requested model not in catalog");
        }
        let session = harness.open(spec(OpenMode::Start, cwd.clone())).await.expect("create session");
        let text = reply(session.as_ref(), "initial",
            "Do not use tools. Remember this marker for the next message: indigo-orbit-731. Reply exactly: inline acp ready").await;
        assert!(text.to_ascii_lowercase().contains("inline acp ready"), "unexpected completion: {text:?}");
        let native_session = session.key().session.clone();
        harness.shutdown().await.expect("shutdown first process");
        drop(session);
        drop(harness);

        let resumed = launch(descriptor).await;
        let session = resumed.open(spec(OpenMode::Resume { session: native_session }, cwd)).await.expect("resume in fresh process");
        let text = reply(session.as_ref(), "resumed",
            "Do not use tools. Reply with only the marker I asked you to remember in my previous message.").await;
        assert!(text.contains("indigo-orbit-731"), "resumed session lost context: {text:?}");
        resumed.shutdown().await.expect("shutdown resumed process");
        eprintln!("OpenCode v2 through bridge v2 harness: catalog, turn, shutdown, cross-process resume and retained context passed");
    }).await.expect("OpenCode v2 smoke timed out");
}

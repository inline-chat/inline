use std::path::PathBuf;
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{ProcessHostConfig, TurnOutcome};
use inline_agent_driver_acp::{IsolatedAcpHarness, provider_support};

fn spec(mode: OpenMode, folder: PathBuf) -> OpenSpec {
    OpenSpec {
        mode,
        folder,
        settings: SettingsChange {
            model: Some("low".into()),
            ..Default::default()
        },
        instructions: None,
        title: None,
        after: None,
        output_mode: OutputMode::Detailed,
    }
}

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
        .unwrap();
    let mut answer = String::new();
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
                assert!(error.is_none());
                return answer;
            }
            _ => {}
        }
    }
    panic!("Amp stream ended before completion")
}

#[tokio::test]
#[ignore = "requires current pinned Amp adapter, authenticated Amp CLI and built Inline process host"]
async fn amp_bridge_v2_retains_context_after_release_and_process_restart() {
    tokio::time::timeout(Duration::from_secs(180), async {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().canonicalize().unwrap();
        let mut descriptor = provider_support("amp").unwrap().launch_descriptor(Some(
            std::env::var_os("INLINE_ACP_AMP_BIN").expect("Amp adapter path").into(),
        ));
        descriptor.provider_runtime = Some(std::env::var_os("INLINE_ACP_AMP_CLI").expect("Amp CLI path").into());
        descriptor.process_host = Some(ProcessHostConfig {
            executable: std::env::var_os("INLINE_ACP_PROCESS_HOST_BIN").expect("Inline CLI path").into(),
            lock_file: folder.join("provider.process.lock"), provider_id: "amp".into(),
        });
        let harness = IsolatedAcpHarness::connect(descriptor.clone(), "live-test", None).await.unwrap();
        assert_eq!(harness.describe().provider.as_str(), "amp");
        let catalog = harness.catalog(CatalogScope { folder: Some(folder.clone()), session: None }).await.unwrap();
        assert!(catalog.models.iter().any(|model| model.value == "low"));
        assert!(catalog.commands.iter().any(|command| command.name == "init"));
        let session = harness.open(spec(OpenMode::Start, folder.clone())).await.unwrap();
        let answer = reply(session.as_ref(), "initial", "Do not use tools. Remember this marker: emerald-orbit-593. Reply exactly: inline amp v2 ready").await;
        assert!(answer.to_lowercase().contains("inline amp v2 ready"), "{answer}");
        let id = session.key().session.clone();
        assert_eq!(session.release().await.unwrap().outcome, ReleaseOutcome::NativeReleased);
        harness.shutdown().await.unwrap();
        drop(session);
        drop(harness);
        let harness = IsolatedAcpHarness::connect(descriptor, "live-test", None).await.unwrap();
        let resumed = harness.open(spec(OpenMode::Resume { session: id.clone() }, folder)).await.unwrap();
        assert_eq!(resumed.key().session, id);
        let answer = reply(resumed.as_ref(), "resumed", "Do not use tools. Reply with only the marker I asked you to remember in my previous message.").await;
        assert!(answer.contains("emerald-orbit-593"), "context was lost: {answer}");
        assert_eq!(resumed.release().await.unwrap().outcome, ReleaseOutcome::NativeReleased);
        harness.shutdown().await.unwrap();
        eprintln!("PASS: Amp bridge v2 catalog, settings, advertised commands, turn, native release, process restart and retained context");
    }).await.expect("Amp live continuity timed out");
}

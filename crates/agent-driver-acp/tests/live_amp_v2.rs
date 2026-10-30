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
    tokio::time::timeout(Duration::from_secs(480), async {
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
        // Cross several bridge idle ticks before releasing, then continue the
        // same native conversation repeatedly after the full process restart.
        for turn in 0..3 {
            tokio::time::sleep(Duration::from_secs(16)).await;
            let answer = reply(session.as_ref(), &format!("warm-{turn}"),
                "Do not use tools. Reply only with the marker you are remembering.").await;
            assert!(answer.contains("emerald-orbit-593"), "warm turn {turn}: {answer}");
        }
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
        for turn in 0..3 {
            if turn == 1 { tokio::time::sleep(Duration::from_secs(16)).await; }
            let answer = reply(resumed.as_ref(), &format!("continued-{turn}"),
                "Do not use tools. Reply only with the marker you are remembering.").await;
            assert!(answer.contains("emerald-orbit-593"), "resumed turn {turn}: {answer}");
        }
        assert_eq!(resumed.release().await.unwrap().outcome, ReleaseOutcome::NativeReleased);
        harness.shutdown().await.unwrap();
        eprintln!("PASS: Amp bridge v2 catalog, settings, advertised commands, eight turns across idle ticks and process restart, retained context and native release");
    }).await.expect("Amp live continuity timed out");
}

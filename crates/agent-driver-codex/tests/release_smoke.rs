//! Opt-in real-provider acceptance. Creates only a new disposable conversation;
//! never resumes, edits or deletes an existing user's conversation.

use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::{
    AgentDriver, AgentEvent, AgentMessagePhase, AgentMessageUpdate, AgentSessionCatalog, HistoryWindow, InstallationId, ProviderId,
    ProviderInstanceRef, ProviderSessionId, ProviderSessionRef, ResumeSessionSpec,
    SessionItemPayload, SessionPageSize, SessionQuery, SessionReadRequest, SessionReplay,
    SessionSpec, TurnInput, TurnOptions, TurnOutcome, WorkspaceId,
};
use inline_agent_driver_codex::{
    CodexAppServerTransport, CodexDriverWriter, CodexLaunchConfig, CodexSessionCatalog,
    SpawnedCodexDriver, spawn_codex_driver,
};

type TestResult<T> = Result<T, Box<dyn std::error::Error>>;

async fn reply(
    driver: &inline_agent_driver_codex::CodexAppServerDriver<CodexDriverWriter>,
    session: &ProviderSessionId,
    text: &str,
    correlation: &str,
) -> TestResult<String> {
    let mut turn = driver
        .start_turn(
            session,
            TurnInput {
                text: text.into(),
                attachments: vec![],
                client_message_id: Some(correlation.into()),
            },
            TurnOptions::default(),
        )
        .await?;
    let mut answer = String::new();
    let mut messages: Vec<(String, Option<AgentMessagePhase>, String)> = Vec::new();
    while let Some(event) = turn.events.next().await {
        match event? {
            AgentEvent::AgentTextDelta { text, .. } => answer.push_str(&text),
            AgentEvent::AgentTextCompleted { text, .. } => answer = text,
            AgentEvent::AgentMessage { item_id, phase, update, .. } => {
                let index = messages.iter().position(|(id, _, _)| id == &item_id)
                    .unwrap_or_else(|| {
                        messages.push((item_id, None, String::new()));
                        messages.len() - 1
                    });
                let (_, current_phase, text) = &mut messages[index];
                if phase.is_some() { *current_phase = phase; }
                match update {
                    AgentMessageUpdate::Started => {}
                    AgentMessageUpdate::Delta(delta) => text.push_str(&delta),
                    AgentMessageUpdate::Completed(snapshot) => *text = snapshot,
                }
            }
            AgentEvent::TurnCompleted {
                outcome: TurnOutcome::Completed,
                ..
            } => {
                let final_message = messages.iter().rev().find(|(_, phase, text)| {
                    *phase == Some(AgentMessagePhase::FinalAnswer) && !text.trim().is_empty()
                }).or_else(|| messages.iter().rev().find(|(_, phase, text)| {
                    *phase != Some(AgentMessagePhase::Commentary) && !text.trim().is_empty()
                }));
                return Ok(final_message.map_or(answer, |(_, _, text)| text.clone()));
            }
            AgentEvent::TurnCompleted { .. } => return Err("provider turn did not complete".into()),
            AgentEvent::ApprovalRequested(_) | AgentEvent::QuestionRequested(_) => {
                return Err("text-only acceptance unexpectedly requested input".into());
            }
            _ => {}
        }
    }
    Err("provider stream ended before terminal event".into())
}

async fn launch() -> TestResult<SpawnedCodexDriver> {
    // Require an explicit binary: accidentally exercising a broken PATH shim
    // or a different installed version would make the evidence misleading.
    let executable = std::env::var_os("INLINE_CODEX_SMOKE_EXECUTABLE")
        .ok_or("set INLINE_CODEX_SMOKE_EXECUTABLE to the candidate Codex binary")?;
    Ok(spawn_codex_driver(
        CodexLaunchConfig {
            executable: executable.into(),
            transport: CodexAppServerTransport::PrivateStdio,
            ..Default::default()
        },
        env!("CARGO_PKG_VERSION"),
    )
    .await?)
}

#[tokio::test]
#[ignore = "creates a new real Codex conversation and uses two model turns; requires authenticated Codex"]
async fn real_default_reply_catalog_and_exact_resume_after_restart() -> TestResult<()> {
    let workspace = tempfile::tempdir()?;
    let cwd = workspace.path().canonicalize()?;
    let marker = format!("inline-acceptance-{}", uuid::Uuid::new_v4().simple());
    let first = launch().await?;
    let result = tokio::time::timeout(Duration::from_secs(120), async {
        let session = first.driver.start_session(SessionSpec { cwd: cwd.clone() }).await?;
        let answer = reply(&first.driver, &session,
            &format!("This is a text-only integration test. Do not use tools, inspect files, or change anything. Remember this marker for the next message: {marker}. Reply with only that marker."),
            "release-smoke-first").await?;
        if answer.trim() != marker { return Err("first default answer did not match".into()); }
        Ok::<_, Box<dyn std::error::Error>>(session)
    }).await;
    let stopped = first.driver.shutdown().await;
    let session = result??;
    stopped?;

    let second = launch().await?;
    let result = tokio::time::timeout(Duration::from_secs(120), async {
        let provider = ProviderInstanceRef::new(InstallationId::new("release-smoke")?, ProviderId::new("codex")?)?;
        let workspace_id = WorkspaceId::new("release-smoke-workspace")?;
        let catalog = CodexSessionCatalog::new(second.driver.clone(), provider.clone(), workspace_id.clone(), &cwd)?;
        let page = catalog.list_sessions(SessionQuery { provider: provider.clone(), workspace_id: workspace_id.clone(), cursor: None, page_size: SessionPageSize::new(50) }).await?;
        if !page.sessions().iter().any(|item| item.session().session_id() == &session) {
            return Err("fresh app-server session was absent from catalog".into());
        }
        let snapshot = catalog.read_session(SessionReadRequest {
            session: ProviderSessionRef::new(provider, session.clone())?, workspace_id,
            window: HistoryWindow::default(),
        }).await?;
        if !snapshot.items().iter().any(|item| matches!(&item.payload, SessionItemPayload::Message { text, .. } if text.contains(&marker))) {
            return Err("persisted session history did not contain the first turn".into());
        }
        second.driver.resume_session(ResumeSessionSpec { session_id: session.clone(), cwd, replay: SessionReplay::None }).await?;
        let answer = reply(&second.driver, &session,
            "Do not use tools. Reply with only the marker I asked you to remember in my previous message.",
            "release-smoke-second").await?;
        if answer.trim() != marker { return Err("resumed answer lost the original context".into()); }
        Ok::<_, Box<dyn std::error::Error>>(())
    }).await;
    let stopped = second.driver.shutdown().await;
    result??;
    stopped?;
    eprintln!(
        "default reply, catalog, history and exact resume passed; disposable Codex session retained: {session}"
    );
    Ok(())
}

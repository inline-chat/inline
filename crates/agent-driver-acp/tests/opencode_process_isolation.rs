#![cfg(unix)]
use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{
    HostToolCall, HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult,
    HostToolSpec, TurnOutcome,
};
use inline_agent_driver_acp::{AcpLaunchDescriptor, IsolatedAcpHarness};
use std::{path::PathBuf, time::Duration};

struct Tools;
impl HostToolHandler for Tools {
    fn call<'a>(&'a self, _: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(async { HostToolResult::failure("fixture does not execute tools") })
    }
}
fn spec(mode: OpenMode, folder: PathBuf) -> OpenSpec {
    OpenSpec {
        mode,
        folder,
        settings: Default::default(),
        instructions: None,
        title: None,
        after: None,
        output_mode: OutputMode::Detailed,
    }
}
async fn reply(session: &dyn Session, text: &str) -> String {
    let mut events = session.events();
    session
        .send(Input {
            id: InputId::new(text).unwrap(),
            content: InputContent::text(text),
            delivery: Delivery::Turn,
            origin: Origin::Owner { user: UserId(1) },
        })
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut result = String::new();
        while let Some(envelope) = events.next().await {
            match envelope.event {
                Event::Item(Item {
                    update:
                        ItemUpdate::Completed {
                            body: ItemBody::Message { text, .. },
                            ..
                        },
                    ..
                }) => result = text,
                Event::Turn {
                    phase: TurnPhase::Completed { outcome, .. },
                    ..
                } => {
                    assert_eq!(outcome, TurnOutcome::Completed);
                    return result;
                }
                _ => {}
            }
        }
        panic!("no completion")
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn same_directory_sessions_own_separate_processes_and_tool_registrations() {
    use std::os::unix::fs::PermissionsExt;
    let temp = tempfile::tempdir().unwrap();
    let script = temp.path().join("opencode-fixture");
    std::fs::write(&script, r#"#!/usr/bin/env python3
import json, sys, os
servers = 0
session = 'ses_' + str(os.getpid())
for line in sys.stdin:
    r = json.loads(line)
    method, p = r.get('method'), r.get('params', {})
    if 'id' not in r: continue
    if method == 'initialize':
        value = {'protocolVersion':1, 'agentInfo':{'name':'opencode','version':'2.0.32'}, 'agentCapabilities':{'sessionCapabilities':{'resume':{}}}, 'authMethods':[]}
    elif method in ['session/new', 'session/resume']:
        servers = len(p.get('mcpServers', []))
        session = p.get('sessionId', session)
        value = {'sessionId':session, 'configOptions':[]}
    elif method == 'session/prompt':
        text = 'pid=' + str(os.getpid()) + ' tools=' + str(servers)
        print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':text}}}}), flush=True)
        value = {'stopReason':'end_turn'}
    else: value = {}
    print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}), flush=True)
"#).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let harness = IsolatedAcpHarness::connect(
        AcpLaunchDescriptor::opencode(script),
        "test",
        Some(HostToolConfiguration {
            specs: vec![HostToolSpec {
                name: "current_context".into(),
                description: "Fixture".into(),
                input_schema: serde_json::json!({"type":"object"}),
                read_only: true,
            }],
            handler: std::sync::Arc::new(Tools),
        }),
    )
    .await
    .unwrap();
    let cwd = temp.path().canonicalize().unwrap();
    let first = harness
        .open(spec(OpenMode::Start, cwd.clone()))
        .await
        .unwrap();
    let second = harness
        .open(spec(OpenMode::Start, cwd.clone()))
        .await
        .unwrap();
    assert_ne!(
        first.key().session,
        second.key().session,
        "one PID per session"
    );
    let first_text = reply(first.as_ref(), "first").await;
    let second_text = reply(second.as_ref(), "second").await;
    assert_ne!(first_text, second_text);
    assert!(first_text.ends_with("tools=1"));
    assert!(second_text.ends_with("tools=1"));
    assert!(
        harness
            .open(spec(
                OpenMode::Resume {
                    session: first.key().session.clone()
                },
                cwd.clone()
            ))
            .await
            .is_err(),
        "do not double-open a native session"
    );
    assert_eq!(
        first.release().await.unwrap().outcome,
        ReleaseOutcome::NativeReleased
    );
    assert_eq!(
        reply(second.as_ref(), "still-working").await,
        second_text,
        "releasing one chat preserves the other process"
    );
    let resumed = harness
        .open(spec(
            OpenMode::Resume {
                session: first.key().session.clone(),
            },
            cwd,
        ))
        .await
        .unwrap();
    assert_eq!(resumed.key(), first.key());
    assert_ne!(
        reply(resumed.as_ref(), "resumed").await,
        first_text,
        "resume owns a fresh process"
    );
    harness.shutdown().await.unwrap();
    assert!(
        harness
            .open(spec(OpenMode::Start, temp.path().to_path_buf()))
            .await
            .is_err()
    );
}

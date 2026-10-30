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
    assert!(
        matches!(
            harness
                .catalog(CatalogScope {
                    folder: Some(cwd.clone()),
                    session: Some(first.key().session.clone()),
                })
                .await,
            Err(inline_agent_bridge::DriverError::InvalidSession(_))
        ),
        "a stale exact session must not use the other chat's catalog"
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

fn lifecycle_fixture(root: &std::path::Path) -> AcpLaunchDescriptor {
    use std::os::unix::fs::PermissionsExt;
    let script = root.join("lifecycle-fixture");
    std::fs::write(&script, r#"#!/usr/bin/env python3
import json, sys, os, time, threading
root = os.path.dirname(__file__)
session = 'ses_' + str(os.getpid())
def record(method):
    with open(os.path.join(root, 'requests'), 'a') as f:
        f.write(str(os.getpid()) + ' ' + method + '\n')
def exit_later():
    time.sleep(0.2)
    os._exit(7)
for line in sys.stdin:
    r = json.loads(line)
    method, p = r.get('method'), r.get('params', {})
    record(method)
    if 'id' not in r: continue
    if method == 'initialize':
        value = {'protocolVersion':1, 'agentInfo':{'name':'opencode','version':'2.0.32'}, 'agentCapabilities':{'sessionCapabilities':{'resume':{}}}, 'authMethods':[]}
    elif method in ['session/new', 'session/resume']:
        if os.path.basename(p.get('cwd', '')) == 'slow':
            open(os.path.join(root, 'waiting'), 'w').close()
            while not os.path.exists(os.path.join(root, 'continue')): time.sleep(0.01)
        session = p.get('sessionId', session)
        value = {'sessionId':session, 'configOptions':[]}
    elif method == 'session/prompt':
        text = ' '.join(part.get('text', '') for part in p.get('prompt', []))
        print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'ready'}}}}), flush=True)
        if text == 'ignore-cancel': continue
        if text == 'exit-after-turn': threading.Thread(target=exit_later, daemon=True).start()
        value = {'stopReason':'end_turn'}
    else: value = {}
    print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}), flush=True)
"#).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    AcpLaunchDescriptor::opencode(script)
}

fn new_sessions(root: &std::path::Path) -> usize {
    std::fs::read_to_string(root.join("requests"))
        .unwrap()
        .lines()
        .filter(|line| line.ends_with(" session/new"))
        .count()
}

async fn released(events: &mut EventStream) {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if matches!(
                events.next().await.unwrap().event,
                Event::State {
                    state: RunState::Released
                }
            ) {
                return;
            }
        }
    })
    .await
    .expect("process exit must release the session");
}

#[tokio::test]
async fn catalog_reuses_sessions_and_slow_probe_does_not_block_chat_open() {
    let temp = tempfile::tempdir().unwrap();
    let harness = IsolatedAcpHarness::connect(lifecycle_fixture(temp.path()), "test", None)
        .await
        .unwrap();
    let folder = temp.path().canonicalize().unwrap();
    for _ in 0..3 {
        harness
            .catalog(CatalogScope {
                folder: Some(folder.clone()),
                session: None,
            })
            .await
            .unwrap();
    }
    assert_eq!(
        new_sessions(temp.path()),
        1,
        "catalog refreshes retain one probe session"
    );
    let chat = harness
        .open(spec(OpenMode::Start, folder.clone()))
        .await
        .unwrap();
    harness
        .catalog(CatalogScope {
            folder: Some(folder.clone()),
            session: None,
        })
        .await
        .unwrap();
    harness
        .catalog(CatalogScope {
            folder: Some(folder.clone()),
            session: Some(chat.key().session.clone()),
        })
        .await
        .unwrap();
    assert_eq!(
        new_sessions(temp.path()),
        2,
        "live catalog reads use the chat's metadata"
    );
    let slow_folder = folder.join("slow");
    std::fs::create_dir(&slow_folder).unwrap();
    let slow = harness.catalog(CatalogScope {
        folder: Some(slow_folder),
        session: None,
    });
    let concurrent = async {
        tokio::time::timeout(Duration::from_secs(5), async {
            while !folder.join("waiting").exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let opened = tokio::time::timeout(
            Duration::from_secs(3),
            harness.open(spec(OpenMode::Start, folder.clone())),
        )
        .await;
        // Unblock the probe even on failure so the assertion reports a lock
        // regression without leaving a fixture process hung.
        std::fs::write(folder.join("continue"), "").unwrap();
        opened
            .expect("a catalog request must not hold the chat-open lock")
            .unwrap()
    };
    let (catalog, opened) = tokio::join!(slow, concurrent);
    catalog.unwrap();
    assert_ne!(opened.key().session, chat.key().session);
    harness.shutdown().await.unwrap();
}

#[tokio::test]
async fn alternating_catalog_folders_resume_only_their_probe_sessions() {
    let temp = tempfile::tempdir().unwrap();
    let harness = IsolatedAcpHarness::connect(lifecycle_fixture(temp.path()), "test", None)
        .await
        .unwrap();
    let a = temp.path().join("a");
    let b = temp.path().join("b");
    std::fs::create_dir(&a).unwrap();
    std::fs::create_dir(&b).unwrap();
    for folder in [&a, &b, &a] {
        harness
            .catalog(CatalogScope {
                folder: Some(folder.clone()),
                session: None,
            })
            .await
            .unwrap();
    }
    assert_eq!(
        new_sessions(temp.path()),
        2,
        "returning to a folder resumes its tool-free probe session"
    );
    let requests = std::fs::read_to_string(temp.path().join("requests")).unwrap();
    assert_eq!(
        requests
            .lines()
            .filter(|line| line.ends_with(" session/resume"))
            .count(),
        1
    );
    harness.shutdown().await.unwrap();
}

#[tokio::test]
async fn crashed_idle_process_reports_release_and_remains_releasable() {
    let temp = tempfile::tempdir().unwrap();
    let harness = IsolatedAcpHarness::connect(lifecycle_fixture(temp.path()), "test", None)
        .await
        .unwrap();
    let session = harness
        .open(spec(OpenMode::Start, temp.path().to_path_buf()))
        .await
        .unwrap();
    let mut events = session.events();
    assert_eq!(reply(session.as_ref(), "exit-after-turn").await, "ready");
    released(&mut events).await;
    assert_eq!(
        session.release().await.unwrap().outcome,
        ReleaseOutcome::NativeReleased
    );
    assert_eq!(
        session.release().await.unwrap().outcome,
        ReleaseOutcome::NativeReleased
    );
    let resumed = harness
        .open(spec(
            OpenMode::Resume {
                session: session.key().session.clone(),
            },
            temp.path().to_path_buf(),
        ))
        .await
        .unwrap();
    assert_eq!(reply(resumed.as_ref(), "resumed").await, "ready");
    drop(session);
    harness.shutdown().await.unwrap();
}

#[tokio::test]
async fn release_still_reaps_process_when_cancel_is_not_acknowledged() {
    let temp = tempfile::tempdir().unwrap();
    let harness = IsolatedAcpHarness::connect(lifecycle_fixture(temp.path()), "test", None)
        .await
        .unwrap();
    let session = harness
        .open(spec(OpenMode::Start, temp.path().to_path_buf()))
        .await
        .unwrap();
    let mut events = session.events();
    session
        .send(Input {
            id: InputId::new("ignored-cancel").unwrap(),
            content: InputContent::text("ignore-cancel"),
            delivery: Delivery::Turn,
            origin: Origin::Owner { user: UserId(1) },
        })
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while !matches!(events.next().await.unwrap().event, Event::Item(_)) {}
    })
    .await
    .unwrap();
    let result = tokio::time::timeout(Duration::from_secs(20), session.release())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.outcome, ReleaseOutcome::NativeReleased);
    released(&mut events).await;
    harness.shutdown().await.unwrap();
}

//! Session list, fork and close for ACP agents, gated on what each agent
//! advertises in `sessionCapabilities`. An agent that does not advertise a
//! method must never be sent it.
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::{Agent, ConnectionTo, schema::v1 as acp};
use futures_util::StreamExt;
use inline_agent_bridge::harness::*;
use inline_agent_bridge::{AgentDriver, DriverError, ProviderId, TurnOutcome};
use inline_agent_driver_acp::{AcpDriver, AcpHarness, AcpSessionOps};

/// What the scripted agent advertises and how it misbehaves.
#[derive(Clone, Copy, Default)]
struct Script {
    list: bool,
    fork: bool,
    close: bool,
    fail_close: bool,
}

impl Script {
    fn all() -> Self {
        Self {
            list: true,
            fork: true,
            close: true,
            fail_close: false,
        }
    }
}

#[derive(Default)]
struct Seen {
    lists: Vec<(Option<PathBuf>, Option<String>)>,
    forks: Vec<(String, PathBuf, usize)>,
    closes: Vec<String>,
    prompts: Vec<(String, String)>,
}

struct Fixture {
    harness: AcpHarness,
    driver: Arc<AcpDriver>,
    seen: Arc<Mutex<Seen>>,
}

async fn fixture(script: Script) -> Fixture {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let (lists, forks, closes, prompts) = (seen.clone(), seen.clone(), seen.clone(), seen.clone());
    let agent = Agent
        .builder()
        .on_receive_request(
            async move |r: acp::InitializeRequest, responder, _| {
                let mut session =
                    acp::SessionCapabilities::new().resume(acp::SessionResumeCapabilities::new());
                if script.list {
                    session = session.list(acp::SessionListCapabilities::new());
                }
                if script.fork {
                    session = session.fork(acp::SessionForkCapabilities::new());
                }
                if script.close {
                    session = session.close(acp::SessionCloseCapabilities::new());
                }
                responder.respond(
                    acp::InitializeResponse::new(r.protocol_version)
                        .agent_info(acp::Implementation::new("opencode", "2.0.32"))
                        .agent_capabilities(
                            acp::AgentCapabilities::new().session_capabilities(session),
                        ),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async |_r: acp::NewSessionRequest, responder, _| {
                responder.respond(acp::NewSessionResponse::new("ses_new"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async |_r: acp::ResumeSessionRequest, responder, _| {
                responder.respond(acp::ResumeSessionResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |r: acp::ListSessionsRequest, responder, _| {
                lists
                    .lock()
                    .unwrap()
                    .lists
                    .push((r.cwd.clone(), r.cursor.clone()));
                if r.cwd.as_deref() == Some(Path::new("/broken")) {
                    return responder
                        .respond_with_error(agent_client_protocol::Error::internal_error());
                }
                if r.cursor.is_some() {
                    return responder.respond(acp::ListSessionsResponse::new(vec![
                        acp::SessionInfo::new("ses_three", "/tmp"),
                    ]));
                }
                responder.respond(
                    acp::ListSessionsResponse::new(vec![
                        acp::SessionInfo::new("ses_one", "/tmp")
                            .title("Fix the reconnect race")
                            .updated_at("2026-11-23T08:15:30.123Z"),
                        // Unusable identity: dropped, not fatal.
                        acp::SessionInfo::new("bad\nid", "/tmp"),
                        acp::SessionInfo::new("ses_two", "/tmp/other")
                            .title("  ")
                            .updated_at("yesterday"),
                    ])
                    .next_cursor("page-2"),
                )
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |r: acp::ForkSessionRequest, responder, _| {
                forks.lock().unwrap().forks.push((
                    r.session_id.to_string(),
                    r.cwd.clone(),
                    r.mcp_servers.len(),
                ));
                if r.session_id.to_string() == "ses_missing" {
                    return responder.respond_with_error(
                        agent_client_protocol::Error::resource_not_found(None),
                    );
                }
                responder.respond(acp::ForkSessionResponse::new("ses_fork"))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |r: acp::CloseSessionRequest, responder, _| {
                closes.lock().unwrap().closes.push(r.session_id.to_string());
                if script.fail_close {
                    return responder
                        .respond_with_error(agent_client_protocol::Error::internal_error());
                }
                responder.respond(acp::CloseSessionResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |r: acp::PromptRequest,
                        responder,
                        _connection: ConnectionTo<agent_client_protocol::Client>| {
                let text = r
                    .prompt
                    .iter()
                    .filter_map(|part| match part {
                        acp::ContentBlock::Text(text) => Some(text.text.as_str()),
                        _ => None,
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
                prompts
                    .lock()
                    .unwrap()
                    .prompts
                    .push((r.session_id.to_string(), text));
                responder.respond(acp::PromptResponse::new(acp::StopReason::EndTurn))
            },
            agent_client_protocol::on_receive_request!(),
        );
    let driver = Arc::new(AcpDriver::connect_transport(agent, "test").await.unwrap());
    let harness = AcpHarness::new(
        driver.clone(),
        ProviderId::new("opencode").unwrap(),
        ExecutableInfo {
            path: "opencode".into(),
            source: ExecutableSource::Path,
            version: Some("2.0.32".into()),
            sha256: None,
            other_installs: Vec::new(),
        },
        "test",
    );
    Fixture {
        harness,
        driver,
        seen,
    }
}

fn spec(mode: OpenMode) -> OpenSpec {
    OpenSpec {
        mode,
        folder: PathBuf::from("/tmp"),
        settings: Default::default(),
        instructions: None,
        title: None,
        after: None,
        output_mode: OutputMode::Detailed,
    }
}

fn fork_of(session: &str) -> OpenMode {
    OpenMode::Fork {
        session: inline_agent_bridge::ProviderSessionId::new(session).unwrap(),
        at: None,
    }
}

fn listing(folder: &str, cursor: Option<&str>) -> SessionQuery {
    SessionQuery {
        folder: Some(folder.into()),
        cursor: cursor.map(|cursor| inline_agent_bridge::SessionPageCursor::new(cursor).unwrap()),
        ..SessionQuery::default()
    }
}

async fn turn(session: &dyn Session, id: &str, text: &str) {
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
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(envelope) = events.next().await {
            if let Event::Turn {
                phase: TurnPhase::Completed { outcome, .. },
                ..
            } = envelope.event
            {
                assert_eq!(outcome, TurnOutcome::Completed);
                return;
            }
        }
        panic!("stream ended before the turn completed");
    })
    .await
    .expect("turn timed out");
}

#[tokio::test]
async fn advertised_list_pages_through_the_agents_sessions() {
    let f = fixture(Script::all()).await;
    assert_eq!(
        f.harness.session_ops(),
        AcpSessionOps {
            list: true,
            fork: true,
            close: true
        }
    );
    let page = f.harness.sessions(listing("/tmp", None)).await.unwrap();
    let ids = page
        .sessions
        .iter()
        .map(|summary| summary.key.session.as_str())
        .collect::<Vec<_>>();
    assert_eq!(ids, ["ses_one", "ses_two"], "unusable ids are dropped");
    let first = &page.sessions[0];
    assert_eq!(first.key.provider.as_str(), "opencode");
    assert_eq!(first.title.as_deref(), Some("Fix the reconnect race"));
    assert_eq!(first.folder.as_deref(), Some(Path::new("/tmp")));
    assert_eq!(first.updated_at, Some(1_795_421_730));
    assert!(!first.archived && first.held_by.is_none());
    let second = &page.sessions[1];
    assert_eq!(second.title, None, "a blank title is no title");
    assert_eq!(second.updated_at, None, "an unparseable time is omitted");
    assert_eq!(second.folder.as_deref(), Some(Path::new("/tmp/other")));
    let next = page.next.expect("the agent's cursor carries over");
    assert_eq!(next.as_str(), "page-2");

    let older = f
        .harness
        .sessions(listing("/tmp", Some("page-2")))
        .await
        .unwrap();
    assert_eq!(older.sessions.len(), 1);
    assert!(older.next.is_none());
    assert_eq!(
        f.seen.lock().unwrap().lists,
        [
            (Some(PathBuf::from("/tmp")), None),
            (Some(PathBuf::from("/tmp")), Some("page-2".to_owned())),
        ]
    );
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn list_errors_reach_the_caller() {
    let f = fixture(Script::all()).await;
    let error = f
        .harness
        .sessions(listing("/broken", None))
        .await
        .unwrap_err();
    assert!(matches!(error, DriverError::Rejected(_)), "{error:?}");
    // A failed read does not end the connection: other sessions keep working.
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    turn(session.as_ref(), "after-list-error", "still here").await;
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn advertised_fork_opens_the_copy_with_this_threads_guide() {
    let f = fixture(Script::all()).await;
    let mut fork = spec(fork_of("ses_source"));
    fork.instructions = Some("fork thread guide".into());
    let session = f.harness.open(fork).await.unwrap();
    assert_eq!(session.key().session.as_str(), "ses_fork");
    turn(session.as_ref(), "fork-first", "carry on").await;
    turn(session.as_ref(), "fork-second", "and again").await;
    {
        let seen = f.seen.lock().unwrap();
        assert_eq!(
            seen.forks,
            [("ses_source".to_owned(), PathBuf::from("/tmp"), 0)]
        );
        // Turns go to the fork, and the fork's new thread gets its guide once.
        assert!(seen.prompts.iter().all(|(id, _)| id == "ses_fork"));
        assert!(seen.prompts[0].1.contains("fork thread guide"));
        assert!(!seen.prompts[1].1.contains("fork thread guide"));
    }
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn fork_point_and_missing_source_are_typed() {
    let f = fixture(Script::all()).await;
    let at_turn = f
        .harness
        .open(spec(OpenMode::Fork {
            session: inline_agent_bridge::ProviderSessionId::new("ses_source").unwrap(),
            at: Some(ForkPoint::Turn {
                turn: inline_agent_bridge::TurnId::new("turn-1").unwrap(),
            }),
        }))
        .await;
    assert!(
        matches!(at_turn, Err(OpenError::Unavailable(_))),
        "session/fork has no fork point"
    );
    assert!(f.seen.lock().unwrap().forks.is_empty());
    let missing = f.harness.open(spec(fork_of("ses_missing"))).await;
    assert!(matches!(missing, Err(OpenError::NotFound)));
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn advertised_close_releases_the_session_natively() {
    let f = fixture(Script::all()).await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    turn(session.as_ref(), "before-close", "hello").await;
    let released = session.release().await.unwrap();
    assert_eq!(released.outcome, ReleaseOutcome::NativeReleased);
    assert_eq!(f.seen.lock().unwrap().closes, ["ses_new"]);
    // The closed session can be resumed again as usual.
    let resumed = f
        .harness
        .open(spec(OpenMode::Resume {
            session: session.key().session.clone(),
        }))
        .await
        .unwrap();
    turn(resumed.as_ref(), "after-close", "back again").await;
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn failed_close_leaves_the_session_held_by_the_agent() {
    let f = fixture(Script {
        fail_close: true,
        ..Script::all()
    })
    .await;
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    let released = session.release().await.unwrap();
    assert_eq!(released.outcome, ReleaseOutcome::Unsubscribed);
    assert_eq!(f.seen.lock().unwrap().closes, ["ses_new"]);
    f.driver.shutdown().await.unwrap();
}

#[tokio::test]
async fn unadvertised_methods_are_never_sent() {
    let f = fixture(Script::default()).await;
    assert_eq!(f.harness.session_ops(), AcpSessionOps::default());
    let page = f.harness.sessions(listing("/tmp", None)).await.unwrap();
    assert_eq!(page, SessionPage::default());
    let fork = f.harness.open(spec(fork_of("ses_source"))).await;
    assert!(matches!(fork, Err(OpenError::Unavailable(_))));
    let session = f.harness.open(spec(OpenMode::Start)).await.unwrap();
    turn(session.as_ref(), "plain", "hello").await;
    let released = session.release().await.unwrap();
    assert_eq!(released.outcome, ReleaseOutcome::Unsubscribed);
    {
        let seen = f.seen.lock().unwrap();
        assert!(seen.lists.is_empty(), "session/list sent unadvertised");
        assert!(seen.forks.is_empty(), "session/fork sent unadvertised");
        assert!(seen.closes.is_empty(), "session/close sent unadvertised");
    }
    f.driver.shutdown().await.unwrap();
}

/// The bridge's real ACP route: one private process per session.
#[cfg(unix)]
mod isolated {
    use super::*;
    use inline_agent_driver_acp::{AcpLaunchDescriptor, IsolatedAcpHarness};
    use std::os::unix::fs::PermissionsExt;

    fn agent(root: &Path, capabilities: &str) -> AcpLaunchDescriptor {
        let script = root.join("session-ops-fixture");
        let source = r#"#!/usr/bin/env python3
import json, sys, os
root = os.path.dirname(__file__)
session = 'ses_' + str(os.getpid())
def record(method):
    with open(os.path.join(root, 'requests'), 'a') as f:
        f.write(str(os.getpid()) + ' ' + method + '\n')
for line in sys.stdin:
    r = json.loads(line)
    method, p = r.get('method'), r.get('params', {})
    if method: record(method)
    if 'id' not in r: continue
    if method == 'initialize':
        value = {'protocolVersion':1, 'agentInfo':{'name':'opencode','version':'2.0.32'}, 'agentCapabilities':{'sessionCapabilities':CAPABILITIES}, 'authMethods':[]}
    elif method in ['session/new', 'session/resume']:
        session = p.get('sessionId', session)
        value = {'sessionId':session, 'configOptions':[]}
    elif method == 'session/list':
        value = {'sessions':[{'sessionId':session,'cwd':p.get('cwd','/')},{'sessionId':'ses_old','cwd':p.get('cwd','/'),'title':'Earlier work'}]}
    elif method == 'session/fork':
        session = 'ses_fork_' + str(os.getpid())
        value = {'sessionId':session, 'configOptions':[]}
    elif method == 'session/prompt':
        value = {'stopReason':'end_turn'}
    else: value = {}
    print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}), flush=True)
"#
        .replace("CAPABILITIES", capabilities);
        std::fs::write(&script, source).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        AcpLaunchDescriptor::opencode(script)
    }

    fn requests(root: &Path) -> Vec<(String, String)> {
        std::fs::read_to_string(root.join("requests"))
            .unwrap_or_default()
            .lines()
            .filter_map(|line| line.split_once(' '))
            .map(|(pid, method)| (pid.to_owned(), method.to_owned()))
            .collect()
    }

    fn count(root: &Path, method: &str) -> usize {
        requests(root).iter().filter(|(_, m)| m == method).count()
    }

    #[tokio::test]
    async fn advertised_ops_run_in_the_right_process() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let harness = IsolatedAcpHarness::connect(
            agent(&root, "{'resume':{},'list':{},'fork':{},'close':{}}"),
            "test",
            None,
        )
        .await
        .unwrap();
        // The tool-free picker probe answers listings; its own session is hidden.
        harness
            .catalog(CatalogScope {
                folder: Some(root.clone()),
                session: None,
            })
            .await
            .unwrap();
        let launched = count(&root, "initialize");
        let page = harness
            .sessions(SessionQuery {
                folder: Some(root.clone()),
                ..SessionQuery::default()
            })
            .await
            .unwrap();
        let ids = page
            .sessions
            .iter()
            .map(|summary| summary.key.session.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, ["ses_old"], "the probe's session is not listed");
        assert_eq!(count(&root, "initialize"), launched, "the probe listed");

        let fork = harness
            .open(OpenSpec {
                folder: root.clone(),
                ..spec(fork_of("ses_old"))
            })
            .await
            .unwrap();
        let (fork_pid, _) = requests(&root)
            .into_iter()
            .find(|(_, method)| method == "session/fork")
            .expect("session/fork sent");
        assert_eq!(fork.key().session.as_str(), format!("ses_fork_{fork_pid}"));
        turn(fork.as_ref(), "isolated-fork", "hello").await;
        assert_eq!(
            fork.release().await.unwrap().outcome,
            ReleaseOutcome::NativeReleased
        );
        assert!(
            requests(&root).contains(&(fork_pid, "session/close".to_owned())),
            "the fork's own process is asked to close it"
        );
        harness.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn unadvertised_ops_launch_nothing_and_send_nothing() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let harness = IsolatedAcpHarness::connect(agent(&root, "{'resume':{}}"), "test", None)
            .await
            .unwrap();
        assert_eq!(count(&root, "initialize"), 1);
        let page = harness
            .sessions(SessionQuery {
                folder: Some(root.clone()),
                ..SessionQuery::default()
            })
            .await
            .unwrap();
        assert!(page.sessions.is_empty());
        let fork = harness
            .open(OpenSpec {
                folder: root.clone(),
                ..spec(fork_of("ses_old"))
            })
            .await;
        assert!(matches!(fork, Err(OpenError::Unavailable(_))));
        assert_eq!(count(&root, "initialize"), 1, "nothing was launched");
        let session = harness
            .open(OpenSpec {
                folder: root.clone(),
                ..spec(OpenMode::Start)
            })
            .await
            .unwrap();
        assert_eq!(
            session.release().await.unwrap().outcome,
            ReleaseOutcome::NativeReleased,
            "the private process is stopped either way"
        );
        for method in ["session/list", "session/fork", "session/close"] {
            assert_eq!(count(&root, method), 0, "{method} sent unadvertised");
        }
        harness.shutdown().await.unwrap();
    }
}

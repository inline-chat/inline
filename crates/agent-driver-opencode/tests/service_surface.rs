//! The installed OpenCode's service against what the native driver needs,
//! with no model and no credentials: the version gate, every HTTP route the
//! driver calls in the service's own OpenAPI document, and a session's
//! open / settings / release handshake (instruction entry, client-MCP
//! tools, event stream).
//!
//! Opt-in, run by the harness-compatibility workflow:
//! `INLINE_OPENCODE_SURFACE=1 INLINE_OPENCODE_EXECUTABLE=/path/to/opencode
//! cargo test -p inline-agent-driver-opencode --test service_surface -- --ignored`.
//! It reuses the registered service or starts one; point it at an isolated
//! one with `XDG_STATE_HOME`, `XDG_DATA_HOME` and `XDG_CONFIG_HOME`.
//! `INLINE_OPENCODE_OPENAPI_OUT` saves the service's OpenAPI document.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use inline_agent_bridge::harness::*;
use inline_agent_bridge::{
    HostToolCall, HostToolConfiguration, HostToolFuture, HostToolHandler, HostToolResult,
    HostToolSpec,
};
use inline_agent_driver_opencode::api::{Api, Query};
use inline_agent_driver_opencode::{OpenCodeHarness, OpenCodeHarnessConfig, ServiceConfig};
use serde_json::{Value, json};

/// Every route the driver calls, as the OpenAPI document names it.
const ROUTES: &[(&str, &str)] = &[
    ("get", "/api/info"),
    ("get", "/api/event"),
    ("get", "/api/model"),
    ("get", "/api/model/default"),
    ("get", "/api/agent"),
    ("get", "/api/command"),
    ("get", "/api/skill"),
    ("get", "/api/project"),
    ("get", "/api/experimental/usage/limits"),
    ("get", "/api/experimental/client-mcp"),
    ("get", "/api/session"),
    ("post", "/api/session"),
    ("get", "/api/session/active"),
    ("get", "/api/session/{sessionID}"),
    ("patch", "/api/session/{sessionID}"),
    ("post", "/api/session/{sessionID}/fork"),
    ("post", "/api/session/{sessionID}/prompt"),
    ("post", "/api/session/{sessionID}/synthetic"),
    ("post", "/api/session/{sessionID}/command"),
    ("post", "/api/session/{sessionID}/interrupt"),
    ("get", "/api/session/{sessionID}/inbox"),
    ("delete", "/api/session/{sessionID}/inbox/{inboxID}"),
    ("get", "/api/session/{sessionID}/message"),
    ("post", "/api/session/{sessionID}/model"),
    ("post", "/api/session/{sessionID}/agent"),
    ("post", "/api/session/{sessionID}/compact"),
    ("post", "/api/session/{sessionID}/revert/stage"),
    ("post", "/api/session/{sessionID}/generate"),
    ("get", "/api/session/{sessionID}/permission"),
    (
        "post",
        "/api/session/{sessionID}/permission/{requestID}/reply",
    ),
    ("get", "/api/session/{sessionID}/form"),
    ("post", "/api/session/{sessionID}/form/{formID}/reply"),
    ("delete", "/api/session/{sessionID}/form/{formID}"),
    ("delete", "/api/shell/{id}"),
    (
        "put",
        "/api/experimental/session/{sessionID}/instructions/entries/{key}",
    ),
    ("get", "/api/experimental/session/{sessionID}/log"),
];

fn executable() -> PathBuf {
    std::env::var_os("INLINE_OPENCODE_EXECUTABLE")
        .map(PathBuf::from)
        .expect("INLINE_OPENCODE_EXECUTABLE")
}

struct Refuse;

impl HostToolHandler for Refuse {
    fn call<'a>(&'a self, _call: HostToolCall) -> HostToolFuture<'a> {
        Box::pin(async { HostToolResult::failure("not in this test") })
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs an installed OpenCode v2; set INLINE_OPENCODE_SURFACE=1"]
async fn the_service_serves_what_the_driver_calls() {
    if std::env::var("INLINE_OPENCODE_SURFACE").as_deref() != Ok("1") {
        return;
    }
    let (endpoint, info) =
        inline_agent_driver_opencode::service::ensure(&ServiceConfig::new(executable()))
            .await
            .expect("service");
    let version = inline_agent_driver_opencode::version::parse(&info.version).expect("version");
    eprintln!("OpenCode service {version}");
    assert!(
        inline_agent_driver_opencode::native_supported(&version),
        "{version} is outside the native route (floor {})",
        inline_agent_driver_opencode::CORE_FLOOR
    );

    // Routes: OpenCode answers unknown parameters and paths loosely, so a
    // renamed route would only fail at run time.
    let api = Api::new(endpoint).unwrap();
    let document = api
        .get("openapi.json", Query::new())
        .await
        .expect("openapi");
    if let Some(out) = std::env::var_os("INLINE_OPENCODE_OPENAPI_OUT") {
        std::fs::write(out, serde_json::to_vec_pretty(&document).unwrap()).unwrap();
    }
    let paths = document
        .get("paths")
        .and_then(Value::as_object)
        .expect("paths");
    let missing: Vec<String> = ROUTES
        .iter()
        .filter(|(method, path)| paths.get(*path).and_then(|ops| ops.get(*method)).is_none())
        .map(|(method, path)| format!("{} {path}", method.to_uppercase()))
        .collect();
    assert!(
        missing.is_empty(),
        "routes missing from {version}: {missing:?}"
    );

    // Handshake: open a session with Inline's guide and tools, change its
    // settings, and release it, all without a model call.
    let folder = tempfile::tempdir().unwrap();
    let mut config = OpenCodeHarnessConfig::new(executable(), "surface-test");
    config.host_tools = Some(HostToolConfiguration {
        specs: vec![HostToolSpec {
            name: "send_message".into(),
            description: "Send a message to the Inline thread".into(),
            input_schema: json!({"type": "object", "properties": {"text": {"type": "string"}}}),
            read_only: false,
        }],
        handler: Arc::new(Refuse),
    });
    let harness = OpenCodeHarness::new(config);
    let catalog = harness
        .catalog(CatalogScope {
            folder: Some(folder.path().to_path_buf()),
            session: None,
        })
        .await
        .expect("catalog");
    assert_eq!(harness.describe().health, RuntimeHealth::Ready);
    assert!(
        catalog.modes.iter().any(|mode| mode.id.as_str() == "plan"),
        "{:?}",
        catalog.modes
    );
    let session = harness
        .open(OpenSpec {
            mode: OpenMode::Start,
            folder: folder.path().to_path_buf(),
            settings: SettingsChange::default(),
            instructions: Some("You are Inline's test agent.".into()),
            title: Some("Inline surface test".into()),
            after: None,
            output_mode: OutputMode::Detailed,
        })
        .await
        .expect("open");
    let id = session.key().session.as_str().to_owned();
    let entries = api
        .get(
            &format!("api/experimental/session/{id}/instructions/entries"),
            Query::new(),
        )
        .await
        .expect("instruction entries");
    assert!(
        entries.to_string().contains("\"inline\""),
        "Inline's guide entry is missing: {entries}"
    );
    session
        .control(Op::Mode {
            mode: ModeId::new("plan").unwrap(),
        })
        .await
        .expect("mode");
    session
        .control(Op::Rename {
            title: "Inline surface test (renamed)".into(),
        })
        .await
        .expect("rename");
    session
        .control(Op::Interrupt {
            cancel_queued: true,
        })
        .await
        .expect("interrupt while idle");
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let info = api
                .get(&format!("api/session/{id}"), Query::new())
                .await
                .expect("session");
            if info.to_string().contains("(renamed)") {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("the rename reached the service");
    assert!(session.live_work().is_idle());
    let released = session.release().await.expect("release");
    assert_eq!(released.outcome, ReleaseOutcome::NativeReleased);
    harness.shutdown().await;
}

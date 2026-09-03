//! Optional allowlisted error reporting with bounded, scrubbed failure text.
use std::sync::Arc;
use std::sync::Once;
use std::time::Duration;

use crate::errors::JsonCliError;

const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const BRIDGE_RUNTIME_MESSAGE: &str = "Inline CLI bridge runtime failed";
const COMMAND_FAILURE_MESSAGE: &str = "Inline CLI command failed";
const PANIC_MESSAGE: &str = "Inline CLI process panicked";
static PANIC_HOOK: Once = Once::new();

pub(crate) struct TelemetryGuard(Option<sentry::ClientInitGuard>);

impl Drop for TelemetryGuard {
    fn drop(&mut self) {
        let Some(guard) = self.0.take() else { return };
        // The SDK's transport destructor joins its worker even after flush
        // times out. Keep that join off the command's exit path. If spawning
        // fails, leave SDK teardown to process exit rather than blocking here.
        let guard = std::mem::ManuallyDrop::new(guard);
        let (done, completion) = std::sync::mpsc::sync_channel(1);
        if std::thread::Builder::new()
            .name("inline-telemetry-shutdown".into())
            .spawn(move || {
                drop(std::mem::ManuallyDrop::into_inner(guard));
                let _ = done.send(());
            })
            .is_ok()
        {
            let _ = completion.recv_timeout(SHUTDOWN_TIMEOUT);
        }
    }
}

pub(crate) fn init() -> Option<TelemetryGuard> {
    if std::env::var("INLINE_CLI_TELEMETRY").is_ok_and(|value| telemetry_disabled(&value)) {
        return None;
    }
    let dsn = std::env::var("INLINE_CLI_SENTRY_DSN")
        .ok()
        .or_else(|| option_env!("INLINE_CLI_SENTRY_DSN").map(str::to_owned))?;
    if dsn.trim().is_empty() {
        return None;
    }
    let Ok(dsn) = dsn.parse::<sentry::types::Dsn>() else {
        log::warn!("CLI error reporting disabled: invalid INLINE_CLI_SENTRY_DSN.");
        return None;
    };
    // Sentry's reqwest 0.13 no-provider feature does not auto-select ring.
    // Initialize it before Sentry, independently of API client startup order.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut options = sentry::ClientOptions::default();
    options.dsn = Some(dsn);
    options.release = Some(format!("inline-cli@{}", env!("CARGO_PKG_VERSION")).into());
    options.default_integrations = false;
    options.send_default_pii = false;
    options.auto_session_tracking = false;
    options.max_breadcrumbs = 0;
    options.shutdown_timeout = SHUTDOWN_TIMEOUT;
    options.before_send = Some(Arc::new(|event| Some(allowlisted_event(event))));
    let guard = TelemetryGuard(Some(sentry::init(options)));
    install_panic_hook();
    Some(guard)
}

fn telemetry_disabled(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "off" | "0" | "false"
    )
}

pub(crate) fn report(
    error: &JsonCliError,
    target: Option<&str>,
    phase: Option<&str>,
    command: Option<&str>,
) {
    if matches!(
        error.code.as_str(),
        "invalid_args" | "not_authenticated" | "setup_cancelled" | "confirmation_required"
    ) {
        return;
    }
    let mut event = sentry::protocol::Event {
        message: Some(COMMAND_FAILURE_MESSAGE.into()),
        level: sentry::Level::Error,
        ..Default::default()
    };
    event
        .tags
        .insert("error_code".into(), safe_code(&error.code));
    if let Some(target) = target {
        event.tags.insert("target".into(), safe_code(target));
    }
    if let Some(phase) = phase {
        event.tags.insert("phase".into(), safe_code(phase));
    }
    if let Some(command) = command {
        event.tags.insert("command".into(), safe_code(command));
    }
    event
        .extra
        .insert("failure_text".into(), command_failure_text(error).into());
    sentry::capture_event(event);
}

fn command_failure_text(error: &JsonCliError) -> String {
    let mut text = error.message.clone();
    if let Some(status) = error.status {
        text.push_str(&format!(" Status: {status}."));
    }
    if let Some(hint) = &error.hint {
        text.push_str(&format!(" Hint: {hint}"));
    }
    crate::diagnostics::safe_text(&text)
}

/// Reports a recovered bridge failure using fixed grouping metadata plus the
/// bounded, scrubbed display text. Source chains, backtraces, and surrounding
/// runtime state are not attached. Repeated restart loops are sampled at attempts
/// 1, 2, 3 and powers of two so one poisoned delivery cannot flood Sentry.
pub(crate) fn report_bridge_runtime_error(
    target: &str,
    phase: &str,
    error: &(dyn std::error::Error + 'static),
    attempt: Option<u32>,
) {
    if attempt.is_some_and(|attempt| !should_report_bridge_attempt(attempt)) {
        return;
    }
    capture_bridge_runtime_event(
        target,
        phase,
        classify_bridge_runtime_failure(error),
        attempt,
        Some(&error.to_string()),
    );
}

pub(crate) fn report_bridge_provider_exit(target: &str) {
    capture_bridge_runtime_event(
        target,
        "provider_process",
        "provider_process_exited",
        None,
        None,
    );
}

pub(crate) fn report_bridge_configuration_fallback(target: &str, failure: &'static str) {
    capture_bridge_runtime_event(target, "agent_configuration", failure, None, None);
}

pub(crate) fn bridge_error_requires_provider_restart(
    error: &(dyn std::error::Error + 'static),
) -> bool {
    matches!(
        classify_bridge_runtime_failure(error),
        "ambiguous_provider_timeout" | "provider_epoch_ended" | "provider_process_exited"
    )
}

fn capture_bridge_runtime_event(
    target: &str,
    phase: &str,
    failure: &'static str,
    attempt: Option<u32>,
    failure_text: Option<&str>,
) {
    let mut event = sentry::protocol::Event {
        message: Some(BRIDGE_RUNTIME_MESSAGE.into()),
        level: sentry::Level::Error,
        ..Default::default()
    };
    event.tags.insert("surface".into(), "bridge".into());
    event
        .tags
        .insert("error_code".into(), "bridge_runtime_failure".into());
    event.tags.insert("target".into(), safe_code(target));
    event.tags.insert("phase".into(), safe_code(phase));
    event.tags.insert("failure".into(), failure.into());
    if let Some(attempt) = attempt {
        event.tags.insert("attempt".into(), attempt.to_string());
    }
    if let Some(failure_text) = failure_text {
        event.extra.insert(
            "failure_text".into(),
            crate::diagnostics::safe_text(failure_text).into(),
        );
    }
    sentry::capture_event(event);
}

fn should_report_bridge_attempt(attempt: u32) -> bool {
    attempt <= 3 || attempt.is_power_of_two()
}

fn classify_bridge_runtime_failure(error: &(dyn std::error::Error + 'static)) -> &'static str {
    if error
        .downcast_ref::<std::io::Error>()
        .is_some_and(|error| error.kind() == std::io::ErrorKind::ConnectionAborted)
    {
        return "provider_epoch_ended";
    }
    let message = error.to_string().to_ascii_lowercase();
    if message.contains("agent configuration is unavailable") {
        "agent_configuration_catalog_unavailable"
    } else if message.contains("project selection is no longer available") {
        "agent_project_unavailable"
    } else if message.contains("model selection is no longer available") {
        "agent_model_unavailable"
    } else if message.contains("reasoning selection is no longer available") {
        "agent_reasoning_unavailable"
    } else if message.contains("bound to a different agent provider")
        || message.contains("belongs to provider")
    {
        "provider_mismatch"
    } else if message.contains("timed out with an unknown provider outcome") {
        "ambiguous_provider_timeout"
    } else if message.contains("authentication") && message.contains("failed") {
        "provider_authentication_failed"
    } else if message.contains("authentication is required") {
        "provider_authentication_required"
    } else if message.contains("active elsewhere") || message.contains("active writer") {
        "provider_session_busy"
    } else if message.contains("bad request") && message.contains("http 400") {
        "remote_bad_request"
    } else if message.contains("epoch ended") {
        "provider_epoch_ended"
    } else if message.contains("app-server disconnected")
        || message.contains("process exited")
        || message.contains("exited during")
    {
        "provider_process_exited"
    } else if message.contains("timed out") || message.contains("timeout") {
        "timeout"
    } else if message.contains("websocket")
        || message.contains("realtime connection")
        || message.contains("event stream closed")
        || message.contains("no route to host")
        || message.contains("lookup address")
    {
        "inline_network"
    } else if message.contains("protocol") || message.contains("malformed") {
        "provider_protocol"
    } else if message.contains("database") || message.contains("sqlite") {
        "local_store"
    } else {
        "unknown"
    }
}

fn install_panic_hook() {
    PANIC_HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |panic| {
            let mut event = sentry::protocol::Event {
                message: Some(PANIC_MESSAGE.into()),
                level: sentry::Level::Fatal,
                ..Default::default()
            };
            event.tags.insert("surface".into(), "process".into());
            event.tags.insert("error_code".into(), "panic".into());
            event.tags.insert("phase".into(), "panic".into());
            sentry::capture_event(event);
            previous(panic);
        }));
    });
}

fn safe_code(value: &str) -> String {
    if !value.is_empty()
        && value.len() <= 80
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    {
        value.to_owned()
    } else {
        "unknown".to_owned()
    }
}

fn allowlisted_event(event: sentry::protocol::Event<'static>) -> sentry::protocol::Event<'static> {
    // Reconstruct instead of blacklisting: future integrations/scope changes
    // cannot silently add usernames, request bodies, breadcrumbs, or stacks.
    let surface = event
        .tags
        .get("surface")
        .map(String::as_str)
        .filter(|surface| matches!(*surface, "bridge" | "process"));
    let message = match surface {
        Some("bridge") => BRIDGE_RUNTIME_MESSAGE,
        Some("process") => PANIC_MESSAGE,
        _ => COMMAND_FAILURE_MESSAGE,
    };
    let mut safe = sentry::protocol::Event {
        event_id: event.event_id,
        timestamp: event.timestamp,
        message: Some(message.into()),
        level: if surface == Some("process") {
            sentry::Level::Fatal
        } else {
            sentry::Level::Error
        },
        release: Some(format!("inline-cli@{}", env!("CARGO_PKG_VERSION")).into()),
        ..Default::default()
    };
    for name in [
        "surface",
        "error_code",
        "target",
        "phase",
        "failure",
        "attempt",
        "command",
    ] {
        if let Some(value) = event.tags.get(name) {
            safe.tags.insert(name.into(), safe_code(value));
        }
    }
    if let Some(failure_text) = event
        .extra
        .get("failure_text")
        .and_then(|value| value.as_str())
    {
        let failure_text = crate::diagnostics::safe_text(failure_text);
        if !failure_text.is_empty() {
            safe.extra
                .insert("failure_text".into(), failure_text.into());
        }
    }
    safe.tags.insert("os".into(), std::env::consts::OS.into());
    safe.tags
        .insert("arch".into(), std::env::consts::ARCH.into());
    safe.fingerprint = if surface.is_some() {
        vec![
            "inline-cli".into(),
            safe.tags.get("surface").cloned().unwrap_or_default().into(),
            safe.tags
                .get("error_code")
                .cloned()
                .unwrap_or_default()
                .into(),
            safe.tags.get("target").cloned().unwrap_or_default().into(),
            safe.tags.get("phase").cloned().unwrap_or_default().into(),
            safe.tags.get("failure").cloned().unwrap_or_default().into(),
        ]
        .into()
    } else {
        vec![
            "inline-cli".into(),
            safe.tags.get("command").cloned().unwrap_or_default().into(),
            safe.tags
                .get("error_code")
                .cloned()
                .unwrap_or_default()
                .into(),
            safe.tags.get("target").cloned().unwrap_or_default().into(),
            safe.tags.get("phase").cloned().unwrap_or_default().into(),
        ]
        .into()
    };
    safe
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_opt_out_is_case_and_whitespace_insensitive() {
        for value in ["OFF", " off ", "0", "false", "False"] {
            assert!(telemetry_disabled(value));
        }
        assert!(!telemetry_disabled("on"));
    }

    #[test]
    fn sentry_features_do_not_break_the_existing_tls_client() {
        // Enabling a second rustls crypto provider can make this panic, even
        // when telemetry is disabled. No network request is made here.
        assert!(reqwest::Client::builder().build().is_ok());
    }

    #[test]
    fn outbound_event_cannot_include_arbitrary_diagnostics_or_pii() {
        let mut event = sentry::protocol::Event {
            message: Some("private-token".into()),
            server_name: Some("private-host".into()),
            user: Some(sentry::protocol::User {
                email: Some("private@example.com".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        event.extra.insert("secret".into(), "private-token".into());
        event.tags.insert("phase".into(), "integration".into());
        event.tags.insert("path".into(), "/Users/private".into());
        let encoded = serde_json::to_string(&allowlisted_event(event)).unwrap();
        assert!(encoded.contains("integration"));
        assert!(!encoded.contains("private"));
    }

    #[test]
    fn bridge_events_keep_only_bounded_failure_metadata() {
        let mut event = sentry::protocol::Event {
            message: Some("private prompt and /Users/private/project".into()),
            server_name: Some("private-host".into()),
            ..Default::default()
        };
        event.tags.insert("surface".into(), "bridge".into());
        event
            .tags
            .insert("error_code".into(), "bridge_runtime_failure".into());
        event.tags.insert("target".into(), "codex".into());
        event.tags.insert("phase".into(), "provider_cycle".into());
        event.tags.insert(
            "failure".into(),
            "agent_configuration_catalog_unavailable".into(),
        );
        event.tags.insert("attempt".into(), "8".into());
        event
            .tags
            .insert("session_id".into(), "private-session".into());
        event.extra.insert(
            "failure_text".into(),
            "Claude login failed at /Users/private/project\nTOKEN=private-value".into(),
        );

        let safe = allowlisted_event(event);
        let encoded = serde_json::to_string(&safe).unwrap();
        assert_eq!(safe.message.as_deref(), Some(BRIDGE_RUNTIME_MESSAGE));
        assert_eq!(
            safe.fingerprint,
            vec![
                "inline-cli",
                "bridge",
                "bridge_runtime_failure",
                "codex",
                "provider_cycle",
                "agent_configuration_catalog_unavailable",
            ]
        );
        assert!(encoded.contains("agent_configuration_catalog_unavailable"));
        assert!(encoded.contains("Claude login failed"));
        assert!(!encoded.contains("private"));
        assert!(!encoded.contains("session_id"));
    }

    #[test]
    fn bridge_failure_classification_never_returns_the_source_text() {
        let configuration = std::io::Error::other(
            "This thread's Agent configuration is unavailable on this provider.",
        );
        let unknown = std::io::Error::other("private prompt /Users/private/project token-123");
        let bad_request = std::io::Error::other("Internal: Bad request (HTTP 400)");
        assert_eq!(
            classify_bridge_runtime_failure(&configuration),
            "agent_configuration_catalog_unavailable"
        );
        assert_eq!(classify_bridge_runtime_failure(&unknown), "unknown");
        assert_eq!(
            classify_bridge_runtime_failure(&bad_request),
            "remote_bad_request"
        );
        assert!(should_report_bridge_attempt(1));
        assert!(should_report_bridge_attempt(3));
        assert!(should_report_bridge_attempt(8));
        assert!(!should_report_bridge_attempt(5));
    }

    #[test]
    fn only_provider_epoch_failures_request_a_restart() {
        let local_delivery = std::io::Error::other("database write failed");
        let provider_epoch = std::io::Error::other("local agent connection epoch ended");
        let typed_provider_epoch = std::io::Error::new(
            std::io::ErrorKind::ConnectionAborted,
            "private turn cleanup diagnostic",
        );
        let ambiguous_start =
            std::io::Error::other("thread/start timed out with an unknown provider outcome");

        assert!(!bridge_error_requires_provider_restart(&local_delivery));
        assert!(bridge_error_requires_provider_restart(&provider_epoch));
        assert!(bridge_error_requires_provider_restart(
            &typed_provider_epoch
        ));
        assert_eq!(
            classify_bridge_runtime_failure(&typed_provider_epoch),
            "provider_epoch_ended"
        );
        assert!(bridge_error_requires_provider_restart(&ambiguous_start));
    }

    #[test]
    fn panic_events_keep_only_the_fixed_process_metadata() {
        let mut event = sentry::protocol::Event {
            message: Some("private panic payload and /Users/private/project".into()),
            level: sentry::Level::Fatal,
            server_name: Some("private-host".into()),
            ..Default::default()
        };
        event.tags.insert("surface".into(), "process".into());
        event.tags.insert("error_code".into(), "panic".into());
        event.tags.insert("phase".into(), "panic".into());
        event
            .tags
            .insert("session_id".into(), "private-session".into());

        let safe = allowlisted_event(event);
        let encoded = serde_json::to_string(&safe).unwrap();
        assert_eq!(safe.message.as_deref(), Some(PANIC_MESSAGE));
        assert_eq!(safe.level, sentry::Level::Fatal);
        assert_eq!(
            safe.fingerprint,
            vec!["inline-cli", "process", "panic", "", "panic", ""]
        );
        assert!(!encoded.contains("private"));
        assert!(!encoded.contains("session_id"));
    }
}

//! Optional metadata-only error reporting. Never capture arbitrary Error values.
use std::sync::Arc;
use std::time::Duration;

const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);

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
    options.before_send = Some(Arc::new(|event| Some(metadata_only(event))));
    Some(TelemetryGuard(Some(sentry::init(options))))
}

fn telemetry_disabled(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "off" | "0" | "false"
    )
}

pub(crate) fn report(code: &str, target: Option<&str>, phase: Option<&str>) {
    if matches!(
        code,
        "invalid_args" | "not_authenticated" | "setup_cancelled" | "confirmation_required"
    ) {
        return;
    }
    let mut event = sentry::protocol::Event {
        message: Some("Inline CLI command failed".into()),
        level: sentry::Level::Error,
        ..Default::default()
    };
    event.tags.insert("error_code".into(), safe_code(code));
    if let Some(target) = target {
        event.tags.insert("target".into(), safe_code(target));
    }
    if let Some(phase) = phase {
        event.tags.insert("phase".into(), safe_code(phase));
    }
    sentry::capture_event(event);
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

fn metadata_only(event: sentry::protocol::Event<'static>) -> sentry::protocol::Event<'static> {
    // Reconstruct instead of blacklisting: future integrations/scope changes
    // cannot silently add usernames, request bodies, breadcrumbs, or stacks.
    let mut safe = sentry::protocol::Event {
        event_id: event.event_id,
        timestamp: event.timestamp,
        message: Some("Inline CLI command failed".into()),
        level: sentry::Level::Error,
        release: Some(format!("inline-cli@{}", env!("CARGO_PKG_VERSION")).into()),
        ..Default::default()
    };
    for name in ["error_code", "target", "phase"] {
        if let Some(value) = event.tags.get(name) {
            safe.tags.insert(name.into(), safe_code(value));
        }
    }
    safe.tags.insert("os".into(), std::env::consts::OS.into());
    safe.tags
        .insert("arch".into(), std::env::consts::ARCH.into());
    safe.fingerprint = vec![
        "inline-cli".into(),
        safe.tags
            .get("error_code")
            .cloned()
            .unwrap_or_default()
            .into(),
        safe.tags.get("target").cloned().unwrap_or_default().into(),
        safe.tags.get("phase").cloned().unwrap_or_default().into(),
    ]
    .into();
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
        let encoded = serde_json::to_string(&metadata_only(event)).unwrap();
        assert!(encoded.contains("integration"));
        assert!(!encoded.contains("private"));
    }
}

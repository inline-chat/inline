//! Local diagnostics are separate from the allowlisted telemetry payload.
use std::error::Error;
use std::io::Write;
use std::sync::OnceLock;

use crate::errors::{JsonCliError, json_cli_error_from_error};

const MAX_DETAIL_CHARS: usize = 4_000;

pub(crate) fn init(verbosity: u8) {
    if verbosity == 0 {
        return;
    }
    let level = if verbosity > 1 {
        log::LevelFilter::Trace
    } else {
        log::LevelFilter::Debug
    };
    let mut logger = env_logger::Builder::new();
    logger
        // HTTP and provider wire traces can contain credentials and content.
        // Do not inherit RUST_LOG or enable dependency targets wholesale.
        .filter_level(log::LevelFilter::Off)
        .filter_module("inline::", level)
        .filter_module("inline_agent_bridge", level)
        .filter_module("inline_agent_driver_codex", level)
        .filter_module("inline_agent_driver_acp", level)
        .write_style(env_logger::WriteStyle::Never)
        .format(|buf, record| {
            writeln!(
                buf,
                "{} {} {}: {}",
                buf.timestamp_millis(),
                record.level(),
                record.target(),
                safe_text(&record.args().to_string())
            )
        });
    let _ = logger.try_init();
    log::debug!(
        "diagnostics enabled version={} os={} arch={} trace={}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH,
        verbosity > 1
    );
}

pub(crate) fn safe_text(value: &str) -> String {
    // Bound work before redaction, then bound what reaches stderr/UI. This
    // sanitizer also removes terminal controls, local paths and URL secrets.
    let mut bounded: String = value.chars().take(64 * 1024).collect();
    static SECRETS: OnceLock<Vec<regex::Regex>> = OnceLock::new();
    for pattern in SECRETS.get_or_init(|| {
        [
            r#"(?i)\bBearer\s+[^\s"'<>]+"#,
            r"\b[0-9]+:IN[A-Za-z0-9_-]{12,}\b",
            r"\bsk-[A-Za-z0-9_-]{16,}\b",
            r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b",
        ]
        .iter()
        .map(|pattern| regex::Regex::new(pattern).expect("static secret pattern"))
        .collect()
    }) {
        bounded = pattern.replace_all(&bounded, "[redacted]").into_owned();
    }
    let redacted = inline_agent_bridge::sanitize_diagnostic_text(&bounded).unwrap_or_default();
    let mut result: String = redacted.chars().take(MAX_DETAIL_CHARS).collect();
    if redacted.chars().count() > MAX_DETAIL_CHARS {
        result.push_str(" [truncated]");
    }
    result
}

pub(crate) fn error_chain(error: &(dyn Error + 'static)) -> String {
    let mut parts = vec![error.to_string()];
    let mut source = error.source();
    for _ in 0..8 {
        let Some(cause) = source else { break };
        let text = cause.to_string();
        if !parts.contains(&text) {
            parts.push(text);
        }
        source = cause.source();
    }
    safe_text(&parts.join(": "))
}

pub(crate) fn error_payload(error: &(dyn Error + 'static)) -> JsonCliError {
    let mut payload = json_cli_error_from_error(error);
    let detail = error_chain(error);
    payload.message = safe_text(&payload.message);
    // Preserve the actionable outer context and underlying transport cause.
    if !error.is::<crate::errors::CliError>()
        && payload.body.is_none()
        && !detail.is_empty()
        && !payload.message.contains(&detail)
    {
        payload.message = safe_text(&format!("{}: {detail}", payload.message));
    }
    payload.hint = payload.hint.map(|text| safe_text(&text));
    payload.examples = payload
        .examples
        .iter()
        .map(|text| safe_text(text))
        .collect();
    // Arbitrary API bodies may contain user data, even on a failure.
    payload.body = None;
    payload.api_error = payload.api_error.map(|text| safe_text(&text));
    payload
}

pub(crate) fn log_error(error: &(dyn Error + 'static)) {
    let payload = error_payload(error);
    log::debug!("command failed code={}: {}", payload.code, payload.message);
    if let Some(hint) = payload.hint {
        log::debug!("recovery hint: {hint}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostics_preserve_causes_and_scrub_secrets() {
        let error = std::io::Error::other("TLS failed: certificate expired; TOKEN=private-token");
        let payload = error_payload(&error);
        assert!(payload.message.contains("certificate expired"));
        assert!(!payload.message.contains("private-token"));
        assert!(safe_text("Authorization: Bearer secret").contains("[redacted]"));
        assert!(!safe_text("https://example.com/?token=hidden").contains("hidden"));
        assert!(
            !safe_text("invalid 123:INabcdefghijklmno credential").contains("INabcdefghijklmno")
        );
        assert!(safe_text(&"x".repeat(10_000)).len() < 4_100);
    }

    #[test]
    fn diagnostic_prose_preserves_auth_errors_but_scrubs_explicit_values() {
        for message in [
            "No token found.",
            "Token missing",
            "Please provide a token",
            "credential lookup failed",
        ] {
            assert_eq!(safe_text(message), message);
        }
        for message in [
            "TOKEN=private-value",
            "token = private-value",
            "token: private-value",
            "--token private-value",
            "api_key: private-value",
            r#"{"refreshToken":"private-value"}"#,
            r#"{"apiKey":"private-value"}"#,
            "accessToken = private-value",
            "--providerApiKey private-value",
            "sessionToken: private-value",
            "PRIVATE_KEY: private-value",
            "Authorization: Bearer private-value",
        ] {
            assert!(!safe_text(message).contains("private-value"), "{message}");
        }
    }

    #[test]
    fn structured_hint_is_not_duplicated_into_the_message() {
        let error = crate::errors::CliError::invalid_args("Unsupported profile");
        let payload = error_payload(&error);
        assert_eq!(payload.message, "Unsupported profile");
        assert!(payload.hint.is_some());
    }

    #[test]
    fn top_level_rendering_never_includes_an_arbitrary_http_body() {
        let error = crate::errors::HttpStatusCliError::download_failed(
            403,
            Some("private response body TOKEN=secret-value".into()),
        );
        assert!(error_payload(&error).body.is_none());
        let rendered = crate::errors::human_cli_error_from_error(&error);
        assert!(!rendered.contains("private response body"));
        assert!(!rendered.contains("secret-value"));
    }
}

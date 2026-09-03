//! Local diagnostics are separate from the allowlisted telemetry payload.
use std::collections::VecDeque;
use std::error::Error;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::errors::{JsonCliError, json_cli_error_from_error};

const MAX_DETAIL_CHARS: usize = 4_000;
const MAX_BUFFERED_LINES: usize = 256;

#[derive(Default)]
struct BufferedDiagnostics {
    verbosity: u8,
    lines: VecDeque<String>,
}

static BUFFERED_DIAGNOSTICS: OnceLock<Mutex<BufferedDiagnostics>> = OnceLock::new();

fn buffered_diagnostics() -> &'static Mutex<BufferedDiagnostics> {
    BUFFERED_DIAGNOSTICS.get_or_init(|| Mutex::new(BufferedDiagnostics::default()))
}

pub(crate) fn init(verbosity: u8) {
    if verbosity == 0 {
        return;
    }
    if let Ok(mut diagnostics) = buffered_diagnostics().lock() {
        diagnostics.verbosity = verbosity;
        diagnostics.lines.clear();
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
            let line = format!(
                "{} {} {}: {}",
                buf.timestamp_millis(),
                record.level(),
                record.target(),
                safe_text(&record.args().to_string())
            );
            record_diagnostic_line(&line);
            writeln!(buf, "{line}")
        });
    let _ = logger.try_init();
    log::debug!(
        "diagnostics enabled version={} os={} arch={} install_source={} trace={}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH,
        executable_provenance(),
        verbosity > 1
    );
}

fn record_diagnostic_line(line: &str) {
    let Ok(mut diagnostics) = buffered_diagnostics().lock() else {
        return;
    };
    if diagnostics.verbosity == 0 {
        return;
    }
    if diagnostics.lines.len() == MAX_BUFFERED_LINES {
        diagnostics.lines.pop_front();
    }
    diagnostics.lines.push_back(safe_text(line));
}

/// Writes the bounded, already-scrubbed verbose transcript after a command failure.
///
/// The report is created only when verbose diagnostics were enabled. It uses a
/// new owner-readable temporary file and never includes argv, environment
/// variables, request bodies, message content, or credentials.
pub(crate) fn write_failure_report(summary: &str) -> std::io::Result<Option<PathBuf>> {
    let lines = {
        let diagnostics = buffered_diagnostics()
            .lock()
            .map_err(|_| std::io::Error::other("diagnostic buffer is unavailable"))?;
        if diagnostics.verbosity == 0 {
            return Ok(None);
        }
        diagnostics.lines.iter().cloned().collect::<Vec<_>>()
    };

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let path = std::env::temp_dir().join(format!(
        "inline-diagnostics-{timestamp}-{}.log",
        std::process::id()
    ));
    write_failure_report_to(&path, summary, &lines)?;
    Ok(Some(path))
}

fn write_failure_report_to(
    path: &std::path::Path,
    summary: &str,
    lines: &[String],
) -> std::io::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    writeln!(file, "Inline CLI diagnostic report")?;
    writeln!(file, "version: {}", env!("CARGO_PKG_VERSION"))?;
    writeln!(file, "os: {}", std::env::consts::OS)?;
    writeln!(file, "architecture: {}", std::env::consts::ARCH)?;
    writeln!(file, "install source: {}", executable_provenance())?;
    writeln!(file, "summary: {}", safe_text(summary))?;
    writeln!(file)?;
    writeln!(file, "Recent verbose diagnostics (oldest to newest):")?;
    for line in lines {
        writeln!(file, "{}", safe_text(line))?;
    }
    Ok(())
}

fn executable_provenance() -> &'static str {
    std::env::current_exe()
        .ok()
        .as_deref()
        .map(executable_provenance_for_path)
        .unwrap_or("unknown")
}

fn executable_provenance_for_path(path: &std::path::Path) -> &'static str {
    let value = path.to_string_lossy().replace('\\', "/");
    if value.contains("/target/debug/") || value.contains("/target/release/") {
        "source_build"
    } else if value.contains("/.cargo/bin/") {
        "cargo"
    } else if value.contains("/Cellar/") || value.contains("/Caskroom/") {
        "homebrew"
    } else if value.contains("/.local/share/inline/bridge/") {
        "managed_bridge_copy"
    } else if value.starts_with("/opt/homebrew/bin/")
        || value.starts_with("/usr/local/bin/")
        || value.starts_with("/usr/bin/")
    {
        "system_prefix_unknown"
    } else {
        "unknown"
    }
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

    #[test]
    fn executable_provenance_is_conservative() {
        use std::path::Path;

        assert_eq!(
            executable_provenance_for_path(Path::new(
                "/opt/homebrew/Cellar/inline/0.7.8/bin/inline"
            )),
            "homebrew"
        );
        assert_eq!(
            executable_provenance_for_path(Path::new("/opt/homebrew/bin/inline")),
            "system_prefix_unknown"
        );
        assert_eq!(
            executable_provenance_for_path(Path::new("/workspace/target/debug/inline")),
            "source_build"
        );
    }

    #[test]
    fn failure_report_is_bounded_scrubbed_and_owner_readable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("setup-failure.log");
        write_failure_report_to(
            &path,
            "service timed out TOKEN=private-summary",
            &[
                "first useful line".to_string(),
                "Authorization: Bearer private-log-value".to_string(),
            ],
        )
        .unwrap();

        let report = std::fs::read_to_string(&path).unwrap();
        assert!(report.contains("Inline CLI diagnostic report"));
        assert!(report.contains("service timed out"));
        assert!(report.contains("first useful line"));
        assert!(!report.contains("private-summary"));
        assert!(!report.contains("private-log-value"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
}

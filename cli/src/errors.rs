use serde::Serialize;
use std::fmt::Write as _;
use std::io::{self, IsTerminal};

use crate::api::ApiError;
use crate::realtime::RealtimeError;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JsonErrorEnvelope {
    pub(crate) error: JsonCliError,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JsonCliError {
    pub(crate) code: String,
    pub(crate) message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) api_error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) api_error_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) hint: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub(crate) examples: Vec<String>,
}

impl JsonCliError {
    pub(crate) fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            status: None,
            api_error: None,
            api_error_code: None,
            body: None,
            hint: None,
            examples: Vec::new(),
        }
    }

    pub(crate) fn invalid_args(message: impl Into<String>) -> Self {
        let mut payload = Self::new("invalid_args", message);
        payload.hint = Some("Run with --help to see valid usage.".to_string());
        payload
    }
}

#[derive(Debug)]
pub(crate) struct CliError {
    pub(crate) code: &'static str,
    pub(crate) message: String,
    pub(crate) hint: Option<String>,
    pub(crate) examples: Vec<String>,
}

impl CliError {
    pub(crate) fn invalid_args(message: impl Into<String>) -> Self {
        Self {
            code: "invalid_args",
            message: message.into(),
            hint: Some("Run with --help to see valid usage.".to_string()),
            examples: Vec::new(),
        }
    }

    pub(crate) fn missing_peer() -> Self {
        Self {
            code: "missing_peer",
            message: "Missing required argument: provide --chat-id or --user-id".to_string(),
            hint: Some(
                "Use `inline chats list` to find chat IDs, or `inline users list` for DM user IDs."
                    .to_string(),
            ),
            examples: vec![
                "inline messages list --chat-id 123".to_string(),
                "inline messages list --user-id 42".to_string(),
            ],
        }
    }

    pub(crate) fn missing_forward_source() -> Self {
        Self {
            code: "missing_forward_source",
            message: "Missing required argument: provide --from-chat-id or --from-user-id"
                .to_string(),
            hint: Some(
                "Use `inline chats list` to find chat IDs, or `inline users list --filter ... --id` for DM user IDs."
                    .to_string(),
            ),
            examples: vec![
                "inline messages forward --from-chat-id 123 --message-id 456 --to-chat-id 789"
                    .to_string(),
                "inline messages forward --from-user-id 42 --message-id 456 --to-chat-id 789"
                    .to_string(),
            ],
        }
    }

    pub(crate) fn missing_forward_destination() -> Self {
        Self {
            code: "missing_forward_destination",
            message: "Missing required argument: provide --to-chat-id or --to-user-id".to_string(),
            hint: Some(
                "Use `inline chats list` to find chat IDs, or `inline users list --filter ... --id` for DM user IDs."
                    .to_string(),
            ),
            examples: vec![
                "inline messages forward --from-chat-id 123 --message-id 456 --to-chat-id 789"
                    .to_string(),
                "inline messages forward --from-chat-id 123 --message-id 456 --to-user-id 42"
                    .to_string(),
            ],
        }
    }

    pub(crate) fn missing_message_ids() -> Self {
        Self {
            code: "missing_message_ids",
            message: "Missing required argument: provide one or more --message-id values"
                .to_string(),
            hint: Some("Repeat --message-id to act on multiple messages.".to_string()),
            examples: vec![
                "inline messages delete --chat-id 123 --message-id 456".to_string(),
                "inline messages forward --from-chat-id 123 --message-id 456 --message-id 789 --to-chat-id 321"
                    .to_string(),
            ],
        }
    }

    pub(crate) fn confirmation_required() -> Self {
        Self {
            code: "confirmation_required",
            message: "Confirmation required: re-run with --yes or -y to proceed".to_string(),
            hint: Some(
                "This command is destructive. In --json mode, the CLI never prompts; pass --yes or -y explicitly."
                    .to_string(),
            ),
            examples: vec![
                "inline chats delete --chat-id 123 -y --json".to_string(),
                "inline messages delete --chat-id 123 --message-id 456 --yes --json".to_string(),
                "inline spaces delete-member --space-id 31 --user-id 42 -y --json".to_string(),
            ],
        }
    }

    pub(crate) fn missing_text_or_stdin() -> Self {
        Self {
            code: "missing_text",
            message: "Missing required argument: provide --text/--message/--msg or --stdin"
                .to_string(),
            hint: Some(
                "Use --text (or its aliases) for inline content, or --stdin to read from standard input."
                    .to_string(),
            ),
            examples: vec![
                "inline messages edit --chat-id 123 --message-id 456 --text \"updated\"".to_string(),
                "echo \"updated\" | inline messages edit --chat-id 123 --message-id 456 --stdin"
                    .to_string(),
            ],
        }
    }

    pub(crate) fn stdin_not_piped() -> Self {
        Self {
            code: "stdin_not_piped",
            message: "--stdin was provided, but stdin is a terminal".to_string(),
            hint: Some(
                "Pipe message content into the command, redirect a file, or use --text/--message/--msg."
                    .to_string(),
            ),
            examples: vec![
                "echo \"hello\" | inline messages send --chat-id 123 --stdin".to_string(),
                "inline messages send --chat-id 123 --text \"hello\"".to_string(),
            ],
        }
    }

    pub(crate) fn mentions_require_text() -> Self {
        Self {
            code: "invalid_mentions",
            message:
                "Invalid usage: --mention requires message text via --text/--message/--msg or --stdin"
                    .to_string(),
            hint: Some(
                "Mentions are UTF-16 offsets into the message text; provide the same text you calculated offsets against."
                    .to_string(),
            ),
            examples: vec![
                "inline messages send --chat-id 123 --text \"@Sam hello\" --mention 42:0:4"
                    .to_string(),
            ],
        }
    }

    pub(crate) fn missing_query() -> Self {
        Self {
            code: "missing_query",
            message: "Missing required argument: provide --query with search terms".to_string(),
            hint: Some("--query is repeatable; pass one or more queries to search.".to_string()),
            examples: vec![
                "inline messages search --chat-id 123 --query \"onboarding\"".to_string(),
                "inline search --user-id 42 --query \"bug\" --query \"broken\"".to_string(),
            ],
        }
    }

    pub(crate) fn invalid_time_range() -> Self {
        Self {
            code: "invalid_time_range",
            message: "Invalid time range: --until must be on or after --since".to_string(),
            hint: Some(
                "Time flows from --since to --until (e.g. --since \"2d ago\" --until \"1d ago\")."
                    .to_string(),
            ),
            examples: vec![
                "inline messages list --chat-id 123 --since \"2d ago\" --until \"1d ago\""
                    .to_string(),
            ],
        }
    }

    pub(crate) fn missing_translate_language() -> Self {
        Self {
            code: "missing_translate_language",
            message: "Missing value: --translate requires a language code".to_string(),
            hint: Some("Use a language code like en, es, de.".to_string()),
            examples: vec!["inline messages list --chat-id 123 --translate en".to_string()],
        }
    }

    pub(crate) fn not_found_user_id(user_id: i64) -> Self {
        Self {
            code: "not_found",
            message: format!("Not found: user id {user_id} does not exist in your chat list"),
            hint: Some("Run `inline users list` to see available user IDs.".to_string()),
            examples: vec!["inline users list".to_string()],
        }
    }

    pub(crate) fn interactive_required(action: impl Into<String>, examples: Vec<String>) -> Self {
        let action = action.into();
        Self {
            code: "interactive_required",
            message: format!("Interactive terminal required: {action}"),
            hint: Some(
                "This command needs a terminal prompt. For automation, use an existing token via INLINE_TOKEN or run an explicit non-interactive command."
                    .to_string(),
            ),
            examples,
        }
    }

    pub(crate) fn not_authenticated() -> Self {
        Self {
            code: "not_authenticated",
            message: "No token found. Run `inline auth login` first.".to_string(),
            hint: Some(
                "Agents and CI can pass a token with the INLINE_TOKEN environment variable."
                    .to_string(),
            ),
            examples: vec![
                "inline auth login".to_string(),
                "INLINE_TOKEN=... inline auth me --json".to_string(),
            ],
        }
    }

    pub(crate) fn unexpected_rpc_result(method: impl Into<String>) -> Self {
        let method = method.into();
        Self {
            code: "unexpected_rpc_result",
            message: format!("Unexpected RPC result for {method}"),
            hint: Some(
                "The realtime API returned a response variant that does not match the requested method. This usually means the CLI and server protocol versions are out of sync."
                    .to_string(),
            ),
            examples: vec![
                "inline update".to_string(),
                "inline doctor --json".to_string(),
            ],
        }
    }

    pub(crate) fn unexpected_api_response(
        context: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        let context = context.into();
        let detail = detail.into();
        Self {
            code: "unexpected_api_response",
            message: format!("Unexpected API response for {context}: {detail}"),
            hint: Some(
                "The server returned a success response that is missing required data. This usually means the CLI and server API versions are out of sync."
                    .to_string(),
            ),
            examples: vec![
                "inline update".to_string(),
                "inline doctor --json".to_string(),
            ],
        }
    }
}

impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(f, "{}", self.message)?;
        if let Some(hint) = &self.hint {
            writeln!(f)?;
            writeln!(f, "Hint: {hint}")?;
        }
        if !self.examples.is_empty() {
            writeln!(f)?;
            writeln!(f, "Examples:")?;
            for example in &self.examples {
                writeln!(f, "  {example}")?;
            }
        }
        Ok(())
    }
}

impl std::error::Error for CliError {}

#[derive(Debug)]
pub(crate) struct HttpStatusCliError {
    pub(crate) code: &'static str,
    pub(crate) message: String,
    pub(crate) status: u16,
    pub(crate) body: Option<String>,
    pub(crate) hint: Option<String>,
}

impl HttpStatusCliError {
    pub(crate) fn download_failed(status: u16, body: Option<String>) -> Self {
        Self {
            code: "download_http_status",
            message: format!("Download failed with HTTP {status}"),
            status,
            body,
            hint: Some(
                "The attachment URL was reachable but returned a non-success HTTP status. The file may have expired or access may be denied."
                    .to_string(),
            ),
        }
    }
}

impl std::fmt::Display for HttpStatusCliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(f, "{}", self.message)?;
        if let Some(body) = &self.body {
            writeln!(f)?;
            writeln!(f, "Response body: {body}")?;
        }
        if let Some(hint) = &self.hint {
            writeln!(f)?;
            writeln!(f, "Hint: {hint}")?;
        }
        Ok(())
    }
}

impl std::error::Error for HttpStatusCliError {}

pub(crate) fn json_cli_error_from_error(error: &(dyn std::error::Error + 'static)) -> JsonCliError {
    if let Some(cli_error) = error.downcast_ref::<CliError>() {
        let mut payload = JsonCliError::new(cli_error.code, cli_error.message.clone());
        payload.hint = cli_error.hint.clone();
        payload.examples = cli_error.examples.clone();
        return payload;
    }

    if let Some(status_error) = error.downcast_ref::<HttpStatusCliError>() {
        let mut payload = JsonCliError::new(status_error.code, status_error.message.clone());
        payload.status = Some(status_error.status);
        payload.body = status_error.body.clone();
        payload.hint = status_error.hint.clone();
        return payload;
    }

    if let Some(api_error) = error.downcast_ref::<ApiError>() {
        return json_cli_error_from_api_error(api_error);
    }

    if let Some(realtime_error) = error.downcast_ref::<RealtimeError>() {
        return json_cli_error_from_realtime_error(realtime_error);
    }

    if let Some(http_error) = error.downcast_ref::<reqwest::Error>() {
        return json_cli_error_from_http_error(http_error);
    }

    if let Some(io_error) = error.downcast_ref::<std::io::Error>() {
        return json_cli_error_from_io_error(io_error);
    }

    if let Some(json_error) = find_error_in_chain::<serde_json::Error>(error) {
        return json_cli_error_from_json_error(json_error);
    }

    if let Some(io_error) = find_error_in_chain::<std::io::Error>(error) {
        return json_cli_error_from_io_error(io_error);
    }

    JsonCliError::new("error", error.to_string())
}

pub(crate) fn human_cli_error_from_error(error: &(dyn std::error::Error + 'static)) -> String {
    let payload = json_cli_error_from_error(error);
    format_human_cli_error(&payload, &style_error_label("Error"))
}

fn format_human_cli_error(payload: &JsonCliError, error_label: &str) -> String {
    let mut output = String::new();
    writeln!(&mut output, "{error_label}: {}", payload.message).expect("write string");
    writeln!(&mut output, "Code: {}", payload.code).expect("write string");

    if let Some(status) = payload.status {
        writeln!(&mut output, "Status: {status}").expect("write string");
    }

    if let Some(api_error) = &payload.api_error {
        match payload.api_error_code {
            Some(code) => {
                writeln!(&mut output, "API error: {api_error} ({code})").expect("write string")
            }
            None => writeln!(&mut output, "API error: {api_error}").expect("write string"),
        }
    }

    if let Some(body) = &payload.body {
        writeln!(&mut output).expect("write string");
        writeln!(&mut output, "Response: {body}").expect("write string");
    }

    if let Some(hint) = &payload.hint {
        writeln!(&mut output).expect("write string");
        writeln!(&mut output, "Hint: {hint}").expect("write string");
    }

    if !payload.examples.is_empty() {
        writeln!(&mut output).expect("write string");
        writeln!(&mut output, "Examples:").expect("write string");
        for example in &payload.examples {
            writeln!(&mut output, "  {example}").expect("write string");
        }
    }

    output.trim_end_matches('\n').to_string()
}

fn style_error_label(value: &str) -> String {
    if should_use_stderr_color() {
        format!("\x1b[1;31m{value}\x1b[0m")
    } else {
        value.to_string()
    }
}

fn should_use_stderr_color() -> bool {
    if std::env::var_os("NO_COLOR").is_some() {
        return false;
    }
    if let Some(force) = std::env::var_os("CLICOLOR_FORCE") {
        if force != "0" {
            return true;
        }
    }
    io::stderr().is_terminal()
}

fn find_error_in_chain<'a, T: std::error::Error + 'static>(
    mut error: &'a (dyn std::error::Error + 'static),
) -> Option<&'a T> {
    loop {
        if let Some(found) = error.downcast_ref::<T>() {
            return Some(found);
        }
        error = error.source()?;
    }
}

fn json_cli_error_from_http_error(error: &reqwest::Error) -> JsonCliError {
    let mut payload = JsonCliError::new("network_error", error.to_string());
    payload.status = error.status().map(|status| status.as_u16());
    payload.hint = Some(
        "Check network connectivity, configured Inline URLs, and attachment URLs.".to_string(),
    );
    payload
}

fn json_cli_error_from_io_error(error: &std::io::Error) -> JsonCliError {
    let mut payload = JsonCliError::new("io_error", error.to_string());
    payload.hint =
        Some("Check file paths, directory permissions, and available disk space.".to_string());
    payload
}

fn json_cli_error_from_json_error(error: &serde_json::Error) -> JsonCliError {
    let mut payload = JsonCliError::new("json_error", error.to_string());
    payload.hint =
        Some("The CLI could not encode or decode JSON in the expected shape.".to_string());
    payload
}

fn json_cli_error_from_api_error(error: &ApiError) -> JsonCliError {
    match error {
        ApiError::Api {
            status,
            error,
            error_code,
            description,
        } => {
            let mut payload = JsonCliError::new("api_error", description.clone());
            payload.status = *status;
            payload.api_error = Some(error.clone());
            payload.api_error_code = *error_code;
            payload.hint = Some("The Inline API rejected the request.".to_string());
            payload
        }
        ApiError::Status {
            status,
            message,
            body,
        } => {
            let mut payload = JsonCliError::new(
                "api_http_status",
                format!("Inline API returned HTTP {status}: {message}"),
            );
            payload.status = Some(*status);
            payload.body = body.clone();
            payload.hint =
                Some("The server did not return a standard Inline API error envelope.".to_string());
            payload
        }
        ApiError::Http(err) => {
            let mut payload = json_cli_error_from_http_error(err);
            payload.hint = Some("Check network connectivity and INLINE_API_BASE_URL.".to_string());
            payload
        }
        ApiError::Io(err) => json_cli_error_from_io_error(err),
        ApiError::Json(err) => {
            let mut payload = JsonCliError::new("api_decode_error", err.to_string());
            payload.hint =
                Some("The server response was not in the expected JSON shape.".to_string());
            payload
        }
    }
}

fn json_cli_error_from_realtime_error(error: &RealtimeError) -> JsonCliError {
    match error {
        RealtimeError::RpcError {
            code,
            error_code,
            error_name,
            message,
            friendly,
        } => {
            let mut payload = JsonCliError::new("rpc_error", friendly.clone());
            if (100..=599).contains(code) {
                payload.status = Some(*code as u16);
            }
            payload.api_error = Some(error_name.clone());
            payload.api_error_code = Some(*error_code);
            if !message.trim().is_empty() {
                payload.body = Some(message.clone());
            }
            payload
        }
        RealtimeError::ConnectionError {
            reason,
            reason_name,
            friendly,
        } => {
            let mut payload = JsonCliError::new("realtime_connection_error", friendly.clone());
            payload.api_error = Some(reason_name.clone());
            payload.api_error_code = Some(*reason);
            payload.hint = Some(realtime_connection_error_hint(reason_name).to_string());
            payload
        }
        RealtimeError::ConnectionClosed => {
            let mut payload = JsonCliError::new("realtime_connection_closed", error.to_string());
            payload.hint = Some("Check network connectivity and INLINE_REALTIME_URL.".to_string());
            payload
        }
        RealtimeError::WebSocket(err) => {
            let mut payload = JsonCliError::new("websocket_error", err.to_string());
            payload.hint = Some("Check network connectivity and INLINE_REALTIME_URL.".to_string());
            payload
        }
        RealtimeError::Url(err) => JsonCliError::new("invalid_realtime_url", err.to_string()),
        RealtimeError::Protocol(err) => JsonCliError::new("protocol_decode_error", err.to_string()),
        RealtimeError::MissingResult => JsonCliError::new("missing_rpc_result", error.to_string()),
    }
}

fn realtime_connection_error_hint(reason_name: &str) -> &'static str {
    match reason_name {
        "UNAUTHORIZED" | "INVALID_AUTH" | "SESSION_REVOKED" => {
            "The realtime server rejected the current token. Run `inline auth login` again or pass a fresh token with INLINE_TOKEN."
        }
        _ => {
            "The realtime server rejected the connection. Check INLINE_REALTIME_URL and authentication."
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug)]
    struct SourceWrapper<E: std::error::Error + 'static> {
        source: E,
    }

    impl<E: std::error::Error + 'static> std::fmt::Display for SourceWrapper<E> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(f, "wrapped error")
        }
    }

    impl<E: std::error::Error + 'static> std::error::Error for SourceWrapper<E> {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            Some(&self.source)
        }
    }

    #[test]
    fn destructive_confirmation_errors_are_structured() {
        let err = CliError::confirmation_required();
        assert_eq!(err.code, "confirmation_required");
        assert!(err.message.contains("--yes"));
        assert!(err.message.contains("-y"));
        assert!(err.hint.as_deref().unwrap_or("").contains("--yes"));
        assert!(err.hint.as_deref().unwrap_or("").contains("-y"));
        assert!(!err.examples.is_empty());
    }

    #[test]
    fn api_errors_map_to_agent_json_fields() {
        let err = ApiError::Api {
            status: Some(400),
            error: "INVALID_CODE".to_string(),
            error_code: Some(123),
            description: "Code is invalid".to_string(),
        };

        let payload = json_cli_error_from_error(&err);
        assert_eq!(payload.code, "api_error");
        assert_eq!(payload.message, "Code is invalid");
        assert_eq!(payload.status, Some(400));
        assert_eq!(payload.api_error.as_deref(), Some("INVALID_CODE"));
        assert_eq!(payload.api_error_code, Some(123));
    }

    #[test]
    fn api_http_errors_reuse_network_error_mapping() {
        let http_error = reqwest::Client::new().get("http://").build().unwrap_err();
        let err = ApiError::Http(http_error);
        let payload = json_cli_error_from_error(&err);

        assert_eq!(payload.code, "network_error");
        assert!(
            payload
                .hint
                .as_deref()
                .unwrap_or_default()
                .contains("INLINE_API_BASE_URL")
        );
    }

    #[test]
    fn api_io_errors_reuse_io_error_mapping() {
        let err = ApiError::Io(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "upload unreadable",
        ));
        let payload = json_cli_error_from_error(&err);

        assert_eq!(payload.code, "io_error");
        assert!(payload.message.contains("upload unreadable"));
        assert!(
            payload
                .hint
                .as_deref()
                .unwrap_or_default()
                .contains("directory permissions")
        );
    }

    #[test]
    fn auth_missing_token_errors_are_structured() {
        let err = CliError::not_authenticated();
        assert_eq!(err.code, "not_authenticated");
        assert!(err.hint.as_deref().unwrap_or("").contains("INLINE_TOKEN"));
        assert!(!err.examples.is_empty());
    }

    #[test]
    fn human_errors_include_code_hint_and_examples() {
        let err = CliError::not_authenticated();
        let payload = json_cli_error_from_error(&err);
        let text = format_human_cli_error(&payload, "Error");

        assert!(text.starts_with("Error: No token found."));
        assert!(text.contains("\nCode: not_authenticated\n"));
        assert!(text.contains("\nHint: Agents and CI can pass a token"));
        assert!(text.contains("\nExamples:\n  inline auth login"));
    }

    #[test]
    fn invalid_args_errors_map_to_agent_json_fields() {
        let err = CliError::invalid_args("Provide --public or --private");
        let payload = json_cli_error_from_error(&err);
        assert_eq!(payload.code, "invalid_args");
        assert_eq!(payload.message, "Provide --public or --private");
        assert!(payload.hint.as_deref().unwrap_or("").contains("--help"));
    }

    #[test]
    fn stdin_not_piped_errors_are_structured() {
        let err = CliError::stdin_not_piped();
        assert_eq!(err.code, "stdin_not_piped");
        assert!(err.hint.as_deref().unwrap_or("").contains("Pipe"));
        assert!(!err.examples.is_empty());

        let payload = json_cli_error_from_error(&err);
        assert_eq!(payload.code, "stdin_not_piped");
        assert!(payload.message.contains("terminal"));
        assert!(payload.hint.as_deref().unwrap_or("").contains("--text"));
    }

    #[test]
    fn http_status_errors_map_to_agent_json_fields() {
        let err = HttpStatusCliError::download_failed(403, Some("forbidden".to_string()));
        let payload = json_cli_error_from_error(&err);

        assert_eq!(payload.code, "download_http_status");
        assert_eq!(payload.message, "Download failed with HTTP 403");
        assert_eq!(payload.status, Some(403));
        assert_eq!(payload.body.as_deref(), Some("forbidden"));
        assert!(payload.hint.as_deref().unwrap_or("").contains("attachment"));
    }

    #[test]
    fn human_errors_include_status_api_error_and_response_body() {
        let err = ApiError::Api {
            status: Some(400),
            error: "USERNAME_INVALID".to_string(),
            error_code: Some(5),
            description: "Username is invalid".to_string(),
        };
        let payload = json_cli_error_from_error(&err);
        let text = format_human_cli_error(&payload, "Error");

        assert!(text.contains("Error: Username is invalid"));
        assert!(text.contains("Code: api_error"));
        assert!(text.contains("Status: 400"));
        assert!(text.contains("API error: USERNAME_INVALID (5)"));

        let download_err = HttpStatusCliError::download_failed(403, Some("forbidden".to_string()));
        let payload = json_cli_error_from_error(&download_err);
        let text = format_human_cli_error(&payload, "Error");

        assert!(text.contains("Code: download_http_status"));
        assert!(text.contains("Status: 403"));
        assert!(text.contains("Response: forbidden"));
    }

    #[test]
    fn direct_reqwest_errors_map_to_agent_json_fields() {
        let err = reqwest::Client::new().get("http://").build().unwrap_err();
        let payload = json_cli_error_from_error(&err);

        assert_eq!(payload.code, "network_error");
        assert!(
            payload
                .hint
                .as_deref()
                .unwrap_or_default()
                .contains("network connectivity")
        );
    }

    #[test]
    fn direct_io_errors_map_to_agent_json_fields() {
        let err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "no access");
        let payload = json_cli_error_from_error(&err);

        assert_eq!(payload.code, "io_error");
        assert!(payload.message.contains("no access"));
        assert!(
            payload
                .hint
                .as_deref()
                .unwrap_or_default()
                .contains("file paths")
        );
    }

    #[test]
    fn direct_json_errors_map_to_agent_json_fields() {
        let err = serde_json::from_str::<serde_json::Value>("{").unwrap_err();
        let payload = json_cli_error_from_error(&err);

        assert_eq!(payload.code, "json_error");
        assert!(
            payload
                .hint
                .as_deref()
                .unwrap_or_default()
                .contains("encode or decode JSON")
        );
    }

    #[test]
    fn source_io_errors_map_to_agent_json_fields() {
        let err = SourceWrapper {
            source: std::io::Error::new(std::io::ErrorKind::PermissionDenied, "wrapped no access"),
        };
        let payload = json_cli_error_from_error(&err);

        assert_eq!(payload.code, "io_error");
        assert!(payload.message.contains("wrapped no access"));
    }

    #[test]
    fn unexpected_rpc_result_errors_are_structured() {
        let err = CliError::unexpected_rpc_result("getChats");
        assert_eq!(err.code, "unexpected_rpc_result");
        assert!(err.message.contains("getChats"));
        assert!(
            err.hint
                .as_deref()
                .unwrap_or("")
                .contains("protocol versions")
        );
        assert!(!err.examples.is_empty());

        let payload = json_cli_error_from_error(&err);
        assert_eq!(payload.code, "unexpected_rpc_result");
        assert!(payload.message.contains("getChats"));
    }

    #[test]
    fn unexpected_api_response_errors_are_structured() {
        let err = CliError::unexpected_api_response("uploadFile", "missing media id");
        assert_eq!(err.code, "unexpected_api_response");
        assert!(err.message.contains("uploadFile"));
        assert!(
            err.hint
                .as_deref()
                .unwrap_or("")
                .contains("missing required data")
        );
        assert!(!err.examples.is_empty());

        let payload = json_cli_error_from_error(&err);
        assert_eq!(payload.code, "unexpected_api_response");
        assert!(payload.message.contains("missing media id"));
        assert!(payload.hint.as_deref().unwrap_or("").contains("server"));
    }

    #[test]
    fn realtime_connection_errors_map_reason_to_agent_json_fields() {
        let err = RealtimeError::ConnectionError {
            reason: 2,
            reason_name: "INVALID_AUTH".to_string(),
            friendly: "Realtime auth token is invalid".to_string(),
        };

        let payload = json_cli_error_from_error(&err);
        assert_eq!(payload.code, "realtime_connection_error");
        assert_eq!(payload.message, "Realtime auth token is invalid");
        assert_eq!(payload.api_error.as_deref(), Some("INVALID_AUTH"));
        assert_eq!(payload.api_error_code, Some(2));
        assert!(
            payload
                .hint
                .as_deref()
                .unwrap_or("")
                .contains("INLINE_TOKEN")
        );
    }

    #[test]
    fn realtime_rpc_errors_map_proto_code_name_to_agent_json_fields() {
        let err = RealtimeError::RpcError {
            code: 400,
            error_code: 5,
            error_name: "PEER_ID_INVALID".to_string(),
            message: "chat id is invalid".to_string(),
            friendly: "Invalid peer (chat/user id): chat id is invalid (HTTP 400)".to_string(),
        };

        let payload = json_cli_error_from_error(&err);
        assert_eq!(payload.code, "rpc_error");
        assert_eq!(payload.status, Some(400));
        assert_eq!(payload.api_error.as_deref(), Some("PEER_ID_INVALID"));
        assert_eq!(payload.api_error_code, Some(5));
        assert_eq!(payload.body.as_deref(), Some("chat id is invalid"));
    }

    #[test]
    fn realtime_connection_closed_has_distinct_agent_code() {
        let payload = json_cli_error_from_error(&RealtimeError::ConnectionClosed);
        assert_eq!(payload.code, "realtime_connection_closed");
        assert_eq!(payload.message, "realtime connection closed");
    }
}

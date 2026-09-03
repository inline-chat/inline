use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PRIVATE_SENTINEL: &str = "private-telemetry-fixture";
const FAILURE_ARGS: &[&str] = &["--json", "--compact", "search", "--query", PRIVATE_SENTINEL];

fn command(args: &[&str], dsn: &str, telemetry: &str) -> (Command, PathBuf) {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "inline-telemetry-{}-{nonce}-{PRIVATE_SENTINEL}",
        std::process::id()
    ));
    let mut command = Command::new(env!("CARGO_BIN_EXE_inline"));
    command
        .args(args)
        .env("INLINE_CLI_TELEMETRY", telemetry)
        .env("INLINE_CLI_SENTRY_DSN", dsn)
        .env("INLINE_DATA_DIR", &root)
        .env("INLINE_SECRETS_PATH", root.join("secrets.json"))
        .env("INLINE_STATE_PATH", root.join("state.json"))
        .env("INLINE_API_BASE_URL", "http://127.0.0.1:9/v1")
        .env("INLINE_REALTIME_URL", "ws://127.0.0.1:9/realtime")
        .env_remove("INLINE_TOKEN")
        .env("SENTRY_ENVIRONMENT", PRIVATE_SENTINEL)
        .env("SENTRY_RELEASE", PRIVATE_SENTINEL)
        .env_remove("HTTP_PROXY")
        .env_remove("http_proxy")
        .env_remove("HTTPS_PROXY")
        .env_remove("https_proxy")
        .env_remove("ALL_PROXY")
        .env_remove("all_proxy")
        .env("NO_PROXY", "127.0.0.1")
        // Completions can exceed a pipe buffer; only stderr is relevant here.
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    (command, root)
}

fn run_bounded(mut command: Command) -> Output {
    let mut child = command.spawn().unwrap();
    let started = Instant::now();
    let completed = loop {
        if child.try_wait().unwrap().is_some() {
            break true;
        }
        if started.elapsed() > Duration::from_secs(4) {
            child.kill().unwrap();
            break false;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let output = child.wait_with_output().unwrap();
    assert!(
        completed,
        "telemetry held the command open beyond its deadline"
    );
    output
}

fn error_code(output: &Output) -> String {
    assert!(!output.status.success());
    let payload: Value = serde_json::from_slice(&output.stderr).unwrap();
    payload["error"]["code"].as_str().unwrap().to_owned()
}

#[test]
fn sentry_http_envelope_contains_allowlisted_scrubbed_failure_text() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let dsn = format!("http://fixture@{}/1", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let started = Instant::now();
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        started.elapsed() < Duration::from_secs(5),
                        "no Sentry request"
                    );
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept Sentry request: {error}"),
            }
        };
        // Darwin can inherit the listener's nonblocking mode on accept.
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut reader = BufReader::new(&mut stream);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert_eq!(line, "POST /api/1/envelope/ HTTP/1.1\r\n");
        let mut length = None;
        let mut header_bytes = line.len();
        loop {
            line.clear();
            assert!(reader.read_line(&mut line).unwrap() > 0);
            header_bytes += line.len();
            assert!(header_bytes < 16 * 1024);
            if line == "\r\n" {
                break;
            }
            assert!(!line.contains(PRIVATE_SENTINEL));
            if let Some((name, value)) = line.split_once(':')
                && name.eq_ignore_ascii_case("content-length")
            {
                length = Some(value.trim().parse::<usize>().unwrap());
            }
        }
        let length = length.expect("known-size Sentry envelope");
        assert!(length < 16 * 1024);
        let mut body = vec![0; length];
        reader.read_exact(&mut body).unwrap();
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
            .unwrap();
        body
    });

    let (mut command, root) = command(FAILURE_ARGS, &dsn, "on");
    command.env("INLINE_TOKEN", PRIVATE_SENTINEL);
    let output = run_bounded(command);
    let body = server.join().unwrap();
    assert_eq!(error_code(&output), "missing_peer");
    assert!(
        !root.exists(),
        "argument validation must precede auth storage"
    );
    let body = String::from_utf8(body).unwrap();
    assert!(!body.contains(PRIVATE_SENTINEL));
    let parts: Vec<Value> = body
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(parts.len(), 3, "only one event, no sessions or attachments");
    assert_eq!(parts[0].as_object().unwrap().len(), 1);
    assert!(parts[0]["event_id"].is_string());
    assert_eq!(parts[1]["type"], "event");
    let event = &parts[2];
    let allowed = [
        "event_id",
        "fingerprint",
        "message",
        "timestamp",
        "release",
        "tags",
        "extra",
    ];
    assert!(
        event
            .as_object()
            .unwrap()
            .keys()
            .all(|key| allowed.contains(&key.as_str()))
    );
    assert_eq!(event["message"], "Inline CLI command failed");
    assert_eq!(
        event["release"],
        format!("inline-cli@{}", env!("CARGO_PKG_VERSION"))
    );
    assert_eq!(
        event["fingerprint"],
        serde_json::json!(["inline-cli", "missing_peer", "", ""])
    );
    assert_eq!(
        event["tags"],
        serde_json::json!({
            "error_code": "missing_peer", "os": std::env::consts::OS, "arch": std::env::consts::ARCH
        })
    );
    assert_eq!(
        event["extra"]["failure_text"],
        "Missing required argument: provide --chat-id or --user-id Hint: Use `inline chats list` to find chat IDs, or `inline users list` for DM user IDs."
    );
}

#[test]
fn telemetry_opt_out_and_empty_dsn_make_no_connection() {
    for setting in ["off", " OFF ", "0", "False", "empty-dsn"] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let dsn = format!("http://fixture@{}/1", listener.local_addr().unwrap());
        let (dsn, telemetry) = if setting == "empty-dsn" {
            ("", "on")
        } else {
            (dsn.as_str(), setting)
        };
        let (command, root) = command(FAILURE_ARGS, dsn, telemetry);
        assert_eq!(error_code(&run_bounded(command)), "missing_peer");
        assert!(!root.exists());
        // Any attempted TCP connection remains in this listener's backlog,
        // even after the child exits, so no asynchronous observer is needed.
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock,
            "{setting}"
        );
    }
}

#[test]
fn offline_commands_and_excluded_errors_make_no_connection() {
    let cases: &[(&[&str], Option<&str>)] = &[
        (&["--help"], None),
        (&["--version"], None),
        (&["completion", "bash"], None),
        (&["capabilities", "messages", "send", "--compact"], None),
        (&["schema", "commands", "auth", "login", "--compact"], None),
        (&["plugin", "install", "--dry-run", "--json"], None),
        (
            &["--json", "--compact", "definitely-not-a-command"],
            Some("invalid_args"),
        ),
        (
            &["--json", "--compact", "auth", "me"],
            Some("not_authenticated"),
        ),
    ];
    for (args, expected_error) in cases {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let dsn = format!("http://fixture@{}/1", listener.local_addr().unwrap());
        let (command, root) = command(args, &dsn, "on");
        let output = run_bounded(command);
        if let Some(expected_error) = expected_error {
            assert_eq!(error_code(&output), *expected_error);
        } else {
            assert!(output.status.success());
            assert!(output.stderr.is_empty());
        }
        assert!(!root.exists());
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock,
            "{args:?}"
        );
    }
}

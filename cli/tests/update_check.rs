use std::io::{Read, Write};
use std::net::TcpListener;
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

fn manifest(version: &str) -> String {
    let mut targets = serde_json::Map::new();
    for target in [
        "aarch64-apple-darwin",
        "x86_64-apple-darwin",
        "aarch64-unknown-linux-gnu",
        "x86_64-unknown-linux-gnu",
        "aarch64-unknown-linux-musl",
        "x86_64-unknown-linux-musl",
    ] {
        targets.insert(
            target.to_string(),
            json!({
                "url": "http://127.0.0.1:9/must-not-download",
                "sha256": "0".repeat(64),
                "size": 123
            }),
        );
    }
    json!({"version": version, "targets": targets}).to_string()
}

fn run_check(args: &[&str], body: String) -> Output {
    let root = tempfile::tempdir().unwrap();
    let secrets = root.path().join("credentials");
    std::fs::write(&secrets, b"invalid credential data must not be read").unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("http://{}/manifest.json", listener.local_addr().unwrap());
    let server = thread::spawn(move || {
        let start = Instant::now();
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        start.elapsed() < Duration::from_secs(10),
                        "no manifest request"
                    );
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("accept: {error}"),
            }
        };
        // Darwin can inherit the listener's nonblocking mode on accepted sockets.
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
            assert!(request.len() < 16 * 1024);
        }
        assert!(request.starts_with(b"GET /manifest.json HTTP/1.1\r\n"));
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
    });
    let output = Command::new(env!("CARGO_BIN_EXE_inline"))
        .args(args)
        .env_remove("INLINE_TOKEN")
        .env("INLINE_CLI_TELEMETRY", "off")
        .env("INLINE_RELEASE_MANIFEST_URL", url)
        .env("INLINE_DATA_DIR", root.path().join("data"))
        .env("INLINE_SECRETS_PATH", &secrets)
        .env("INLINE_STATE_PATH", root.path().join("state"))
        .env("INLINE_API_BASE_URL", "not an API URL")
        .env("INLINE_REALTIME_URL", "not a realtime URL")
        .output()
        .unwrap();
    server.join().unwrap();
    assert_eq!(
        std::fs::read(&secrets).unwrap(),
        b"invalid credential data must not be read"
    );
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 1);
    output
}

#[test]
fn check_and_upgrade_alias_return_json_without_auth_download_or_state_writes() {
    let output = run_check(
        &["upgrade", "--check", "--json", "--compact"],
        manifest("999.0.0"),
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty());
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.lines().count(), 1);
    let payload: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(payload["current_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(payload["latest_version"], "999.0.0");
    assert_eq!(payload["update_available"], payload["supported"]);
    assert!(payload["target"].is_string());
}

#[test]
fn check_keeps_pretty_json_and_reports_up_to_date_without_installing() {
    let output = run_check(
        &["update", "--check", "--json"],
        manifest(env!("CARGO_PKG_VERSION")),
    );
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.lines().count() > 1);
    let payload: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(payload["update_available"], false);

    let output = run_check(&["update", "--check"], manifest("999.0.0"));
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.contains("999.0.0"));
    assert!(!text.contains("Updated inline"));
}

#[test]
fn invalid_manifest_keeps_the_existing_json_error_envelope() {
    let output = run_check(
        &["update", "--check", "--json", "--compact"],
        "not JSON".into(),
    );
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let error: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert!(error["error"]["code"].is_string());
    assert!(error["error"]["message"].is_string());
}

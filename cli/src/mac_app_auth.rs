#[cfg(any(target_os = "macos", test))]
use rand::{RngCore, rngs::OsRng};
#[cfg(any(target_os = "macos", test))]
use serde::{Deserialize, Serialize};
use std::io;

#[cfg(target_os = "macos")]
use std::io::Write;

#[cfg(target_os = "macos")]
use std::net::Ipv4Addr;
#[cfg(target_os = "macos")]
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::Command;
#[cfg(target_os = "macos")]
use std::time::Duration;
#[cfg(target_os = "macos")]
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
#[cfg(target_os = "macos")]
use tokio::net::{TcpListener, TcpStream};

#[cfg(any(target_os = "macos", test))]
const PROTOCOL_VERSION: u32 = 1;
#[cfg(target_os = "macos")]
const BUNDLE_ID: &str = "chat.inline.InlineMac";
#[cfg(target_os = "macos")]
const MAX_MESSAGE_BYTES: usize = 8 * 1024;
#[cfg(target_os = "macos")]
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(3);
#[cfg(target_os = "macos")]
const LOGIN_TIMEOUT: Duration = Duration::from_secs(120);
#[cfg(target_os = "macos")]
const MAX_CONNECTIONS: usize = 8;

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) enum LoginOutcome {
    Token { token: String, user_id: i64 },
    Cancelled(Option<String>),
}

#[cfg(any(target_os = "macos", test))]
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    version: u32,
    action: Action,
    capability: String,
    token: Option<String>,
    #[serde(alias = "userID")]
    user_id: Option<i64>,
    detail: Option<String>,
}

#[cfg(any(target_os = "macos", test))]
#[derive(Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Action {
    Probe,
    Complete,
    Cancel,
}

#[cfg(target_os = "macos")]
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response<'a> {
    version: u32,
    status: &'a str,
    device_id: Option<&'a str>,
    // Protocol v1 shipped with Swift's synthesized acronym spelling. Emit both
    // keys so released app builds and corrected clients can share this version.
    #[serde(rename = "deviceID")]
    legacy_device_id: Option<&'a str>,
    device_name: Option<&'a str>,
    client_version: Option<&'a str>,
    os_version: Option<&'a str>,
    verification_code: Option<&'a str>,
    detail: Option<&'a str>,
}

#[cfg(target_os = "macos")]
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BootstrapReady<'a> {
    version: u32,
    status: &'a str,
    callback_url: &'a str,
}

pub(crate) fn supporting_app_available() -> bool {
    #[cfg(target_os = "macos")]
    {
        find_supporting_app().is_some()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

pub(crate) async fn login(
    device_id: &str,
    device_name: Option<&str>,
    client_version: &str,
    os_version: Option<&str>,
) -> Result<LoginOutcome, Box<dyn std::error::Error>> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (device_id, device_name, client_version, os_version);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Inline for Mac login is unavailable",
        )
        .into())
    }

    #[cfg(target_os = "macos")]
    {
        let app = find_supporting_app().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "a compatible Inline for Mac installation was not found",
            )
        })?;
        let pending = PendingLogin::bind().await?;
        println!(
            "Inline for Mac verification code: {}",
            pending.verification_code
        );

        let status = Command::new("/usr/bin/open")
            .arg("-a")
            .arg(&app)
            .arg(&pending.callback_url)
            .status()?;
        if !status.success() {
            return Err(io::Error::other("could not open Inline for Mac").into());
        }

        pending
            .wait(device_id, device_name, client_version, os_version)
            .await
    }
}

/// Starts the same capability-authenticated loopback handoff without opening
/// or prompting in the CLI. The parent macOS app receives the callback URL on
/// its private stdout pipe and explicitly authorizes the request.
pub(crate) async fn login_from_parent_app(
    device_id: &str,
    device_name: Option<&str>,
    client_version: &str,
    os_version: Option<&str>,
) -> Result<LoginOutcome, Box<dyn std::error::Error>> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (device_id, device_name, client_version, os_version);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Inline for Mac bootstrap is unavailable",
        )
        .into())
    }

    #[cfg(target_os = "macos")]
    {
        let pending = PendingLogin::bind().await?;
        let ready = BootstrapReady {
            version: PROTOCOL_VERSION,
            status: "ready",
            callback_url: &pending.callback_url,
        };
        let mut stdout = io::stdout().lock();
        serde_json::to_writer(&mut stdout, &ready)?;
        stdout.write_all(b"\n")?;
        stdout.flush()?;
        drop(stdout);

        pending
            .wait(device_id, device_name, client_version, os_version)
            .await
    }
}

#[cfg(target_os = "macos")]
struct PendingLogin {
    listener: TcpListener,
    capability: String,
    verification_code: String,
    callback_url: String,
}

#[cfg(target_os = "macos")]
impl PendingLogin {
    async fn bind() -> Result<Self, Box<dyn std::error::Error>> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let address = listener.local_addr()?;
        if !address.ip().is_loopback() {
            return Err(io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                "CLI login listener did not bind to loopback",
            )
            .into());
        }

        let capability = random_hex(32);
        let verification_code = random_verification_code();
        let callback_url = login_url(address.port(), &capability)?;
        Ok(Self {
            listener,
            capability,
            verification_code,
            callback_url,
        })
    }

    async fn wait(
        self,
        device_id: &str,
        device_name: Option<&str>,
        client_version: &str,
        os_version: Option<&str>,
    ) -> Result<LoginOutcome, Box<dyn std::error::Error>> {
        let client = ClientMetadata {
            device_id,
            device_name,
            client_version,
            os_version,
            verification_code: &self.verification_code,
        };
        tokio::time::timeout(
            LOGIN_TIMEOUT,
            serve_login(self.listener, &self.capability, client),
        )
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "Inline for Mac approval timed out"))?
    }
}

#[cfg(target_os = "macos")]
struct ClientMetadata<'a> {
    device_id: &'a str,
    device_name: Option<&'a str>,
    client_version: &'a str,
    os_version: Option<&'a str>,
    verification_code: &'a str,
}

#[cfg(target_os = "macos")]
async fn serve_login(
    listener: TcpListener,
    capability: &str,
    client: ClientMetadata<'_>,
) -> Result<LoginOutcome, Box<dyn std::error::Error>> {
    let mut probed = false;
    for _ in 0..MAX_CONNECTIONS {
        let (stream, peer) = listener.accept().await?;
        if !peer.ip().is_loopback() {
            continue;
        }
        let received = match read_request(stream).await {
            Ok(request) => request,
            Err(_) => continue,
        };
        let ReceivedRequest { request, stream } = received;
        if request.version != PROTOCOL_VERSION || !constant_time_eq(&request.capability, capability)
        {
            continue;
        }

        match request.action {
            Action::Probe => {
                probed = true;
                write_response(
                    stream,
                    Response {
                        version: PROTOCOL_VERSION,
                        status: "available",
                        device_id: Some(client.device_id),
                        legacy_device_id: Some(client.device_id),
                        device_name: client.device_name,
                        client_version: Some(client.client_version),
                        os_version: client.os_version,
                        verification_code: Some(client.verification_code),
                        detail: None,
                    },
                )
                .await?;
            }
            Action::Complete if probed => {
                let token = request
                    .token
                    .filter(|value| !value.trim().is_empty() && value.len() <= 4 * 1024);
                let Some(token) = token else { continue };
                let Some(user_id) = request.user_id.filter(|value| *value > 0) else {
                    continue;
                };
                write_response(stream, terminal_response("accepted", None)).await?;
                return Ok(LoginOutcome::Token { token, user_id });
            }
            Action::Cancel => {
                let detail = request.detail.map(|value| safe_detail(&value));
                write_response(stream, terminal_response("accepted", None)).await?;
                return Ok(LoginOutcome::Cancelled(detail));
            }
            Action::Complete => continue,
        }
    }
    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        "too many invalid local login requests",
    )
    .into())
}

#[cfg(target_os = "macos")]
struct ReceivedRequest {
    request: Request,
    stream: TcpStream,
}

#[cfg(target_os = "macos")]
async fn read_request(stream: TcpStream) -> Result<ReceivedRequest, Box<dyn std::error::Error>> {
    let mut bytes = Vec::with_capacity(1024);
    let mut reader = BufReader::new(stream);
    let mut limited = (&mut reader).take((MAX_MESSAGE_BYTES + 1) as u64);
    let count = tokio::time::timeout(CONNECTION_TIMEOUT, limited.read_until(b'\n', &mut bytes))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "local login request timed out"))??;
    drop(limited);
    if count == 0 || bytes.len() > MAX_MESSAGE_BYTES {
        return Err(
            io::Error::new(io::ErrorKind::InvalidData, "invalid local login request").into(),
        );
    }
    let request = serde_json::from_slice(&bytes)?;
    Ok(ReceivedRequest {
        request,
        stream: reader.into_inner(),
    })
}

#[cfg(target_os = "macos")]
async fn write_response(
    mut stream: TcpStream,
    response: Response<'_>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut bytes = serde_json::to_vec(&response)?;
    if bytes.len() >= MAX_MESSAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "local login response is too large",
        )
        .into());
    }
    bytes.push(b'\n');
    tokio::time::timeout(CONNECTION_TIMEOUT, stream.write_all(&bytes))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "local login response timed out"))??;
    Ok(())
}

#[cfg(target_os = "macos")]
fn terminal_response<'a>(status: &'a str, detail: Option<&'a str>) -> Response<'a> {
    Response {
        version: PROTOCOL_VERSION,
        status,
        device_id: None,
        legacy_device_id: None,
        device_name: None,
        client_version: None,
        os_version: None,
        verification_code: None,
        detail,
    }
}

#[cfg(target_os = "macos")]
fn find_supporting_app() -> Option<PathBuf> {
    let output = Command::new("/usr/bin/mdfind")
        .arg(format!("kMDItemCFBundleIdentifier == '{BUNDLE_ID}'"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let user_applications = std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|path| path.join("Applications"));
    let mut candidates: Vec<_> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(PathBuf::from)
        .filter(|path| {
            path.starts_with("/Applications")
                || user_applications
                    .as_ref()
                    .is_some_and(|applications| path.starts_with(applications))
        })
        .collect();
    candidates.sort_by_key(|path| !path.starts_with("/Applications"));
    candidates
        .into_iter()
        .find(|path| supports_protocol(path, PROTOCOL_VERSION))
}

#[cfg(target_os = "macos")]
fn supports_protocol(app: &Path, required_version: u32) -> bool {
    if app.extension().and_then(|value| value.to_str()) != Some("app") || !app.is_dir() {
        return false;
    }
    let plist = app.join("Contents/Info.plist");
    let output = match Command::new("/usr/bin/plutil")
        .args(["-extract", "InlineCLIAuthProtocolVersion", "raw", "-o", "-"])
        .arg(plist)
        .output()
    {
        Ok(output) if output.status.success() => output,
        _ => return false,
    };
    parse_protocol_version(&output.stdout).is_some_and(|version| version >= required_version)
}

#[cfg(any(target_os = "macos", test))]
fn parse_protocol_version(bytes: &[u8]) -> Option<u32> {
    std::str::from_utf8(bytes).ok()?.trim().parse().ok()
}

#[cfg(target_os = "macos")]
fn login_url(port: u16, capability: &str) -> Result<String, url::ParseError> {
    let mut url = url::Url::parse("inline://cli-auth")?;
    url.query_pairs_mut()
        .append_pair("version", &PROTOCOL_VERSION.to_string())
        .append_pair("port", &port.to_string())
        .append_pair("capability", capability);
    Ok(url.into())
}

#[cfg(target_os = "macos")]
fn random_verification_code() -> String {
    format!("{:06}", OsRng.next_u32() % 1_000_000)
}

#[cfg(any(target_os = "macos", test))]
fn random_hex(byte_count: usize) -> String {
    let mut bytes = vec![0_u8; byte_count];
    OsRng.fill_bytes(&mut bytes);
    let mut output = String::with_capacity(byte_count * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(target_os = "macos")]
fn constant_time_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.as_bytes()
        .iter()
        .zip(right.as_bytes())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

#[cfg(target_os = "macos")]
fn safe_detail(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .take(200)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_capability_version() {
        assert_eq!(parse_protocol_version(b"1\n"), Some(1));
        assert_eq!(parse_protocol_version(b"not-a-version"), None);
    }

    #[test]
    fn random_capability_is_opaque_and_unique() {
        let first = random_hex(32);
        let second = random_hex(32);
        assert_eq!(first.len(), 64);
        assert!(first.chars().all(|character| character.is_ascii_hexdigit()));
        assert_ne!(first, second);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn bootstrap_ready_output_is_compact_and_token_free() {
        let output = serde_json::to_string(&BootstrapReady {
            version: PROTOCOL_VERSION,
            status: "ready",
            callback_url: "inline://cli-auth?version=1&port=1234&capability=opaque",
        })
        .unwrap();
        assert_eq!(
            output,
            r#"{"version":1,"status":"ready","callbackUrl":"inline://cli-auth?version=1&port=1234&capability=opaque"}"#
        );
        assert!(!output.contains("token"));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn loopback_handoff_requires_probe_and_returns_token() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let capability = random_hex(32);
        let server_capability = capability.clone();
        let task = tokio::spawn(async move {
            serve_login(
                listener,
                &server_capability,
                ClientMetadata {
                    device_id: "cli_0123456789abcdef0123456789abcdef",
                    device_name: Some("Test Mac"),
                    client_version: "0.6.2",
                    os_version: Some("15.5"),
                    verification_code: "123456",
                },
            )
            .await
            .unwrap()
        });

        let probe = send_test_request(
            port,
            Request {
                version: PROTOCOL_VERSION,
                action: Action::Probe,
                capability: capability.clone(),
                token: None,
                user_id: None,
                detail: None,
            },
        )
        .await;
        assert_eq!(probe["status"], "available");
        assert_eq!(probe["deviceId"], "cli_0123456789abcdef0123456789abcdef");
        assert_eq!(probe["deviceID"], probe["deviceId"]);
        assert_eq!(probe["verificationCode"], "123456");

        let complete = send_test_request(
            port,
            Request {
                version: PROTOCOL_VERSION,
                action: Action::Complete,
                capability,
                token: Some("secret-token".to_string()),
                user_id: Some(42),
                detail: None,
            },
        )
        .await;
        assert_eq!(complete["status"], "accepted");
        match task.await.unwrap() {
            LoginOutcome::Token { token, user_id } => {
                assert_eq!(token, "secret-token");
                assert_eq!(user_id, 42);
            }
            LoginOutcome::Cancelled(_) => panic!("expected token"),
        }
    }

    #[test]
    fn accepts_legacy_swift_user_id_key() {
        let request: Request = serde_json::from_value(serde_json::json!({
            "version": PROTOCOL_VERSION,
            "action": "complete",
            "capability": "opaque-capability",
            "token": "secret-token",
            "userID": 42,
            "detail": null
        }))
        .unwrap();

        assert_eq!(request.user_id, Some(42));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn loopback_handoff_can_cancel_before_probe() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let capability = random_hex(32);
        let server_capability = capability.clone();
        let task = tokio::spawn(async move {
            serve_login(
                listener,
                &server_capability,
                ClientMetadata {
                    device_id: "cli_0123456789abcdef0123456789abcdef",
                    device_name: None,
                    client_version: "0.6.2",
                    os_version: None,
                    verification_code: "123456",
                },
            )
            .await
            .unwrap()
        });

        let response = send_test_request(
            port,
            Request {
                version: PROTOCOL_VERSION,
                action: Action::Cancel,
                capability,
                token: None,
                user_id: None,
                detail: Some("Inline for Mac is not signed in.".to_string()),
            },
        )
        .await;
        assert_eq!(response["status"], "accepted");
        match task.await.unwrap() {
            LoginOutcome::Cancelled(detail) => {
                assert_eq!(detail.as_deref(), Some("Inline for Mac is not signed in."));
            }
            LoginOutcome::Token { .. } => panic!("expected cancellation"),
        }
    }

    #[cfg(target_os = "macos")]
    async fn send_test_request(port: u16, request: Request) -> serde_json::Value {
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        let mut bytes = serde_json::to_vec(&request).unwrap();
        bytes.push(b'\n');
        stream.write_all(&bytes).await.unwrap();
        let mut reader = BufReader::new(stream);
        let mut response = Vec::new();
        reader.read_until(b'\n', &mut response).await.unwrap();
        serde_json::from_slice(&response).unwrap()
    }
}

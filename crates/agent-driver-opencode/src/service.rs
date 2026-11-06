//! The shared OpenCode background service.
//!
//! OpenCode v2 runs one service per user that every client shares: the TUI,
//! desktop, web and this bridge. It registers itself at
//! `$XDG_STATE_HOME/opencode/service.json` (default `~/.local/state`) with its
//! URL, pid, version and an optional private password (HTTP basic auth, user
//! `opencode`). The bridge reuses a healthy registered service and otherwise
//! asks the configured executable to start one (`opencode service start`),
//! exactly as OpenCode's own clients do. It never stops or replaces a service
//! it did not start: other clients may be using it.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use base64::Engine;
use serde::Deserialize;
use tokio::process::Command;

/// How long `/api/info` may take before a registration counts as unresponsive.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// How long `opencode service start` may take (OpenCode's own clients wait 120 s).
pub const DEFAULT_START_TIMEOUT: Duration = Duration::from_secs(120);

/// Where to reach a service.
#[derive(Clone, PartialEq, Eq)]
pub struct Endpoint {
    /// Base URL, for example `http://127.0.0.1:4096/`.
    pub url: url::Url,
    /// Private service password, when the service requires authentication.
    pub password: Option<String>,
}

impl std::fmt::Debug for Endpoint {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Endpoint")
            .field("url", &self.url.as_str())
            .field("password", &self.password.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

impl Endpoint {
    /// An endpoint without authentication (tests, explicit `--server` URLs).
    pub fn open(url: url::Url) -> Self {
        Self {
            url,
            password: None,
        }
    }

    /// The `authorization` header value, when the service needs one.
    pub fn authorization(&self) -> Option<String> {
        self.password.as_ref().map(|password| {
            format!(
                "Basic {}",
                base64::engine::general_purpose::STANDARD.encode(format!("opencode:{password}"))
            )
        })
    }

    /// Resolves an API path (`api/session`) against the base URL.
    pub fn join(&self, path: &str) -> url::Url {
        let mut base = self.url.clone();
        if !base.path().ends_with('/') {
            let path = format!("{}/", base.path());
            base.set_path(&path);
        }
        base.join(path.trim_start_matches('/'))
            .unwrap_or_else(|_| base.clone())
    }
}

/// What a registered service reports about itself.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct ServerInfo {
    /// OpenCode version the service runs.
    pub version: String,
    /// Service process id.
    pub pid: u32,
}

#[derive(Debug, Deserialize)]
struct Registration {
    url: String,
    pid: u32,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    password: Option<String>,
}

/// How to find and start the service.
#[derive(Clone, Debug)]
pub struct ServiceConfig {
    /// The `opencode` executable chosen at setup.
    pub executable: PathBuf,
    /// Registration file; `None` uses OpenCode's default location.
    pub registration: Option<PathBuf>,
    /// Environment variable names removed before starting the service.
    pub scrub_env: Vec<OsString>,
    /// How long starting may take.
    pub start_timeout: Duration,
}

impl ServiceConfig {
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            registration: None,
            scrub_env: Vec::new(),
            start_timeout: DEFAULT_START_TIMEOUT,
        }
    }

    fn registration_path(&self) -> Option<PathBuf> {
        self.registration.clone().or_else(default_registration)
    }
}

/// OpenCode's default registration file.
pub fn default_registration() -> Option<PathBuf> {
    let state = std::env::var_os("XDG_STATE_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
        })?;
    Some(state.join("opencode").join("service.json"))
}

/// Why no service could be reached.
#[derive(Debug, thiserror::Error)]
pub enum ServiceError {
    #[error("the OpenCode executable is missing at {0}")]
    ExecutableMissing(String),
    #[error("OpenCode could not start its background service: {0}")]
    Start(String),
    #[error("the OpenCode background service is not answering: {0}")]
    Unreachable(String),
}

/// What a registration answered.
enum Probe {
    Ready(Endpoint, ServerInfo),
    /// The registered process answers but is still starting.
    Starting,
    Absent,
}

/// A healthy registered service, without starting one.
pub async fn discover(config: &ServiceConfig) -> Option<(Endpoint, ServerInfo)> {
    match registered(config).await {
        Probe::Ready(endpoint, info) => Some((endpoint, info)),
        _ => None,
    }
}

async fn registered(config: &ServiceConfig) -> Probe {
    let Some(path) = config.registration_path() else {
        return Probe::Absent;
    };
    match read_registration(&path).await {
        Some(registration) => probe(registration).await,
        None => Probe::Absent,
    }
}

/// A healthy service, starting one with `opencode service start` if needed.
/// A registered service that is still starting is waited on, as OpenCode's
/// own clients do, rather than started a second time.
pub async fn ensure(config: &ServiceConfig) -> Result<(Endpoint, ServerInfo), ServiceError> {
    let deadline = tokio::time::Instant::now() + config.start_timeout;
    loop {
        match registered(config).await {
            Probe::Ready(endpoint, info) => return Ok((endpoint, info)),
            Probe::Starting if tokio::time::Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            Probe::Starting => {
                return Err(ServiceError::Unreachable(
                    "the background service did not finish starting".to_owned(),
                ));
            }
            Probe::Absent => break,
        }
    }
    if !config.executable.is_file() {
        return Err(ServiceError::ExecutableMissing(
            config.executable.display().to_string(),
        ));
    }
    let mut command = Command::new(&config.executable);
    command
        .args(["service", "start"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for name in &config.scrub_env {
        command.env_remove(name);
    }
    if let Some(path) = &config.registration
        && let Some(state) = path.parent().and_then(Path::parent)
    {
        // A non-default registration file is a private state root (tests).
        command.env("XDG_STATE_HOME", state);
    }
    let output = tokio::time::timeout(config.start_timeout, command.output())
        .await
        .map_err(|_| ServiceError::Start("timed out".to_owned()))?
        .map_err(|error| ServiceError::Start(error.to_string()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(ServiceError::Start(tail(&stderr, 400)));
    }
    // `service start` prints the URL once the registration answers; allow a
    // moment for the file to be visible.
    for _ in 0..20 {
        if let Some(found) = discover(config).await {
            return Ok(found);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(ServiceError::Unreachable(
        "the service started but its registration did not answer".to_owned(),
    ))
}

async fn read_registration(path: &Path) -> Option<Registration> {
    let text = tokio::fs::read_to_string(path).await.ok()?;
    serde_json::from_str(&text).ok()
}

async fn probe(registration: Registration) -> Probe {
    let Ok(url) = url::Url::parse(&registration.url) else {
        return Probe::Absent;
    };
    if !matches!(url.scheme(), "http" | "https") {
        return Probe::Absent;
    }
    let endpoint = Endpoint {
        url,
        password: registration
            .password
            .filter(|password| !password.is_empty()),
    };
    let Ok((ready, info)) = info_status(&endpoint, PROBE_TIMEOUT).await else {
        return Probe::Absent;
    };
    // A recycled pid or a replaced service is not this registration.
    if info.pid != registration.pid {
        return Probe::Absent;
    }
    if let Some(version) = &registration.version
        && *version != info.version
    {
        return Probe::Absent;
    }
    if ready {
        Probe::Ready(endpoint, info)
    } else {
        Probe::Starting
    }
}

/// `/api/info` with whether the service is ready: a starting service answers
/// its version and pid with a non-success status; 500 means it failed.
async fn info_status(endpoint: &Endpoint, timeout: Duration) -> Result<(bool, ServerInfo), String> {
    let client = reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|error| error.to_string())?;
    let mut request = client.get(endpoint.join("api/info"));
    if let Some(authorization) = endpoint.authorization() {
        request = request.header(reqwest::header::AUTHORIZATION, authorization);
    }
    let response = request.send().await.map_err(|error| error.to_string())?;
    let status = response.status();
    if matches!(status.as_u16(), 401 | 404 | 500) {
        return Err(format!("status {status}"));
    }
    let info = response
        .json::<ServerInfo>()
        .await
        .map_err(|error| error.to_string())?;
    Ok((status.is_success(), info))
}

/// `GET /api/info`.
pub async fn info(endpoint: &Endpoint, timeout: Duration) -> Result<ServerInfo, String> {
    let client = reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|error| error.to_string())?;
    let mut request = client.get(endpoint.join("api/info"));
    if let Some(authorization) = endpoint.authorization() {
        request = request.header(reqwest::header::AUTHORIZATION, authorization);
    }
    let response = request.send().await.map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err(format!("status {}", response.status()));
    }
    response
        .json::<ServerInfo>()
        .await
        .map_err(|error| error.to_string())
}

fn tail(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let skip = text.chars().count() - max;
    format!("…{}", text.chars().skip(skip).collect::<String>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_joins_paths_and_hides_its_password() {
        let endpoint = Endpoint {
            url: url::Url::parse("http://127.0.0.1:4096").unwrap(),
            password: Some("secret".into()),
        };
        assert_eq!(
            endpoint.join("api/session").as_str(),
            "http://127.0.0.1:4096/api/session"
        );
        assert_eq!(
            endpoint.authorization().as_deref(),
            Some("Basic b3BlbmNvZGU6c2VjcmV0")
        );
        assert!(!format!("{endpoint:?}").contains("secret"));
        let nested = Endpoint::open(url::Url::parse("http://host/base").unwrap());
        assert_eq!(
            nested.join("/api/info").as_str(),
            "http://host/base/api/info"
        );
    }

    #[test]
    fn tail_keeps_the_end() {
        assert_eq!(tail("abcdef", 3), "…def");
        assert_eq!(tail("  ab ", 3), "ab");
    }
}

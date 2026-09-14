use std::collections::HashMap;
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flate2::read::GzDecoder;
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tar::Archive;
use thiserror::Error;
use tokio::io::AsyncWriteExt;
use tokio::task::JoinHandle;

use crate::config::Config;
use crate::identity as client_info;
use crate::state::{LocalDb, StateError};

const UPDATE_CHECK_INTERVAL_SECS: i64 = 6 * 60 * 60;
const UPDATE_CHECK_TIMEOUT_SECS: u64 = 4;
const UPDATE_CHECK_FINISH_TIMEOUT_MS: u64 = 150;
const MAX_UPDATE_DOWNLOAD_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum UpdateError {
    #[error("state error: {0}")]
    State(#[from] StateError),
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("version error: {0}")]
    Version(#[from] semver::Error),
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("missing release manifest url")]
    MissingManifestUrl,
    #[error("missing release target for {0}")]
    MissingTarget(String),
    #[error("checksum mismatch (expected {expected}, got {actual})")]
    ChecksumMismatch { expected: String, actual: String },
    #[error("update download exceeds the {MAX_UPDATE_DOWNLOAD_BYTES}-byte safety limit")]
    DownloadTooLarge,
    #[error("update download size mismatch (expected {expected} bytes, got {actual})")]
    SizeMismatch { expected: u64, actual: u64 },
    #[error("missing inline binary in update bundle")]
    MissingBinary,
    #[error("inline in the update bundle must be a regular file")]
    InvalidBinary,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateManifest {
    version: String,
    #[allow(dead_code)]
    published_at: Option<String>,
    install_url: Option<String>,
    targets: HashMap<String, UpdateTarget>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateTarget {
    url: String,
    sha256: String,
    size: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct UpdateCheck {
    current_version: String,
    latest_version: String,
    target: String,
    supported: bool,
    update_available: bool,
}

pub async fn check_update(config: &Config) -> Result<UpdateCheck, UpdateError> {
    let manifest_url = config
        .release_manifest_url
        .as_deref()
        .ok_or(UpdateError::MissingManifestUrl)?;
    let manifest = fetch_manifest(manifest_url).await?;
    describe_update(&manifest, env!("CARGO_PKG_VERSION"), current_target())
}

fn describe_update(
    manifest: &UpdateManifest,
    current: &str,
    target: &str,
) -> Result<UpdateCheck, UpdateError> {
    let newer = Version::parse(&manifest.version)? > Version::parse(current)?;
    let supported = target != "unknown" && manifest.targets.contains_key(target);
    Ok(UpdateCheck {
        current_version: current.to_string(),
        latest_version: manifest.version.clone(),
        target: target.to_string(),
        supported,
        update_available: newer && supported,
    })
}

pub fn print_update_check(check: &UpdateCheck) {
    if !check.supported {
        println!(
            "Latest release: v{} (current v{}). No update bundle for {}.",
            crate::output::terminal_text(&check.latest_version),
            crate::output::terminal_text(&check.current_version),
            check.target
        );
    } else if check.update_available {
        println!(
            "Update available: v{} (current v{}). Run: inline update",
            crate::output::terminal_text(&check.latest_version),
            crate::output::terminal_text(&check.current_version)
        );
    } else {
        println!("inline is up to date (v{}).", check.current_version);
    }
}

pub async fn run_update(config: &Config, json: bool) -> Result<Option<PathBuf>, UpdateError> {
    let mut install_url_hint = config.release_install_url.clone();
    let result = run_update_inner(config, json, &mut install_url_hint).await;
    if result.is_err() && !json {
        print_reinstall_instructions(install_url_hint.as_deref());
    }
    result
}

async fn run_update_inner(
    config: &Config,
    json: bool,
    install_url_hint: &mut Option<String>,
) -> Result<Option<PathBuf>, UpdateError> {
    let manifest_url = config
        .release_manifest_url
        .clone()
        .ok_or(UpdateError::MissingManifestUrl)?;
    let manifest = fetch_manifest(&manifest_url).await?;
    if manifest.install_url.is_some() {
        *install_url_hint = manifest.install_url.clone();
    }
    let target = current_target();
    if target == "unknown" {
        if !json {
            eprintln!("Auto-update is not supported on this OS yet.");
        }
        return Ok(None);
    }

    let latest = Version::parse(&manifest.version)?;
    let current = Version::parse(env!("CARGO_PKG_VERSION"))?;
    if latest <= current {
        if !json {
            println!("inline is up to date (v{current}).");
        }
        return Ok(None);
    }

    let target_manifest = manifest
        .targets
        .get(target)
        .ok_or_else(|| UpdateError::MissingTarget(target.to_string()))?;

    let temp_dir = create_temp_dir()?;
    let archive_path = temp_dir.path().join("inline.tar.gz");
    download_file(target_manifest, &archive_path).await?;

    let extract_dir = temp_dir.path().join("extract");
    fs::create_dir_all(&extract_dir)?;
    extract_archive(&archive_path, &extract_dir)?;

    let extracted_binary = extract_dir.join("inline");
    validate_binary(&extracted_binary)?;

    let current_exe = std::env::current_exe()?;
    let staged_path = stage_binary(&extracted_binary, temp_dir.path())?;
    let install_outcome = install_binary(&staged_path, &current_exe)?;

    if !json {
        if install_outcome.used_fallback {
            println!(
                "Updated inline to v{latest} (installed to {}).",
                install_outcome.install_path.display()
            );
            if let Some(parent) = (!install_outcome.path_on_env)
                .then(|| install_outcome.install_path.parent())
                .flatten()
            {
                eprintln!(
                    "{} is not on your PATH. Add it to run the updated inline.",
                    parent.display()
                );
            }
        } else {
            println!("Updated inline to v{latest}.");
        }
    }
    Ok(Some(install_outcome.install_path))
}

pub fn spawn_update_check(
    config: &Config,
    local_db: &LocalDb,
    json: bool,
) -> Option<JoinHandle<()>> {
    let manifest_url = config.release_manifest_url.clone()?;
    let install_url = config.release_install_url.clone();
    let local_db = local_db.clone();
    let current_version = env!("CARGO_PKG_VERSION").to_string();

    // If we're not due for a check, avoid spawning a task at all. This keeps fast CLI
    // invocations fast (no task scheduling + join timeout).
    if current_target() == "unknown" {
        return None;
    }
    let now = current_epoch_seconds();
    let recently_attempted = local_db.load().ok().is_some_and(|state| {
        state.release_manifest_url.as_deref() == Some(&manifest_url)
            && state.last_update_attempt_at.is_some_and(|last_attempt| {
                now.saturating_sub(last_attempt) < UPDATE_CHECK_INTERVAL_SECS
            })
    });
    if recently_attempted {
        return None;
    }

    Some(tokio::spawn(async move {
        let update_result =
            check_for_update(manifest_url, install_url, local_db, current_version, json).await;
        if let (true, Err(error)) = (cfg!(debug_assertions), update_result) {
            eprintln!("update check failed: {error}");
        }
    }))
}

pub async fn finish_update_check(handle: Option<JoinHandle<()>>) {
    if let Some(handle) = handle {
        let _ = tokio::time::timeout(
            Duration::from_millis(UPDATE_CHECK_FINISH_TIMEOUT_MS),
            handle,
        )
        .await;
    }
}

async fn check_for_update(
    manifest_url: String,
    install_url: Option<String>,
    local_db: LocalDb,
    current_version: String,
    json: bool,
) -> Result<(), UpdateError> {
    let target = current_target();
    if target == "unknown" {
        return Ok(());
    }

    let now = current_epoch_seconds();
    let mut state = local_db.load()?;
    if state.release_manifest_url.as_deref() != Some(&manifest_url) {
        state.last_update_check_at = None;
        state.last_update_attempt_at = None;
        state.last_update_notified_version = None;
        state.last_seen_release_version = None;
    }

    if state
        .last_update_attempt_at
        .is_some_and(|last_attempt| now.saturating_sub(last_attempt) < UPDATE_CHECK_INTERVAL_SECS)
    {
        return Ok(());
    }

    // Mark attempt early so we don't keep spawning checks if the CLI exits quickly.
    state.release_manifest_url = Some(manifest_url.clone());
    state.last_update_attempt_at = Some(now);
    let _ = local_db.save(&state);

    let client = client_info::http_client_builder()
        .timeout(Duration::from_secs(UPDATE_CHECK_TIMEOUT_SECS))
        .build()?;
    let response = client.get(&manifest_url).send().await?.error_for_status()?;
    let payload = response.text().await?;
    let manifest: UpdateManifest = serde_json::from_str(&payload)?;

    state.last_update_check_at = Some(now);
    state.last_seen_release_version = Some(manifest.version.clone());

    let latest = Version::parse(&manifest.version)?;
    let current = Version::parse(&current_version)?;
    if latest > current && manifest.targets.contains_key(target) {
        let should_notify = state
            .last_update_notified_version
            .as_deref()
            .map(|version| version != manifest.version.as_str())
            .unwrap_or(true);
        if should_notify {
            let install_url = manifest.install_url.clone().or(install_url);
            print_update_notice(
                &current_version,
                &manifest.version,
                install_url.as_deref(),
                json,
            );
            state.last_update_notified_version = Some(manifest.version.clone());
        }
    }

    local_db.save(&state)?;
    Ok(())
}

fn print_update_notice(current: &str, latest: &str, install_url: Option<&str>, json: bool) {
    if json {
        return;
    }
    eprintln!("Update available: v{latest} (current v{current}).");
    if let Some(url) = install_url {
        eprintln!("Run: curl -fsSL {url} | sh");
    }
}

fn print_reinstall_instructions(install_url: Option<&str>) {
    eprintln!("Update failed. Reinstall with:");
    if let Some(url) = install_url {
        eprintln!("  curl -fsSL {url} | sh");
    } else {
        eprintln!("  curl -fsSL https://public-assets.inline.chat/cli/install.sh | sh");
    }
}

fn current_target() -> &'static str {
    if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            "aarch64-apple-darwin"
        } else if cfg!(target_arch = "x86_64") {
            "x86_64-apple-darwin"
        } else {
            "unknown"
        }
    } else if cfg!(target_os = "linux") {
        if cfg!(target_arch = "aarch64") {
            if cfg!(target_env = "musl") {
                "aarch64-unknown-linux-musl"
            } else if cfg!(target_env = "gnu") {
                "aarch64-unknown-linux-gnu"
            } else {
                "unknown"
            }
        } else if cfg!(target_arch = "x86_64") {
            if cfg!(target_env = "musl") {
                "x86_64-unknown-linux-musl"
            } else if cfg!(target_env = "gnu") {
                "x86_64-unknown-linux-gnu"
            } else {
                "unknown"
            }
        } else {
            "unknown"
        }
    } else {
        "unknown"
    }
}

fn current_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

async fn fetch_manifest(url: &str) -> Result<UpdateManifest, UpdateError> {
    let client = client_info::http_client_builder()
        .timeout(Duration::from_secs(UPDATE_CHECK_TIMEOUT_SECS))
        .build()?;
    let response = client.get(url).send().await?.error_for_status()?;
    let payload = response.text().await?;
    Ok(serde_json::from_str(&payload)?)
}

async fn download_file(target: &UpdateTarget, path: &Path) -> Result<(), UpdateError> {
    if target
        .size
        .is_some_and(|size| size > MAX_UPDATE_DOWNLOAD_BYTES)
    {
        return Err(UpdateError::DownloadTooLarge);
    }
    let client = client_info::http_client_builder()
        .timeout(Duration::from_secs(60))
        .build()?;
    let mut response = client.get(&target.url).send().await?.error_for_status()?;
    if let Some(actual) = response.content_length() {
        if actual > MAX_UPDATE_DOWNLOAD_BYTES {
            return Err(UpdateError::DownloadTooLarge);
        }
        if let Some(expected) = target.size.filter(|size| *size != actual) {
            return Err(UpdateError::SizeMismatch { expected, actual });
        }
    }
    let mut file = tokio::fs::File::create(path).await?;
    let mut hasher = Sha256::new();
    let mut actual_size = 0u64;
    while let Some(chunk) = response.chunk().await? {
        actual_size = actual_size.saturating_add(chunk.len() as u64);
        if actual_size > MAX_UPDATE_DOWNLOAD_BYTES {
            return Err(UpdateError::DownloadTooLarge);
        }
        if let Some(expected) = target.size.filter(|size| actual_size > *size) {
            return Err(UpdateError::SizeMismatch {
                expected,
                actual: actual_size,
            });
        }
        file.write_all(&chunk).await?;
        hasher.update(&chunk);
    }
    file.flush().await?;
    if let Some(expected) = target.size.filter(|size| *size != actual_size) {
        return Err(UpdateError::SizeMismatch {
            expected,
            actual: actual_size,
        });
    }
    let actual = bytes_to_hex(&hasher.finalize());
    let expected = target.sha256.trim();
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(UpdateError::ChecksumMismatch {
            expected: expected.to_string(),
            actual,
        });
    }
    Ok(())
}

fn create_temp_dir() -> Result<tempfile::TempDir, io::Error> {
    let mut builder = tempfile::Builder::new();
    builder.prefix("inline-update-");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        builder.permissions(fs::Permissions::from_mode(0o700));
    }
    builder.tempdir()
}

fn validate_binary(path: &Path) -> Result<(), UpdateError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => Ok(()),
        Ok(_) => Err(UpdateError::InvalidBinary),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Err(UpdateError::MissingBinary),
        Err(error) => Err(error.into()),
    }
}

fn bytes_to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = std::fmt::Write::write_fmt(&mut out, format_args!("{:02x}", byte));
    }
    out
}

fn extract_archive(archive_path: &Path, output_dir: &Path) -> Result<(), UpdateError> {
    let file = File::open(archive_path)?;
    let decoder = GzDecoder::new(file);
    let mut archive = Archive::new(decoder);
    archive.unpack(output_dir)?;
    Ok(())
}

fn stage_binary(extracted_binary: &Path, stage_dir: &Path) -> Result<PathBuf, UpdateError> {
    let staged_path = stage_dir.join("inline.new");
    fs::copy(extracted_binary, &staged_path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&staged_path)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&staged_path, perms)?;
    }
    Ok(staged_path)
}

struct InstallOutcome {
    install_path: PathBuf,
    used_fallback: bool,
    path_on_env: bool,
}

fn install_binary(staged_path: &Path, install_path: &Path) -> Result<InstallOutcome, UpdateError> {
    match install_binary_direct(staged_path, install_path) {
        Ok(()) => Ok(InstallOutcome {
            install_path: install_path.to_path_buf(),
            used_fallback: false,
            path_on_env: path_contains_dir(install_path),
        }),
        Err(error) => {
            if error.kind() == io::ErrorKind::PermissionDenied {
                if command_exists("sudo") {
                    if let Err(sudo_error) = install_binary_with_sudo(staged_path, install_path) {
                        let combined = io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            format!("install failed: {error}; sudo install failed: {sudo_error}"),
                        );
                        return Err(UpdateError::Io(combined));
                    }
                    return Ok(InstallOutcome {
                        install_path: install_path.to_path_buf(),
                        used_fallback: false,
                        path_on_env: path_contains_dir(install_path),
                    });
                }

                let fallback_path = user_fallback_path(install_path)?;
                install_binary_direct(staged_path, &fallback_path)?;
                return Ok(InstallOutcome {
                    install_path: fallback_path.clone(),
                    used_fallback: true,
                    path_on_env: path_contains_dir(&fallback_path),
                });
            }
            Err(UpdateError::Io(error))
        }
    }
}

fn install_binary_direct(staged_path: &Path, install_path: &Path) -> Result<(), io::Error> {
    match fs::rename(staged_path, install_path) {
        Ok(()) => Ok(()),
        Err(error) if is_cross_device_link(&error) => {
            copy_binary_atomically(staged_path, install_path)
        }
        Err(error) => Err(error),
    }
}

fn copy_binary_atomically(staged_path: &Path, install_path: &Path) -> Result<(), io::Error> {
    let parent = install_path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "install path has no parent directory",
        )
    })?;
    let mut replacement = tempfile::Builder::new()
        .prefix(".inline-update-")
        .tempfile_in(parent)?;
    let mut source = File::open(staged_path)?;
    io::copy(&mut source, replacement.as_file_mut())?;
    replacement
        .as_file()
        .set_permissions(source.metadata()?.permissions())?;
    replacement.as_file().sync_all()?;
    replacement
        .persist(install_path)
        .map_err(|error| error.error)?;
    Ok(())
}

fn install_binary_with_sudo(staged_path: &Path, install_path: &Path) -> Result<(), io::Error> {
    if !command_exists("sudo") {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "sudo not available",
        ));
    }
    if command_exists("install") {
        let status = Command::new("sudo")
            .arg("install")
            .arg("-m")
            .arg("0755")
            .arg(staged_path)
            .arg(install_path)
            .status()?;
        if status.success() {
            return Ok(());
        }
        return Err(io::Error::other("sudo install failed"));
    }

    let status = Command::new("sudo")
        .arg("cp")
        .arg(staged_path)
        .arg(install_path)
        .status()?;
    if !status.success() {
        return Err(io::Error::other("sudo copy failed"));
    }
    let status = Command::new("sudo")
        .arg("chmod")
        .arg("755")
        .arg(install_path)
        .status()?;
    if !status.success() {
        return Err(io::Error::other("sudo chmod failed"));
    }
    Ok(())
}

fn user_fallback_path(install_path: &Path) -> Result<PathBuf, UpdateError> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME not set"))?;
    let file_name = install_path
        .file_name()
        .unwrap_or_else(|| std::ffi::OsStr::new("inline"));
    let dir = PathBuf::from(home).join(".local").join("bin");
    fs::create_dir_all(&dir)?;
    Ok(dir.join(file_name))
}

fn command_exists(command: &str) -> bool {
    std::env::var_os("PATH")
        .and_then(|paths| {
            for path in std::env::split_paths(&paths) {
                let full_path = path.join(command);
                if full_path.exists() {
                    return Some(());
                }
            }
            None
        })
        .is_some()
}

fn path_contains_dir(path: &Path) -> bool {
    let Some(dir) = path.parent() else {
        return false;
    };
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|entry| entry == dir))
        .unwrap_or(false)
}

fn is_cross_device_link(error: &io::Error) -> bool {
    #[cfg(unix)]
    {
        error.raw_os_error() == Some(18)
    }
    #[cfg(not(unix))]
    {
        let _ = error;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use tokio::io::AsyncReadExt;
    use tokio::net::TcpListener;
    use tokio::sync::oneshot;

    fn target(url: String, body: &[u8], size: Option<u64>) -> UpdateTarget {
        UpdateTarget {
            url,
            sha256: bytes_to_hex(&Sha256::digest(body)),
            size,
        }
    }

    async fn read_request(stream: &mut tokio::net::TcpStream) {
        tokio::time::timeout(Duration::from_secs(5), async {
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).await.unwrap();
                request.push(byte[0]);
                assert!(request.len() < 16 * 1024);
            }
            assert!(request.starts_with(b"GET /archive HTTP/1.1\r\n"));
        })
        .await
        .expect("complete HTTP request");
    }

    async fn serve(response: Vec<u8>) -> (String, JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/archive", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_request(&mut stream).await;
            stream.write_all(&response).await.unwrap();
            stream.shutdown().await.unwrap();
        });
        (url, task)
    }

    fn response(body: &[u8]) -> Vec<u8> {
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(body);
        response
    }

    #[test]
    fn update_checks_handle_versions_and_unavailable_platforms() {
        let mut manifest = UpdateManifest {
            version: "1.2.0".into(),
            published_at: None,
            install_url: None,
            targets: HashMap::from([(
                "test-platform".into(),
                target("http://127.0.0.1:9/archive".into(), b"binary", None),
            )]),
        };
        for (current, available) in [("1.1.0", true), ("1.2.0", false), ("1.3.0", false)] {
            let check = describe_update(&manifest, current, "test-platform").unwrap();
            assert_eq!(check.update_available, available);
            assert!(check.supported);
        }
        let check = describe_update(&manifest, "1.0.0", "missing-platform").unwrap();
        assert!(!check.supported);
        assert!(!check.update_available);
        manifest.version = "1.2.0-beta.1".into();
        assert!(
            !describe_update(&manifest, "1.2.0", "test-platform")
                .unwrap()
                .update_available
        );
        manifest.version = "invalid".into();
        assert!(matches!(
            describe_update(&manifest, "1.0.0", "test-platform"),
            Err(UpdateError::Version(_))
        ));
    }

    #[tokio::test]
    async fn archive_is_written_before_the_server_finishes_and_hashes_all_chunks() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("archive");
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/archive", listener.local_addr().unwrap());
        let body = vec![b'x'; 64 * 1024];
        let target = target(url, &body, Some(body.len() as u64));
        let (first_sent, first_received) = oneshot::channel();
        let (continue_send, continue_receive) = oneshot::channel();
        let server_body = body.clone();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_request(&mut stream).await;
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                )
                .await
                .unwrap();
            stream.write_all(b"8000\r\n").await.unwrap();
            stream.write_all(&server_body[..32 * 1024]).await.unwrap();
            stream.write_all(b"\r\n").await.unwrap();
            // The second chunk is held until the test sees the first on disk.
            first_sent.send(()).unwrap();
            continue_receive.await.unwrap();
            stream.write_all(b"8000\r\n").await.unwrap();
            stream.write_all(&server_body[32 * 1024..]).await.unwrap();
            stream.write_all(b"\r\n0\r\n\r\n").await.unwrap();
        });
        let download_path = path.clone();
        let download = tokio::spawn(async move { download_file(&target, &download_path).await });
        tokio::time::timeout(Duration::from_secs(5), first_received)
            .await
            .expect("first response chunk")
            .unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if fs::metadata(&path).is_ok_and(|metadata| metadata.len() > 0) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("first chunk should reach disk before response completes");
        assert!(!download.is_finished());
        continue_send.send(()).unwrap();
        download.await.unwrap().unwrap();
        server.await.unwrap();
        assert_eq!(fs::read(path).unwrap(), body);
    }

    #[tokio::test]
    async fn downloads_reject_bad_hash_size_and_truncated_responses() {
        let root = tempfile::tempdir().unwrap();
        let body = b"binary fixture";
        let (url, server) = serve(response(body)).await;
        let mut bad_hash = target(url, body, None);
        bad_hash.sha256 = "0".repeat(64);
        assert!(matches!(
            download_file(&bad_hash, &root.path().join("bad-hash")).await,
            Err(UpdateError::ChecksumMismatch { .. })
        ));
        server.await.unwrap();

        let (url, server) = serve(response(body)).await;
        let bad_size = target(url, body, Some(1));
        let path = root.path().join("bad-size");
        assert!(matches!(
            download_file(&bad_size, &path).await,
            Err(UpdateError::SizeMismatch { .. })
        ));
        assert!(!path.exists());
        server.await.unwrap();

        let (url, server) = serve(
            b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort".to_vec(),
        )
        .await;
        let truncated = target(url, body, None);
        assert!(matches!(
            download_file(&truncated, &root.path().join("truncated")).await,
            Err(UpdateError::Http(_))
        ));
        server.await.unwrap();

        let oversize = target(
            "http://127.0.0.1:9/archive".into(),
            body,
            Some(MAX_UPDATE_DOWNLOAD_BYTES + 1),
        );
        let path = root.path().join("oversize");
        assert!(matches!(
            download_file(&oversize, &path).await,
            Err(UpdateError::DownloadTooLarge)
        ));
        assert!(!path.exists());

        let (url, server) = serve(
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                MAX_UPDATE_DOWNLOAD_BYTES + 1
            )
            .into_bytes(),
        )
        .await;
        let oversize_response = target(url, body, None);
        let path = root.path().join("oversize-response");
        assert!(matches!(
            download_file(&oversize_response, &path).await,
            Err(UpdateError::DownloadTooLarge)
        ));
        assert!(!path.exists());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn downloads_accept_manifests_without_size_and_uppercase_checksums() {
        let root = tempfile::tempdir().unwrap();
        let body = b"binary fixture";
        let (url, server) = serve(response(body)).await;
        let mut target = target(url, body, None);
        target.sha256 = target.sha256.to_uppercase();
        let path = root.path().join("archive");
        download_file(&target, &path).await.unwrap();
        server.await.unwrap();
        assert_eq!(fs::read(path).unwrap(), body);
    }

    #[tokio::test]
    async fn chunked_downloads_enforce_optional_manifest_size() {
        for expected in [1, 20] {
            let root = tempfile::tempdir().unwrap();
            let (url, server) = serve(
                b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nbinary\r\n0\r\n\r\n"
                    .to_vec(),
            )
            .await;
            let target = target(url, b"binary", Some(expected));
            assert!(matches!(
                download_file(&target, &root.path().join("archive")).await,
                Err(UpdateError::SizeMismatch { .. })
            ));
            server.await.unwrap();
        }
    }

    #[test]
    fn staging_directories_are_private_unique_and_cleaned_independently() {
        let first = create_temp_dir().unwrap();
        let second = create_temp_dir().unwrap();
        assert_ne!(first.path(), second.path());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(first.path()).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        let old_path = first.path().to_path_buf();
        fs::write(first.path().join("partial-download"), b"partial").unwrap();
        drop(first);
        assert!(!old_path.exists());
        assert!(second.path().exists());
    }

    #[test]
    fn atomic_copy_replaces_the_binary_without_modifying_old_open_handles() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("source");
        let destination = root.path().join("inline");
        fs::write(&source, b"new complete binary").unwrap();
        fs::write(&destination, b"old complete binary").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut previous_handle = File::open(&destination).unwrap();
        copy_binary_atomically(&source, &destination).unwrap();
        assert_eq!(fs::read(&destination).unwrap(), b"new complete binary");
        let mut old = String::new();
        previous_handle.read_to_string(&mut old).unwrap();
        assert_eq!(old, "old complete binary");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&destination).unwrap().permissions().mode() & 0o777,
                0o755
            );
        }
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 2);
    }

    #[test]
    fn failed_atomic_copy_keeps_the_existing_install_and_leaves_no_sibling_file() {
        let root = tempfile::tempdir().unwrap();
        let destination = root.path().join("inline");
        fs::write(&destination, b"working binary").unwrap();
        assert!(copy_binary_atomically(&root.path().join("missing"), &destination).is_err());
        assert_eq!(fs::read(&destination).unwrap(), b"working binary");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);

        let directory = root.path().join("directory");
        fs::create_dir(&directory).unwrap();
        fs::write(directory.join("keep"), b"untouched").unwrap();
        assert!(copy_binary_atomically(&destination, &directory).is_err());
        assert_eq!(fs::read(directory.join("keep")).unwrap(), b"untouched");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 2);
    }

    #[test]
    fn bundle_binary_must_be_a_regular_file() {
        let root = tempfile::tempdir().unwrap();
        assert!(matches!(
            validate_binary(&root.path().join("missing")),
            Err(UpdateError::MissingBinary)
        ));
        assert!(matches!(
            validate_binary(root.path()),
            Err(UpdateError::InvalidBinary)
        ));
        let regular = root.path().join("inline");
        fs::write(&regular, b"binary").unwrap();
        validate_binary(&regular).unwrap();
        #[cfg(unix)]
        {
            let link = root.path().join("link");
            std::os::unix::fs::symlink(&regular, &link).unwrap();
            assert!(matches!(
                validate_binary(&link),
                Err(UpdateError::InvalidBinary)
            ));
        }
    }
}

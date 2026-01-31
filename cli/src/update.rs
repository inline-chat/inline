use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flate2::read::GzDecoder;
use semver::Version;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tar::Archive;
use thiserror::Error;
use tokio::task::JoinHandle;

use crate::config::Config;
use crate::state::{LocalDb, StateError};

const UPDATE_CHECK_INTERVAL_SECS: i64 = 6 * 60 * 60;
const UPDATE_CHECK_TIMEOUT_SECS: u64 = 4;

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
    #[error("missing inline binary in update bundle")]
    MissingBinary,
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
    #[allow(dead_code)]
    size: Option<u64>,
}

pub async fn run_update(config: &Config, json: bool) -> Result<(), UpdateError> {
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
) -> Result<(), UpdateError> {
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
        return Ok(());
    }

    let latest = Version::parse(&manifest.version)?;
    let current = Version::parse(env!("CARGO_PKG_VERSION"))?;
    if latest <= current {
        if !json {
            println!("inline is up to date (v{current}).");
        }
        return Ok(());
    }

    let target_manifest = manifest
        .targets
        .get(target)
        .ok_or_else(|| UpdateError::MissingTarget(target.to_string()))?;

    let temp_dir = create_temp_dir()?;
    let archive_path = temp_dir.join("inline.tar.gz");
    download_file(&target_manifest.url, &archive_path).await?;
    let actual_sha = sha256_file(&archive_path)?;
    let expected_sha = target_manifest.sha256.trim().to_string();
    if actual_sha != expected_sha {
        return Err(UpdateError::ChecksumMismatch {
            expected: expected_sha,
            actual: actual_sha,
        });
    }

    let extract_dir = temp_dir.join("extract");
    fs::create_dir_all(&extract_dir)?;
    extract_archive(&archive_path, &extract_dir)?;

    let extracted_binary = extract_dir.join("inline");
    if !extracted_binary.exists() {
        return Err(UpdateError::MissingBinary);
    }

    let current_exe = std::env::current_exe()?;
    let staged_path = stage_binary(&extracted_binary, &temp_dir)?;
    let install_outcome = install_binary(&staged_path, &current_exe)?;

    if !json {
        if install_outcome.used_fallback {
            println!(
                "Updated inline to v{latest} (installed to {}).",
                install_outcome.install_path.display()
            );
            if !install_outcome.path_on_env {
                if let Some(parent) = install_outcome.install_path.parent() {
                    eprintln!(
                        "{} is not on your PATH. Add it to run the updated inline.",
                        parent.display()
                    );
                }
            }
        } else {
            println!("Updated inline to v{latest}.");
        }
    }
    Ok(())
}

pub fn spawn_update_check(config: &Config, local_db: &LocalDb, json: bool) -> Option<JoinHandle<()>> {
    let manifest_url = config.release_manifest_url.clone()?;
    let install_url = config.release_install_url.clone();
    let local_db = local_db.clone();
    let current_version = env!("CARGO_PKG_VERSION").to_string();

    Some(tokio::spawn(async move {
        if let Err(error) = check_for_update(
            manifest_url,
            install_url,
            local_db,
            current_version,
            json,
        )
        .await
        {
            if cfg!(debug_assertions) {
                eprintln!("update check failed: {error}");
            }
        }
    }))
}

pub async fn finish_update_check(handle: Option<JoinHandle<()>>) {
    if let Some(handle) = handle {
        let _ = tokio::time::timeout(Duration::from_millis(400), handle).await;
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
        state.last_update_notified_version = None;
        state.last_seen_release_version = None;
    }

    if let Some(last_check) = state.last_update_check_at {
        if now.saturating_sub(last_check) < UPDATE_CHECK_INTERVAL_SECS {
            return Ok(());
        }
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(UPDATE_CHECK_TIMEOUT_SECS))
        .build()?;
    let response = client.get(&manifest_url).send().await?.error_for_status()?;
    let payload = response.text().await?;
    let manifest: UpdateManifest = serde_json::from_str(&payload)?;

    state.release_manifest_url = Some(manifest_url);
    state.last_update_check_at = Some(now);
    state.last_seen_release_version = Some(manifest.version.clone());

    let latest = Version::parse(&manifest.version)?;
    let current = Version::parse(&current_version)?;
    if latest > current {
        if manifest.targets.contains_key(target) {
            let should_notify = state
                .last_update_notified_version
                .as_deref()
                .map(|version| version != manifest.version.as_str())
                .unwrap_or(true);
            if should_notify {
                let install_url = manifest.install_url.clone().or(install_url);
                print_update_notice(&current_version, &manifest.version, install_url.as_deref(), json);
                state.last_update_notified_version = Some(manifest.version.clone());
            }
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
    if cfg!(target_arch = "aarch64") {
        "aarch64-apple-darwin"
    } else if cfg!(target_arch = "x86_64") {
        "x86_64-apple-darwin"
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
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(UPDATE_CHECK_TIMEOUT_SECS))
        .build()?;
    let response = client.get(url).send().await?.error_for_status()?;
    let payload = response.text().await?;
    Ok(serde_json::from_str(&payload)?)
}

async fn download_file(url: &str, path: &Path) -> Result<(), UpdateError> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;
    let response = client.get(url).send().await?.error_for_status()?;
    let bytes = response.bytes().await?;
    tokio::fs::write(path, &bytes).await?;
    Ok(())
}

fn create_temp_dir() -> Result<PathBuf, UpdateError> {
    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let dir = std::env::temp_dir().join(format!("inline-update-{}", timestamp.as_secs()));
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn sha256_file(path: &Path) -> Result<String, UpdateError> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(bytes_to_hex(&hasher.finalize()))
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
                            format!(
                                "install failed: {error}; sudo install failed: {sudo_error}"
                            ),
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
            fs::copy(staged_path, install_path)?;
            let _ = fs::remove_file(staged_path);
            Ok(())
        }
        Err(error) => Err(error),
    }
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
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "sudo install failed",
        ));
    }

    let status = Command::new("sudo")
        .arg("cp")
        .arg(staged_path)
        .arg(install_path)
        .status()?;
    if !status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "sudo copy failed",
        ));
    }
    let status = Command::new("sudo")
        .arg("chmod")
        .arg("755")
        .arg(install_path)
        .status()?;
    if !status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "sudo chmod failed",
        ));
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

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
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

pub async fn run_update(config: &Config, json: bool) -> Result<(), UpdateError> {
    let manifest_url = config
        .release_manifest_url
        .clone()
        .ok_or(UpdateError::MissingManifestUrl)?;
    let manifest = fetch_manifest(&manifest_url).await?;
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
    let staged_path = stage_binary(&extracted_binary, &current_exe)?;
    install_binary(&staged_path, &current_exe)?;

    if !json {
        println!("Updated inline to v{latest}.");
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

fn stage_binary(extracted_binary: &Path, install_path: &Path) -> Result<PathBuf, UpdateError> {
    let install_dir = install_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "missing install directory"))?;
    let staged_path = install_dir.join("inline.new");
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

fn install_binary(staged_path: &Path, install_path: &Path) -> Result<(), UpdateError> {
    fs::rename(staged_path, install_path)?;
    Ok(())
}

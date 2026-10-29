use crate::{
    config::Config,
    identity as client_info,
    state::{LocalDb, StateError},
};
use flate2::read::GzDecoder;
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{self, Read},
    path::{Path, PathBuf},
    process::Stdio,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tar::Archive;
use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    task::JoinHandle,
};

mod cache;
pub mod manifest;
pub mod store;
mod transfer;
pub use store::{Artifact, Store};
use transfer::*;

const MAX_UPDATE_DOWNLOAD_BYTES: u64 = 100 * 1024 * 1024;
const CHECK_INTERVAL: i64 = 6 * 60 * 60;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
    Stable,
    Alpha,
}
impl UpdateChannel {
    pub fn resolve(saved: Option<Self>, version: &str) -> Self {
        saved.unwrap_or(if version.contains('-') {
            Self::Alpha
        } else {
            Self::Stable
        })
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Alpha => "alpha",
        }
    }
}

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
    #[error("another update operation is in progress")]
    Busy,
    #[error("release verification failed ({0}); the working version was kept")]
    Verification(&'static str),
    #[error("missing release manifest url")]
    MissingManifestUrl,
    #[error("missing release target for {0}")]
    MissingTarget(String),
    #[error("checksum mismatch (expected {expected}, got {actual})")]
    ChecksumMismatch { expected: String, actual: String },
    #[error("update download exceeds safety limit")]
    DownloadTooLarge,
    #[error("update download size mismatch (expected {expected} bytes, got {actual})")]
    SizeMismatch { expected: u64, actual: u64 },
    #[error("missing inline binary in update bundle")]
    MissingBinary,
    #[error("inline in the update bundle must be a regular file")]
    InvalidBinary,
}
impl UpdateError {
    pub fn stage(&self) -> &'static str {
        match self {
            Self::Verification(stage) => stage,
            Self::ChecksumMismatch { .. } => "checksum",
            Self::DownloadTooLarge | Self::SizeMismatch { .. } => "download_size",
            Self::Http(_) => "network",
            Self::MissingBinary | Self::InvalidBinary => "archive",
            Self::Busy => "busy",
            _ => "installation",
        }
    }
}

struct UpdateTarget {
    url: String,
    sha256: String,
    size: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct UpdateCheck {
    channel: UpdateChannel,
    current_version: String,
    latest_version: String,
    target: String,
    supported: bool,
    update_available: bool,
    verified: bool,
}

pub fn select_channel(
    db: &LocalDb,
    requested: Option<UpdateChannel>,
) -> Result<UpdateChannel, UpdateError> {
    let config = Config::load();
    let store = Store::new(&config.data_dir);
    let saved = store.read()?;
    if requested.is_none() && store.root.join("update.json").exists() {
        return Ok(saved.channel);
    }
    let legacy = db.load().ok().and_then(|state| state.update_channel);
    if requested.is_none() {
        return Ok(UpdateChannel::resolve(legacy, env!("CARGO_PKG_VERSION")));
    }
    store.edit(|state| {
        let channel = UpdateChannel::resolve(requested.or(legacy), env!("CARGO_PKG_VERSION"));
        if state.channel != channel {
            state.staged = None;
            state.last_attempt = None;
            state.retry_at = None;
        }
        state.channel = channel;
        if requested.is_some() {
            state.follows_app = false;
            state.channel_override = true;
            state.revision += 1;
        }
        Ok(state.channel)
    })
}

pub fn configure(
    config: &Config,
    enabled: Option<bool>,
    channel: Option<UpdateChannel>,
    app: bool,
    register: bool,
) -> Result<store::State, UpdateError> {
    let store = Store::new(&config.data_dir);
    if !store.root.join("update.json").exists() {
        // Read the legacy channel best-effort without ever saving the account
        // file. Old app and terminal channel choices had the same storage.
        let db = LocalDb::new(config.state_path.clone(), config.api_base_url.clone());
        if let Some(channel) = db.load().ok().and_then(|state| state.update_channel) {
            store.edit(|state| {
                if !store.root.join("update.json").exists() {
                    state.channel = channel;
                    state.channel_override = true;
                }
                Ok(())
            })?;
        }
    }
    if register {
        enroll_current(&store)?;
    }
    store.edit(|state| {
        let before = (
            state.auto_update,
            state.channel,
            state.follows_app,
            state.channel_override,
        );
        if let Some(enabled) = enabled {
            state.auto_update = enabled;
        }
        if let Some(channel) = channel {
            if !app || !state.channel_override {
                if state.channel != channel {
                    state.last_attempt = None;
                    state.retry_at = None;
                }
                if state.channel != channel {
                    state.staged = None;
                }
                state.channel = channel;
                state.follows_app = app;
            }
        }

        if !app && channel.is_some() {
            state.follows_app = false;
            state.channel_override = true;
        }
        if before
            != (
                state.auto_update,
                state.channel,
                state.follows_app,
                state.channel_override,
            )
        {
            state.revision += 1;
        }
        Ok(state.clone())
    })
}

pub fn follow_app(config: &Config, channel: UpdateChannel) -> Result<(), UpdateError> {
    Store::new(&config.data_dir).edit(|state| {
        state.channel_override = false;
        state.follows_app = true;
        if state.channel != channel {
            state.staged = None;
            state.retry_at = None;
            state.last_attempt = None;
        }
        state.channel = channel;
        state.revision += 1;
        Ok(())
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    #[serde(flatten)]
    pub state: store::State,
    pub current_version: &'static str,
    pub target: &'static str,
    pub automatic_updates_available: bool,
    pub installation_method: &'static str,
    pub bridges: Vec<crate::bridge::BridgeUpdateStatus>,
}
pub fn status(config: &Config) -> Result<Status, UpdateError> {
    let store = Store::new(&config.data_dir);
    let exe = std::env::current_exe()?;
    Ok(Status {
        state: store.read()?,
        current_version: env!("CARGO_PKG_VERSION"),
        target: current_target(),
        automatic_updates_available: automatic_allowed(),
        installation_method: installation_method(&exe, &store),
        bridges: crate::bridge::update_statuses(config),
    })
}

fn check_due(state: &store::State, now: i64, interval: i64) -> bool {
    if let Some(retry) = state.retry_at {
        return now >= retry;
    }
    !state
        .last_attempt
        .is_some_and(|at| now.saturating_sub(at) < interval)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Compatibility {
    bridge_schema_version: u32,
    minimum_reader_schema_version: u32,
}
fn compatibility() -> Compatibility {
    serde_json::from_str(include_str!("../update-compatibility.json"))
        .expect("embedded update compatibility")
}

pub(crate) fn automatic_allowed() -> bool {
    !cfg!(debug_assertions)
        && !Config::release_manifest_overridden()
        && std::env::var_os("INLINE_RELEASE_BASE_URL").is_none()
        && !std::env::var("INLINE_DISABLE_AUTOUPDATE").is_ok_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "on"
            )
        })
}

fn manifest_url(config: &Config, channel: UpdateChannel) -> Result<String, UpdateError> {
    let base = config
        .release_manifest_url
        .as_deref()
        .ok_or(UpdateError::MissingManifestUrl)?;
    if Config::release_manifest_overridden() {
        return Ok(base.to_owned());
    }
    Ok(format!(
        "{}/channels/{}.json",
        base.trim_end_matches("/manifest.json"),
        channel.as_str()
    ))
}

async fn fetch_release(
    config: &Config,
    channel: UpdateChannel,
) -> Result<manifest::Release, UpdateError> {
    let client = client_info::http_client_builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::limited(5))
        .timeout(Duration::from_secs(15))
        .build()?;
    let mut response = client
        .get(manifest_url(config, channel)?)
        .send()
        .await?
        .error_for_status()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len() + chunk.len() > manifest::MAX_MANIFEST_BYTES {
            return Err(UpdateError::Verification("manifest_size"));
        }
        bytes.extend_from_slice(&chunk);
    }
    let release = manifest::verify(&bytes, channel)?;
    let state = Store::new(&config.data_dir).read()?;
    if release.generation < *state.highest_generation.get(channel.as_str()).unwrap_or(&0) {
        return Err(UpdateError::Verification("manifest_replay"));
    }
    if let Some(previous) = state.accepted.get(channel.as_str()).or_else(|| {
        state
            .latest
            .as_ref()
            .filter(|previous| previous.channel == channel)
    }) {
        if release.generation == previous.generation && release != *previous {
            return Err(UpdateError::Verification("manifest_identity"));
        }
        if Version::parse(&release.version)?
            .cmp_precedence(&Version::parse(&previous.version)?)
            .is_lt()
        {
            return Err(UpdateError::Verification("release_rollback"));
        }
    }
    if let Some(previous) = state
        .accepted
        .get(channel.as_str())
        .filter(|old| old.version == release.version)
    {
        let mut identity = previous.clone();
        identity.generation = release.generation;
        if identity != release {
            return Err(UpdateError::Verification("manifest_identity"));
        }
    }
    Ok(release)
}

pub async fn check_update(
    config: &Config,
    channel: UpdateChannel,
) -> Result<UpdateCheck, UpdateError> {
    if Config::release_manifest_overridden() {
        return check_explicit_mirror(config, channel).await;
    }
    let release = fetch_release(config, channel).await?;
    Ok(UpdateCheck {
        channel,
        current_version: env!("CARGO_PKG_VERSION").into(),
        latest_version: release.version.clone(),
        target: current_target().into(),
        supported: release.targets.contains_key(current_target()),
        update_available: newer(&release.version, env!("CARGO_PKG_VERSION"))?
            && release.targets.contains_key(current_target()),
        verified: true,
    })
}
// Preserve the read-only developer mirror contract of --check. A legacy
// advertised version is explicitly unverified; installation/background paths
// never call this helper and still require pinned signatures over HTTPS.
async fn check_explicit_mirror(
    config: &Config,
    channel: UpdateChannel,
) -> Result<UpdateCheck, UpdateError> {
    let client = client_info::http_client_builder()
        .timeout(Duration::from_secs(10))
        .build()?;
    let mut response = client
        .get(manifest_url(config, channel)?)
        .send()
        .await?
        .error_for_status()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len() + chunk.len() > manifest::MAX_MANIFEST_BYTES {
            return Err(UpdateError::Verification("manifest_size"));
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes)?;
    let (version, supported, verified) = if value.get("payload").is_some() {
        let release = manifest::verify(&bytes, channel)?;
        let supported = release.targets.contains_key(current_target());
        (release.version, supported, true)
    } else {
        let version = value
            .get("version")
            .and_then(serde_json::Value::as_str)
            .ok_or(UpdateError::Verification("manifest_contract"))?;
        if version.len() > 64 {
            return Err(UpdateError::Verification("manifest_contract"));
        }
        Version::parse(version)?;
        (
            version.to_owned(),
            value
                .get("targets")
                .and_then(|targets| targets.get(current_target()))
                .is_some(),
            false,
        )
    };
    Ok(UpdateCheck {
        channel,
        current_version: env!("CARGO_PKG_VERSION").into(),
        latest_version: version.clone(),
        target: current_target().into(),
        supported,
        update_available: supported && newer(&version, env!("CARGO_PKG_VERSION"))?,
        verified,
    })
}

pub fn print_update_check(check: &UpdateCheck) {
    if !check.verified {
        println!("Mirror metadata is unverified. Installation requires signed release metadata.");
    }
    if check.update_available {
        println!(
            "Update available: v{} (current v{}). Run: inline update",
            check.latest_version, check.current_version
        );
    } else if !check.supported {
        println!("No release bundle for {}.", check.target);
    } else {
        println!(
            "inline is up to date on {} (v{}).",
            check.channel.as_str(),
            check.current_version
        );
    }
}
pub fn newer(candidate: &str, current: &str) -> Result<bool, UpdateError> {
    Ok(Version::parse(candidate)?
        .cmp_precedence(&Version::parse(current)?)
        .is_gt())
}

pub async fn perform(
    config: &Config,
    channel: UpdateChannel,
    background: bool,
) -> Result<Status, UpdateError> {
    let store = Store::new(&config.data_dir);
    if background && (!automatic_allowed() || !store.read()?.auto_update) {
        return status(config);
    }
    if background {
        let state = store.read()?;
        let now = current_epoch_seconds();
        if !check_due(&state, now, 3600) {
            return status(config);
        }
    }
    let _installation = match store.installation_lock() {
        Ok(lock) => lock,
        Err(UpdateError::Busy) if background => return status(config),
        Err(error) => return Err(error),
    };
    let revision = store.edit(|state| {
        if !store.root.join("update.json").exists() {
            state.channel = channel;
        }
        if state.channel != channel
            || (background
                && (!state.auto_update || !check_due(state, current_epoch_seconds(), 3600)))
        {
            return Ok(None);
        }
        state.last_attempt = Some(current_epoch_seconds());
        Ok(Some(state.revision))
    })?;
    let Some(revision) = revision else {
        return status(config);
    };
    let result = perform_inner(config, &store, channel, background, revision).await;
    if let Err(error) = &result {
        let now = current_epoch_seconds();
        let report = store
            .edit(|state| {
                let since = *state.failure_since.get_or_insert(now);
                state.failure = Some(error.stage().into());
                state.outcome = "retry_scheduled".into();
                state.consecutive_failures = state.consecutive_failures.saturating_add(1);
                state.retry_at = Some(
                    now + (300_i64
                        * (1_i64 << state.consecutive_failures.saturating_sub(1).min(7)))
                    .min(6 * 3600),
                );
                Ok(error.stage() != "network" || now - since >= 24 * 60 * 60)
            })
            .unwrap_or(false);
        if report {
            crate::telemetry::report_update(
                "failed",
                channel.as_str(),
                env!("CARGO_PKG_VERSION"),
                "unknown",
                error.stage(),
            );
        }
    }
    if let Err(error) = result {
        return if background {
            status(config)
        } else {
            Err(error)
        };
    }
    store.edit(|state| {
        state.last_success = Some(current_epoch_seconds());
        state.failure = None;
        state.failure_since = None;
        state.retry_at = None;
        state.consecutive_failures = 0;
        Ok(())
    })?;
    status(config)
}

async fn perform_inner(
    config: &Config,
    store: &Store,
    channel: UpdateChannel,
    background: bool,
    revision: u64,
) -> Result<(), UpdateError> {
    let release = fetch_release(config, channel).await?;
    let selected = next_release(&release, env!("CARGO_PKG_VERSION"))?;
    store.edit(|state| {
        state
            .highest_generation
            .insert(channel.as_str().into(), release.generation);
        state
            .accepted
            .insert(channel.as_str().into(), release.clone());
        state.latest = Some(release.clone());
        Ok(())
    })?;
    if !newer(&selected.version, env!("CARGO_PKG_VERSION"))? {
        store.edit(|state| {
            state.outcome = "current".into();
            Ok(())
        })?;
        return Ok(());
    }
    let target = selected
        .targets
        .get(current_target())
        .ok_or_else(|| UpdateError::MissingTarget(current_target().into()))?;
    let artifact = stage_release(store, selected, target).await?;
    if !background {
        enroll_current(store)?;
    }
    if publish_staged(store, &artifact, background, revision)? {
        let _ = cache::collect(store);
        crate::telemetry::report_update(
            "staged",
            channel.as_str(),
            env!("CARGO_PKG_VERSION"),
            &artifact.version,
            "verified",
        );
    }
    Ok(())
}

// Policy and pointer changes share the short settings transaction. The slow
// network, extraction and executable probes have already completed.
fn publish_staged(
    store: &Store,
    artifact: &Artifact,
    background: bool,
    revision: u64,
) -> Result<bool, UpdateError> {
    store.edit(|state| {
        if state.revision != revision || (background && !state.auto_update) {
            return Ok(false);
        }
        state.staged = Some(artifact.clone());
        state.outcome = "staged".into();
        for (path, old_hash) in &mut state.launchers {
            if installation_method(path, store) == "managed"
                && file_hash(path).ok().as_ref() == Some(old_hash)
            {
                copy_binary_atomically(&artifact.executable, path)?;
                *old_hash = artifact.executable_sha256.clone();
            }
        }
        Ok(true)
    })
}

fn next_release<'a>(
    release: &'a manifest::Release,
    current: &str,
) -> Result<&'a manifest::Release, UpdateError> {
    if let Some(baseline) = &release.required_baseline {
        if newer(&baseline.version, current)? {
            return next_release(baseline, current);
        }
    }
    Ok(release)
}

async fn stage_release(
    store: &Store,
    release: &manifest::Release,
    target: &manifest::Target,
) -> Result<Artifact, UpdateError> {
    let directory = store.root.join("versions").join(&target.sha256);
    let executable = directory.join("inline");
    if let Ok(artifact) = store::read_json::<Artifact>(&directory.join("receipt.json")) {
        if artifact.version == release.version
            && artifact.sha256 == target.sha256
            && artifact.executable == executable
            && file_hash(&executable).is_ok_and(|hash| hash == artifact.executable_sha256)
            && verify_executable(&executable, &release.version)
                .await
                .is_ok()
        {
            return Ok(artifact);
        }
        // Re-download a damaged cache from the authenticated target. Atomic
        // replacement retains open handles and never edits account data.
    }
    let temporary = create_temp_dir()?;
    let archive = temporary.path().join("inline.tar.gz");
    download_file(
        &UpdateTarget {
            url: target.url.clone(),
            sha256: target.sha256.clone(),
            size: Some(target.size),
        },
        &archive,
    )
    .await?;
    let extraction = temporary.path().join("extracted");
    fs::create_dir(&extraction)?;
    extract_archive(&archive, &extraction)?;
    let stage = stage_binary(&extraction.join("inline"), temporary.path())?;
    verify_executable(&stage, &release.version).await?;
    {
        let _versions = store::blocking_lock(&store.root.join("versions.lock"))?;
        store::private_dir(&directory)?;
        copy_binary_atomically(&stage, &executable)?;
    }
    verify_executable(&executable, &release.version).await?;
    let artifact = Artifact {
        version: release.version.clone(),
        target: current_target().into(),
        sha256: target.sha256.clone(),
        executable_sha256: file_hash(&executable)?,
        executable,
        bridge_schema_version: release.bridge_schema_version,
        minimum_reader_schema_version: release.minimum_reader_schema_version,
    };
    store::atomic_json(&directory.join("receipt.json"), &artifact)?;
    Ok(artifact)
}

pub fn file_hash(path: &Path) -> Result<String, UpdateError> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(bytes_to_hex(&hasher.finalize()))
}

pub fn installation_method(path: &Path, store: &Store) -> &'static str {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if [path, canonical.as_path()].iter().any(|path| {
        path.components()
            .any(|part| part.as_os_str() == "Cellar" || part.as_os_str() == "Caskroom")
    }) {
        return "homebrew";
    }
    if canonical.starts_with(store.root.join("versions")) {
        return "managed";
    }
    if fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return "external";
    }
    if store
        .read()
        .is_ok_and(|state| state.launchers.contains_key(path))
    {
        return "managed";
    }
    "external"
}

fn enroll_current(store: &Store) -> Result<(), UpdateError> {
    let path = std::env::current_exe()?;
    if path.starts_with(&store.root)
        || store
            .root
            .parent()
            .is_some_and(|data| crate::bridge::is_service_entry_point(data, &path))
        || installation_method(&path, store) == "homebrew"
    {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(&path)?;
    if !metadata.is_file() {
        return Ok(());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Ok(());
        }
    }
    let hash = file_hash(&path)?;
    store.edit(|state| {
        state.launchers.entry(path).or_insert(hash);
        Ok(())
    })
}

pub(crate) fn retain_running_binary(store: &Store) -> Result<Artifact, UpdateError> {
    let source = std::env::current_exe()?;
    let hash = file_hash(&source)?;
    let directory = store.root.join("versions").join(&hash);
    let executable = directory.join("inline");
    let artifact = Artifact {
        version: env!("CARGO_PKG_VERSION").into(),
        target: current_target().into(),
        sha256: hash.clone(),
        executable_sha256: hash,
        executable,
        bridge_schema_version: compatibility().bridge_schema_version,
        minimum_reader_schema_version: compatibility().minimum_reader_schema_version,
    };
    // Ordinary service startup must not need another durable write when its
    // retained engine is already verified, including after disk exhaustion.
    if store::read_json::<Artifact>(&directory.join("receipt.json"))
        .is_ok_and(|cached| cached == artifact)
        && validate_cached(store, &artifact).is_ok()
    {
        return Ok(artifact);
    }
    store::private_dir(&directory)?;
    if validate_cached(store, &artifact).is_err() {
        copy_binary_atomically(&source, &artifact.executable)?;
    }
    store::atomic_json(&directory.join("receipt.json"), &artifact)?;
    validate_cached(store, &artifact)?;
    Ok(artifact)
}

pub(crate) fn validate_cached(store: &Store, artifact: &Artifact) -> Result<(), UpdateError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let metadata = fs::symlink_metadata(&artifact.executable)?;
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o111 == 0
        {
            return Err(UpdateError::Verification("runtime_permissions"));
        }
    }
    if artifact.sha256.len() != 64
        || !artifact.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        || artifact.executable
            != store
                .root
                .join("versions")
                .join(&artifact.sha256)
                .join("inline")
        || !fs::symlink_metadata(&artifact.executable)?.is_file()
        || fs::canonicalize(&artifact.executable)?
            != fs::canonicalize(&store.root)?
                .join("versions")
                .join(&artifact.sha256)
                .join("inline")
        || file_hash(&artifact.executable)? != artifact.executable_sha256
    {
        return Err(UpdateError::Verification("runtime_identity"));
    }
    Ok(())
}

pub async fn verify_executable(path: &Path, version: &str) -> Result<(), UpdateError> {
    validate_binary(path)?;
    #[cfg(target_os = "macos")]
    {
        let result = tokio::time::timeout(Duration::from_secs(15), tokio::process::Command::new("/usr/bin/codesign").args(["--verify", "--strict", "--all-architectures", "-R=anchor apple generic and identifier \"chat.inline.cli\" and certificate leaf[subject.OU] = \"2487AN8AL4\""]).arg(path).stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true).status()).await.map_err(|_| UpdateError::Verification("codesign_timeout"))??;
        if !result.success() {
            return Err(UpdateError::Verification("codesign"));
        }
    }
    let output = bounded_probe(path).await?;
    if output.trim() != format!("inline {version}") {
        return Err(UpdateError::Verification("version_probe"));
    }
    Ok(())
}

async fn bounded_probe(path: &Path) -> Result<String, UpdateError> {
    let mut child = tokio::process::Command::new(path)
        .arg("--version")
        .env("INLINE_DISABLE_AUTOUPDATE", "1")
        .env("INLINE_CLI_TELEMETRY", "off")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    let mut output = child
        .stdout
        .take()
        .ok_or(UpdateError::Verification("version_probe"))?
        .take(4097);
    let mut bytes = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        output.read_to_end(&mut bytes).await?;
        let status = child.wait().await?;
        if !status.success() || bytes.len() > 4096 {
            return Err(io::Error::other("version probe failed"));
        }
        Ok(())
    })
    .await
    .map_err(|_| UpdateError::Verification("version_probe_timeout"))??;
    String::from_utf8(bytes).map_err(|_| UpdateError::Verification("version_probe"))
}

pub fn spawn_update_check(config: &Config, _db: &LocalDb, _json: bool) -> Option<JoinHandle<()>> {
    if !automatic_allowed() {
        return None;
    }
    let store = Store::new(&config.data_dir);
    let state = store.read().ok()?;
    if !state.auto_update
        || !check_due(&state, current_epoch_seconds(), CHECK_INTERVAL)
        || state.launchers.is_empty()
    {
        return None;
    }
    let mut command = std::process::Command::new(std::env::current_exe().ok()?);
    command
        .args(["update", "--background", "--json"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    if let Ok(mut child) = command.spawn() {
        // Long-lived MCP callers reap the worker; short-lived callers can exit
        // immediately without keeping a Tokio blocking worker alive.
        let _ = std::thread::Builder::new()
            .name("inline-update-reaper".into())
            .spawn(move || {
                let _ = child.wait();
            });
    }
    None
}
pub async fn finish_update_check(handle: Option<JoinHandle<()>>) {
    if let Some(handle) = handle {
        let _ = tokio::time::timeout(Duration::from_millis(150), handle).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn updater_activation_honors_opt_out_and_preserves_unowned_or_replaced_launchers() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path());
        let owned = root.path().join("inline");
        let changed = root.path().join("replaced");
        fs::write(&owned, "old").unwrap();
        fs::write(&changed, "old").unwrap();
        let candidate = root.path().join("candidate");
        fs::write(&candidate, "new").unwrap();
        let artifact = Artifact {
            version: "1.1.0".into(),
            target: "fixture".into(),
            sha256: "b".repeat(64),
            executable_sha256: file_hash(&candidate).unwrap(),
            executable: candidate,
            bridge_schema_version: 30,
            minimum_reader_schema_version: 30,
        };
        store
            .edit(|state| {
                state.launchers.insert(owned.clone(), file_hash(&owned)?);
                state
                    .launchers
                    .insert(changed.clone(), file_hash(&changed)?);
                Ok(())
            })
            .unwrap();
        fs::write(&changed, "installed-by-another-owner").unwrap();
        let mut config = Config::load();
        config.data_dir = root.path().to_path_buf();
        config.state_path = root.path().join("state.json");
        let before = store.read().unwrap().revision;
        configure(&config, Some(false), None, false, false).unwrap();
        assert!(!publish_staged(&store, &artifact, true, before).unwrap());
        assert_eq!(fs::read(&owned).unwrap(), b"old");
        assert!(store.read().unwrap().staged.is_none());
        let enabled = configure(&config, Some(true), None, false, false).unwrap();
        assert!(publish_staged(&store, &artifact, true, enabled.revision).unwrap());
        assert_eq!(fs::read(&owned).unwrap(), b"new");
        assert_eq!(fs::read(&changed).unwrap(), b"installed-by-another-owner");
        assert_eq!(store.read().unwrap().staged, Some(artifact));
    }

    #[test]
    fn updater_policy_changes_win_without_cancelling_for_redundant_configuration() {
        let root = tempfile::tempdir().unwrap();
        let mut config = Config::load();
        config.data_dir = root.path().to_path_buf();
        config.state_path = root.path().join("state.json");
        let first =
            configure(&config, Some(true), Some(UpdateChannel::Alpha), true, false).unwrap();
        let same = configure(&config, None, Some(UpdateChannel::Alpha), true, false).unwrap();
        assert_eq!(same.revision, first.revision);
        let off = configure(&config, Some(false), None, false, false).unwrap();
        assert!(off.revision > first.revision);
        assert!(!off.auto_update);
        configure(&config, None, Some(UpdateChannel::Stable), false, false).unwrap();
        let app = configure(&config, None, Some(UpdateChannel::Alpha), true, false).unwrap();
        assert_eq!(app.channel, UpdateChannel::Stable);
        assert!(!app.follows_app);
        assert!(!app.auto_update);
        follow_app(&config, UpdateChannel::Alpha).unwrap();
        let following = store::Store::new(root.path()).read().unwrap();
        assert!(following.follows_app);
        assert!(!following.channel_override);
        assert_eq!(following.channel, UpdateChannel::Alpha);
        assert!(!following.auto_update);
    }

    #[test]
    fn updater_retry_deadline_takes_precedence_over_normal_check_interval() {
        let mut state = store::State::default();
        state.last_attempt = Some(100);
        state.retry_at = Some(400);
        assert!(!check_due(&state, 399, CHECK_INTERVAL));
        assert!(check_due(&state, 400, CHECK_INTERVAL));
        state.retry_at = None;
        assert!(!check_due(&state, 400, CHECK_INTERVAL));
        assert!(check_due(&state, 100 + CHECK_INTERVAL, CHECK_INTERVAL));
    }

    #[test]
    fn semver_channels_do_not_downgrade_or_order_build_metadata() {
        assert!(!newer("1.2.3", "1.2.4-alpha.1").unwrap());
        assert!(newer("1.2.3", "1.2.3-alpha.8").unwrap());
        assert!(!newer("1.2.3+b", "1.2.3+a").unwrap());
    }
    #[test]
    fn foreign_and_homebrew_launchers_are_not_managed() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path());
        let foreign = root.path().join("inline");
        fs::write(&foreign, "foreign").unwrap();
        assert_eq!(installation_method(&foreign, &store), "external");
        #[cfg(unix)]
        {
            let brew = root.path().join("Caskroom/inline/version");
            fs::create_dir_all(&brew).unwrap();
            let binary = brew.join("inline");
            fs::write(&binary, "brew").unwrap();
            let launcher = root.path().join("brew-inline");
            std::os::unix::fs::symlink(&binary, &launcher).unwrap();
            assert_eq!(installation_method(&launcher, &store), "homebrew");
        }
    }
}

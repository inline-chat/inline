use std::env;
use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use inline_sdk::InlineProtocolAuthorization;
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AuthError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid saved Inline Protocol credential: {0}")]
    InvalidInlineProtocol(String),
    #[error("logout is in progress")]
    LogoutInProgress,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct SecretsFile {
    token: Option<String>,
    api_base_url: Option<String>,
    updated_at: Option<i64>,
    device_id: Option<String>,
    inline_protocol_permanent: Option<StoredInlineProtocolAuthorization>,
    inline_protocol_temporary: Option<StoredInlineProtocolAuthorization>,
    inline_protocol_pending_challenge: Option<String>,
    #[serde(default)]
    logout_in_progress: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredInlineProtocolAuthorization {
    key: String,
    key_id: String,
    server_salt: i64,
    temporary: bool,
    expires_at: Option<i32>,
}

impl From<&InlineProtocolAuthorization> for StoredInlineProtocolAuthorization {
    fn from(value: &InlineProtocolAuthorization) -> Self {
        Self {
            key: URL_SAFE_NO_PAD.encode(value.key),
            key_id: URL_SAFE_NO_PAD.encode(value.key_id),
            server_salt: value.server_salt,
            temporary: value.temporary,
            expires_at: value.expires_at,
        }
    }
}

impl TryFrom<StoredInlineProtocolAuthorization> for InlineProtocolAuthorization {
    type Error = AuthError;

    fn try_from(value: StoredInlineProtocolAuthorization) -> Result<Self, Self::Error> {
        let key: [u8; 256] = URL_SAFE_NO_PAD
            .decode(value.key)
            .map_err(|error| AuthError::InvalidInlineProtocol(error.to_string()))?
            .try_into()
            .map_err(|_| {
                AuthError::InvalidInlineProtocol("invalid authorization key length".into())
            })?;
        let key_id: [u8; 8] = URL_SAFE_NO_PAD
            .decode(value.key_id)
            .map_err(|error| AuthError::InvalidInlineProtocol(error.to_string()))?
            .try_into()
            .map_err(|_| AuthError::InvalidInlineProtocol("invalid key id length".into()))?;
        Ok(Self {
            key,
            key_id,
            server_salt: value.server_salt,
            temporary: value.temporary,
            expires_at: value.expires_at,
        })
    }
}

#[derive(Clone)]
pub struct AuthStore {
    path: PathBuf,
    api_base_url: String,
}

impl AuthStore {
    pub fn new(path: PathBuf, api_base_url: String) -> Self {
        Self { path, api_base_url }
    }

    pub fn load_token(&self) -> Result<Option<String>, AuthError> {
        if let Some(token) = load_env_token() {
            return Ok(Some(token));
        }

        self.load_saved_token()
    }

    pub fn load_saved_token(&self) -> Result<Option<String>, AuthError> {
        let secrets = match self.read_secrets()? {
            Some(secrets) => secrets,
            None => return Ok(None),
        };
        if secrets
            .api_base_url
            .as_deref()
            .is_some_and(|api_base_url| api_base_url != self.api_base_url)
        {
            return Ok(None);
        }
        if secrets.logout_in_progress {
            return Ok(None);
        }
        if secrets.inline_protocol_temporary.is_some() {
            return Ok(None);
        }
        Ok(secrets.token.filter(|token| !token.trim().is_empty()))
    }

    pub fn device_id(&self) -> Result<String, AuthError> {
        if let Ok(device_id) = env::var("INLINE_DEVICE_ID") {
            let device_id = device_id.trim().to_string();
            if !device_id.is_empty() {
                return Ok(device_id);
            }
        }

        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        if let Some(device_id) = secrets
            .device_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Ok(device_id.to_string());
        }

        let device_id = generate_device_id();
        secrets.device_id = Some(device_id.clone());
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)?;
        Ok(device_id)
    }

    pub fn store_token(&self, token: &str) -> Result<(), AuthError> {
        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        secrets.token = Some(token.to_string());
        secrets.inline_protocol_permanent = None;
        secrets.inline_protocol_temporary = None;
        secrets.inline_protocol_pending_challenge = None;
        secrets.logout_in_progress = false;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    pub fn store_inline_protocol_pending(
        &self,
        permanent: &InlineProtocolAuthorization,
        challenge_id: &[u8],
    ) -> Result<(), AuthError> {
        validate_permanent_authorization(permanent)?;
        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        secrets.inline_protocol_permanent = Some(permanent.into());
        secrets.inline_protocol_pending_challenge = Some(URL_SAFE_NO_PAD.encode(challenge_id));
        secrets.logout_in_progress = false;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    pub fn load_inline_protocol_pending(
        &self,
    ) -> Result<Option<(InlineProtocolAuthorization, Vec<u8>)>, AuthError> {
        let Some(secrets) = self.read_secrets_for_current_api()? else {
            return Ok(None);
        };
        if secrets.logout_in_progress {
            return Ok(None);
        }
        let (Some(permanent), Some(challenge)) = (
            secrets.inline_protocol_permanent,
            secrets.inline_protocol_pending_challenge,
        ) else {
            return Ok(None);
        };
        let challenge = URL_SAFE_NO_PAD
            .decode(challenge)
            .map_err(|error| AuthError::InvalidInlineProtocol(error.to_string()))?;
        let permanent = permanent.try_into()?;
        validate_permanent_authorization(&permanent)?;
        Ok(Some((permanent, challenge)))
    }

    pub fn store_inline_protocol_authorizations(
        &self,
        permanent: &InlineProtocolAuthorization,
        temporary: &InlineProtocolAuthorization,
    ) -> Result<(), AuthError> {
        validate_inline_protocol_authorizations(permanent, temporary)?;
        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        secrets.token = None;
        secrets.inline_protocol_permanent = Some(permanent.into());
        secrets.inline_protocol_temporary = Some(temporary.into());
        secrets.inline_protocol_pending_challenge = None;
        secrets.logout_in_progress = false;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    #[allow(dead_code)] // Retained for explicit credential inspection and compatibility tooling.
    pub fn load_inline_protocol_temporary(
        &self,
    ) -> Result<Option<InlineProtocolAuthorization>, AuthError> {
        let Some(secrets) = self.read_secrets_for_current_api()? else {
            return Ok(None);
        };
        if secrets.logout_in_progress {
            return Ok(None);
        }
        secrets
            .inline_protocol_temporary
            .map(TryInto::try_into)
            .transpose()
    }

    pub fn load_inline_protocol_authorizations(
        &self,
    ) -> Result<Option<(InlineProtocolAuthorization, InlineProtocolAuthorization)>, AuthError> {
        let Some(secrets) = self.read_secrets_for_current_api()? else {
            return Ok(None);
        };
        if secrets.logout_in_progress {
            return Ok(None);
        }
        let Some(temporary) = secrets.inline_protocol_temporary else {
            return Ok(None);
        };
        let permanent = secrets.inline_protocol_permanent.ok_or_else(|| {
            AuthError::InvalidInlineProtocol(
                "temporary authorization has no permanent owner".into(),
            )
        })?;
        let permanent = permanent.try_into()?;
        let temporary = temporary.try_into()?;
        validate_inline_protocol_authorizations(&permanent, &temporary)?;
        Ok(Some((permanent, temporary)))
    }

    pub fn clear_account_authority(&self) -> Result<(), AuthError> {
        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        secrets.token = None;
        secrets.inline_protocol_permanent = None;
        secrets.inline_protocol_temporary = None;
        secrets.inline_protocol_pending_challenge = None;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    pub fn begin_logout(&self) -> Result<(), AuthError> {
        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        secrets.logout_in_progress = true;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    pub fn logout_pending(&self) -> Result<bool, AuthError> {
        Ok(self
            .read_secrets_for_current_api()?
            .is_some_and(|secrets| secrets.logout_in_progress))
    }

    pub fn complete_logout(&self) -> Result<(), AuthError> {
        self.clear_token()
    }

    pub fn clear_token(&self) -> Result<(), AuthError> {
        let mut secrets = match self.read_secrets_for_current_api()? {
            Some(secrets) => secrets,
            None => return Ok(()),
        };

        secrets.token = None;
        secrets.inline_protocol_permanent = None;
        secrets.inline_protocol_temporary = None;
        secrets.inline_protocol_pending_challenge = None;
        secrets.logout_in_progress = false;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets_with_policy(&secrets, true)
    }

    fn read_secrets_for_current_api(&self) -> Result<Option<SecretsFile>, AuthError> {
        let secrets = match self.read_secrets()? {
            Some(secrets) => secrets,
            None => return Ok(None),
        };

        if secrets
            .api_base_url
            .as_deref()
            .is_some_and(|api_base_url| api_base_url != self.api_base_url)
        {
            return Ok(None);
        }

        Ok(Some(secrets))
    }

    fn read_secrets(&self) -> Result<Option<SecretsFile>, AuthError> {
        let contents = match fs::read_to_string(&self.path) {
            Ok(contents) => contents,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(AuthError::Io(err)),
        };

        Ok(Some(serde_json::from_str(&contents)?))
    }

    fn write_secrets(&self, secrets: &SecretsFile) -> Result<(), AuthError> {
        self.write_secrets_with_policy(secrets, false)
    }

    fn write_secrets_with_policy(
        &self,
        secrets: &SecretsFile,
        completes_logout: bool,
    ) -> Result<(), AuthError> {
        if let Some(parent) = self.path.parent() {
            ensure_dir(parent)?;
        }

        let _lock = lock_credentials_file(&self.path)?;
        let current = self.read_secrets()?;
        if current.is_some_and(|value| value.logout_in_progress)
            && !secrets.logout_in_progress
            && !completes_logout
        {
            return Err(AuthError::LogoutInProgress);
        }

        let payload = serde_json::to_string_pretty(secrets)?;
        atomic_replace(&self.path, payload.as_bytes())?;
        Ok(())
    }
}

fn lock_credentials_file(path: &Path) -> Result<File, io::Error> {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("credentials");
    let lock_path = path.with_file_name(format!(".{file_name}.lock"));
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(lock_path)?;
    set_file_permissions_handle(&lock, 0o600)?;
    lock_file_exclusive(&lock)?;
    Ok(lock)
}

fn atomic_replace(path: &Path, payload: &[u8]) -> Result<(), io::Error> {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("credentials");
    let mut random = [0_u8; 8];
    OsRng.fill_bytes(&mut random);
    let temporary_path = path.with_file_name(format!(
        ".{file_name}.{}.{}.tmp",
        std::process::id(),
        u64::from_le_bytes(random),
    ));
    let mut temporary = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary_path)?;
    set_file_permissions_handle(&temporary, 0o600)?;
    temporary.write_all(payload)?;
    temporary.sync_all()?;
    drop(temporary);
    fs::rename(&temporary_path, path)?;
    if let Some(parent) = path.parent() {
        File::open(parent)?.sync_all()?;
    }
    Ok(())
}

pub(crate) fn validate_inline_protocol_authorizations(
    permanent: &InlineProtocolAuthorization,
    temporary: &InlineProtocolAuthorization,
) -> Result<(), AuthError> {
    validate_permanent_authorization(permanent)?;
    if !temporary.temporary {
        return Err(AuthError::InvalidInlineProtocol(
            "temporary authorization is marked permanent".into(),
        ));
    }
    if temporary.expires_at.is_none() {
        return Err(AuthError::InvalidInlineProtocol(
            "temporary authorization has no expiry".into(),
        ));
    }
    Ok(())
}

fn validate_permanent_authorization(
    permanent: &InlineProtocolAuthorization,
) -> Result<(), AuthError> {
    if permanent.temporary || permanent.expires_at.is_some() {
        return Err(AuthError::InvalidInlineProtocol(
            "permanent authorization has temporary-key metadata".into(),
        ));
    }
    Ok(())
}

pub(crate) fn temporary_authorization_needs_regeneration(
    temporary: &InlineProtocolAuthorization,
    now_seconds: i64,
) -> bool {
    temporary
        .expires_at
        .is_none_or(|expires_at| i64::from(expires_at) <= now_seconds + 60)
}

pub fn env_token_present() -> bool {
    load_env_token().is_some()
}

fn load_env_token() -> Option<String> {
    env::var("INLINE_TOKEN")
        .ok()
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
}

fn ensure_dir(path: &Path) -> Result<(), io::Error> {
    fs::create_dir_all(path)?;
    set_dir_permissions(path, 0o700)?;
    Ok(())
}

fn current_epoch_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn generate_device_id() -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);

    let mut id = String::with_capacity("cli_".len() + bytes.len() * 2);
    id.push_str("cli_");
    for byte in bytes {
        let _ = write!(&mut id, "{byte:02x}");
    }
    id
}

#[cfg(unix)]
fn set_file_permissions_handle(file: &File, mode: u32) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    let perm = fs::Permissions::from_mode(mode);
    file.set_permissions(perm)
}

#[cfg(unix)]
fn lock_file_exclusive(file: &File) -> Result<(), io::Error> {
    use std::os::fd::AsRawFd;
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(unix)]
fn set_dir_permissions(path: &Path, mode: u32) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    let perm = fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perm)
}

#[cfg(not(unix))]
fn set_file_permissions_handle(_file: &File, _mode: u32) -> Result<(), io::Error> {
    Ok(())
}

#[cfg(not(unix))]
fn lock_file_exclusive(_file: &File) -> Result<(), io::Error> {
    Ok(())
}

#[cfg(not(unix))]
fn set_dir_permissions(_path: &Path, _mode: u32) -> Result<(), io::Error> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn authorization(seed: u8, temporary: bool) -> InlineProtocolAuthorization {
        InlineProtocolAuthorization {
            key: [seed; 256],
            key_id: [seed; 8],
            server_salt: i64::from(seed),
            temporary,
            expires_at: temporary.then_some(2_000_000_000),
        }
    }

    #[test]
    fn rejects_inverted_inline_protocol_key_roles() {
        let (_directory, store) = store();
        let error = store
            .store_inline_protocol_authorizations(&authorization(1, true), &authorization(2, false))
            .unwrap_err();

        assert!(matches!(error, AuthError::InvalidInlineProtocol(_)));
    }

    #[test]
    fn temporary_expiry_preflights_refresh_with_a_safety_window() {
        let temporary = authorization(2, true);
        assert!(!temporary_authorization_needs_regeneration(
            &temporary,
            1_999_999_939,
        ));
        assert!(temporary_authorization_needs_regeneration(
            &temporary,
            1_999_999_940,
        ));
    }

    fn store() -> (tempfile::TempDir, AuthStore) {
        let directory = tempfile::tempdir().expect("temporary auth directory");
        let store = AuthStore::new(
            directory.path().join("credentials.json"),
            "https://api.inline.test/v1".into(),
        );
        (directory, store)
    }

    #[test]
    fn v3_authority_clears_saved_bearer() {
        let (_directory, store) = store();
        store.store_token("legacy-token").expect("store bearer");
        store
            .store_inline_protocol_authorizations(&authorization(1, false), &authorization(2, true))
            .expect("store V3 authority");

        assert!(store.load_saved_token().expect("load bearer").is_none());
        assert!(
            store
                .load_inline_protocol_authorizations()
                .expect("load V3 authority")
                .is_some()
        );
    }

    #[test]
    fn bearer_authority_clears_saved_v3() {
        let (_directory, store) = store();
        store
            .store_inline_protocol_authorizations(&authorization(1, false), &authorization(2, true))
            .expect("store V3 authority");
        store.store_token("legacy-token").expect("store bearer");

        assert_eq!(
            store.load_saved_token().expect("load bearer").as_deref(),
            Some("legacy-token")
        );
        assert!(
            store
                .load_inline_protocol_authorizations()
                .expect("load V3 authority")
                .is_none()
        );
    }

    #[test]
    fn invalidation_clears_credentials_without_deleting_store() {
        let (_directory, store) = store();
        store
            .store_inline_protocol_authorizations(&authorization(1, false), &authorization(2, true))
            .expect("store V3 authority");
        store
            .clear_account_authority()
            .expect("clear account authority");

        assert!(store.path.exists());
        assert!(store.load_saved_token().expect("load bearer").is_none());
        assert!(
            store
                .load_inline_protocol_authorizations()
                .expect("load V3 authority")
                .is_none()
        );
    }

    #[test]
    fn logout_marker_blocks_and_then_clears_all_saved_authority() {
        let (_directory, store) = store();
        store
            .store_inline_protocol_authorizations(&authorization(1, false), &authorization(2, true))
            .expect("store V3 authority");

        store.begin_logout().expect("begin logout");

        assert!(store.logout_pending().expect("load logout marker"));
        assert!(store.load_saved_token().expect("load bearer").is_none());
        assert!(
            store
                .load_inline_protocol_authorizations()
                .expect("load V3 authority")
                .is_none()
        );

        store.complete_logout().expect("complete logout");

        assert!(!store.logout_pending().expect("load logout marker"));
        assert!(store.load_saved_token().expect("load bearer").is_none());
        assert!(
            store
                .load_inline_protocol_authorizations()
                .expect("load V3 authority")
                .is_none()
        );
    }

    #[test]
    fn stale_credential_writer_cannot_clear_a_logout_marker() {
        let (_directory, store) = store();
        store
            .store_inline_protocol_authorizations(&authorization(1, false), &authorization(2, true))
            .expect("store V3 authority");
        let mut stale = store
            .read_secrets_for_current_api()
            .expect("read authority")
            .expect("stored authority");

        store.begin_logout().expect("begin logout");
        stale.logout_in_progress = false;
        stale.updated_at = Some(current_epoch_seconds() as i64 + 1);
        assert!(matches!(
            store.write_secrets(&stale),
            Err(AuthError::LogoutInProgress)
        ));
        assert!(store.logout_pending().expect("marker remains durable"));

        store.complete_logout().expect("complete logout");
        assert!(!store.logout_pending().expect("marker cleared after purge"));
    }
}

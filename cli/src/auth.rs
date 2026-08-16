use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io;
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
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    pub fn store_inline_protocol_pending(
        &self,
        permanent: &InlineProtocolAuthorization,
        challenge_id: &[u8],
    ) -> Result<(), AuthError> {
        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        secrets.inline_protocol_permanent = Some(permanent.into());
        secrets.inline_protocol_pending_challenge = Some(URL_SAFE_NO_PAD.encode(challenge_id));
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
        let (Some(permanent), Some(challenge)) = (
            secrets.inline_protocol_permanent,
            secrets.inline_protocol_pending_challenge,
        ) else {
            return Ok(None);
        };
        let challenge = URL_SAFE_NO_PAD
            .decode(challenge)
            .map_err(|error| AuthError::InvalidInlineProtocol(error.to_string()))?;
        Ok(Some((permanent.try_into()?, challenge)))
    }

    pub fn store_inline_protocol_authorizations(
        &self,
        permanent: &InlineProtocolAuthorization,
        temporary: &InlineProtocolAuthorization,
    ) -> Result<(), AuthError> {
        let mut secrets = self.read_secrets_for_current_api()?.unwrap_or_default();
        secrets.inline_protocol_permanent = Some(permanent.into());
        secrets.inline_protocol_temporary = Some(temporary.into());
        secrets.inline_protocol_pending_challenge = None;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    pub fn load_inline_protocol_temporary(
        &self,
    ) -> Result<Option<InlineProtocolAuthorization>, AuthError> {
        let Some(secrets) = self.read_secrets_for_current_api()? else {
            return Ok(None);
        };
        secrets
            .inline_protocol_temporary
            .map(TryInto::try_into)
            .transpose()
    }

    pub fn clear_token(&self) -> Result<(), AuthError> {
        let mut secrets = match self.read_secrets_for_current_api()? {
            Some(secrets) => secrets,
            None => return Ok(()),
        };

        if secrets
            .device_id
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
            .is_empty()
        {
            match fs::remove_file(&self.path) {
                Ok(()) => return Ok(()),
                Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
                Err(err) => return Err(AuthError::Io(err)),
            }
        }

        secrets.token = None;
        secrets.inline_protocol_permanent = None;
        secrets.inline_protocol_temporary = None;
        secrets.inline_protocol_pending_challenge = None;
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
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
        if let Some(parent) = self.path.parent() {
            ensure_dir(parent)?;
        }

        let payload = serde_json::to_string_pretty(secrets)?;
        fs::write(&self.path, payload)?;
        set_file_permissions(&self.path, 0o600)?;
        Ok(())
    }
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
fn set_file_permissions(path: &Path, mode: u32) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    let perm = fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perm)
}

#[cfg(unix)]
fn set_dir_permissions(path: &Path, mode: u32) -> Result<(), io::Error> {
    use std::os::unix::fs::PermissionsExt;
    let perm = fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perm)
}

#[cfg(not(unix))]
fn set_file_permissions(_path: &Path, _mode: u32) -> Result<(), io::Error> {
    Ok(())
}

#[cfg(not(unix))]
fn set_dir_permissions(_path: &Path, _mode: u32) -> Result<(), io::Error> {
    Ok(())
}

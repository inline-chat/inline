use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AuthError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct SecretsFile {
    token: Option<String>,
    api_base_url: Option<String>,
    updated_at: Option<i64>,
    device_id: Option<String>,
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

        let secrets = match self.read_secrets()? {
            Some(secrets) => secrets,
            None => return Ok(None),
        };
        if let Some(api_base_url) = secrets.api_base_url.as_deref() {
            if api_base_url != self.api_base_url {
                return Ok(None);
            }
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
        secrets.api_base_url = Some(self.api_base_url.clone());
        secrets.updated_at = Some(current_epoch_seconds() as i64);
        self.write_secrets(&secrets)
    }

    fn read_secrets_for_current_api(&self) -> Result<Option<SecretsFile>, AuthError> {
        let secrets = match self.read_secrets()? {
            Some(secrets) => secrets,
            None => return Ok(None),
        };

        if let Some(api_base_url) = secrets.api_base_url.as_deref() {
            if api_base_url != self.api_base_url {
                return Ok(None);
            }
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

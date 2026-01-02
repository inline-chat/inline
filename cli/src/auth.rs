use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

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
        if let Ok(token) = env::var("INLINE_TOKEN") {
            if !token.trim().is_empty() {
                return Ok(Some(token));
            }
        }

        let contents = match fs::read_to_string(&self.path) {
            Ok(contents) => contents,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(AuthError::Io(err)),
        };

        let secrets: SecretsFile = serde_json::from_str(&contents)?;
        if let Some(api_base_url) = secrets.api_base_url.as_deref() {
            if api_base_url != self.api_base_url {
                return Ok(None);
            }
        }
        Ok(secrets.token.filter(|token| !token.trim().is_empty()))
    }

    pub fn store_token(&self, token: &str) -> Result<(), AuthError> {
        if let Some(parent) = self.path.parent() {
            ensure_dir(parent)?;
        }

        let secrets = SecretsFile {
            token: Some(token.to_string()),
            api_base_url: Some(self.api_base_url.clone()),
            updated_at: Some(current_epoch_seconds() as i64),
        };
        let payload = serde_json::to_string_pretty(&secrets)?;
        fs::write(&self.path, payload)?;
        set_file_permissions(&self.path, 0o600)?;
        Ok(())
    }

    pub fn clear_token(&self) -> Result<(), AuthError> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(AuthError::Io(err)),
        }
    }
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

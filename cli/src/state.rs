use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::protocol::proto;

#[derive(Debug, Error)]
pub enum StateError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct LocalState {
    pub current_user: Option<proto::User>,
    pub api_base_url: Option<String>,
    pub updated_at: Option<i64>,
    pub release_manifest_url: Option<String>,
    pub last_update_check_at: Option<i64>,
    pub last_update_notified_version: Option<String>,
    pub last_seen_release_version: Option<String>,
}

#[derive(Clone)]
pub struct LocalDb {
    path: PathBuf,
    api_base_url: String,
}

impl LocalDb {
    pub fn new(path: PathBuf, api_base_url: String) -> Self {
        Self { path, api_base_url }
    }

    pub fn load(&self) -> Result<LocalState, StateError> {
        let contents = match fs::read_to_string(&self.path) {
            Ok(contents) => contents,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(LocalState::default()),
            Err(err) => return Err(StateError::Io(err)),
        };
        let state: LocalState = serde_json::from_str(&contents)?;
        if let Some(api_base_url) = state.api_base_url.as_deref() {
            if api_base_url != self.api_base_url {
                return Ok(LocalState::default());
            }
        }
        Ok(state)
    }

    pub fn save(&self, state: &LocalState) -> Result<(), StateError> {
        if let Some(parent) = self.path.parent() {
            ensure_dir(parent)?;
        }
        let payload = serde_json::to_string_pretty(state)?;
        fs::write(&self.path, payload)?;
        set_file_permissions(&self.path, 0o600)?;
        Ok(())
    }

    pub fn set_current_user(&self, user: proto::User) -> Result<(), StateError> {
        let mut state = self.load()?;
        state.current_user = Some(user);
        state.api_base_url = Some(self.api_base_url.clone());
        state.updated_at = Some(current_epoch_seconds() as i64);
        self.save(&state)
    }

    pub fn clear_current_user(&self) -> Result<(), StateError> {
        let mut state = self.load()?;
        state.current_user = None;
        state.api_base_url = Some(self.api_base_url.clone());
        state.updated_at = Some(current_epoch_seconds() as i64);
        self.save(&state)
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

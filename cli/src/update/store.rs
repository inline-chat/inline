use super::{UpdateChannel, UpdateError, manifest::Release};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub schema_version: u32,
    pub auto_update: bool,
    pub channel: UpdateChannel,
    pub follows_app: bool,
    pub channel_override: bool,
    pub revision: u64,
    pub launchers: BTreeMap<PathBuf, String>,
    pub highest_generation: BTreeMap<String, u64>,
    pub latest: Option<Release>,
    pub accepted: BTreeMap<String, Release>,
    pub staged: Option<Artifact>,
    pub last_attempt: Option<i64>,
    pub last_success: Option<i64>,
    pub failure_since: Option<i64>,
    pub retry_at: Option<i64>,
    pub consecutive_failures: u32,
    pub outcome: String,
    pub failure: Option<String>,
}

impl Default for State {
    fn default() -> Self {
        Self {
            schema_version: 1,
            auto_update: true,
            channel: UpdateChannel::resolve(None, env!("CARGO_PKG_VERSION")),
            follows_app: false,
            channel_override: false,
            revision: 0,
            launchers: BTreeMap::new(),
            highest_generation: BTreeMap::new(),
            latest: None,
            accepted: BTreeMap::new(),
            staged: None,
            last_attempt: None,
            last_success: None,
            failure_since: None,
            retry_at: None,
            consecutive_failures: 0,
            outcome: "not_checked".into(),
            failure: None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Artifact {
    pub version: String,
    pub target: String,
    pub sha256: String,
    pub executable_sha256: String,
    pub executable: PathBuf,
    pub bridge_schema_version: u32,
    pub minimum_reader_schema_version: u32,
}

#[derive(Clone)]
pub struct Store {
    pub root: PathBuf,
}

impl Store {
    pub fn new(data: &Path) -> Self {
        Self {
            root: data.join("runtime"),
        }
    }
    pub fn read(&self) -> Result<State, UpdateError> {
        match read_json(&self.root.join("update.json")) {
            Ok(state) => {
                let state: State = state;
                if state.schema_version != 1 {
                    return Err(UpdateError::Verification("state_version"));
                }
                Ok(state)
            }
            Err(UpdateError::Io(error)) if error.kind() == io::ErrorKind::NotFound => {
                Ok(State::default())
            }
            Err(error) => Err(error),
        }
    }
    pub fn edit<T>(
        &self,
        body: impl FnOnce(&mut State) -> Result<T, UpdateError>,
    ) -> Result<T, UpdateError> {
        private_dir(&self.root)?;
        let _lock = lock(&self.root.join("settings.lock"))?;
        let mut state = self.read()?;
        let result = body(&mut state)?;
        atomic_json(&self.root.join("update.json"), &state)?;
        Ok(result)
    }
    pub fn installation_lock(&self) -> Result<File, UpdateError> {
        private_dir(&self.root)?;
        lock(&self.root.join("install.lock"))
    }
}

pub fn private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() {
        return Err(io::Error::other("unsafe runtime directory"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::other("runtime directory has a different owner"));
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

pub fn lock(path: &Path) -> Result<File, UpdateError> {
    if fs::symlink_metadata(path).is_ok_and(|m| !m.is_file()) {
        return Err(UpdateError::Verification("unsafe_lock"));
    }
    let mut options = OpenOptions::new();
    options.create(true).read(true).write(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path)?;
    file.try_lock().map_err(|_| UpdateError::Busy)?;
    Ok(file)
}

pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, UpdateError> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.len() > 512 * 1024 {
        return Err(UpdateError::Verification("unsafe_state"));
    }
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

pub fn atomic_json(path: &Path, value: &impl Serialize) -> Result<(), UpdateError> {
    atomic_bytes(path, &serde_json::to_vec_pretty(value)?, 0o600)?;
    Ok(())
}

pub fn atomic_bytes(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("missing parent"))?;
    private_dir(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.as_file()
            .set_permissions(fs::Permissions::from_mode(mode))?;
    }
    file.as_file().sync_all()?;
    file.persist(path).map_err(|error| error.error)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn settings_are_private_atomic_and_lock_contention_cannot_lose_changes() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path());
        store
            .edit(|state| {
                state.auto_update = false;
                state.revision += 1;
                Ok(())
            })
            .unwrap();
        let before = fs::read(store.root.join("update.json")).unwrap();
        let held = lock(&store.root.join("settings.lock")).unwrap();
        assert!(matches!(
            store.edit(|state| {
                state.auto_update = true;
                Ok(())
            }),
            Err(UpdateError::Busy)
        ));
        assert_eq!(fs::read(store.root.join("update.json")).unwrap(), before);
        drop(held);
        assert!(!store.read().unwrap().auto_update);
    }
}

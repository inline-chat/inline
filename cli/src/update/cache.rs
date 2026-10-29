//! Conservative collection: keep every selection and the retained supervisor.
use super::{Artifact, Store, UpdateError, store, validate_cached};
use serde::Deserialize;
use std::{
    collections::HashSet,
    fs,
    time::{Duration, SystemTime},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Selections {
    schema_version: u32,
    current: Artifact,
    previous: Option<Artifact>,
    candidate: Option<Artifact>,
    #[serde(default)]
    supervisor: Option<Artifact>,
}

pub(super) fn collect(store: &Store) -> Result<(), UpdateError> {
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(7 * 24 * 60 * 60))
        .unwrap_or(SystemTime::UNIX_EPOCH);
    collect_before(store, cutoff)
}

fn collect_before(store: &Store, cutoff: SystemTime) -> Result<(), UpdateError> {
    let _versions = store::blocking_lock(&store.root.join("versions.lock"))?;
    let mut keep = HashSet::new();
    if let Some(staged) = store.read()?.staged {
        keep.insert(staged.sha256);
    }
    // Do not remove the engine running this collection, including an app's
    // private helper that is about to return its operation result.
    if let (Ok(exe), Ok(root)) = (
        std::env::current_exe().and_then(fs::canonicalize),
        fs::canonicalize(&store.root),
    ) && let Ok(relative) = exe.strip_prefix(root.join("versions"))
        && let Some(hash) = relative.components().next()
    {
        keep.insert(hash.as_os_str().to_string_lossy().into_owned());
    }
    let Some(data) = store.root.parent() else {
        return Ok(());
    };
    let bridge = data.join("bridge");
    let mut accounts = Vec::new();
    if bridge.is_dir() {
        for entry in fs::read_dir(&bridge)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            if entry.file_name() == "accounts" {
                for account in fs::read_dir(entry.path())? {
                    let account = account?;
                    if account.file_type()?.is_dir() {
                        accounts.push(account.path());
                    }
                }
            } else {
                accounts.push(entry.path());
            }
        }
    }
    for account in accounts {
        let journal = account.join("activation.json");
        if !journal.exists() {
            // A legacy service may use an older private runtime. Enroll it
            // before collecting versions whose ownership is still ambiguous.
            if account.join("config.json").exists() {
                return Ok(());
            }
            continue;
        }
        #[derive(Deserialize)]
        struct PendingStart {
            candidate: Artifact,
        }
        if account.join("startup.json").is_file() {
            let pending: PendingStart = store::read_json(&account.join("startup.json"))?;
            keep.insert(pending.candidate.sha256);
        }
        let selection: Selections = store::read_json(&journal)?;
        if selection.schema_version != 1 || selection.supervisor.is_none() {
            return Ok(());
        }
        for artifact in [
            Some(selection.current),
            selection.previous,
            selection.candidate,
            selection.supervisor,
        ]
        .into_iter()
        .flatten()
        {
            keep.insert(artifact.sha256);
        }
    }
    let versions = store.root.join("versions");
    if !fs::symlink_metadata(&versions).is_ok_and(|metadata| metadata.is_dir()) {
        return Ok(());
    }
    for entry in fs::read_dir(&versions)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir()
            || keep.contains(&entry.file_name().to_string_lossy().into_owned())
        {
            continue;
        }
        let directory = entry.path();
        if entry.metadata()?.modified()? >= cutoff {
            continue;
        }
        let Ok(receipt) = store::read_json::<Artifact>(&directory.join("receipt.json")) else {
            continue;
        };
        if receipt.sha256 != entry.file_name().to_string_lossy()
            || validate_cached(store, &receipt).is_err()
        {
            continue;
        }
        // Never collect user-added files or traverse arbitrary directories.
        if fs::read_dir(&directory)?.any(|item| {
            item.map_or(true, |item| {
                !matches!(item.file_name().to_str(), Some("inline" | "receipt.json"))
            })
        }) {
            continue;
        }
        fs::remove_file(directory.join("inline"))?;
        fs::remove_file(directory.join("receipt.json"))?;
        fs::remove_dir(directory)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn updater_cache_keeps_current_previous_candidate_supervisor_and_unknown_user_files() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::new(root.path());
        store.edit(|_| Ok(())).unwrap();
        let make = |id: u8| {
            let hash = super::super::transfer::bytes_to_hex(&sha2::Sha256::digest([id]));
            let dir = store.root.join("versions").join(&hash);
            store::private_dir(&dir).unwrap();
            let executable = dir.join("inline");
            fs::write(&executable, [id]).unwrap();
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
            let artifact = Artifact {
                version: format!("1.0.{id}"),
                target: "fixture".into(),
                sha256: hash.clone(),
                executable_sha256: hash,
                executable,
                bridge_schema_version: 30,
                minimum_reader_schema_version: 30,
            };
            store::atomic_json(&dir.join("receipt.json"), &artifact).unwrap();
            artifact
        };
        use sha2::Digest;
        let guard = make(1);
        let current = make(2);
        let previous = make(3);
        let candidate = make(4);
        let staged = make(5);
        let orphan = make(6);
        let user = make(7);
        store
            .edit(|s| {
                s.staged = Some(staged.clone());
                Ok(())
            })
            .unwrap();
        let account = root.path().join("bridge/accounts/1");
        store::private_dir(&account).unwrap();
        store::atomic_json(&account.join("activation.json"), &serde_json::json!({"schemaVersion":1,"current":current,"previous":previous,"candidate":candidate,"supervisor":guard})).unwrap();
        fs::write(user.executable.parent().unwrap().join("user-note"), "keep").unwrap();
        collect_before(&store, SystemTime::now() + Duration::from_secs(1)).unwrap();
        for artifact in [guard, current, previous, candidate, staged, user] {
            assert!(artifact.executable.exists());
        }
        assert!(!orphan.executable.exists());
    }
}

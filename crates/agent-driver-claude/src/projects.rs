//! Saved Claude Code project roots, without reading session transcripts or
//! retaining the per-project settings and credentials in `.claude.json`.

use std::collections::{BTreeMap, HashSet};
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use inline_agent_bridge::harness::CatalogFolder;
use serde::Deserialize;
use serde::de::IgnoredAny;

const MAX_CONFIG_BYTES: u64 = 8 * 1024 * 1024;
const MAX_PROJECTS: usize = 1_000;

#[derive(Deserialize)]
struct SavedProjects {
    #[serde(default)]
    projects: BTreeMap<String, IgnoredAny>,
}

pub(crate) fn folders(env: &[(OsString, OsString)]) -> Vec<CatalogFolder> {
    let Some(path) = config_path(env) else {
        return Vec::new();
    };
    match read_folders(&path) {
        Ok(folders) => folders,
        Err(_) => {
            // Never log file contents: the same file contains account state.
            log::warn!("Claude saved projects could not be read");
            Vec::new()
        }
    }
}

fn config_path(env: &[(OsString, OsString)]) -> Option<PathBuf> {
    let configured = env
        .iter()
        .rev()
        .find(|(name, _)| name == "CLAUDE_CONFIG_DIR")
        .map(|(_, value)| value.clone())
        .or_else(|| std::env::var_os("CLAUDE_CONFIG_DIR"))
        .filter(|value| !value.is_empty());
    let path = match configured {
        Some(dir) => PathBuf::from(dir).join(".claude.json"),
        None => PathBuf::from(std::env::var_os("HOME")?).join(".claude.json"),
    };
    path.is_absolute().then_some(path)
}

fn read_folders(path: &Path) -> io::Result<Vec<CatalogFolder>> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut bytes = Vec::new();
    file.take(MAX_CONFIG_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_CONFIG_BYTES {
        return Err(io::Error::other(
            "Claude project state exceeds the supported size",
        ));
    }
    let saved: SavedProjects = serde_json::from_slice(&bytes)
        .map_err(|_| io::Error::other("Claude saved projects could not be read"))?;
    if saved.projects.len() > MAX_PROJECTS {
        return Err(io::Error::other("Claude has more than 1000 saved projects"));
    }
    let mut seen = HashSet::new();
    Ok(saved
        .projects
        .into_keys()
        .filter(|root| Path::new(root).is_absolute())
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .filter(|path| path.is_dir() && path.parent().is_some())
        .filter(|path| seen.insert(path.clone()))
        .map(|path| CatalogFolder {
            label: path.file_name().unwrap().to_string_lossy().into_owned(),
            path,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn saved_projects_are_verified_deduplicated_and_read_only() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("inline");
        std::fs::create_dir(&project).unwrap();
        let state = json!({
            "accountState": {"ignored": true},
            "projects": {
                project.to_str().unwrap(): {"hasTrustDialogAccepted": true},
                project.join(".").to_str().unwrap(): {},
                dir.path().join("gone").to_str().unwrap(): {},
                "relative": {},
                "/": {},
            }
        })
        .to_string();
        let path = dir.path().join(".claude.json");
        std::fs::write(&path, &state).unwrap();
        let folders = read_folders(&path).unwrap();
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].label, "inline");
        assert_eq!(folders[0].path, std::fs::canonicalize(project).unwrap());
        assert_eq!(std::fs::read_to_string(path).unwrap(), state);
    }

    #[test]
    fn custom_config_directory_uses_its_own_global_state() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            config_path(&[("CLAUDE_CONFIG_DIR".into(), dir.path().into())]),
            Some(dir.path().join(".claude.json")),
        );
        assert_eq!(
            config_path(&[("CLAUDE_CONFIG_DIR".into(), "relative".into())]),
            None
        );
    }

    #[test]
    fn missing_invalid_and_oversized_state_is_bounded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".claude.json");
        assert!(read_folders(&path).unwrap().is_empty());
        std::fs::write(&path, b"{invalid").unwrap();
        assert!(read_folders(&path).is_err());
        std::fs::write(&path, vec![b' '; MAX_CONFIG_BYTES as usize + 1]).unwrap();
        assert!(read_folders(&path).is_err());
    }
}

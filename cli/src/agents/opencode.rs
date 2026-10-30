//! Inventory both generations, while selecting only v2 for new bridge setup.

use std::collections::HashSet;
use std::path::PathBuf;

use inline_agent_driver_acp::{OPENCODE_MIGRATION_URL, parse_opencode_version};
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OpenCodeInstallation {
    #[serde(skip)]
    pub(crate) executable: PathBuf,
    pub(crate) version: Option<String>,
    pub(crate) major_version: Option<u64>,
    pub(crate) support_status: OpenCodeSupport,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) migration_url: Option<&'static str>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OpenCodeSupport {
    Supported,
    MigrationRequired,
    Unsupported,
    Unknown,
}

impl OpenCodeInstallation {
    fn new(executable: PathBuf, version: Option<String>) -> Self {
        let major_version = version
            .as_deref()
            .and_then(parse_opencode_version)
            .map(|v| v.major);
        let support_status = match major_version {
            Some(2) => OpenCodeSupport::Supported,
            Some(1) => OpenCodeSupport::MigrationRequired,
            Some(_) => OpenCodeSupport::Unsupported,
            None => OpenCodeSupport::Unknown,
        };
        Self {
            executable,
            version,
            major_version,
            support_status,
            migration_url: (support_status == OpenCodeSupport::MigrationRequired)
                .then_some(OPENCODE_MIGRATION_URL),
        }
    }
}

pub(crate) fn installations() -> Vec<OpenCodeInstallation> {
    discover(
        super::discovery::search_directories(),
        crate::bridge::opencode_version,
    )
}

fn discover(
    directories: impl IntoIterator<Item = PathBuf>,
    mut probe: impl FnMut(&std::path::Path) -> Option<String>,
) -> Vec<OpenCodeInstallation> {
    let mut seen = HashSet::new();
    let mut found = Vec::new();
    for directory in directories {
        for name in ["opencode", "opencode2"] {
            let path = directory.join(name);
            if !super::discovery::is_executable(&path) {
                continue;
            }
            let identity = path.canonicalize().unwrap_or_else(|_| path.clone());
            if seen.insert(identity) {
                found.push(OpenCodeInstallation::new(path.clone(), probe(&path)));
            }
            // Discovery is diagnostic, not an unbounded PATH scan of processes.
            if found.len() == 8 {
                return found;
            }
        }
    }
    found
}

pub(crate) fn selected(installations: &[OpenCodeInstallation]) -> Option<&OpenCodeInstallation> {
    installations
        .iter()
        .find(|item| item.support_status == OpenCodeSupport::Supported)
        .or_else(|| installations.first())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn inventories_both_majors_and_prefers_v2_even_when_v1_is_first() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let temp = tempfile::tempdir().unwrap();
        for name in ["opencode", "opencode2"] {
            let path = temp.path().join(name);
            std::fs::write(&path, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let alias = temp.path().join("alias");
        std::fs::create_dir(&alias).unwrap();
        symlink(temp.path().join("opencode2"), alias.join("opencode")).unwrap();
        let found = discover([temp.path().to_path_buf(), alias], |path| {
            Some(
                if path.ends_with("opencode2") {
                    "2.0.32"
                } else {
                    "1.19.4"
                }
                .into(),
            )
        });
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].support_status, OpenCodeSupport::MigrationRequired);
        assert_eq!(selected(&found).unwrap().major_version, Some(2));
        let json = serde_json::to_string(&found).unwrap();
        assert!(json.contains("migration_required"));
        assert!(!json.contains(temp.path().to_str().unwrap()));
    }

    #[test]
    fn unknown_and_future_versions_are_not_supported() {
        for (version, expected) in [
            (None, OpenCodeSupport::Unknown),
            (Some("3.0.0"), OpenCodeSupport::Unsupported),
        ] {
            let installation =
                OpenCodeInstallation::new("opencode".into(), version.map(str::to_owned));
            assert_eq!(installation.support_status, expected);
        }
    }
}

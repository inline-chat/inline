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
            Some(0 | 1) => OpenCodeSupport::MigrationRequired,
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

/// Setup and dry-run use the same authoritative choice. Inventory is limited
/// to a short probe; unknown candidates need the full startup budget before a
/// known legacy installation can establish that v2 is unavailable.
pub(crate) fn select_for_setup(
    installations: &[OpenCodeInstallation],
) -> Result<OpenCodeInstallation, String> {
    select_for_setup_with_probe(installations, |path| {
        crate::bridge::opencode_startup_version(path).map_err(|error| error.to_string())
    })
}

fn select_for_setup_with_probe(
    installations: &[OpenCodeInstallation],
    mut probe: impl FnMut(&std::path::Path) -> Result<String, String>,
) -> Result<OpenCodeInstallation, String> {
    let installations = &installations[..installations.len().min(8)];
    if let Some(supported) = installations
        .iter()
        .find(|item| item.support_status == OpenCodeSupport::Supported)
    {
        return Ok(supported.clone());
    }
    let mut rejected = installations.first().cloned();
    let mut unavailable = None;
    for candidate in installations
        .iter()
        .filter(|item| item.support_status == OpenCodeSupport::Unknown)
    {
        let version = match probe(&candidate.executable) {
            Ok(version) => version,
            Err(error) => {
                unavailable = Some(error);
                continue;
            }
        };
        let verified = OpenCodeInstallation::new(candidate.executable.clone(), Some(version));
        if verified.support_status == OpenCodeSupport::Supported {
            return Ok(verified);
        }
        if verified.support_status == OpenCodeSupport::Unknown {
            unavailable = Some("OpenCode returned an unrecognized version".to_string());
        } else {
            rejected = Some(verified);
        }
    }
    if let Some(error) = unavailable {
        return Err(format!(
            "Could not verify an OpenCode installation: {error}. Retry setup after `opencode --version` succeeds; OpenCode v2 is required."
        ));
    }
    if let Some(rejected) = rejected {
        inline_agent_driver_acp::require_opencode_v2(
            rejected.version.as_deref().unwrap_or_default(),
        )?;
    }
    Err("OpenCode v2 is not installed; install it from https://opencode.ai/v2/docs, then rerun `inline setup opencode`".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_rechecks_unknown_v2_after_a_fast_legacy_installation() {
        let installations = vec![
            OpenCodeInstallation::new("/fast/opencode".into(), Some("1.19.4".into())),
            OpenCodeInstallation::new("/slow/opencode2".into(), None),
        ];
        let mut probed = Vec::new();
        let chosen = select_for_setup_with_probe(&installations, |path| {
            probed.push(path.to_path_buf());
            Ok("opencode v2.0.32".to_string())
        })
        .unwrap();
        assert_eq!(chosen.executable, PathBuf::from("/slow/opencode2"));
        assert_eq!(chosen.support_status, OpenCodeSupport::Supported);
        assert_eq!(probed, vec![PathBuf::from("/slow/opencode2")]);
    }

    #[test]
    fn setup_prefers_verified_v2_without_waiting_on_unknown_candidates() {
        let installations = vec![
            OpenCodeInstallation::new("/unknown/opencode".into(), None),
            OpenCodeInstallation::new("/known/opencode2".into(), Some("2.0.32".into())),
        ];
        let chosen = select_for_setup_with_probe(&installations, |_| {
            panic!("a verified v2 candidate needs no slow discovery retry")
        })
        .unwrap();
        assert_eq!(chosen.executable, PathBuf::from("/known/opencode2"));
    }

    #[test]
    fn setup_keeps_searching_after_an_unavailable_unknown_candidate() {
        let installations = vec![
            OpenCodeInstallation::new("/failed/opencode".into(), None),
            OpenCodeInstallation::new("/working/opencode2".into(), None),
        ];
        let chosen = select_for_setup_with_probe(&installations, |path| {
            if path == std::path::Path::new("/failed/opencode") {
                Err("version probe timed out".to_string())
            } else {
                Ok("2.0.32".to_string())
            }
        })
        .unwrap();
        assert_eq!(chosen.executable, PathBuf::from("/working/opencode2"));
    }

    #[test]
    fn setup_bounds_reprobes_and_does_not_mislabel_unavailable_candidates_as_legacy_only() {
        let installations = (0..10)
            .map(|index| {
                OpenCodeInstallation::new(format!("/unknown-{index}/opencode").into(), None)
            })
            .collect::<Vec<_>>();
        let mut probes = 0;
        let error = select_for_setup_with_probe(&installations, |_| {
            probes += 1;
            Err("version probe timed out".to_string())
        })
        .unwrap_err();
        assert_eq!(probes, 8);
        assert!(error.contains("Could not verify"));
        assert!(error.contains("timed out"));
        assert!(!error.contains("not installed"));
    }

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

    #[test]
    fn legacy_zero_major_is_inventoried_with_migration_guidance() {
        let installation = OpenCodeInstallation::new("opencode".into(), Some("0.15.0".into()));
        assert_eq!(
            installation.support_status,
            OpenCodeSupport::MigrationRequired
        );
        assert_eq!(installation.migration_url, Some(OPENCODE_MIGRATION_URL));
    }
}

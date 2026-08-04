use std::collections::HashSet;
use std::env;
use std::path::{Path, PathBuf};

use super::catalog::{AgentTarget, TARGETS, TargetDescriptor};

#[derive(Clone, Debug)]
pub(crate) struct InstalledTarget {
    pub(crate) descriptor: &'static TargetDescriptor,
    pub(crate) executable: PathBuf,
}

pub(crate) fn installed_targets() -> Vec<InstalledTarget> {
    TARGETS
        .iter()
        .filter_map(|descriptor| {
            find_executable(descriptor.executable).map(|executable| InstalledTarget {
                descriptor,
                executable,
            })
        })
        .collect()
}

pub(crate) fn installed_target(target: AgentTarget) -> Option<InstalledTarget> {
    let descriptor = target.descriptor();
    find_executable(descriptor.executable).map(|executable| InstalledTarget {
        descriptor,
        executable,
    })
}

pub(super) fn find_executable(name: &str) -> Option<PathBuf> {
    find_executable_in(name, search_directories())
}

fn find_executable_in(
    name: &str,
    directories: impl IntoIterator<Item = PathBuf>,
) -> Option<PathBuf> {
    directories
        .into_iter()
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable(candidate))
}

fn search_directories() -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut directories = Vec::new();
    if let Some(path) = env::var_os("PATH") {
        for directory in env::split_paths(&path) {
            if seen.insert(directory.clone()) {
                directories.push(directory);
            }
        }
    }
    for directory in [
        Some(PathBuf::from("/opt/homebrew/bin")),
        Some(PathBuf::from("/usr/local/bin")),
        home_bin(".local/bin"),
        home_bin(".bun/bin"),
        home_bin(".local/share/pnpm"),
        home_bin(".claude/local"),
        home_bin(".opencode/bin"),
        home_bin(".amp/bin"),
        home_bin(".hermes/bin"),
    ]
    .into_iter()
    .flatten()
    {
        if seen.insert(directory.clone()) {
            directories.push(directory);
        }
    }
    directories
}

fn home_bin(relative: &str) -> Option<PathBuf> {
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .map(|home| home.join(relative))
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(windows)]
fn is_executable(path: &Path) -> bool {
    path.is_file() || path.with_extension("exe").is_file()
}

#[cfg(not(any(unix, windows)))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[cfg(unix)]
    fn make_executable(path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        fs::write(path, "#!/bin/sh\n").expect("write executable fixture");
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .expect("make fixture executable");
    }

    #[test]
    fn catalog_runtime_names_are_user_installed_clis() {
        assert_eq!(AgentTarget::Claude.descriptor().executable, "claude");
        assert_eq!(AgentTarget::Amp.descriptor().executable, "amp");
    }

    #[cfg(unix)]
    #[test]
    fn executable_discovery_uses_the_first_matching_directory() {
        let first = tempfile::tempdir().expect("first directory");
        let second = tempfile::tempdir().expect("second directory");
        make_executable(&first.path().join("hermes"));
        make_executable(&second.path().join("hermes"));

        assert_eq!(
            find_executable_in(
                "hermes",
                [first.path().to_path_buf(), second.path().to_path_buf()]
            ),
            Some(first.path().join("hermes"))
        );
        assert_eq!(
            find_executable_in("openclaw", [first.path().to_path_buf()]),
            None
        );
    }
}

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
            find_target_executable(descriptor).map(|executable| InstalledTarget {
                descriptor,
                executable,
            })
        })
        .collect()
}

pub(crate) fn installed_target(target: AgentTarget) -> Option<InstalledTarget> {
    let descriptor = target.descriptor();
    find_target_executable(descriptor).map(|executable| InstalledTarget {
        descriptor,
        executable,
    })
}

fn find_target_executable(descriptor: &'static TargetDescriptor) -> Option<PathBuf> {
    find_executable(descriptor.executable).or_else(|| {
        (descriptor.target == AgentTarget::Codex)
            .then(find_chatgpt_codex_executable)
            .flatten()
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

#[cfg(target_os = "macos")]
fn find_executable_candidate(candidates: impl IntoIterator<Item = PathBuf>) -> Option<PathBuf> {
    candidates
        .into_iter()
        .find(|candidate| is_executable(candidate))
}

#[cfg(target_os = "macos")]
fn find_chatgpt_codex_executable() -> Option<PathBuf> {
    let relative = Path::new("ChatGPT.app/Contents/Resources/codex");
    let mut candidates = vec![PathBuf::from("/Applications").join(relative)];
    if let Some(home) = home_directory() {
        candidates.push(home.join("Applications").join(relative));
    }
    // Runtime preparation performs the authoritative OpenAI signature and
    // protocol checks. Discovery only makes ChatGPT-app-only installs
    // selectable instead of rejecting setup before those checks can run.
    find_executable_candidate(candidates)
}

#[cfg(not(target_os = "macos"))]
fn find_chatgpt_codex_executable() -> Option<PathBuf> {
    None
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
        home_bin(".volta/bin"),
        home_bin(".asdf/shims"),
        home_bin(".local/share/mise/shims"),
        home_bin(".mise/shims"),
        home_bin(".cargo/bin"),
        home_bin(".fnm/current/bin"),
        home_bin(".nodenv/shims"),
        home_bin(".npm-global/bin"),
        home_bin(".local/share/pnpm"),
        home_bin("Library/pnpm"),
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
    if let Some(home) = home_directory() {
        for directory in version_manager_bins(&home) {
            if seen.insert(directory.clone()) {
                directories.push(directory);
            }
        }
    }
    directories
}

fn home_bin(relative: &str) -> Option<PathBuf> {
    home_directory().map(|home| home.join(relative))
}

fn home_directory() -> Option<PathBuf> {
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn version_manager_bins(home: &Path) -> Vec<PathBuf> {
    let mut directories = Vec::new();
    append_version_bins(&mut directories, &home.join(".nvm/versions/node"), "bin");
    append_version_bins(
        &mut directories,
        &home.join(".local/share/fnm/node-versions"),
        "installation/bin",
    );
    directories
}

fn append_version_bins(directories: &mut Vec<PathBuf>, root: &Path, suffix: &str) {
    let Ok(entries) = root.read_dir() else { return };
    let mut versions = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect::<Vec<_>>();
    versions.sort_by(|left, right| {
        let version = |path: &Path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.strip_prefix('v').unwrap_or(name))
                .and_then(|name| semver::Version::parse(name).ok())
        };
        match (version(left), version(right)) {
            (Some(left), Some(right)) => right.cmp(&left),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => right.cmp(left),
        }
    });
    directories.extend(
        versions
            .into_iter()
            .take(64)
            .map(|version| version.join(suffix)),
    );
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

    #[cfg(unix)]
    #[test]
    fn bundled_codex_fallback_accepts_an_executable_candidate() {
        let application = tempfile::tempdir().expect("application fixture");
        let bundled = application
            .path()
            .join("ChatGPT.app/Contents/Resources/codex");
        fs::create_dir_all(bundled.parent().expect("resource directory"))
            .expect("create resource directory");
        make_executable(&bundled);

        assert_eq!(
            find_executable_candidate([application.path().join("missing"), bundled.clone()]),
            Some(bundled)
        );
    }

    #[test]
    fn version_manager_discovery_is_bounded_and_includes_nvm_and_fnm() {
        let home = tempfile::tempdir().expect("home directory");
        let nvm = home.path().join(".nvm/versions/node/v22.0.0/bin");
        let older_nvm = home.path().join(".nvm/versions/node/v9.0.0/bin");
        let fnm = home
            .path()
            .join(".local/share/fnm/node-versions/v20.0.0/installation/bin");
        fs::create_dir_all(&nvm).expect("create nvm fixture");
        fs::create_dir_all(&older_nvm).expect("create older nvm fixture");
        fs::create_dir_all(&fnm).expect("create fnm fixture");

        let directories = version_manager_bins(home.path());

        assert!(directories.contains(&nvm));
        assert!(directories.contains(&fnm));
        assert!(
            directories.iter().position(|path| path == &nvm)
                < directories.iter().position(|path| path == &older_nvm)
        );
        assert!(directories.len() <= 128);
    }
}

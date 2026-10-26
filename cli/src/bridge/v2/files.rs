//! The file-reference picker's listing, served from a work's folder
//! (`LIST_WORK_FILES`, spec §15 item 4).
//!
//! Relative paths only, never the absolute folder. The requested subfolder
//! must stay inside the work's folder (symlink escapes are refused). In a git
//! checkout the listing is git's own (`.gitignore` respected); elsewhere a
//! bounded walk that skips `.git`. File contents are never read.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::bridge::helpers::safe_relative_path;

/// Upper bound on files considered for one request.
const MAX_CANDIDATES: usize = 50_000;
const MAX_WALK_DEPTH: usize = 16;
const MAX_PAGE: usize = 200;

/// One listed path, relative to the work's folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WorkEntry {
    pub path: String,
    pub is_dir: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FilePage {
    /// Entries relative to the work's folder, `/`-separated. Without a query,
    /// the requested folder's children (folders included); with a query,
    /// matching files anywhere below it.
    pub entries: Vec<WorkEntry>,
    /// Pass back as `after` for the next page.
    pub next: Option<String>,
    /// More files existed than the listing considered.
    pub truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub(crate) enum FileListError {
    #[error("the path is outside the work's folder")]
    OutsideFolder,
    #[error("the work's folder is not available")]
    FolderUnavailable,
}

pub(crate) fn list_work_files(
    folder: &Path,
    relative_path: &str,
    query: Option<&str>,
    after: Option<&str>,
    limit: usize,
) -> Result<FilePage, FileListError> {
    let folder = folder
        .canonicalize()
        .map_err(|_| FileListError::FolderUnavailable)?;
    let base = if relative_path.trim().is_empty() || relative_path == "." {
        PathBuf::new()
    } else {
        safe_relative_path(Path::new(relative_path), &folder).ok_or(FileListError::OutsideFolder)?
    };
    let root = folder.join(&base);
    // A symlinked subfolder must still resolve inside the work's folder.
    let resolved = root
        .canonicalize()
        .map_err(|_| FileListError::OutsideFolder)?;
    if !resolved.starts_with(&folder) || !resolved.is_dir() {
        return Err(FileListError::OutsideFolder);
    }

    let (mut paths, truncated) = match git_files(&folder, &base) {
        Some(listing) => listing,
        None => walk_files(&folder, &resolved),
    };
    let entries: Vec<WorkEntry> = match query.map(str::trim).filter(|query| !query.is_empty()) {
        Some(query) => {
            let query = query.to_lowercase();
            let mut scored: Vec<(u32, String)> = paths
                .into_iter()
                .filter_map(|path| fuzzy_score(&path, &query).map(|score| (score, path)))
                .collect();
            scored.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
            scored
                .into_iter()
                .map(|(_, path)| WorkEntry {
                    path,
                    is_dir: false,
                })
                .collect()
        }
        None => {
            paths.sort();
            children(&paths, &base_text(&base))
        }
    };
    let start = after.filter(|after| !after.is_empty()).map_or(0, |after| {
        entries
            .iter()
            .position(|entry| entry.path == after)
            .map_or(0, |index| index + 1)
    });
    let limit = limit.clamp(1, MAX_PAGE);
    let page: Vec<WorkEntry> = entries.iter().skip(start).take(limit).cloned().collect();
    let next = (start + page.len() < entries.len())
        .then(|| page.last().map(|entry| entry.path.clone()))
        .flatten();
    Ok(FilePage {
        entries: page,
        next,
        truncated,
    })
}

fn base_text(base: &Path) -> String {
    base.components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

/// Immediate children of `base` from a sorted list of file paths; a folder
/// appears once, before files of the same name order.
fn children(paths: &[String], base: &str) -> Vec<WorkEntry> {
    let prefix = if base.is_empty() {
        String::new()
    } else {
        format!("{base}/")
    };
    let mut entries: Vec<WorkEntry> = Vec::new();
    for path in paths {
        let Some(rest) = path.strip_prefix(&prefix) else {
            continue;
        };
        let (child, is_dir) = match rest.split_once('/') {
            Some((folder, _)) => (format!("{prefix}{folder}"), true),
            None => (path.clone(), false),
        };
        if !entries.iter().any(|entry| entry.path == child) {
            entries.push(WorkEntry {
                path: child,
                is_dir,
            });
        }
    }
    entries.sort_by(|left, right| left.path.cmp(&right.path));
    entries
}

/// `git ls-files` for tracked and untracked, non-ignored files under `base`.
fn git_files(folder: &Path, base: &Path) -> Option<(Vec<String>, bool)> {
    let mut command = Command::new("git");
    command.arg("-C").arg(folder).args([
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
    ]);
    command.arg(if base.as_os_str().is_empty() {
        Path::new(".")
    } else {
        base
    });
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    let mut paths = Vec::new();
    let mut truncated = false;
    for raw in output.stdout.split(|byte| *byte == 0) {
        if raw.is_empty() {
            continue;
        }
        if paths.len() == MAX_CANDIDATES {
            truncated = true;
            break;
        }
        if let Ok(path) = std::str::from_utf8(raw) {
            paths.push(path.to_owned());
        }
    }
    paths.dedup();
    Some((paths, truncated))
}

/// Bounded walk for folders that are not git checkouts.
fn walk_files(folder: &Path, root: &Path) -> (Vec<String>, bool) {
    let mut paths = Vec::new();
    let walker = walkdir::WalkDir::new(root)
        .follow_links(false)
        .max_depth(MAX_WALK_DEPTH)
        .into_iter()
        .filter_entry(|entry| entry.file_name() != ".git");
    for entry in walker.flatten() {
        if !entry.file_type().is_file() {
            continue;
        }
        if paths.len() == MAX_CANDIDATES {
            return (paths, true);
        }
        if let Ok(relative) = entry.path().strip_prefix(folder) {
            paths.push(
                relative
                    .components()
                    .map(|component| component.as_os_str().to_string_lossy())
                    .collect::<Vec<_>>()
                    .join("/"),
            );
        }
    }
    (paths, false)
}

/// Lower is better; `None` when the query is not a subsequence of the path.
/// File-name matches rank ahead of directory matches.
fn fuzzy_score(path: &str, query: &str) -> Option<u32> {
    let lower = path.to_lowercase();
    let name = lower.rsplit('/').next().unwrap_or(&lower);
    if name == query {
        return Some(0);
    }
    if name.starts_with(query) {
        return Some(1);
    }
    if name.contains(query) {
        return Some(2);
    }
    if lower.contains(query) {
        return Some(3);
    }
    let mut characters = lower.chars();
    query
        .chars()
        .all(|wanted| characters.any(|candidate| candidate == wanted))
        .then_some(4)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder() -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("dir");
        for path in ["src/main.rs", "src/parser.rs", "README.md", ".git/config"] {
            let path = dir.path().join(path);
            std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
            std::fs::write(path, "x").expect("write");
        }
        dir
    }

    fn paths(page: &FilePage) -> Vec<&str> {
        page.entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect()
    }

    #[test]
    fn lists_relative_paths_without_git_internals() {
        let dir = folder();
        let page = list_work_files(dir.path(), "", None, None, 50).expect("page");
        assert_eq!(
            page.entries,
            [
                WorkEntry {
                    path: "README.md".to_owned(),
                    is_dir: false
                },
                WorkEntry {
                    path: "src".to_owned(),
                    is_dir: true
                },
            ]
        );
        let src = list_work_files(dir.path(), "src", None, None, 50).expect("src");
        assert_eq!(paths(&src), ["src/main.rs", "src/parser.rs"]);
    }

    #[test]
    fn queries_rank_file_names_and_pages_continue_after_the_cursor() {
        let dir = folder();
        let page = list_work_files(dir.path(), "", Some("pars"), None, 50).expect("page");
        assert_eq!(paths(&page), ["src/parser.rs"]);
        let first = list_work_files(dir.path(), "src", None, None, 1).expect("first");
        assert_eq!(first.next.as_deref(), Some("src/main.rs"));
        let second =
            list_work_files(dir.path(), "src", None, first.next.as_deref(), 1).expect("second");
        assert_eq!(paths(&second), ["src/parser.rs"]);
        assert_eq!(second.next, None);
    }

    #[test]
    fn escapes_are_refused() {
        let dir = folder();
        assert_eq!(
            list_work_files(dir.path(), "../", None, None, 10),
            Err(FileListError::OutsideFolder)
        );
        let outside = tempfile::tempdir().expect("outside");
        std::os::unix::fs::symlink(outside.path(), dir.path().join("link")).expect("symlink");
        assert_eq!(
            list_work_files(dir.path(), "link", None, None, 10),
            Err(FileListError::OutsideFolder)
        );
    }
}

//! No project: a thread that works in no project gets a folder of its own
//! under `~/Documents/Inline/<date>/`, made when it is chosen. These folders
//! never show among the agent's folders; the apps see "No project".

use std::path::{Component, Path, PathBuf};

use super::settings::Folder;

/// The choice id the apps keep for No project.
pub(crate) const NO_PROJECT_ID: &str = "no-project";
pub(crate) const NO_PROJECT_LABEL: &str = "No project";

/// Where No project folders go: `~/Documents/Inline`.
#[cfg(not(test))]
fn root() -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    home.is_absolute()
        .then(|| home.join("Documents").join("Inline"))
}

/// Tests never write to the real Documents folder.
#[cfg(test)]
pub(crate) fn root() -> Option<PathBuf> {
    static ROOT: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    let root = ROOT.get_or_init(|| tempfile::tempdir().expect("a test No project root"));
    Some(std::fs::canonicalize(root.path()).ok()?.join("Inline"))
}

/// The No project choice, first among a thread's folders.
pub(crate) fn choice() -> Folder {
    Folder {
        id: NO_PROJECT_ID.to_owned(),
        label: NO_PROJECT_LABEL.to_owned(),
        description: Some("A new folder in Documents/Inline".to_owned()),
    }
}

/// Whether `folder` is a No project folder.
pub(crate) fn is_managed(folder: &Path) -> bool {
    root().is_some_and(|root| is_managed_in(&root, folder))
}

/// A folder as people know it: "No project", else its name.
pub(crate) fn label(folder: &Path) -> String {
    if is_managed(folder) {
        return NO_PROJECT_LABEL.to_owned();
    }
    folder
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| folder.display().to_string())
}

/// The No project folder for one agent's thread, made if missing. The same
/// thread gets the same folder on the same day, so choosing No project again
/// adds nothing.
pub(crate) fn allocate(agent_name: &str, chat_id: i64) -> Result<PathBuf, String> {
    let root = root().ok_or("No home folder to make a No project folder in.")?;
    allocate_in(
        &root,
        &chrono::Local::now().format("%Y-%m-%d").to_string(),
        agent_name,
        chat_id,
    )
}

/// Removes a No project folder nothing was put in, once the thread works
/// elsewhere.
pub(crate) fn forget(folder: &Path) {
    if is_managed(folder) {
        // Only an empty folder goes.
        let _ = std::fs::remove_dir(folder);
    }
}

fn allocate_in(root: &Path, day: &str, agent_name: &str, chat_id: i64) -> Result<PathBuf, String> {
    let folder = root
        .join(day)
        .join(format!("{}-{chat_id}", slug(agent_name)));
    std::fs::create_dir_all(&folder).map_err(|error| {
        format!(
            "Couldn't make the folder {} for No project: {error}",
            folder.display()
        )
    })?;
    Ok(folder)
}

/// `root/<YYYY-MM-DD>/<name>`, by path, so a folder that is gone still counts.
fn is_managed_in(root: &Path, folder: &Path) -> bool {
    let relative = match folder.strip_prefix(root) {
        Ok(relative) => relative.to_path_buf(),
        Err(_) => {
            let (Ok(root), Ok(folder)) =
                (std::fs::canonicalize(root), std::fs::canonicalize(folder))
            else {
                return false;
            };
            match folder.strip_prefix(&root) {
                Ok(relative) => relative.to_path_buf(),
                Err(_) => return false,
            }
        }
    };
    let parts: Vec<Component<'_>> = relative.components().collect();
    matches!(
        parts.as_slice(),
        [Component::Normal(day), Component::Normal(_)]
            if day.to_str().is_some_and(is_day)
    )
}

fn is_day(name: &str) -> bool {
    chrono::NaiveDate::parse_from_str(name, "%Y-%m-%d").is_ok() && name.len() == 10
}

/// A file-name-safe, lowercase form of the agent's name.
fn slug(name: &str) -> String {
    let mut slug = String::new();
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            slug.push(character.to_ascii_lowercase());
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_end_matches('-');
    if slug.is_empty() {
        "agent".to_owned()
    } else {
        slug.chars().take(32).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_thread_gets_one_folder_of_its_own() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("Inline");
        let first = allocate_in(&root, "2026-11-07", "Mo's Codex", 42).unwrap();
        assert!(first.is_dir());
        assert_eq!(first, root.join("2026-11-07/mo-s-codex-42"));
        assert_eq!(
            allocate_in(&root, "2026-11-07", "Mo's Codex", 42).unwrap(),
            first
        );
        assert_ne!(
            allocate_in(&root, "2026-11-07", "Mo's Codex", 43).unwrap(),
            first
        );
        assert_ne!(
            allocate_in(&root, "2026-11-07", "Claude", 42).unwrap(),
            first
        );
        assert!(is_managed_in(&root, &first));
    }

    #[test]
    fn only_dated_folders_under_the_root_are_no_project() {
        let root = Path::new("/Users/someone/Documents/Inline");
        assert!(is_managed_in(root, &root.join("2026-11-07/codex-1")));
        assert!(!is_managed_in(root, root));
        assert!(!is_managed_in(root, &root.join("2026-11-07")));
        assert!(!is_managed_in(root, &root.join("notes")));
        assert!(!is_managed_in(root, &root.join("notes/site")));
        assert!(!is_managed_in(root, &root.join("2026-11-07/codex-1/src")));
        assert!(!is_managed_in(root, Path::new("/Users/someone/dev/inline")));
    }

    #[test]
    fn slugs_are_file_name_safe() {
        assert_eq!(slug("Mo's Codex"), "mo-s-codex");
        assert_eq!(slug("  ✨ "), "agent");
        assert_eq!(slug("Claude Code (work)"), "claude-code-work");
    }
}

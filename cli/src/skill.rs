use serde::Serialize;
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::errors::CliError;
use crate::output::{self, JsonFormat};

const SKILL_FILES: &[(&str, &str)] = &[
    (
        "SKILL.md",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../skills/inline/SKILL.md"
        )),
    ),
    (
        "agents/openai.yaml",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../skills/inline/agents/openai.yaml"
        )),
    ),
    (
        "references/concepts.md",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../skills/inline/references/concepts.md"
        )),
    ),
    (
        "references/inline-cli.md",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../skills/inline/references/inline-cli.md"
        )),
    ),
    (
        "references/recipes.md",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../skills/inline/references/recipes.md"
        )),
    ),
    (
        "references/workflows.md",
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../skills/inline/references/workflows.md"
        )),
    ),
];

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SkillInstallOutput {
    status: &'static str,
    skill: &'static str,
    agent: &'static str,
    path: String,
    files_written: usize,
}

pub(crate) fn install_for_codex(
    force: bool,
    json: bool,
    json_format: JsonFormat,
) -> Result<(), Box<dyn std::error::Error>> {
    let target = codex_skill_path()?;
    let files_written = install_to(&target, force)?;
    let status = if files_written == 0 {
        "already_current"
    } else {
        "installed"
    };
    let result = SkillInstallOutput {
        status,
        skill: "inline",
        agent: "codex",
        path: target.display().to_string(),
        files_written,
    };

    if json {
        output::print_json(&result, json_format)?;
    } else if files_written == 0 {
        println!("Inline skill is already current for Codex.");
        println!("Path: {}", target.display());
    } else {
        println!("Installed the Inline skill for Codex.");
        println!("Path: {}", target.display());
        println!("Restart Codex to load the skill.");
    }
    Ok(())
}

fn codex_skill_path() -> Result<PathBuf, io::Error> {
    let codex_home = env::var_os("CODEX_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("HOME")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .map(|home| home.join(".codex"))
        })
        .or_else(|| {
            env::var_os("USERPROFILE")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .map(|home| home.join(".codex"))
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "user home directory not found"))?;
    Ok(codex_home.join("skills").join("inline"))
}

fn install_to(target: &Path, force: bool) -> Result<usize, Box<dyn std::error::Error>> {
    let target_metadata = fs::symlink_metadata(target).ok();
    if target_metadata
        .as_ref()
        .is_some_and(|metadata| metadata.file_type().is_symlink())
    {
        if target.exists() && skill_is_current(target)? {
            return Ok(0);
        }
        return Err(CliError {
            code: "skill_managed_externally",
            message: format!(
                "The Inline skill at {} is a symlink managed by another installer",
                target.display()
            ),
            hint: Some(
                "Update it with its original manager (for example, `npx skills update inline`) instead of replacing the link."
                    .to_string(),
            ),
            examples: vec!["npx skills update inline --global --yes".to_string()],
        }
        .into());
    }
    if target_metadata
        .as_ref()
        .is_some_and(|metadata| !metadata.is_dir())
    {
        return Err(CliError {
            code: "skill_path_not_directory",
            message: format!(
                "The Inline skill path {} exists but is not a directory",
                target.display()
            ),
            hint: Some(
                "Move the existing path aside, then run `inline skill install` again.".to_string(),
            ),
            examples: Vec::new(),
        }
        .into());
    }
    if target.exists() && skill_is_current(target)? {
        return Ok(0);
    }
    if target.exists() && !force {
        return Err(CliError {
            code: "skill_already_exists",
            message: format!(
                "An Inline skill already exists at {} and differs from this CLI's bundled version",
                target.display()
            ),
            hint: Some(
                "Review the existing skill, then re-run with --force to overwrite only Inline-managed files. Extra files are preserved."
                    .to_string(),
            ),
            examples: vec!["inline skill install --force".to_string()],
        }
        .into());
    }

    fs::create_dir_all(target)?;
    for (relative_path, contents) in SKILL_FILES {
        let destination = target.join(relative_path);
        reject_nested_symlinks(target, Path::new(relative_path))?;
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(destination, contents)?;
    }
    Ok(SKILL_FILES.len())
}

fn reject_nested_symlinks(
    target: &Path,
    relative_path: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut candidate = target.to_path_buf();
    for component in relative_path.components() {
        candidate.push(component);
        match fs::symlink_metadata(&candidate) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(CliError {
                    code: "skill_path_contains_symlink",
                    message: format!(
                        "Refusing to write through symlink inside the Inline skill: {}",
                        candidate.display()
                    ),
                    hint: Some(
                        "Review the existing skill installation and move the symlink aside before retrying."
                            .to_string(),
                    ),
                    examples: Vec::new(),
                }
                .into());
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => break,
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn skill_is_current(target: &Path) -> Result<bool, io::Error> {
    for (relative_path, expected) in SKILL_FILES {
        let actual = match fs::read_to_string(target.join(relative_path)) {
            Ok(actual) => actual,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error),
        };
        if actual != *expected {
            return Ok(false);
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use walkdir::WalkDir;

    #[test]
    fn bundled_manifest_covers_source_skill_files() {
        let source_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../skills/inline");
        let source_files = WalkDir::new(&source_root)
            .into_iter()
            .map(|entry| entry.unwrap())
            .filter(|entry| entry.file_type().is_file())
            .filter_map(|entry| {
                let relative = entry.path().strip_prefix(&source_root).unwrap();
                (relative.file_name().and_then(|name| name.to_str()) != Some(".DS_Store"))
                    .then(|| relative.to_string_lossy().replace('\\', "/"))
            })
            .collect::<BTreeSet<_>>();
        let bundled_files = SKILL_FILES
            .iter()
            .map(|(path, _)| (*path).to_string())
            .collect::<BTreeSet<_>>();

        assert_eq!(bundled_files, source_files);
    }

    #[test]
    fn installs_complete_bundled_skill_and_is_idempotent() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("skills/inline");

        assert_eq!(install_to(&target, false).unwrap(), SKILL_FILES.len());
        assert_eq!(install_to(&target, false).unwrap(), 0);
        assert!(target.join("SKILL.md").is_file());
        assert!(target.join("agents/openai.yaml").is_file());
        assert!(target.join("references/inline-cli.md").is_file());
    }

    #[test]
    fn differing_install_requires_force_and_preserves_extra_files() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("skills/inline");
        install_to(&target, false).unwrap();
        fs::write(target.join("SKILL.md"), "customized").unwrap();
        fs::write(target.join("notes.md"), "keep me").unwrap();

        let error = install_to(&target, false).unwrap_err();
        let cli_error = error.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_error.code, "skill_already_exists");

        assert_eq!(install_to(&target, true).unwrap(), SKILL_FILES.len());
        assert_eq!(
            fs::read_to_string(target.join("SKILL.md")).unwrap(),
            SKILL_FILES[0].1
        );
        assert_eq!(
            fs::read_to_string(target.join("notes.md")).unwrap(),
            "keep me"
        );
    }

    #[cfg(unix)]
    #[test]
    fn does_not_replace_an_externally_managed_symlink() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let external = root.path().join("external-inline");
        let target = root.path().join("skills/inline");
        fs::create_dir_all(&external).unwrap();
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(external.join("SKILL.md"), "older external skill").unwrap();
        symlink(&external, &target).unwrap();

        let error = install_to(&target, true).unwrap_err();
        let cli_error = error.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_error.code, "skill_managed_externally");
        assert_eq!(
            fs::read_to_string(external.join("SKILL.md")).unwrap(),
            "older external skill"
        );
    }

    #[test]
    fn rejects_a_file_at_the_skill_directory_path() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("skills/inline");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(&target, "not a directory").unwrap();

        let error = install_to(&target, true).unwrap_err();
        let cli_error = error.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_error.code, "skill_path_not_directory");
    }

    #[cfg(unix)]
    #[test]
    fn force_install_does_not_write_through_a_nested_symlink() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("skills/inline");
        let external = root.path().join("external-references");
        fs::create_dir_all(&target).unwrap();
        fs::create_dir_all(&external).unwrap();
        fs::write(target.join("SKILL.md"), "older skill").unwrap();
        symlink(&external, target.join("references")).unwrap();

        let error = install_to(&target, true).unwrap_err();
        let cli_error = error.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_error.code, "skill_path_contains_symlink");
        assert!(!external.join("concepts.md").exists());
    }
}

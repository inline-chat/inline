use chrono::{DateTime, Utc};
use std::fs;
use std::path::{Path, PathBuf};

use crate::dates::parse_relative_time;
use crate::errors::CliError;

pub(crate) fn normalize_search_queries(
    queries: &[String],
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let normalized: Vec<String> = queries
        .iter()
        .map(|query| query.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|query| !query.is_empty())
        .collect();

    if normalized.is_empty() {
        return Err(CliError::missing_query().into());
    }

    Ok(normalized)
}

pub(crate) fn validate_message_limit(
    limit: Option<i32>,
) -> Result<Option<i32>, Box<dyn std::error::Error>> {
    match limit {
        Some(value) if value <= 0 => {
            Err(CliError::invalid_args("--limit must be greater than 0").into())
        }
        value => Ok(value),
    }
}

pub(crate) fn validate_table_only_list_flags(
    json: bool,
    ids: bool,
    id: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if json && (ids || id) {
        Err(CliError::invalid_args(
            "--ids/--id are only supported in table output mode (omit --json)",
        )
        .into())
    } else {
        Ok(())
    }
}

pub(crate) fn validate_attachment_inputs(
    paths: &[PathBuf],
    max_bytes: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    for path in paths {
        let metadata = fs::metadata(path).map_err(|_| {
            CliError::invalid_args(format!("Attachment not found: {}", path.display()))
        })?;
        if metadata.is_file() {
            if metadata.len() > max_bytes {
                return Err(CliError::invalid_args("Attachment exceeds 200MB limit").into());
            }
        } else if metadata.is_dir() {
            if !directory_has_uploadable_file(path) {
                return Err(CliError::invalid_args(format!(
                    "Folder has no files to upload: {}",
                    path.display()
                ))
                .into());
            }
        } else {
            return Err(CliError::invalid_args(format!(
                "Attachment is not a file or folder: {}",
                path.display()
            ))
            .into());
        }
    }

    Ok(())
}

fn directory_has_uploadable_file(path: &Path) -> bool {
    walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(Result::ok)
        .any(|entry| {
            entry.path() != path && !entry.file_type().is_symlink() && entry.file_type().is_file()
        })
}

pub(crate) fn validate_output_file_path_arg(
    name: &str,
    path: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Ok(metadata) = fs::metadata(path) {
        if metadata.is_dir() {
            return Err(CliError::invalid_args(format!(
                "{name} must be a file path, got directory: {}",
                path.display()
            ))
            .into());
        }
    }

    validate_parent_directory(name, path)
}

pub(crate) fn validate_output_dir_path_arg(
    name: &str,
    path: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Ok(metadata) = fs::metadata(path) {
        if !metadata.is_dir() {
            return Err(CliError::invalid_args(format!(
                "{name} must be a directory path: {}",
                path.display()
            ))
            .into());
        }
        return Ok(());
    }

    validate_parent_directory(name, path)
}

fn validate_parent_directory(name: &str, path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    else {
        return Ok(());
    };

    if let Ok(metadata) = fs::metadata(parent) {
        if !metadata.is_dir() {
            return Err(CliError::invalid_args(format!(
                "Parent for {name} must be a directory: {}",
                parent.display()
            ))
            .into());
        }
    }

    Ok(())
}

pub(crate) fn validate_positive_id_arg(
    name: &str,
    value: i64,
) -> Result<i64, Box<dyn std::error::Error>> {
    if value <= 0 {
        Err(CliError::invalid_args(format!("{name} must be greater than 0")).into())
    } else {
        Ok(value)
    }
}

pub(crate) fn validate_optional_positive_id_arg(
    name: &str,
    value: Option<i64>,
) -> Result<Option<i64>, Box<dyn std::error::Error>> {
    value
        .map(|id| validate_positive_id_arg(name, id))
        .transpose()
}

pub(crate) fn validate_positive_ids_arg(
    name: &str,
    values: &[i64],
) -> Result<(), Box<dyn std::error::Error>> {
    if values.iter().any(|id| *id <= 0) {
        Err(CliError::invalid_args(format!("All {name} values must be greater than 0")).into())
    } else {
        Ok(())
    }
}

pub(crate) fn validate_message_id_arg(
    name: &str,
    value: i64,
) -> Result<i64, Box<dyn std::error::Error>> {
    validate_positive_id_arg(name, value)
}

pub(crate) fn validate_optional_message_id_arg(
    name: &str,
    value: Option<i64>,
) -> Result<Option<i64>, Box<dyn std::error::Error>> {
    validate_optional_positive_id_arg(name, value)
}

pub(crate) fn validate_message_ids_arg(
    name: &str,
    values: &[i64],
) -> Result<(), Box<dyn std::error::Error>> {
    validate_positive_ids_arg(name, values)
}

pub(crate) fn parse_time_filters(
    since: Option<&str>,
    until: Option<&str>,
    now: DateTime<Utc>,
) -> Result<(Option<i64>, Option<i64>), Box<dyn std::error::Error>> {
    let since_ts = since
        .map(|value| parse_relative_time(value, now))
        .transpose()
        .map_err(|e| CliError::invalid_args(format!("invalid --since: {e}")))?;
    let until_ts = until
        .map(|value| parse_relative_time(value, now))
        .transpose()
        .map_err(|e| CliError::invalid_args(format!("invalid --until: {e}")))?;

    if let (Some(s), Some(u)) = (since_ts, until_ts) {
        if u < s {
            return Err(CliError::invalid_time_range().into());
        }
    }

    Ok((since_ts, until_ts))
}

pub(crate) fn normalize_translation_language(
    language: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let trimmed = language.trim();
    if trimmed.is_empty() {
        return Err(CliError::missing_translate_language().into());
    }
    Ok(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempTestDir {
        path: PathBuf,
    }

    impl TempTestDir {
        fn new(label: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "inline-cli-validation-{label}-{}-{nanos}",
                std::process::id()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TempTestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn manifest_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
    }

    fn manifest_file() -> PathBuf {
        manifest_dir().join("Cargo.toml")
    }

    fn assert_invalid_args(err: Box<dyn std::error::Error>, message_fragment: &str) {
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(
            cli_err.message.contains(message_fragment),
            "expected {:?} to contain {:?}",
            cli_err.message,
            message_fragment
        );
    }

    #[test]
    fn missing_query_errors_are_structured() {
        let err = normalize_search_queries(&[]).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "missing_query");
    }

    #[test]
    fn non_positive_message_limits_are_structured_invalid_args() {
        for value in [0, -1] {
            let err = validate_message_limit(Some(value)).unwrap_err();
            let cli_err = err.downcast_ref::<CliError>().unwrap();
            assert_eq!(cli_err.code, "invalid_args");
            assert!(cli_err.message.contains("--limit"));
        }

        assert_eq!(validate_message_limit(Some(1)).unwrap(), Some(1));
        assert_eq!(validate_message_limit(None).unwrap(), None);
    }

    #[test]
    fn table_only_list_flags_are_structured_invalid_args_in_json_mode() {
        for (ids, id) in [(true, false), (false, true), (true, true)] {
            let err = validate_table_only_list_flags(true, ids, id).unwrap_err();
            let cli_err = err.downcast_ref::<CliError>().unwrap();
            assert_eq!(cli_err.code, "invalid_args");
            assert!(cli_err.message.contains("--ids/--id"));
            assert!(cli_err.message.contains("--json"));
        }

        validate_table_only_list_flags(false, true, false).unwrap();
        validate_table_only_list_flags(false, false, true).unwrap();
        validate_table_only_list_flags(true, false, false).unwrap();
    }

    #[test]
    fn attachment_inputs_validate_existing_paths_and_size() {
        let file = manifest_file();
        let dir = manifest_dir();
        validate_attachment_inputs(&[file.clone(), dir.clone()], u64::MAX).unwrap();

        let err = validate_attachment_inputs(&[file], 1).unwrap_err();
        assert_invalid_args(err, "Attachment exceeds");

        let missing = dir.join("missing-inline-cli-attachment-test-file");
        let err = validate_attachment_inputs(&[missing], u64::MAX).unwrap_err();
        assert_invalid_args(err, "Attachment not found");

        let empty_dir = TempTestDir::new("empty-attachment-dir");
        let err = validate_attachment_inputs(&[empty_dir.path.clone()], u64::MAX).unwrap_err();
        assert_invalid_args(err, "Folder has no files to upload");
    }

    #[test]
    fn output_file_paths_reject_directories_and_file_parents() {
        validate_output_file_path_arg("--output", &manifest_file()).unwrap();
        validate_output_file_path_arg("--output", &manifest_dir().join("export.json")).unwrap();

        let err = validate_output_file_path_arg("--output", &manifest_dir()).unwrap_err();
        assert_invalid_args(err, "--output");

        let parent_is_file = manifest_file().join("child.json");
        let err = validate_output_file_path_arg("--output", &parent_is_file).unwrap_err();
        assert_invalid_args(err, "Parent for --output");
    }

    #[test]
    fn output_dir_paths_reject_files_and_file_parents() {
        validate_output_dir_path_arg("--dir", &manifest_dir()).unwrap();
        validate_output_dir_path_arg("--dir", &manifest_dir().join("downloads")).unwrap();

        let err = validate_output_dir_path_arg("--dir", &manifest_file()).unwrap_err();
        assert_invalid_args(err, "--dir");

        let parent_is_file = manifest_file().join("downloads");
        let err = validate_output_dir_path_arg("--dir", &parent_is_file).unwrap_err();
        assert_invalid_args(err, "Parent for --dir");
    }

    #[test]
    fn non_positive_message_ids_are_structured_invalid_args() {
        for value in [0, -1] {
            let err = validate_message_id_arg("--message-id", value).unwrap_err();
            let cli_err = err.downcast_ref::<CliError>().unwrap();
            assert_eq!(cli_err.code, "invalid_args");
            assert!(cli_err.message.contains("--message-id"));
        }

        assert_eq!(validate_message_id_arg("--message-id", 1).unwrap(), 1);
    }

    #[test]
    fn non_positive_generic_ids_are_structured_invalid_args() {
        let err = validate_positive_id_arg("--chat-id", 0).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--chat-id"));
        assert_eq!(validate_positive_id_arg("--chat-id", 1).unwrap(), 1);
    }

    #[test]
    fn optional_positive_ids_are_structured_invalid_args() {
        let err = validate_optional_positive_id_arg("--space-id", Some(0)).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--space-id"));
        assert_eq!(
            validate_optional_positive_id_arg("--space-id", Some(1)).unwrap(),
            Some(1)
        );
        assert_eq!(
            validate_optional_positive_id_arg("--space-id", None).unwrap(),
            None
        );
    }

    #[test]
    fn repeated_positive_ids_are_structured_invalid_args() {
        let err = validate_positive_ids_arg("--participant", &[1, 0, 2]).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--participant"));
        validate_positive_ids_arg("--participant", &[1, 2]).unwrap();
    }

    #[test]
    fn non_positive_optional_reply_ids_are_structured_invalid_args() {
        let err = validate_optional_message_id_arg("--reply-to", Some(0)).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--reply-to"));
        assert_eq!(
            validate_optional_message_id_arg("--reply-to", Some(1)).unwrap(),
            Some(1)
        );
        assert_eq!(
            validate_optional_message_id_arg("--reply-to", None).unwrap(),
            None
        );
    }

    #[test]
    fn non_positive_offset_ids_are_structured_invalid_args() {
        let err = validate_optional_message_id_arg("--offset-id", Some(0)).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--offset-id"));
        assert_eq!(
            validate_optional_message_id_arg("--offset-id", Some(1)).unwrap(),
            Some(1)
        );
    }

    #[test]
    fn non_positive_repeated_message_ids_are_structured_invalid_args() {
        let err = validate_message_ids_arg("--message-id", &[1, 0, 2]).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--message-id"));
        validate_message_ids_arg("--message-id", &[1, 2]).unwrap();
    }

    #[test]
    fn invalid_time_filters_are_structured() {
        let now = DateTime::parse_from_rfc3339("2024-01-03T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        let err = parse_time_filters(Some("not a time"), None, now).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("--since"));

        let err = parse_time_filters(Some("2024-01-03"), Some("2024-01-02"), now).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "invalid_time_range");
    }

    #[test]
    fn empty_translation_language_is_structured() {
        let err = normalize_translation_language("  ").unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();
        assert_eq!(cli_err.code, "missing_translate_language");
    }
}

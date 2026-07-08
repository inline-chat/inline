use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use std::{fs, io};

use crate::errors::CliError;
use crate::output::format_bytes;
use inline_protocol::proto;
use inline_sdk::api::{UploadFileInput, UploadFileResult, UploadFileType, UploadVideoMetadata};

pub(crate) const MAX_ATTACHMENT_BYTES: u64 = 200 * 1024 * 1024;

#[derive(Clone)]
pub(crate) struct PreparedAttachment {
    upload_path: PathBuf,
    pub(crate) display_name: String,
    file_name: String,
    mime_type: Option<String>,
    file_type: UploadFileType,
    video_metadata: Option<UploadVideoMetadata>,
    #[allow(dead_code)]
    pub(crate) size_bytes: u64,
    cleanup_path: Option<PathBuf>,
}

impl PreparedAttachment {
    pub(crate) fn to_upload_input(&self) -> UploadFileInput {
        let mut input = UploadFileInput::new(
            self.upload_path.clone(),
            self.file_name.clone(),
            self.file_type,
        );
        if let Some(mime_type) = self.mime_type.as_deref() {
            input = input.with_mime_type(mime_type);
        }
        if let Some(metadata) = self.video_metadata {
            input = input.with_video_metadata(metadata);
        }
        input
    }
}

impl Drop for PreparedAttachment {
    fn drop(&mut self) {
        if let Some(path) = self.cleanup_path.take() {
            let _ = fs::remove_file(path);
        }
    }
}

pub(crate) fn prepare_attachments(
    paths: &[PathBuf],
    data_dir: &Path,
    force_file: bool,
    quiet: bool,
) -> Result<Vec<PreparedAttachment>, Box<dyn std::error::Error>> {
    if paths.is_empty() {
        return Ok(Vec::new());
    }

    let mut prepared = Vec::with_capacity(paths.len());
    for path in paths {
        let metadata = fs::metadata(path).map_err(|_| {
            CliError::invalid_args(format!("Attachment not found: {}", path.display()))
        })?;
        if metadata.is_dir() {
            prepared.push(prepare_directory_attachment(path, data_dir, quiet)?);
        } else if metadata.is_file() {
            prepared.push(prepare_file_attachment(
                path,
                metadata.len(),
                force_file,
                quiet,
            )?);
        } else {
            return Err(CliError::invalid_args(format!(
                "Attachment is not a file or folder: {}",
                path.display()
            ))
            .into());
        }
    }

    Ok(prepared)
}

pub(crate) fn input_media_from_upload(
    upload: &UploadFileResult,
) -> Result<proto::InputMedia, Box<dyn std::error::Error>> {
    if let Some(photo_id) = upload.photo_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Photo(proto::InputMediaPhoto {
                photo_id,
            })),
        });
    }
    if let Some(video_id) = upload.video_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Video(proto::InputMediaVideo {
                video_id,
            })),
        });
    }
    if let Some(document_id) = upload.document_id {
        return Ok(proto::InputMedia {
            media: Some(proto::input_media::Media::Document(
                proto::InputMediaDocument { document_id },
            )),
        });
    }
    Err(CliError::unexpected_api_response("uploadFile", "missing media id").into())
}

fn prepare_directory_attachment(
    path: &Path,
    data_dir: &Path,
    quiet: bool,
) -> Result<PreparedAttachment, Box<dyn std::error::Error>> {
    if !quiet {
        eprintln!("Zipping folder {}...", path.display());
    }
    let (zip_path, zip_name) = zip_directory(path, data_dir)?;
    let size = fs::metadata(&zip_path)?.len();
    ensure_attachment_size(&zip_name, size, quiet)?;

    Ok(PreparedAttachment {
        upload_path: zip_path.clone(),
        display_name: path.display().to_string(),
        file_name: zip_name,
        mime_type: Some("application/zip".to_string()),
        file_type: UploadFileType::Document,
        video_metadata: None,
        size_bytes: size,
        cleanup_path: Some(zip_path),
    })
}

fn prepare_file_attachment(
    path: &Path,
    size: u64,
    force_file: bool,
    quiet: bool,
) -> Result<PreparedAttachment, Box<dyn std::error::Error>> {
    let display_name = path.display().to_string();
    ensure_attachment_size(&display_name, size, quiet)?;

    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| CliError::invalid_args("Attachment file name is invalid"))?
        .to_string();

    let mime_type = mime_guess::from_path(path)
        .first()
        .map(|mime| mime.essence_str().to_string());

    let mut file_type = match mime_type.as_deref() {
        Some(value) if value.starts_with("image/") => UploadFileType::Photo,
        Some(value) if value.starts_with("video/") => UploadFileType::Video,
        _ => UploadFileType::Document,
    };

    if force_file && matches!(file_type, UploadFileType::Photo | UploadFileType::Video) {
        file_type = UploadFileType::Document;
    }

    let mut video_metadata = None;
    if matches!(file_type, UploadFileType::Video) {
        if let Some(metadata) = probe_video_metadata(path) {
            video_metadata = Some(metadata);
        } else if !quiet {
            eprintln!(
                "Warning: could not read video metadata for {}. Uploading as document.",
                display_name
            );
            file_type = UploadFileType::Document;
        }
    }

    Ok(PreparedAttachment {
        upload_path: path.to_path_buf(),
        display_name,
        file_name,
        mime_type,
        file_type,
        video_metadata,
        size_bytes: size,
        cleanup_path: None,
    })
}

fn ensure_attachment_size(
    label: &str,
    size: u64,
    quiet: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if size > MAX_ATTACHMENT_BYTES {
        let size_label = format_bytes(size as i64);
        if !quiet {
            eprintln!("Attachment {} is {} (limit 200MB).", label, size_label);
        }
        return Err(CliError::invalid_args("Attachment exceeds 200MB limit").into());
    }
    Ok(())
}

fn zip_directory(
    dir: &Path,
    data_dir: &Path,
) -> Result<(PathBuf, String), Box<dyn std::error::Error>> {
    fs::create_dir_all(data_dir)?;
    let folder_name = dir
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("folder");
    let zip_name = format!("{}.zip", folder_name);
    let zip_path = data_dir.join(format!("{}-{}.zip", folder_name, current_epoch_seconds()));

    let file = fs::File::create(&zip_path)?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::FileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o644);

    let mut has_entries = false;
    for entry in walkdir::WalkDir::new(dir)
        .into_iter()
        .filter_map(Result::ok)
    {
        if entry.path() == dir {
            continue;
        }
        if entry.file_type().is_symlink() {
            continue;
        }

        let relative = entry.path().strip_prefix(dir)?;
        let mut name = relative.to_string_lossy().replace('\\', "/");
        if entry.file_type().is_dir() {
            name.push('/');
            zip.add_directory(name, options)?;
            continue;
        }

        if entry.file_type().is_file() {
            has_entries = true;
            zip.start_file(name, options)?;
            let mut input = fs::File::open(entry.path())?;
            io::copy(&mut input, &mut zip)?;
        }
    }

    zip.finish()?;

    if !has_entries {
        return Err(CliError::invalid_args("Folder has no files to upload.").into());
    }

    Ok((zip_path, zip_name))
}

fn probe_video_metadata(path: &Path) -> Option<UploadVideoMetadata> {
    let output = std::process::Command::new("ffprobe")
        .arg("-v")
        .arg("error")
        .arg("-select_streams")
        .arg("v:0")
        .arg("-show_entries")
        .arg("stream=width,height,duration")
        .arg("-of")
        .arg("json")
        .arg(path)
        .output();

    let output = match output {
        Ok(output) if output.status.success() => output,
        _ => return None,
    };

    let parsed: FfprobeOutput = serde_json::from_slice(&output.stdout).ok()?;
    let stream = parsed.streams.into_iter().next()?;
    let width = stream.width?;
    let height = stream.height?;
    let duration = stream
        .duration
        .and_then(|value| value.parse::<f64>().ok())?;
    if width <= 0 || height <= 0 {
        return None;
    }
    let duration = duration.ceil() as i32;
    if duration <= 0 {
        return None;
    }

    Some(UploadVideoMetadata {
        width,
        height,
        duration,
    })
}

fn current_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(serde::Deserialize)]
struct FfprobeOutput {
    streams: Vec<FfprobeStream>,
}

#[derive(serde::Deserialize)]
struct FfprobeStream {
    width: Option<i32>,
    height: Option<i32>,
    duration: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_response_without_media_id_is_structured() {
        let upload = UploadFileResult {
            file_unique_id: "file-1".to_string(),
            photo_id: None,
            video_id: None,
            document_id: None,
        };

        let err = input_media_from_upload(&upload).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "unexpected_api_response");
        assert!(cli_err.message.contains("uploadFile"));
        assert!(cli_err.message.contains("missing media id"));
    }

    #[test]
    fn upload_response_maps_first_media_id_to_input_media() {
        let upload = UploadFileResult {
            file_unique_id: "file-1".to_string(),
            photo_id: Some(11),
            video_id: Some(22),
            document_id: Some(33),
        };

        let media = input_media_from_upload(&upload).unwrap();
        match media.media {
            Some(proto::input_media::Media::Photo(photo)) => assert_eq!(photo.photo_id, 11),
            other => panic!("expected photo media, got {other:?}"),
        }
    }

    #[test]
    fn prepare_file_attachment_infers_photo_and_force_file_document() {
        let path = PathBuf::from("image.jpg");

        let photo = prepare_file_attachment(&path, 100, false, true).unwrap();
        assert!(matches!(photo.file_type, UploadFileType::Photo));
        assert_eq!(photo.mime_type.as_deref(), Some("image/jpeg"));

        let document = prepare_file_attachment(&path, 100, true, true).unwrap();
        assert!(matches!(document.file_type, UploadFileType::Document));
        assert_eq!(document.to_upload_input().file_name, "image.jpg");
    }

    #[test]
    fn oversized_attachment_errors_are_structured() {
        let err = ensure_attachment_size("big.bin", MAX_ATTACHMENT_BYTES + 1, true).unwrap_err();
        let cli_err = err.downcast_ref::<CliError>().unwrap();

        assert_eq!(cli_err.code, "invalid_args");
        assert!(cli_err.message.contains("Attachment exceeds"));
    }
}

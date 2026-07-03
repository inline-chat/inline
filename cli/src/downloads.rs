use chrono::{TimeZone, Utc};
use futures_util::StreamExt;
use std::path::{Path, PathBuf};
use tokio::io::AsyncWriteExt;

use crate::client_info;
use crate::errors::{CliError, HttpStatusCliError};
use crate::media::best_photo_size;
use crate::protocol::proto;

pub(crate) fn resolve_download_path(
    message: &proto::Message,
    output: Option<PathBuf>,
    dir: Option<PathBuf>,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(output) = output {
        return Ok(output);
    }
    let file_name = message
        .media
        .as_ref()
        .and_then(media_file_name)
        .unwrap_or_else(|| format!("message-{}.bin", message.id));
    let base_dir = dir.unwrap_or_else(|| PathBuf::from("."));
    Ok(base_dir.join(file_name))
}

pub(crate) fn resolve_batch_download_path(
    message: &proto::Message,
    dir: &Path,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let Some(media) = message.media.as_ref() else {
        return Err(CliError::invalid_args("Message has no downloadable media.").into());
    };
    let descriptor = media_download_descriptor(media)?;
    let prefix = format!(
        "{}-MSG{}-{}-{}",
        compact_message_date(message.date),
        message.id,
        descriptor.kind,
        descriptor.media_id
    );
    let file_name = if let Some(original_name) = descriptor.original_name {
        format!("{prefix}-{original_name}")
    } else {
        format!("{prefix}.{}", descriptor.extension)
    };
    Ok(available_path(dir.join(file_name)))
}

pub(crate) async fn download_message_media(
    message: &proto::Message,
    output_path: &Path,
) -> Result<u64, Box<dyn std::error::Error>> {
    let Some(media) = message.media.as_ref() else {
        return Err(CliError::invalid_args("Message has no downloadable media.").into());
    };
    let (url, description) = match &media.media {
        Some(proto::message_media::Media::Document(document)) => {
            let document = document.document.as_ref();
            (document.and_then(|doc| doc.cdn_url.clone()), "document")
        }
        Some(proto::message_media::Media::Video(video)) => {
            let video = video.video.as_ref();
            (video.and_then(|vid| vid.cdn_url.clone()), "video")
        }
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo.photo.as_ref();
            let (url, _, _, _) = match photo {
                Some(photo) => best_photo_size(photo),
                None => (None, None, None, None),
            };
            (url, "photo")
        }
        Some(proto::message_media::Media::Voice(voice)) => {
            let voice = voice.voice.as_ref();
            (voice.and_then(|clip| clip.cdn_url.clone()), "voice")
        }
        Some(proto::message_media::Media::Nudge(_)) => (None, "nudge"),
        None => (None, "media"),
    };
    let url = match url {
        Some(url) if !url.trim().is_empty() => url,
        _ => {
            return Err(
                CliError::invalid_args(format!("No CDN URL available for {description}.")).into(),
            );
        }
    };

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let client = client_info::http_client_builder().build()?;
    let response = client.get(url).send().await?;
    if !response.status().is_success() {
        let status = response.status().as_u16();
        let body = response
            .text()
            .await
            .ok()
            .and_then(|body| http_body_preview(&body));
        return Err(HttpStatusCliError::download_failed(status, body).into());
    }

    let mut file = tokio::fs::File::create(output_path).await?;
    let mut total = 0u64;
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        total += chunk.len() as u64;
    }
    file.flush().await?;
    Ok(total)
}

fn http_body_preview(body: &str) -> Option<String> {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return None;
    }

    const MAX_BODY_PREVIEW_CHARS: usize = 500;
    let mut preview = String::new();
    for (index, ch) in trimmed.chars().enumerate() {
        if index >= MAX_BODY_PREVIEW_CHARS {
            preview.push_str("...");
            return Some(preview);
        }
        preview.push(ch);
    }
    Some(preview)
}

struct MediaDownloadDescriptor {
    kind: &'static str,
    media_id: i64,
    extension: String,
    original_name: Option<String>,
}

fn media_download_descriptor(
    media: &proto::MessageMedia,
) -> Result<MediaDownloadDescriptor, CliError> {
    match &media.media {
        Some(proto::message_media::Media::Document(document)) => {
            let document = document.document.as_ref().ok_or_else(|| {
                CliError::invalid_args("Document media is missing file metadata.")
            })?;
            let original_name = sanitize_file_name(&document.file_name);
            Ok(MediaDownloadDescriptor {
                kind: "document",
                media_id: document.id,
                extension: original_name
                    .as_deref()
                    .and_then(file_extension)
                    .unwrap_or("bin")
                    .to_string(),
                original_name,
            })
        }
        Some(proto::message_media::Media::Video(video)) => {
            let video = video
                .video
                .as_ref()
                .ok_or_else(|| CliError::invalid_args("Video media is missing file metadata."))?;
            Ok(MediaDownloadDescriptor {
                kind: "video",
                media_id: video.id,
                extension: "mp4".to_string(),
                original_name: None,
            })
        }
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo
                .photo
                .as_ref()
                .ok_or_else(|| CliError::invalid_args("Photo media is missing file metadata."))?;
            let extension = match proto::photo::Format::try_from(photo.format) {
                Ok(proto::photo::Format::Png) => "png",
                Ok(proto::photo::Format::Jpeg) => "jpg",
                _ => "jpg",
            };
            Ok(MediaDownloadDescriptor {
                kind: "photo",
                media_id: photo.id,
                extension: extension.to_string(),
                original_name: None,
            })
        }
        Some(proto::message_media::Media::Voice(voice)) => {
            let voice = voice
                .voice
                .as_ref()
                .ok_or_else(|| CliError::invalid_args("Voice media is missing file metadata."))?;
            let extension = match voice.mime_type.as_str() {
                "audio/mpeg" => "mp3",
                "audio/wav" | "audio/x-wav" => "wav",
                "audio/flac" => "flac",
                _ => "ogg",
            };
            Ok(MediaDownloadDescriptor {
                kind: "voice",
                media_id: voice.id,
                extension: extension.to_string(),
                original_name: None,
            })
        }
        Some(proto::message_media::Media::Nudge(_)) => Err(CliError::invalid_args(
            "Nudge messages do not contain downloadable media.",
        )),
        None => Err(CliError::invalid_args("Message media is empty.")),
    }
}

fn compact_message_date(timestamp: i64) -> String {
    Utc.timestamp_opt(timestamp, 0)
        .single()
        .map(|date| date.format("%Y%m%d-%H%M").to_string())
        .unwrap_or_else(|| "00000000-0000".to_string())
}

fn available_path(path: PathBuf) -> PathBuf {
    if !path.exists() {
        return path;
    }

    let parent = path.parent().unwrap_or_else(|| Path::new(""));
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("download");
    let extension = path.extension().and_then(|value| value.to_str());

    for suffix in 2.. {
        let file_name = match extension {
            Some(extension) if !extension.is_empty() => format!("{stem}-{suffix}.{extension}"),
            _ => format!("{stem}-{suffix}"),
        };
        let candidate = parent.join(file_name);
        if !candidate.exists() {
            return candidate;
        }
    }

    unreachable!("unbounded suffix loop should return a candidate path")
}

fn media_file_name(media: &proto::MessageMedia) -> Option<String> {
    match &media.media {
        Some(proto::message_media::Media::Document(document)) => document
            .document
            .as_ref()
            .and_then(|doc| sanitize_file_name(&doc.file_name)),
        Some(proto::message_media::Media::Video(video)) => video
            .video
            .as_ref()
            .map(|video| format!("video-{}.mp4", video.id)),
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo.photo.as_ref()?;
            let ext = match proto::photo::Format::try_from(photo.format) {
                Ok(proto::photo::Format::Png) => "png",
                Ok(proto::photo::Format::Jpeg) => "jpg",
                _ => "jpg",
            };
            Some(format!("photo-{}.{}", photo.id, ext))
        }
        Some(proto::message_media::Media::Voice(voice)) => voice.voice.as_ref().map(|voice| {
            let ext = match voice.mime_type.as_str() {
                "audio/mpeg" => "mp3",
                "audio/wav" | "audio/x-wav" => "wav",
                "audio/flac" => "flac",
                _ => "ogg",
            };
            format!("voice-{}.{}", voice.id, ext)
        }),
        Some(proto::message_media::Media::Nudge(_)) => None,
        None => None,
    }
}

fn file_extension(name: &str) -> Option<&str> {
    Path::new(name)
        .extension()
        .and_then(|extension| extension.to_str())
        .filter(|extension| !extension.trim().is_empty())
}

fn sanitize_file_name(name: &str) -> Option<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return None;
    }
    let file_name = std::path::Path::new(trimmed)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(trimmed);
    Some(file_name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_body_preview_trims_empty_and_caps_long_bodies() {
        assert!(http_body_preview("   ").is_none());

        let preview = http_body_preview(&"x".repeat(600)).unwrap();
        assert_eq!(preview.len(), 503);
        assert!(preview.ends_with("..."));
    }

    #[test]
    fn resolve_download_path_prefers_explicit_output() {
        let message = proto::Message {
            id: 42,
            ..Default::default()
        };
        let output = PathBuf::from("custom.bin");

        assert_eq!(
            resolve_download_path(
                &message,
                Some(output.clone()),
                Some(PathBuf::from("downloads"))
            )
            .unwrap(),
            output
        );
    }

    #[test]
    fn resolve_download_path_uses_media_file_name_or_message_fallback() {
        let message = proto::Message {
            id: 42,
            media: Some(proto::MessageMedia {
                media: Some(proto::message_media::Media::Document(
                    proto::MessageDocument {
                        document: Some(proto::Document {
                            file_name: "report.pdf".to_string(),
                            ..Default::default()
                        }),
                    },
                )),
            }),
            ..Default::default()
        };

        assert_eq!(
            resolve_download_path(&message, None, Some(PathBuf::from("downloads"))).unwrap(),
            PathBuf::from("downloads").join("report.pdf")
        );

        let fallback = proto::Message {
            id: 99,
            ..Default::default()
        };
        assert_eq!(
            resolve_download_path(&fallback, None, Some(PathBuf::from("downloads"))).unwrap(),
            PathBuf::from("downloads").join("message-99.bin")
        );
    }

    #[test]
    fn resolve_batch_download_path_prefixes_date_message_and_media_id() {
        let message = proto::Message {
            id: 91,
            date: 0,
            media: Some(proto::MessageMedia {
                media: Some(proto::message_media::Media::Document(
                    proto::MessageDocument {
                        document: Some(proto::Document {
                            id: 9981,
                            file_name: "reports/report.pdf".to_string(),
                            ..Default::default()
                        }),
                    },
                )),
            }),
            ..Default::default()
        };

        assert_eq!(
            resolve_batch_download_path(&message, Path::new("downloads")).unwrap(),
            PathBuf::from("downloads").join("19700101-0000-MSG91-document-9981-report.pdf")
        );
    }

    #[test]
    fn available_path_suffixes_existing_files() {
        let suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "inline-cli-download-path-test-{}-{suffix}",
            std::process::id(),
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let first = dir.join("file.txt");
        std::fs::write(&first, b"existing").unwrap();

        assert_eq!(available_path(first), dir.join("file-2.txt"));
    }
}

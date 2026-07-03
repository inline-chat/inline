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
}

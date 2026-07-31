use std::io;
use std::path::Path;
use std::time::Duration;

use futures_util::StreamExt;
use inline_agent_bridge::{InputAttachment, InputAttachmentKind};
use inline_client::{MediaKind, MessageContent};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

const MAX_LOCAL_ATTACHMENT_BYTES: usize = 20 * 1024 * 1024;
const ATTACHMENT_FETCH_TIMEOUT: Duration = Duration::from_secs(15);

pub(super) struct InboundContent {
    pub text: String,
    pub unsupported_notice: Option<String>,
    pub attachments: Vec<InputAttachment>,
}

pub(super) fn normalize_inbound_content(content: &MessageContent) -> Option<InboundContent> {
    let normalized = match content {
        MessageContent::Text { text } => InboundContent {
            text: text.trim().to_string(),
            unsupported_notice: None,
            attachments: Vec::new(),
        },
        MessageContent::Media {
            caption,
            kind,
            url,
            mime_type,
            file_name,
            size_bytes,
            width,
            height,
            duration_ms,
            ..
        } => {
            let label = file_name
                .as_deref()
                .filter(|name| !name.trim().is_empty())
                .map_or_else(|| format!("{kind:?}").to_lowercase(), str::to_string);
            let text = caption
                    .as_deref()
                    .map(str::trim)
                    .filter(|caption| !caption.is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| default_media_direction(*kind).to_string());
            let attachment = url
                .as_deref()
                .map(str::trim)
                .filter(|url| !url.is_empty())
                .map(|uri| InputAttachment {
                    kind: attachment_kind(*kind),
                    uri: uri.to_string(),
                    local_uri: None,
                    mime_type: mime_type.clone(),
                    file_name: file_name.clone(),
                    size_bytes: *size_bytes,
                    width: *width,
                    height: *height,
                    duration_ms: *duration_ms,
                });
            InboundContent {
                text,
                unsupported_notice: attachment.is_none().then(|| {
                    format!(
                        "I can’t access the attached {label} because Inline did not provide a download URL."
                    )
                }),
                attachments: attachment.into_iter().collect(),
            }
        }
        MessageContent::Unsupported { .. } | _ => InboundContent {
            text: "attachment".to_string(),
            unsupported_notice: Some(
                "I can’t pass this message content to the local agent yet. Send the direction as text."
                    .to_string(),
            ),
            attachments: Vec::new(),
        },
    };

    (!normalized.text.is_empty()).then_some(normalized)
}

/// Adds a private, immutable local file URI to each downloadable attachment.
/// The original Inline URL remains available as a transport fallback, but
/// provider adapters should prefer the local URI so queued work and repeated
/// reads do not depend on a temporary signed URL.
pub(super) async fn materialize_inbound_attachments(
    attachments: &[InputAttachment],
    cache_dir: &Path,
) -> Vec<InputAttachment> {
    let mut materialized = Vec::with_capacity(attachments.len());
    for attachment in attachments {
        let mut attachment = attachment.clone();
        if attachment.local_uri.is_none() {
            match materialize_inbound_attachment(&attachment, cache_dir).await {
                Ok(local_uri) => attachment.local_uri = Some(local_uri),
                Err(error) => log::warn!(
                    target: "inline::bridge::media",
                    "phase=attachment_materialization_failed kind={:?} reason={}",
                    attachment.kind,
                    super::super::safe_diagnostic(&error.to_string())
                ),
            }
        }
        materialized.push(attachment);
    }
    materialized
}

async fn materialize_inbound_attachment(
    attachment: &InputAttachment,
    cache_dir: &Path,
) -> Result<String, Box<dyn std::error::Error>> {
    if attachment
        .size_bytes
        .is_some_and(|size| size == 0 || size > MAX_LOCAL_ATTACHMENT_BYTES as u64)
    {
        return Err(io::Error::other("attachment size is outside the local cache limit").into());
    }
    let url = reqwest::Url::parse(&attachment.uri)
        .map_err(|_| io::Error::other("attachment URL is invalid"))?;
    if url.scheme() != "https" || url.host_str().is_none() {
        return Err(io::Error::other("attachment URL must use HTTPS").into());
    }
    let response = reqwest::Client::builder()
        .timeout(ATTACHMENT_FETCH_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()?
        .get(url)
        .send()
        .await?;
    if !response.status().is_success() {
        return Err(io::Error::other(format!(
            "attachment download returned HTTP {}",
            response.status().as_u16()
        ))
        .into());
    }
    if response
        .content_length()
        .is_some_and(|size| size == 0 || size > MAX_LOCAL_ATTACHMENT_BYTES as u64)
    {
        return Err(
            io::Error::other("attachment download is outside the local cache limit").into(),
        );
    }
    let mut bytes = Vec::with_capacity(
        response
            .content_length()
            .and_then(|size| usize::try_from(size).ok())
            .unwrap_or_default(),
    );
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len().saturating_add(chunk.len()) > MAX_LOCAL_ATTACHMENT_BYTES {
            return Err(io::Error::other("attachment exceeded the local cache limit").into());
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err(io::Error::other("attachment download was empty").into());
    }
    tokio::fs::create_dir_all(cache_dir).await?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    let extension = safe_attachment_extension(attachment);
    let file_name = extension.map_or_else(
        || digest.clone(),
        |extension| format!("{digest}.{extension}"),
    );
    let path = cache_dir.join(file_name);
    match tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .await
    {
        Ok(mut file) => {
            file.write_all(&bytes).await?;
            file.flush().await?;
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            let existing = tokio::fs::read(&path).await?;
            if existing.len() != bytes.len() || Sha256::digest(&existing) != Sha256::digest(&bytes)
            {
                return Err(
                    io::Error::other("cached attachment failed integrity validation").into(),
                );
            }
        }
        Err(error) => return Err(error.into()),
    }
    url::Url::from_file_path(&path)
        .map(|url| url.to_string())
        .map_err(|_| {
            io::Error::other("cached attachment path cannot be represented as a file URL").into()
        })
}

fn safe_attachment_extension(attachment: &InputAttachment) -> Option<String> {
    attachment
        .file_name
        .as_deref()
        .and_then(|name| Path::new(name).extension())
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .filter(|extension| {
            !extension.is_empty()
                && extension.len() <= 12
                && extension.bytes().all(|byte| byte.is_ascii_alphanumeric())
        })
        .or_else(|| {
            attachment
                .mime_type
                .as_deref()
                .and_then(mime_guess::get_mime_extensions_str)
                .and_then(|extensions| extensions.first().copied())
                .map(str::to_string)
        })
}

fn attachment_kind(kind: MediaKind) -> InputAttachmentKind {
    match kind {
        MediaKind::Photo => InputAttachmentKind::Image,
        MediaKind::Voice => InputAttachmentKind::Audio,
        MediaKind::Video => InputAttachmentKind::Video,
        MediaKind::Document => InputAttachmentKind::File,
        _ => InputAttachmentKind::File,
    }
}

fn default_media_direction(kind: MediaKind) -> &'static str {
    match kind {
        MediaKind::Photo => "Review the attached image.",
        MediaKind::Voice => "Review the attached voice message.",
        MediaKind::Video => "Review the attached video.",
        MediaKind::Document => "Review the attached file.",
        _ => "Review the attached media.",
    }
}

#[cfg(test)]
mod tests {
    use inline_client::{MediaKind, MessageContent};

    use super::*;

    #[test]
    fn trims_text_and_ignores_empty_messages() {
        let normalized = normalize_inbound_content(&MessageContent::Text {
            text: "  inspect this  ".to_string(),
        })
        .expect("text content");
        assert_eq!(normalized.text, "inspect this");
        assert_eq!(normalized.unsupported_notice, None);
        assert!(normalized.attachments.is_empty());

        assert!(
            normalize_inbound_content(&MessageContent::Text {
                text: "  \n ".to_string(),
            })
            .is_none()
        );
    }

    #[test]
    fn preserves_media_caption_for_routing_and_names_the_attachment() {
        let normalized = normalize_inbound_content(&MessageContent::Media {
            kind: MediaKind::Document,
            file_id: "file-1".to_string(),
            url: None,
            mime_type: Some("text/plain".to_string()),
            file_name: Some("notes.txt".to_string()),
            caption: Some("  /help  ".to_string()),
            size_bytes: None,
            width: None,
            height: None,
            duration_ms: None,
        })
        .expect("media content");

        assert_eq!(normalized.text, "/help");
        assert_eq!(
            normalized.unsupported_notice.as_deref(),
            Some(
                "I can’t access the attached notes.txt because Inline did not provide a download URL."
            )
        );
        assert!(normalized.attachments.is_empty());
    }

    #[test]
    fn uses_media_kind_when_the_attachment_has_no_name() {
        let normalized = normalize_inbound_content(&MessageContent::Media {
            kind: MediaKind::Photo,
            file_id: "file-2".to_string(),
            url: None,
            mime_type: None,
            file_name: None,
            caption: None,
            size_bytes: None,
            width: None,
            height: None,
            duration_ms: None,
        })
        .expect("media content");

        assert_eq!(normalized.text, "Review the attached image.");
        assert!(
            normalized
                .unsupported_notice
                .as_deref()
                .is_some_and(|notice| notice.contains("attached photo"))
        );
    }

    #[test]
    fn unsupported_content_has_provider_neutral_recovery_copy() {
        let normalized = normalize_inbound_content(&MessageContent::Unsupported {
            reason: "redacted".to_string(),
        })
        .expect("unsupported content");

        assert_eq!(normalized.text, "attachment");
        assert_eq!(
            normalized.unsupported_notice.as_deref(),
            Some(
                "I can’t pass this message content to the local agent yet. Send the direction as text."
            )
        );
        assert!(normalized.attachments.is_empty());
    }

    #[test]
    fn preserves_downloadable_media_as_a_provider_neutral_attachment() {
        let normalized = normalize_inbound_content(&MessageContent::Media {
            kind: MediaKind::Photo,
            file_id: "file-3".to_string(),
            url: Some("https://cdn.inline.chat/photo.jpg".to_string()),
            mime_type: Some("image/jpeg".to_string()),
            file_name: Some("photo.jpg".to_string()),
            caption: Some("inspect this".to_string()),
            size_bytes: Some(42),
            width: Some(10),
            height: Some(10),
            duration_ms: None,
        })
        .expect("media content");

        assert_eq!(normalized.text, "inspect this");
        assert_eq!(normalized.unsupported_notice, None);
        assert_eq!(normalized.attachments.len(), 1);
        assert_eq!(normalized.attachments[0].kind, InputAttachmentKind::Image);
        assert_eq!(
            normalized.attachments[0].uri,
            "https://cdn.inline.chat/photo.jpg"
        );
    }
}

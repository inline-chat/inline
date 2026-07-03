use std::collections::HashMap;

use crate::media::best_photo_size;
use crate::output::{
    AttachmentSummary, MediaSummary, MessageListOutput, MessageSummary, PeerSummary, format_bytes,
    format_relative_date, user_summary,
};
use crate::protocol::proto;

pub(crate) fn build_message_list(
    result: proto::GetChatHistoryResult,
    users_by_id: &HashMap<i64, proto::User>,
    current_user_id: Option<i64>,
    peer: Option<PeerSummary>,
    peer_name: Option<String>,
    translations_by_id: Option<&HashMap<i64, proto::MessageTranslation>>,
) -> MessageListOutput {
    build_message_list_from_messages(
        &result.messages,
        users_by_id,
        current_user_id,
        peer,
        peer_name,
        translations_by_id,
    )
}

pub(crate) fn build_message_list_from_messages(
    messages: &[proto::Message],
    users_by_id: &HashMap<i64, proto::User>,
    current_user_id: Option<i64>,
    peer: Option<PeerSummary>,
    peer_name: Option<String>,
    translations_by_id: Option<&HashMap<i64, proto::MessageTranslation>>,
) -> MessageListOutput {
    let now = current_epoch_seconds() as i64;
    let items = messages
        .iter()
        .map(|message| {
            message_summary(
                message,
                users_by_id,
                current_user_id,
                now,
                translations_by_id,
            )
        })
        .collect();
    MessageListOutput {
        items,
        peer,
        peer_name,
    }
}

pub(crate) fn message_summary(
    message: &proto::Message,
    users_by_id: &HashMap<i64, proto::User>,
    current_user_id: Option<i64>,
    now: i64,
    translations_by_id: Option<&HashMap<i64, proto::MessageTranslation>>,
) -> MessageSummary {
    let media = message_media_summary(message);
    let attachments = message_attachment_summaries(message);
    let translation = translations_by_id
        .and_then(|translations| translations.get(&message.id))
        .cloned();
    let preview = message_preview(message, media.as_ref(), &attachments, translation.as_ref());
    let sender = users_by_id.get(&message.from_id).map(user_summary);
    let sender_name = if message.out || current_user_id == Some(message.from_id) {
        "You".to_string()
    } else if let Some(sender) = &sender {
        sender.display_name.clone()
    } else {
        format!("user {}", message.from_id)
    };
    let relative_date = format_relative_date(message.date, now);
    MessageSummary {
        message: message.clone(),
        preview,
        translation,
        sender,
        sender_name,
        relative_date,
        media,
        attachments,
    }
}

fn message_preview(
    message: &proto::Message,
    media: Option<&MediaSummary>,
    attachments: &[AttachmentSummary],
    translation: Option<&proto::MessageTranslation>,
) -> String {
    let mut parts = Vec::new();
    let mut original_text = None;
    if let Some(text) = message.message.as_deref() {
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            let normalized = normalize_preview_text(trimmed);
            original_text = Some(normalized.clone());
            parts.push(normalized);
        }
    }

    if let Some(translation) = translation {
        let trimmed = translation.translation.trim();
        if !trimmed.is_empty() {
            let normalized = normalize_preview_text(trimmed);
            if original_text.as_deref() != Some(normalized.as_str()) {
                parts.push(format!("tr({}): {}", translation.language, normalized));
            }
        }
    }

    if let Some(media) = media {
        parts.push(media_preview(media));
    }

    for attachment in attachments {
        parts.push(attachment_preview(attachment));
    }

    if parts.is_empty() {
        return "<non-text>".to_string();
    }

    parts.join(" ")
}

fn normalize_preview_text(value: &str) -> String {
    value
        .replace(['\n', '\r'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn message_media_summary(message: &proto::Message) -> Option<MediaSummary> {
    let media = message.media.as_ref()?;
    match &media.media {
        Some(proto::message_media::Media::Document(document)) => {
            let document = document.document.as_ref()?;
            Some(MediaSummary {
                kind: "document".to_string(),
                file_name: Some(document.file_name.clone()),
                mime_type: Some(document.mime_type.clone()),
                size: Some(document.size),
                duration: None,
                width: None,
                height: None,
                url: document.cdn_url.clone(),
            })
        }
        Some(proto::message_media::Media::Video(video)) => {
            let video = video.video.as_ref()?;
            Some(MediaSummary {
                kind: "video".to_string(),
                file_name: None,
                mime_type: None,
                size: Some(video.size),
                duration: Some(video.duration),
                width: Some(video.w),
                height: Some(video.h),
                url: video.cdn_url.clone(),
            })
        }
        Some(proto::message_media::Media::Photo(photo)) => {
            let photo = photo.photo.as_ref()?;
            let (url, size, width, height) = best_photo_size(photo);
            Some(MediaSummary {
                kind: "photo".to_string(),
                file_name: None,
                mime_type: None,
                size,
                duration: None,
                width,
                height,
                url,
            })
        }
        Some(proto::message_media::Media::Voice(voice)) => {
            let voice = voice.voice.as_ref()?;
            Some(MediaSummary {
                kind: "voice".to_string(),
                file_name: None,
                mime_type: Some(voice.mime_type.clone()),
                size: Some(voice.size),
                duration: Some(voice.duration),
                width: None,
                height: None,
                url: voice.cdn_url.clone(),
            })
        }
        Some(proto::message_media::Media::Nudge(_)) => Some(MediaSummary {
            kind: "nudge".to_string(),
            file_name: None,
            mime_type: None,
            size: None,
            duration: None,
            width: None,
            height: None,
            url: None,
        }),
        None => None,
    }
}

fn message_attachment_summaries(message: &proto::Message) -> Vec<AttachmentSummary> {
    let mut items = Vec::new();
    if let Some(attachments) = message.attachments.as_ref() {
        for attachment in &attachments.attachments {
            match &attachment.attachment {
                Some(proto::message_attachment::Attachment::UrlPreview(preview)) => {
                    items.push(AttachmentSummary {
                        kind: "url_preview".to_string(),
                        title: preview.title.clone(),
                        url: preview.url.clone(),
                        site_name: preview.site_name.clone(),
                        application: None,
                        status: None,
                        number: None,
                        assigned_user_id: None,
                    });
                }
                Some(proto::message_attachment::Attachment::ExternalTask(task)) => {
                    items.push(AttachmentSummary {
                        kind: "external_task".to_string(),
                        title: Some(task.title.clone()),
                        url: Some(task.url.clone()),
                        site_name: None,
                        application: Some(task.application.clone()),
                        status: Some(format_external_status(task.status)),
                        number: Some(task.number.clone()),
                        assigned_user_id: Some(task.assigned_user_id),
                    });
                }
                None => {}
            }
        }
    }
    items
}

fn format_external_status(status: i32) -> String {
    match proto::message_attachment_external_task::Status::try_from(status) {
        Ok(proto::message_attachment_external_task::Status::Backlog) => "backlog".to_string(),
        Ok(proto::message_attachment_external_task::Status::Todo) => "todo".to_string(),
        Ok(proto::message_attachment_external_task::Status::InProgress) => {
            "in_progress".to_string()
        }
        Ok(proto::message_attachment_external_task::Status::Done) => "done".to_string(),
        Ok(proto::message_attachment_external_task::Status::Cancelled) => "cancelled".to_string(),
        _ => "unknown".to_string(),
    }
}

fn media_preview(media: &MediaSummary) -> String {
    match media.kind.as_str() {
        "document" => {
            let mut label = String::from("[file");
            if let Some(name) = &media.file_name {
                label.push_str(&format!(": {}", name));
            }
            if let Some(mime) = &media.mime_type {
                label.push_str(&format!(" {}", mime));
            }
            if let Some(size) = media.size {
                label.push_str(&format!(" {}", format_bytes(size as i64)));
            }
            label.push(']');
            label
        }
        "video" => {
            let mut label = String::from("[video");
            if let Some(duration) = media.duration {
                label.push_str(&format!(" {}s", duration));
            }
            if let Some(size) = media.size {
                label.push_str(&format!(" {}", format_bytes(size as i64)));
            }
            label.push(']');
            label
        }
        "photo" => "[photo]".to_string(),
        _ => "[media]".to_string(),
    }
}

fn attachment_preview(attachment: &AttachmentSummary) -> String {
    match attachment.kind.as_str() {
        "url_preview" => {
            if let Some(title) = &attachment.title {
                format!("[link: {}]", title)
            } else if let Some(site) = &attachment.site_name {
                format!("[link: {}]", site)
            } else if let Some(url) = &attachment.url {
                format!("[link: {}]", url)
            } else {
                "[link]".to_string()
            }
        }
        "external_task" => {
            let mut label = String::from("[task");
            if let Some(app) = &attachment.application {
                label.push_str(&format!(" {}", app));
            }
            if let Some(title) = &attachment.title {
                label.push_str(&format!(": {}", title));
            }
            label.push(']');
            label
        }
        _ => "[attachment]".to_string(),
    }
}

fn current_epoch_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_summary_uses_sender_name_preview_and_relative_date() {
        let now = 1_700_000_000;
        let users_by_id: HashMap<i64, proto::User> = [(
            42,
            proto::User {
                id: 42,
                first_name: Some("Sam".to_string()),
                ..Default::default()
            },
        )]
        .into_iter()
        .collect();
        let message = proto::Message {
            id: 7,
            from_id: 42,
            message: Some(" hello\n  world ".to_string()),
            date: now - 120,
            ..Default::default()
        };

        let summary = message_summary(&message, &users_by_id, Some(1), now, None);

        assert_eq!(summary.sender_name, "Sam");
        assert_eq!(summary.preview, "hello world");
        assert_eq!(summary.relative_date, "2m ago");
    }

    #[test]
    fn message_summary_uses_you_for_outgoing_messages() {
        let now = 1_700_000_000;
        let message = proto::Message {
            id: 7,
            from_id: 42,
            out: true,
            message: Some("sent".to_string()),
            date: now,
            ..Default::default()
        };

        let summary = message_summary(&message, &HashMap::new(), None, now, None);

        assert_eq!(summary.sender_name, "You");
    }

    #[test]
    fn preview_includes_distinct_translation_media_and_task() {
        let now = 1_700_000_000;
        let translations_by_id: HashMap<i64, proto::MessageTranslation> = [(
            7,
            proto::MessageTranslation {
                message_id: 7,
                language: "es".to_string(),
                translation: "hola".to_string(),
                ..Default::default()
            },
        )]
        .into_iter()
        .collect();
        let message = proto::Message {
            id: 7,
            from_id: 42,
            message: Some("hello".to_string()),
            date: now,
            media: Some(proto::MessageMedia {
                media: Some(proto::message_media::Media::Video(proto::MessageVideo {
                    video: Some(proto::Video {
                        size: 1_572_864,
                        duration: 12,
                        ..Default::default()
                    }),
                })),
            }),
            attachments: Some(proto::MessageAttachments {
                attachments: vec![proto::MessageAttachment {
                    id: 99,
                    attachment: Some(proto::message_attachment::Attachment::ExternalTask(
                        proto::MessageAttachmentExternalTask {
                            id: 88,
                            task_id: "task-1".to_string(),
                            title: "Fix login".to_string(),
                            url: "https://linear.example/ISSUE-1".to_string(),
                            application: "linear".to_string(),
                            status: proto::message_attachment_external_task::Status::InProgress
                                as i32,
                            number: "ISSUE-1".to_string(),
                            assigned_user_id: 42,
                            date: now,
                        },
                    )),
                }],
            }),
            ..Default::default()
        };

        let summary = message_summary(
            &message,
            &HashMap::new(),
            None,
            now,
            Some(&translations_by_id),
        );

        assert_eq!(
            summary.preview,
            "hello tr(es): hola [video 12s 1.5MB] [task linear: Fix login]"
        );
    }
}

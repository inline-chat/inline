use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Debug, Error, PartialEq, Eq)]
#[error("{kind} must not be empty")]
pub struct InvalidIdentifier {
    kind: &'static str,
}

macro_rules! string_id {
    ($name:ident, $kind:literal) => {
        #[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn new(value: impl Into<String>) -> Result<Self, InvalidIdentifier> {
                let value = value.into();
                if value.trim().is_empty() {
                    return Err(InvalidIdentifier { kind: $kind });
                }
                Ok(Self(value))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }
    };
}

string_id!(InstallationId, "installation id");
string_id!(WorkspaceId, "workspace id");
string_id!(ProviderId, "provider id");
string_id!(ProviderSessionId, "provider session id");
string_id!(TurnId, "turn id");
string_id!(DirectionId, "direction id");
string_id!(QueueItemId, "queue item id");

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BindingKey {
    pub installation_id: InstallationId,
    pub chat_id: i64,
    pub workspace_id: WorkspaceId,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Direction {
    pub id: DirectionId,
    pub text: String,
    #[serde(default)]
    pub attachments: Vec<InputAttachment>,
}

impl Direction {
    pub fn new(id: DirectionId, text: impl Into<String>) -> Self {
        Self {
            id,
            text: text.into(),
            attachments: Vec::new(),
        }
    }

    pub fn with_attachments(mut self, attachments: Vec<InputAttachment>) -> Self {
        self.attachments = attachments;
        self
    }
}

/// Provider-neutral kind of one attachment included with a user direction.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputAttachmentKind {
    Image,
    Audio,
    Video,
    File,
}

/// Durable, bounded descriptor for media supplied with a user direction.
///
/// Payload bytes are deliberately not persisted in the bridge database. A
/// provider adapter may consume the remote URI directly. The bridge may also
/// materialize the payload into its private cache and supply a read-only local
/// file URI so every driver can refer to the same bytes without another
/// network fetch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputAttachment {
    pub kind: InputAttachmentKind,
    pub uri: String,
    #[serde(default)]
    pub local_uri: Option<String>,
    pub mime_type: Option<String>,
    pub file_name: Option<String>,
    pub size_bytes: Option<u64>,
    /// Display width reported by Inline for image or video media.
    #[serde(default)]
    pub width: Option<u32>,
    /// Display height reported by Inline for image or video media.
    #[serde(default)]
    pub height: Option<u32>,
    /// Media duration reported by Inline, in milliseconds.
    #[serde(default)]
    pub duration_ms: Option<u64>,
}

/// Provider-neutral kind of one artifact produced by an agent turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputAttachmentKind {
    /// A raster image intended for Inline's native photo surface.
    Image,
}

/// Durable descriptor for an immutable local artifact produced by a provider.
///
/// The bridge re-reads the file only after verifying its exact byte length and
/// SHA-256 digest. This lets final-send recovery replay the upload without
/// trusting a provider-controlled path after the original event is gone.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputAttachment {
    /// Provider-owned stable identity within the turn.
    pub id: String,
    /// Media category exposed to Inline.
    pub kind: OutputAttachmentKind,
    /// Absolute local artifact path.
    pub path: PathBuf,
    /// Verified MIME type.
    pub mime_type: String,
    /// Safe display file name.
    pub file_name: String,
    /// Exact payload length.
    pub size_bytes: u64,
    /// Lowercase hexadecimal SHA-256 digest of the payload.
    pub sha256: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_reject_blank_values() {
        assert_eq!(
            TurnId::new("  "),
            Err(InvalidIdentifier { kind: "turn id" })
        );
    }

    #[test]
    fn identifiers_round_trip_through_json() {
        let id = ProviderSessionId::new("thread-1").expect("valid id");
        let encoded = serde_json::to_string(&id).expect("serialize id");
        assert_eq!(encoded, "\"thread-1\"");
        assert_eq!(
            serde_json::from_str::<ProviderSessionId>(&encoded).expect("deserialize id"),
            id
        );
    }

    #[test]
    fn legacy_input_attachments_decode_without_a_local_uri() {
        let attachment = serde_json::from_str::<InputAttachment>(
            r#"{"kind":"file","uri":"https://cdn.inline.chat/report.pdf","mime_type":"application/pdf","file_name":"report.pdf","size_bytes":42}"#,
        )
        .expect("legacy attachment");
        assert_eq!(attachment.local_uri, None);
    }
}

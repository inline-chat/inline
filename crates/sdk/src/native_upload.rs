//! Durable, resumable native upload support shared by Realtime V2 and V3.

use crate::{
    InlineProtocolV3Connection, InlineProtocolV3Error, RealtimeClient, RealtimeError,
    RealtimeSession,
};
use inline_protocol::proto;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

const HASH_READ_SIZE: usize = 1024 * 1024;
const MAX_NEGOTIATED_PART_SIZE: u32 = 16 * 1024 * 1024;
const MAX_PROCESSING_RETRY_SECONDS: u64 = 30;

fn bounded_processing_retry_seconds(seconds: u32) -> u64 {
    u64::from(seconds.max(1)).min(MAX_PROCESSING_RETRY_SECONDS)
}

/// High-level file input for a native Inline upload.
#[derive(Clone, Debug)]
pub struct NativeUploadInput {
    /// Local file to read in bounded chunks.
    pub path: PathBuf,
    /// File name presented to recipients.
    pub file_name: String,
    /// MIME type supplied to media processing.
    pub mime_type: String,
    /// Media pipeline selected for the completed upload.
    pub kind: proto::UploadKind,
    /// Stable 16-byte retry identity. A random value is generated when absent.
    pub client_upload_id: Option<[u8; 16]>,
    /// Completed photo used as the video's thumbnail.
    pub thumbnail_file_unique_id: Option<String>,
    /// Optional video metadata.
    pub video: Option<proto::UploadVideoMetadata>,
    /// Optional voice metadata.
    pub voice: Option<proto::UploadVoiceMetadata>,
}

impl NativeUploadInput {
    /// Creates a file upload with no kind-specific metadata.
    pub fn new(
        path: impl Into<PathBuf>,
        file_name: impl Into<String>,
        mime_type: impl Into<String>,
        kind: proto::UploadKind,
    ) -> Self {
        Self {
            path: path.into(),
            file_name: file_name.into(),
            mime_type: mime_type.into(),
            kind,
            client_upload_id: None,
            thumbnail_file_unique_id: None,
            video: None,
            voice: None,
        }
    }
}

/// Authoritative progress reported after the server accepts a part.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeUploadProgress {
    /// Bytes durably accepted by the server.
    pub accepted_bytes: u64,
    /// Total source size.
    pub total_bytes: u64,
}

/// Native upload failure.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum NativeUploadError {
    /// The source cannot be opened or changed while being uploaded.
    #[error("upload source error: {0}")]
    Source(#[from] std::io::Error),
    /// Realtime V2 transport or RPC failed.
    #[error("Realtime V2 upload failed: {0}")]
    V2(#[from] RealtimeError),
    /// Realtime V3 transport or RPC failed.
    #[error("Realtime V3 upload failed: {0}")]
    V3(#[from] InlineProtocolV3Error),
    /// The server returned invalid upload geometry or an unexpected result.
    #[error("invalid native upload response")]
    Protocol,
    /// Media processing rejected the complete file.
    #[error("upload finalization failed (code {code}, retryable: {retryable})")]
    Rejected {
        /// Protocol failure code.
        code: i32,
        /// Whether retrying may succeed.
        retryable: bool,
    },
    /// The server canceled the upload before it completed.
    #[error("upload canceled by server")]
    Canceled,
    /// The server expired the upload before it completed.
    #[error("upload expired before completion")]
    Expired,
}

enum Transport<'a> {
    V2(&'a mut RealtimeClient),
    V2Session(&'a RealtimeSession),
    V3(&'a mut InlineProtocolV3Connection),
}

trait NativeUploadTransport {
    async fn create(
        &mut self,
        input: proto::CreateUploadInput,
    ) -> Result<proto::CreateUploadResult, NativeUploadError>;
    async fn save(
        &mut self,
        input: proto::SaveUploadPartInput,
    ) -> Result<proto::SaveUploadPartResult, NativeUploadError>;
    async fn state(
        &mut self,
        upload_id: Vec<u8>,
    ) -> Result<proto::GetUploadStateResult, NativeUploadError>;
    async fn finish(
        &mut self,
        upload_id: Vec<u8>,
    ) -> Result<proto::FinishUploadResult, NativeUploadError>;
}

impl NativeUploadTransport for Transport<'_> {
    async fn create(
        &mut self,
        input: proto::CreateUploadInput,
    ) -> Result<proto::CreateUploadResult, NativeUploadError> {
        Ok(match self {
            Self::V2(client) => client.call(input).await?,
            Self::V2Session(client) => client.call(input).await?,
            Self::V3(client) => client.call(input).await?,
        })
    }

    async fn save(
        &mut self,
        input: proto::SaveUploadPartInput,
    ) -> Result<proto::SaveUploadPartResult, NativeUploadError> {
        Ok(match self {
            Self::V2(client) => client.call(input).await?,
            Self::V2Session(client) => client.call(input).await?,
            Self::V3(client) => client.call(input).await?,
        })
    }

    async fn state(
        &mut self,
        upload_id: Vec<u8>,
    ) -> Result<proto::GetUploadStateResult, NativeUploadError> {
        let input = proto::GetUploadStateInput { upload_id };
        Ok(match self {
            Self::V2(client) => client.call(input).await?,
            Self::V2Session(client) => client.call(input).await?,
            Self::V3(client) => client.call(input).await?,
        })
    }

    async fn finish(
        &mut self,
        upload_id: Vec<u8>,
    ) -> Result<proto::FinishUploadResult, NativeUploadError> {
        let input = proto::FinishUploadInput { upload_id };
        Ok(match self {
            Self::V2(client) => client.call(input).await?,
            Self::V2Session(client) => client.call(input).await?,
            Self::V3(client) => client.call(input).await?,
        })
    }
}

/// Uploads a file through the typed Realtime V2 RPC carrier.
pub async fn upload_file_v2(
    client: &mut RealtimeClient,
    input: NativeUploadInput,
    mut progress: impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    upload(Transport::V2(client), input, &mut progress).await
}

/// Uploads a file through a multiplexed typed Realtime V2 session.
pub async fn upload_file_session(
    client: &RealtimeSession,
    input: NativeUploadInput,
    mut progress: impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    upload(Transport::V2Session(client), input, &mut progress).await
}

/// Uploads a file through the secure Realtime V3 RPC carrier.
pub async fn upload_file_v3(
    client: &mut InlineProtocolV3Connection,
    input: NativeUploadInput,
    mut progress: impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    upload(Transport::V3(client), input, &mut progress).await
}

async fn upload(
    transport: Transport<'_>,
    input: NativeUploadInput,
    progress: &mut impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    upload_with_transport(transport, input, progress).await
}

async fn upload_with_transport(
    mut transport: impl NativeUploadTransport,
    input: NativeUploadInput,
    progress: &mut impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    let mut file = tokio::fs::File::open(&input.path).await?;
    let byte_count = file.metadata().await?.len();
    if byte_count == 0 {
        return Err(NativeUploadError::Protocol);
    }
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; HASH_READ_SIZE];
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let client_upload_id = input
        .client_upload_id
        .unwrap_or_else(|| *uuid::Uuid::new_v4().as_bytes());
    let metadata = match (input.video, input.voice) {
        (Some(video), None) => Some(proto::create_upload_input::Metadata::Video(video)),
        (None, Some(voice)) => Some(proto::create_upload_input::Metadata::Voice(voice)),
        (None, None) => None,
        _ => return Err(NativeUploadError::Protocol),
    };
    let created = transport
        .create(proto::CreateUploadInput {
            client_upload_id: client_upload_id.to_vec(),
            file_name: input.file_name,
            mime_type: input.mime_type,
            byte_count,
            sha256: hasher.finalize().to_vec(),
            kind: input.kind as i32,
            thumbnail_file_unique_id: input.thumbnail_file_unique_id,
            metadata,
        })
        .await?;
    let expected_parts = byte_count.div_ceil(u64::from(created.part_size));
    if created.upload_id.len() != 16
        || created.part_size == 0
        || created.part_size > MAX_NEGOTIATED_PART_SIZE
        || created.part_count == 0
        || u64::from(created.part_count) != expected_parts
    {
        return Err(NativeUploadError::Protocol);
    }

    let mut accepted = vec![false; created.part_count as usize];
    for index in created.accepted_parts {
        let Some(slot) = accepted.get_mut(index as usize) else {
            return Err(NativeUploadError::Protocol);
        };
        *slot = true;
    }
    report_progress(&accepted, created.part_size, byte_count, progress);

    loop {
        for index in 0..created.part_count {
            if accepted[index as usize] {
                continue;
            }
            let offset = u64::from(index) * u64::from(created.part_size);
            let length = u64::from(created.part_size).min(byte_count - offset) as usize;
            let mut part = vec![0_u8; length];
            file.seek(std::io::SeekFrom::Start(offset)).await?;
            file.read_exact(&mut part).await?;
            let save = transport
                .save(proto::SaveUploadPartInput {
                    upload_id: created.upload_id.clone(),
                    part_index: index,
                    data: part,
                })
                .await;
            if let Err(error) = save {
                let state = transport.state(created.upload_id.clone()).await;
                match state {
                    Ok(state) if state.accepted_parts.contains(&index) => {}
                    _ => return Err(error),
                }
            }
            accepted[index as usize] = true;
            report_progress(&accepted, created.part_size, byte_count, progress);
        }

        let finish = match transport.finish(created.upload_id.clone()).await {
            Ok(finish) => finish,
            Err(error) if is_ambiguous_finish_error(&error) => {
                let state = match transport.state(created.upload_id.clone()).await {
                    Ok(state) => state,
                    Err(_) => return Err(error),
                };
                match proto::UploadStatus::try_from(state.status) {
                    Ok(proto::UploadStatus::Uploading) => {
                        accepted.fill(false);
                        for index in state.accepted_parts {
                            let Some(slot) = accepted.get_mut(index as usize) else {
                                return Err(NativeUploadError::Protocol);
                            };
                            *slot = true;
                        }
                    }
                    Ok(proto::UploadStatus::Processing) => {
                        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    }
                    Ok(proto::UploadStatus::Complete) => {
                        return state.complete.ok_or(NativeUploadError::Protocol);
                    }
                    Ok(proto::UploadStatus::Failed) => {
                        let failure = state.failure.ok_or(NativeUploadError::Protocol)?;
                        return Err(NativeUploadError::Rejected {
                            code: failure.code,
                            retryable: failure.retryable,
                        });
                    }
                    Ok(proto::UploadStatus::Canceled) => {
                        return Err(NativeUploadError::Canceled);
                    }
                    Ok(proto::UploadStatus::Expired) => {
                        return Err(NativeUploadError::Expired);
                    }
                    Ok(proto::UploadStatus::Unspecified) | Err(_) => {
                        return Err(NativeUploadError::Protocol);
                    }
                }
                continue;
            }
            Err(error) => return Err(error),
        };
        match finish.state.ok_or(NativeUploadError::Protocol)? {
            proto::finish_upload_result::State::Complete(complete) => return Ok(complete),
            proto::finish_upload_result::State::Missing(missing) => {
                for index in missing.part_indices {
                    let Some(slot) = accepted.get_mut(index as usize) else {
                        return Err(NativeUploadError::Protocol);
                    };
                    *slot = false;
                }
            }
            proto::finish_upload_result::State::Processing(processing) => {
                tokio::time::sleep(std::time::Duration::from_secs(
                    bounded_processing_retry_seconds(processing.retry_after_seconds),
                ))
                .await;
            }
            proto::finish_upload_result::State::Failed(failure) => {
                return Err(NativeUploadError::Rejected {
                    code: failure.code,
                    retryable: failure.retryable,
                });
            }
        }
    }
}

fn is_ambiguous_finish_error(error: &NativeUploadError) -> bool {
    matches!(
        error,
        NativeUploadError::V2(
            RealtimeError::CommitOutcomeUnknown | RealtimeError::ConnectionClosed
        ) | NativeUploadError::V3(
            InlineProtocolV3Error::CommitOutcomeUnknown | InlineProtocolV3Error::Closed
        )
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_authenticated_processing_retry_hints() {
        assert_eq!(bounded_processing_retry_seconds(0), 1);
        assert_eq!(bounded_processing_retry_seconds(2), 2);
        assert_eq!(bounded_processing_retry_seconds(u32::MAX), 30);
    }

    struct LostResponseTransport {
        accepted: bool,
        lose_response: bool,
        lose_finish_response: bool,
        finish_state: Option<ReconciledState>,
        calls: Vec<&'static str>,
    }

    #[derive(Clone, Copy)]
    enum ReconciledState {
        Complete,
        Failed,
        Canceled,
        Expired,
    }

    impl NativeUploadTransport for LostResponseTransport {
        async fn create(
            &mut self,
            _input: proto::CreateUploadInput,
        ) -> Result<proto::CreateUploadResult, NativeUploadError> {
            self.calls.push("create");
            Ok(proto::CreateUploadResult {
                upload_id: vec![7; 16],
                part_size: 512 * 1024,
                part_count: 1,
                expires_at: 1_900_000_000,
                accepted_parts: vec![],
            })
        }

        async fn save(
            &mut self,
            input: proto::SaveUploadPartInput,
        ) -> Result<proto::SaveUploadPartResult, NativeUploadError> {
            self.calls.push("save");
            assert_eq!(input.part_index, 0);
            assert_eq!(input.data, vec![1, 2, 3]);
            self.accepted = true;
            if self.lose_response {
                self.lose_response = false;
                return Err(NativeUploadError::Protocol);
            }
            Ok(proto::SaveUploadPartResult {
                already_present: false,
            })
        }

        async fn state(
            &mut self,
            upload_id: Vec<u8>,
        ) -> Result<proto::GetUploadStateResult, NativeUploadError> {
            self.calls.push("state");
            assert_eq!(upload_id, vec![7; 16]);
            if let Some(finish_state) = self.finish_state {
                return Ok(match finish_state {
                    ReconciledState::Complete => proto::GetUploadStateResult {
                        status: proto::UploadStatus::Complete as i32,
                        accepted_parts: vec![0],
                        complete: Some(proto::UploadComplete {
                            file_unique_id: "INDnative".into(),
                            media: None,
                        }),
                        failure: None,
                    },
                    ReconciledState::Failed => proto::GetUploadStateResult {
                        status: proto::UploadStatus::Failed as i32,
                        accepted_parts: vec![0],
                        complete: None,
                        failure: Some(proto::UploadFailure {
                            code: proto::upload_failure::Code::UploadFailureInvalidMedia as i32,
                            retryable: false,
                        }),
                    },
                    ReconciledState::Canceled => proto::GetUploadStateResult {
                        status: proto::UploadStatus::Canceled as i32,
                        accepted_parts: vec![0],
                        complete: None,
                        failure: None,
                    },
                    ReconciledState::Expired => proto::GetUploadStateResult {
                        status: proto::UploadStatus::Expired as i32,
                        accepted_parts: vec![0],
                        complete: None,
                        failure: None,
                    },
                });
            }
            Ok(proto::GetUploadStateResult {
                status: proto::UploadStatus::Uploading as i32,
                accepted_parts: if self.accepted { vec![0] } else { vec![] },
                complete: None,
                failure: None,
            })
        }

        async fn finish(
            &mut self,
            upload_id: Vec<u8>,
        ) -> Result<proto::FinishUploadResult, NativeUploadError> {
            self.calls.push("finish");
            assert_eq!(upload_id, vec![7; 16]);
            if self.lose_finish_response {
                self.lose_finish_response = false;
                if self.finish_state.is_none() {
                    self.finish_state = Some(ReconciledState::Complete);
                }
                return Err(NativeUploadError::V3(
                    InlineProtocolV3Error::CommitOutcomeUnknown,
                ));
            }
            Ok(proto::FinishUploadResult {
                state: Some(proto::finish_upload_result::State::Complete(
                    proto::UploadComplete {
                        file_unique_id: "INDnative".into(),
                        media: None,
                    },
                )),
            })
        }
    }

    #[tokio::test]
    async fn reconciles_a_part_committed_before_its_response_was_lost() {
        let path = std::env::temp_dir().join(format!(
            "inline-native-upload-test-{}",
            uuid::Uuid::new_v4()
        ));
        tokio::fs::write(&path, [1_u8, 2, 3]).await.unwrap();
        let transport = LostResponseTransport {
            accepted: false,
            lose_response: true,
            lose_finish_response: false,
            finish_state: None,
            calls: vec![],
        };
        let mut progress = vec![];
        let result = upload_with_transport(
            transport,
            NativeUploadInput::new(
                &path,
                "proof.bin",
                "application/octet-stream",
                proto::UploadKind::Document,
            ),
            &mut |value| progress.push(value.accepted_bytes),
        )
        .await
        .unwrap();
        tokio::fs::remove_file(&path).await.unwrap();

        assert_eq!(result.file_unique_id, "INDnative");
        assert_eq!(progress, vec![0, 3]);
    }

    #[tokio::test]
    async fn reconciles_finish_committed_before_its_response_was_lost() {
        let result = run_lost_finish(None).await.unwrap();

        assert_eq!(result.file_unique_id, "INDnative");
    }

    #[tokio::test]
    async fn preserves_authoritative_failed_finish_state() {
        let error = run_lost_finish(Some(ReconciledState::Failed))
            .await
            .unwrap_err();

        assert!(matches!(
            error,
            NativeUploadError::Rejected {
                code,
                retryable: false
            } if code == proto::upload_failure::Code::UploadFailureInvalidMedia as i32
        ));
    }

    #[tokio::test]
    async fn preserves_authoritative_canceled_finish_state() {
        let error = run_lost_finish(Some(ReconciledState::Canceled))
            .await
            .unwrap_err();

        assert!(matches!(error, NativeUploadError::Canceled));
    }

    #[tokio::test]
    async fn preserves_authoritative_expired_finish_state() {
        let error = run_lost_finish(Some(ReconciledState::Expired))
            .await
            .unwrap_err();

        assert!(matches!(error, NativeUploadError::Expired));
    }

    async fn run_lost_finish(
        finish_state: Option<ReconciledState>,
    ) -> Result<proto::UploadComplete, NativeUploadError> {
        let path = std::env::temp_dir().join(format!(
            "inline-native-upload-finish-state-test-{}",
            uuid::Uuid::new_v4()
        ));
        tokio::fs::write(&path, [1_u8, 2, 3]).await.unwrap();
        let transport = LostResponseTransport {
            accepted: false,
            lose_response: false,
            lose_finish_response: true,
            finish_state,
            calls: vec![],
        };
        let result = upload_with_transport(
            transport,
            NativeUploadInput::new(
                &path,
                "proof.bin",
                "application/octet-stream",
                proto::UploadKind::Document,
            ),
            &mut |_| {},
        )
        .await;
        tokio::fs::remove_file(&path).await.unwrap();
        result
    }
}

fn report_progress(
    accepted: &[bool],
    part_size: u32,
    byte_count: u64,
    progress: &mut impl FnMut(NativeUploadProgress),
) {
    let accepted_bytes = accepted
        .iter()
        .enumerate()
        .filter(|(_, accepted)| **accepted)
        .map(|(index, _)| {
            let offset = index as u64 * u64::from(part_size);
            u64::from(part_size).min(byte_count - offset)
        })
        .sum();
    progress(NativeUploadProgress {
        accepted_bytes,
        total_bytes: byte_count,
    });
}

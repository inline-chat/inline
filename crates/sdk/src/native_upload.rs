//! Durable, resumable native upload support shared by Realtime V2 and V3.

use crate::{
    InlineProtocolV3Connection, InlineProtocolV3Error, RealtimeClient, RealtimeError,
    RealtimeSession,
};
use futures_util::stream::{FuturesUnordered, StreamExt as _};
use inline_protocol::proto;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

const HASH_READ_SIZE: usize = 1024 * 1024;
const NEGOTIATED_PART_SIZE: u32 = 512 * 1024;
const MAX_NEGOTIATED_PARTS: u32 = 1_000;
const MAX_PROCESSING_RETRY_SECONDS: u64 = 30;
const MAX_V3_RESUME_ATTEMPTS: u32 = 3;
const MAX_PART_SAVE_ATTEMPTS: u32 = 3;
const RECONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const PROCESSING_TIMEOUT: Duration = Duration::from_secs(600);
/// Parts in flight per file on a multiplexed session (the server admits 64
/// applications per account session and per-part saves are idempotent).
const PARALLEL_PARTS: usize = 4;

fn bounded_processing_retry_seconds(seconds: u32) -> u64 {
    u64::from(seconds.max(1)).min(MAX_PROCESSING_RETRY_SECONDS)
}

fn valid_upload_geometry(created: &proto::CreateUploadResult, byte_count: u64) -> bool {
    if created.upload_id.len() != 16
        || created.part_size == 0
        || created.part_size != NEGOTIATED_PART_SIZE
        || created.part_count == 0
        || created.part_count > MAX_NEGOTIATED_PARTS
    {
        return false;
    }
    u64::from(created.part_count) == byte_count.div_ceil(u64::from(created.part_size))
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
    /// All bytes were accepted, but media processing did not finish in time.
    /// Retrying with the same upload identity reconciles the existing upload.
    #[error("upload processing timed out; retry with the same upload identity")]
    ProcessingTimedOut,
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
    /// Another handle to the same carrier that may run calls concurrently with
    /// this one, when the carrier multiplexes requests.
    fn fork(&self) -> Option<Self>
    where
        Self: Sized,
    {
        None
    }
}

impl NativeUploadTransport for Transport<'_> {
    fn fork(&self) -> Option<Self> {
        match self {
            Self::V2Session(session) => Some(Self::V2Session(session)),
            Self::V2(_) | Self::V3(_) => None,
        }
    }

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
    mut input: NativeUploadInput,
    mut progress: impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    // The retry identity must outlive the carrier. Reusing it makes create,
    // part saves, and finish reconciliation safe after an abrupt disconnect.
    input
        .client_upload_id
        .get_or_insert_with(|| *uuid::Uuid::new_v4().as_bytes());
    let mut resume_attempts = 0;
    let mut accepted_high_water = 0;
    loop {
        let result = upload(
            Transport::V3(client),
            input.clone(),
            &mut |accepted: NativeUploadProgress| {
                if accepted.accepted_bytes > accepted_high_water {
                    accepted_high_water = accepted.accepted_bytes;
                    resume_attempts = 0;
                }
                progress(accepted);
            },
        )
        .await;
        match result {
            Ok(complete) => return Ok(complete),
            Err(error)
                if resumable_v3_upload_error(&error)
                    && resume_attempts < MAX_V3_RESUME_ATTEMPTS =>
            {
                loop {
                    resume_attempts += 1;
                    tokio::time::sleep(v3_resume_delay(resume_attempts)).await;
                    match tokio::time::timeout(RECONNECT_TIMEOUT, client.reconnect())
                        .await
                        .unwrap_or(Err(InlineProtocolV3Error::Timeout))
                    {
                        Ok(reconnected) => {
                            *client = reconnected;
                            break;
                        }
                        Err(error)
                            if resumable_v3_transport_error(&error)
                                && resume_attempts < MAX_V3_RESUME_ATTEMPTS => {}
                        Err(error) => return Err(NativeUploadError::V3(error)),
                    }
                }
            }
            Err(error) => return Err(error),
        }
    }
}

/// Uploads through a separate V3 transfer session with several parts in
/// flight, then, if that carrier fails, resumes on `client` with the same
/// upload identity (accepted parts are reconciled, not resent).
pub async fn upload_file_v3_parallel(
    client: &mut InlineProtocolV3Connection,
    mut input: NativeUploadInput,
    mut progress: impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    input
        .client_upload_id
        .get_or_insert_with(|| *uuid::Uuid::new_v4().as_bytes());
    // A second carrier pays for itself only beyond a few parts.
    let worth_parallel = tokio::fs::metadata(&input.path)
        .await
        .is_ok_and(|metadata| {
            metadata.len() > u64::from(NEGOTIATED_PART_SIZE) * PARALLEL_PARTS as u64
        });
    if worth_parallel
        && let Ok(Ok(session)) =
            tokio::time::timeout(RECONNECT_TIMEOUT, client.open_transfer_session()).await
    {
        match upload(Transport::V2Session(&session), input.clone(), &mut progress).await {
            Ok(complete) => return Ok(complete),
            Err(NativeUploadError::V2(error)) => {
                log::debug!(target: "inline::upload", "transfer session failed, resuming on the main connection: {error}");
            }
            Err(error) => return Err(error),
        }
    }
    upload_file_v3(client, input, progress).await
}

fn resumable_v3_upload_error(error: &NativeUploadError) -> bool {
    matches!(error, NativeUploadError::V3(error) if resumable_v3_transport_error(error))
}

fn resumable_v3_transport_error(error: &InlineProtocolV3Error) -> bool {
    matches!(
        error,
        InlineProtocolV3Error::CommitOutcomeUnknown
            | InlineProtocolV3Error::Closed
            | InlineProtocolV3Error::Timeout
            | InlineProtocolV3Error::WebSocket(_)
    )
}

fn v3_resume_delay(attempt: u32) -> std::time::Duration {
    std::time::Duration::from_millis(250 * u64::from(1_u32 << attempt.saturating_sub(1).min(3)))
}

async fn upload(
    transport: Transport<'_>,
    input: NativeUploadInput,
    progress: &mut impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    upload_with_transport(transport, input, progress).await
}

async fn upload_with_transport(
    transport: impl NativeUploadTransport,
    input: NativeUploadInput,
    progress: &mut impl FnMut(NativeUploadProgress),
) -> Result<proto::UploadComplete, NativeUploadError> {
    upload_with_processing_timeout(transport, input, progress, PROCESSING_TIMEOUT).await
}

async fn upload_with_processing_timeout(
    mut transport: impl NativeUploadTransport,
    input: NativeUploadInput,
    progress: &mut impl FnMut(NativeUploadProgress),
    processing_timeout: Duration,
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
    if !valid_upload_geometry(&created, byte_count) {
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
    let mut processing_deadline = None;

    loop {
        let missing: Vec<u32> = (0..created.part_count)
            .filter(|index| !accepted[*index as usize])
            .collect();
        if !missing.is_empty() {
            // Missing bytes return the upload to transfer. A previous
            // processing deadline must never cancel a healthy retransmission.
            processing_deadline = None;
        }
        if transport.fork().is_some() {
            let mut queue = missing.into_iter();
            let mut in_flight = FuturesUnordered::new();
            loop {
                while in_flight.len() < PARALLEL_PARTS {
                    let Some(index) = queue.next() else { break };
                    let part = read_part(&mut file, index, created.part_size, byte_count).await?;
                    let mut fork = transport.fork().ok_or(NativeUploadError::Protocol)?;
                    let upload_id = created.upload_id.clone();
                    in_flight.push(async move {
                        (index, save_part(&mut fork, &upload_id, index, part).await)
                    });
                }
                // Dropping the remaining saves on an early return abandons only
                // idempotent part writes; the manifest stays authoritative.
                let Some((index, outcome)) = in_flight.next().await else {
                    break;
                };
                if let Some(complete) = outcome? {
                    return Ok(complete);
                }
                accepted[index as usize] = true;
                report_progress(&accepted, created.part_size, byte_count, progress);
            }
        } else {
            for index in missing {
                let part = read_part(&mut file, index, created.part_size, byte_count).await?;
                if let Some(complete) =
                    save_part(&mut transport, &created.upload_id, index, part).await?
                {
                    return Ok(complete);
                }
                accepted[index as usize] = true;
                report_progress(&accepted, created.part_size, byte_count, progress);
            }
        }

        let deadline = *processing_deadline
            .get_or_insert_with(|| tokio::time::Instant::now() + processing_timeout);
        let finish =
            match tokio::time::timeout_at(deadline, transport.finish(created.upload_id.clone()))
                .await
                .map_err(|_| NativeUploadError::ProcessingTimedOut)?
            {
                Ok(finish) => finish,
                Err(error) if is_ambiguous_finish_error(&error) => {
                    let state = match tokio::time::timeout_at(
                        deadline,
                        transport.state(created.upload_id.clone()),
                    )
                    .await
                    .map_err(|_| NativeUploadError::ProcessingTimedOut)?
                    {
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
                            tokio::time::timeout_at(
                                deadline,
                                tokio::time::sleep(Duration::from_secs(1)),
                            )
                            .await
                            .map_err(|_| NativeUploadError::ProcessingTimedOut)?;
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
                if missing.part_indices.is_empty() {
                    return Err(NativeUploadError::Protocol);
                }
                for index in missing.part_indices {
                    let Some(slot) = accepted.get_mut(index as usize) else {
                        return Err(NativeUploadError::Protocol);
                    };
                    *slot = false;
                }
            }
            proto::finish_upload_result::State::Processing(processing) => {
                tokio::time::timeout_at(
                    deadline,
                    tokio::time::sleep(Duration::from_secs(bounded_processing_retry_seconds(
                        processing.retry_after_seconds,
                    ))),
                )
                .await
                .map_err(|_| NativeUploadError::ProcessingTimedOut)?;
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

async fn read_part(
    file: &mut tokio::fs::File,
    index: u32,
    part_size: u32,
    byte_count: u64,
) -> Result<Vec<u8>, NativeUploadError> {
    let offset = u64::from(index) * u64::from(part_size);
    let length = u64::from(part_size).min(byte_count - offset) as usize;
    let mut part = vec![0_u8; length];
    file.seek(std::io::SeekFrom::Start(offset)).await?;
    file.read_exact(&mut part).await?;
    Ok(part)
}

/// Saves one part, reconciling an ambiguous failure against the manifest.
/// Returns the completed upload when reconciliation finds it already complete.
async fn save_part(
    transport: &mut impl NativeUploadTransport,
    upload_id: &[u8],
    index: u32,
    part: Vec<u8>,
) -> Result<Option<proto::UploadComplete>, NativeUploadError> {
    let mut save_attempts = 0;
    loop {
        let save = transport
            .save(proto::SaveUploadPartInput {
                upload_id: upload_id.to_vec(),
                part_index: index,
                data: part.clone(),
            })
            .await;
        let Err(error) = save else {
            return Ok(None);
        };
        let state = match transport.state(upload_id.to_vec()).await {
            Ok(state) => state,
            Err(_) => return Err(error),
        };
        match proto::UploadStatus::try_from(state.status) {
            Ok(proto::UploadStatus::Complete) => {
                return state.complete.ok_or(NativeUploadError::Protocol).map(Some);
            }
            Ok(proto::UploadStatus::Failed) => {
                let failure = state.failure.ok_or(NativeUploadError::Protocol)?;
                return Err(NativeUploadError::Rejected {
                    code: failure.code,
                    retryable: failure.retryable,
                });
            }
            Ok(proto::UploadStatus::Canceled) => return Err(NativeUploadError::Canceled),
            Ok(proto::UploadStatus::Expired) => return Err(NativeUploadError::Expired),
            Ok(proto::UploadStatus::Uploading | proto::UploadStatus::Processing)
                if state.accepted_parts.contains(&index) =>
            {
                return Ok(None);
            }
            Ok(proto::UploadStatus::Uploading) => {}
            Ok(proto::UploadStatus::Processing | proto::UploadStatus::Unspecified) | Err(_) => {
                return Err(NativeUploadError::Protocol);
            }
        }
        save_attempts += 1;
        if save_attempts >= MAX_PART_SAVE_ATTEMPTS {
            return Err(error);
        }
        tokio::time::sleep(std::time::Duration::from_millis(
            100 * u64::from(1_u32 << save_attempts.saturating_sub(1)),
        ))
        .await;
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
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::*;

    #[test]
    fn bounds_authenticated_processing_retry_hints() {
        assert_eq!(bounded_processing_retry_seconds(0), 1);
        assert_eq!(bounded_processing_retry_seconds(2), 2);
        assert_eq!(bounded_processing_retry_seconds(u32::MAX), 30);
    }

    #[test]
    fn rejects_invalid_geometry_before_division_or_allocation() {
        let mut created = proto::CreateUploadResult {
            upload_id: vec![7; 16],
            part_size: 0,
            part_count: 1,
            expires_at: 1_900_000_000,
            accepted_parts: vec![],
        };
        assert!(!valid_upload_geometry(&created, 1));

        created.part_size = NEGOTIATED_PART_SIZE;
        created.part_count = MAX_NEGOTIATED_PARTS + 1;
        assert!(!valid_upload_geometry(
            &created,
            u64::from(NEGOTIATED_PART_SIZE) * u64::from(created.part_count),
        ));

        created.part_count = 1;
        assert!(valid_upload_geometry(&created, 3));
    }

    #[test]
    fn classifies_only_transient_v3_carrier_failures_for_resume() {
        assert!(resumable_v3_transport_error(&InlineProtocolV3Error::Closed));
        assert!(resumable_v3_transport_error(
            &InlineProtocolV3Error::Timeout
        ));
        assert!(!resumable_v3_transport_error(
            &InlineProtocolV3Error::AuthorizationInvalidated,
        ));
        assert_eq!(v3_resume_delay(1), std::time::Duration::from_millis(250));
        assert_eq!(v3_resume_delay(3), std::time::Duration::from_secs(1));
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

    struct StalledProcessing(LostResponseTransport);

    impl NativeUploadTransport for StalledProcessing {
        async fn create(
            &mut self,
            input: proto::CreateUploadInput,
        ) -> Result<proto::CreateUploadResult, NativeUploadError> {
            self.0.create(input).await
        }

        async fn save(
            &mut self,
            input: proto::SaveUploadPartInput,
        ) -> Result<proto::SaveUploadPartResult, NativeUploadError> {
            self.0.save(input).await
        }

        async fn state(
            &mut self,
            upload_id: Vec<u8>,
        ) -> Result<proto::GetUploadStateResult, NativeUploadError> {
            self.0.state(upload_id).await
        }

        async fn finish(
            &mut self,
            _: Vec<u8>,
        ) -> Result<proto::FinishUploadResult, NativeUploadError> {
            std::future::pending().await
        }
    }

    #[derive(Default)]
    struct ConcurrentState {
        in_flight: usize,
        max_in_flight: usize,
        saved: std::collections::BTreeSet<u32>,
        fail_once: Option<u32>,
    }

    #[derive(Clone, Default)]
    struct ConcurrentTransport(std::sync::Arc<std::sync::Mutex<ConcurrentState>>);

    impl NativeUploadTransport for ConcurrentTransport {
        async fn create(
            &mut self,
            input: proto::CreateUploadInput,
        ) -> Result<proto::CreateUploadResult, NativeUploadError> {
            Ok(proto::CreateUploadResult {
                upload_id: vec![9; 16],
                part_size: NEGOTIATED_PART_SIZE,
                part_count: input.byte_count.div_ceil(u64::from(NEGOTIATED_PART_SIZE)) as u32,
                expires_at: 1_900_000_000,
                accepted_parts: vec![],
            })
        }

        async fn save(
            &mut self,
            input: proto::SaveUploadPartInput,
        ) -> Result<proto::SaveUploadPartResult, NativeUploadError> {
            {
                let mut state = self.0.lock().unwrap();
                state.in_flight += 1;
                state.max_in_flight = state.max_in_flight.max(state.in_flight);
            }
            tokio::time::sleep(Duration::from_millis(15)).await;
            let mut state = self.0.lock().unwrap();
            state.in_flight -= 1;
            state.saved.insert(input.part_index);
            if state.fail_once == Some(input.part_index) {
                state.fail_once = None;
                // The part was stored; only its response was lost.
                return Err(NativeUploadError::Protocol);
            }
            Ok(proto::SaveUploadPartResult {
                already_present: false,
            })
        }

        async fn state(
            &mut self,
            _upload_id: Vec<u8>,
        ) -> Result<proto::GetUploadStateResult, NativeUploadError> {
            Ok(proto::GetUploadStateResult {
                status: proto::UploadStatus::Uploading as i32,
                accepted_parts: self.0.lock().unwrap().saved.iter().copied().collect(),
                complete: None,
                failure: None,
            })
        }

        async fn finish(
            &mut self,
            _upload_id: Vec<u8>,
        ) -> Result<proto::FinishUploadResult, NativeUploadError> {
            Ok(proto::FinishUploadResult {
                state: Some(proto::finish_upload_result::State::Complete(
                    proto::UploadComplete {
                        file_unique_id: "INDparallel".into(),
                        media: None,
                    },
                )),
            })
        }

        fn fork(&self) -> Option<Self> {
            Some(self.clone())
        }
    }

    #[tokio::test]
    async fn multiplexed_carriers_keep_four_parts_in_flight_and_reconcile_each() {
        let path = std::env::temp_dir().join(format!("inline-parallel-{}", uuid::Uuid::new_v4()));
        let bytes = vec![5_u8; NEGOTIATED_PART_SIZE as usize * 10 + 7];
        tokio::fs::write(&path, &bytes).await.unwrap();
        let transport = ConcurrentTransport::default();
        transport.0.lock().unwrap().fail_once = Some(3);
        let mut progress = vec![];
        let result = upload_with_processing_timeout(
            transport.clone(),
            NativeUploadInput::new(
                &path,
                "parallel.bin",
                "application/octet-stream",
                proto::UploadKind::Document,
            ),
            &mut |value| progress.push(value.accepted_bytes),
            Duration::from_secs(5),
        )
        .await
        .unwrap();
        assert_eq!(result.file_unique_id, "INDparallel");
        {
            let state = transport.0.lock().unwrap();
            assert_eq!(state.max_in_flight, PARALLEL_PARTS);
            assert_eq!(state.saved, (0..11).collect());
        }
        assert_eq!(*progress.last().unwrap(), bytes.len() as u64);
        tokio::fs::remove_file(path).await.unwrap();
    }

    #[tokio::test]
    async fn stalled_finalization_expires_after_accepted_bytes_without_deleting_the_source() {
        let path = std::env::temp_dir().join(format!(
            "inline-processing-timeout-{}",
            uuid::Uuid::new_v4()
        ));
        tokio::fs::write(&path, [1_u8, 2, 3]).await.unwrap();
        let transport = StalledProcessing(LostResponseTransport {
            accepted: false,
            lose_response: false,
            lose_finish_response: false,
            finish_state: None,
            calls: vec![],
        });
        let mut progress = vec![];
        let result = upload_with_processing_timeout(
            transport,
            NativeUploadInput::new(
                &path,
                "proof.bin",
                "application/octet-stream",
                proto::UploadKind::Document,
            ),
            &mut |value| progress.push(value.accepted_bytes),
            Duration::from_millis(10),
        )
        .await;
        assert!(matches!(result, Err(NativeUploadError::ProcessingTimedOut)));
        assert_eq!(progress, vec![0, 3]);
        assert_eq!(tokio::fs::read(&path).await.unwrap(), [1, 2, 3]);
        tokio::fs::remove_file(path).await.unwrap();
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

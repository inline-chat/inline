//! Explicit single-document range downloads. Healthy V2 and V3 carriers are
//! supported; replacement-carrier recovery currently applies to V2 only.

use crate::errors::CliError;
use crate::{
    AuthenticatedRealtime, clear_owned_authority_if_invalidated, connect_realtime,
    resumable_v2_upload_error,
};
use inline_protocol::proto;
use inline_sdk::{RealtimeError, RpcRequest};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

const PART_SIZE: u32 = 512 * 1024;
const MAX_DOCUMENT_BYTES: u64 = 500_000_000;
const RPC_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
struct FilePartRequest(proto::GetFilePartInput);

impl RpcRequest for FilePartRequest {
    type Response = proto::GetFilePartResult;
    const METHOD: proto::Method = proto::Method::GetFilePart;

    fn into_rpc_input(self) -> proto::rpc_call::Input {
        proto::rpc_call::Input::GetFilePart(self.0)
    }

    fn response_from_rpc_result(
        result: proto::rpc_result::Result,
    ) -> Result<Self::Response, RealtimeError> {
        match result {
            proto::rpc_result::Result::GetFilePart(part) => Ok(part),
            _ => Err(RealtimeError::UnexpectedResult {
                method: "getFilePart",
                expected: "getFilePart",
                actual: "another RPC result",
            }),
        }
    }
}

trait FilePartFetching {
    async fn fetch_part(
        &mut self,
        request: proto::GetFilePartInput,
    ) -> Result<proto::GetFilePartResult, Box<dyn std::error::Error>>;
}

impl FilePartFetching for AuthenticatedRealtime {
    async fn fetch_part(
        &mut self,
        request: proto::GetFilePartInput,
    ) -> Result<proto::GetFilePartResult, Box<dyn std::error::Error>> {
        let mut failures = 0;
        loop {
            let result =
                tokio::time::timeout(RPC_TIMEOUT, self.call(FilePartRequest(request.clone())))
                    .await;
            let error = match result {
                Ok(Ok(part)) => return Ok(part),
                Ok(Err(error)) => error,
                Err(_) => Box::new(RealtimeError::Timeout {
                    operation: "native download RPC",
                    timeout: RPC_TIMEOUT,
                }),
            };
            if server_range_timed_out(error.as_ref()) {
                if failures >= 3 {
                    return Err(error);
                }
                failures += 1;
                // The server bounded its storage read; this carrier remains
                // healthy. Retry the read with a fresh RPC ID at the same offset.
                tokio::time::sleep(Duration::from_millis(250 * (1 << (failures - 1)))).await;
                continue;
            }
            let retryable = error
                .downcast_ref::<RealtimeError>()
                .is_some_and(resumable_v2_upload_error);
            if !retryable || failures >= 3 {
                return Err(error);
            }
            let Self::V2 {
                connection,
                authority_owner,
                url,
                token,
            } = self
            else {
                return Err(error);
            };
            loop {
                failures += 1;
                tokio::time::sleep(Duration::from_millis(250 * (1 << (failures - 1)))).await;
                let reconnected = tokio::time::timeout(RPC_TIMEOUT, connect_realtime(url, token))
                    .await
                    .unwrap_or_else(|_| {
                        Err(RealtimeError::Timeout {
                            operation: "native download reconnect",
                            timeout: RPC_TIMEOUT,
                        })
                    });
                match reconnected {
                    Ok(reconnected) => {
                        *connection = reconnected;
                        break;
                    }
                    Err(error) if resumable_v2_upload_error(&error) && failures < 3 => {}
                    Err(error) => {
                        clear_owned_authority_if_invalidated(
                            authority_owner.as_ref(),
                            matches!(error, RealtimeError::AuthenticationInvalidated),
                        )?;
                        return Err(error.into());
                    }
                }
            }
        }
    }
}

fn server_range_timed_out(error: &(dyn std::error::Error + 'static)) -> bool {
    let internal_error = proto::rpc_error::Code::InternalError as i32;
    matches!(error.downcast_ref::<RealtimeError>(),
        Some(RealtimeError::RpcError { code: 408, error_code, .. }) if *error_code == internal_error)
        || matches!(error.downcast_ref::<inline_sdk::InlineProtocolV3Error>(),
            Some(inline_sdk::InlineProtocolV3Error::Rpc { status: 408, error_code, .. }) if *error_code == internal_error)
}

pub(crate) async fn download_message_document(
    realtime: &mut AuthenticatedRealtime,
    message: &proto::Message,
    output: &Path,
) -> Result<u64, Box<dyn std::error::Error>> {
    let Some(proto::message_media::Media::Document(media)) = message
        .media
        .as_ref()
        .and_then(|media| media.media.as_ref())
    else {
        return Err(
            CliError::invalid_args("--native currently requires a document message").into(),
        );
    };
    let document = media
        .document
        .as_ref()
        .ok_or_else(|| CliError::invalid_args("Document metadata is missing"))?;
    let file_id = document
        .file_unique_id
        .as_ref()
        .filter(|id| valid_file_id(id))
        .ok_or_else(|| CliError::invalid_args("Document has no native file identity"))?;
    if document.size <= 0
        || document.size as u64 > MAX_DOCUMENT_BYTES
        || !(1..=i64::from(i32::MAX)).contains(&message.chat_id)
        || !(1..=i64::from(i32::MAX)).contains(&message.id)
    {
        return Err(CliError::invalid_args(
            "Document size or message locator is invalid for native download",
        )
        .into());
    }
    download_ranges(
        realtime,
        proto::GetFilePartInput {
            file_unique_id: file_id.clone(),
            offset: 0,
            limit: PART_SIZE,
            message: Some(proto::FileMessageLocation {
                chat_id: message.chat_id,
                message_id: message.id,
            }),
        },
        document.size as u64,
        output,
    )
    .await
}

fn valid_file_id(id: &str) -> bool {
    (6..=128).contains(&id.len())
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

async fn download_ranges(
    transport: &mut impl FilePartFetching,
    mut request: proto::GetFilePartInput,
    expected_size: u64,
    output: &Path,
) -> Result<u64, Box<dyn std::error::Error>> {
    if output.exists() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "Native download destination already exists",
        )
        .into());
    }
    let parent = output
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    tokio::fs::create_dir_all(parent).await?;
    let staged = tempfile::Builder::new()
        .prefix(".inline-download-")
        .tempfile_in(parent)?;
    let mut file = tokio::fs::File::from_std(staged.reopen()?);
    while request.offset < expected_size {
        let part = transport.fetch_part(request.clone()).await?;
        validate_part(&request, &part, expected_size)?;
        file.write_all(&part.data).await?;
        request.offset += part.data.len() as u64;
        log::debug!(target: "inline::download", "download accepted {}/{} bytes", request.offset, expected_size);
    }
    file.flush().await?;
    file.sync_all().await?;
    drop(file);
    staged.persist_noclobber(output)?;
    Ok(request.offset)
}

fn validate_part(
    request: &proto::GetFilePartInput,
    part: &proto::GetFilePartResult,
    expected_size: u64,
) -> Result<(), CliError> {
    if part.offset != request.offset
        || part.total_size != expected_size
        || part.total_size > MAX_DOCUMENT_BYTES
        || request.offset >= expected_size
        || part.data.len() as u64 != u64::from(request.limit).min(expected_size - request.offset)
        || part.sha256.len() != 32
    {
        return Err(CliError::invalid_args(
            "Invalid native download range response",
        ));
    }
    if Sha256::digest(&part.data).as_slice() != part.sha256 {
        return Err(CliError::invalid_args(
            "Native download range failed its SHA-256 integrity check",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Cli, Command, MessagesCommand};
    use clap::Parser;
    use futures_util::{SinkExt, StreamExt};
    use prost::Message;
    use tokio::net::{TcpListener, TcpStream};
    use tokio_tungstenite::{WebSocketStream, accept_async, tungstenite::Message as WsMessage};

    #[derive(Clone, Copy)]
    enum Corruption {
        Hash,
        Offset,
        Total,
        ShortRange,
    }

    struct MemoryFetcher {
        bytes: Vec<u8>,
        offsets: Vec<u64>,
        corruption: Option<Corruption>,
        competing_output: Option<std::path::PathBuf>,
    }

    fn request() -> proto::GetFilePartInput {
        proto::GetFilePartInput {
            file_unique_id: "IND_fixture".into(),
            offset: 0,
            limit: PART_SIZE,
            message: Some(proto::FileMessageLocation {
                chat_id: 12,
                message_id: 34,
            }),
        }
    }

    fn range(bytes: &[u8], request: &proto::GetFilePartInput) -> proto::GetFilePartResult {
        let start = request.offset as usize;
        let end = bytes.len().min(start + request.limit as usize);
        let data = bytes[start..end].to_vec();
        proto::GetFilePartResult {
            offset: request.offset,
            total_size: bytes.len() as u64,
            sha256: Sha256::digest(&data).to_vec(),
            data,
        }
    }

    impl FilePartFetching for MemoryFetcher {
        async fn fetch_part(
            &mut self,
            request: proto::GetFilePartInput,
        ) -> Result<proto::GetFilePartResult, Box<dyn std::error::Error>> {
            self.offsets.push(request.offset);
            let mut part = range(&self.bytes, &request);
            if request.offset > 0 {
                if let Some(output) = self.competing_output.take() {
                    tokio::fs::write(output, b"keep competing file").await?;
                }
                match self.corruption {
                    Some(Corruption::Hash) => part.sha256[0] ^= 1,
                    Some(Corruption::Offset) => part.offset += 1,
                    Some(Corruption::Total) => part.total_size += 1,
                    Some(Corruption::ShortRange) => {
                        part.data.pop();
                    }
                    None => {}
                }
            }
            Ok(part)
        }
    }

    fn memory(corruption: Option<Corruption>) -> MemoryFetcher {
        MemoryFetcher {
            bytes: vec![19; PART_SIZE as usize + 17],
            offsets: Vec::new(),
            corruption,
            competing_output: None,
        }
    }

    #[tokio::test]
    async fn downloads_bounded_verified_ranges_then_publishes_complete_file() {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("complete.bin");
        let mut transport = memory(None);
        let size = transport.bytes.len() as u64;
        assert_eq!(
            download_ranges(&mut transport, request(), size, &output)
                .await
                .unwrap(),
            size
        );
        assert_eq!(transport.offsets, vec![0, u64::from(PART_SIZE)]);
        assert_eq!(tokio::fs::read(&output).await.unwrap(), transport.bytes);
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[tokio::test]
    async fn corrupt_or_inconsistent_later_ranges_never_publish_partial_output() {
        for corruption in [
            Corruption::Hash,
            Corruption::Offset,
            Corruption::Total,
            Corruption::ShortRange,
        ] {
            let directory = tempfile::tempdir().unwrap();
            let output = directory.path().join("failed.bin");
            let mut transport = memory(Some(corruption));
            let size = transport.bytes.len() as u64;
            assert!(
                download_ranges(&mut transport, request(), size, &output)
                    .await
                    .is_err()
            );
            assert!(!output.exists());
            assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
        }
    }

    #[tokio::test]
    async fn existing_destination_is_preserved_without_fetching() {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("existing.bin");
        tokio::fs::write(&output, b"keep me").await.unwrap();
        let mut transport = memory(None);
        let size = transport.bytes.len() as u64;
        assert!(
            download_ranges(&mut transport, request(), size, &output)
                .await
                .is_err()
        );
        assert_eq!(tokio::fs::read(&output).await.unwrap(), b"keep me");
        assert!(transport.offsets.is_empty());
    }

    #[tokio::test]
    async fn publication_does_not_overwrite_a_destination_created_during_transfer() {
        let directory = tempfile::tempdir().unwrap();
        let output = directory.path().join("competing.bin");
        let mut transport = memory(None);
        transport.competing_output = Some(output.clone());
        let size = transport.bytes.len() as u64;
        assert!(
            download_ranges(&mut transport, request(), size, &output)
                .await
                .is_err()
        );
        assert_eq!(
            tokio::fs::read(&output).await.unwrap(),
            b"keep competing file"
        );
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn parses_explicit_native_download() {
        let cli = Cli::try_parse_from([
            "inline",
            "messages",
            "download",
            "--chat-id",
            "12",
            "--message-id",
            "34",
            "--native",
            "--output",
            "fixture.bin",
        ])
        .unwrap();
        assert!(
            matches!(cli.command, Command::Messages { command: MessagesCommand::Download(args) } if args.native)
        );
    }

    async fn next_client_message(ws: &mut WebSocketStream<TcpStream>) -> proto::ClientMessage {
        loop {
            match ws.next().await.unwrap().unwrap() {
                WsMessage::Binary(bytes) => return proto::ClientMessage::decode(&*bytes).unwrap(),
                WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
                frame => panic!("unexpected frame: {frame:?}"),
            }
        }
    }

    async fn send(ws: &mut WebSocketStream<TcpStream>, body: proto::server_protocol_message::Body) {
        ws.send(WsMessage::Binary(
            proto::ServerProtocolMessage {
                id: 1,
                body: Some(body),
            }
            .encode_to_vec()
            .into(),
        ))
        .await
        .unwrap();
    }

    async fn exercise_reconnect(always_lose: bool) {
        tokio::time::timeout(Duration::from_secs(10), async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("ws://{}/realtime", listener.local_addr().unwrap());
            let source = vec![19; PART_SIZE as usize + 17];
            let bytes = source.clone();
            let server = tokio::spawn(async move {
                let mut offsets = Vec::new();
                for carrier in 0..if always_lose { 4 } else { 2 } {
                    let (stream, _) = listener.accept().await.unwrap();
                    let mut ws = accept_async(stream).await.unwrap();
                    assert!(matches!(
                        next_client_message(&mut ws).await.body,
                        Some(proto::client_message::Body::ConnectionInit(_))
                    ));
                    send(
                        &mut ws,
                        proto::server_protocol_message::Body::ConnectionOpen(
                            proto::ConnectionOpen {},
                        ),
                    )
                    .await;
                    loop {
                        let message = next_client_message(&mut ws).await;
                        let Some(proto::client_message::Body::RpcCall(call)) = message.body else {
                            continue;
                        };
                        let Some(proto::rpc_call::Input::GetFilePart(input)) = call.input else {
                            panic!("unexpected RPC");
                        };
                        assert_eq!(input.file_unique_id, request().file_unique_id);
                        assert_eq!(input.message, request().message);
                        assert_eq!(input.limit, PART_SIZE);
                        offsets.push(input.offset);
                        if always_lose || (carrier == 0 && input.offset > 0) {
                            ws.close(None).await.unwrap();
                            break;
                        }
                        let part = range(&bytes, &input);
                        let last = part.offset + part.data.len() as u64 == part.total_size;
                        send(
                            &mut ws,
                            proto::server_protocol_message::Body::RpcResult(proto::RpcResult {
                                req_msg_id: message.id,
                                result: Some(proto::rpc_result::Result::GetFilePart(part)),
                            }),
                        )
                        .await;
                        if last {
                            break;
                        }
                    }
                }
                offsets
            });
            let connection = connect_realtime(&url, "local-test-token").await.unwrap();
            let mut realtime = AuthenticatedRealtime::V2 {
                connection,
                authority_owner: None,
                url,
                token: "local-test-token".into(),
            };
            let directory = tempfile::tempdir().unwrap();
            let output = directory.path().join("reconnected.bin");
            let result =
                download_ranges(&mut realtime, request(), source.len() as u64, &output).await;
            let offsets = server.await.unwrap();
            if always_lose {
                assert!(result.is_err());
                assert_eq!(offsets, vec![0, 0, 0, 0]);
                assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
            } else {
                assert_eq!(result.unwrap(), source.len() as u64);
                assert_eq!(offsets, vec![0, u64::from(PART_SIZE), u64::from(PART_SIZE)]);
                assert_eq!(tokio::fs::read(output).await.unwrap(), source);
            }
        })
        .await
        .expect("native download must terminate within its retry budget");
    }

    #[tokio::test]
    async fn carrier_loss_retries_the_same_range_without_duplicate_output() {
        exercise_reconnect(false).await;
    }

    #[tokio::test]
    async fn repeated_carrier_loss_stops_after_three_reconnects_and_cleans_partial() {
        exercise_reconnect(true).await;
    }

    async fn exercise_server_timeout(failures: usize) {
        tokio::time::timeout(Duration::from_secs(10), async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("ws://{}/realtime", listener.local_addr().unwrap());
            let server = tokio::spawn(async move {
                let (stream, _) = listener.accept().await.unwrap();
                let mut ws = accept_async(stream).await.unwrap();
                assert!(matches!(
                    next_client_message(&mut ws).await.body,
                    Some(proto::client_message::Body::ConnectionInit(_))
                ));
                send(
                    &mut ws,
                    proto::server_protocol_message::Body::ConnectionOpen(proto::ConnectionOpen {}),
                )
                .await;
                let mut previous_request_id = 0;
                for attempt in 0..failures.min(3) + 1 {
                    let message = next_client_message(&mut ws).await;
                    assert!(
                        message.id > previous_request_id,
                        "range retry must have a fresh RPC identity"
                    );
                    previous_request_id = message.id;
                    let Some(proto::client_message::Body::RpcCall(call)) = message.body else {
                        panic!("unexpected request");
                    };
                    assert_eq!(
                        call.input,
                        Some(proto::rpc_call::Input::GetFilePart(request()))
                    );
                    if attempt < failures {
                        send(
                            &mut ws,
                            proto::server_protocol_message::Body::RpcError(proto::RpcError {
                                req_msg_id: message.id,
                                error_code: proto::rpc_error::Code::InternalError as i32,
                                code: 408,
                                message: "File download part timed out".into(),
                            }),
                        )
                        .await;
                    } else {
                        send(
                            &mut ws,
                            proto::server_protocol_message::Body::RpcResult(proto::RpcResult {
                                req_msg_id: message.id,
                                result: Some(proto::rpc_result::Result::GetFilePart(range(
                                    &[1, 2, 3],
                                    &request(),
                                ))),
                            }),
                        )
                        .await;
                    }
                }
            });
            let connection = connect_realtime(&url, "local-test-token").await.unwrap();
            let mut realtime = AuthenticatedRealtime::V2 {
                connection,
                authority_owner: None,
                url,
                token: "local-test-token".into(),
            };
            let directory = tempfile::tempdir().unwrap();
            let output = directory.path().join("server-timeout.bin");
            let result = download_ranges(&mut realtime, request(), 3, &output).await;
            if failures > 3 {
                assert!(result.is_err());
                assert!(!output.exists());
                assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
            } else {
                assert_eq!(result.unwrap(), 3);
                assert_eq!(tokio::fs::read(output).await.unwrap(), [1, 2, 3]);
            }
            server.await.unwrap();
        })
        .await
        .expect("server range deadline retries must be bounded on the same carrier");
    }

    #[tokio::test]
    async fn server_range_deadlines_retry_on_the_healthy_carrier() {
        exercise_server_timeout(2).await;
    }

    #[tokio::test]
    async fn repeated_server_range_deadlines_stop_after_three_retries() {
        exercise_server_timeout(4).await;
    }

    #[test]
    fn authorization_and_other_rpc_failures_are_not_server_range_timeouts() {
        for (code, error_code) in [
            (408, proto::rpc_error::Code::Unauthenticated),
            (403, proto::rpc_error::Code::Unauthenticated),
            (500, proto::rpc_error::Code::InternalError),
        ] {
            let error = RealtimeError::RpcError {
                code,
                error_code: error_code as i32,
                error_name: "test".into(),
                message: "test".into(),
                friendly: "test".into(),
            };
            assert!(!server_range_timed_out(&error));
        }
    }
}

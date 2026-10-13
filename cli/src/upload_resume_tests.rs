use super::*;
use futures_util::{SinkExt, StreamExt};
use prost::Message;
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::{WebSocketStream, accept_async, tungstenite::Message as WsMessage};

const PART_SIZE: usize = 512 * 1024;
const UPLOAD_ID: [u8; 16] = [42; 16];

#[derive(Clone, Copy)]
enum Failure {
    AcceptedPart,
    ProgressingPartLoss,
    NoProgressAfterPart,
    CommittedFinish,
    ReconnectHandshakeLoss,
    EveryCreate,
    RejectCreate,
}

fn source_byte_count(failure: Failure) -> usize {
    let full_parts = if matches!(failure, Failure::ProgressingPartLoss) {
        4
    } else {
        1
    };
    PART_SIZE * full_parts + 37
}

#[derive(Default)]
struct Observed {
    connections: usize,
    creates: usize,
    client_upload_id: Option<Vec<u8>>,
    accepted: Vec<u32>,
    saved_parts: Vec<u32>,
    finishes: usize,
    finalizations: usize,
    sends: usize,
}

async fn next_message(ws: &mut WebSocketStream<TcpStream>) -> proto::ClientMessage {
    loop {
        match ws.next().await.unwrap().unwrap() {
            WsMessage::Binary(bytes) => return proto::ClientMessage::decode(&*bytes).unwrap(),
            WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
            message => panic!("unexpected client frame: {message:?}"),
        }
    }
}

async fn reply(
    ws: &mut WebSocketStream<TcpStream>,
    request_id: u64,
    result: proto::rpc_result::Result,
) {
    server_message(
        ws,
        proto::server_protocol_message::Body::RpcResult(proto::RpcResult {
            req_msg_id: request_id,
            result: Some(result),
        }),
    )
    .await;
}

async fn server_message(
    ws: &mut WebSocketStream<TcpStream>,
    body: proto::server_protocol_message::Body,
) {
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

fn complete() -> proto::UploadComplete {
    proto::UploadComplete {
        file_unique_id: "one-file".into(),
        ..Default::default()
    }
}

async fn serve(listener: TcpListener, failure: Failure) -> Observed {
    let mut observed = Observed::default();
    let byte_count = source_byte_count(failure);
    let part_count = byte_count.div_ceil(PART_SIZE) as u32;
    let connection_count = match failure {
        Failure::AcceptedPart | Failure::CommittedFinish => 2,
        Failure::ProgressingPartLoss => 5,
        Failure::EveryCreate | Failure::ReconnectHandshakeLoss | Failure::NoProgressAfterPart => 4,
        Failure::RejectCreate => 1,
    };
    for carrier in 0..connection_count {
        let (stream, _) = listener.accept().await.unwrap();
        observed.connections += 1;
        if matches!(failure, Failure::ReconnectHandshakeLoss) && (1..=2).contains(&carrier) {
            // Fail opening two replacement carriers before a healthy one arrives.
            drop(stream);
            continue;
        }
        let mut ws = accept_async(stream).await.unwrap();
        assert!(matches!(
            next_message(&mut ws).await.body,
            Some(proto::client_message::Body::ConnectionInit(_))
        ));
        server_message(
            &mut ws,
            proto::server_protocol_message::Body::ConnectionOpen(proto::ConnectionOpen {}),
        )
        .await;

        loop {
            let message = next_message(&mut ws).await;
            let Some(proto::client_message::Body::RpcCall(rpc)) = message.body else {
                continue;
            };
            match rpc.input.unwrap() {
                proto::rpc_call::Input::CreateUpload(input) => {
                    observed.creates += 1;
                    assert_eq!(input.byte_count, byte_count as u64);
                    assert_eq!(input.client_upload_id.len(), 16);
                    if let Some(id) = &observed.client_upload_id {
                        assert_eq!(
                            &input.client_upload_id, id,
                            "retry created a new upload identity"
                        );
                    } else {
                        observed.client_upload_id = Some(input.client_upload_id);
                    }
                    if matches!(failure, Failure::EveryCreate)
                        || (carrier == 0 && matches!(failure, Failure::ReconnectHandshakeLoss))
                    {
                        ws.close(None).await.unwrap();
                        break;
                    }
                    if matches!(failure, Failure::RejectCreate) {
                        server_message(
                            &mut ws,
                            proto::server_protocol_message::Body::RpcError(proto::RpcError {
                                req_msg_id: message.id,
                                error_code: proto::rpc_error::Code::BadRequest as i32,
                                code: 400,
                                message: "invalid upload metadata".into(),
                            }),
                        )
                        .await;
                        break;
                    }
                    reply(
                        &mut ws,
                        message.id,
                        proto::rpc_result::Result::CreateUpload(proto::CreateUploadResult {
                            upload_id: UPLOAD_ID.to_vec(),
                            part_size: PART_SIZE as u32,
                            part_count,
                            accepted_parts: observed.accepted.clone(),
                            ..Default::default()
                        }),
                    )
                    .await;
                }
                proto::rpc_call::Input::SaveUploadPart(input) => {
                    assert_eq!(input.upload_id, UPLOAD_ID);
                    assert!(
                        !observed.accepted.contains(&input.part_index),
                        "accepted part was retransmitted"
                    );
                    assert_eq!(
                        input.data.len(),
                        PART_SIZE.min(byte_count - input.part_index as usize * PART_SIZE)
                    );
                    assert!(input.data.iter().all(|byte| *byte == 7));
                    if matches!(failure, Failure::NoProgressAfterPart) && input.part_index == 1 {
                        // Replay a positive accepted prefix, but never advance it.
                        ws.close(None).await.unwrap();
                        break;
                    }
                    observed.accepted.push(input.part_index);
                    observed.saved_parts.push(input.part_index);
                    if (carrier == 0 && matches!(failure, Failure::AcceptedPart))
                        || (carrier < 4 && matches!(failure, Failure::ProgressingPartLoss))
                    {
                        // Commit the part, then lose its acknowledgement and the carrier.
                        ws.close(None).await.unwrap();
                        break;
                    }
                    reply(
                        &mut ws,
                        message.id,
                        proto::rpc_result::Result::SaveUploadPart(proto::SaveUploadPartResult {
                            already_present: false,
                        }),
                    )
                    .await;
                    if carrier == 0 && matches!(failure, Failure::NoProgressAfterPart) {
                        ws.close(None).await.unwrap();
                        break;
                    }
                }
                proto::rpc_call::Input::FinishUpload(input) => {
                    assert_eq!(input.upload_id, UPLOAD_ID);
                    assert_eq!(observed.accepted, (0..part_count).collect::<Vec<_>>());
                    observed.finishes += 1;
                    if observed.finalizations == 0 {
                        observed.finalizations += 1;
                    }
                    if carrier == 0 && matches!(failure, Failure::CommittedFinish) {
                        // Finalize once, then lose its response and the carrier.
                        ws.close(None).await.unwrap();
                        break;
                    }
                    reply(
                        &mut ws,
                        message.id,
                        proto::rpc_result::Result::FinishUpload(proto::FinishUploadResult {
                            state: Some(proto::finish_upload_result::State::Complete(complete())),
                        }),
                    )
                    .await;
                }
                proto::rpc_call::Input::SendMessage(_) => {
                    assert_eq!(
                        observed.finalizations, 1,
                        "message sent before upload completed"
                    );
                    observed.sends += 1;
                    reply(
                        &mut ws,
                        message.id,
                        proto::rpc_result::Result::SendMessage(proto::SendMessageResult::default()),
                    )
                    .await;
                    break;
                }
                input => panic!("unexpected RPC: {input:?}"),
            }
        }
    }
    observed
}

async fn exercise(failure: Failure, supplied_id: Option<[u8; 16]>) -> Observed {
    tokio::time::timeout(Duration::from_secs(10), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/realtime", listener.local_addr().unwrap());
        let server = tokio::spawn(serve(listener, failure));
        let connection = connect_realtime(&url, "local-test-token").await.unwrap();
        let mut realtime = AuthenticatedRealtime::V2 {
            connection,
            authority_owner: None,
            url,
            token: "local-test-token".into(),
        };
        let source = tempfile::NamedTempFile::new().unwrap();
        fs::write(source.path(), vec![7; source_byte_count(failure)]).unwrap();
        let mut input = NativeUploadInput::new(
            source.path(),
            "fixture.bin",
            "application/octet-stream",
            proto::UploadKind::Document,
        );
        input.client_upload_id = supplied_id;
        let result = realtime.upload(input).await;
        match failure {
            Failure::AcceptedPart
            | Failure::ProgressingPartLoss
            | Failure::CommittedFinish
            | Failure::ReconnectHandshakeLoss => {
                assert_eq!(result.unwrap().file_unique_id, "one-file");
                realtime
                    .call(proto::SendMessageInput::default())
                    .await
                    .unwrap();
            }
            Failure::EveryCreate | Failure::NoProgressAfterPart => assert!(result.is_err()),
            Failure::RejectCreate => {
                let error = result.unwrap_err();
                assert!(matches!(
                    error.downcast_ref::<NativeUploadError>(),
                    Some(NativeUploadError::V2(inline_sdk::RealtimeError::RpcError {
                        code: 400,
                        ..
                    }))
                ));
            }
        }
        let observed = server.await.unwrap();
        if let Some(id) = supplied_id {
            assert_eq!(observed.client_upload_id.as_deref(), Some(id.as_slice()));
        }
        observed
    })
    .await
    .expect("upload reconnect must terminate within its bounded retry budget")
}

#[tokio::test]
async fn accepted_part_survives_carrier_loss_without_retransmission() {
    let observed = exercise(Failure::AcceptedPart, None).await;
    assert_eq!(observed.connections, 2);
    assert_eq!(observed.creates, 2);
    assert_eq!(observed.saved_parts, vec![0, 1]);
    assert_eq!(observed.finalizations, 1);
    assert_eq!(observed.sends, 1);
}

#[tokio::test]
async fn newly_accepted_parts_allow_more_than_three_total_reconnects() {
    let observed = exercise(Failure::ProgressingPartLoss, None).await;
    assert_eq!(observed.connections, 5);
    assert_eq!(observed.creates, 5);
    assert_eq!(observed.saved_parts, vec![0, 1, 2, 3, 4]);
    assert_eq!(observed.finalizations, 1);
    assert_eq!(observed.sends, 1);
}

#[tokio::test]
async fn replaying_an_unchanged_accepted_prefix_does_not_replenish_reconnects() {
    let observed = exercise(Failure::NoProgressAfterPart, None).await;
    assert_eq!(observed.connections, 4);
    assert_eq!(observed.creates, 4);
    assert_eq!(observed.saved_parts, vec![0]);
    assert_eq!(observed.sends, 0);
}

#[tokio::test]
async fn lost_finish_response_reuses_upload_and_sends_message_once() {
    let observed = exercise(Failure::CommittedFinish, Some([19; 16])).await;
    assert_eq!(observed.connections, 2);
    assert_eq!(observed.creates, 2);
    assert_eq!(observed.saved_parts, vec![0, 1]);
    assert_eq!(observed.finishes, 2);
    assert_eq!(observed.finalizations, 1);
    assert_eq!(observed.sends, 1);
}

#[tokio::test]
async fn failed_reconnects_share_the_same_retry_budget_and_upload_identity() {
    let observed = exercise(Failure::ReconnectHandshakeLoss, None).await;
    assert_eq!(observed.connections, 4);
    assert_eq!(observed.creates, 2);
    assert_eq!(observed.saved_parts, vec![0, 1]);
    assert_eq!(observed.finalizations, 1);
    assert_eq!(observed.sends, 1);
}

#[tokio::test]
async fn repeated_carrier_loss_stops_after_three_reconnects() {
    let observed = exercise(Failure::EveryCreate, None).await;
    assert_eq!(observed.connections, 4);
    assert_eq!(observed.creates, 4);
    assert_eq!(observed.sends, 0);
}

#[tokio::test]
async fn invalid_upload_rpc_is_terminal() {
    let observed = exercise(Failure::RejectCreate, None).await;
    assert_eq!(observed.connections, 1);
    assert_eq!(observed.creates, 1);
    assert_eq!(observed.sends, 0);
}

#[test]
fn only_transport_failures_resume_uploads() {
    use inline_sdk::RealtimeError;
    assert!(resumable_v2_upload_error(&RealtimeError::ConnectionClosed));
    assert!(resumable_v2_upload_error(
        &RealtimeError::CommitOutcomeUnknown
    ));
    assert!(resumable_v2_upload_error(&RealtimeError::Timeout {
        operation: "rpc",
        timeout: Duration::from_secs(1)
    }));
    assert!(!resumable_v2_upload_error(
        &RealtimeError::AuthenticationInvalidated
    ));
    assert!(!resumable_v2_upload_error(&RealtimeError::MissingResult));
}

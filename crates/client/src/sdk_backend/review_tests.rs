//! Socket-level regression checks for independently reviewed source contracts.

use super::*;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_tungstenite::{accept_async, tungstenite::Message as WsMessage};

async fn fixture(
    mut respond: impl FnMut(proto::rpc_call::Input) -> Option<proto::rpc_result::Result>
    + Send
    + 'static,
) -> (SdkBackend, InMemoryStore, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        let _ = socket.next().await.unwrap().unwrap();
        socket
            .send(WsMessage::Binary(
                proto::ServerProtocolMessage {
                    id: 1,
                    body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                        proto::ConnectionOpen::default(),
                    )),
                }
                .encode_to_vec()
                .into(),
            ))
            .await
            .unwrap();
        let mut server_id = 2;
        while let Some(Ok(WsMessage::Binary(bytes))) = socket.next().await {
            let message = proto::ClientMessage::decode(&*bytes).unwrap();
            let Some(proto::client_message::Body::RpcCall(call)) = message.body else {
                continue;
            };
            let Some(result) = respond(call.input.expect("fixture request input")) else {
                break;
            };
            socket
                .send(WsMessage::Binary(
                    proto::ServerProtocolMessage {
                        id: server_id,
                        body: Some(proto::server_protocol_message::Body::RpcResult(
                            proto::RpcResult {
                                req_msg_id: message.id,
                                result: Some(result),
                            },
                        )),
                    }
                    .encode_to_vec()
                    .into(),
                ))
                .await
                .unwrap();
            server_id += 1;
        }
    });
    let store = InMemoryStore::new();
    store
        .save_session(StoredSession {
            auth: AuthCredential::AccessToken {
                token: AuthToken::try_new("fixture-token").unwrap(),
            },
            account_namespace: Some("review-fixture".into()),
        })
        .await
        .unwrap();
    let backend = SdkBackend::builder()
        .store(store.clone())
        .realtime_url(format!("ws://{address}/realtime"))
        .without_realtime_handshake()
        .build()
        .unwrap();
    (backend, store, server)
}

fn source_space(id: i64) -> proto::Space {
    proto::Space {
        id,
        name: format!("Workspace {id}"),
        seq: Some(1),
        ..Default::default()
    }
}

#[tokio::test]
async fn bounded_directory_refresh_keeps_partial_success_rotates_and_preserves_state_on_failure() {
    let details = Arc::new(StdMutex::new(Vec::new()));
    let requested = details.clone();
    let mut lists = 0;
    let (backend, store, server) = fixture(move |input| {
        Some(match input {
            proto::rpc_call::Input::GetMe(_) => {
                proto::rpc_result::Result::GetMe(proto::GetMeResult {
                    user: Some(proto::User {
                        id: 42,
                        ..Default::default()
                    }),
                })
            }
            proto::rpc_call::Input::GetSpaces(_) => {
                lists += 1;
                if lists == 3 {
                    return None;
                }
                proto::rpc_result::Result::GetSpaces(proto::GetSpacesResult {
                    spaces: (1..=10).map(source_space).collect(),
                })
            }
            proto::rpc_call::Input::GetSpace(input) => {
                requested.lock().unwrap().push(input.space_id);
                proto::rpc_result::Result::GetSpace(proto::GetSpaceResult {
                    space: Some(source_space(input.space_id)),
                    // An incomplete/failed detail must not erase other workspaces
                    // or starve later IDs on every repeated bounded refresh.
                    membership: (input.space_id != 2).then_some(proto::Member {
                        space_id: input.space_id,
                        user_id: 42,
                        ..Default::default()
                    }),
                    settings: None,
                })
            }
            other => panic!("unexpected directory request: {other:?}"),
        })
    })
    .await;
    let old = crate::AccountDirectoryState {
        account_user_id: Some(InlineId::new(42)),
        snapshot: AccountStateSnapshot {
            spaces: vec![space_record_from_proto(&source_space(99))],
            spaces_complete: true,
            ..Default::default()
        },
        ..Default::default()
    };
    assert!(store.record_account_directory(0, old).await.unwrap());
    let first = backend.refresh_account_state().await.unwrap();
    assert_eq!(
        first.spaces.len(),
        10,
        "getSpaces proves all accessible IDs even with partial detail work"
    );
    assert!(!first.spaces_complete);
    assert_eq!(first.space_memberships.len(), 7);
    assert_eq!(first.removed_space_ids, vec![InlineId::new(99)]);
    assert_eq!(*details.lock().unwrap(), (1..=8).collect::<Vec<_>>());
    let second = backend.refresh_account_state().await.unwrap();
    assert!(!second.spaces_complete);
    assert_eq!(second.space_memberships.len(), 9);
    assert!(
        second
            .space_memberships
            .iter()
            .any(|member| member.space_id == InlineId::new(10))
    );
    assert_eq!(&details.lock().unwrap()[8..], &[9, 10, 1, 2, 3, 4, 5, 6]);
    assert!(!second.removed_space_ids.contains(&InlineId::new(2)));
    let durable = store.account_directory().await.unwrap();
    assert!(backend.refresh_account_state().await.is_err());
    assert_eq!(
        store.account_directory().await.unwrap(),
        durable,
        "a failed full listing is not authoritative removal"
    );
    server.abort();
}

fn empty_edit() -> EditMessageRequest {
    EditMessageRequest {
        chat_id: InlineId::new(7),
        message_id: InlineId::new(9),
        text: String::new(),
        entities: Vec::new(),
        external_id: None,
        parse_markdown: false,
    }
}

#[tokio::test]
async fn clearing_uncached_media_caption_checks_canonical_identity_and_does_not_upload() {
    for (media, wrong_chat, expected) in [
        (true, false, None),
        (false, false, Some(ClientErrorCategory::InvalidInput)),
        (true, true, Some(ClientErrorCategory::ProtocolMismatch)),
    ] {
        let requests = Arc::new(StdMutex::new(Vec::new()));
        let observed = requests.clone();
        let (backend, _, server) = fixture(move |input| Some(match input {
            proto::rpc_call::Input::GetMessages(input) => {
                observed.lock().unwrap().push("lookup");
                assert_eq!(input.message_ids, vec![9]);
                assert!(matches!(input.peer_id.and_then(|peer| peer.r#type), Some(proto::input_peer::Type::Chat(chat)) if chat.chat_id == 7));
                proto::rpc_result::Result::GetMessages(proto::GetMessagesResult {
                    messages: vec![proto::Message {
                        id: 9, chat_id: if wrong_chat { 8 } else { 7 }, message: Some("caption".into()),
                        media: media.then_some(proto::MessageMedia { media: Some(proto::message_media::Media::Document(proto::MessageDocument {
                            document: Some(proto::Document { id: 11, ..Default::default() }),
                        })) }), ..Default::default()
                    }], seq: Some(1),
                })
            }
            proto::rpc_call::Input::EditMessage(input) => {
                observed.lock().unwrap().push("edit");
                assert!(input.text.is_empty());
                assert!(input.entities.unwrap().entities.is_empty());
                proto::rpc_result::Result::EditMessage(proto::EditMessageResult { updates: Vec::new() })
            }
            other => panic!("caption clear must not upload or alter media: {other:?}"),
        })).await;
        match expected {
            None => {
                backend.edit_message(empty_edit()).await.unwrap();
            }
            Some(category) => assert_eq!(
                backend
                    .edit_message(empty_edit())
                    .await
                    .unwrap_err()
                    .category,
                category
            ),
        }
        assert_eq!(
            *requests.lock().unwrap(),
            if expected.is_none() {
                vec!["lookup", "edit"]
            } else {
                vec!["lookup"]
            }
        );
        server.abort();
    }
}

#[tokio::test]
async fn cached_profiles_do_not_prove_workspace_access_and_invalid_rosters_do_not_publish() {
    let store = InMemoryStore::new();
    store
        .record_space_member(SpaceMemberRecord {
            space_id: InlineId::new(5),
            user_id: InlineId::new(42),
            ..space_member_record_from_proto(&proto::Member::default())
        })
        .await
        .unwrap();
    let backend = SdkBackend::builder().store(store).build().unwrap();
    let request = crate::SpaceMembersRequest {
        space_id: InlineId::new(5),
        limit: Some(1),
        cursor: None,
        refresh: false,
    };
    assert_eq!(
        backend.space_members(request).await.unwrap_err().category,
        ClientErrorCategory::NotFound
    );

    for ids in [vec![42, 42], vec![0]] {
        let (backend, store, server) = fixture(move |input| {
            Some(match input {
                proto::rpc_call::Input::GetSpaceMembers(input) => {
                    proto::rpc_result::Result::GetSpaceMembers(proto::GetSpaceMembersResult {
                        members: ids
                            .iter()
                            .map(|id| proto::Member {
                                user_id: *id,
                                space_id: input.space_id,
                                ..Default::default()
                            })
                            .collect(),
                        users: Vec::new(),
                        seq: Some(1),
                    })
                }
                other => panic!("unexpected roster request: {other:?}"),
            })
        })
        .await;
        let before = store.account_directory().await.unwrap();
        let result = backend
            .space_members(crate::SpaceMembersRequest {
                space_id: InlineId::new(5),
                limit: Some(1),
                cursor: None,
                refresh: true,
            })
            .await;
        assert_eq!(
            result.unwrap_err().category,
            ClientErrorCategory::ProtocolMismatch
        );
        assert_eq!(store.account_directory().await.unwrap(), before);
        assert!(
            store
                .space_members(InlineId::new(5))
                .await
                .unwrap()
                .is_empty()
        );
        server.abort();
    }
}

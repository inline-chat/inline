//! Executable cross-boundary contracts using real SQLite and native RPC records.
use super::tests::{read_test_client_message, rpc_result_message, send_test_server_message};
use super::*;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};
use tokio_tungstenite::accept_async;

fn entity(kind: &str) -> crate::MessageEntityRecord {
    crate::MessageEntityRecord {
        kind: kind.into(),
        offset: 3,
        length: 5,
        user_id: None,
        agent_id: None,
        group_id: None,
        chat_id: None,
        value: None,
    }
}
fn session() -> StoredSession {
    StoredSession {
        auth: AuthCredential::AccessToken {
            token: AuthToken::try_new("contract-token").unwrap(),
        },
        account_namespace: Some("contract-account".into()),
    }
}
async fn open(socket: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) {
    read_test_client_message(socket).await;
    send_test_server_message(
        socket,
        proto::ServerProtocolMessage {
            id: 1,
            body: Some(proto::server_protocol_message::Body::ConnectionOpen(
                proto::ConnectionOpen::default(),
            )),
        },
    )
    .await;
}
fn send_result(random_id: i64, message_id: i64) -> proto::rpc_result::Result {
    proto::rpc_result::Result::SendMessage(proto::SendMessageResult {
        updates: vec![proto::Update {
            update: Some(proto::update::Update::UpdateMessageId(
                proto::UpdateMessageId {
                    random_id,
                    message_id,
                },
            )),
            ..Default::default()
        }],
        ..Default::default()
    })
}
fn input(message: &proto::ClientMessage) -> &proto::rpc_call::Input {
    match message.body.as_ref().unwrap() {
        proto::client_message::Body::RpcCall(call) => call.input.as_ref().unwrap(),
        other => panic!("expected source RPC, got {other:?}"),
    }
}

#[tokio::test]
async fn persisted_entities_reach_actual_native_send_edit_and_upload_requests() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        open(&mut socket).await;
        let send = read_test_client_message(&mut socket).await;
        match input(&send) {
            proto::rpc_call::Input::SendMessage(send) => {
                assert_eq!(send.message.as_deref(), Some("😀 hello"));
                let entity = &send.entities.as_ref().unwrap().entities[0];
                assert_eq!(
                    (entity.r#type, entity.offset, entity.length),
                    (proto::message_entity::Type::Bold as i32, 3, 5)
                );
            }
            other => panic!("unexpected send: {other:?}"),
        }
        send_test_server_message(
            &mut socket,
            rpc_result_message(2, send.id, send_result(99, 11)),
        )
        .await;
        let edit = read_test_client_message(&mut socket).await;
        match input(&edit) {
            proto::rpc_call::Input::EditMessage(edit) => {
                assert_eq!(edit.text, "😀 hello");
                assert_eq!(
                    edit.entities.as_ref().unwrap().entities[0].r#type,
                    proto::message_entity::Type::Italic as i32
                );
            }
            other => panic!("unexpected edit: {other:?}"),
        }
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                3,
                edit.id,
                proto::rpc_result::Result::EditMessage(proto::EditMessageResult::default()),
            ),
        )
        .await;
        let create = read_test_client_message(&mut socket).await;
        assert!(
            matches!(input(&create), proto::rpc_call::Input::CreateUpload(create) if create.byte_count == 4)
        );
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                4,
                create.id,
                proto::rpc_result::Result::CreateUpload(proto::CreateUploadResult {
                    upload_id: vec![1; 16],
                    part_size: 512 * 1024,
                    part_count: 1,
                    ..Default::default()
                }),
            ),
        )
        .await;
        let part = read_test_client_message(&mut socket).await;
        assert!(
            matches!(input(&part), proto::rpc_call::Input::SaveUploadPart(part) if part.data == vec![1,2,3,4])
        );
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                5,
                part.id,
                proto::rpc_result::Result::SaveUploadPart(proto::SaveUploadPartResult::default()),
            ),
        )
        .await;
        let finish = read_test_client_message(&mut socket).await;
        assert!(matches!(
            input(&finish),
            proto::rpc_call::Input::FinishUpload(_)
        ));
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                6,
                finish.id,
                proto::rpc_result::Result::FinishUpload(proto::FinishUploadResult {
                    state: Some(proto::finish_upload_result::State::Complete(
                        proto::UploadComplete {
                            file_unique_id: "INDtest".into(),
                            media: Some(proto::upload_complete::Media::Document(proto::Document {
                                id: 31,
                                ..Default::default()
                            })),
                        },
                    )),
                }),
            ),
        )
        .await;
        let media = read_test_client_message(&mut socket).await;
        match input(&media) {
            proto::rpc_call::Input::SendMessage(media) => {
                assert_eq!(media.message.as_deref(), Some("😀 hello"));
                assert!(
                    matches!(media.media.as_ref().unwrap().media, Some(proto::input_media::Media::Document(ref document)) if document.document_id == 31)
                );
                let entity = &media.entities.as_ref().unwrap().entities[0];
                assert_eq!(
                    (entity.r#type, entity.offset, entity.length),
                    (proto::message_entity::Type::Underline as i32, 3, 5)
                );
            }
            other => panic!("unexpected caption send: {other:?}"),
        }
        send_test_server_message(
            &mut socket,
            rpc_result_message(7, media.id, send_result(100, 12)),
        )
        .await;
    });
    let store = InMemoryStore::new();
    store.save_session(session()).await.unwrap();
    let backend = SdkBackend::builder()
        .store(store)
        .realtime_url(format!("ws://{addr}/realtime"))
        .without_realtime_handshake()
        .build()
        .unwrap();
    let mut send = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(7),
        },
        "😀 hello",
    );
    send.entities.push(entity("TYPE_BOLD"));
    send.random_id = Some(RandomId::new(99));
    let send: SendTextRequest =
        serde_json::from_slice(&serde_json::to_vec(&send).unwrap()).unwrap();
    assert_eq!(
        backend.send_text(send).await.unwrap().message_id,
        Some(InlineId::new(11))
    );
    backend
        .edit_message(EditMessageRequest {
            chat_id: InlineId::new(7),
            message_id: InlineId::new(11),
            text: "😀 hello".into(),
            entities: vec![entity("TYPE_ITALIC")],
            external_id: None,
            parse_markdown: false,
        })
        .await
        .unwrap();
    let upload = UploadRequest {
        peer: PeerRef::Chat {
            chat_id: InlineId::new(7),
        },
        kind: MediaKind::Document,
        file_name: Some("a.bin".into()),
        mime_type: Some("application/octet-stream".into()),
        size_bytes: Some(4),
        caption: Some("😀 hello".into()),
        entities: vec![entity("TYPE_UNDERLINE")],
        width: None,
        height: None,
        duration_ms: None,
        external_id: None,
        random_id: Some(RandomId::new(100)),
        reply_to_message_id: None,
    };
    let upload = serde_json::from_slice(&serde_json::to_vec(&upload).unwrap()).unwrap();
    assert_eq!(
        backend
            .send_media(upload, vec![1, 2, 3, 4], None)
            .await
            .unwrap()
            .message_id,
        Some(InlineId::new(12))
    );
    server.await.unwrap();
}

#[tokio::test]
async fn invalid_utf16_entities_fail_before_session_transaction_and_upload() {
    let backend = SdkBackend::builder().build().unwrap();
    let mut invalid = entity("TYPE_BOLD");
    invalid.offset = 1;
    invalid.length = 1;
    let mut send = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(7),
        },
        "😀 hello",
    );
    send.entities = vec![invalid.clone()];
    assert_eq!(
        backend.send_text(send).await.unwrap_err().category,
        ClientErrorCategory::InvalidInput
    );
    assert_eq!(
        backend
            .edit_message(EditMessageRequest {
                chat_id: InlineId::new(7),
                message_id: InlineId::new(1),
                text: "😀 hello".into(),
                entities: vec![invalid.clone()],
                external_id: None,
                parse_markdown: false
            })
            .await
            .unwrap_err()
            .category,
        ClientErrorCategory::InvalidInput
    );
    let upload = UploadRequest {
        peer: PeerRef::Chat {
            chat_id: InlineId::new(7),
        },
        kind: MediaKind::Document,
        file_name: None,
        mime_type: None,
        size_bytes: None,
        caption: Some("😀 hello".into()),
        entities: vec![invalid],
        width: None,
        height: None,
        duration_ms: None,
        external_id: None,
        random_id: Some(RandomId::new(100)),
        reply_to_message_id: None,
    };
    assert_eq!(
        backend
            .send_media(upload, vec![1, 2, 3], None)
            .await
            .unwrap_err()
            .category,
        ClientErrorCategory::InvalidInput
    );
    assert!(
        backend
            .store
            .transaction(TransactionId::try_new("sdk-upload-0000000000000064").unwrap())
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn stale_workspace_detail_cannot_undo_a_confirmed_removal_after_sqlite_reopen() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (requested, wait_request) = tokio::sync::oneshot::channel();
    let (release, wait_release) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        open(&mut socket).await;
        let me = read_test_client_message(&mut socket).await;
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                2,
                me.id,
                proto::rpc_result::Result::GetMe(proto::GetMeResult {
                    user: Some(proto::User {
                        id: 42,
                        ..Default::default()
                    }),
                }),
            ),
        )
        .await;
        let spaces = read_test_client_message(&mut socket).await;
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                3,
                spaces.id,
                proto::rpc_result::Result::GetSpaces(proto::GetSpacesResult {
                    spaces: vec![proto::Space {
                        id: 5,
                        name: "Work".into(),
                        seq: Some(1),
                        ..Default::default()
                    }],
                }),
            ),
        )
        .await;
        let detail = read_test_client_message(&mut socket).await;
        requested.send(()).unwrap();
        wait_release.await.unwrap();
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                4,
                detail.id,
                proto::rpc_result::Result::GetSpace(proto::GetSpaceResult {
                    space: Some(proto::Space {
                        id: 5,
                        name: "Old".into(),
                        seq: Some(1),
                        ..Default::default()
                    }),
                    membership: Some(proto::Member {
                        space_id: 5,
                        user_id: 42,
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
            ),
        )
        .await;
    });
    let path = std::env::temp_dir().join(format!(
        "inline-directory-race-{}-{}.sqlite",
        std::process::id(),
        now_seconds()
    ));
    let store = crate::SqliteStore::open(&path).unwrap();
    store.save_session(session()).await.unwrap();
    store
        .record_account_directory(
            0,
            crate::AccountDirectoryState {
                account_user_id: Some(InlineId::new(42)),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let backend = SdkBackend::builder()
        .store(store.clone())
        .realtime_url(format!("ws://{addr}/realtime"))
        .without_realtime_handshake()
        .build()
        .unwrap();
    let refresh_backend = backend.clone();
    let refresh = tokio::spawn(async move { refresh_backend.refresh_account_state().await });
    wait_request.await.unwrap();
    backend
        .apply_sync_batch(
            vec![proto::Update {
                update: Some(proto::update::Update::SpaceMemberDelete(
                    proto::UpdateSpaceMemberDelete {
                        space_id: 5,
                        user_id: 42,
                        ..Default::default()
                    },
                )),
                ..Default::default()
            }],
            None,
        )
        .await
        .unwrap();
    release.send(()).unwrap();
    assert!(refresh.await.unwrap().is_err());
    server.await.unwrap();
    drop(backend);
    drop(store);
    let store = crate::SqliteStore::open(&path).unwrap();
    let state = store.account_directory().await.unwrap();
    assert!(state.snapshot.spaces.is_empty());
    assert_eq!(state.snapshot.removed_space_ids, vec![InlineId::new(5)]);
    drop(store);
    std::fs::remove_file(path).unwrap();
}

#[tokio::test]
async fn logout_discards_a_delayed_dialog_snapshot_and_does_not_repopulate_sqlite() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (requested, wait_request) = tokio::sync::oneshot::channel();
    let (release, wait_release) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        open(&mut socket).await;
        let request = read_test_client_message(&mut socket).await;
        assert!(matches!(
            input(&request),
            proto::rpc_call::Input::GetChats(_)
        ));
        requested.send(()).unwrap();
        wait_release.await.unwrap();
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                2,
                request.id,
                proto::rpc_result::Result::GetChats(proto::GetChatsResult {
                    chats: vec![proto::Chat {
                        id: 7,
                        title: "Stale".into(),
                        peer_id: Some(peer_for_sync_bucket_peer(crate::SyncBucketPeer::Chat {
                            chat_id: InlineId::new(7),
                        })),
                        seq: Some(1),
                        ..Default::default()
                    }],
                    ..Default::default()
                }),
            ),
        )
        .await;
    });
    let api = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let api_addr = api.local_addr().unwrap();
    let logout_server = tokio::spawn(async move {
        let (mut stream, _) = api.accept().await.unwrap();
        let mut bytes = [0; 4096];
        stream.read(&mut bytes).await.unwrap();
        let body = r#"{"ok":true,"result":null}"#;
        stream.write_all(format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
    });
    let path = std::env::temp_dir().join(format!(
        "inline-logout-race-{}-{}.sqlite",
        std::process::id(),
        now_seconds()
    ));
    let store = crate::SqliteStore::open(&path).unwrap();
    store.save_session(session()).await.unwrap();
    let backend = SdkBackend::builder()
        .store(store.clone())
        .api_base_url(format!("http://{api_addr}/v1"))
        .realtime_url(format!("ws://{addr}/realtime"))
        .without_realtime_handshake()
        .build()
        .unwrap();
    let old = backend.clone();
    let snapshot = tokio::spawn(async move { old.dialogs(DialogsRequest::default()).await });
    wait_request.await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), backend.logout())
        .await
        .unwrap()
        .unwrap();
    release.send(()).unwrap();
    assert_eq!(
        snapshot.await.unwrap().unwrap_err().category,
        ClientErrorCategory::AuthRequired
    );
    server.await.unwrap();
    logout_server.await.unwrap();
    drop(backend);
    drop(store);
    let store = crate::SqliteStore::open(&path).unwrap();
    assert!(store.load_session().await.unwrap().is_none());
    assert!(store.dialog(InlineId::new(7)).await.unwrap().is_none());
    assert!(
        store
            .account_directory()
            .await
            .unwrap()
            .snapshot
            .spaces
            .is_empty()
    );
    drop(store);
    std::fs::remove_file(path).unwrap();
}

#[tokio::test]
async fn explicit_open_of_hidden_dm_restores_visibility_through_source() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = accept_async(stream).await.unwrap();
        open(&mut socket).await;
        let request = read_test_client_message(&mut socket).await;
        let peer = proto::Peer {
            r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 42 })),
        };
        let chat = proto::Chat {
            id: 7,
            peer_id: Some(peer.clone()),
            seq: Some(1),
            ..Default::default()
        };
        let dialog = proto::Dialog {
            chat_id: Some(7),
            peer: Some(peer),
            chat_list_hidden: Some(true),
            open: Some(false),
            ..Default::default()
        };
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                2,
                request.id,
                proto::rpc_result::Result::GetChat(proto::GetChatResult {
                    chat: Some(chat.clone()),
                    dialog: Some(dialog.clone()),
                    ..Default::default()
                }),
            ),
        )
        .await;
        let reopen = read_test_client_message(&mut socket).await;
        assert!(
            matches!(input(&reopen),proto::rpc_call::Input::UpdateDialogOrder(order) if matches!(order.destination.as_ref().unwrap().destination,Some(proto::dialog_folder_destination::Destination::Root(true))))
        );
        send_test_server_message(
            &mut socket,
            rpc_result_message(
                3,
                reopen.id,
                proto::rpc_result::Result::UpdateDialogOrder(proto::UpdateDialogOrderResult {
                    chat: Some(chat),
                    dialog: Some(proto::Dialog {
                        chat_list_hidden: Some(false),
                        open: Some(true),
                        ..dialog
                    }),
                    ..Default::default()
                }),
            ),
        )
        .await;
    });
    let store = InMemoryStore::new();
    store.save_session(session()).await.unwrap();
    let backend = SdkBackend::builder()
        .store(store.clone())
        .realtime_url(format!("ws://{addr}/realtime"))
        .without_realtime_handshake()
        .build()
        .unwrap();
    let created = backend
        .create_dm(CreateDmRequest {
            user_id: InlineId::new(42),
        })
        .await
        .unwrap();
    let dialog = store.dialog(created.chat_id).await.unwrap().unwrap();
    assert_eq!(dialog.kind, ConversationKind::DirectMessage);
    assert_eq!(dialog.chat_list_hidden, Some(false));
    assert_eq!(dialog.open, Some(true));
    server.await.unwrap();
}

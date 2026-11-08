//! Synthetic stores and loopback RPC fixtures; no live accounts or services.
use super::*;
use hegel::{TestCase, generators as gs};
use serde_json::json;

fn channel(space_id: Option<i64>) -> proto::Chat {
    proto::Chat {
        id: 7,
        title: "channel".into(),
        space_id,
        peer_id: Some(proto::Peer {
            r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id: 7 })),
        }),
        ..Default::default()
    }
}

fn runt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}

fn structure(dialog: &DialogRecord) -> serde_json::Value {
    serde_json::to_value(dialog)
        .unwrap()
        .get("structure")
        .cloned()
        .unwrap_or(serde_json::Value::Null)
}

#[allow(deprecated)]
#[tokio::test]
async fn parity_promoted_dialog_visibility_survives_partial_updates_and_restart() {
    let fixture = FixtureDir::new();
    let path = fixture.0.join("visibility.sqlite");
    {
        let store = crate::SqliteStore::open(&path).unwrap();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
        let mut hidden = DialogRecord::new(InlineId::new(7));
        hidden.chat_list_hidden = Some(true);
        store.record_dialog(hidden).await.unwrap();

        // A chat-only patch must not change account-local visibility.
        backend
            .record_chat_update(channel(None), None, None)
            .await
            .unwrap();
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .chat_list_hidden,
            Some(true)
        );

        // Current server encodes a promoted dialog with visibility true and
        // omits chat_list_hidden, rather than sending an explicit false.
        let visible = proto::Dialog {
            chat_id: Some(7),
            sidebar_visible: Some(true),
            ..Default::default()
        };
        backend
            .apply_updates(
                vec![proto::Update {
                    update: Some(proto::update::Update::ChatOpen(proto::UpdateChatOpen {
                        chat: Some(channel(None)),
                        dialog: Some(visible),
                        ..Default::default()
                    })),
                    ..Default::default()
                }],
                None,
                None,
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .chat_list_hidden,
            Some(false)
        );
    }
    let store = crate::SqliteStore::open(&path).unwrap();
    assert_eq!(
        store
            .dialog(InlineId::new(7))
            .await
            .unwrap()
            .unwrap()
            .chat_list_hidden,
        Some(false)
    );
}

#[allow(deprecated)]
#[tokio::test]
async fn parity_snapshot_visibility_and_stale_repair_user_state() {
    let store = InMemoryStore::new();
    let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
    let visible = proto::Dialog {
        chat_id: Some(7),
        sidebar_visible: Some(true),
        ..Default::default()
    };
    backend
        .apply_get_chats_snapshot(proto::GetChatsResult {
            chats: vec![channel(None)],
            dialogs: vec![visible.clone()],
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(
        store
            .dialog(InlineId::new(7))
            .await
            .unwrap()
            .unwrap()
            .chat_list_hidden,
        Some(false)
    );

    let mut hidden = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
    hidden.chat_list_hidden = Some(true);
    store.record_dialog(hidden).await.unwrap();
    backend
        .apply_get_chats_snapshot(proto::GetChatsResult {
            chats: vec![channel(None)],
            dialogs: vec![proto::Dialog {
                chat_id: Some(7),
                ..Default::default()
            }],
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(
        store
            .dialog(InlineId::new(7))
            .await
            .unwrap()
            .unwrap()
            .chat_list_hidden,
        Some(true)
    );
    let mut stale = visible;
    clear_dialog_user_state(&mut stale);
    backend
        .record_chat_update(channel(None), Some(stale), None)
        .await
        .unwrap();
    assert_eq!(
        store
            .dialog(InlineId::new(7))
            .await
            .unwrap()
            .unwrap()
            .chat_list_hidden,
        Some(true)
    );
}

#[allow(deprecated)]
#[tokio::test]
async fn parity_sidecar_visibility_respects_explicit_hidden_and_partial_dialogs() {
    let store = InMemoryStore::new();
    let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
    let mut hidden = DialogRecord::new(InlineId::new(7));
    hidden.chat_list_hidden = Some(true);
    store.record_dialog(hidden).await.unwrap();
    for (visible, explicit_hidden, expected) in [
        (None, None, Some(true)),
        (Some(true), None, Some(false)),
        (Some(false), None, Some(true)),
        (Some(true), Some(true), Some(true)),
    ] {
        backend
            .apply_sidecars(proto::UpdateSidecars {
                chats: vec![channel(None)],
                dialogs: vec![proto::Dialog {
                    chat_id: Some(7),
                    sidebar_visible: visible,
                    chat_list_hidden: explicit_hidden,
                    ..Default::default()
                }],
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .chat_list_hidden,
            expected
        );
    }
}

#[hegel::test(test_cases = 1000)]
fn parity_complete_move_home_clears_space_on_both_stores(tc: TestCase) {
    let space = tc.draw(gs::integers::<i64>().min_value(1));
    runt().block_on(async {
        for store in [Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>, Arc::new(crate::SqliteStore::open_in_memory().unwrap())] {
            let backend = SdkBackend::builder().shared_store(store.clone()).build().unwrap();
            backend.record_chat_update(channel(Some(space)), None, None).await.unwrap();
            backend.record_chat_update(channel(None), None, None).await.unwrap();
            let dialog = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
            assert_eq!(dialog.space_id, None);
            assert_eq!(structure(&dialog), json!({"kind":"channel","peer_user_id":null,"space_id":null,"parent_chat_id":null,"parent_message_id":null}));
        }
    });
}

#[hegel::test(test_cases = 1000)]
fn parity_title_patch_preserves_structure_on_both_stores(tc: TestCase) {
    let title = tc.draw(gs::text().max_size(100));
    runt().block_on(async {
        for store in [
            Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
        ] {
            let backend = SdkBackend::builder()
                .shared_store(store.clone())
                .build()
                .unwrap();
            let mut child = channel(Some(5));
            child.parent_chat_id = Some(3);
            child.parent_message_id = Some(9);
            backend.record_chat_update(child, None, None).await.unwrap();
            let before = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
            assert_eq!(structure(&before)["kind"], "reply_child");
            backend
                .record_chat_update(
                    proto::Chat {
                        id: 7,
                        title: title.clone(),
                        ..Default::default()
                    },
                    None,
                    None,
                )
                .await
                .unwrap();
            let after = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
            assert_eq!(structure(&before), structure(&after));
            assert_eq!(after.parent_chat_id, Some(InlineId::new(3)));
            assert_eq!(after.parent_message_id, Some(InlineId::new(9)));
        }
    });
}

#[tokio::test]
async fn parity_complete_child_detach_clears_both_parents() {
    let store = InMemoryStore::new();
    let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
    let mut child = channel(Some(5));
    child.parent_chat_id = Some(3);
    child.parent_message_id = Some(9);
    backend.record_chat_update(child, None, None).await.unwrap();
    backend
        .apply_get_chats_snapshot(proto::GetChatsResult {
            chats: vec![channel(None)],
            ..Default::default()
        })
        .await
        .unwrap();
    let detached = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
    assert_eq!(structure(&detached)["kind"], "channel");
    assert_eq!(detached.parent_chat_id, None);
    assert_eq!(detached.parent_message_id, None);
}

#[test]
fn parity_old_serialized_record_remains_unknown_and_conflict_is_not_direct() {
    let legacy = DialogRecord::new(InlineId::new(7));
    assert!(structure(&legacy).is_null());
    let mut chat = channel(None);
    chat.peer_id = Some(proto::Peer {
        r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 2 })),
    });
    chat.parent_chat_id = Some(3);
    chat.parent_message_id = Some(9);
    let records = dialog_records_from_get_chats(&proto::GetChatsResult {
        chats: vec![chat],
        ..Default::default()
    });
    assert!(structure(&records[0]).is_null());
}

fn join_self() -> proto::Update {
    proto::Update {
        update: Some(proto::update::Update::JoinSpace(proto::UpdateJoinSpace {
            space: Some(proto::Space {
                id: 5,
                name: "workspace".into(),
                ..Default::default()
            }),
            member: Some(proto::Member {
                space_id: 5,
                user_id: 2,
                ..Default::default()
            }),
        })),
        ..Default::default()
    }
}
fn remove_member(user_id: i64) -> proto::Update {
    proto::Update {
        update: Some(proto::update::Update::SpaceMemberDelete(
            proto::UpdateSpaceMemberDelete {
                space_id: 5,
                user_id,
                ..Default::default()
            },
        )),
        ..Default::default()
    }
}
#[tokio::test]
async fn parity_account_access_self_removal_survives_stale_catalog_and_other_member_does_not_remove_self()
 {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let backend = SdkBackend::builder()
            .shared_store(store.clone())
            .build()
            .unwrap();
        backend
            .apply_updates(vec![join_self(), remove_member(3)], None, None)
            .await
            .unwrap();
        let snapshot = serde_json::to_value(backend.account_state().await.unwrap()).unwrap();
        assert_eq!(
            snapshot["space_access"],
            json!([{"space_id":5,"status":"accessible"}])
        );
        backend
            .record_chat_update(channel(Some(5)), None, None)
            .await
            .unwrap();
        backend
            .apply_updates(vec![remove_member(2)], None, None)
            .await
            .unwrap();
        backend
            .apply_get_chats_snapshot(proto::GetChatsResult {
                spaces: vec![proto::Space {
                    id: 5,
                    name: "stale".into(),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .await
            .unwrap();
        let snapshot = serde_json::to_value(backend.account_state().await.unwrap()).unwrap();
        assert_eq!(
            snapshot["space_access"],
            json!([{"space_id":5,"status":"removed"}])
        );
        assert_eq!(snapshot["space_access_complete"], false);
        assert!(store.dialog(InlineId::new(7)).await.unwrap().is_some());
    }
}
#[tokio::test]
async fn parity_empty_account_cache_does_not_prove_complete_access() {
    let backend = SdkBackend::builder()
        .store(InMemoryStore::new())
        .build()
        .unwrap();
    backend
        .apply_get_chats_snapshot(proto::GetChatsResult::default())
        .await
        .unwrap();
    let snapshot = serde_json::to_value(backend.account_state().await.unwrap()).unwrap();
    assert_eq!(snapshot["space_access_complete"], false);
    assert_eq!(snapshot["spaces"], json!([]));
    assert_eq!(snapshot["space_members"], json!([]));
    assert_eq!(snapshot["users"], json!([]));
}

struct FixtureDir(std::path::PathBuf);
impl FixtureDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "inline-parity-client-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for FixtureDir {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}

#[hegel::test(test_cases = 1000)]
fn parity_account_stores_isolate_overlapping_source_ids(tc: TestCase) {
    let space = tc.draw(gs::integers::<i64>().min_value(1));
    runt().block_on(async {
        for (left, right) in [
            (
                Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
                Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            ),
            (
                Arc::new(crate::SqliteStore::open_in_memory().unwrap()) as Arc<dyn ClientStore>,
                Arc::new(crate::SqliteStore::open_in_memory().unwrap()) as Arc<dyn ClientStore>,
            ),
        ] {
            let a = SdkBackend::builder()
                .shared_store(left.clone())
                .build()
                .unwrap();
            let b = SdkBackend::builder()
                .shared_store(right.clone())
                .build()
                .unwrap();
            a.record_chat_update(channel(Some(space)), None, None)
                .await
                .unwrap();
            b.record_chat_update(channel(None), None, None)
                .await
                .unwrap();
            a.apply_updates(vec![join_self(), remove_member(2)], None, None)
                .await
                .unwrap();
            assert_eq!(
                left.dialog(InlineId::new(7))
                    .await
                    .unwrap()
                    .unwrap()
                    .space_id,
                Some(InlineId::new(space))
            );
            assert_eq!(
                right
                    .dialog(InlineId::new(7))
                    .await
                    .unwrap()
                    .unwrap()
                    .space_id,
                None
            );
            assert_eq!(
                left.account_state().await.unwrap().space_access[0].status,
                crate::SpaceAccessStatus::Removed
            );
            assert!(right.account_state().await.unwrap().space_access.is_empty());
            left.clear_account_data().await.unwrap();
            assert!(left.self_user_id().await.unwrap().is_none());
            assert!(left.account_state().await.unwrap().space_access.is_empty());
            assert!(right.dialog(InlineId::new(7)).await.unwrap().is_some());
        }
    });
}

#[tokio::test]
async fn parity_sidecar_complete_detach_partial_preservation_and_conflict_recovery() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let backend = SdkBackend::builder()
            .shared_store(store.clone())
            .build()
            .unwrap();
        let mut child = channel(Some(5));
        child.parent_chat_id = Some(3);
        child.parent_message_id = Some(9);
        backend
            .apply_sidecars(proto::UpdateSidecars {
                chats: vec![child.clone()],
                ..Default::default()
            })
            .await
            .unwrap();
        let before = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
        backend
            .apply_sidecars(proto::UpdateSidecars {
                chats: vec![proto::Chat {
                    id: 7,
                    title: "patch".into(),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .structure,
            before.structure
        );
        child.peer_id = Some(proto::Peer {
            r#type: Some(proto::peer::Type::User(proto::PeerUser { user_id: 2 })),
        });
        backend
            .apply_sidecars(proto::UpdateSidecars {
                chats: vec![child],
                ..Default::default()
            })
            .await
            .unwrap();
        assert!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .structure
                .is_none()
        );
        backend
            .apply_sidecars(proto::UpdateSidecars {
                chats: vec![channel(None)],
                ..Default::default()
            })
            .await
            .unwrap();
        let repaired = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
        assert_eq!(repaired.structure.unwrap().kind, crate::DialogKind::Channel);
        assert_eq!(
            (
                repaired.space_id,
                repaired.parent_chat_id,
                repaired.parent_message_id
            ),
            (None, None, None)
        );
    }
}

// The existing ISB1 crash journal format is read from sync.rs. Use the actual
// recovery path, rather than replaying a DTO into the cache by hand.
fn pending_payload(updates: &[proto::Update]) -> Vec<u8> {
    use prost::Message;
    let mut bytes = b"ISB1".to_vec();
    bytes.extend_from_slice(&(updates.len() as u32).to_le_bytes());
    for update in updates {
        let value = update.encode_to_vec();
        bytes.extend_from_slice(&(value.len() as u32).to_le_bytes());
        bytes.extend(value);
    }
    bytes.push(0);
    bytes
}

#[tokio::test]
async fn parity_sqlite_crash_journal_replays_structure_and_removal_before_cursor_commit() {
    for crash_boundary in 0..4 {
        let fixture = FixtureDir::new();
        let path = fixture.0.join("fixture.sqlite");
        {
            let store = crate::SqliteStore::open(&path).unwrap();
            let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
            backend
                .apply_updates(vec![join_self()], None, None)
                .await
                .unwrap();
            let mut child = channel(Some(5));
            child.parent_chat_id = Some(3);
            child.parent_message_id = Some(9);
            backend.record_chat_update(child, None, None).await.unwrap();
            let mut updates = vec![
                proto::Update {
                    update: Some(proto::update::Update::ChatMoved(proto::UpdateChatMoved {
                        chat: Some(channel(None)),
                        ..Default::default()
                    })),
                    ..Default::default()
                },
                remove_member(2),
            ];
            for (i, u) in updates.iter_mut().enumerate() {
                u.seq = Some(i as i32 + 1);
                u.date = Some(100);
            }
            store
                .save_pending_sync_batch(crate::PendingSyncBatch {
                    key: crate::SyncBucketKey::User,
                    committed_state: crate::SyncBucketState { seq: 2, date: 100 },
                    payload: pending_payload(&updates),
                })
                .await
                .unwrap();
            if crash_boundary >= 1 {
                backend
                    .apply_updates(vec![updates[0].clone()], None, None)
                    .await
                    .unwrap();
            }
            if crash_boundary == 2 {
                // Simulate process death after tombstone persistence but before member cleanup.
                store
                    .record_space_access(crate::SpaceAccessRecord {
                        space_id: InlineId::new(5),
                        status: crate::SpaceAccessStatus::Removed,
                    })
                    .await
                    .unwrap();
            }
            if crash_boundary == 3 {
                backend
                    .apply_updates(vec![updates[1].clone()], None, None)
                    .await
                    .unwrap();
            }
            assert_eq!(
                store
                    .sync_bucket_state(crate::SyncBucketKey::User)
                    .await
                    .unwrap()
                    .seq,
                0
            );
        }
        {
            let store = crate::SqliteStore::open(&path).unwrap();
            let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
            let events = backend
                .sync
                .process_realtime(&backend, vec![])
                .await
                .unwrap();
            assert!(!events.is_empty());
            assert!(store.pending_sync_batches().await.unwrap().is_empty());
            assert_eq!(
                store
                    .sync_bucket_state(crate::SyncBucketKey::User)
                    .await
                    .unwrap()
                    .seq,
                2
            );
            let dialog = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
            assert_eq!(dialog.structure.unwrap().kind, crate::DialogKind::Channel);
            assert_eq!(
                (
                    dialog.space_id,
                    dialog.parent_chat_id,
                    dialog.parent_message_id
                ),
                (None, None, None)
            );
            assert_eq!(
                store.account_state().await.unwrap().space_access[0].status,
                crate::SpaceAccessStatus::Removed
            );
            assert!(
                store
                    .space_members(InlineId::new(5))
                    .await
                    .unwrap()
                    .is_empty()
            );
            let persisted = store.pending_client_events().await.unwrap();
            assert_eq!(persisted.len(), events.len());
            assert!(
                backend
                    .sync
                    .process_realtime(&backend, vec![])
                    .await
                    .unwrap()
                    .is_empty()
            );
            assert_eq!(store.pending_client_events().await.unwrap(), persisted);
        }
    }
}

type FixtureReply = Result<proto::rpc_result::Result, (proto::rpc_error::Code, i32)>;
async fn rpc_fixture(
    store: Arc<dyn ClientStore>,
    replies: Vec<(proto::Method, FixtureReply)>,
) -> (SdkBackend, tokio::task::JoinHandle<Vec<proto::RpcCall>>) {
    rpc_fixture_skipping(store, replies, HashSet::new()).await
}

async fn rpc_fixture_skipping(
    store: Arc<dyn ClientStore>,
    replies: Vec<(proto::Method, FixtureReply)>,
    skipped: HashSet<usize>,
) -> (SdkBackend, tokio::task::JoinHandle<Vec<proto::RpcCall>>) {
    rpc_fixture_controlled(store, replies, skipped, None).await
}

async fn rpc_fixture_controlled(
    store: Arc<dyn ClientStore>,
    replies: Vec<(proto::Method, FixtureReply)>,
    skipped: HashSet<usize>,
    mut gate: Option<(
        usize,
        tokio::sync::oneshot::Sender<()>,
        tokio::sync::oneshot::Receiver<()>,
    )>,
) -> (SdkBackend, tokio::task::JoinHandle<Vec<proto::RpcCall>>) {
    use futures_util::{SinkExt, StreamExt};
    use prost::Message;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        let first = ws.next().await.unwrap().unwrap();
        let tokio_tungstenite::tungstenite::Message::Binary(bytes) = first else {
            panic!("connection init must be binary")
        };
        let init = proto::ClientMessage::decode(&*bytes).unwrap();
        assert!(matches!(
            init.body,
            Some(proto::client_message::Body::ConnectionInit(_))
        ));
        ws.send(tokio_tungstenite::tungstenite::Message::Binary(
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
        let mut calls = Vec::new();
        for (index, (method, reply)) in replies.into_iter().enumerate() {
            let (id, call) = loop {
                let frame = tokio::time::timeout(std::time::Duration::from_secs(3), ws.next())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap();
                if let tokio_tungstenite::tungstenite::Message::Binary(bytes) = frame {
                    let request = proto::ClientMessage::decode(&*bytes).unwrap();
                    if let Some(proto::client_message::Body::RpcCall(call)) = request.body {
                        break (request.id, call);
                    }
                }
            };
            assert_eq!(call.method, method as i32);
            if skipped.contains(&index) {
                calls.push(call);
                continue;
            }
            if gate.as_ref().is_some_and(|(at, _, _)| *at == index) {
                let (_, started, release) = gate.take().unwrap();
                started.send(()).unwrap();
                release.await.unwrap();
            }
            let body = match reply {
                Ok(result) => proto::server_protocol_message::Body::RpcResult(proto::RpcResult {
                    req_msg_id: id,
                    result: Some(result),
                }),
                Err((error_code, code)) => {
                    proto::server_protocol_message::Body::RpcError(proto::RpcError {
                        req_msg_id: id,
                        error_code: error_code as i32,
                        code,
                        message: "fixture response".into(),
                        ..Default::default()
                    })
                }
            };
            ws.send(tokio_tungstenite::tungstenite::Message::Binary(
                proto::ServerProtocolMessage {
                    id: index as u64 + 2,
                    body: Some(body),
                }
                .encode_to_vec()
                .into(),
            ))
            .await
            .unwrap();
            calls.push(call);
        }
        if !skipped.is_empty() {
            std::future::pending::<()>().await;
        }
        calls
    });
    store
        .save_session(StoredSession {
            auth: AuthCredential::AccessToken {
                token: crate::AuthToken::try_new("synthetic-fixture-token").unwrap(),
            },
            account_namespace: Some("fixture".into()),
        })
        .await
        .unwrap();
    let backend = SdkBackend::builder()
        .shared_store(store)
        .realtime_url(format!("ws://{address}/fixture"))
        .without_realtime_handshake()
        .build()
        .unwrap();
    (backend, server)
}

#[tokio::test]
async fn parity_retention_gap_revalidates_stale_space_and_persists_source_denial() {
    let fixture = FixtureDir::new();
    let path = fixture.0.join("fixture.sqlite");
    {
        let store = crate::SqliteStore::open(&path).unwrap();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
        backend
            .apply_updates(vec![join_self()], None, None)
            .await
            .unwrap();
        backend
            .record_chat_update(channel(Some(5)), None, None)
            .await
            .unwrap();
        drop(backend);
        // The self-removal event was lost; a stale catalog still has this space.
        let replies = vec![
            (
                proto::Method::GetUpdatesState,
                Ok(proto::rpc_result::Result::GetUpdatesState(
                    proto::GetUpdatesStateResult {
                        date: 100,
                        seq: Some(2),
                        ..Default::default()
                    },
                )),
            ),
            (
                proto::Method::GetChats,
                Ok(proto::rpc_result::Result::GetChats(proto::GetChatsResult {
                    spaces: vec![proto::Space {
                        id: 5,
                        name: "stale".into(),
                        ..Default::default()
                    }],
                    ..Default::default()
                })),
            ),
            (
                proto::Method::GetMe,
                Ok(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                    user: Some(proto::User {
                        id: 2,
                        ..Default::default()
                    }),
                })),
            ),
            (
                proto::Method::GetUserSettings,
                Ok(proto::rpc_result::Result::GetUserSettings(
                    proto::GetUserSettingsResult {
                        user_settings: Some(proto::UserSettings::default()),
                    },
                )),
            ),
            (
                proto::Method::GetSpace,
                Err((proto::rpc_error::Code::SpaceIdInvalid, 400)),
            ),
        ];
        let (backend, server) = rpc_fixture(Arc::new(store.clone()), replies).await;
        backend.repair_user_bucket(1).await.unwrap();
        server.await.unwrap();
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Removed
        );
        assert!(store.dialog(InlineId::new(7)).await.unwrap().is_some());
    }
    let store = crate::SqliteStore::open(&path).unwrap();
    assert_eq!(
        store.account_state().await.unwrap().space_access[0].status,
        crate::SpaceAccessStatus::Removed
    );
    assert!(!store.account_state().await.unwrap().space_access_complete);
    drop(store);
}

#[tokio::test]
async fn parity_transient_space_refresh_failure_does_not_claim_removal() {
    let store = InMemoryStore::new();
    let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
    backend
        .apply_updates(vec![join_self()], None, None)
        .await
        .unwrap();
    let (backend, server) = rpc_fixture(
        Arc::new(store.clone()),
        vec![(
            proto::Method::GetSpace,
            Err((proto::rpc_error::Code::InternalError, 500)),
        )],
    )
    .await;
    assert!(
        backend
            .repair_space_bucket(InlineId::new(5), 0)
            .await
            .is_err()
    );
    server.await.unwrap();
    assert_eq!(
        store.account_state().await.unwrap().space_access[0].status,
        crate::SpaceAccessStatus::Accessible
    );
}

#[tokio::test]
async fn parity_creation_retains_canonical_structure_description_and_creator() {
    let store = InMemoryStore::new();
    let mut source = channel(Some(5));
    source.description = Some("description".into());
    source.created_by = Some(2);
    let (backend, server) = rpc_fixture(
        Arc::new(store.clone()),
        vec![(
            proto::Method::CreateChat,
            Ok(proto::rpc_result::Result::CreateChat(
                proto::CreateChatResult {
                    chat: Some(source),
                    ..Default::default()
                },
            )),
        )],
    )
    .await;
    backend
        .create_thread(CreateThreadRequest {
            title: Some("channel".into()),
            space_id: Some(InlineId::new(5)),
            description: None,
            emoji: None,
            is_public: false,
            participants: vec![],
        })
        .await
        .unwrap();
    server.await.unwrap();
    let dialog = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
    assert_eq!(dialog.structure.unwrap().space_id, Some(InlineId::new(5)));
    assert_eq!(dialog.description.as_deref(), Some("description"));
    assert_eq!(dialog.created_by, Some(InlineId::new(2)));
}

fn bold_json(offset: i64, length: i64) -> serde_json::Value {
    json!({"kind":"TYPE_BOLD","offset":offset,"length":length,"user_id":null,"agent_id":null,"group_id":null,"chat_id":null,"value":null})
}
fn text_request_json(entities: serde_json::Value) -> serde_json::Value {
    json!({"peer":{"type":"chat","chat_id":7},"text":"a😀b","entities":entities})
}
fn edit_request_json(entities: serde_json::Value) -> serde_json::Value {
    json!({"chat_id":7,"message_id":1,"text":"a😀b","entities":entities})
}
fn upload_request_json(entities: serde_json::Value) -> serde_json::Value {
    json!({"peer":{"type":"chat","chat_id":7},"kind":"document","caption":"a😀b","entities":entities})
}

#[test]
fn parity_outbound_entities_default_empty_and_round_trip_signed_ranges() {
    for entity in [json!([]), json!([bold_json(i64::MIN, i64::MAX)])] {
        let send: SendTextRequest =
            serde_json::from_value(text_request_json(entity.clone())).unwrap();
        let edit: EditMessageRequest =
            serde_json::from_value(edit_request_json(entity.clone())).unwrap();
        let upload: UploadRequest =
            serde_json::from_value(upload_request_json(entity.clone())).unwrap();
        for value in [
            serde_json::to_value(send).unwrap(),
            serde_json::to_value(edit).unwrap(),
            serde_json::to_value(upload).unwrap(),
        ] {
            assert_eq!(value["entities"], entity);
        }
    }
    for value in [
        serde_json::to_value(SendTextRequest::new(
            PeerRef::Chat {
                chat_id: InlineId::new(7),
            },
            "plain",
        ))
        .unwrap(),
        serde_json::to_value(
            serde_json::from_value::<EditMessageRequest>(
                json!({"chat_id":7,"message_id":1,"text":"plain"}),
            )
            .unwrap(),
        )
        .unwrap(),
        serde_json::to_value(
            serde_json::from_value::<UploadRequest>(
                json!({"peer":{"type":"chat","chat_id":7},"kind":"document"}),
            )
            .unwrap(),
        )
        .unwrap(),
    ] {
        assert_eq!(value["entities"], json!([]));
    }
}

#[tokio::test]
async fn parity_outbound_rejects_malformed_utf16_before_any_session_or_upload() {
    let backend = SdkBackend::builder()
        .store(InMemoryStore::new())
        .build()
        .unwrap();
    for (offset, length) in [
        (-1, 1),
        (0, -1),
        (0, 0),
        (i64::MAX, 1),
        (1, i64::MAX),
        (2, 1),
        (1, 1),
        (4, 1),
    ] {
        let entities = json!([bold_json(offset, length)]);
        let send = backend
            .send_text(serde_json::from_value(text_request_json(entities.clone())).unwrap())
            .await
            .unwrap_err();
        let edit = backend
            .edit_message(serde_json::from_value(edit_request_json(entities.clone())).unwrap())
            .await
            .unwrap_err();
        let upload = backend
            .send_media(
                serde_json::from_value(upload_request_json(entities)).unwrap(),
                vec![1],
                None,
            )
            .await
            .unwrap_err();
        for error in [send, edit, upload] {
            assert_eq!(
                error.category,
                ClientErrorCategory::InvalidInput,
                "offset={offset}, length={length}: {error:?}"
            );
        }
    }
}

#[tokio::test]
async fn parity_send_and_edit_transmit_entities_with_non_bmp_utf16_offsets() {
    let store = InMemoryStore::new();
    let (backend, server) = rpc_fixture(
        Arc::new(store.clone()),
        vec![
            (
                proto::Method::SendMessage,
                Ok(proto::rpc_result::Result::SendMessage(
                    proto::SendMessageResult::default(),
                )),
            ),
            (
                proto::Method::EditMessage,
                Ok(proto::rpc_result::Result::EditMessage(
                    proto::EditMessageResult::default(),
                )),
            ),
        ],
    )
    .await;
    backend
        .send_text(serde_json::from_value(text_request_json(json!([bold_json(1, 2)]))).unwrap())
        .await
        .unwrap();
    backend
        .edit_message(serde_json::from_value(edit_request_json(json!([bold_json(1, 2)]))).unwrap())
        .await
        .unwrap();
    let calls = server.await.unwrap();
    for call in calls {
        let entities = match call.input.unwrap() {
            proto::rpc_call::Input::SendMessage(input) => input.entities,
            proto::rpc_call::Input::EditMessage(input) => input.entities,
            _ => panic!("unexpected call"),
        }
        .expect("native entities");
        assert_eq!(entities.entities.len(), 1);
        assert_eq!(entities.entities[0].offset, 1);
        assert_eq!(entities.entities[0].length, 2);
        assert_eq!(
            entities.entities[0].r#type,
            proto::message_entity::Type::Bold as i32
        );
    }
}

#[tokio::test]
async fn parity_upload_transmits_caption_entities_through_native_upload_and_send() {
    let store = InMemoryStore::new();
    let (backend, server) = rpc_fixture(
        Arc::new(store.clone()),
        vec![
            (
                proto::Method::CreateUpload,
                Ok(proto::rpc_result::Result::CreateUpload(
                    proto::CreateUploadResult {
                        upload_id: vec![7; 16],
                        part_size: 512 * 1024,
                        part_count: 1,
                        ..Default::default()
                    },
                )),
            ),
            (
                proto::Method::SaveUploadPart,
                Ok(proto::rpc_result::Result::SaveUploadPart(
                    proto::SaveUploadPartResult::default(),
                )),
            ),
            (
                proto::Method::FinishUpload,
                Ok(proto::rpc_result::Result::FinishUpload(
                    proto::FinishUploadResult {
                        state: Some(proto::finish_upload_result::State::Complete(
                            proto::UploadComplete {
                                file_unique_id: "fixture-document".into(),
                                media: Some(proto::upload_complete::Media::Document(
                                    proto::Document {
                                        id: 99,
                                        ..Default::default()
                                    },
                                )),
                            },
                        )),
                    },
                )),
            ),
            (
                proto::Method::SendMessage,
                Ok(proto::rpc_result::Result::SendMessage(
                    proto::SendMessageResult::default(),
                )),
            ),
        ],
    )
    .await;
    backend
        .send_media(
            serde_json::from_value(upload_request_json(json!([bold_json(1, 2)]))).unwrap(),
            vec![1, 2, 3],
            None,
        )
        .await
        .unwrap();
    let calls = server.await.unwrap();
    let proto::rpc_call::Input::SendMessage(input) = calls.last().unwrap().input.clone().unwrap()
    else {
        panic!("send must follow upload")
    };
    assert_eq!(input.message.as_deref(), Some("a😀b"));
    let entities = input.entities.expect("caption entities");
    assert_eq!(entities.entities[0].offset, 1);
    assert_eq!(entities.entities[0].length, 2);
}

#[test]
fn parity_structure_requires_every_nullable_field_to_be_present() {
    let complete = json!({"kind":"channel","peer_user_id":null,"space_id":null,"parent_chat_id":null,"parent_message_id":null});
    assert!(serde_json::from_value::<crate::DialogStructure>(complete.clone()).is_ok());
    for key in [
        "peer_user_id",
        "space_id",
        "parent_chat_id",
        "parent_message_id",
    ] {
        let mut partial = complete.clone();
        partial.as_object_mut().unwrap().remove(key);
        assert!(
            serde_json::from_value::<crate::DialogStructure>(partial).is_err(),
            "missing {key} must not be an authoritative clear"
        );
    }
}

#[tokio::test]
async fn parity_explicit_entities_and_markdown_reach_native_together() {
    // processText.ts remaps client UTF-16 entities through Markdown source maps.
    let (backend, server) = rpc_fixture(
        Arc::new(InMemoryStore::new()),
        vec![
            (
                proto::Method::SendMessage,
                Ok(proto::rpc_result::Result::SendMessage(
                    proto::SendMessageResult::default(),
                )),
            ),
            (
                proto::Method::EditMessage,
                Ok(proto::rpc_result::Result::EditMessage(
                    proto::EditMessageResult::default(),
                )),
            ),
        ],
    )
    .await;
    let mut send: SendTextRequest =
        serde_json::from_value(text_request_json(json!([bold_json(1, 2)]))).unwrap();
    send.parse_markdown = true;
    backend.send_text(send).await.unwrap();
    let mut edit: EditMessageRequest =
        serde_json::from_value(edit_request_json(json!([bold_json(1, 2)]))).unwrap();
    edit.parse_markdown = true;
    backend.edit_message(edit).await.unwrap();
    for call in server.await.unwrap() {
        let (markdown, entities) = match call.input.unwrap() {
            proto::rpc_call::Input::SendMessage(input) => (input.parse_markdown, input.entities),
            proto::rpc_call::Input::EditMessage(input) => (input.parse_markdown, input.entities),
            _ => panic!("unexpected call"),
        };
        assert_eq!(markdown, Some(true));
        assert_eq!(entities.unwrap().entities[0].length, 2);
    }
}

#[hegel::test(test_cases = 2000)]
fn parity_utf16_ranges_accept_exact_scalar_spans_and_preserve_all_supported_payloads(tc: TestCase) {
    let prefix = tc.draw(gs::text().max_size(100));
    let selected = format!("😀{}", tc.draw(gs::text().max_size(100)));
    let text = format!("{prefix}{selected}tail");
    let id = tc.draw(gs::integers::<i64>().min_value(1));
    let agent = tc.draw(gs::booleans()).then_some(InlineId::new(id));
    for kind in 1..=19 {
        if kind == proto::message_entity::Type::ThreadTitle as i32 {
            continue;
        }
        let kind = proto::message_entity::Type::try_from(kind).unwrap();
        let mut record = crate::MessageEntityRecord {
            kind: kind.as_str_name().into(),
            offset: prefix.encode_utf16().count() as i64,
            length: selected.encode_utf16().count() as i64,
            user_id: None,
            agent_id: None,
            group_id: None,
            chat_id: None,
            value: None,
        };
        use proto::message_entity::Type;
        match kind {
            Type::Mention => {
                record.user_id = Some(InlineId::new(id));
                record.agent_id = agent;
            }
            Type::BotCommand => {
                record.user_id = tc.draw(gs::booleans()).then_some(InlineId::new(id))
            }
            Type::GroupMention => record.group_id = Some(InlineId::new(id)),
            Type::Thread => record.chat_id = Some(InlineId::new(id)),
            Type::Pre => record.value = tc.draw(gs::booleans()).then(|| format!("lang{id}")),
            Type::TextUrl => record.value = Some(format!("https://example.invalid/{id}")),
            _ => {}
        }
        let native = crate::entities::to_proto(&text, &[record.clone()])
            .unwrap()
            .unwrap();
        assert_eq!(native.entities[0].r#type, kind as i32);
        assert_eq!(message_entity_from_proto(&native.entities[0]), record);
    }
}

#[hegel::test(test_cases = 2000)]
fn parity_utf16_full_signed_ranges_match_the_scalar_boundary_contract(tc: TestCase) {
    let offset = tc.draw(gs::integers::<i64>());
    let length = tc.draw(gs::integers::<i64>());
    let record: crate::MessageEntityRecord =
        serde_json::from_value(bold_json(offset, length)).unwrap();
    let result = crate::entities::to_proto("a😀b", &[record]);
    match (offset, length) {
        (0, 1 | 3 | 4) | (1, 2 | 3) | (3, 1) => {
            let native = result.unwrap().unwrap();
            assert_eq!(
                (native.entities[0].offset, native.entities[0].length),
                (offset, length)
            );
        }
        _ => assert_eq!(
            result.unwrap_err().category,
            ClientErrorCategory::InvalidInput
        ),
    }
}

#[tokio::test]
async fn parity_invalid_entities_fail_every_mutation_sibling_before_auth() {
    let sdk = SdkBackend::builder()
        .store(InMemoryStore::new())
        .build()
        .unwrap();
    let memory = crate::InMemoryBackend::new();
    for backend in [&sdk as &dyn ClientBackend, &memory] {
        for (offset, length) in [
            (-1, 1),
            (0, -1),
            (0, 0),
            (i64::MAX, 1),
            (1, i64::MAX),
            (2, 1),
            (1, 1),
            (4, 1),
        ] {
            let entities = json!([bold_json(offset, length)]);
            let send: SendTextRequest =
                serde_json::from_value(text_request_json(entities.clone())).unwrap();
            let edit: EditMessageRequest =
                serde_json::from_value(edit_request_json(entities.clone())).unwrap();
            let upload: UploadRequest =
                serde_json::from_value(upload_request_json(entities)).unwrap();
            let errors = [
                backend.send_text(send.clone()).await.unwrap_err(),
                backend
                    .send_interactive_text(SendInteractiveTextRequest {
                        message: send,
                        actions: MessageActions::default(),
                    })
                    .await
                    .unwrap_err(),
                backend.edit_message(edit.clone()).await.unwrap_err(),
                backend
                    .edit_interactive_message(EditInteractiveMessageRequest {
                        message: edit,
                        actions: MessageActions::default(),
                    })
                    .await
                    .unwrap_err(),
                backend.send_media(upload, vec![1], None).await.unwrap_err(),
            ];
            for error in errors {
                assert_eq!(error.category, ClientErrorCategory::InvalidInput);
            }
        }
    }
}

#[tokio::test]
async fn parity_memory_mutations_preserve_entities_and_media_caption_shape() {
    let backend = crate::InMemoryBackend::new();
    backend
        .connect(ConnectRequest::new(AuthCredential::AccessToken {
            token: AuthToken::try_new("fixture-token").unwrap(),
        }))
        .await
        .unwrap();
    let entities = json!([bold_json(1, 2)]);
    let expected: Vec<crate::MessageEntityRecord> =
        serde_json::from_value(entities.clone()).unwrap();
    for interactive in [false, true] {
        let mut send: SendTextRequest =
            serde_json::from_value(text_request_json(entities.clone())).unwrap();
        send.parse_markdown = true;
        let sent = if interactive {
            backend
                .send_interactive_text(SendInteractiveTextRequest {
                    message: send,
                    actions: MessageActions::default(),
                })
                .await
                .unwrap()
        } else {
            backend.send_text(send).await.unwrap()
        };
        assert_eq!(sent.message.unwrap().metadata.entities, expected);
    }
    let sent = backend
        .send_media(
            serde_json::from_value(upload_request_json(entities.clone())).unwrap(),
            vec![1],
            None,
        )
        .await
        .unwrap();
    let message = sent.message.unwrap();
    assert_eq!(message.metadata.entities, expected);
    let before = message.content.clone();
    let mut edit: EditMessageRequest = serde_json::from_value(edit_request_json(entities)).unwrap();
    edit.message_id = message.message_id;
    for interactive in [false, true] {
        let edited = if interactive {
            backend
                .edit_interactive_message(EditInteractiveMessageRequest {
                    message: edit.clone(),
                    actions: MessageActions::default(),
                })
                .await
                .unwrap()
        } else {
            backend.edit_message(edit.clone()).await.unwrap()
        };
        let ClientEvent::MessageStored { message } = &edited.events[0] else {
            panic!("edited message event");
        };
        assert_eq!(message.content, before);
        assert_eq!(message.metadata.entities, expected);
    }
}

#[test]
fn parity_entity_payload_validation_rejects_unknown_kinds_and_conflicting_identities() {
    for kind in [
        "TYPE_UNSPECIFIED",
        "TYPE_THREAD_TITLE",
        "TYPE_UNKNOWN_999",
        "invented",
    ] {
        let mut record: crate::MessageEntityRecord =
            serde_json::from_value(bold_json(0, 1)).unwrap();
        record.kind = kind.into();
        assert_eq!(
            crate::entities::to_proto("x", &[record])
                .unwrap_err()
                .category,
            ClientErrorCategory::Unsupported
        );
    }
    for kind in [
        "TYPE_MENTION",
        "TYPE_GROUP_MENTION",
        "TYPE_THREAD",
        "TYPE_TEXT_URL",
    ] {
        let mut record: crate::MessageEntityRecord =
            serde_json::from_value(bold_json(0, 1)).unwrap();
        record.kind = kind.into();
        assert_eq!(
            crate::entities::to_proto("x", &[record])
                .unwrap_err()
                .category,
            ClientErrorCategory::InvalidInput
        );
    }
    for field in ["user_id", "agent_id", "group_id", "chat_id", "value"] {
        let mut value = bold_json(0, 1);
        value[field] = if field == "value" {
            json!("value")
        } else {
            json!(1)
        };
        let record = serde_json::from_value(value).unwrap();
        assert_eq!(
            crate::entities::to_proto("x", &[record])
                .unwrap_err()
                .category,
            ClientErrorCategory::InvalidInput
        );
    }
}

#[tokio::test]
async fn parity_sqlite_never_promotes_incomplete_structure_json_to_complete() {
    let dir = FixtureDir::new();
    let path = dir.0.join("structure.sqlite");
    let store = crate::SqliteStore::open(&path).unwrap();
    let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
    backend
        .record_chat_update(channel(Some(5)), None, None)
        .await
        .unwrap();
    let complete = serde_json::to_value(
        store
            .dialog(InlineId::new(7))
            .await
            .unwrap()
            .unwrap()
            .structure,
    )
    .unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    for key in [
        "peer_user_id",
        "space_id",
        "parent_chat_id",
        "parent_message_id",
    ] {
        let mut partial = complete.clone();
        partial.as_object_mut().unwrap().remove(key);
        connection
            .execute(
                "UPDATE dialogs SET structure_json = ?1 WHERE chat_id = 7",
                [partial.to_string()],
            )
            .unwrap();
        assert!(
            store.dialog(InlineId::new(7)).await.is_err(),
            "incomplete persisted {key} must fail closed"
        );
    }
}

#[test]
fn parity_entity_scale_is_iterative_and_preserves_order() {
    let text = "😀".repeat(100_000);
    let entities = (0..100_000)
        .map(|i| serde_json::from_value::<crate::MessageEntityRecord>(bold_json(i * 2, 2)).unwrap())
        .collect::<Vec<_>>();
    let native = crate::entities::to_proto(&text, &entities)
        .unwrap()
        .unwrap();
    assert_eq!(native.entities.len(), 100_000);
    assert_eq!(native.entities.last().unwrap().offset, 199_998);
    let copy = entities.clone();
    assert_eq!(entities, copy);
    let encoded = serde_json::to_vec(&entities).unwrap();
    let decoded: Vec<crate::MessageEntityRecord> = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded, entities);
    assert!(!format!("{:?}", native.entities[0]).is_empty());
}

#[test]
fn parity_unqualified_bot_command_preserves_range_only_native_form() {
    // A present botCommand payload with ID 0 is rejected by
    // resolveBotCommandTargets.ts; a range-only command is valid and untargeted.
    let mut record: crate::MessageEntityRecord = serde_json::from_value(bold_json(0, 5)).unwrap();
    record.kind = "TYPE_BOT_COMMAND".into();
    let native = crate::entities::to_proto("/help", &[record])
        .unwrap()
        .unwrap();
    assert_eq!(native.entities[0].entity, None);
}

fn source_space(id: i64) -> proto::Space {
    proto::Space {
        id,
        name: format!("space{id}"),
        ..Default::default()
    }
}
fn get_space_reply(id: i64) -> Result<proto::rpc_result::Result, (proto::rpc_error::Code, i32)> {
    Ok(proto::rpc_result::Result::GetSpace(proto::GetSpaceResult {
        space: Some(source_space(id)),
        membership: Some(proto::Member {
            space_id: id,
            user_id: 2,
            ..Default::default()
        }),
        ..Default::default()
    }))
}

#[tokio::test]
async fn parity_initial_dialog_discovery_proves_unique_spaces_and_keeps_denied_chats() {
    let store = InMemoryStore::new();
    let chats = proto::GetChatsResult {
        spaces: vec![source_space(2), source_space(1), source_space(1)],
        chats: vec![channel(Some(2))],
        ..Default::default()
    };
    let (backend, server) = rpc_fixture(
        Arc::new(store.clone()),
        vec![
            (
                proto::Method::GetChats,
                Ok(proto::rpc_result::Result::GetChats(chats)),
            ),
            (proto::Method::GetSpace, get_space_reply(1)),
            (
                proto::Method::GetSpace,
                Err((proto::rpc_error::Code::SpaceIdInvalid, 404)),
            ),
        ],
    )
    .await;
    let dialogs = backend.dialogs(DialogsRequest::default()).await.unwrap();
    let snapshot = backend.account_state().await.unwrap();
    assert_eq!(
        snapshot.space_access,
        vec![
            crate::SpaceAccessRecord {
                space_id: InlineId::new(1),
                status: crate::SpaceAccessStatus::Accessible
            },
            crate::SpaceAccessRecord {
                space_id: InlineId::new(2),
                status: crate::SpaceAccessStatus::Removed
            },
        ]
    );
    assert!(!snapshot.space_access_complete);
    assert_eq!(dialogs.dialogs.len(), 1);
    assert_eq!(dialogs.dialogs[0].chat_id, InlineId::new(7));
    let calls = server.await.unwrap();
    assert_eq!(calls.len(), 3);
    assert_eq!(store.self_user_id().await.unwrap(), Some(InlineId::new(2)));
}

#[tokio::test]
async fn parity_initial_space_refresh_is_bounded_fair_and_transient_failure_retries() {
    let store = InMemoryStore::new();
    // Ten source spaces exceed the eight-RPC cap; the next page rotates past
    // the first batch, then a later call retries the transient first failure.
    let chats = proto::GetChatsResult {
        spaces: (1..=10).map(source_space).collect(),
        ..Default::default()
    };
    let mut replies = Vec::new();
    for round in 0..3 {
        replies.push((
            proto::Method::GetChats,
            Ok(proto::rpc_result::Result::GetChats(chats.clone())),
        ));
        for id in match round {
            0 => vec![1, 2, 3, 4, 5, 6, 7, 8],
            1 => vec![9, 10, 1, 2, 3, 4, 5, 6],
            _ => vec![7, 8, 9, 10, 1, 2, 3, 4],
        } {
            replies.push((
                proto::Method::GetSpace,
                if round == 0 && id == 1 {
                    Err((proto::rpc_error::Code::InternalError, 500))
                } else {
                    get_space_reply(id)
                },
            ));
        }
    }
    let (backend, server) = rpc_fixture(Arc::new(store.clone()), replies).await;
    backend.dialogs(DialogsRequest::default()).await.unwrap();
    let first = backend.account_state().await.unwrap();
    assert_eq!(first.space_access.len(), 8);
    assert_eq!(
        first.space_access[0].status,
        crate::SpaceAccessStatus::Unknown
    );
    assert!(
        !first
            .space_access
            .iter()
            .any(|access| access.space_id == InlineId::new(9))
    );
    for _ in 0..2 {
        backend.dialogs(DialogsRequest::default()).await.unwrap();
    }
    let final_snapshot = backend.account_state().await.unwrap();
    assert_eq!(final_snapshot.space_access.len(), 10);
    assert!(
        final_snapshot
            .space_access
            .iter()
            .all(|a| a.status == crate::SpaceAccessStatus::Accessible)
    );
    assert!(!final_snapshot.space_access_complete);
    let calls = server.await.unwrap();
    let spaces = calls
        .iter()
        .filter_map(|call| match &call.input {
            Some(proto::rpc_call::Input::GetSpace(input)) => Some(input.space_id),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        spaces,
        vec![
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1, 2, 3, 4
        ]
    );
}

#[tokio::test]
async fn parity_initial_refresh_timeouts_are_bounded_and_leave_unattempted_pending() {
    let store = InMemoryStore::new();
    let chats = proto::GetChatsResult {
        spaces: (1..=8).map(source_space).collect(),
        ..Default::default()
    };
    let mut replies = vec![(
        proto::Method::GetChats,
        Ok(proto::rpc_result::Result::GetChats(chats)),
    )];
    replies.extend((1..=3).map(|id| (proto::Method::GetSpace, get_space_reply(id))));
    let (backend, server) =
        rpc_fixture_skipping(Arc::new(store.clone()), replies, HashSet::from([1, 2, 3])).await;
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(7),
        backend.dialogs(DialogsRequest::default()),
    )
    .await;
    // Stop the intentionally silent synthetic peer even if the assertion fails.
    server.abort();
    let _ = server.await;
    result
        .expect("source-access discovery must finish within its time budget")
        .unwrap();
    let snapshot = backend.account_state().await.unwrap();
    assert_eq!(
        snapshot.space_access.len(),
        3,
        "two per-RPC timeouts plus the aggregate deadline"
    );
    assert!(
        snapshot
            .space_access
            .iter()
            .all(|a| a.status == crate::SpaceAccessStatus::Unknown)
    );
    assert!(!snapshot.space_access.iter().any(|a| a.space_id.get() >= 4));
    assert!(!snapshot.space_access_complete);
}

#[tokio::test]
async fn parity_initial_refresh_failure_invalidates_access_but_preserves_removal_tombstone() {
    let store = InMemoryStore::new();
    for (id, status) in [
        (1, crate::SpaceAccessStatus::Accessible),
        (2, crate::SpaceAccessStatus::Removed),
    ] {
        store
            .record_space_access(crate::SpaceAccessRecord {
                space_id: InlineId::new(id),
                status,
            })
            .await
            .unwrap();
    }
    let (backend, server) = rpc_fixture(
        Arc::new(store.clone()),
        vec![
            (
                proto::Method::GetChats,
                Ok(proto::rpc_result::Result::GetChats(
                    proto::GetChatsResult::default(),
                )),
            ),
            (
                proto::Method::GetSpace,
                Err((proto::rpc_error::Code::InternalError, 500)),
            ),
            (
                proto::Method::GetSpace,
                Err((proto::rpc_error::Code::InternalError, 500)),
            ),
        ],
    )
    .await;
    backend.dialogs(DialogsRequest::default()).await.unwrap();
    server.await.unwrap();
    assert_eq!(
        backend.account_state().await.unwrap().space_access,
        vec![
            crate::SpaceAccessRecord {
                space_id: InlineId::new(1),
                status: crate::SpaceAccessStatus::Unknown
            },
            crate::SpaceAccessRecord {
                space_id: InlineId::new(2),
                status: crate::SpaceAccessStatus::Removed
            },
        ]
    );
}

#[tokio::test]
async fn parity_review_get_chats_preserves_pin_ids() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let backend = SdkBackend::builder()
            .shared_store(store.clone())
            .build()
            .unwrap();
        backend
            .record_chat_update(channel(None), None, None)
            .await
            .unwrap();
        backend
            .mutate_dialog(InlineId::new(7), |d| {
                d.pinned_message_ids = vec![InlineId::new(99)]
            })
            .await
            .unwrap();
        backend
            .apply_get_chats_snapshot(proto::GetChatsResult {
                chats: vec![channel(None)],
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(
            store
                .dialog(InlineId::new(7))
                .await
                .unwrap()
                .unwrap()
                .pinned_message_ids,
            vec![InlineId::new(99)]
        );
    }
}

#[hegel::test(test_cases = 1000)]
fn parity_review_old_structure_replay_never_reattaches(tc: TestCase) {
    let seq = tc.draw(gs::integers::<i32>().min_value(1).max_value(i32::MAX - 1));
    runt().block_on(async {
        for store in [
            Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
        ] {
            let backend = SdkBackend::builder()
                .shared_store(store.clone())
                .build()
                .unwrap();
            let mut newer = channel(None);
            newer.seq = Some(seq + 1);
            backend.record_chat_update(newer, None, None).await.unwrap();
            let mut old = channel(Some(5));
            old.seq = Some(seq);
            old.parent_chat_id = Some(3);
            old.parent_message_id = Some(9);
            backend
                .apply_get_chats_snapshot(proto::GetChatsResult {
                    chats: vec![old.clone()],
                    ..Default::default()
                })
                .await
                .unwrap();
            backend
                .apply_sidecars(proto::UpdateSidecars {
                    chats: vec![old.clone()],
                    ..Default::default()
                })
                .await
                .unwrap();
            backend.record_chat_update(old, None, None).await.unwrap();
            let after = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
            assert_eq!(after.space_id, None);
            assert_eq!(after.parent_chat_id, None);
            assert_eq!(structure(&after)["kind"], "channel");
        }
    });
}

#[tokio::test]
async fn parity_review_held_access_cannot_revive_removal_or_clear() {
    for clear in [false, true] {
        for store in [
            Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
        ] {
            store.record_self_user_id(InlineId::new(2)).await.unwrap();
            let (began_tx, began) = tokio::sync::oneshot::channel();
            let (release, release_rx) = tokio::sync::oneshot::channel();
            let (backend, server) = rpc_fixture_controlled(
                store.clone(),
                vec![(proto::Method::GetSpace, get_space_reply(5))],
                HashSet::new(),
                Some((0, began_tx, release_rx)),
            )
            .await;
            let worker = backend.clone();
            let task = tokio::spawn(async move {
                worker
                    .refresh_discovered_space_access(vec![InlineId::new(5)])
                    .await
            });
            began.await.unwrap();
            if clear {
                store.clear_account_data().await.unwrap();
            } else {
                backend
                    .apply_updates(vec![remove_member(2)], None, None)
                    .await
                    .unwrap();
            }
            release.send(()).unwrap();
            let result = task.await.unwrap();
            if clear {
                assert_eq!(
                    result.unwrap_err().category,
                    ClientErrorCategory::AuthRequired
                );
            } else {
                result.unwrap();
            }
            server.await.unwrap();
            let snapshot = store.account_state().await.unwrap();
            if clear {
                assert!(snapshot.space_access.is_empty());
                assert!(snapshot.spaces.is_empty());
                assert!(snapshot.space_members.is_empty());
                assert_eq!(store.self_user_id().await.unwrap(), None);
            } else {
                assert_eq!(
                    snapshot.space_access[0].status,
                    crate::SpaceAccessStatus::Removed
                );
            }
        }
    }
}

#[tokio::test]
async fn parity_review_queued_join_does_not_revive_source_denial() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let backend = SdkBackend::builder()
            .shared_store(store.clone())
            .build()
            .unwrap();
        backend
            .apply_updates(vec![join_self()], None, None)
            .await
            .unwrap();
        backend
            .record_space_removed(InlineId::new(5))
            .await
            .unwrap();
        backend
            .apply_updates(vec![join_self()], None, None)
            .await
            .unwrap();
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Removed
        );
        assert!(
            store
                .space_members(InlineId::new(5))
                .await
                .unwrap()
                .is_empty()
        );
    }
}

#[tokio::test]
async fn parity_review_held_get_chats_cannot_reattach_or_repopulate_clear() {
    for clear in [false, true] {
        for store in [
            Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
        ] {
            let mut old = channel(None);
            old.seq = Some(10);
            old.parent_chat_id = Some(3);
            old.parent_message_id = Some(9);
            let (began_tx, began) = tokio::sync::oneshot::channel();
            let (release, release_rx) = tokio::sync::oneshot::channel();
            let (backend, server) = rpc_fixture_controlled(
                store.clone(),
                vec![(
                    proto::Method::GetChats,
                    Ok(proto::rpc_result::Result::GetChats(proto::GetChatsResult {
                        chats: vec![old],
                        ..Default::default()
                    })),
                )],
                HashSet::new(),
                Some((0, began_tx, release_rx)),
            )
            .await;
            let worker = backend.clone();
            let task = tokio::spawn(async move {
                worker.dialogs(DialogsRequest::default()).await.unwrap();
            });
            began.await.unwrap();
            if clear {
                store.clear_account_data().await.unwrap();
            } else {
                let mut new = channel(None);
                new.seq = Some(11);
                backend.record_chat_update(new, None, None).await.unwrap();
            }
            release.send(()).unwrap();
            task.await.unwrap();
            server.await.unwrap();
            let after = store.dialog(InlineId::new(7)).await.unwrap();
            if clear {
                assert!(after.is_none());
            } else {
                let after = after.unwrap();
                assert_eq!(after.parent_chat_id, None);
                assert_eq!(structure(&after)["kind"], "channel");
            }
        }
    }
}

#[tokio::test]
async fn parity_review_held_error_fallback_cannot_clear_newer_tombstone_or_account() {
    for clear in [false, true] {
        for store in [
            Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
        ] {
            store.record_self_user_id(InlineId::new(2)).await.unwrap();
            let (began_tx, began) = tokio::sync::oneshot::channel();
            let (release, release_rx) = tokio::sync::oneshot::channel();
            let (backend, server) = rpc_fixture_controlled(
                store.clone(),
                vec![(
                    proto::Method::GetSpace,
                    Err((proto::rpc_error::Code::InternalError, 500)),
                )],
                HashSet::new(),
                Some((0, began_tx, release_rx)),
            )
            .await;
            let worker = backend.clone();
            let task = tokio::spawn(async move {
                worker
                    .refresh_discovered_space_access(vec![InlineId::new(5)])
                    .await
            });
            began.await.unwrap();
            if clear {
                store.clear_account_data().await.unwrap();
            } else {
                backend
                    .apply_updates(vec![remove_member(2)], None, None)
                    .await
                    .unwrap();
            }
            release.send(()).unwrap();
            let result = task.await.unwrap();
            if clear {
                assert_eq!(
                    result.unwrap_err().category,
                    ClientErrorCategory::AuthRequired
                );
            } else {
                result.unwrap();
            }
            server.await.unwrap();
            let after = store.account_state().await.unwrap();
            if clear {
                assert!(after.space_access.is_empty());
            } else {
                assert_eq!(
                    after.space_access[0].status,
                    crate::SpaceAccessStatus::Removed
                );
            }
        }
    }
}

#[tokio::test]
async fn parity_review_newer_source_proof_can_restore_removed_access() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        store.record_self_user_id(InlineId::new(2)).await.unwrap();
        let seed = SdkBackend::builder()
            .shared_store(store.clone())
            .build()
            .unwrap();
        let mut removal = remove_member(2);
        removal.seq = Some(10);
        seed.apply_updates_in_bucket(
            vec![removal],
            None,
            None,
            Some(crate::SyncBucketKey::Space {
                space_id: InlineId::new(5),
            }),
        )
        .await
        .unwrap();
        let mut reply = get_space_reply(5).unwrap();
        if let proto::rpc_result::Result::GetSpace(result) = &mut reply {
            result.space.as_mut().unwrap().seq = Some(11);
        }
        let (backend, server) =
            rpc_fixture(store.clone(), vec![(proto::Method::GetSpace, Ok(reply))]).await;
        backend
            .refresh_discovered_space_access(vec![InlineId::new(5)])
            .await
            .unwrap();
        server.await.unwrap();
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Accessible
        );
        let mut old_removal = remove_member(2);
        old_removal.seq = Some(9);
        backend
            .apply_updates_in_bucket(
                vec![old_removal],
                None,
                None,
                Some(crate::SyncBucketKey::Space {
                    space_id: InlineId::new(5),
                }),
            )
            .await
            .unwrap();
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Accessible
        );
        assert_eq!(
            store
                .space_members(InlineId::new(5))
                .await
                .unwrap()
                .iter()
                .map(|m| m.user_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(2)]
        );
    }
}

#[tokio::test]
async fn parity_review_persisted_older_journal_cannot_overwrite_newer_direct_proof() {
    use prost::Message;
    let fixture = FixtureDir::new();
    let path = fixture.0.join("freshness.sqlite");
    {
        let store = crate::SqliteStore::open(&path).unwrap();
        let mut queued_join = join_self();
        queued_join.seq = Some(1);
        queued_join.date = Some(100);
        let mut old_child = channel(Some(5));
        old_child.seq = Some(4);
        old_child.parent_chat_id = Some(3);
        old_child.parent_message_id = Some(9);
        let mut payload = pending_payload(&[queued_join]);
        payload.pop();
        payload.push(1);
        let bytes = proto::UpdateSidecars {
            chats: vec![old_child],
            ..Default::default()
        }
        .encode_to_vec();
        payload.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        payload.extend(bytes);
        store
            .save_pending_sync_batch(crate::PendingSyncBatch {
                key: crate::SyncBucketKey::User,
                committed_state: crate::SyncBucketState { seq: 1, date: 100 },
                payload,
            })
            .await
            .unwrap();
        let mut latest = channel(None);
        latest.seq = Some(10);
        let (backend, server) = rpc_fixture(
            Arc::new(store.clone()),
            vec![
                (
                    proto::Method::GetChats,
                    Ok(proto::rpc_result::Result::GetChats(proto::GetChatsResult {
                        chats: vec![latest],
                        spaces: vec![source_space(5)],
                        ..Default::default()
                    })),
                ),
                (
                    proto::Method::GetSpace,
                    Err((proto::rpc_error::Code::SpaceIdInvalid, 404)),
                ),
            ],
        )
        .await;
        backend.dialogs(DialogsRequest::default()).await.unwrap();
        server.await.unwrap();
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Removed
        );
    }
    {
        let store = crate::SqliteStore::open(&path).unwrap();
        let backend = SdkBackend::builder().store(store.clone()).build().unwrap();
        backend
            .sync
            .process_realtime(&backend, vec![])
            .await
            .unwrap();
        assert!(store.pending_sync_batches().await.unwrap().is_empty());
        assert_eq!(
            store
                .sync_bucket_state(crate::SyncBucketKey::User)
                .await
                .unwrap()
                .seq,
            1
        );
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Removed
        );
        let chat = store.dialog(InlineId::new(7)).await.unwrap().unwrap();
        assert_eq!(
            (chat.space_id, chat.parent_chat_id, chat.parent_message_id),
            (None, None, None)
        );
        assert_eq!(structure(&chat)["kind"], "channel");
        assert_eq!(store.source_version("chat:7".into()).await.unwrap().seq, 10);
    }
}

#[tokio::test]
async fn parity_review_held_user_repair_cannot_repopulate_cleared_account() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let (began_tx, began) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        let replies = vec![
            (
                proto::Method::GetUpdatesState,
                Ok(proto::rpc_result::Result::GetUpdatesState(
                    proto::GetUpdatesStateResult {
                        date: 100,
                        seq: Some(2),
                        ..Default::default()
                    },
                )),
            ),
            (
                proto::Method::GetChats,
                Ok(proto::rpc_result::Result::GetChats(proto::GetChatsResult {
                    chats: vec![channel(None)],
                    ..Default::default()
                })),
            ),
            (
                proto::Method::GetMe,
                Ok(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                    user: Some(proto::User {
                        id: 2,
                        ..Default::default()
                    }),
                })),
            ),
            (
                proto::Method::GetUserSettings,
                Ok(proto::rpc_result::Result::GetUserSettings(
                    proto::GetUserSettingsResult {
                        user_settings: Some(proto::UserSettings::default()),
                    },
                )),
            ),
        ];
        let (backend, server) = rpc_fixture_controlled(
            store.clone(),
            replies,
            HashSet::new(),
            Some((1, began_tx, release_rx)),
        )
        .await;
        let task = tokio::spawn(async move { backend.repair_user_bucket(2).await });
        began.await.unwrap();
        store.clear_account_data().await.unwrap();
        release.send(()).unwrap();
        let result = task.await.unwrap();
        server.await.unwrap();
        assert!(
            result.is_err(),
            "an account change must abort the repair checkpoint"
        );
        assert!(store.dialog(InlineId::new(7)).await.unwrap().is_none());
        let snapshot = store.account_state().await.unwrap();
        assert!(snapshot.users.is_empty());
        assert_eq!(store.self_user_id().await.unwrap(), None);
    }
}

#[tokio::test]
async fn parity_review_held_denial_preserves_newer_join_and_self_membership() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let (began_tx, began) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        let (backend, server) = rpc_fixture_controlled(
            store.clone(),
            vec![(
                proto::Method::GetSpace,
                Err((proto::rpc_error::Code::SpaceIdInvalid, 404)),
            )],
            HashSet::new(),
            Some((0, began_tx, release_rx)),
        )
        .await;
        let worker = backend.clone();
        let task = tokio::spawn(async move {
            worker
                .refresh_discovered_space_access(vec![InlineId::new(5)])
                .await
                .unwrap();
        });
        began.await.unwrap();
        backend
            .apply_updates(vec![join_self()], None, None)
            .await
            .unwrap();
        release.send(()).unwrap();
        task.await.unwrap();
        server.await.unwrap();
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Accessible
        );
        assert_eq!(
            store
                .space_members(InlineId::new(5))
                .await
                .unwrap()
                .iter()
                .map(|m| m.user_id)
                .collect::<Vec<_>>(),
            vec![InlineId::new(2)]
        );
    }
}

#[tokio::test]
async fn parity_review_held_chat_repair_cannot_repopulate_cleared_account() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let (began_tx, began) = tokio::sync::oneshot::channel();
        let (release, release_rx) = tokio::sync::oneshot::channel();
        let mut chat = channel(None);
        chat.seq = Some(2);
        let reply = proto::GetChatResult {
            dialog: Some(proto::Dialog {
                chat_id: Some(7),
                peer: chat.peer_id.clone(),
                ..Default::default()
            }),
            chat: Some(chat),
            ..Default::default()
        };
        let (backend, server) = rpc_fixture_controlled(
            store.clone(),
            vec![(
                proto::Method::GetChat,
                Ok(proto::rpc_result::Result::GetChat(reply)),
            )],
            HashSet::new(),
            Some((0, began_tx, release_rx)),
        )
        .await;
        let task = tokio::spawn(async move {
            backend
                .repair_chat_bucket(
                    crate::SyncBucketPeer::Chat {
                        chat_id: InlineId::new(7),
                    },
                    2,
                )
                .await
        });
        began.await.unwrap();
        store.clear_account_data().await.unwrap();
        release.send(()).unwrap();
        let result = task.await.unwrap();
        server.await.unwrap();
        assert!(result.is_err(), "an account change must abort chat repair");
        assert!(store.dialog(InlineId::new(7)).await.unwrap().is_none());
    }
}

#[hegel::test(test_cases = 1000)]
fn parity_final_user_and_space_sequences_are_independent(tc: TestCase) {
    let user_seq = tc.draw(gs::integers::<i32>().min_value(1));
    let space_seq = tc.draw(gs::integers::<i32>().min_value(0).max_value(i32::MAX - 1));
    runt().block_on(async {
        for store in [
            Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
        ] {
            let member = space_member_record_from_proto(&proto::Member {
                space_id: 5,
                user_id: 2,
                ..Default::default()
            });
            let expected = store.source_version("access:5".into()).await.unwrap();
            assert!(
                store
                    .record_source_space_access(
                        crate::SpaceAccessRecord {
                            space_id: InlineId::new(5),
                            status: crate::SpaceAccessStatus::Accessible
                        },
                        i64::from(space_seq),
                        expected,
                        true,
                        crate::store::SourceSpaceProjection {
                            space: None,
                            self_member: Some(member.clone())
                        }
                    )
                    .await
                    .unwrap()
            );
            let mut removal = remove_member(2);
            removal.seq = Some(user_seq);
            removal.date = Some(100);
            store
                .save_pending_sync_batch(crate::PendingSyncBatch {
                    key: crate::SyncBucketKey::User,
                    committed_state: crate::SyncBucketState {
                        seq: i64::from(user_seq),
                        date: 100,
                    },
                    payload: pending_payload(&[removal]),
                })
                .await
                .unwrap();
            let backend = SdkBackend::builder()
                .shared_store(store.clone())
                .build()
                .unwrap();
            backend
                .sync
                .process_realtime(&backend, vec![])
                .await
                .unwrap();
            assert_eq!(
                store.account_state().await.unwrap().space_access[0].status,
                crate::SpaceAccessStatus::Removed,
                "user_seq={user_seq}, space_seq={space_seq}"
            );
            assert_eq!(
                store.source_version("access:5".into()).await.unwrap().seq,
                i64::from(space_seq),
                "user sequence must not advance a space frontier"
            );
            let expected = store.source_version("access:5".into()).await.unwrap();
            assert!(
                store
                    .record_source_space_access(
                        crate::SpaceAccessRecord {
                            space_id: InlineId::new(5),
                            status: crate::SpaceAccessStatus::Accessible
                        },
                        i64::from(space_seq) + 1,
                        expected,
                        true,
                        crate::store::SourceSpaceProjection {
                            space: None,
                            self_member: Some(member)
                        }
                    )
                    .await
                    .unwrap(),
                "user_seq={user_seq} must not block a fresh space proof"
            );
        }
    });
}

#[tokio::test]
async fn parity_final_fresh_equal_space_proof_reconciles_unsequenced_eviction() {
    for store in [
        Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
        Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
    ] {
        let member = space_member_record_from_proto(&proto::Member {
            space_id: 5,
            user_id: 2,
            ..Default::default()
        });
        let expected = store.source_version("access:5".into()).await.unwrap();
        store
            .record_source_space_access(
                crate::SpaceAccessRecord {
                    space_id: InlineId::new(5),
                    status: crate::SpaceAccessStatus::Accessible,
                },
                11,
                expected,
                true,
                crate::store::SourceSpaceProjection {
                    space: None,
                    self_member: Some(member.clone()),
                },
            )
            .await
            .unwrap();
        let backend = SdkBackend::builder()
            .shared_store(store.clone())
            .build()
            .unwrap();
        backend
            .apply_updates(vec![remove_member(2)], None, None)
            .await
            .unwrap();
        assert_eq!(
            store.account_state().await.unwrap().space_access[0].status,
            crate::SpaceAccessStatus::Removed,
            "real unsequenced evictions still revoke immediately"
        );
        let expected = store.source_version("access:5".into()).await.unwrap();
        assert!(
            store
                .record_source_space_access(
                    crate::SpaceAccessRecord {
                        space_id: InlineId::new(5),
                        status: crate::SpaceAccessStatus::Accessible
                    },
                    11,
                    expected,
                    true,
                    crate::store::SourceSpaceProjection {
                        space: None,
                        self_member: Some(member)
                    }
                )
                .await
                .unwrap(),
            "a fresh RPC at the unchanged space frontier must reconcile an old unsequenced eviction"
        );
        assert_eq!(
            store.space_members(InlineId::new(5)).await.unwrap().len(),
            1
        );
    }
}

#[tokio::test]
async fn parity_final_clear_during_late_space_rpc_aborts_entire_user_repair() {
    for denial in [false, true] {
        for store in [
            Arc::new(InMemoryStore::new()) as Arc<dyn ClientStore>,
            Arc::new(crate::SqliteStore::open_in_memory().unwrap()),
        ] {
            let (began_tx, began) = tokio::sync::oneshot::channel();
            let (release, release_rx) = tokio::sync::oneshot::channel();
            let replies = vec![
                (
                    proto::Method::GetUpdatesState,
                    Ok(proto::rpc_result::Result::GetUpdatesState(
                        proto::GetUpdatesStateResult {
                            date: 100,
                            seq: Some(2),
                            ..Default::default()
                        },
                    )),
                ),
                (
                    proto::Method::GetChats,
                    Ok(proto::rpc_result::Result::GetChats(proto::GetChatsResult {
                        spaces: vec![source_space(5)],
                        ..Default::default()
                    })),
                ),
                (
                    proto::Method::GetMe,
                    Ok(proto::rpc_result::Result::GetMe(proto::GetMeResult {
                        user: Some(proto::User {
                            id: 2,
                            ..Default::default()
                        }),
                    })),
                ),
                (
                    proto::Method::GetUserSettings,
                    Ok(proto::rpc_result::Result::GetUserSettings(
                        proto::GetUserSettingsResult {
                            user_settings: Some(proto::UserSettings::default()),
                        },
                    )),
                ),
                (
                    proto::Method::GetSpace,
                    if denial {
                        Err((proto::rpc_error::Code::SpaceIdInvalid, 404))
                    } else {
                        get_space_reply(5)
                    },
                ),
            ];
            let (backend, server) = rpc_fixture_controlled(
                store.clone(),
                replies,
                HashSet::new(),
                Some((4, began_tx, release_rx)),
            )
            .await;
            let task = tokio::spawn(async move { backend.repair_user_bucket(2).await });
            began.await.unwrap();
            store.clear_account_data().await.unwrap();
            release.send(()).unwrap();
            let result = task.await.unwrap();
            server.await.unwrap();
            assert!(
                result.is_err(),
                "cleared account must abort the entire repair, including checkpoint"
            );
            let snapshot = store.account_state().await.unwrap();
            assert!(snapshot.users.is_empty());
            assert!(snapshot.space_access.is_empty());
            assert!(snapshot.spaces.is_empty());
            assert_eq!(store.self_user_id().await.unwrap(), None);
            assert_eq!(store.user_settings().await.unwrap(), None);
            assert_eq!(
                store
                    .sync_bucket_state(crate::SyncBucketKey::User)
                    .await
                    .unwrap()
                    .seq,
                0
            );
        }
    }
}

#[tokio::test]
async fn parity_final_raw_clear_waits_for_final_writes_and_checkpoint_lease() {
    let fixture = FixtureDir::new();
    let path = fixture.0.join("lifecycle.sqlite");
    let sqlite = crate::SqliteStore::open(&path).unwrap();
    // The raw clearer uses a clone distinct from the repair's store handle.
    for (store, clearer) in [
        {
            let memory = InMemoryStore::new();
            (
                Arc::new(memory.clone()) as Arc<dyn ClientStore>,
                Arc::new(memory) as Arc<dyn ClientStore>,
            )
        },
        (
            Arc::new(sqlite.clone()) as Arc<dyn ClientStore>,
            Arc::new(sqlite) as Arc<dyn ClientStore>,
        ),
    ] {
        let epoch = store.source_version("account".into()).await.unwrap().epoch;
        let guard = store.source_account_guard().await.unwrap();
        let clear = clearer.clear_account_data();
        tokio::pin!(clear);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(10), &mut clear)
                .await
                .is_err()
        );
        store
            .record_users(vec![user_record_from_proto(&proto::User {
                id: 2,
                ..Default::default()
            })])
            .await
            .unwrap();
        let checkpoint = crate::SyncBucketState { seq: 7, date: 100 };
        // Exercise the same atomic outbox/cursor operation used by cold repair.
        store
            .commit_pending_sync_batch_with_events(
                crate::SyncBucketKey::User,
                checkpoint,
                vec![ClientEvent::UserSettingsChanged {}],
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .sync_bucket_state(crate::SyncBucketKey::User)
                .await
                .unwrap(),
            checkpoint
        );
        assert_eq!(store.account_state().await.unwrap().users.len(), 1);
        assert_eq!(
            store.source_version("account".into()).await.unwrap().epoch,
            epoch
        );
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(10), &mut clear)
                .await
                .is_err()
        );
        drop(guard);
        tokio::time::timeout(std::time::Duration::from_secs(1), clear)
            .await
            .unwrap()
            .unwrap();
        assert!(store.account_state().await.unwrap().users.is_empty());
        assert_eq!(
            store
                .sync_bucket_state(crate::SyncBucketKey::User)
                .await
                .unwrap()
                .seq,
            0
        );
        assert!(store.pending_client_events().await.unwrap().is_empty());
        assert_eq!(
            store.source_version("account".into()).await.unwrap().epoch,
            epoch + 1
        );
    }
    let reopened = crate::SqliteStore::open(&path).unwrap();
    assert_eq!(
        reopened
            .sync_bucket_state(crate::SyncBucketKey::User)
            .await
            .unwrap()
            .seq,
        0
    );
    assert!(reopened.account_state().await.unwrap().users.is_empty());
    assert_eq!(
        reopened
            .source_version("account".into())
            .await
            .unwrap()
            .epoch,
        1
    );
}

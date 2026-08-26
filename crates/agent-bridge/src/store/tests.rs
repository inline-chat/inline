use super::*;
use crate::{ApprovalDecision, InputAttachment, InputAttachmentKind, InstallationId, WorkspaceId};

fn binding() -> BindingKey {
    BindingKey {
        installation_id: InstallationId::new("host-1").expect("installation id"),
        chat_id: 42,
        workspace_id: WorkspaceId::new("workspace-1").expect("workspace id"),
    }
}

fn queued(id: &str, created_at: i64) -> QueueRecord {
    QueueRecord {
        queue_id: QueueItemId::new(id).expect("queue id"),
        binding: binding(),
        direction: Direction::new(
            DirectionId::new(format!("direction-{id}")).expect("direction id"),
            format!("work {id}"),
        ),
        state: QueueState::Pending,
        created_at,
        started_at: None,
        lease_expires_at: None,
        attempt_count: 0,
    }
}

fn inbound(id: &str, accepted_at: i64) -> InboundRecord {
    InboundRecord {
        event_id: id.to_string(),
        binding: binding(),
        message_id: 100,
        delivery_chat_id: binding().chat_id,
        sender_user_id: 7,
        direction: Direction::new(
            DirectionId::new(format!("direction-{id}")).expect("direction id"),
            format!("work {id}"),
        ),
        state: InboundState::Accepted,
        accepted_at,
        started_at: None,
        lease_expires_at: None,
        attempt_count: 0,
        provider_turn_id: None,
        stream_message_id: None,
        failure: None,
    }
}

#[test]
fn event_claim_is_idempotent() {
    let store = BridgeStore::open_in_memory().expect("store");
    assert!(store.claim_event("event-1", 10).expect("first claim"));
    assert!(!store.claim_event("event-1", 11).expect("duplicate claim"));
}

#[test]
fn completed_provider_turns_become_snapshot_hydration_dedupe_keys() {
    let store = BridgeStore::open_in_memory().expect("store");
    let record = inbound("event-1", 10);
    let turn_id = TurnId::new("provider-turn-1").expect("turn");
    assert!(store.accept_inbound(&record).expect("accept"));
    assert!(store.start_inbound(&record.event_id, 11).expect("start"));
    assert!(
        store
            .attach_inbound_turn(&record.event_id, &turn_id, Some(55))
            .expect("attach turn")
    );
    assert!(
        store
            .completed_provider_turn_ids(&record.binding)
            .expect("pending turns")
            .is_empty()
    );
    assert!(
        store
            .stage_inbound_final_send(&record.event_id, InboundState::Completed, "done", None,)
            .expect("stage final")
    );
    assert_eq!(
        store
            .ensure_inbound_final_send_random_id(&record.event_id, 777)
            .expect("terminal random id"),
        Some(777)
    );
    assert!(
        store
            .commit_inbound_final_send(&record.event_id)
            .expect("complete")
    );
    assert_eq!(
        store
            .completed_provider_turn_ids(&record.binding)
            .expect("completed turns"),
        std::collections::HashSet::from([turn_id.to_string()])
    );
    assert_eq!(
        store
            .completed_inbound_for_provider_turn_input(
                &turn_id,
                &record.binding,
                &record.direction.text,
            )
            .expect("completed inbound")
            .map(|record| record.event_id),
        Some("event-1".to_string())
    );
    assert!(
        store
            .completed_inbound_for_provider_turn_input(
                &turn_id,
                &record.binding,
                "a different provider item",
            )
            .expect("non-matching input")
            .is_none()
    );

    let mut steer = inbound("event-steer", 12);
    steer.message_id = 101;
    steer.direction.text = "steer the active turn".to_string();
    assert!(store.accept_inbound(&steer).expect("accept steer"));
    assert!(
        store
            .start_inbound(&steer.event_id, 13)
            .expect("start steer")
    );
    assert!(
        store
            .attach_inbound_turn(&steer.event_id, &turn_id, None)
            .expect("attach steer")
    );
    assert!(
        store
            .complete_inbound(&steer.event_id)
            .expect("complete steer")
    );
    assert_eq!(
        store
            .completed_terminal_random_id_for_provider_turn(&turn_id, &record.binding)
            .expect("stored final identity"),
        Some(777)
    );
}

#[test]
fn ambiguous_legacy_turn_identity_fails_closed() {
    let store = BridgeStore::open_in_memory().expect("store");
    let turn_id = TurnId::new("provider-turn-ambiguous").expect("turn");
    for (index, random_id) in [(0_i64, 701_i64), (1, 702)] {
        let mut record = inbound(&format!("event-ambiguous-{index}"), 10 + index);
        record.message_id = 100 + index;
        record.direction.text = "same historical prompt".to_string();
        assert!(store.accept_inbound(&record).expect("accept"));
        assert!(
            store
                .start_inbound(&record.event_id, 20 + index)
                .expect("start")
        );
        assert!(
            store
                .attach_inbound_turn(&record.event_id, &turn_id, None)
                .expect("attach turn")
        );
        assert!(
            store
                .stage_inbound_final_send(&record.event_id, InboundState::Completed, "done", None,)
                .expect("stage final")
        );
        assert_eq!(
            store
                .ensure_inbound_final_send_random_id(&record.event_id, random_id)
                .expect("terminal random id"),
            Some(random_id)
        );
        assert!(
            store
                .commit_inbound_final_send(&record.event_id)
                .expect("commit final")
        );
    }

    assert!(
        store
            .completed_inbound_for_provider_turn_input(
                &turn_id,
                &binding(),
                "same historical prompt",
            )
            .expect("ambiguous user identity")
            .is_none()
    );
    assert!(matches!(
        store.completed_terminal_random_id_for_provider_turn(&turn_id, &binding()),
        Err(StoreError::AmbiguousInboundTerminalIdentity)
    ));
}

#[test]
fn provider_echo_suppression_requires_the_exact_local_binding() {
    let store = BridgeStore::open_in_memory().expect("store");
    let record = inbound("event-echo", 10);
    let direction_id = record.direction.id.clone();
    assert!(store.accept_inbound(&record).expect("accept"));
    assert!(
        store
            .inbound_direction_belongs_to_binding(&record.binding, &direction_id)
            .expect("local direction")
    );

    let mut foreign_binding = record.binding.clone();
    foreign_binding.chat_id += 1;
    assert!(
        !store
            .inbound_direction_belongs_to_binding(&foreign_binding, &direction_id)
            .expect("foreign direction")
    );
    assert!(
        !store
            .inbound_direction_belongs_to_binding(
                &record.binding,
                &DirectionId::new("direction-missing").expect("missing direction"),
            )
            .expect("missing direction")
    );
}

#[test]
fn binding_round_trips() {
    let store = BridgeStore::open_in_memory().expect("store");
    let provider = ProviderId::new("codex").expect("provider id");
    let session = ProviderSessionId::new("thread-1").expect("session id");
    store
        .put_binding(&binding(), &provider, &session, 10)
        .expect("put binding");
    assert_eq!(
        store.get_binding(&binding()).expect("get binding"),
        Some((provider, session))
    );
}

#[test]
fn inbound_acceptance_is_atomic_and_idempotent() {
    let store = BridgeStore::open_in_memory().expect("store");
    let record = inbound("event-1", 10);
    assert!(store.accept_inbound(&record).expect("first accept"));
    assert!(!store.accept_inbound(&record).expect("duplicate accept"));
    assert!(!store.claim_event("event-1", 11).expect("already processed"));
}

#[test]
fn inbound_and_queue_preserve_attachment_descriptors() {
    let store = BridgeStore::open_in_memory().expect("store");
    let attachment = InputAttachment {
        kind: InputAttachmentKind::Image,
        uri: "https://cdn.inline.chat/photo.jpg".to_string(),
        local_uri: None,
        mime_type: Some("image/jpeg".to_string()),
        file_name: Some("photo.jpg".to_string()),
        size_bytes: Some(42),
        width: Some(10),
        height: Some(20),
        duration_ms: None,
    };
    let mut record = inbound("event-media", 10);
    record.direction.attachments.push(attachment.clone());
    assert!(store.accept_inbound(&record).expect("accept media"));
    assert_eq!(
        store
            .get_inbound("event-media")
            .expect("read media")
            .expect("stored media")
            .direction
            .attachments,
        std::slice::from_ref(&attachment)
    );

    let mut queued = queued("queue-media", 11);
    queued.direction.attachments.push(attachment.clone());
    store.enqueue(&queued).expect("enqueue media");
    assert_eq!(
        store
            .take_next_queue(&binding(), 12)
            .expect("claim media queue")
            .expect("queued media")
            .direction
            .attachments,
        [attachment]
    );
}

#[test]
fn accepted_inbound_monotonically_gains_late_attachments() {
    let store = BridgeStore::open_in_memory().expect("store");
    let record = inbound("event-media-late", 10);
    assert!(store.accept_inbound(&record).expect("accept without media"));

    let attachment = InputAttachment {
        kind: InputAttachmentKind::File,
        uri: "https://cdn.inline.chat/report.pdf".to_string(),
        local_uri: None,
        mime_type: Some("application/pdf".to_string()),
        file_name: Some("report.pdf".to_string()),
        size_bytes: Some(42),
        width: None,
        height: None,
        duration_ms: None,
    };
    let mut hydrated = record.clone();
    hydrated.direction.attachments.push(attachment.clone());
    assert!(
        store
            .enrich_accepted_inbound_attachments(&hydrated)
            .expect("enrich accepted media")
    );
    assert_eq!(
        store
            .get_inbound(&record.event_id)
            .expect("read enriched media")
            .expect("stored media")
            .direction
            .attachments,
        [attachment]
    );
    assert!(
        !store
            .enrich_accepted_inbound_attachments(&hydrated)
            .expect("do not overwrite media")
    );
}

#[test]
fn started_inbound_rejects_late_attachment_enrichment() {
    let store = BridgeStore::open_in_memory().expect("store");
    let record = inbound("event-media-started", 10);
    assert!(store.accept_inbound(&record).expect("accept without media"));
    store
        .take_next_inbound(&record.binding, 20)
        .expect("claim")
        .expect("started inbound");

    let mut hydrated = record;
    hydrated.direction.attachments.push(InputAttachment {
        kind: InputAttachmentKind::File,
        uri: "https://cdn.inline.chat/report.pdf".to_string(),
        local_uri: None,
        mime_type: Some("application/pdf".to_string()),
        file_name: Some("report.pdf".to_string()),
        size_bytes: Some(42),
        width: None,
        height: None,
        duration_ms: None,
    });
    assert!(
        !store
            .enrich_accepted_inbound_attachments(&hydrated)
            .expect("started work is immutable")
    );
}

#[test]
fn a_claimed_control_event_cannot_be_replayed_as_inbound_work() {
    let store = BridgeStore::open_in_memory().expect("store");
    let record = inbound("event-stop", 10);

    assert!(store.claim_event("event-stop", 10).expect("control claim"));
    assert!(!store.accept_inbound(&record).expect("replayed accept"));
    assert!(store.get_inbound("event-stop").expect("lookup").is_none());
}

#[test]
fn inbound_acceptance_deduplicates_stable_message_identity() {
    let store = BridgeStore::open_in_memory().expect("store");
    let first = inbound("delivery-1", 10);
    let mut replay = first.clone();
    replay.event_id = "delivery-2".to_string();
    replay.direction.id = DirectionId::new("delivery-2").expect("direction id");

    assert!(store.accept_inbound(&first).expect("first accept"));
    assert!(!store.accept_inbound(&replay).expect("replayed accept"));
    assert!(store.get_inbound("delivery-2").expect("lookup").is_none());
}

#[test]
fn equal_timestamp_directions_keep_durable_ingest_order() {
    let store = BridgeStore::open_in_memory().expect("store");
    let first = inbound("event-z", 10);
    let mut second = inbound("event-a", 10);
    second.message_id = 101;
    second.direction.id = DirectionId::new("event-a").expect("direction id");
    store.accept_inbound(&first).expect("first accept");
    store.accept_inbound(&second).expect("second accept");

    let claimed = store
        .take_next_inbound(&binding(), 20)
        .expect("claim")
        .expect("first direction");
    assert_eq!(claimed.event_id, "event-z");
    store.complete_inbound(&claimed.event_id).expect("complete");
    let claimed = store
        .take_next_inbound(&binding(), 21)
        .expect("claim")
        .expect("second direction");
    assert_eq!(claimed.event_id, "event-a");
}

#[test]
fn inbound_lease_recovers_crash_before_terminal_commit() {
    let store = BridgeStore::open_in_memory().expect("store");
    store
        .accept_inbound(&inbound("event-1", 10))
        .expect("accept");
    let first = store
        .take_next_inbound(&binding(), 20)
        .expect("take")
        .expect("inbound item");
    assert_eq!(first.state, InboundState::Started);
    assert_eq!(first.attempt_count, 1);
    let turn_id = TurnId::new("turn-1").expect("turn id");
    assert!(
        store
            .attach_inbound_turn(&first.event_id, &turn_id, Some(55))
            .expect("attach turn")
    );
    let attached = store
        .get_inbound(&first.event_id)
        .expect("load")
        .expect("inbound item");
    assert_eq!(attached.provider_turn_id, Some(turn_id));
    assert_eq!(attached.stream_message_id, Some(55));
    assert!(
        store
            .attach_inbound_stream_message(&first.event_id, 56)
            .expect("replace stream message")
    );
    assert_eq!(
        store
            .get_inbound(&first.event_id)
            .expect("reload")
            .expect("inbound item")
            .stream_message_id,
        Some(56)
    );
    assert!(
        store
            .renew_inbound_lease(&first.event_id, 100)
            .expect("renew")
    );
    assert_eq!(store.recover_expired_inbound(399).expect("not expired"), 0);
    assert_eq!(store.recover_expired_inbound(400).expect("recover"), 1);

    let second = store
        .take_next_inbound(&binding(), 500)
        .expect("retake")
        .expect("inbound item");
    assert_eq!(second.event_id, first.event_id);
    assert_eq!(second.attempt_count, 2);
    assert!(store.complete_inbound(&second.event_id).expect("complete"));
    assert!(
        !store
            .complete_inbound(&second.event_id)
            .expect("complete twice")
    );
}

#[test]
fn delivery_chat_is_promoted_only_before_provider_or_stream_attachment() {
    let store = BridgeStore::open_in_memory().expect("store");
    store
        .accept_inbound(&inbound("event-delivery", 10))
        .expect("accept");
    let started = store
        .take_next_inbound(&binding(), 20)
        .expect("take")
        .expect("started");
    assert_eq!(started.delivery_chat_id, binding().chat_id);
    assert!(
        store
            .set_inbound_delivery_chat(&started.event_id, 99)
            .expect("promote")
    );
    assert_eq!(
        store
            .get_inbound(&started.event_id)
            .expect("read")
            .expect("record")
            .delivery_chat_id,
        99
    );
    store
        .attach_inbound_stream_message(&started.event_id, 55)
        .expect("stream");
    assert!(
        !store
            .set_inbound_delivery_chat(&started.event_id, 100)
            .expect("late promotion rejected")
    );
    assert!(
        store
            .stage_inbound_final_send(&started.event_id, InboundState::Completed, "done", None,)
            .expect("stage final")
    );
    let pending = store
        .pending_inbound_final_sends(&binding().installation_id)
        .expect("pending finals");
    assert_eq!(pending[0].delivery_chat_id, 99);
}

#[test]
fn known_inbound_can_be_claimed_for_live_steering_once() {
    let store = BridgeStore::open_in_memory().expect("store");
    store
        .accept_inbound(&inbound("event-steer", 10))
        .expect("accept");
    assert!(store.start_inbound("event-steer", 20).expect("start steer"));
    assert!(!store.start_inbound("event-steer", 21).expect("start twice"));
    assert!(store.defer_inbound("event-steer").expect("defer"));
    assert!(
        store
            .start_inbound("event-steer", 22)
            .expect("start after defer")
    );
    assert!(
        store
            .complete_inbound("event-steer")
            .expect("complete steer")
    );
}

#[test]
fn failed_inbound_is_terminal() {
    let store = BridgeStore::open_in_memory().expect("store");
    store
        .accept_inbound(&inbound("event-1", 10))
        .expect("accept");
    let record = store
        .take_next_inbound(&binding(), 20)
        .expect("take")
        .expect("inbound item");
    assert!(
        store
            .fail_inbound(&record.event_id, "redacted")
            .expect("fail")
    );
    assert_eq!(
        store.take_next_inbound(&binding(), 30).expect("terminal"),
        None
    );
}

#[test]
fn restart_interrupts_started_inbound_instead_of_replaying_it() {
    let store = BridgeStore::open_in_memory().expect("store");
    store
        .accept_inbound(&inbound("event-1", 10))
        .expect("accept");
    let record = store
        .take_next_inbound(&binding(), 20)
        .expect("take")
        .expect("inbound item");
    store
        .attach_inbound_turn(
            &record.event_id,
            &TurnId::new("turn-1").expect("turn id"),
            Some(55),
        )
        .expect("attach");

    let interrupted = store
        .interrupt_started_inbound(&binding(), "bridge restarted")
        .expect("interrupt");
    assert_eq!(
        interrupted,
        vec![InterruptedInbound {
            event_id: "event-1".to_string(),
            binding: binding(),
            message_id: 100,
            delivery_chat_id: binding().chat_id,
            stream_message_id: Some(55),
        }]
    );
    let stored = store.get_inbound("event-1").expect("load").expect("record");
    assert_eq!(stored.state, InboundState::Failed);
    assert_eq!(stored.failure.as_deref(), Some("bridge restarted"));
    assert_eq!(
        store.take_next_inbound(&binding(), 30).expect("queue"),
        None
    );
}

#[test]
fn durable_crash_boundary_preserves_ack_dedupe_and_recovery_handles() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let path = directory.path().join("bridge.sqlite");
    let turn_id = TurnId::new("turn-crash").expect("turn id");
    let approval = PendingApproval {
        callback_token: "approval-crash".to_string(),
        installation_id: binding().installation_id.clone(),
        provider_id: ProviderId::new("codex").expect("provider id"),
        provider_approval_id: "provider-approval-crash".to_string(),
        turn_id: turn_id.clone(),
        origin_chat_id: binding().chat_id,
        action_chat_id: 84,
        message_id: None,
        origin_status_message_id: None,
        decisions: vec![ApprovalDecision::ApproveOnce, ApprovalDecision::Reject],
        created_at: 100,
        expires_at: 200,
    };

    {
        let store = BridgeStore::open(&path).expect("initial store");
        let record = inbound("event-crash", 10);
        assert!(store.accept_inbound(&record).expect("accept before ack"));
        assert!(
            !store
                .accept_inbound(&record)
                .expect("redelivery after ack crash")
        );
        let started = store
            .take_next_inbound(&binding(), 20)
            .expect("claim")
            .expect("started record");
        assert!(
            store
                .attach_inbound_turn(&started.event_id, &turn_id, Some(55))
                .expect("attach recovery handles")
        );
        assert!(store.insert_approval(&approval).expect("insert approval"));
        assert!(
            store
                .attach_approval_message(&approval.callback_token, 56)
                .expect("attach private approval")
        );
        assert!(
            store
                .attach_approval_origin_status_message(&approval.callback_token, 57)
                .expect("attach origin approval status")
        );
        assert!(matches!(
            store
                .claim_approval(
                    &approval.callback_token,
                    0,
                    &ApprovalClaimContext {
                        installation_id: binding().installation_id,
                        turn_id: turn_id.clone(),
                        origin_chat_id: binding().chat_id,
                        action_chat_id: approval.action_chat_id,
                        actor_user_id: 7,
                        allowed_actor_user_id: 7,
                        now: 150,
                    },
                )
                .expect("claim approval before crash"),
            ApprovalClaimOutcome::Claimed(_)
        ));
    }

    let store = BridgeStore::open(&path).expect("reopened store");
    assert!(
        !store
            .accept_inbound(&inbound("event-crash", 10))
            .expect("redelivery after restart")
    );
    let interrupted_approvals = store
        .invalidate_open_approvals(160)
        .expect("invalidate approvals");
    assert_eq!(interrupted_approvals.len(), 1);
    assert_eq!(interrupted_approvals[0].message_id, Some(56));
    assert_eq!(interrupted_approvals[0].origin_status_message_id, Some(57));
    assert_eq!(interrupted_approvals[0].state, ApprovalState::Resolving);

    let interrupted_turns = store
        .interrupt_started_inbound(&binding(), "bridge restarted")
        .expect("interrupt started turn");
    assert_eq!(interrupted_turns.len(), 1);
    assert_eq!(interrupted_turns[0].stream_message_id, Some(55));
    assert_eq!(
        store
            .get_inbound("event-crash")
            .expect("load interrupted turn")
            .expect("interrupted turn")
            .state,
        InboundState::Failed
    );
    assert!(
        store
            .take_next_inbound(&binding(), 170)
            .expect("no unsafe replay")
            .is_none()
    );
    assert!(
        !store
            .complete_inbound("event-crash")
            .expect("late final commit loses")
    );
}

#[test]
fn queue_is_taken_in_order_once() {
    let store = BridgeStore::open_in_memory().expect("store");
    store.enqueue(&queued("q2", 20)).expect("enqueue q2");
    store.enqueue(&queued("q1", 10)).expect("enqueue q1");
    let first = store
        .take_next_queue(&binding(), 30)
        .expect("take first")
        .expect("first queue item");
    assert_eq!(first.queue_id.as_str(), "q1");
    let second = store
        .take_next_queue(&binding(), 31)
        .expect("take second")
        .expect("second queue item");
    assert_eq!(second.queue_id.as_str(), "q2");
    assert_eq!(
        store.take_next_queue(&binding(), 32).expect("empty queue"),
        None
    );
}

#[test]
fn undo_only_removes_pending_item() {
    let store = BridgeStore::open_in_memory().expect("store");
    let record = queued("q1", 10);
    store.enqueue(&record).expect("enqueue");
    assert!(store.undo_queue(&record.queue_id).expect("undo pending"));
    assert!(!store.undo_queue(&record.queue_id).expect("undo twice"));
    assert_eq!(
        store.take_next_queue(&binding(), 20).expect("empty queue"),
        None
    );
}

#[test]
fn queue_state_parser_rejects_unknown_value() {
    assert!(matches!(
        QueueState::parse("future".to_string()),
        Err(StoreError::UnknownQueueState(_))
    ));
}

#[test]
fn expired_started_queue_is_recovered_and_attempted_again() {
    let store = BridgeStore::open_in_memory().expect("store");
    store.enqueue(&queued("q1", 10)).expect("enqueue");
    let first = store
        .take_next_queue(&binding(), 20)
        .expect("take")
        .expect("queue item");
    assert_eq!(first.attempt_count, 1);
    assert_eq!(store.recover_expired_queue(319).expect("not expired"), 0);
    assert_eq!(store.recover_expired_queue(320).expect("recover"), 1);
    let second = store
        .take_next_queue(&binding(), 400)
        .expect("retake")
        .expect("queue item");
    assert_eq!(second.queue_id, first.queue_id);
    assert_eq!(second.attempt_count, 2);
    assert!(store.complete_queue(&second.queue_id).expect("complete"));
    assert!(
        !store
            .complete_queue(&second.queue_id)
            .expect("complete twice")
    );
}

#[test]
fn migration_records_schema_version() {
    let connection = Connection::open_in_memory().expect("connection");
    migrate(&connection).expect("migrate");
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
}

#[test]
fn on_disk_migration_preserves_a_private_pre_upgrade_backup() {
    let directory = tempfile::tempdir().expect("directory");
    let database = directory.path().join("bridge.sqlite");
    let connection = Connection::open(&database).expect("connection");
    migrate(&connection).expect("initial migration");
    connection
        .execute_batch("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;")
        .expect("wal mode");
    connection
        .execute_batch(
            "BEGIN IMMEDIATE;
             DROP TABLE session_thread_openings;
             DROP TABLE session_thread_bindings;
             INSERT INTO processed_events (event_id, accepted_at)
                 VALUES ('before-upgrade', 7);
             PRAGMA user_version = 23;
             COMMIT;",
        )
        .expect("simulate shipped schema");
    assert!(
        fs::metadata(database.with_extension("sqlite-wal"))
            .expect("uncheckpointed WAL")
            .len()
            > 32
    );

    let store = BridgeStore::open(&database).expect("migrated store");
    assert!(
        store
            .event_processed("before-upgrade")
            .expect("migrated state")
    );
    drop(store);

    let backup = directory
        .path()
        .join("bridge.sqlite.pre-schema-25-from-23.backup");
    let backup_connection = Connection::open_with_flags(&backup, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .expect("migration backup");
    let version: i64 = backup_connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("backup schema");
    let event: String = backup_connection
        .query_row(
            "SELECT event_id FROM processed_events WHERE event_id = 'before-upgrade'",
            [],
            |row| row.get(0),
        )
        .expect("backup contents");
    assert_eq!(version, 23);
    assert_eq!(event, "before-upgrade");
    let quick_check: String = backup_connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
        .expect("backup integrity");
    assert_eq!(quick_check, "ok");
    drop(backup_connection);

    let original_backup = fs::read(&backup).expect("original backup");
    drop(BridgeStore::open(&database).expect("reopen migrated store"));
    assert_eq!(
        fs::read(&backup).expect("preserved backup"),
        original_backup
    );
    drop(connection);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&backup)
                .expect("backup metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

#[test]
fn version_ten_database_adds_durable_questions_forward() {
    let connection = Connection::open_in_memory().expect("connection");
    migrate(&connection).expect("initial migration");
    connection
        .execute_batch(
            "DROP TABLE question_requests;
             DROP TABLE operator_allowlist_requests;
             DROP TABLE host_tool_calls;
             DROP TABLE inbound_progress_messages;
             DROP TABLE inbound_progress;
             DROP TABLE unauthorized_dm_notices;
             DROP TABLE command_choice_requests;
             DROP TABLE reply_thread_overrides;
             DROP TABLE history_import_threads;
             DROP TABLE session_thread_openings;
             DROP TABLE session_thread_bindings;
             ALTER TABLE inbound_directions DROP COLUMN terminal_output_attachments_json;
             ALTER TABLE inbound_directions DROP COLUMN delivery_chat_id;
             ALTER TABLE session_bindings DROP COLUMN session_configuration_fingerprint;
             ALTER TABLE workspaces DROP COLUMN filesystem_device_id;
             ALTER TABLE workspaces DROP COLUMN filesystem_file_id;
             PRAGMA user_version = 10;",
        )
        .expect("simulate version ten");

    migrate(&connection).expect("forward migration");

    let table: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'question_requests'",
            [],
            |row| row.get(0),
        )
        .expect("question table");
    assert_eq!(table, 1);
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
}

#[test]
fn newer_schema_version_is_rejected() {
    let connection = Connection::open_in_memory().expect("connection");
    connection
        .execute_batch("PRAGMA user_version = 26;")
        .expect("set schema version");
    assert!(matches!(
        migrate(&connection),
        Err(StoreError::UnsupportedSchemaVersion {
            found: 26,
            supported: CURRENT_SCHEMA_VERSION
        })
    ));
}

#[test]
fn version_twenty_two_database_adds_history_import_guards_forward() {
    let connection = Connection::open_in_memory().expect("connection");
    migrate(&connection).expect("initial migration");
    connection
        .execute_batch(
            "DROP TABLE session_thread_openings;
             DROP TABLE session_thread_bindings;
             DROP TABLE history_import_threads;
             PRAGMA user_version = 22;",
        )
        .expect("simulate version twenty two");

    migrate(&connection).expect("forward migration");

    let table: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'history_import_threads'",
            [],
            |row| row.get(0),
        )
        .expect("history import table");
    assert_eq!(table, 1);
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
}

#[test]
fn version_twenty_three_database_adds_session_thread_bindings_forward() {
    let connection = Connection::open_in_memory().expect("connection");
    migrate(&connection).expect("initial migration");
    connection
        .execute_batch(
            "DROP TABLE session_thread_openings;
             DROP TABLE session_thread_bindings;
             PRAGMA user_version = 23;",
        )
        .expect("simulate version twenty three");

    migrate(&connection).expect("forward migration");

    let table: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'session_thread_bindings'",
            [],
            |row| row.get(0),
        )
        .expect("session thread table");
    assert_eq!(table, 1);
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
}

#[test]
fn version_twenty_four_database_adds_session_thread_openings_forward() {
    let connection = Connection::open_in_memory().expect("connection");
    migrate(&connection).expect("initial migration");
    connection
        .execute_batch(
            "DROP TABLE session_thread_openings;
             PRAGMA user_version = 24;",
        )
        .expect("simulate version twenty four");

    migrate(&connection).expect("forward migration");

    let table: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'session_thread_openings'",
            [],
            |row| row.get(0),
        )
        .expect("session thread opening table");
    assert_eq!(table, 1);
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
}

#[test]
fn version_one_database_is_migrated_forward() {
    let connection = Connection::open_in_memory().expect("connection");
    connection
        .execute_batch(
            "CREATE TABLE processed_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                accepted_at INTEGER NOT NULL
             );
             CREATE TABLE session_bindings (
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                provider_session_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (installation_id, chat_id, workspace_id)
             );
             CREATE TABLE queue_items (
                queue_id TEXT PRIMARY KEY NOT NULL,
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                direction_id TEXT NOT NULL,
                direction_text TEXT NOT NULL,
                state TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                started_at INTEGER,
                lease_expires_at INTEGER,
                attempt_count INTEGER NOT NULL DEFAULT 0
             );
             PRAGMA user_version = 1;",
        )
        .expect("v1 schema");

    migrate(&connection).expect("migrate v1");
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
    let inbound_table: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'inbound_directions'",
            [],
            |row| row.get(0),
        )
        .expect("inbound table");
    assert_eq!(inbound_table, 1);
}

#[test]
fn version_two_database_is_migrated_forward() {
    let connection = Connection::open_in_memory().expect("connection");
    connection
        .execute_batch(
            "CREATE TABLE inbound_directions (
                event_id TEXT PRIMARY KEY NOT NULL,
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                message_id INTEGER NOT NULL,
                sender_user_id INTEGER NOT NULL,
                direction_id TEXT NOT NULL,
                direction_text TEXT NOT NULL,
                state TEXT NOT NULL,
                accepted_at INTEGER NOT NULL,
                started_at INTEGER,
                lease_expires_at INTEGER,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                provider_turn_id TEXT,
                stream_message_id INTEGER,
                failure TEXT
             );
             CREATE TABLE session_bindings (
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                provider_session_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (installation_id, chat_id, workspace_id)
             );
             PRAGMA user_version = 2;",
        )
        .expect("v2 schema");

    migrate(&connection).expect("migrate v2");
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
    let approval_table: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'approval_requests'",
            [],
            |row| row.get(0),
        )
        .expect("approval table");
    assert_eq!(approval_table, 1);
}

#[test]
fn version_four_workspace_database_is_migrated_forward() {
    let connection = Connection::open_in_memory().expect("connection");
    connection
        .execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE installations (
                installation_id TEXT PRIMARY KEY NOT NULL,
                provider_id TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
             );
             CREATE TABLE workspaces (
                installation_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                path TEXT NOT NULL,
                display_name TEXT NOT NULL,
                parent_hint TEXT,
                last_selected_at INTEGER NOT NULL,
                selection_order INTEGER NOT NULL,
                missing_since INTEGER,
                PRIMARY KEY (installation_id, workspace_id),
                UNIQUE (installation_id, path),
                FOREIGN KEY (installation_id) REFERENCES installations(installation_id)
                    ON DELETE RESTRICT
             );
             CREATE TABLE chat_workspaces (
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (installation_id, chat_id),
                FOREIGN KEY (installation_id, workspace_id)
                    REFERENCES workspaces(installation_id, workspace_id)
                    ON DELETE RESTRICT
             );
             CREATE TABLE session_bindings (
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                provider_session_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (installation_id, chat_id, workspace_id)
             );
             CREATE TABLE inbound_directions (
                event_id TEXT PRIMARY KEY NOT NULL,
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                message_id INTEGER NOT NULL,
                sender_user_id INTEGER NOT NULL,
                direction_id TEXT NOT NULL,
                direction_text TEXT NOT NULL,
                state TEXT NOT NULL,
                accepted_at INTEGER NOT NULL,
                started_at INTEGER,
                lease_expires_at INTEGER,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                provider_turn_id TEXT,
                stream_message_id INTEGER,
                failure TEXT
             );
             CREATE TABLE approval_requests (
                callback_token TEXT PRIMARY KEY NOT NULL,
                installation_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                provider_approval_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                message_id INTEGER,
                decisions_json TEXT NOT NULL,
                state TEXT NOT NULL,
                selected_option INTEGER,
                resolved_by_user_id INTEGER,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                resolved_at INTEGER,
                UNIQUE (installation_id, provider_id, turn_id, provider_approval_id)
             );
             PRAGMA user_version = 4;",
        )
        .expect("v4 schema");

    migrate(&connection).expect("migrate v4");
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .expect("schema version");
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
    for table in ["installation_settings_defaults", "chat_settings"] {
        let count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |row| row.get(0),
            )
            .expect("settings table");
        assert_eq!(count, 1, "missing {table}");
    }
}

#[test]
fn version_six_approval_action_chat_is_backfilled_to_origin() {
    let connection = Connection::open_in_memory().expect("connection");
    connection
        .execute_batch(
            "CREATE TABLE inbound_directions (
                event_id TEXT PRIMARY KEY NOT NULL,
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                message_id INTEGER NOT NULL,
                sender_user_id INTEGER NOT NULL,
                direction_id TEXT NOT NULL,
                direction_text TEXT NOT NULL,
                state TEXT NOT NULL,
                accepted_at INTEGER NOT NULL,
                started_at INTEGER,
                lease_expires_at INTEGER,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                provider_turn_id TEXT,
                stream_message_id INTEGER,
                failure TEXT,
                ingest_order INTEGER
             );
             CREATE TABLE session_bindings (
                installation_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                provider_session_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (installation_id, chat_id, workspace_id)
             );
             CREATE TABLE approval_requests (
                callback_token TEXT PRIMARY KEY NOT NULL,
                installation_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                provider_approval_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                chat_id INTEGER NOT NULL,
                message_id INTEGER,
                decisions_json TEXT NOT NULL,
                state TEXT NOT NULL,
                selected_option INTEGER,
                resolved_by_user_id INTEGER,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                resolved_at INTEGER
             );
             CREATE TABLE workspaces (
                installation_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                path TEXT NOT NULL,
                display_name TEXT NOT NULL,
                parent_hint TEXT,
                last_selected_at INTEGER NOT NULL,
                selection_order INTEGER NOT NULL,
                missing_since INTEGER,
                PRIMARY KEY (installation_id, workspace_id),
                UNIQUE (installation_id, path)
             );
             INSERT INTO approval_requests (
                callback_token, installation_id, provider_id,
                provider_approval_id, turn_id, chat_id, message_id,
                decisions_json, state, selected_option,
                resolved_by_user_id, created_at, expires_at, resolved_at
             ) VALUES (
                'legacy', 'codex-install', 'codex', 'provider-legacy',
                'turn-legacy', 42, 9, '[\"reject\"]', 'pending',
                NULL, NULL, 100, 200, NULL
             );
             PRAGMA user_version = 6;",
        )
        .expect("v6 schema");

    migrate(&connection).expect("migrate v6");
    let store = BridgeStore {
        connection: Mutex::new(connection),
    };
    let record = store
        .get_approval("legacy")
        .expect("read")
        .expect("legacy approval");
    assert_eq!(record.origin_chat_id, 42);
    assert_eq!(record.action_chat_id, 42);
    assert_eq!(record.message_id, Some(9));
    assert_eq!(record.origin_status_message_id, None);
}

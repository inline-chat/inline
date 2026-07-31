//! Durable handoff between provider completion and an idempotent final message send.

use rusqlite::{Connection, params};

use super::*;
use crate::{InstallationId, OutputAttachment};

const MAX_FINAL_TEXT_BYTES: usize = 128 * 1024;
const MAX_OUTPUT_ATTACHMENTS: usize = 8;
const MAX_OUTPUT_ATTACHMENTS_JSON_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingFinalSend {
    pub event_id: String,
    pub binding: BindingKey,
    pub message_id: i64,
    pub delivery_chat_id: i64,
    pub stream_message_id: Option<i64>,
    pub terminal_random_id: Option<i64>,
    pub state: InboundState,
    pub final_text: String,
    pub output_attachments: Vec<OutputAttachment>,
    pub failure: Option<String>,
}

impl BridgeStore {
    /// Durably records a terminal result before attempting its final Inline
    /// send. Repeating the same stage operation is harmless.
    pub fn stage_inbound_final_send(
        &self,
        event_id: &str,
        state: InboundState,
        final_text: &str,
        failure: Option<&str>,
    ) -> StoreResult<bool> {
        self.stage_inbound_final_send_with_attachments(event_id, state, final_text, &[], failure)
    }

    /// Durably records a terminal result and its bounded provider-generated
    /// artifacts before attempting Inline delivery.
    pub fn stage_inbound_final_send_with_attachments(
        &self,
        event_id: &str,
        state: InboundState,
        final_text: &str,
        output_attachments: &[OutputAttachment],
        failure: Option<&str>,
    ) -> StoreResult<bool> {
        if !matches!(state, InboundState::Completed | InboundState::Failed) {
            return Err(StoreError::InvalidInboundFinalState(
                state.as_str().to_string(),
            ));
        }
        if final_text.is_empty() || final_text.len() > MAX_FINAL_TEXT_BYTES {
            return Err(StoreError::InvalidInboundFinalText);
        }
        if output_attachments.len() > MAX_OUTPUT_ATTACHMENTS {
            return Err(StoreError::InvalidInboundOutputAttachments);
        }
        let output_attachments_json = serde_json::to_string(output_attachments)?;
        if output_attachments_json.len() > MAX_OUTPUT_ATTACHMENTS_JSON_BYTES {
            return Err(StoreError::InvalidInboundOutputAttachments);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                terminal_state = ?2, terminal_text = ?3,
                terminal_output_attachments_json = ?4, terminal_failure = ?5
             WHERE event_id = ?1 AND state = 'started'
               AND (
                    terminal_state IS NULL OR
                    (terminal_state = ?2 AND terminal_text = ?3
                     AND terminal_output_attachments_json = ?4
                     AND terminal_failure IS ?5)
               )",
            params![
                event_id,
                state.as_str(),
                final_text,
                output_attachments_json,
                failure
            ],
        )?;
        Ok(changed == 1)
    }

    /// Lists terminal results whose provider work finished but whose final
    /// Inline message has not yet been durably acknowledged by the bridge.
    pub fn pending_inbound_final_sends(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Vec<PendingFinalSend>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let mut statement = connection.prepare(
            "SELECT event_id, chat_id, workspace_id, message_id, delivery_chat_id,
                    stream_message_id, terminal_random_id, terminal_state, terminal_text,
                    terminal_output_attachments_json, terminal_failure
             FROM inbound_directions
             WHERE installation_id = ?1 AND state = 'started'
               AND terminal_state IS NOT NULL
             ORDER BY ingest_order ASC",
        )?;
        statement
            .query_map(params![installation_id.as_str()], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, String>(9)?,
                    row.get::<_, Option<String>>(10)?,
                ))
            })?
            .map(|row| {
                let (
                    event_id,
                    chat_id,
                    workspace_id,
                    message_id,
                    delivery_chat_id,
                    stream_message_id,
                    terminal_random_id,
                    state,
                    final_text,
                    output_attachments_json,
                    failure,
                ) = row?;
                Ok(PendingFinalSend {
                    event_id,
                    binding: BindingKey {
                        installation_id: installation_id.clone(),
                        chat_id,
                        workspace_id: parse_workspace_id(workspace_id)?,
                    },
                    message_id,
                    delivery_chat_id,
                    stream_message_id,
                    terminal_random_id,
                    state: InboundState::parse(state)?,
                    final_text,
                    output_attachments: serde_json::from_str(&output_attachments_json)?,
                    failure,
                })
            })
            .collect()
    }

    /// Persists the first non-zero final-send identity and returns it
    /// for this and every later retry of the staged result.
    pub fn ensure_inbound_final_send_random_id(
        &self,
        event_id: &str,
        candidate: i64,
    ) -> StoreResult<Option<i64>> {
        if candidate <= 0 {
            return Ok(None);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        connection.execute(
            "UPDATE inbound_directions
             SET terminal_random_id = COALESCE(terminal_random_id, ?2)
             WHERE event_id = ?1 AND state = 'started'
               AND terminal_state IS NOT NULL",
            params![event_id, candidate],
        )?;
        connection
            .query_row(
                "SELECT terminal_random_id FROM inbound_directions WHERE event_id = ?1",
                params![event_id],
                |row| row.get(0),
            )
            .optional()
            .map(|value| value.flatten())
            .map_err(Into::into)
    }

    /// Commits a staged result only after its final Inline message was sent or
    /// found through the existing idempotent send transaction.
    pub fn commit_inbound_final_send(&self, event_id: &str) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                state = terminal_state,
                lease_expires_at = NULL,
                failure = terminal_failure,
                terminal_state = NULL,
                terminal_text = NULL,
                terminal_output_attachments_json = '[]',
                terminal_failure = NULL
             WHERE event_id = ?1 AND state = 'started'
               AND terminal_state IS NOT NULL",
            params![event_id],
        )?;
        Ok(changed == 1)
    }
}

pub(super) fn migrate_v22(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE inbound_directions
             ADD COLUMN terminal_output_attachments_json TEXT NOT NULL DEFAULT '[]';
         PRAGMA user_version = 22;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v9(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE inbound_directions ADD COLUMN terminal_state TEXT
             CHECK (terminal_state IS NULL OR terminal_state IN ('completed', 'failed'));
         ALTER TABLE inbound_directions ADD COLUMN terminal_text TEXT;
         ALTER TABLE inbound_directions ADD COLUMN terminal_failure TEXT;
         PRAGMA user_version = 9;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v10(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE inbound_directions ADD COLUMN terminal_random_id INTEGER
             CHECK (terminal_random_id IS NULL OR terminal_random_id > 0);
         PRAGMA user_version = 10;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Direction, DirectionId, InstallationId, OutputAttachmentKind, WorkspaceId};

    fn binding() -> BindingKey {
        BindingKey {
            installation_id: InstallationId::new("install-1").expect("installation"),
            chat_id: 42,
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
        }
    }

    fn started(store: &BridgeStore, event_id: &str) {
        let binding = binding();
        store
            .accept_inbound(&InboundRecord {
                event_id: event_id.to_string(),
                binding,
                message_id: 10,
                delivery_chat_id: 42,
                sender_user_id: 1,
                direction: Direction::new(
                    DirectionId::new(format!("direction-{event_id}")).expect("direction"),
                    "work",
                ),
                state: InboundState::Accepted,
                accepted_at: 1,
                started_at: None,
                lease_expires_at: None,
                attempt_count: 0,
                provider_turn_id: None,
                stream_message_id: None,
                failure: None,
            })
            .expect("accept");
        assert!(store.start_inbound(event_id, 2).expect("start"));
        assert!(
            store
                .attach_inbound_turn(
                    event_id,
                    &crate::TurnId::new(format!("turn-{event_id}")).expect("turn"),
                    Some(55),
                )
                .expect("attach")
        );
    }

    #[test]
    fn staged_final_send_survives_recovery_scans_until_committed() {
        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-1");
        assert!(
            store
                .stage_inbound_final_send("event-1", InboundState::Completed, "Done.", None,)
                .expect("stage")
        );
        assert_eq!(
            store
                .ensure_inbound_final_send_random_id("event-1", 123)
                .expect("final send identity"),
            Some(123)
        );
        assert_eq!(
            store
                .ensure_inbound_final_send_random_id("event-1", 456)
                .expect("stable final send identity"),
            Some(123)
        );

        assert_eq!(store.recover_expired_inbound(1_000).expect("recover"), 0);
        assert!(
            store
                .interrupt_started_inbound(&binding(), "restart")
                .expect("interrupt")
                .is_empty()
        );
        let pending = store
            .pending_inbound_final_sends(&binding().installation_id)
            .expect("pending");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].final_text, "Done.");
        assert_eq!(pending[0].stream_message_id, Some(55));
        assert_eq!(pending[0].terminal_random_id, Some(123));
        assert_eq!(pending[0].state, InboundState::Completed);

        assert!(store.commit_inbound_final_send("event-1").expect("commit"));
        assert!(
            store
                .pending_inbound_final_sends(&binding().installation_id)
                .expect("pending after commit")
                .is_empty()
        );
        assert_eq!(
            store
                .get_inbound("event-1")
                .expect("load")
                .expect("record")
                .state,
            InboundState::Completed
        );
    }

    #[test]
    fn staged_output_attachments_survive_until_final_send_commit() {
        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-output");
        let attachment = OutputAttachment {
            id: "image-1".to_string(),
            kind: OutputAttachmentKind::Image,
            path: PathBuf::from("/tmp/generated.png"),
            mime_type: "image/png".to_string(),
            file_name: "generated-image.png".to_string(),
            size_bytes: 42,
            sha256: "ab".repeat(32),
        };

        assert!(
            store
                .stage_inbound_final_send_with_attachments(
                    "event-output",
                    InboundState::Completed,
                    "Done.",
                    std::slice::from_ref(&attachment),
                    None,
                )
                .expect("stage")
        );
        let pending = store
            .pending_inbound_final_sends(&binding().installation_id)
            .expect("pending");
        assert_eq!(pending[0].output_attachments, [attachment]);

        assert!(
            store
                .commit_inbound_final_send("event-output")
                .expect("commit")
        );
    }

    #[test]
    fn staged_final_send_is_idempotent_but_cannot_be_rewritten() {
        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-1");
        assert!(
            store
                .stage_inbound_final_send(
                    "event-1",
                    InboundState::Failed,
                    "Could not finish.",
                    Some("provider failed"),
                )
                .expect("stage")
        );
        assert!(
            store
                .stage_inbound_final_send(
                    "event-1",
                    InboundState::Failed,
                    "Could not finish.",
                    Some("provider failed"),
                )
                .expect("repeat")
        );
        assert!(
            !store
                .stage_inbound_final_send(
                    "event-1",
                    InboundState::Completed,
                    "Different result.",
                    None,
                )
                .expect("rewrite")
        );
        assert!(matches!(
            store.stage_inbound_final_send("event-1", InboundState::Started, "Invalid.", None,),
            Err(StoreError::InvalidInboundFinalState(_))
        ));
    }
}

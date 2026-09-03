//! Durable handoff between provider completion and an idempotent final message send.

use rusqlite::{Connection, params};

use super::*;
use crate::{InstallationId, OutputAttachment};

// Match the server's complete text-message envelope so durable final-send
// recovery never rejects a payload that Inline itself accepts.
const MAX_FINAL_TEXT_BYTES: usize = 400_000;
const MAX_FINAL_TEXT_UTF16: usize = 100_000;
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
    pub agent_output_session_id: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingAgentOutputLink {
    pub event_id: String,
    pub agent_session_id: i64,
    pub provider_turn_id: TurnId,
    pub message_id: i64,
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
        self.stage_inbound_final_send_with_attachments_and_link(
            event_id,
            state,
            final_text,
            output_attachments,
            failure,
            None,
        )
    }

    /// Atomically journals the terminal answer and, when this is a resumed
    /// provider session, the server session that must own the final message.
    pub fn stage_inbound_final_send_with_attachments_and_link(
        &self,
        event_id: &str,
        state: InboundState,
        final_text: &str,
        output_attachments: &[OutputAttachment],
        failure: Option<&str>,
        agent_output_session_id: Option<i64>,
    ) -> StoreResult<bool> {
        if !matches!(state, InboundState::Completed | InboundState::Failed) {
            return Err(StoreError::InvalidInboundFinalState(
                state.as_str().to_string(),
            ));
        }
        if final_text.is_empty() {
            return Err(StoreError::InvalidInboundFinalText);
        }
        if final_text.len() > MAX_FINAL_TEXT_BYTES {
            return Err(StoreError::InboundFinalTextBytesExceeded {
                actual_bytes: final_text.len(),
                limit_bytes: MAX_FINAL_TEXT_BYTES,
            });
        }
        let final_text_utf16 = final_text.encode_utf16().count();
        if final_text_utf16 > MAX_FINAL_TEXT_UTF16 {
            return Err(StoreError::InboundFinalTextUtf16Exceeded {
                actual_utf16: final_text_utf16,
                limit_utf16: MAX_FINAL_TEXT_UTF16,
            });
        }
        if output_attachments.len() > MAX_OUTPUT_ATTACHMENTS {
            return Err(StoreError::InboundOutputAttachmentCountExceeded {
                actual_count: output_attachments.len(),
                limit_count: MAX_OUTPUT_ATTACHMENTS,
            });
        }
        if agent_output_session_id.is_some_and(|id| id <= 0) {
            return Ok(false);
        }
        let output_attachments_json = serde_json::to_string(output_attachments)?;
        if output_attachments_json.len() > MAX_OUTPUT_ATTACHMENTS_JSON_BYTES {
            return Err(StoreError::InboundOutputAttachmentBytesExceeded {
                actual_bytes: output_attachments_json.len(),
                limit_bytes: MAX_OUTPUT_ATTACHMENTS_JSON_BYTES,
            });
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                terminal_state = ?2, terminal_text = ?3,
                terminal_output_attachments_json = ?4, terminal_failure = ?5,
                agent_output_session_id = COALESCE(agent_output_session_id, ?6)
             WHERE event_id = ?1 AND state = 'started'
               AND (?6 IS NULL OR provider_turn_id IS NOT NULL)
               AND (?6 IS NULL OR agent_output_session_id IS NULL
                    OR agent_output_session_id = ?6)
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
                failure,
                agent_output_session_id,
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
                    terminal_output_attachments_json, terminal_failure,
                    agent_output_session_id
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
                    row.get::<_, Option<i64>>(11)?,
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
                    agent_output_session_id,
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
                    agent_output_session_id,
                })
            })
            .collect()
    }

    /// Records the canonical Inline message returned by the stable final-send
    /// transaction. A crash before this write simply repeats that transaction
    /// and receives the same message identity during recovery.
    pub fn attach_inbound_agent_output_message(
        &self,
        event_id: &str,
        message_id: i64,
    ) -> StoreResult<bool> {
        if message_id <= 0 {
            return Ok(false);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions
             SET agent_output_message_id = COALESCE(agent_output_message_id, ?2)
             WHERE event_id = ?1 AND agent_output_session_id IS NOT NULL
               AND agent_output_linked = 0
               AND (agent_output_message_id IS NULL OR agent_output_message_id = ?2)",
            params![event_id, message_id],
        )?;
        Ok(changed == 1)
    }

    pub fn pending_agent_output_links(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Vec<PendingAgentOutputLink>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let mut statement = connection.prepare(
            "SELECT event_id, agent_output_session_id, provider_turn_id,
                    agent_output_message_id
             FROM inbound_directions
             WHERE installation_id = ?1 AND agent_output_linked = 0
               AND agent_output_session_id IS NOT NULL
               AND agent_output_message_id IS NOT NULL
               AND provider_turn_id IS NOT NULL
             ORDER BY ingest_order ASC",
        )?;
        statement
            .query_map(params![installation_id.as_str()], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })?
            .map(|row| {
                let (event_id, agent_session_id, provider_turn_id, message_id) = row?;
                if agent_session_id <= 0 || message_id <= 0 {
                    return Err(StoreError::InvalidIdentifier {
                        kind: "agent output link",
                        value: event_id,
                    });
                }
                Ok(PendingAgentOutputLink {
                    event_id,
                    agent_session_id,
                    provider_turn_id: parse_turn_id(provider_turn_id)?,
                    message_id,
                })
            })
            .collect()
    }

    pub fn mark_agent_output_linked(&self, event_id: &str) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET agent_output_linked = 1
             WHERE event_id = ?1 AND agent_output_linked = 0
               AND agent_output_session_id IS NOT NULL
               AND agent_output_message_id IS NOT NULL
               AND provider_turn_id IS NOT NULL",
            params![event_id],
        )?;
        Ok(changed == 1)
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
    /// found through the existing idempotent send transaction. Progress state
    /// is no longer needed after that boundary because Inline owns the visible
    /// messages and there is no pending final send left to reconstruct.
    pub fn commit_inbound_final_send(&self, event_id: &str) -> StoreResult<bool> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let changed = transaction.execute(
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
        if changed == 1 {
            transaction.execute(
                "DELETE FROM inbound_progress_messages WHERE event_id = ?1",
                params![event_id],
            )?;
            transaction.execute(
                "DELETE FROM inbound_progress WHERE event_id = ?1",
                params![event_id],
            )?;
        }
        transaction.commit()?;
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

pub(super) fn migrate_v29(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch("BEGIN IMMEDIATE;")?;
    let result = (|| -> StoreResult<()> {
        if !table_has_column(connection, "inbound_directions", "agent_output_session_id")? {
            connection.execute_batch(
                "ALTER TABLE inbound_directions ADD COLUMN agent_output_session_id INTEGER
                     CHECK (agent_output_session_id IS NULL OR agent_output_session_id > 0);",
            )?;
        }
        if !table_has_column(connection, "inbound_directions", "agent_output_message_id")? {
            connection.execute_batch(
                "ALTER TABLE inbound_directions ADD COLUMN agent_output_message_id INTEGER
                     CHECK (agent_output_message_id IS NULL OR agent_output_message_id > 0);",
            )?;
        }
        if !table_has_column(connection, "inbound_directions", "agent_output_linked")? {
            connection.execute_batch(
                "ALTER TABLE inbound_directions ADD COLUMN agent_output_linked INTEGER NOT NULL DEFAULT 0
                     CHECK (agent_output_linked IN (0, 1));",
            )?;
        }
        connection.execute_batch(
            "CREATE INDEX IF NOT EXISTS inbound_agent_output_link_recovery
                 ON inbound_directions (installation_id, agent_output_linked, ingest_order)
                 WHERE agent_output_session_id IS NOT NULL;
             PRAGMA user_version = 29;",
        )?;
        Ok(())
    })();
    match result {
        Ok(()) => connection.execute_batch("COMMIT;")?,
        Err(error) => {
            let _ = connection.execute_batch("ROLLBACK;");
            return Err(error);
        }
    }
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
                .put_inbound_progress_ledger("event-1", r#"{"entries":[]}"#)
                .expect("progress ledger")
        );
        assert_eq!(
            store
                .attach_inbound_progress_message("event-1", 0, 55)
                .expect("progress message"),
            Some(55)
        );
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
        assert_eq!(
            store.inbound_progress("event-1").expect("progress"),
            DurableProgress {
                ledger_json: Some(r#"{"entries":[]}"#.to_string()),
                message_ids: vec![55],
            }
        );

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
        assert_eq!(
            store.inbound_progress("event-1").expect("cleaned progress"),
            DurableProgress::default()
        );
    }

    #[test]
    fn terminal_text_journal_matches_inline_message_limits() {
        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-large-final");
        let valid = "🦀".repeat(40_000);
        assert!(valid.len() > 128 * 1024);
        assert!(valid.len() <= MAX_FINAL_TEXT_BYTES);
        assert!(valid.encode_utf16().count() <= MAX_FINAL_TEXT_UTF16);
        assert!(
            store
                .stage_inbound_final_send(
                    "event-large-final",
                    InboundState::Completed,
                    &valid,
                    None,
                )
                .expect("stage transport-valid final text")
        );

        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-final-utf16-limit");
        let oversized_utf16 = "x".repeat(MAX_FINAL_TEXT_UTF16 + 1);
        assert!(matches!(
            store.stage_inbound_final_send(
                "event-final-utf16-limit",
                InboundState::Completed,
                &oversized_utf16,
                None,
            ),
            Err(StoreError::InboundFinalTextUtf16Exceeded {
                actual_utf16,
                limit_utf16: MAX_FINAL_TEXT_UTF16,
            }) if actual_utf16 == MAX_FINAL_TEXT_UTF16 + 1
        ));

        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-final-byte-limit");
        let oversized_bytes = "ࠀ".repeat(MAX_FINAL_TEXT_BYTES / 3 + 1);
        assert!(matches!(
            store.stage_inbound_final_send(
                "event-final-byte-limit",
                InboundState::Completed,
                &oversized_bytes,
                None,
            ),
            Err(StoreError::InboundFinalTextBytesExceeded {
                actual_bytes,
                limit_bytes: MAX_FINAL_TEXT_BYTES,
            }) if actual_bytes > MAX_FINAL_TEXT_BYTES
        ));
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
    fn terminal_attachment_limits_report_actual_and_maximum_values() {
        let attachment = OutputAttachment {
            id: "image-1".to_string(),
            kind: OutputAttachmentKind::Image,
            path: PathBuf::from("/tmp/generated.png"),
            mime_type: "image/png".to_string(),
            file_name: "generated-image.png".to_string(),
            size_bytes: 42,
            sha256: "ab".repeat(32),
        };

        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-output-count-limit");
        let too_many = vec![attachment.clone(); MAX_OUTPUT_ATTACHMENTS + 1];
        assert!(matches!(
            store.stage_inbound_final_send_with_attachments(
                "event-output-count-limit",
                InboundState::Completed,
                "Done.",
                &too_many,
                None,
            ),
            Err(StoreError::InboundOutputAttachmentCountExceeded {
                actual_count,
                limit_count: MAX_OUTPUT_ATTACHMENTS,
            }) if actual_count == MAX_OUTPUT_ATTACHMENTS + 1
        ));

        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-output-metadata-limit");
        let mut oversized = attachment;
        oversized.id = "x".repeat(MAX_OUTPUT_ATTACHMENTS_JSON_BYTES);
        assert!(matches!(
            store.stage_inbound_final_send_with_attachments(
                "event-output-metadata-limit",
                InboundState::Completed,
                "Done.",
                &[oversized],
                None,
            ),
            Err(StoreError::InboundOutputAttachmentBytesExceeded {
                actual_bytes,
                limit_bytes: MAX_OUTPUT_ATTACHMENTS_JSON_BYTES,
            }) if actual_bytes > MAX_OUTPUT_ATTACHMENTS_JSON_BYTES
        ));
    }

    #[test]
    fn agent_output_link_debt_survives_final_commit_until_linked() {
        let store = BridgeStore::open_in_memory().expect("store");
        started(&store, "event-link");
        assert!(
            store
                .stage_inbound_final_send_with_attachments_and_link(
                    "event-link",
                    InboundState::Completed,
                    "Done.",
                    &[],
                    None,
                    Some(77),
                )
                .expect("stage final and link")
        );
        assert!(
            store
                .attach_inbound_agent_output_message("event-link", 88)
                .expect("attach message")
        );
        assert!(
            store
                .commit_inbound_final_send("event-link")
                .expect("commit final")
        );

        let pending = store
            .pending_agent_output_links(&binding().installation_id)
            .expect("pending links");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].event_id, "event-link");
        assert_eq!(pending[0].agent_session_id, 77);
        assert_eq!(pending[0].message_id, 88);
        assert_eq!(pending[0].provider_turn_id.as_str(), "turn-event-link");

        assert!(
            store
                .mark_agent_output_linked("event-link")
                .expect("linked")
        );
        assert!(
            store
                .pending_agent_output_links(&binding().installation_id)
                .expect("pending after link")
                .is_empty()
        );
        assert!(
            !store
                .mark_agent_output_linked("event-link")
                .expect("repeat")
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

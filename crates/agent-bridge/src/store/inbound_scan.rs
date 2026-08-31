//! Installation-wide inbound scheduling and restart recovery.

use rusqlite::params;

use super::*;
use crate::InstallationId;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InboundUndoOutcome {
    Removed,
    Unauthorized,
    WrongContext,
    AlreadyStarted,
    Unknown,
}

impl BridgeStore {
    /// Returns the most recent completed trigger before the supplied event in
    /// the same durable conversation binding.
    pub fn previous_completed_message_id(
        &self,
        event_id: &str,
        binding: &BindingKey,
    ) -> StoreResult<Option<i64>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        connection
            .query_row(
                "SELECT previous.message_id
                 FROM inbound_directions AS current
                 JOIN inbound_directions AS previous
                   ON previous.installation_id = current.installation_id
                  AND previous.chat_id = current.chat_id
                  AND previous.workspace_id = current.workspace_id
                  AND previous.ingest_order < current.ingest_order
                 WHERE current.event_id = ?1
                   AND current.installation_id = ?2
                   AND current.chat_id = ?3
                   AND current.workspace_id = ?4
                   AND previous.state = 'completed'
                 ORDER BY previous.ingest_order DESC
                 LIMIT 1",
                params![
                    event_id,
                    binding.installation_id.as_str(),
                    binding.chat_id,
                    binding.workspace_id.as_str(),
                ],
                |row| row.get(0),
            )
            .optional()
            .map_err(StoreError::from)
    }

    /// Removes one accepted direction before a worker starts it.
    pub fn undo_accepted_inbound(
        &self,
        event_id: &str,
        installation_id: &InstallationId,
        chat_id: i64,
        actor_user_id: i64,
    ) -> StoreResult<InboundUndoOutcome> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let record = transaction
            .query_row(
                "SELECT installation_id, chat_id, sender_user_id, state
                 FROM inbound_directions WHERE event_id = ?1",
                params![event_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((stored_installation, stored_chat, sender_user_id, state)) = record else {
            transaction.commit()?;
            return Ok(InboundUndoOutcome::Unknown);
        };
        if stored_installation != installation_id.as_str() || stored_chat != chat_id {
            transaction.commit()?;
            return Ok(InboundUndoOutcome::WrongContext);
        }
        if sender_user_id != actor_user_id {
            transaction.commit()?;
            return Ok(InboundUndoOutcome::Unauthorized);
        }
        if state != "accepted" {
            transaction.commit()?;
            return Ok(InboundUndoOutcome::AlreadyStarted);
        }
        let changed = transaction.execute(
            "UPDATE inbound_directions SET state = 'failed', failure = 'removed from queue'
             WHERE event_id = ?1 AND state = 'accepted'",
            params![event_id],
        )?;
        transaction.commit()?;
        Ok(if changed == 1 {
            InboundUndoOutcome::Removed
        } else {
            InboundUndoOutcome::AlreadyStarted
        })
    }

    /// Returns pending conversation bindings in global ingest order.
    ///
    /// This does not claim work. A supervisor selects an inactive binding and
    /// then uses `take_next_inbound`, whose compare-and-set owns the claim.
    pub fn pending_inbound_bindings(
        &self,
        installation_id: &InstallationId,
        limit: usize,
    ) -> StoreResult<Vec<BindingKey>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let mut statement = connection.prepare(
            "SELECT chat_id, workspace_id, MIN(ingest_order) AS first_ingest
             FROM inbound_directions
             WHERE installation_id = ?1 AND state = 'accepted'
             GROUP BY chat_id, workspace_id
             ORDER BY first_ingest ASC
             LIMIT ?2",
        )?;
        statement
            .query_map(
                params![
                    installation_id.as_str(),
                    i64::try_from(limit).unwrap_or(i64::MAX)
                ],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
            )?
            .map(|row| {
                let (chat_id, workspace_id) = row?;
                Ok(BindingKey {
                    installation_id: installation_id.clone(),
                    chat_id,
                    workspace_id: parse_workspace_id(workspace_id)?,
                })
            })
            .collect()
    }

    /// Marks every turn whose live process handle was lost as interrupted.
    /// Started coding work is never replayed automatically after restart.
    pub fn interrupt_started_inbound_for_installation(
        &self,
        installation_id: &InstallationId,
        failure: &str,
    ) -> StoreResult<Vec<InterruptedInbound>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let interrupted = {
            let mut statement = transaction.prepare(
                "SELECT event_id, chat_id, workspace_id, message_id, delivery_chat_id,
                        stream_message_id
                 FROM inbound_directions
                 WHERE installation_id = ?1 AND state = 'started'
                   AND terminal_state IS NULL
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
                    ) = row?;
                    Ok(InterruptedInbound {
                        event_id,
                        binding: BindingKey {
                            installation_id: installation_id.clone(),
                            chat_id,
                            workspace_id: parse_workspace_id(workspace_id)?,
                        },
                        message_id,
                        delivery_chat_id,
                        stream_message_id,
                    })
                })
                .collect::<StoreResult<Vec<_>>>()?
        };
        transaction.execute(
            "UPDATE inbound_directions SET
                state = 'failed', lease_expires_at = NULL, failure = ?2
             WHERE installation_id = ?1 AND state = 'started'
               AND terminal_state IS NULL",
            params![installation_id.as_str(), failure],
        )?;
        transaction.commit()?;
        Ok(interrupted)
    }

    /// Stages a durable failed result for every live turn whose provider
    /// process handle was lost. The pending-final-send recovery path owns the
    /// idempotent Inline send and terminal commit.
    pub fn stage_interrupted_inbound_for_installation(
        &self,
        installation_id: &InstallationId,
        failure: &str,
        final_text: &str,
    ) -> StoreResult<usize> {
        if final_text.is_empty() {
            return Err(StoreError::InvalidInboundFinalText);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE inbound_directions SET
                terminal_state = 'failed', terminal_text = ?3, terminal_failure = ?2
             WHERE installation_id = ?1 AND state = 'started'
               AND terminal_state IS NULL
               AND NOT EXISTS (
                    SELECT 1 FROM session_pickers
                    WHERE session_pickers.installation_id = inbound_directions.installation_id
                      AND session_pickers.origin_event_id = inbound_directions.event_id
                      AND session_pickers.state IN (
                          'publishing', 'active', 'opening', 'retryable', 'completed'
                      )
               )",
            params![installation_id.as_str(), failure, final_text],
        )?;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::WorkspaceId;

    fn installation() -> InstallationId {
        InstallationId::new("install-1").expect("installation")
    }

    fn binding(chat_id: i64) -> BindingKey {
        BindingKey {
            installation_id: installation(),
            chat_id,
            workspace_id: WorkspaceId::new(format!("workspace-{chat_id}")).expect("workspace"),
        }
    }

    fn inbound(event: &str, chat_id: i64, accepted_at: i64) -> InboundRecord {
        InboundRecord {
            event_id: event.to_string(),
            binding: binding(chat_id),
            message_id: chat_id,
            delivery_chat_id: chat_id,
            sender_user_id: 7,
            direction: Direction::new(DirectionId::new(event).expect("direction"), event),
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
    fn pending_bindings_follow_global_ingest_order() {
        let store = BridgeStore::open_in_memory().expect("store");
        store
            .accept_inbound(&inbound("z-first", 20, 10))
            .expect("first");
        store
            .accept_inbound(&inbound("a-second", 10, 10))
            .expect("second");
        store
            .accept_inbound(&inbound("third-same-chat", 20, 10))
            .expect("third");

        assert_eq!(
            store
                .pending_inbound_bindings(&installation(), 8)
                .expect("bindings"),
            vec![binding(20), binding(10)]
        );
    }

    #[test]
    fn restart_interrupts_started_work_across_every_conversation() {
        let store = BridgeStore::open_in_memory().expect("store");
        store.accept_inbound(&inbound("one", 10, 10)).expect("one");
        store.accept_inbound(&inbound("two", 20, 11)).expect("two");
        store.take_next_inbound(&binding(10), 20).expect("take one");
        store.take_next_inbound(&binding(20), 20).expect("take two");

        let interrupted = store
            .interrupt_started_inbound_for_installation(&installation(), "restart")
            .expect("interrupt");
        assert_eq!(
            interrupted
                .iter()
                .map(|record| record.binding.chat_id)
                .collect::<Vec<_>>(),
            vec![10, 20]
        );
        assert!(interrupted.iter().all(|record| {
            store
                .get_inbound(&record.event_id)
                .expect("lookup")
                .is_some_and(|record| record.state == InboundState::Failed)
        }));
    }

    #[test]
    fn provider_loss_stages_every_started_turn_for_durable_final_send() {
        let store = BridgeStore::open_in_memory().expect("store");
        store.accept_inbound(&inbound("one", 10, 10)).expect("one");
        store.accept_inbound(&inbound("two", 20, 11)).expect("two");
        store.take_next_inbound(&binding(10), 20).expect("take one");
        store.take_next_inbound(&binding(20), 20).expect("take two");

        assert_eq!(
            store
                .stage_interrupted_inbound_for_installation(
                    &installation(),
                    "provider disconnected",
                    "The local agent disconnected.",
                )
                .expect("stage"),
            2
        );
        let pending = store
            .pending_inbound_final_sends(&installation())
            .expect("pending");
        assert_eq!(pending.len(), 2);
        assert!(pending.iter().all(|record| {
            record.state == InboundState::Failed
                && record.failure.as_deref() == Some("provider disconnected")
        }));
        for record in pending {
            assert!(
                store
                    .commit_inbound_final_send(&record.event_id)
                    .expect("commit")
            );
        }
        assert!(
            store
                .pending_inbound_final_sends(&installation())
                .expect("pending after commit")
                .is_empty()
        );
    }

    #[test]
    fn accepted_work_can_be_undone_only_by_its_sender_before_start() {
        let store = BridgeStore::open_in_memory().expect("store");
        store
            .accept_inbound(&inbound("queued", 10, 10))
            .expect("queued");
        assert_eq!(
            store
                .undo_accepted_inbound("queued", &installation(), 10, 8)
                .expect("unauthorized"),
            InboundUndoOutcome::Unauthorized
        );
        assert_eq!(
            store
                .undo_accepted_inbound("queued", &installation(), 11, 7)
                .expect("context"),
            InboundUndoOutcome::WrongContext
        );
        assert_eq!(
            store
                .undo_accepted_inbound("queued", &installation(), 10, 7)
                .expect("undo"),
            InboundUndoOutcome::Removed
        );
        assert_eq!(
            store
                .undo_accepted_inbound("queued", &installation(), 10, 7)
                .expect("again"),
            InboundUndoOutcome::AlreadyStarted
        );
    }

    #[test]
    fn previous_context_checkpoint_uses_completed_ingest_order() {
        let store = BridgeStore::open_in_memory().expect("store");
        store.accept_inbound(&inbound("one", 10, 10)).expect("one");
        let mut second = inbound("two", 10, 10);
        second.message_id = 11;
        store.accept_inbound(&second).expect("two");
        let first = store
            .take_next_inbound(&binding(10), 20)
            .expect("take")
            .expect("first");
        store.complete_inbound(&first.event_id).expect("complete");

        assert_eq!(
            store
                .previous_completed_message_id("two", &binding(10))
                .expect("checkpoint"),
            Some(10)
        );
    }
}

//! Durable, bounded progress state for restart-safe verbose presentation.

use rusqlite::{Connection, OptionalExtension, params};

use super::*;

const MAX_PROGRESS_LEDGER_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DurableProgress {
    pub ledger_json: Option<String>,
    pub message_ids: Vec<i64>,
}

impl BridgeStore {
    /// Persists an already-normalized, display-safe progress ledger. The bridge
    /// records this before publishing a corresponding presentation update.
    pub fn put_inbound_progress_ledger(
        &self,
        event_id: &str,
        ledger_json: &str,
    ) -> StoreResult<bool> {
        if ledger_json.is_empty() || ledger_json.len() > MAX_PROGRESS_LEDGER_BYTES {
            return Err(StoreError::InvalidProgressLedger);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "INSERT INTO inbound_progress (event_id, ledger_json)
             SELECT event_id, ?2 FROM inbound_directions
             WHERE event_id = ?1 AND state = 'started'
             ON CONFLICT(event_id) DO UPDATE SET ledger_json = excluded.ledger_json",
            params![event_id, ledger_json],
        )?;
        Ok(changed == 1)
    }

    /// Returns the safe ledger and every known progress-message identity in
    /// stable chunk order. Missing chunk indexes are ignored fail-closed.
    pub fn inbound_progress(&self, event_id: &str) -> StoreResult<DurableProgress> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let ledger_json = connection
            .query_row(
                "SELECT ledger_json FROM inbound_progress WHERE event_id = ?1",
                params![event_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let mut statement = connection.prepare(
            "SELECT message_id FROM inbound_progress_messages
             WHERE event_id = ?1 ORDER BY chunk_index ASC",
        )?;
        let message_ids = statement
            .query_map(params![event_id], |row| row.get::<_, i64>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(DurableProgress {
            ledger_json,
            message_ids,
        })
    }

    /// Records a progress message at one stable chunk index. A retry with a
    /// different candidate retains the first confirmed identity.
    pub fn attach_inbound_progress_message(
        &self,
        event_id: &str,
        chunk_index: usize,
        message_id: i64,
    ) -> StoreResult<Option<i64>> {
        if message_id <= 0 {
            return Ok(None);
        }
        let chunk_index = i64::try_from(chunk_index).unwrap_or(i64::MAX);
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        transaction.execute(
            "INSERT OR IGNORE INTO inbound_progress_messages (
                event_id, chunk_index, message_id
             )
             SELECT event_id, ?2, ?3 FROM inbound_directions
             WHERE event_id = ?1 AND state = 'started'",
            params![event_id, chunk_index, message_id],
        )?;
        let stored = transaction
            .query_row(
                "SELECT message_id FROM inbound_progress_messages
                 WHERE event_id = ?1 AND chunk_index = ?2",
                params![event_id, chunk_index],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        transaction.commit()?;
        Ok(stored)
    }
}

pub(super) fn migrate_v16(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE inbound_progress (
            event_id TEXT PRIMARY KEY NOT NULL,
            ledger_json TEXT NOT NULL,
            FOREIGN KEY (event_id) REFERENCES inbound_directions(event_id)
         );
         CREATE TABLE inbound_progress_messages (
            event_id TEXT NOT NULL,
            chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
            message_id INTEGER NOT NULL CHECK (message_id > 0),
            PRIMARY KEY (event_id, chunk_index),
            FOREIGN KEY (event_id) REFERENCES inbound_directions(event_id)
         );
         PRAGMA user_version = 16;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        BindingKey, Direction, DirectionId, InboundRecord, InboundState, InstallationId,
        WorkspaceId,
    };

    fn inbound() -> InboundRecord {
        InboundRecord {
            event_id: "event-progress".to_string(),
            binding: BindingKey {
                installation_id: InstallationId::new("install").expect("installation"),
                chat_id: 42,
                workspace_id: WorkspaceId::new("workspace").expect("workspace"),
            },
            message_id: 7,
            delivery_chat_id: 42,
            sender_user_id: 9,
            direction: Direction::new(DirectionId::new("direction").expect("direction"), "work"),
            state: InboundState::Accepted,
            accepted_at: 1,
            started_at: None,
            lease_expires_at: None,
            attempt_count: 0,
            provider_turn_id: None,
            stream_message_id: None,
            failure: None,
        }
    }

    #[test]
    fn ledger_and_chunk_identities_round_trip_idempotently() {
        let store = BridgeStore::open_in_memory().expect("store");
        store.accept_inbound(&inbound()).expect("accept");
        store
            .take_next_inbound(&inbound().binding, 2)
            .expect("take")
            .expect("record");

        assert!(
            store
                .put_inbound_progress_ledger("event-progress", r#"{"entries":[]}"#)
                .expect("ledger")
        );
        assert_eq!(
            store
                .attach_inbound_progress_message("event-progress", 0, 100)
                .expect("first"),
            Some(100)
        );
        assert_eq!(
            store
                .attach_inbound_progress_message("event-progress", 0, 999)
                .expect("retry"),
            Some(100)
        );
        assert_eq!(
            store
                .attach_inbound_progress_message("event-progress", 1, 101)
                .expect("second"),
            Some(101)
        );
        assert_eq!(
            store.inbound_progress("event-progress").expect("load"),
            DurableProgress {
                ledger_json: Some(r#"{"entries":[]}"#.to_string()),
                message_ids: vec![100, 101],
            }
        );
    }

    #[test]
    fn progress_state_cannot_attach_before_or_after_a_started_turn() {
        let store = BridgeStore::open_in_memory().expect("store");
        store.accept_inbound(&inbound()).expect("accept");
        assert!(
            !store
                .put_inbound_progress_ledger("event-progress", "{}")
                .expect("accepted")
        );
        assert_eq!(
            store
                .attach_inbound_progress_message("event-progress", 0, 100)
                .expect("accepted message"),
            None
        );
        store
            .take_next_inbound(&inbound().binding, 2)
            .expect("take")
            .expect("record");
        store.complete_inbound("event-progress").expect("complete");
        assert!(
            !store
                .put_inbound_progress_ledger("event-progress", "{}")
                .expect("completed")
        );
    }
}

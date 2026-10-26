//! Durable ledger of Inline messages sent to native sessions.
//!
//! An Inline delivery is acknowledged only after its input is recorded here,
//! and every native receipt moves the record forward. After a restart, a
//! record that never reached a confirmed state is reported to the sender
//! instead of being sent again, so input is neither dropped silently nor
//! delivered twice. Only identities and states are stored, never text.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

/// Where one input stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum InputState {
    /// Recorded; not yet written to the harness.
    Received,
    /// Held in Inline: paused, acquiring, released or moved out of the queue.
    Pending,
    /// Written; the harness's receipt has not arrived.
    Sent,
    /// The harness accepted it (started, steered, queued or absorbed).
    Accepted,
    /// The harness consumed it in a turn.
    Consumed,
    /// The harness may or may not have it. Never resent automatically.
    Unknown,
    /// Rejected, or given up on; the sender was told.
    Failed,
    /// The sender chose not to run it.
    Discarded,
}

impl InputState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Received => "received",
            Self::Pending => "pending",
            Self::Sent => "sent",
            Self::Accepted => "accepted",
            Self::Consumed => "consumed",
            Self::Unknown => "unknown",
            Self::Failed => "failed",
            Self::Discarded => "discarded",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "received" => Self::Received,
            "pending" => Self::Pending,
            "sent" => Self::Sent,
            "accepted" => Self::Accepted,
            "consumed" => Self::Consumed,
            "unknown" => Self::Unknown,
            "failed" => Self::Failed,
            "discarded" => Self::Discarded,
            _ => return None,
        })
    }

    /// The input reached a state that needs nothing more from the bridge.
    pub(crate) fn is_settled(self) -> bool {
        matches!(
            self,
            Self::Accepted | Self::Consumed | Self::Failed | Self::Discarded
        )
    }
}

/// One recorded input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct InputRecord {
    pub input_id: String,
    pub chat_id: i64,
    pub message_id: i64,
    pub sender_user_id: i64,
    pub state: InputState,
}

/// The outcome of recording an Inline message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Begin {
    /// First time: send it with this input ID.
    New { input_id: String },
    /// Already recorded (a replayed delivery): do not send it again.
    Seen(InputRecord),
}

/// The stable native input ID for one Inline message. Claude requires UUIDs;
/// a name-based UUID gives a replayed delivery the same ID.
pub(crate) fn input_id(bot_user_id: i64, chat_id: i64, message_id: i64, kind: &str) -> String {
    Uuid::new_v5(
        &Uuid::NAMESPACE_OID,
        format!("inline:{kind}:{bot_user_id}:{chat_id}:{message_id}").as_bytes(),
    )
    .to_string()
}

pub(crate) struct Ledger {
    connection: Mutex<Connection>,
}

impl Ledger {
    pub(crate) fn open(path: &Path) -> rusqlite::Result<Self> {
        Self::from_connection(Connection::open(path)?)
    }

    #[cfg(test)]
    pub(crate) fn in_memory() -> rusqlite::Result<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> rusqlite::Result<Self> {
        connection.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS v2_inputs (
                 input_id TEXT PRIMARY KEY,
                 chat_id INTEGER NOT NULL,
                 message_id INTEGER NOT NULL,
                 sender_user_id INTEGER NOT NULL,
                 state TEXT NOT NULL,
                 created_at INTEGER NOT NULL,
                 updated_at INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS v2_inputs_open ON v2_inputs (state, chat_id);",
        )?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    /// Records an Inline message as received, unless it already was.
    pub(crate) fn begin(
        &self,
        input_id: &str,
        chat_id: i64,
        message_id: i64,
        sender_user_id: i64,
    ) -> rusqlite::Result<Begin> {
        let connection = self.connection.lock().expect("ledger poisoned");
        if let Some(record) = record(&connection, input_id)? {
            return Ok(Begin::Seen(record));
        }
        let now = now_seconds();
        connection.execute(
            "INSERT INTO v2_inputs (input_id, chat_id, message_id, sender_user_id, state, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
            params![
                input_id,
                chat_id,
                message_id,
                sender_user_id,
                InputState::Received.as_str(),
                now
            ],
        )?;
        Ok(Begin::New {
            input_id: input_id.to_owned(),
        })
    }

    pub(crate) fn set(&self, input_id: &str, state: InputState) -> rusqlite::Result<()> {
        let connection = self.connection.lock().expect("ledger poisoned");
        connection.execute(
            "UPDATE v2_inputs SET state = ?2, updated_at = ?3 WHERE input_id = ?1",
            params![input_id, state.as_str(), now_seconds()],
        )?;
        Ok(())
    }

    pub(crate) fn get(&self, input_id: &str) -> rusqlite::Result<Option<InputRecord>> {
        let connection = self.connection.lock().expect("ledger poisoned");
        record(&connection, input_id)
    }

    /// Inputs a previous run left without a confirmed outcome.
    pub(crate) fn unresolved(&self) -> rusqlite::Result<Vec<InputRecord>> {
        let connection = self.connection.lock().expect("ledger poisoned");
        let mut statement = connection.prepare(
            "SELECT input_id, chat_id, message_id, sender_user_id, state FROM v2_inputs
             WHERE state IN ('received', 'pending', 'sent', 'unknown') ORDER BY created_at",
        )?;
        let rows = statement.query_map([], row_record)?;
        rows.filter_map(Result::transpose).collect()
    }

    /// Drops settled records older than `max_age_secs`.
    pub(crate) fn prune(&self, max_age_secs: i64) -> rusqlite::Result<usize> {
        let connection = self.connection.lock().expect("ledger poisoned");
        connection.execute(
            "DELETE FROM v2_inputs WHERE state IN ('accepted', 'consumed', 'failed', 'discarded')
             AND updated_at < ?1",
            params![now_seconds() - max_age_secs],
        )
    }
}

fn record(connection: &Connection, input_id: &str) -> rusqlite::Result<Option<InputRecord>> {
    connection
        .query_row(
            "SELECT input_id, chat_id, message_id, sender_user_id, state FROM v2_inputs WHERE input_id = ?1",
            params![input_id],
            row_record,
        )
        .optional()
        .map(Option::flatten)
}

fn row_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<Option<InputRecord>> {
    let state: String = row.get(4)?;
    Ok(InputState::parse(&state).map(|state| InputRecord {
        input_id: row.get(0).unwrap_or_default(),
        chat_id: row.get(1).unwrap_or_default(),
        message_id: row.get(2).unwrap_or_default(),
        sender_user_id: row.get(3).unwrap_or_default(),
        state,
    }))
}

fn now_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_replayed_delivery_is_seen_not_resent() {
        let ledger = Ledger::in_memory().unwrap();
        let id = input_id(9, 5, 10, "direct");
        assert_eq!(id, input_id(9, 5, 10, "direct"));
        assert!(Uuid::parse_str(&id).is_ok());
        assert_eq!(
            ledger.begin(&id, 5, 10, 7).unwrap(),
            Begin::New {
                input_id: id.clone()
            }
        );
        ledger.set(&id, InputState::Sent).unwrap();
        let Begin::Seen(record) = ledger.begin(&id, 5, 10, 7).unwrap() else {
            panic!("seen");
        };
        assert_eq!(record.state, InputState::Sent);
        assert_eq!(ledger.unresolved().unwrap().len(), 1);
        ledger.set(&id, InputState::Consumed).unwrap();
        assert!(ledger.unresolved().unwrap().is_empty());
    }
}

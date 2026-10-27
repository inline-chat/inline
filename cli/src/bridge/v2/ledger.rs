//! Durable ledger of Inline messages sent to native sessions.
//!
//! An Inline delivery is acknowledged only after its input is recorded here,
//! and every native receipt moves the record forward. After a restart, a
//! record written but never confirmed is settled by its session (what it
//! shows it consumed), and one never written is reported to its sender;
//! nothing is sent again, so input is neither dropped silently nor delivered
//! twice. Pending outbound messages retain their existing stable identity and
//! body here until Inline acknowledges publication.
//!
//! It also keeps each thread's settings (model, reasoning and permission
//! ids), so a choice made in Agent Settings or by a command survives a
//! restart.

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
             CREATE INDEX IF NOT EXISTS v2_inputs_open ON v2_inputs (state, chat_id);
             CREATE TABLE IF NOT EXISTS v2_threads (
                 chat_id INTEGER PRIMARY KEY,
                 settings TEXT NOT NULL,
                 bound TEXT,
                 updated_at INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS v2_work_moves (
                 source_chat_id INTEGER PRIMARY KEY,
                 destination_chat_id INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS v2_input_work (
                 input_id TEXT PRIMARY KEY,
                 chat_id INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS v2_outputs (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 random_id INTEGER NOT NULL UNIQUE,
                 chat_id INTEGER NOT NULL,
                 payload TEXT NOT NULL,
                 created_at INTEGER NOT NULL
             );",
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

    /// Saves a thread's settings and the composer configuration they last
    /// took, both as JSON.
    pub(crate) fn save_thread(
        &self,
        chat_id: i64,
        settings: &str,
        bound: Option<&str>,
    ) -> rusqlite::Result<()> {
        let connection = self.connection.lock().expect("ledger poisoned");
        connection.execute(
            "INSERT INTO v2_threads (chat_id, settings, bound, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (chat_id) DO UPDATE SET settings = ?2, bound = ?3, updated_at = ?4",
            params![chat_id, settings, bound, now_seconds()],
        )?;
        Ok(())
    }

    /// Every saved thread: (chat, settings, composer configuration).
    pub(crate) fn threads(&self) -> rusqlite::Result<Vec<(i64, String, Option<String>)>> {
        let connection = self.connection.lock().expect("ledger poisoned");
        let mut statement =
            connection.prepare("SELECT chat_id, settings, bound FROM v2_threads")?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?;
        rows.collect()
    }

    /// Retain a work's choices in its destination before asking Inline to move it.
    /// The source remains intact, including when the operation creates a fork.
    pub(crate) fn copy_thread(&self, from: i64, to: i64) -> rusqlite::Result<()> {
        let connection = self.connection.lock().expect("ledger poisoned");
        connection.execute(
            "INSERT INTO v2_threads (chat_id, settings, bound, updated_at)
             SELECT ?2, settings, bound, ?3 FROM v2_threads WHERE chat_id = ?1
             ON CONFLICT (chat_id) DO UPDATE SET settings = excluded.settings,
                 bound = excluded.bound, updated_at = excluded.updated_at",
            params![from, to, now_seconds()],
        )?;
        Ok(())
    }

    /// Canonical work routing changes; input records keep their physical message chat.
    pub(crate) fn move_thread(&self, from: i64, to: i64) -> rusqlite::Result<()> {
        self.copy_thread(from, to)?;
        let mut connection = self.connection.lock().expect("ledger poisoned");
        let tx = connection.transaction()?;
        tx.execute(
            "INSERT INTO v2_input_work (input_id, chat_id)
                    SELECT input_id, ?2 FROM v2_inputs WHERE chat_id = ?1
                    ON CONFLICT (input_id) DO NOTHING",
            params![from, to],
        )?;
        tx.execute(
            "UPDATE v2_input_work SET chat_id = ?2 WHERE chat_id = ?1",
            params![from, to],
        )?;
        tx.execute(
            "UPDATE v2_work_moves SET destination_chat_id = ?2 WHERE destination_chat_id = ?1",
            params![from, to],
        )?;
        tx.execute(
            "INSERT INTO v2_work_moves (source_chat_id, destination_chat_id) VALUES (?1, ?2)
                    ON CONFLICT (source_chat_id) DO UPDATE SET destination_chat_id = ?2",
            params![from, to],
        )?;
        tx.execute(
            "UPDATE v2_outputs SET chat_id = ?2 WHERE chat_id = ?1",
            params![from, to],
        )?;
        tx.commit()
    }

    pub(crate) fn input_work(&self, input_id: &str, physical_chat: i64) -> rusqlite::Result<i64> {
        let connection = self.connection.lock().expect("ledger poisoned");
        Ok(connection
            .query_row(
                "SELECT chat_id FROM v2_input_work WHERE input_id = ?1",
                [input_id],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(physical_chat))
    }

    pub(crate) fn forget_move(&self, chat_id: i64) -> rusqlite::Result<()> {
        self.connection.lock().expect("ledger poisoned").execute(
            "DELETE FROM v2_work_moves WHERE source_chat_id = ?1",
            [chat_id],
        )?;
        Ok(())
    }

    pub(crate) fn moves(&self) -> rusqlite::Result<Vec<(i64, i64)>> {
        let connection = self.connection.lock().expect("ledger poisoned");
        let mut statement =
            connection.prepare("SELECT source_chat_id, destination_chat_id FROM v2_work_moves")?;
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect()
    }

    pub(crate) fn save_output(
        &self,
        chat_id: i64,
        random_id: i64,
        payload: &str,
    ) -> rusqlite::Result<()> {
        let connection = self.connection.lock().expect("ledger poisoned");
        connection.execute("INSERT INTO v2_outputs (random_id, chat_id, payload, created_at) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT (random_id) DO UPDATE SET chat_id = ?2, payload = ?3", params![random_id, chat_id, payload, now_seconds()])?;
        Ok(())
    }

    pub(crate) fn outputs(&self, chat_id: i64) -> rusqlite::Result<Vec<String>> {
        let connection = self.connection.lock().expect("ledger poisoned");
        let mut statement =
            connection.prepare("SELECT payload FROM v2_outputs WHERE chat_id = ?1 ORDER BY id")?;
        statement.query_map([chat_id], |row| row.get(0))?.collect()
    }

    pub(crate) fn output_chats(&self) -> rusqlite::Result<Vec<i64>> {
        let connection = self.connection.lock().expect("ledger poisoned");
        let mut statement = connection.prepare("SELECT DISTINCT chat_id FROM v2_outputs")?;
        statement.query_map([], |row| row.get(0))?.collect()
    }

    pub(crate) fn remove_output(&self, random_id: i64) -> rusqlite::Result<()> {
        let connection = self.connection.lock().expect("ledger poisoned");
        connection.execute("DELETE FROM v2_outputs WHERE random_id = ?1", [random_id])?;
        Ok(())
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

    #[test]
    fn thread_settings_survive_reopening() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ledger.sqlite");
        {
            let ledger = Ledger::open(&path).unwrap();
            ledger
                .save_thread(7, r#"{"permission_mode":"plan"}"#, None)
                .unwrap();
            ledger
                .save_thread(7, r#"{"permission_mode":"default"}"#, Some(r#"["m",null]"#))
                .unwrap();
        }
        let ledger = Ledger::open(&path).unwrap();
        assert_eq!(
            ledger.threads().unwrap(),
            vec![(
                7,
                r#"{"permission_mode":"default"}"#.to_owned(),
                Some(r#"["m",null]"#.to_owned())
            )]
        );
    }
    #[test]
    fn pending_outputs_and_moved_choices_survive_reopening_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ledger.sqlite");
        {
            let ledger = Ledger::open(&path).unwrap();
            ledger.save_thread(7, "plan", Some("bound-model")).unwrap();
            ledger.begin("original-message", 7, 42, 9).unwrap();
            ledger.set("original-message", InputState::Unknown).unwrap();
            // Random IDs sort in the opposite direction from publication order.
            ledger
                .save_output(7, 90, "final body and target 7")
                .unwrap();
            ledger.save_output(7, 10, "open card").unwrap();
            ledger
                .save_output(7, 10, "closed card with the same ID")
                .unwrap();
            ledger.move_thread(7, 8).unwrap();
            ledger.move_thread(8, 11).unwrap();
        }
        let ledger = Ledger::open(&path).unwrap();
        assert_eq!(
            ledger.outputs(11).unwrap(),
            vec!["final body and target 7", "closed card with the same ID"]
        );
        let choices = ledger.threads().unwrap();
        for chat in [7, 8, 11] {
            assert!(choices.contains(&(chat, "plan".into(), Some("bound-model".into()))));
        }
        assert!(ledger.moves().unwrap().contains(&(7, 11)));
        assert_eq!(ledger.get("original-message").unwrap().unwrap().chat_id, 7);
        ledger.forget_move(7).unwrap();
        ledger.begin("new-source-work", 7, 43, 9).unwrap();
        assert_eq!(ledger.input_work("original-message", 7).unwrap(), 11);
        assert_eq!(ledger.input_work("new-source-work", 7).unwrap(), 7);
        ledger.remove_output(90).unwrap();
        assert_eq!(
            ledger.outputs(11).unwrap(),
            vec!["closed card with the same ID"]
        );
    }
}

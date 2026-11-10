//! Durable relay state: id mapping, cursors, pending-send reservations,
//! inbound dedupe, task cards, and confirmation claims.
//!
//! One SQLite file per relay installation. Holds ids and short rendered
//! strings only; never credentials.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, params};

/// Store failure.
#[derive(Debug, thiserror::Error)]
#[error("relay store: {0}")]
pub struct StoreError(String);

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self(error.to_string())
    }
}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

/// Result alias.
pub type StoreResult<T> = Result<T, StoreError>;

const SCHEMA_VERSION: i64 = 1;

/// Which piece of a remote message an Inline message mirrors.
pub mod part {
    /// The text body (also used for the owner's own sent message).
    pub const TEXT: &str = "text";
    /// Prefix for file parts: `file:<key>`.
    pub const FILE_PREFIX: &str = "file:";
}

/// Where a linked pair started.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    /// Mirrored from the remote network into Inline.
    Remote,
    /// Sent from Inline to the remote network.
    Inline,
}

impl Origin {
    fn as_str(self) -> &'static str {
        match self {
            Self::Remote => "remote",
            Self::Inline => "inline",
        }
    }

    fn parse(value: &str) -> Self {
        if value == "inline" {
            Self::Inline
        } else {
            Self::Remote
        }
    }
}

/// A remote message part and the Inline message that shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Link {
    /// Remote message id.
    pub remote_id: String,
    /// Part, see [`part`].
    pub part: String,
    /// Inline message; `None` when deliberately not mirrored.
    pub inline_id: Option<i64>,
    /// Direction.
    pub origin: Origin,
    /// Last applied revision.
    pub revision: Option<String>,
    /// Agent reaction currently mirrored on `inline_id`.
    pub agent_reaction: Option<String>,
}

/// A message sent from Inline whose remote delivery is not yet confirmed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingSend {
    /// Correlation id sent to the remote.
    pub request_id: String,
    /// Owner's Inline message.
    pub inline_id: i64,
    /// Remote parent.
    pub reply_to: Option<String>,
    /// Text to (re)send; the owner's own message, kept until delivered.
    pub text: String,
    /// Inline media to (re)fetch, as JSON written by the engine.
    pub media: Option<String>,
    /// Attempts made.
    pub attempts: u32,
    /// Unix seconds before which no retry happens.
    pub next_attempt_at: i64,
}

/// Lifecycle of a confirmation card.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConfirmationState {
    /// Buttons live.
    Open,
    /// An answer is being sent; never sent twice.
    Answering,
    /// Finished (answered, closed remotely, or failed).
    Done,
}

impl ConfirmationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Answering => "answering",
            Self::Done => "done",
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "answering" => Self::Answering,
            "done" => Self::Done,
            _ => Self::Open,
        }
    }
}

/// A confirmation card.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfirmationCard {
    /// Definition key.
    pub key: String,
    /// Remote message.
    pub remote_id: String,
    /// Inline card.
    pub inline_id: i64,
    /// State.
    pub state: ConfirmationState,
    /// Card body without status line.
    pub body: String,
}

/// SQLite-backed relay store.
pub struct RelayStore {
    connection: Mutex<Connection>,
}

impl std::fmt::Debug for RelayStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("RelayStore")
    }
}

impl RelayStore {
    /// Opens (creating 0600) and migrates the store.
    pub fn open(path: &Path) -> StoreResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(path)?;
        }
        Self::from_connection(Connection::open(path)?)
    }

    /// In-memory store for tests.
    pub fn open_in_memory() -> StoreResult<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> StoreResult<Self> {
        connection.execute_batch("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;")?;
        let version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version > SCHEMA_VERSION {
            return Err(StoreError(format!(
                "relay store schema {version} is newer than this Inline CLI supports ({SCHEMA_VERSION}); update Inline"
            )));
        }
        if version < 1 {
            connection.execute_batch(
                "BEGIN IMMEDIATE;
                 CREATE TABLE links (
                     remote_id TEXT NOT NULL,
                     part TEXT NOT NULL,
                     inline_id INTEGER,
                     origin TEXT NOT NULL,
                     revision TEXT,
                     agent_reaction TEXT,
                     PRIMARY KEY (remote_id, part)
                 );
                 CREATE INDEX links_inline ON links(inline_id);
                 CREATE TABLE pending_sends (
                     request_id TEXT PRIMARY KEY,
                     inline_id INTEGER NOT NULL UNIQUE,
                     reply_to TEXT,
                     text TEXT NOT NULL,
                     media TEXT,
                     attempts INTEGER NOT NULL DEFAULT 0,
                     next_attempt_at INTEGER NOT NULL
                 );
                 CREATE TABLE inbound (
                     inline_id INTEGER PRIMARY KEY,
                     outcome TEXT NOT NULL,
                     at INTEGER NOT NULL
                 );
                 CREATE TABLE tasks (
                     task_id TEXT PRIMARY KEY,
                     inline_id INTEGER NOT NULL,
                     rendered TEXT NOT NULL
                 );
                 CREATE TABLE confirmations (
                     key TEXT PRIMARY KEY,
                     remote_id TEXT NOT NULL,
                     inline_id INTEGER NOT NULL,
                     state TEXT NOT NULL,
                     body TEXT NOT NULL
                 );
                 CREATE INDEX confirmations_inline ON confirmations(inline_id);
                 CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 PRAGMA user_version = 1;
                 COMMIT;",
            )?;
        }
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Reads a key.
    pub fn kv_get(&self, key: &str) -> StoreResult<Option<String>> {
        Ok(self
            .lock()
            .query_row("SELECT value FROM kv WHERE key = ?1", [key], |row| {
                row.get(0)
            })
            .optional()?)
    }

    /// Writes a key.
    pub fn kv_set(&self, key: &str, value: &str) -> StoreResult<()> {
        self.lock().execute(
            "INSERT INTO kv (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    /// Deletes a key.
    pub fn kv_delete(&self, key: &str) -> StoreResult<()> {
        self.lock()
            .execute("DELETE FROM kv WHERE key = ?1", [key])?;
        Ok(())
    }

    /// All keys with a prefix, sorted.
    pub fn kv_prefix(&self, prefix: &str) -> StoreResult<Vec<(String, String)>> {
        let connection = self.lock();
        let mut statement = connection.prepare(
            "SELECT key, value FROM kv WHERE substr(key, 1, length(?1)) = ?1 ORDER BY key",
        )?;
        let rows = statement.query_map([prefix], |row| Ok((row.get(0)?, row.get(1)?)))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Reads one link.
    pub fn link(&self, remote_id: &str, part: &str) -> StoreResult<Option<Link>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT remote_id, part, inline_id, origin, revision, agent_reaction
                 FROM links WHERE remote_id = ?1 AND part = ?2",
                params![remote_id, part],
                row_to_link,
            )
            .optional()?)
    }

    /// All links of one remote message.
    pub fn links(&self, remote_id: &str) -> StoreResult<Vec<Link>> {
        let connection = self.lock();
        let mut statement = connection.prepare(
            "SELECT remote_id, part, inline_id, origin, revision, agent_reaction
             FROM links WHERE remote_id = ?1 ORDER BY part",
        )?;
        let rows = statement.query_map([remote_id], row_to_link)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Inserts or replaces a link.
    pub fn put_link(&self, link: &Link) -> StoreResult<()> {
        self.lock().execute(
            "INSERT INTO links (remote_id, part, inline_id, origin, revision, agent_reaction)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(remote_id, part) DO UPDATE SET
                 inline_id = excluded.inline_id, origin = excluded.origin,
                 revision = excluded.revision, agent_reaction = excluded.agent_reaction",
            params![
                link.remote_id,
                link.part,
                link.inline_id,
                link.origin.as_str(),
                link.revision,
                link.agent_reaction
            ],
        )?;
        Ok(())
    }

    /// The remote message shown by an Inline message.
    pub fn remote_for_inline(&self, inline_id: i64) -> StoreResult<Option<String>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT remote_id FROM links WHERE inline_id = ?1
                 ORDER BY CASE part WHEN 'text' THEN 0 ELSE 1 END LIMIT 1",
                [inline_id],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// The Inline message that best represents a remote message (its text
    /// part, else its first mirrored part).
    pub fn inline_for_remote(&self, remote_id: &str) -> StoreResult<Option<i64>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT inline_id FROM links WHERE remote_id = ?1 AND inline_id IS NOT NULL
                 ORDER BY CASE part WHEN 'text' THEN 0 ELSE 1 END, part LIMIT 1",
                [remote_id],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// Reserves a send before contacting the remote. Returns `false` when this
    /// Inline message already has a reservation.
    pub fn reserve_send(&self, pending: &PendingSend) -> StoreResult<bool> {
        let changed = self.lock().execute(
            "INSERT OR IGNORE INTO pending_sends
                 (request_id, inline_id, reply_to, text, media, attempts, next_attempt_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                pending.request_id,
                pending.inline_id,
                pending.reply_to,
                pending.text,
                pending.media,
                pending.attempts,
                pending.next_attempt_at
            ],
        )?;
        Ok(changed == 1)
    }

    /// Records a failed attempt.
    pub fn defer_send(
        &self,
        request_id: &str,
        attempts: u32,
        next_attempt_at: i64,
    ) -> StoreResult<()> {
        self.lock().execute(
            "UPDATE pending_sends SET attempts = ?2, next_attempt_at = ?3 WHERE request_id = ?1",
            params![request_id, attempts, next_attempt_at],
        )?;
        Ok(())
    }

    /// Finds a reservation by correlation id.
    pub fn pending_by_request(&self, request_id: &str) -> StoreResult<Option<PendingSend>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT request_id, inline_id, reply_to, text, media, attempts, next_attempt_at
                 FROM pending_sends WHERE request_id = ?1",
                [request_id],
                row_to_pending,
            )
            .optional()?)
    }

    /// All reservations, oldest first.
    pub fn pending_sends(&self) -> StoreResult<Vec<PendingSend>> {
        let connection = self.lock();
        let mut statement = connection.prepare(
            "SELECT request_id, inline_id, reply_to, text, media, attempts, next_attempt_at
             FROM pending_sends ORDER BY inline_id",
        )?;
        let rows = statement.query_map([], row_to_pending)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Settles a reservation: drops it and, when delivered, links the owner's
    /// Inline message to the remote id. Atomic.
    pub fn settle_send(&self, request_id: &str, remote_id: Option<&str>) -> StoreResult<()> {
        let mut connection = self.lock();
        let transaction = connection.transaction()?;
        let inline_id: Option<i64> = transaction
            .query_row(
                "SELECT inline_id FROM pending_sends WHERE request_id = ?1",
                [request_id],
                |row| row.get(0),
            )
            .optional()?;
        transaction.execute(
            "DELETE FROM pending_sends WHERE request_id = ?1",
            [request_id],
        )?;
        if let (Some(inline_id), Some(remote_id)) = (inline_id, remote_id) {
            transaction.execute(
                "INSERT INTO links (remote_id, part, inline_id, origin, revision, agent_reaction)
                 VALUES (?1, 'text', ?2, 'inline', NULL, NULL)
                 ON CONFLICT(remote_id, part) DO UPDATE SET inline_id = excluded.inline_id,
                     origin = 'inline'",
                params![remote_id, inline_id],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    /// Whether an inbound Inline message was already handled.
    pub fn inbound_handled(&self, inline_id: i64) -> StoreResult<bool> {
        Ok(self
            .lock()
            .query_row(
                "SELECT 1 FROM inbound WHERE inline_id = ?1",
                [inline_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// Marks an inbound Inline message handled. Returns `false` if it already was.
    pub fn mark_inbound(&self, inline_id: i64, outcome: &str, at: i64) -> StoreResult<bool> {
        let changed = self.lock().execute(
            "INSERT OR IGNORE INTO inbound (inline_id, outcome, at) VALUES (?1, ?2, ?3)",
            params![inline_id, outcome, at],
        )?;
        Ok(changed == 1)
    }

    /// Task card for a task.
    pub fn task(&self, task_id: &str) -> StoreResult<Option<(i64, String)>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT inline_id, rendered FROM tasks WHERE task_id = ?1",
                [task_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?)
    }

    /// Records a task card's rendering.
    pub fn put_task(&self, task_id: &str, inline_id: i64, rendered: &str) -> StoreResult<()> {
        self.lock().execute(
            "INSERT INTO tasks (task_id, inline_id, rendered) VALUES (?1, ?2, ?3)
             ON CONFLICT(task_id) DO UPDATE SET inline_id = excluded.inline_id,
                 rendered = excluded.rendered",
            params![task_id, inline_id, rendered],
        )?;
        Ok(())
    }

    /// Confirmation card by key.
    pub fn confirmation(&self, key: &str) -> StoreResult<Option<ConfirmationCard>> {
        Ok(self
            .lock()
            .query_row(
                "SELECT key, remote_id, inline_id, state, body FROM confirmations WHERE key = ?1",
                [key],
                row_to_confirmation,
            )
            .optional()?)
    }

    /// Records a new confirmation card.
    pub fn put_confirmation(&self, card: &ConfirmationCard) -> StoreResult<()> {
        self.lock().execute(
            "INSERT INTO confirmations (key, remote_id, inline_id, state, body)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(key) DO UPDATE SET inline_id = excluded.inline_id,
                 state = excluded.state, body = excluded.body",
            params![
                card.key,
                card.remote_id,
                card.inline_id,
                card.state.as_str(),
                card.body
            ],
        )?;
        Ok(())
    }

    /// Moves a card from `from` to `to`. Returns `false` when it was not in
    /// `from` (someone else claimed it).
    pub fn transition_confirmation(
        &self,
        key: &str,
        from: ConfirmationState,
        to: ConfirmationState,
    ) -> StoreResult<bool> {
        let changed = self.lock().execute(
            "UPDATE confirmations SET state = ?3 WHERE key = ?1 AND state = ?2",
            params![key, from.as_str(), to.as_str()],
        )?;
        Ok(changed == 1)
    }

    /// Cards in a given state.
    pub fn confirmations_in(&self, state: ConfirmationState) -> StoreResult<Vec<ConfirmationCard>> {
        let connection = self.lock();
        let mut statement = connection.prepare(
            "SELECT key, remote_id, inline_id, state, body FROM confirmations WHERE state = ?1",
        )?;
        let rows = statement.query_map([state.as_str()], row_to_confirmation)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }
}

fn row_to_link(row: &rusqlite::Row<'_>) -> rusqlite::Result<Link> {
    Ok(Link {
        remote_id: row.get(0)?,
        part: row.get(1)?,
        inline_id: row.get(2)?,
        origin: Origin::parse(&row.get::<_, String>(3)?),
        revision: row.get(4)?,
        agent_reaction: row.get(5)?,
    })
}

fn row_to_pending(row: &rusqlite::Row<'_>) -> rusqlite::Result<PendingSend> {
    Ok(PendingSend {
        request_id: row.get(0)?,
        inline_id: row.get(1)?,
        reply_to: row.get(2)?,
        text: row.get(3)?,
        media: row.get(4)?,
        attempts: row.get(5)?,
        next_attempt_at: row.get(6)?,
    })
}

fn row_to_confirmation(row: &rusqlite::Row<'_>) -> rusqlite::Result<ConfirmationCard> {
    Ok(ConfirmationCard {
        key: row.get(0)?,
        remote_id: row.get(1)?,
        inline_id: row.get(2)?,
        state: ConfirmationState::parse(&row.get::<_, String>(3)?),
        body: row.get(4)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn send_reservation_settles_into_link() {
        let store = RelayStore::open_in_memory().unwrap();
        let pending = PendingSend {
            request_id: "r1".into(),
            inline_id: 10,
            reply_to: None,
            text: "hi".into(),
            media: None,
            attempts: 0,
            next_attempt_at: 0,
        };
        assert!(store.reserve_send(&pending).unwrap());
        assert!(
            !store.reserve_send(&pending).unwrap(),
            "same inline message twice"
        );
        store.settle_send("r1", Some("m1")).unwrap();
        assert!(store.pending_sends().unwrap().is_empty());
        assert_eq!(store.inline_for_remote("m1").unwrap(), Some(10));
        assert_eq!(store.remote_for_inline(10).unwrap().as_deref(), Some("m1"));
    }

    #[test]
    fn confirmation_claim_is_exclusive() {
        let store = RelayStore::open_in_memory().unwrap();
        store
            .put_confirmation(&ConfirmationCard {
                key: "k".into(),
                remote_id: "m".into(),
                inline_id: 5,
                state: ConfirmationState::Open,
                body: "b".into(),
            })
            .unwrap();
        assert!(
            store
                .transition_confirmation("k", ConfirmationState::Open, ConfirmationState::Answering)
                .unwrap()
        );
        assert!(
            !store
                .transition_confirmation("k", ConfirmationState::Open, ConfirmationState::Answering)
                .unwrap()
        );
    }

    #[test]
    fn reopening_keeps_state() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("relay.sqlite");
        {
            let store = RelayStore::open(&path).unwrap();
            store.kv_set("checkpoint", "c1").unwrap();
            assert!(store.mark_inbound(7, "sent", 1).unwrap());
        }
        let store = RelayStore::open(&path).unwrap();
        assert_eq!(store.kv_get("checkpoint").unwrap().as_deref(), Some("c1"));
        assert!(store.inbound_handled(7).unwrap());
        assert!(!store.mark_inbound(7, "sent", 2).unwrap());
    }
}

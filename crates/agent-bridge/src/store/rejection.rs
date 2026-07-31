//! Bounded rate limiting for generic unauthorized direct-message notices.

use rusqlite::{Connection, OptionalExtension, params};

use super::*;

const MAX_REJECTION_SENDERS: usize = 256;

impl BridgeStore {
    /// Claims one generic DM notice per sender/window. Shared-chat rejection is
    /// handled silently and never calls this method.
    pub fn claim_unauthorized_dm_notice(
        &self,
        sender_user_id: i64,
        now: i64,
        window_seconds: i64,
    ) -> StoreResult<bool> {
        if sender_user_id <= 0 || window_seconds <= 0 {
            return Ok(false);
        }
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let previous = transaction
            .query_row(
                "SELECT last_sent_at FROM unauthorized_dm_notices
                 WHERE sender_user_id = ?1",
                params![sender_user_id],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        if previous.is_some_and(|sent_at| now.saturating_sub(sent_at) < window_seconds) {
            transaction.commit()?;
            return Ok(false);
        }
        transaction.execute(
            "INSERT INTO unauthorized_dm_notices (sender_user_id, last_sent_at)
             VALUES (?1, ?2)
             ON CONFLICT(sender_user_id) DO UPDATE SET last_sent_at = excluded.last_sent_at",
            params![sender_user_id, now],
        )?;
        transaction.execute(
            "DELETE FROM unauthorized_dm_notices
             WHERE sender_user_id IN (
                SELECT sender_user_id FROM unauthorized_dm_notices
                ORDER BY last_sent_at DESC, sender_user_id DESC
                LIMIT -1 OFFSET ?1
             )",
            params![i64::try_from(MAX_REJECTION_SENDERS).unwrap_or(i64::MAX)],
        )?;
        transaction.commit()?;
        Ok(true)
    }
}

pub(super) fn migrate_v17(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE unauthorized_dm_notices (
            sender_user_id INTEGER PRIMARY KEY NOT NULL CHECK (sender_user_id > 0),
            last_sent_at INTEGER NOT NULL
         );
         PRAGMA user_version = 17;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejection_notices_are_rate_limited_and_bounded() {
        let store = BridgeStore::open_in_memory().expect("store");
        assert!(
            store
                .claim_unauthorized_dm_notice(7, 100, 60)
                .expect("first")
        );
        assert!(
            !store
                .claim_unauthorized_dm_notice(7, 159, 60)
                .expect("limited")
        );
        assert!(
            store
                .claim_unauthorized_dm_notice(7, 160, 60)
                .expect("next window")
        );
        for sender in 1..=300 {
            store
                .claim_unauthorized_dm_notice(sender, 1_000 + sender, 60)
                .expect("sender");
        }
        let connection = store.connection.lock().expect("store");
        let count: i64 = connection
            .query_row("SELECT COUNT(*) FROM unauthorized_dm_notices", [], |row| {
                row.get(0)
            })
            .expect("count");
        assert_eq!(count, MAX_REJECTION_SENDERS as i64);
    }
}

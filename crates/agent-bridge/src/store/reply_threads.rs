//! Durable per-chat reply-thread routing overrides.

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use super::{BridgeStore, StoreError, StoreResult};
use crate::InstallationId;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReplyThreadMode {
    #[default]
    Auto,
    On,
    Off,
}

impl ReplyThreadMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::On => "on",
            Self::Off => "off",
        }
    }

    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "auto" => Ok(Self::Auto),
            "on" => Ok(Self::On),
            "off" => Ok(Self::Off),
            _ => Err(StoreError::UnknownReplyThreadMode(value)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplyThreadOverride {
    pub installation_id: InstallationId,
    pub chat_id: i64,
    pub mode: ReplyThreadMode,
    pub revision: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReplyThreadOverrideUpdateOutcome {
    Applied(Option<ReplyThreadOverride>),
    Stale(Option<ReplyThreadOverride>),
}

impl BridgeStore {
    pub fn reply_thread_override(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
    ) -> StoreResult<Option<ReplyThreadOverride>> {
        if chat_id <= 0 {
            return Err(StoreError::InvalidReplyThreadScope);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        load_override(&connection, installation_id, chat_id)
    }

    /// Compare-and-swap one explicit chat override. `None` removes the
    /// override so the caller inherits its configured default.
    pub fn update_reply_thread_override(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
        expected_revision: Option<i64>,
        mode: Option<ReplyThreadMode>,
        now: i64,
    ) -> StoreResult<ReplyThreadOverrideUpdateOutcome> {
        if chat_id <= 0 {
            return Err(StoreError::InvalidReplyThreadScope);
        }
        if expected_revision.is_some_and(|revision| revision <= 0) {
            return Err(StoreError::InvalidSettingsRevision {
                revision: expected_revision.unwrap_or_default(),
            });
        }
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let current = load_override(&transaction, installation_id, chat_id)?;
        if current.as_ref().map(|record| record.revision) != expected_revision {
            transaction.commit()?;
            return Ok(ReplyThreadOverrideUpdateOutcome::Stale(current));
        }

        let applied = match mode {
            Some(mode) => {
                let revision = expected_revision.unwrap_or_default().checked_add(1).ok_or(
                    StoreError::InvalidSettingsRevision {
                        revision: expected_revision.unwrap_or_default(),
                    },
                )?;
                transaction.execute(
                    "INSERT INTO reply_thread_overrides (
                        installation_id, chat_id, mode, revision, updated_at
                     ) VALUES (?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT(installation_id, chat_id) DO UPDATE SET
                        mode = excluded.mode,
                        revision = excluded.revision,
                        updated_at = excluded.updated_at",
                    params![
                        installation_id.as_str(),
                        chat_id,
                        mode.as_str(),
                        revision,
                        now,
                    ],
                )?;
                Some(ReplyThreadOverride {
                    installation_id: installation_id.clone(),
                    chat_id,
                    mode,
                    revision,
                    updated_at: now,
                })
            }
            None => {
                transaction.execute(
                    "DELETE FROM reply_thread_overrides
                     WHERE installation_id = ?1 AND chat_id = ?2",
                    params![installation_id.as_str(), chat_id],
                )?;
                None
            }
        };
        transaction.commit()?;
        Ok(ReplyThreadOverrideUpdateOutcome::Applied(applied))
    }
}

fn load_override(
    connection: &Connection,
    installation_id: &InstallationId,
    chat_id: i64,
) -> StoreResult<Option<ReplyThreadOverride>> {
    let raw = connection
        .query_row(
            "SELECT mode, revision, updated_at
             FROM reply_thread_overrides
             WHERE installation_id = ?1 AND chat_id = ?2",
            params![installation_id.as_str(), chat_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()?;
    raw.map(|(mode, revision, updated_at)| {
        Ok(ReplyThreadOverride {
            installation_id: installation_id.clone(),
            chat_id,
            mode: ReplyThreadMode::parse(mode)?,
            revision,
            updated_at,
        })
    })
    .transpose()
}

pub(super) fn migrate_v19(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE reply_thread_overrides (
            installation_id TEXT NOT NULL,
            chat_id INTEGER NOT NULL CHECK (chat_id > 0),
            mode TEXT NOT NULL CHECK (mode IN ('auto', 'on', 'off')),
            revision INTEGER NOT NULL CHECK (revision > 0),
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (installation_id, chat_id),
            FOREIGN KEY (installation_id) REFERENCES installations(installation_id)
                ON DELETE RESTRICT
         );
         PRAGMA user_version = 19;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{InstallationRecord, ProviderId};

    fn installation() -> InstallationId {
        InstallationId::new("codex").expect("installation")
    }

    fn store() -> BridgeStore {
        let store = BridgeStore::open_in_memory().expect("store");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation(),
                provider_id: ProviderId::new("codex").expect("provider"),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation record");
        store
    }

    #[test]
    fn explicit_auto_is_distinct_from_inheriting_the_default() {
        let store = store();
        let installation = installation();
        assert_eq!(store.reply_thread_override(&installation, 7).unwrap(), None);

        let applied = store
            .update_reply_thread_override(&installation, 7, None, Some(ReplyThreadMode::Auto), 2)
            .unwrap();
        let ReplyThreadOverrideUpdateOutcome::Applied(Some(record)) = applied else {
            panic!("expected explicit override");
        };
        assert_eq!(record.mode, ReplyThreadMode::Auto);
        assert_eq!(record.revision, 1);

        assert!(matches!(
            store.update_reply_thread_override(
                &installation,
                7,
                None,
                Some(ReplyThreadMode::On),
                3,
            ),
            Ok(ReplyThreadOverrideUpdateOutcome::Stale(Some(_)))
        ));

        assert_eq!(
            store
                .update_reply_thread_override(&installation, 7, Some(1), None, 4)
                .unwrap(),
            ReplyThreadOverrideUpdateOutcome::Applied(None)
        );
        assert_eq!(store.reply_thread_override(&installation, 7).unwrap(), None);
    }

    #[test]
    fn chat_overrides_are_isolated_and_revision_checked() {
        let store = store();
        let installation = installation();
        for (chat_id, mode) in [(7, ReplyThreadMode::On), (8, ReplyThreadMode::Off)] {
            assert!(matches!(
                store.update_reply_thread_override(&installation, chat_id, None, Some(mode), 2,),
                Ok(ReplyThreadOverrideUpdateOutcome::Applied(Some(_)))
            ));
        }
        assert_eq!(
            store
                .reply_thread_override(&installation, 7)
                .unwrap()
                .map(|record| record.mode),
            Some(ReplyThreadMode::On)
        );
        assert_eq!(
            store
                .reply_thread_override(&installation, 8)
                .unwrap()
                .map(|record| record.mode),
            Some(ReplyThreadMode::Off)
        );
    }
}

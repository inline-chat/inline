use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};

use crate::{BindingKey, InstallationId};

use super::{
    BridgeStore, StoreError, StoreResult, workspace::reject_conflicting_session_workspace,
};

const MAX_IMPORT_ID_BYTES: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HistoryImportState {
    Importing,
    Incomplete,
}

impl HistoryImportState {
    fn parse(value: String) -> StoreResult<Option<Self>> {
        match value.as_str() {
            "importing" => Ok(Some(Self::Importing)),
            "incomplete" => Ok(Some(Self::Incomplete)),
            "completed" => Ok(None),
            _ => Err(StoreError::UnknownHistoryImportState(value)),
        }
    }
}

impl BridgeStore {
    /// Atomically marks a reply thread as an active history import, binds it
    /// to the source workspace, and inherits the source chat settings. The
    /// guard is written in the same transaction as the routable chat binding
    /// so a process crash cannot expose a partially imported thread to a
    /// normal provider turn.
    pub fn begin_history_import_thread(
        &self,
        source: &BindingKey,
        target_chat_id: i64,
        import_id: &str,
        started_at: i64,
        lease_expires_at: i64,
    ) -> StoreResult<()> {
        validate_import(
            source,
            target_chat_id,
            import_id,
            started_at,
            lease_expires_at,
        )?;
        self.verified_workspace(&source.installation_id, &source.workspace_id, started_at)?;

        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        reject_conflicting_session_workspace(
            &transaction,
            &source.installation_id,
            target_chat_id,
            &source.workspace_id,
        )?;
        let changed = transaction.execute(
            "INSERT INTO history_import_threads (
                installation_id, chat_id, workspace_id, import_id, state,
                started_at, updated_at, lease_expires_at, completed_at
             ) VALUES (?1, ?2, ?3, ?4, 'importing', ?5, ?5, ?6, NULL)
             ON CONFLICT(installation_id, chat_id) DO UPDATE SET
                state = 'importing',
                updated_at = excluded.updated_at,
                lease_expires_at = excluded.lease_expires_at,
                completed_at = NULL
             WHERE history_import_threads.import_id = excluded.import_id
               AND history_import_threads.workspace_id = excluded.workspace_id
               AND history_import_threads.state IN ('importing', 'incomplete')",
            params![
                source.installation_id.as_str(),
                target_chat_id,
                source.workspace_id.as_str(),
                import_id,
                started_at,
                lease_expires_at,
            ],
        )?;
        if changed != 1 {
            return Err(StoreError::HistoryImportConflict {
                chat_id: target_chat_id,
            });
        }
        transaction.execute(
            "INSERT INTO chat_workspaces (
                installation_id, chat_id, workspace_id, updated_at
             ) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(installation_id, chat_id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                updated_at = excluded.updated_at",
            params![
                source.installation_id.as_str(),
                target_chat_id,
                source.workspace_id.as_str(),
                started_at,
            ],
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO chat_settings (
                installation_id, chat_id, workspace_id, model, reasoning,
                permissions, verbose, revision, updated_at
             )
             SELECT installation_id, ?4, workspace_id, model, reasoning,
                    permissions, verbose, 1, ?5
             FROM chat_settings
             WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
            params![
                source.installation_id.as_str(),
                source.chat_id,
                source.workspace_id.as_str(),
                target_chat_id,
                started_at,
            ],
        )?;
        let settings_exist = transaction.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM chat_settings
                WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
             )",
            params![
                source.installation_id.as_str(),
                target_chat_id,
                source.workspace_id.as_str(),
            ],
            |row| row.get::<_, bool>(0),
        )?;
        if !settings_exist {
            return Err(StoreError::MissingSettings {
                installation_id: source.installation_id.to_string(),
                chat_id: source.chat_id,
                workspace_id: source.workspace_id.to_string(),
            });
        }
        transaction.commit()?;
        Ok(())
    }

    /// Reads the durable guard for a thread. An abandoned importing lease is
    /// converted to incomplete rather than failed open, so bridge recreation
    /// can never turn a partial transcript into a normal provider thread.
    pub fn history_import_state(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
        now: i64,
    ) -> StoreResult<Option<HistoryImportState>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        transaction.execute(
            "UPDATE history_import_threads
             SET state = 'incomplete', updated_at = ?3
             WHERE installation_id = ?1 AND chat_id = ?2
               AND state = 'importing' AND lease_expires_at <= ?3",
            params![installation_id.as_str(), chat_id, now],
        )?;
        let state = transaction
            .query_row(
                "SELECT state FROM history_import_threads
                 WHERE installation_id = ?1 AND chat_id = ?2",
                params![installation_id.as_str(), chat_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .map(HistoryImportState::parse)
            .transpose()?
            .flatten();
        transaction.commit()?;
        Ok(state)
    }

    pub fn mark_history_import_incomplete(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
        import_id: &str,
        updated_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE history_import_threads
             SET state = 'incomplete', updated_at = ?4
             WHERE installation_id = ?1 AND chat_id = ?2 AND import_id = ?3
               AND state = 'importing'",
            params![installation_id.as_str(), chat_id, import_id, updated_at],
        )?;
        Ok(changed == 1)
    }

    pub fn complete_history_import(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
        import_id: &str,
        completed_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE history_import_threads
             SET state = 'completed', updated_at = ?4, completed_at = ?4
             WHERE installation_id = ?1 AND chat_id = ?2 AND import_id = ?3
               AND state IN ('importing', 'incomplete')",
            params![installation_id.as_str(), chat_id, import_id, completed_at],
        )?;
        Ok(changed == 1)
    }
}

fn validate_import(
    source: &BindingKey,
    target_chat_id: i64,
    import_id: &str,
    started_at: i64,
    lease_expires_at: i64,
) -> StoreResult<()> {
    if source.chat_id <= 0
        || target_chat_id <= 0
        || source.chat_id == target_chat_id
        || import_id.is_empty()
        || import_id.len() > MAX_IMPORT_ID_BYTES
        || import_id.chars().any(char::is_control)
        || lease_expires_at <= started_at
    {
        return Err(StoreError::InvalidIdentifier {
            kind: "history import",
            value: import_id.to_string(),
        });
    }
    Ok(())
}

pub(super) fn migrate_v23(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE history_import_threads (
            installation_id TEXT NOT NULL,
            chat_id INTEGER NOT NULL,
            workspace_id TEXT NOT NULL,
            import_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('importing', 'incomplete', 'completed')),
            started_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            lease_expires_at INTEGER NOT NULL,
            completed_at INTEGER,
            PRIMARY KEY (installation_id, chat_id),
            UNIQUE (installation_id, import_id),
            FOREIGN KEY (installation_id, workspace_id)
                REFERENCES workspaces(installation_id, workspace_id)
                ON DELETE RESTRICT
         );
         CREATE INDEX history_import_threads_open
         ON history_import_threads (installation_id, state, updated_at);
         PRAGMA user_version = 23;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{InstallationRecord, ProviderId, WorkspaceId};

    fn fixture() -> (BridgeStore, BindingKey, tempfile::TempDir) {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("claude-test").expect("installation");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: ProviderId::new("claude").expect("provider"),
                display_name: "Claude".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        let workspace = tempfile::tempdir().expect("workspace");
        let workspace_id = WorkspaceId::new("workspace-test").expect("workspace");
        store
            .select_workspace(&installation_id, &workspace_id, workspace.path(), 1)
            .expect("workspace");
        let source = BindingKey {
            installation_id,
            chat_id: 9,
            workspace_id,
        };
        store.chat_settings(&source, 1).expect("source settings");
        (store, source, workspace)
    }

    #[test]
    fn guard_binding_and_settings_are_committed_together() {
        let (store, source, _workspace) = fixture();
        store
            .begin_history_import_thread(&source, 42, "opaque", 10, 100)
            .expect("begin import");

        assert_eq!(
            store
                .history_import_state(&source.installation_id, 42, 11)
                .expect("state"),
            Some(HistoryImportState::Importing)
        );
        assert_eq!(
            store
                .bound_chat_workspace(&source.installation_id, 42)
                .expect("binding")
                .expect("bound")
                .workspace_id,
            source.workspace_id
        );
        store
            .chat_settings(
                &BindingKey {
                    installation_id: source.installation_id,
                    chat_id: 42,
                    workspace_id: source.workspace_id,
                },
                11,
            )
            .expect("inherited settings");
    }

    #[test]
    fn expired_importing_lease_fails_closed_until_completion() {
        let (store, source, _workspace) = fixture();
        store
            .begin_history_import_thread(&source, 42, "opaque", 10, 20)
            .expect("begin import");

        assert_eq!(
            store
                .history_import_state(&source.installation_id, 42, 20)
                .expect("stale state"),
            Some(HistoryImportState::Incomplete)
        );
        store
            .begin_history_import_thread(&source, 42, "opaque", 21, 40)
            .expect("retry import");
        assert_eq!(
            store
                .history_import_state(&source.installation_id, 42, 22)
                .expect("retried state"),
            Some(HistoryImportState::Importing)
        );
        assert!(
            store
                .complete_history_import(&source.installation_id, 42, "opaque", 30)
                .expect("complete")
        );
        assert_eq!(
            store
                .history_import_state(&source.installation_id, 42, 10_000)
                .expect("completed state"),
            None
        );
    }

    #[test]
    fn failed_begin_rolls_back_guard_and_binding_together() {
        let (store, source, _workspace) = fixture();
        let missing_source_settings = BindingKey {
            installation_id: source.installation_id.clone(),
            chat_id: 10,
            workspace_id: source.workspace_id,
        };

        assert!(matches!(
            store.begin_history_import_thread(&missing_source_settings, 42, "opaque", 10, 100,),
            Err(StoreError::MissingSettings { .. })
        ));
        assert_eq!(
            store
                .history_import_state(&source.installation_id, 42, 11)
                .expect("guard state"),
            None
        );
        assert_eq!(
            store
                .bound_chat_workspace(&source.installation_id, 42)
                .expect("binding"),
            None
        );
    }
}

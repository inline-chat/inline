//! Durable per-conversation agent settings and installation defaults.

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use super::*;
use crate::InstallationId;

const MAX_SETTING_VALUE_BYTES: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatSettingsRecord {
    pub binding: BindingKey,
    pub model: Option<String>,
    pub reasoning: Option<String>,
    pub permissions: Option<String>,
    pub verbose: bool,
    pub revision: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingsUpdateOutcome {
    Applied(ChatSettingsRecord),
    Stale(ChatSettingsRecord),
}

impl BridgeStore {
    /// Loads conversation settings, seeding a new workspace/session from the
    /// provider installation's most recently selected defaults.
    pub fn chat_settings(&self, binding: &BindingKey, now: i64) -> StoreResult<ChatSettingsRecord> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.unchecked_transaction()?;
        ensure_defaults(&transaction, &binding.installation_id, now)?;
        transaction.execute(
            "INSERT OR IGNORE INTO chat_settings (
                installation_id, chat_id, workspace_id, model, reasoning,
                permissions, verbose, revision, updated_at
             )
             SELECT ?1, ?2, ?3, model, reasoning, permissions, verbose, 1, ?4
             FROM installation_settings_defaults
             WHERE installation_id = ?1",
            params![
                binding.installation_id.as_str(),
                binding.chat_id,
                binding.workspace_id.as_str(),
                now,
            ],
        )?;
        let record =
            load_settings(&transaction, binding)?.ok_or_else(|| StoreError::MissingSettings {
                installation_id: binding.installation_id.to_string(),
                chat_id: binding.chat_id,
                workspace_id: binding.workspace_id.to_string(),
            })?;
        transaction.commit()?;
        Ok(record)
    }

    /// Seeds a newly created delivery conversation from the source chat's
    /// effective settings without changing installation defaults or replacing
    /// settings that the child already owns.
    pub fn inherit_chat_settings(
        &self,
        source: &BindingKey,
        target: &BindingKey,
        now: i64,
    ) -> StoreResult<ChatSettingsRecord> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.unchecked_transaction()?;
        ensure_defaults(&transaction, &source.installation_id, now)?;
        transaction.execute(
            "INSERT OR IGNORE INTO chat_settings (
                installation_id, chat_id, workspace_id, model, reasoning,
                permissions, verbose, revision, updated_at
             )
             SELECT ?4, ?5, ?6, model, reasoning, permissions, verbose, 1, ?7
             FROM chat_settings
             WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
            params![
                source.installation_id.as_str(),
                source.chat_id,
                source.workspace_id.as_str(),
                target.installation_id.as_str(),
                target.chat_id,
                target.workspace_id.as_str(),
                now,
            ],
        )?;
        let record =
            load_settings(&transaction, target)?.ok_or_else(|| StoreError::MissingSettings {
                installation_id: target.installation_id.to_string(),
                chat_id: target.chat_id,
                workspace_id: target.workspace_id.to_string(),
            })?;
        transaction.commit()?;
        Ok(record)
    }

    /// Compare-and-swap one full settings record and copy its values to the
    /// installation defaults for future, previously unbound conversations.
    pub fn update_chat_settings(
        &self,
        expected_revision: i64,
        next: &ChatSettingsRecord,
        now: i64,
    ) -> StoreResult<SettingsUpdateOutcome> {
        validate_setting("model", next.model.as_deref())?;
        validate_setting("reasoning", next.reasoning.as_deref())?;
        validate_setting("permissions", next.permissions.as_deref())?;
        let connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.unchecked_transaction()?;
        ensure_defaults(&transaction, &next.binding.installation_id, now)?;
        let current = load_settings(&transaction, &next.binding)?.ok_or_else(|| {
            StoreError::MissingSettings {
                installation_id: next.binding.installation_id.to_string(),
                chat_id: next.binding.chat_id,
                workspace_id: next.binding.workspace_id.to_string(),
            }
        })?;
        if current.revision != expected_revision {
            transaction.commit()?;
            return Ok(SettingsUpdateOutcome::Stale(current));
        }
        let revision = expected_revision.checked_add(1).ok_or_else(|| {
            StoreError::InvalidSettingsRevision {
                revision: expected_revision,
            }
        })?;
        let changed = transaction.execute(
            "UPDATE chat_settings SET
                model = ?4,
                reasoning = ?5,
                permissions = ?6,
                verbose = ?7,
                revision = ?8,
                updated_at = ?9
             WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
               AND revision = ?10",
            params![
                next.binding.installation_id.as_str(),
                next.binding.chat_id,
                next.binding.workspace_id.as_str(),
                next.model,
                next.reasoning,
                next.permissions,
                next.verbose,
                revision,
                now,
                expected_revision,
            ],
        )?;
        if changed != 1 {
            let current = load_settings(&transaction, &next.binding)?.ok_or_else(|| {
                StoreError::MissingSettings {
                    installation_id: next.binding.installation_id.to_string(),
                    chat_id: next.binding.chat_id,
                    workspace_id: next.binding.workspace_id.to_string(),
                }
            })?;
            transaction.commit()?;
            return Ok(SettingsUpdateOutcome::Stale(current));
        }
        transaction.execute(
            "UPDATE installation_settings_defaults SET
                model = ?2,
                reasoning = ?3,
                permissions = ?4,
                verbose = ?5,
                updated_at = ?6
             WHERE installation_id = ?1",
            params![
                next.binding.installation_id.as_str(),
                next.model,
                next.reasoning,
                next.permissions,
                next.verbose,
                now,
            ],
        )?;
        let applied = ChatSettingsRecord {
            binding: next.binding.clone(),
            model: next.model.clone(),
            reasoning: next.reasoning.clone(),
            permissions: next.permissions.clone(),
            verbose: next.verbose,
            revision,
            updated_at: now,
        };
        transaction.commit()?;
        Ok(SettingsUpdateOutcome::Applied(applied))
    }
}

pub(super) fn migrate_v5(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE installation_settings_defaults (
            installation_id TEXT PRIMARY KEY NOT NULL,
            model TEXT,
            reasoning TEXT,
            permissions TEXT,
            verbose INTEGER NOT NULL DEFAULT 0 CHECK (verbose IN (0, 1)),
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (installation_id) REFERENCES installations(installation_id)
                ON DELETE RESTRICT
         );
         CREATE TABLE chat_settings (
            installation_id TEXT NOT NULL,
            chat_id INTEGER NOT NULL,
            workspace_id TEXT NOT NULL,
            model TEXT,
            reasoning TEXT,
            permissions TEXT,
            verbose INTEGER NOT NULL DEFAULT 0 CHECK (verbose IN (0, 1)),
            revision INTEGER NOT NULL CHECK (revision > 0),
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (installation_id, chat_id, workspace_id),
            FOREIGN KEY (installation_id, workspace_id)
                REFERENCES workspaces(installation_id, workspace_id)
                ON DELETE RESTRICT
         );
         PRAGMA user_version = 5;
         COMMIT;",
    )?;
    Ok(())
}

fn ensure_defaults(
    transaction: &Transaction<'_>,
    installation_id: &InstallationId,
    now: i64,
) -> StoreResult<()> {
    transaction.execute(
        "INSERT OR IGNORE INTO installation_settings_defaults (
            installation_id, model, reasoning, permissions, verbose, updated_at
         ) VALUES (?1, NULL, NULL, NULL, 0, ?2)",
        params![installation_id.as_str(), now],
    )?;
    Ok(())
}

fn load_settings(
    transaction: &Transaction<'_>,
    binding: &BindingKey,
) -> StoreResult<Option<ChatSettingsRecord>> {
    let raw = transaction
        .query_row(
            "SELECT model, reasoning, permissions, verbose, revision, updated_at
             FROM chat_settings
             WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
            params![
                binding.installation_id.as_str(),
                binding.chat_id,
                binding.workspace_id.as_str(),
            ],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, bool>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            },
        )
        .optional()?;
    Ok(raw.map(
        |(model, reasoning, permissions, verbose, revision, updated_at)| ChatSettingsRecord {
            binding: binding.clone(),
            model,
            reasoning,
            permissions,
            verbose,
            revision,
            updated_at,
        },
    ))
}

fn validate_setting(kind: &'static str, value: Option<&str>) -> StoreResult<()> {
    if value.is_some_and(|value| {
        value.is_empty()
            || value.len() > MAX_SETTING_VALUE_BYTES
            || value.chars().any(char::is_control)
    }) {
        return Err(StoreError::InvalidSettingValue { kind });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{InstallationRecord, ProviderId, WorkspaceId};

    fn fixture() -> (BridgeStore, BindingKey) {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("codex").expect("installation");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation_id.clone(),
                provider_id: ProviderId::new("codex").expect("provider"),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        let workspace_id = WorkspaceId::new("workspace").expect("workspace");
        store
            .select_workspace(
                &installation_id,
                &workspace_id,
                &std::env::current_dir().expect("cwd"),
                1,
            )
            .expect("workspace");
        (
            store,
            BindingKey {
                installation_id,
                chat_id: 42,
                workspace_id,
            },
        )
    }

    #[test]
    fn settings_use_revision_compare_and_swap() {
        let (store, binding) = fixture();
        let current = store.chat_settings(&binding, 1).expect("settings");
        assert_eq!(current.revision, 1);
        assert!(!current.verbose);
        let mut next = current.clone();
        next.model = Some("gpt-5.4".to_string());
        next.reasoning = Some("high".to_string());
        next.verbose = true;
        let applied = store.update_chat_settings(1, &next, 2).expect("update");
        let SettingsUpdateOutcome::Applied(applied) = applied else {
            panic!("expected applied settings");
        };
        assert_eq!(applied.revision, 2);
        assert_eq!(applied.model.as_deref(), Some("gpt-5.4"));

        let stale = store
            .update_chat_settings(1, &next, 3)
            .expect("stale update");
        assert_eq!(stale, SettingsUpdateOutcome::Stale(applied));
    }

    #[test]
    fn selected_values_seed_new_conversation_defaults() {
        let (store, binding) = fixture();
        let mut current = store.chat_settings(&binding, 1).expect("settings");
        current.permissions = Some(":workspace".to_string());
        current.verbose = true;
        store
            .update_chat_settings(current.revision, &current, 2)
            .expect("update");

        let mut next_binding = binding.clone();
        next_binding.chat_id = 99;
        let seeded = store
            .chat_settings(&next_binding, 3)
            .expect("seeded settings");
        assert_eq!(seeded.permissions.as_deref(), Some(":workspace"));
        assert!(seeded.verbose);
        assert_eq!(seeded.revision, 1);
    }

    #[test]
    fn reply_thread_inherits_source_snapshot_once_without_overwriting_child_changes() {
        let (store, source) = fixture();
        let mut source_settings = store.chat_settings(&source, 1).expect("source settings");
        source_settings.model = Some("source-model".to_string());
        source_settings.verbose = true;
        store
            .update_chat_settings(source_settings.revision, &source_settings, 2)
            .expect("source update");
        let mut child = source.clone();
        child.chat_id = 99;
        let inherited = store
            .inherit_chat_settings(&source, &child, 3)
            .expect("inherit");
        assert_eq!(inherited.model.as_deref(), Some("source-model"));
        assert!(inherited.verbose);

        let mut child_settings = inherited;
        child_settings.model = Some("child-model".to_string());
        let applied = store
            .update_chat_settings(child_settings.revision, &child_settings, 4)
            .expect("child update");
        assert!(matches!(applied, SettingsUpdateOutcome::Applied(_)));
        let preserved = store
            .inherit_chat_settings(&source, &child, 5)
            .expect("preserve child");
        assert_eq!(preserved.model.as_deref(), Some("child-model"));
    }

    #[test]
    fn invalid_values_are_rejected_before_write() {
        let (store, binding) = fixture();
        let mut current = store.chat_settings(&binding, 1).expect("settings");
        current.model = Some("bad\nmodel".to_string());
        assert!(matches!(
            store.update_chat_settings(current.revision, &current, 2),
            Err(StoreError::InvalidSettingValue { kind: "model" })
        ));
    }
}

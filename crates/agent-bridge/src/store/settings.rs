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

/// The setting explicitly selected by the owner. A model change also resets
/// this conversation's reasoning selection. Future conversations also
/// clear the old model's reasoning selection when model changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChatSettingsField {
    Model,
    Reasoning,
    Permissions,
    Verbose,
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

    /// Materializes the typed Agent context stored on an Inline Chat without
    /// changing this installation's defaults. Missing selections intentionally
    /// reset model and reasoning to provider defaults for this Chat only.
    pub fn apply_agent_thread_configuration(
        &self,
        binding: &BindingKey,
        model: Option<&str>,
        reasoning: Option<&str>,
        now: i64,
    ) -> StoreResult<ChatSettingsRecord> {
        validate_setting("model", model)?;
        validate_setting("reasoning", reasoning)?;
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
        let current =
            load_settings(&transaction, binding)?.ok_or_else(|| StoreError::MissingSettings {
                installation_id: binding.installation_id.to_string(),
                chat_id: binding.chat_id,
                workspace_id: binding.workspace_id.to_string(),
            })?;
        if current.model.as_deref() == model && current.reasoning.as_deref() == reasoning {
            transaction.commit()?;
            return Ok(current);
        }
        transaction.execute(
            "UPDATE chat_settings SET model = ?4, reasoning = ?5,
                revision = revision + 1, updated_at = ?6
             WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
            params![
                binding.installation_id.as_str(),
                binding.chat_id,
                binding.workspace_id.as_str(),
                model,
                reasoning,
                now,
            ],
        )?;
        let updated =
            load_settings(&transaction, binding)?.ok_or_else(|| StoreError::MissingSettings {
                installation_id: binding.installation_id.to_string(),
                chat_id: binding.chat_id,
                workspace_id: binding.workspace_id.to_string(),
            })?;
        transaction.commit()?;
        Ok(updated)
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

    /// Compare-and-swap one explicitly selected setting. Inherited or
    /// provider-changed values on this conversation cannot overwrite the
    /// installation defaults for unrelated fields.
    pub fn update_chat_settings(
        &self,
        expected_revision: i64,
        next: &ChatSettingsRecord,
        field: ChatSettingsField,
        now: i64,
    ) -> StoreResult<SettingsUpdateOutcome> {
        match field {
            ChatSettingsField::Model => validate_setting("model", next.model.as_deref())?,
            ChatSettingsField::Reasoning => {
                validate_setting("reasoning", next.reasoning.as_deref())?
            }
            ChatSettingsField::Permissions => {
                validate_setting("permissions", next.permissions.as_deref())?
            }
            ChatSettingsField::Verbose => {}
        }
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
        let update_chat = match field {
            ChatSettingsField::Model => {
                "UPDATE chat_settings SET model = ?4, reasoning = NULL,
                    revision = ?5, updated_at = ?6
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                   AND revision = ?7"
            }
            ChatSettingsField::Reasoning => {
                "UPDATE chat_settings SET reasoning = ?4,
                    revision = ?5, updated_at = ?6
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                   AND revision = ?7"
            }
            ChatSettingsField::Permissions => {
                "UPDATE chat_settings SET permissions = ?4,
                    revision = ?5, updated_at = ?6
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                   AND revision = ?7"
            }
            ChatSettingsField::Verbose => {
                "UPDATE chat_settings SET verbose = ?4,
                    revision = ?5, updated_at = ?6
                 WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3
                   AND revision = ?7"
            }
        };
        let changed = match field {
            ChatSettingsField::Model => transaction.execute(
                update_chat,
                params![
                    next.binding.installation_id.as_str(),
                    next.binding.chat_id,
                    next.binding.workspace_id.as_str(),
                    next.model,
                    revision,
                    now,
                    expected_revision
                ],
            )?,
            ChatSettingsField::Reasoning => transaction.execute(
                update_chat,
                params![
                    next.binding.installation_id.as_str(),
                    next.binding.chat_id,
                    next.binding.workspace_id.as_str(),
                    next.reasoning,
                    revision,
                    now,
                    expected_revision
                ],
            )?,
            ChatSettingsField::Permissions => transaction.execute(
                update_chat,
                params![
                    next.binding.installation_id.as_str(),
                    next.binding.chat_id,
                    next.binding.workspace_id.as_str(),
                    next.permissions,
                    revision,
                    now,
                    expected_revision
                ],
            )?,
            ChatSettingsField::Verbose => transaction.execute(
                update_chat,
                params![
                    next.binding.installation_id.as_str(),
                    next.binding.chat_id,
                    next.binding.workspace_id.as_str(),
                    next.verbose,
                    revision,
                    now,
                    expected_revision
                ],
            )?,
        };
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
        match field {
            ChatSettingsField::Model => transaction.execute(
                "UPDATE installation_settings_defaults SET model = ?2, reasoning = NULL,
                    updated_at = ?3 WHERE installation_id = ?1",
                params![next.binding.installation_id.as_str(), next.model, now],
            )?,
            // Reasoning IDs belong to a model. An older chat can still use a
            // different model after another chat changes the launch default.
            ChatSettingsField::Reasoning => transaction.execute(
                "UPDATE installation_settings_defaults SET reasoning = ?2,
                    updated_at = ?3 WHERE installation_id = ?1 AND model IS ?4",
                params![
                    next.binding.installation_id.as_str(),
                    next.reasoning,
                    now,
                    current.model
                ],
            )?,
            ChatSettingsField::Permissions => transaction.execute(
                "UPDATE installation_settings_defaults SET permissions = ?2,
                    updated_at = ?3 WHERE installation_id = ?1",
                params![next.binding.installation_id.as_str(), next.permissions, now],
            )?,
            ChatSettingsField::Verbose => transaction.execute(
                "UPDATE installation_settings_defaults SET verbose = ?2,
                    updated_at = ?3 WHERE installation_id = ?1",
                params![next.binding.installation_id.as_str(), next.verbose, now],
            )?,
        };
        let applied = load_settings(&transaction, &next.binding)?.ok_or_else(|| {
            StoreError::MissingSettings {
                installation_id: next.binding.installation_id.to_string(),
                chat_id: next.binding.chat_id,
                workspace_id: next.binding.workspace_id.to_string(),
            }
        })?;
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
        let applied = store
            .update_chat_settings(1, &next, ChatSettingsField::Model, 2)
            .expect("update");
        let SettingsUpdateOutcome::Applied(applied) = applied else {
            panic!("expected applied settings");
        };
        assert_eq!(applied.revision, 2);
        assert_eq!(applied.model.as_deref(), Some("gpt-5.4"));

        let stale = store
            .update_chat_settings(1, &next, ChatSettingsField::Model, 3)
            .expect("stale update");
        assert_eq!(stale, SettingsUpdateOutcome::Stale(applied));
    }

    #[test]
    fn selected_values_seed_new_conversation_defaults() {
        let (store, binding) = fixture();
        let mut current = store.chat_settings(&binding, 1).expect("settings");
        current.permissions = Some(":workspace".to_string());
        store
            .update_chat_settings(
                current.revision,
                &current,
                ChatSettingsField::Permissions,
                2,
            )
            .expect("update");
        let mut current = store.chat_settings(&binding, 2).expect("updated settings");
        current.verbose = true;
        store
            .update_chat_settings(current.revision, &current, ChatSettingsField::Verbose, 3)
            .expect("update verbose");

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
    fn bound_agent_defaults_clear_model_and_reasoning_only() {
        let (store, binding) = fixture();
        let mut current = store.chat_settings(&binding, 1).expect("settings");
        current.model = Some("installation-model".to_string());
        store
            .update_chat_settings(current.revision, &current, ChatSettingsField::Model, 2)
            .expect("update defaults");
        let mut current = store.chat_settings(&binding, 2).expect("updated settings");
        current.reasoning = Some("high".to_string());
        store
            .update_chat_settings(current.revision, &current, ChatSettingsField::Reasoning, 3)
            .expect("update reasoning");
        let mut current = store.chat_settings(&binding, 3).expect("updated settings");
        current.permissions = Some(":workspace".to_string());
        store
            .update_chat_settings(
                current.revision,
                &current,
                ChatSettingsField::Permissions,
                4,
            )
            .expect("update permissions");
        let mut current = store.chat_settings(&binding, 4).expect("updated settings");
        current.verbose = true;
        store
            .update_chat_settings(current.revision, &current, ChatSettingsField::Verbose, 5)
            .expect("update verbose");

        let mut bound_chat = binding.clone();
        bound_chat.chat_id = 99;
        let applied = store
            .apply_agent_thread_configuration(&bound_chat, None, None, 3)
            .expect("apply Agent defaults");

        assert_eq!(applied.model, None);
        assert_eq!(applied.reasoning, None);
        assert_eq!(applied.permissions.as_deref(), Some(":workspace"));
        assert!(applied.verbose);
    }

    #[test]
    fn reply_thread_inherits_source_snapshot_once_without_overwriting_child_changes() {
        let (store, source) = fixture();
        let mut source_settings = store.chat_settings(&source, 1).expect("source settings");
        source_settings.model = Some("source-model".to_string());
        store
            .update_chat_settings(
                source_settings.revision,
                &source_settings,
                ChatSettingsField::Model,
                2,
            )
            .expect("source update");
        let mut source_settings = store.chat_settings(&source, 2).expect("source settings");
        source_settings.verbose = true;
        store
            .update_chat_settings(
                source_settings.revision,
                &source_settings,
                ChatSettingsField::Verbose,
                3,
            )
            .expect("source verbose update");
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
            .update_chat_settings(
                child_settings.revision,
                &child_settings,
                ChatSettingsField::Model,
                4,
            )
            .expect("child update");
        assert!(matches!(applied, SettingsUpdateOutcome::Applied(_)));
        let preserved = store
            .inherit_chat_settings(&source, &child, 5)
            .expect("preserve child");
        assert_eq!(preserved.model.as_deref(), Some("child-model"));
    }

    #[test]
    fn reasoning_defaults_follow_only_the_matching_model() {
        let (store, chat_a) = fixture();
        let mut a = store.chat_settings(&chat_a, 1).unwrap();
        a.model = Some("model-a".into());
        store
            .update_chat_settings(a.revision, &a, ChatSettingsField::Model, 2)
            .unwrap();
        let mut chat_b = chat_a.clone();
        chat_b.chat_id = 98;
        let mut b = store.chat_settings(&chat_b, 3).unwrap();
        b.model = Some("model-b".into());
        store
            .update_chat_settings(b.revision, &b, ChatSettingsField::Model, 4)
            .unwrap();
        let mut b = store.chat_settings(&chat_b, 5).unwrap();
        b.reasoning = Some("b-only".into());
        store
            .update_chat_settings(b.revision, &b, ChatSettingsField::Reasoning, 6)
            .unwrap();

        let mut a = store.chat_settings(&chat_a, 7).unwrap();
        a.reasoning = Some("a-only".into());
        // Unselected record fields cannot influence default propagation.
        a.model = Some("model-b".into());
        store
            .update_chat_settings(a.revision, &a, ChatSettingsField::Reasoning, 8)
            .unwrap();
        let a = store.chat_settings(&chat_a, 9).unwrap();
        assert_eq!(a.model.as_deref(), Some("model-a"));
        assert_eq!(a.reasoning.as_deref(), Some("a-only"));
        let mut future = chat_a.clone();
        future.chat_id = 99;
        let defaults = store.chat_settings(&future, 10).unwrap();
        assert_eq!(defaults.model.as_deref(), Some("model-b"));
        assert_eq!(defaults.reasoning.as_deref(), Some("b-only"));

        // An unset model is also a legitimate match, using NULL-safe SQL.
        let mut b = store.chat_settings(&chat_b, 11).unwrap();
        b.model = None;
        store
            .update_chat_settings(b.revision, &b, ChatSettingsField::Model, 12)
            .unwrap();
        let mut b = store.chat_settings(&chat_b, 13).unwrap();
        b.reasoning = Some("provider-default-effort".into());
        store
            .update_chat_settings(b.revision, &b, ChatSettingsField::Reasoning, 14)
            .unwrap();
        future.chat_id = 100;
        let defaults = store.chat_settings(&future, 15).unwrap();
        assert_eq!(defaults.model, None);
        assert_eq!(
            defaults.reasoning.as_deref(),
            Some("provider-default-effort")
        );
    }

    #[test]
    fn selected_field_updates_do_not_copy_child_configuration_into_installation_defaults() {
        let (store, source) = fixture();
        let mut source_settings = store.chat_settings(&source, 1).expect("source settings");
        source_settings.model = Some("model-a".to_string());
        store
            .update_chat_settings(
                source_settings.revision,
                &source_settings,
                ChatSettingsField::Model,
                2,
            )
            .expect("select model");
        let mut source_settings = store.chat_settings(&source, 2).expect("source settings");
        source_settings.reasoning = Some("high".to_string());
        store
            .update_chat_settings(
                source_settings.revision,
                &source_settings,
                ChatSettingsField::Reasoning,
                3,
            )
            .expect("select reasoning");
        let mut source_settings = store.chat_settings(&source, 3).expect("source settings");
        source_settings.permissions = Some("bypassPermissions".to_string());
        store
            .update_chat_settings(
                source_settings.revision,
                &source_settings,
                ChatSettingsField::Permissions,
                4,
            )
            .expect("select permissions");

        let mut child = source.clone();
        child.chat_id = 99;
        store
            .apply_agent_thread_configuration(&child, Some("model-b"), Some("low"), 5)
            .expect("materialize child Agent context");
        let mut child_settings = store.chat_settings(&child, 5).expect("child settings");
        child_settings.verbose = true;
        store
            .update_chat_settings(
                child_settings.revision,
                &child_settings,
                ChatSettingsField::Verbose,
                6,
            )
            .expect("select verbose");

        let mut future = source.clone();
        future.chat_id = 100;
        let seeded = store.chat_settings(&future, 7).expect("future settings");
        assert_eq!(seeded.model.as_deref(), Some("model-a"));
        assert_eq!(seeded.reasoning.as_deref(), Some("high"));
        assert_eq!(seeded.permissions.as_deref(), Some("bypassPermissions"));
        assert!(seeded.verbose);

        let mut child_settings = store.chat_settings(&child, 7).expect("child settings");
        child_settings.model = Some("model-c".to_string());
        store
            .update_chat_settings(
                child_settings.revision,
                &child_settings,
                ChatSettingsField::Model,
                8,
            )
            .expect("select a new model");
        let mut later = source.clone();
        later.chat_id = 101;
        let seeded = store.chat_settings(&later, 9).expect("later settings");
        assert_eq!(seeded.model.as_deref(), Some("model-c"));
        assert_eq!(
            seeded.reasoning, None,
            "old-model reasoning must not seed a new model"
        );
        assert_eq!(seeded.permissions.as_deref(), Some("bypassPermissions"));
        assert!(seeded.verbose);
    }

    #[test]
    fn same_value_permission_reselection_updates_future_launch_preference() {
        let (store, source) = fixture();
        let mut source_settings = store.chat_settings(&source, 1).expect("source settings");
        source_settings.permissions = Some("bypassPermissions".to_string());
        store
            .update_chat_settings(
                source_settings.revision,
                &source_settings,
                ChatSettingsField::Permissions,
                2,
            )
            .expect("first selection");
        let mut child = source.clone();
        child.chat_id = 99;
        let inherited = store
            .inherit_chat_settings(&source, &child, 3)
            .expect("child snapshot");

        source_settings = store.chat_settings(&source, 3).expect("source settings");
        source_settings.permissions = Some("default".to_string());
        store
            .update_chat_settings(
                source_settings.revision,
                &source_settings,
                ChatSettingsField::Permissions,
                4,
            )
            .expect("change launch preference");
        assert_eq!(inherited.permissions.as_deref(), Some("bypassPermissions"));
        store
            .update_chat_settings(
                inherited.revision,
                &inherited,
                ChatSettingsField::Permissions,
                5,
            )
            .expect("reselect same child value");
        let mut future = source.clone();
        future.chat_id = 100;
        assert_eq!(
            store
                .chat_settings(&future, 6)
                .expect("future settings")
                .permissions
                .as_deref(),
            Some("bypassPermissions")
        );
    }

    #[test]
    fn invalid_values_are_rejected_before_write() {
        let (store, binding) = fixture();
        let mut current = store.chat_settings(&binding, 1).expect("settings");
        current.model = Some("bad\nmodel".to_string());
        assert!(matches!(
            store.update_chat_settings(current.revision, &current, ChatSettingsField::Model, 2),
            Err(StoreError::InvalidSettingValue { kind: "model" })
        ));
    }
}

//! Durable reverse binding between one provider session and one Inline reply thread.

use rusqlite::{Connection, OptionalExtension, params};

use super::*;
use crate::{ProviderInstanceRef, ProviderSessionRef, WorkspaceId};

#[derive(Clone, PartialEq, Eq)]
pub struct SessionThreadBinding {
    session: ProviderSessionRef,
    workspace_id: WorkspaceId,
    parent_chat_id: i64,
    thread_chat_id: i64,
}

/// Durable intent used to recover the only non-atomic boundary in opening a
/// provider session: creating an Inline reply thread before its chat ID is
/// known locally. Reusing the same anchor makes Inline's create-or-return
/// reply-thread operation idempotent across bridge restarts.
#[derive(Clone, PartialEq, Eq)]
pub struct SessionThreadOpening {
    session: ProviderSessionRef,
    workspace_id: WorkspaceId,
    parent_chat_id: i64,
    anchor_message_id: i64,
}

impl SessionThreadOpening {
    pub fn new(
        session: ProviderSessionRef,
        workspace_id: WorkspaceId,
        parent_chat_id: i64,
        anchor_message_id: i64,
    ) -> StoreResult<Self> {
        if parent_chat_id <= 0 || anchor_message_id <= 0 {
            return Err(StoreError::InvalidSessionThreadBinding);
        }
        Ok(Self {
            session,
            workspace_id,
            parent_chat_id,
            anchor_message_id,
        })
    }

    pub fn session(&self) -> &ProviderSessionRef {
        &self.session
    }

    pub fn workspace_id(&self) -> &WorkspaceId {
        &self.workspace_id
    }

    pub fn parent_chat_id(&self) -> i64 {
        self.parent_chat_id
    }

    pub fn anchor_message_id(&self) -> i64 {
        self.anchor_message_id
    }
}

impl std::fmt::Debug for SessionThreadOpening {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionThreadOpening")
            .field("session", &self.session)
            .field("workspace_id", &self.workspace_id)
            .field("parent_chat_id", &self.parent_chat_id)
            .field("anchor_message_id", &self.anchor_message_id)
            .finish()
    }
}

impl SessionThreadBinding {
    pub fn new(
        session: ProviderSessionRef,
        workspace_id: WorkspaceId,
        parent_chat_id: i64,
        thread_chat_id: i64,
    ) -> StoreResult<Self> {
        if parent_chat_id <= 0 || thread_chat_id <= 0 {
            return Err(StoreError::InvalidSessionThreadBinding);
        }
        Ok(Self {
            session,
            workspace_id,
            parent_chat_id,
            thread_chat_id,
        })
    }

    pub fn session(&self) -> &ProviderSessionRef {
        &self.session
    }

    pub fn workspace_id(&self) -> &WorkspaceId {
        &self.workspace_id
    }

    pub fn parent_chat_id(&self) -> i64 {
        self.parent_chat_id
    }

    pub fn thread_chat_id(&self) -> i64 {
        self.thread_chat_id
    }
}

impl std::fmt::Debug for SessionThreadBinding {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionThreadBinding")
            .field("session", &self.session)
            .field("workspace_id", &self.workspace_id)
            .field("parent_chat_id", &self.parent_chat_id)
            .field("thread_chat_id", &self.thread_chat_id)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionThreadBindOutcome {
    Created(SessionThreadBinding),
    Existing(SessionThreadBinding),
}

impl SessionThreadBindOutcome {
    pub fn binding(&self) -> &SessionThreadBinding {
        match self {
            Self::Created(binding) | Self::Existing(binding) => binding,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionThreadPrepareOutcome {
    Bound(SessionThreadBinding),
    Opening(SessionThreadOpening),
}

impl SessionThreadPrepareOutcome {
    pub fn binding(&self) -> Option<&SessionThreadBinding> {
        match self {
            Self::Bound(binding) => Some(binding),
            Self::Opening(_) => None,
        }
    }

    pub fn opening(&self) -> Option<&SessionThreadOpening> {
        match self {
            Self::Bound(_) => None,
            Self::Opening(opening) => Some(opening),
        }
    }
}

impl BridgeStore {
    pub(crate) fn prepare_session_thread_opening(
        &self,
        proposed: &SessionThreadOpening,
        updated_at: i64,
    ) -> StoreResult<SessionThreadPrepareOutcome> {
        validate_opening(proposed)?;
        if updated_at < 0 {
            return Err(StoreError::InvalidSessionThreadBinding);
        }
        let installation_id = proposed.session.provider().installation_id();
        self.verified_workspace(installation_id, &proposed.workspace_id, updated_at)?;

        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        if let Some(existing) = read_by_session(&transaction, &proposed.session)? {
            if existing.workspace_id != proposed.workspace_id
                || existing.parent_chat_id != proposed.parent_chat_id
            {
                return Err(StoreError::SessionThreadBindingConflict {
                    thread_chat_id: existing.thread_chat_id,
                });
            }
            transaction.commit()?;
            return Ok(SessionThreadPrepareOutcome::Bound(existing));
        }
        if let Some(existing) = read_opening_by_session(&transaction, &proposed.session)? {
            if existing.workspace_id != proposed.workspace_id
                || existing.parent_chat_id != proposed.parent_chat_id
            {
                return Err(StoreError::SessionThreadOpeningConflict);
            }
            transaction.commit()?;
            return Ok(SessionThreadPrepareOutcome::Opening(existing));
        }
        let anchor_owned = transaction.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM session_thread_openings
                WHERE installation_id = ?1 AND parent_chat_id = ?2 AND anchor_message_id = ?3
             )",
            params![
                installation_id.as_str(),
                proposed.parent_chat_id,
                proposed.anchor_message_id,
            ],
            |row| row.get::<_, bool>(0),
        )?;
        if anchor_owned {
            return Err(StoreError::SessionThreadOpeningConflict);
        }
        transaction.execute(
            "INSERT INTO session_thread_openings (
                installation_id, provider_id, provider_session_id, workspace_id,
                parent_chat_id, anchor_message_id
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                installation_id.as_str(),
                proposed.session.provider().provider_id().as_str(),
                proposed.session.session_id().as_str(),
                proposed.workspace_id.as_str(),
                proposed.parent_chat_id,
                proposed.anchor_message_id,
            ],
        )?;
        transaction.commit()?;
        Ok(SessionThreadPrepareOutcome::Opening(proposed.clone()))
    }

    pub(crate) fn complete_session_thread_opening(
        &self,
        opening: &SessionThreadOpening,
        thread_chat_id: i64,
        session_configuration_fingerprint: Option<&str>,
        updated_at: i64,
    ) -> StoreResult<SessionThreadBindOutcome> {
        validate_opening(opening)?;
        let proposed = SessionThreadBinding::new(
            opening.session.clone(),
            opening.workspace_id.clone(),
            opening.parent_chat_id,
            thread_chat_id,
        )?;
        if updated_at < 0 {
            return Err(StoreError::InvalidSessionThreadBinding);
        }
        let installation_id = opening.session.provider().installation_id();
        self.verified_workspace(installation_id, &opening.workspace_id, updated_at)?;

        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        if let Some(existing) = read_by_session(&transaction, &opening.session)? {
            if existing.workspace_id != opening.workspace_id
                || existing.parent_chat_id != opening.parent_chat_id
            {
                return Err(StoreError::SessionThreadBindingConflict {
                    thread_chat_id: existing.thread_chat_id,
                });
            }
            delete_opening_for_session(&transaction, &opening.session)?;
            ensure_forward_chat_unowned_or_matches(&transaction, &existing)?;
            put_forward_binding(
                &transaction,
                &existing,
                session_configuration_fingerprint,
                updated_at,
            )?;
            put_chat_workspace(&transaction, &existing, updated_at)?;
            transaction.commit()?;
            return Ok(SessionThreadBindOutcome::Existing(existing));
        }
        let Some(stored_opening) = read_opening_by_session(&transaction, &opening.session)? else {
            return Err(StoreError::SessionThreadOpeningUnavailable);
        };
        if &stored_opening != opening {
            return Err(StoreError::SessionThreadOpeningConflict);
        }
        if let Some(existing) = read_by_chat(&transaction, installation_id, thread_chat_id)? {
            return Err(StoreError::SessionThreadBindingConflict {
                thread_chat_id: existing.thread_chat_id,
            });
        }
        ensure_forward_chat_unowned_or_matches(&transaction, &proposed)?;
        insert_reverse_binding(&transaction, &proposed)?;
        put_chat_workspace(&transaction, &proposed, updated_at)?;
        put_forward_binding(
            &transaction,
            &proposed,
            session_configuration_fingerprint,
            updated_at,
        )?;
        delete_opening(&transaction, opening)?;
        transaction.commit()?;
        Ok(SessionThreadBindOutcome::Created(proposed))
    }

    pub fn session_thread_binding(
        &self,
        session: &ProviderSessionRef,
    ) -> StoreResult<Option<SessionThreadBinding>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        read_by_session(&connection, session)
    }

    pub fn session_thread_binding_for_chat(
        &self,
        installation_id: &crate::InstallationId,
        thread_chat_id: i64,
    ) -> StoreResult<Option<SessionThreadBinding>> {
        if thread_chat_id <= 0 {
            return Err(StoreError::InvalidSessionThreadBinding);
        }
        let connection = self.connection.lock().expect("bridge store poisoned");
        read_by_chat(&connection, installation_id, thread_chat_id)
    }

    /// All Inline conversations already forwarding into one provider session.
    /// A new reverse session-thread owner must not be created while a legacy
    /// or ordinary conversation still owns that same provider identity.
    pub fn provider_session_binding_chats(
        &self,
        session: &ProviderSessionRef,
    ) -> StoreResult<Vec<i64>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let mut statement = connection.prepare(
            "SELECT DISTINCT chat_id
             FROM session_bindings
             WHERE installation_id = ?1 AND provider_id = ?2
               AND provider_session_id = ?3
             ORDER BY chat_id",
        )?;
        let chats = statement
            .query_map(
                params![
                    session.provider().installation_id().as_str(),
                    session.provider().provider_id().as_str(),
                    session.session_id().as_str(),
                ],
                |row| row.get::<_, i64>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(chats)
    }

    /// Commits the reverse session-to-thread owner and the existing forward
    /// turn binding in one local transaction. Provider transcript/checkpoint
    /// state is intentionally not copied into this table.
    pub(crate) fn bind_session_thread(
        &self,
        proposed: &SessionThreadBinding,
        session_configuration_fingerprint: Option<&str>,
        updated_at: i64,
    ) -> StoreResult<SessionThreadBindOutcome> {
        validate_binding(proposed)?;
        if updated_at < 0 {
            return Err(StoreError::InvalidSessionThreadBinding);
        }
        let installation_id = proposed.session.provider().installation_id();
        self.verified_workspace(installation_id, &proposed.workspace_id, updated_at)?;

        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        if let Some(existing) = read_by_session(&transaction, &proposed.session)? {
            if existing.workspace_id != proposed.workspace_id
                || existing.parent_chat_id != proposed.parent_chat_id
            {
                return Err(StoreError::SessionThreadBindingConflict {
                    thread_chat_id: existing.thread_chat_id,
                });
            }
            ensure_forward_chat_unowned_or_matches(&transaction, &existing)?;
            put_forward_binding(
                &transaction,
                &existing,
                session_configuration_fingerprint,
                updated_at,
            )?;
            put_chat_workspace(&transaction, &existing, updated_at)?;
            delete_opening_for_session(&transaction, &proposed.session)?;
            transaction.commit()?;
            return Ok(SessionThreadBindOutcome::Existing(existing));
        }
        if let Some(existing) =
            read_by_chat(&transaction, installation_id, proposed.thread_chat_id)?
        {
            return Err(StoreError::SessionThreadBindingConflict {
                thread_chat_id: existing.thread_chat_id,
            });
        }
        ensure_forward_chat_unowned_or_matches(&transaction, proposed)?;

        insert_reverse_binding(&transaction, proposed)?;
        put_chat_workspace(&transaction, proposed, updated_at)?;
        put_forward_binding(
            &transaction,
            proposed,
            session_configuration_fingerprint,
            updated_at,
        )?;
        delete_opening_for_session(&transaction, &proposed.session)?;
        transaction.commit()?;
        Ok(SessionThreadBindOutcome::Created(proposed.clone()))
    }
}

fn insert_reverse_binding(
    connection: &Connection,
    proposed: &SessionThreadBinding,
) -> StoreResult<()> {
    connection.execute(
        "INSERT INTO session_thread_bindings (
            installation_id, provider_id, provider_session_id, workspace_id,
            parent_chat_id, thread_chat_id
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            proposed.session.provider().installation_id().as_str(),
            proposed.session.provider().provider_id().as_str(),
            proposed.session.session_id().as_str(),
            proposed.workspace_id.as_str(),
            proposed.parent_chat_id,
            proposed.thread_chat_id,
        ],
    )?;
    Ok(())
}

fn delete_opening(connection: &Connection, opening: &SessionThreadOpening) -> StoreResult<()> {
    let changed = connection.execute(
        "DELETE FROM session_thread_openings
         WHERE installation_id = ?1 AND provider_id = ?2 AND provider_session_id = ?3
           AND workspace_id = ?4 AND parent_chat_id = ?5 AND anchor_message_id = ?6",
        params![
            opening.session.provider().installation_id().as_str(),
            opening.session.provider().provider_id().as_str(),
            opening.session.session_id().as_str(),
            opening.workspace_id.as_str(),
            opening.parent_chat_id,
            opening.anchor_message_id,
        ],
    )?;
    if changed != 1 {
        return Err(StoreError::SessionThreadOpeningUnavailable);
    }
    Ok(())
}

fn delete_opening_for_session(
    connection: &Connection,
    session: &ProviderSessionRef,
) -> StoreResult<()> {
    connection.execute(
        "DELETE FROM session_thread_openings
         WHERE installation_id = ?1 AND provider_id = ?2 AND provider_session_id = ?3",
        params![
            session.provider().installation_id().as_str(),
            session.provider().provider_id().as_str(),
            session.session_id().as_str(),
        ],
    )?;
    Ok(())
}

fn put_chat_workspace(
    connection: &Connection,
    binding: &SessionThreadBinding,
    updated_at: i64,
) -> StoreResult<()> {
    connection.execute(
        "INSERT INTO chat_workspaces (
                installation_id, chat_id, workspace_id, updated_at
             ) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(installation_id, chat_id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                updated_at = excluded.updated_at",
        params![
            binding.session.provider().installation_id().as_str(),
            binding.thread_chat_id,
            binding.workspace_id.as_str(),
            updated_at,
        ],
    )?;
    Ok(())
}

fn validate_binding(binding: &SessionThreadBinding) -> StoreResult<()> {
    if binding.parent_chat_id <= 0 || binding.thread_chat_id <= 0 {
        return Err(StoreError::InvalidSessionThreadBinding);
    }
    Ok(())
}

fn validate_opening(opening: &SessionThreadOpening) -> StoreResult<()> {
    if opening.parent_chat_id <= 0 || opening.anchor_message_id <= 0 {
        return Err(StoreError::InvalidSessionThreadBinding);
    }
    Ok(())
}

fn ensure_forward_chat_unowned_or_matches(
    connection: &Connection,
    binding: &SessionThreadBinding,
) -> StoreResult<()> {
    let conflicts = connection.query_row(
        "SELECT EXISTS(
            SELECT 1 FROM session_bindings
            WHERE installation_id = ?1 AND chat_id = ?2
              AND (
                workspace_id != ?3 OR provider_id != ?4 OR provider_session_id != ?5
              )
         )",
        params![
            binding.session.provider().installation_id().as_str(),
            binding.thread_chat_id,
            binding.workspace_id.as_str(),
            binding.session.provider().provider_id().as_str(),
            binding.session.session_id().as_str(),
        ],
        |row| row.get::<_, bool>(0),
    )?;
    if conflicts {
        return Err(StoreError::SessionThreadBindingConflict {
            thread_chat_id: binding.thread_chat_id,
        });
    }
    Ok(())
}

fn put_forward_binding(
    connection: &Connection,
    binding: &SessionThreadBinding,
    session_configuration_fingerprint: Option<&str>,
    updated_at: i64,
) -> StoreResult<()> {
    connection.execute(
        "INSERT INTO session_bindings (
            installation_id, chat_id, workspace_id, provider_id, provider_session_id,
            updated_at, session_configuration_fingerprint
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT (installation_id, chat_id, workspace_id) DO UPDATE SET
            provider_id = excluded.provider_id,
            provider_session_id = excluded.provider_session_id,
            updated_at = excluded.updated_at,
            session_configuration_fingerprint = excluded.session_configuration_fingerprint",
        params![
            binding.session.provider().installation_id().as_str(),
            binding.thread_chat_id,
            binding.workspace_id.as_str(),
            binding.session.provider().provider_id().as_str(),
            binding.session.session_id().as_str(),
            updated_at,
            session_configuration_fingerprint,
        ],
    )?;
    Ok(())
}

fn read_by_session(
    connection: &Connection,
    session: &ProviderSessionRef,
) -> StoreResult<Option<SessionThreadBinding>> {
    let raw = connection
        .query_row(
            "SELECT workspace_id, parent_chat_id, thread_chat_id
             FROM session_thread_bindings
             WHERE installation_id = ?1 AND provider_id = ?2 AND provider_session_id = ?3",
            params![
                session.provider().installation_id().as_str(),
                session.provider().provider_id().as_str(),
                session.session_id().as_str(),
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()?;
    raw.map(|(workspace_id, parent_chat_id, thread_chat_id)| {
        hydrate_binding(
            session.clone(),
            workspace_id,
            parent_chat_id,
            thread_chat_id,
        )
    })
    .transpose()
}

fn read_opening_by_session(
    connection: &Connection,
    session: &ProviderSessionRef,
) -> StoreResult<Option<SessionThreadOpening>> {
    let raw = connection
        .query_row(
            "SELECT workspace_id, parent_chat_id, anchor_message_id
             FROM session_thread_openings
             WHERE installation_id = ?1 AND provider_id = ?2 AND provider_session_id = ?3",
            params![
                session.provider().installation_id().as_str(),
                session.provider().provider_id().as_str(),
                session.session_id().as_str(),
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()?;
    raw.map(|(workspace_id, parent_chat_id, anchor_message_id)| {
        let opening = SessionThreadOpening {
            session: session.clone(),
            workspace_id: parse_workspace_id(workspace_id)?,
            parent_chat_id,
            anchor_message_id,
        };
        validate_opening(&opening)?;
        Ok(opening)
    })
    .transpose()
}

pub(super) fn read_by_chat(
    connection: &Connection,
    installation_id: &crate::InstallationId,
    thread_chat_id: i64,
) -> StoreResult<Option<SessionThreadBinding>> {
    let raw = connection
        .query_row(
            "SELECT provider_id, provider_session_id, workspace_id, parent_chat_id
             FROM session_thread_bindings
             WHERE installation_id = ?1 AND thread_chat_id = ?2",
            params![installation_id.as_str(), thread_chat_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        )
        .optional()?;
    raw.map(
        |(provider_id, provider_session_id, workspace_id, parent_chat_id)| {
            let provider =
                ProviderInstanceRef::new(installation_id.clone(), parse_provider_id(provider_id)?)
                    .map_err(|_| StoreError::InvalidSessionThreadBinding)?;
            let session =
                ProviderSessionRef::new(provider, parse_provider_session_id(provider_session_id)?)
                    .map_err(|_| StoreError::InvalidSessionThreadBinding)?;
            hydrate_binding(session, workspace_id, parent_chat_id, thread_chat_id)
        },
    )
    .transpose()
}

fn hydrate_binding(
    session: ProviderSessionRef,
    workspace_id: String,
    parent_chat_id: i64,
    thread_chat_id: i64,
) -> StoreResult<SessionThreadBinding> {
    let binding = SessionThreadBinding {
        session,
        workspace_id: parse_workspace_id(workspace_id)?,
        parent_chat_id,
        thread_chat_id,
    };
    validate_binding(&binding)?;
    Ok(binding)
}

pub(super) fn migrate_v24(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE session_thread_bindings (
            installation_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            provider_session_id TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            parent_chat_id INTEGER NOT NULL CHECK (parent_chat_id > 0),
            thread_chat_id INTEGER NOT NULL CHECK (thread_chat_id > 0),
            PRIMARY KEY (installation_id, provider_id, provider_session_id),
            UNIQUE (installation_id, thread_chat_id),
            FOREIGN KEY (installation_id, workspace_id)
                REFERENCES workspaces(installation_id, workspace_id)
                ON DELETE RESTRICT
         );
         PRAGMA user_version = 24;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v25(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE session_thread_openings (
            installation_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            provider_session_id TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            parent_chat_id INTEGER NOT NULL CHECK (parent_chat_id > 0),
            anchor_message_id INTEGER NOT NULL CHECK (anchor_message_id > 0),
            PRIMARY KEY (installation_id, provider_id, provider_session_id),
            UNIQUE (installation_id, parent_chat_id, anchor_message_id),
            FOREIGN KEY (installation_id, workspace_id)
                REFERENCES workspaces(installation_id, workspace_id)
                ON DELETE RESTRICT
         );
         PRAGMA user_version = 25;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{InstallationId, ProviderId, ProviderSessionId};

    fn setup() -> (BridgeStore, tempfile::TempDir, SessionThreadBinding) {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation = InstallationId::new("installation-1").expect("installation");
        store
            .put_installation(&InstallationRecord {
                installation_id: installation.clone(),
                provider_id: ProviderId::new("codex").expect("provider"),
                display_name: "Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("installation");
        let directory = tempfile::tempdir().expect("workspace");
        let workspace_id = WorkspaceId::new("workspace-1").expect("workspace");
        store
            .select_workspace(&installation, &workspace_id, directory.path(), 1)
            .expect("workspace");
        let provider =
            ProviderInstanceRef::new(installation, ProviderId::new("codex").expect("provider"))
                .expect("provider instance");
        let session = ProviderSessionRef::new(
            provider,
            ProviderSessionId::new("thread-1").expect("session"),
        )
        .expect("session ref");
        let binding =
            SessionThreadBinding::new(session, workspace_id, 10, 20).expect("thread binding");
        (store, directory, binding)
    }

    fn opening(binding: &SessionThreadBinding, anchor_message_id: i64) -> SessionThreadOpening {
        SessionThreadOpening::new(
            binding.session().clone(),
            binding.workspace_id().clone(),
            binding.parent_chat_id(),
            anchor_message_id,
        )
        .expect("thread opening")
    }

    #[test]
    fn durable_opening_reuses_its_first_anchor_and_completes_atomically() {
        let (store, _directory, binding) = setup();
        let first = opening(&binding, 11);
        let first_outcome = store
            .prepare_session_thread_opening(&first, 2)
            .expect("prepare first");
        assert_eq!(first_outcome.opening(), Some(&first));

        let later_picker = opening(&binding, 12);
        let recovered = store
            .prepare_session_thread_opening(&later_picker, 3)
            .expect("recover opening");
        assert_eq!(recovered.opening(), Some(&first));

        let completed = store
            .complete_session_thread_opening(&first, binding.thread_chat_id(), Some("tools-v1"), 4)
            .expect("complete opening");
        assert!(matches!(completed, SessionThreadBindOutcome::Created(_)));
        let duplicate_completion = store
            .complete_session_thread_opening(&first, binding.thread_chat_id(), Some("tools-v1"), 5)
            .expect("repeat completion after a competing process committed");
        assert!(matches!(
            duplicate_completion,
            SessionThreadBindOutcome::Existing(_)
        ));
        let reopened = store
            .prepare_session_thread_opening(&later_picker, 6)
            .expect("reopen bound session");
        assert_eq!(reopened.binding(), Some(&binding));
    }

    #[test]
    fn durable_opening_survives_a_bridge_store_restart() {
        let directory = tempfile::tempdir().expect("store directory");
        let database = directory.path().join("bridge.sqlite3");
        let workspace = directory.path().join("workspace");
        std::fs::create_dir(&workspace).expect("workspace");
        let installation = InstallationId::new("installation-1").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-1").expect("workspace id");
        let provider = ProviderInstanceRef::new(
            installation.clone(),
            ProviderId::new("codex").expect("provider"),
        )
        .expect("provider instance");
        let session = ProviderSessionRef::new(
            provider,
            ProviderSessionId::new("private-session").expect("session"),
        )
        .expect("session ref");
        let first = SessionThreadOpening::new(session.clone(), workspace_id.clone(), 10, 11)
            .expect("first opening");
        {
            let store = BridgeStore::open(&database).expect("store");
            store
                .put_installation(&InstallationRecord {
                    installation_id: installation.clone(),
                    provider_id: ProviderId::new("codex").expect("provider"),
                    display_name: "Codex".to_string(),
                    created_at: 1,
                    updated_at: 1,
                })
                .expect("installation");
            store
                .select_workspace(&installation, &workspace_id, &workspace, 1)
                .expect("workspace registration");
            store
                .prepare_session_thread_opening(&first, 2)
                .expect("prepare opening");
        }

        let store = BridgeStore::open(&database).expect("reopened store");
        let later =
            SessionThreadOpening::new(session, workspace_id, 10, 12).expect("later picker opening");
        let recovered = store
            .prepare_session_thread_opening(&later, 3)
            .expect("recover after restart");
        assert_eq!(
            recovered.opening().expect("opening").anchor_message_id(),
            11
        );
        let completed = store
            .complete_session_thread_opening(recovered.opening().expect("opening"), 20, None, 4)
            .expect("complete recovered opening");
        assert_eq!(completed.binding().thread_chat_id(), 20);
    }

    #[test]
    fn one_anchor_cannot_prepare_two_provider_sessions() {
        let (store, _directory, binding) = setup();
        let first = opening(&binding, 11);
        store
            .prepare_session_thread_opening(&first, 2)
            .expect("prepare first");
        let other_session = ProviderSessionRef::new(
            binding.session().provider().clone(),
            ProviderSessionId::new("thread-2").expect("other session"),
        )
        .expect("other session ref");
        let other = SessionThreadOpening::new(
            other_session,
            binding.workspace_id().clone(),
            binding.parent_chat_id(),
            11,
        )
        .expect("other opening");
        assert!(matches!(
            store.prepare_session_thread_opening(&other, 3),
            Err(StoreError::SessionThreadOpeningConflict)
        ));
    }

    #[test]
    fn binding_commits_reverse_forward_and_workspace_owners_atomically() {
        let (store, _directory, binding) = setup();
        let outcome = store
            .bind_session_thread(&binding, Some("tools-v1"), 2)
            .expect("bind");
        assert!(matches!(outcome, SessionThreadBindOutcome::Created(_)));
        assert_eq!(
            store
                .session_thread_binding(binding.session())
                .expect("reverse"),
            Some(binding.clone())
        );
        assert_eq!(
            store
                .provider_session_binding_chats(binding.session())
                .expect("forward owners"),
            vec![binding.thread_chat_id()]
        );
        assert_eq!(
            store
                .session_thread_binding_for_chat(
                    binding.session().provider().installation_id(),
                    binding.thread_chat_id(),
                )
                .expect("chat reverse"),
            Some(binding.clone())
        );
        assert_eq!(
            store
                .get_binding(&BindingKey {
                    installation_id: binding.session().provider().installation_id().clone(),
                    chat_id: binding.thread_chat_id(),
                    workspace_id: binding.workspace_id().clone(),
                })
                .expect("forward"),
            Some((
                binding.session().provider().provider_id().clone(),
                binding.session().session_id().clone(),
            ))
        );
        assert_eq!(
            store
                .get_binding_with_configuration(&BindingKey {
                    installation_id: binding.session().provider().installation_id().clone(),
                    chat_id: binding.thread_chat_id(),
                    workspace_id: binding.workspace_id().clone(),
                })
                .expect("configured forward")
                .and_then(|(_, _, fingerprint)| fingerprint),
            Some("tools-v1".to_string())
        );
        assert_eq!(
            store
                .chat_workspace(
                    binding.session().provider().installation_id(),
                    binding.thread_chat_id(),
                )
                .expect("workspace")
                .map(|workspace| workspace.workspace_id),
            Some(binding.workspace_id().clone())
        );
    }

    #[test]
    fn reopening_a_session_reuses_its_first_thread() {
        let (store, _directory, binding) = setup();
        store
            .bind_session_thread(&binding, None, 2)
            .expect("first bind");
        let proposed = SessionThreadBinding::new(
            binding.session().clone(),
            binding.workspace_id().clone(),
            binding.parent_chat_id(),
            21,
        )
        .expect("second proposal");
        let outcome = store
            .bind_session_thread(&proposed, Some("tools-v2"), 3)
            .expect("reopen");
        assert!(matches!(outcome, SessionThreadBindOutcome::Existing(_)));
        assert_eq!(outcome.binding().thread_chat_id(), binding.thread_chat_id());
        assert_eq!(
            store
                .session_thread_binding_for_chat(
                    binding.session().provider().installation_id(),
                    proposed.thread_chat_id(),
                )
                .expect("unused thread"),
            None
        );
        assert_eq!(
            store
                .get_binding_with_configuration(&BindingKey {
                    installation_id: binding.session().provider().installation_id().clone(),
                    chat_id: binding.thread_chat_id(),
                    workspace_id: binding.workspace_id().clone(),
                })
                .expect("configured forward")
                .and_then(|(_, _, fingerprint)| fingerprint),
            Some("tools-v2".to_string())
        );
    }

    #[test]
    fn one_reply_thread_cannot_be_rebound_to_another_provider_session() {
        let (store, _directory, binding) = setup();
        store
            .bind_session_thread(&binding, None, 2)
            .expect("first bind");
        let other_session = ProviderSessionRef::new(
            binding.session().provider().clone(),
            ProviderSessionId::new("thread-2").expect("session"),
        )
        .expect("session ref");
        let conflicting = SessionThreadBinding::new(
            other_session,
            binding.workspace_id().clone(),
            binding.parent_chat_id(),
            binding.thread_chat_id(),
        )
        .expect("conflicting binding");
        assert!(matches!(
            store.bind_session_thread(&conflicting, None, 3),
            Err(StoreError::SessionThreadBindingConflict { thread_chat_id: 20 })
        ));
    }

    #[test]
    fn a_legacy_forward_binding_in_another_workspace_blocks_reverse_ownership() {
        let (store, _directory, binding) = setup();
        let other_directory = tempfile::tempdir().expect("other workspace");
        let other_workspace = WorkspaceId::new("workspace-2").expect("other workspace");
        store
            .select_workspace(
                binding.session().provider().installation_id(),
                &other_workspace,
                other_directory.path(),
                2,
            )
            .expect("register other workspace");
        store
            .put_binding(
                &BindingKey {
                    installation_id: binding.session().provider().installation_id().clone(),
                    chat_id: binding.thread_chat_id(),
                    workspace_id: other_workspace,
                },
                binding.session().provider().provider_id(),
                &ProviderSessionId::new("legacy-session").expect("legacy session"),
                3,
            )
            .expect("legacy forward binding");

        assert!(matches!(
            store.bind_session_thread(&binding, None, 4),
            Err(StoreError::SessionThreadBindingConflict { thread_chat_id: 20 })
        ));
        assert_eq!(
            store
                .session_thread_binding(binding.session())
                .expect("reverse owner"),
            None
        );
    }

    #[test]
    fn generic_forward_writes_cannot_rotate_a_bound_reply_thread() {
        let (store, _directory, binding) = setup();
        store
            .bind_session_thread(&binding, None, 2)
            .expect("bind session thread");

        assert!(matches!(
            store.put_binding(
                &BindingKey {
                    installation_id: binding.session().provider().installation_id().clone(),
                    chat_id: binding.thread_chat_id(),
                    workspace_id: binding.workspace_id().clone(),
                },
                binding.session().provider().provider_id(),
                &ProviderSessionId::new("replacement-session").expect("replacement session"),
                3,
            ),
            Err(StoreError::SessionThreadBindingConflict { thread_chat_id: 20 })
        ));
        assert_eq!(
            store
                .get_binding(&BindingKey {
                    installation_id: binding.session().provider().installation_id().clone(),
                    chat_id: binding.thread_chat_id(),
                    workspace_id: binding.workspace_id().clone(),
                })
                .expect("forward owner"),
            Some((
                binding.session().provider().provider_id().clone(),
                binding.session().session_id().clone(),
            ))
        );
    }

    #[test]
    fn debug_output_never_contains_the_provider_session_id() {
        let (_store, _directory, binding) = setup();
        assert!(!format!("{binding:?}").contains("thread-1"));
        assert!(!format!("{:?}", opening(&binding, 11)).contains("thread-1"));
    }
}

//! Durable provider-installation metadata and local workspace recents.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};

use super::*;
use crate::{InstallationId, WorkspaceId};

pub const MAX_RECENT_WORKSPACES: usize = 8;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallationRecord {
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub display_name: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceFilesystemIdentity {
    pub device_id: u64,
    pub file_id: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct WorkspacePersistentIdentity {
    volume_uuid: [u8; 16],
    object_id: [u8; 8],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceRecord {
    pub installation_id: InstallationId,
    pub workspace_id: WorkspaceId,
    pub path: PathBuf,
    pub display_name: String,
    pub parent_hint: Option<String>,
    pub last_selected_at: i64,
    pub selection_order: i64,
    pub missing_since: Option<i64>,
    pub filesystem_identity: Option<WorkspaceFilesystemIdentity>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceChoice {
    pub workspace_id: WorkspaceId,
    pub display_name: String,
    pub parent_hint: Option<String>,
    pub selected: bool,
}

impl BridgeStore {
    pub fn put_installation(&self, record: &InstallationRecord) -> StoreResult<()> {
        let display_name = normalize_display_component(&record.display_name, "agent")?;
        let connection = self.connection.lock().expect("bridge store poisoned");
        connection.execute(
            "INSERT INTO installations (
                installation_id, provider_id, display_name, created_at, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(installation_id) DO UPDATE SET
                provider_id = excluded.provider_id,
                display_name = excluded.display_name,
                updated_at = excluded.updated_at",
            params![
                record.installation_id.as_str(),
                record.provider_id.as_str(),
                display_name,
                record.created_at,
                record.updated_at,
            ],
        )?;
        Ok(())
    }

    /// Registers or selects a canonical local workspace. The path stays only
    /// in the bridge's protected local database; clients receive opaque IDs
    /// and display metadata through `recent_workspace_choices`.
    pub fn select_workspace(
        &self,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
        path: &Path,
        selected_at: i64,
    ) -> StoreResult<WorkspaceRecord> {
        self.write_workspace(installation_id, workspace_id, path, selected_at, true)
    }

    /// Discovers a project without selecting it or replacing a saved filesystem
    /// identity. An existing conversation must never move just because a
    /// provider's project list changed.
    pub fn discover_workspace(
        &self,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
        path: &Path,
    ) -> StoreResult<()> {
        self.write_workspace(installation_id, workspace_id, path, 0, false)
            .map(|_| ())
    }

    fn write_workspace(
        &self,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
        path: &Path,
        selected_at: i64,
        select: bool,
    ) -> StoreResult<WorkspaceRecord> {
        let canonical_path = canonical_workspace_path(path)?;
        let filesystem_identity = workspace_filesystem_identity(&canonical_path)?;
        let persistent_identity = workspace_persistent_identity(&canonical_path);
        let path_text =
            canonical_path
                .to_str()
                .ok_or_else(|| StoreError::InvalidWorkspacePath {
                    path: path.display().to_string(),
                    reason: "path is not valid UTF-8",
                })?;
        let display_name = workspace_display_name(&canonical_path)?;
        let parent_hint = workspace_parent_hint(&canonical_path);
        let connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.unchecked_transaction()?;
        let selection_order = if select {
            transaction.query_row(
                "SELECT COALESCE(MAX(selection_order), 0) + 1 FROM workspaces
             WHERE installation_id = ?1",
                params![installation_id.as_str()],
                |row| row.get::<_, i64>(0),
            )?
        } else {
            0
        };
        let existing_id = transaction
            .query_row(
                "SELECT workspace_id FROM workspaces
                 WHERE installation_id = ?1 AND path = ?2",
                params![installation_id.as_str(), path_text],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(existing_id) = existing_id
            && existing_id != workspace_id.as_str()
        {
            return Err(StoreError::WorkspaceIdentityConflict {
                path: canonical_path.display().to_string(),
            });
        }
        transaction.execute(
            "INSERT INTO workspaces (
                installation_id, workspace_id, path, display_name, parent_hint,
                last_selected_at, selection_order, missing_since,
                filesystem_device_id, filesystem_file_id,
                filesystem_volume_uuid, filesystem_object_id
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, ?8, ?9, ?10, ?11)
             ON CONFLICT(installation_id, workspace_id) DO UPDATE SET
                path = excluded.path,
                display_name = excluded.display_name,
                parent_hint = excluded.parent_hint,
                last_selected_at = excluded.last_selected_at,
                selection_order = excluded.selection_order,
                missing_since = NULL,
                filesystem_device_id = excluded.filesystem_device_id,
                filesystem_file_id = excluded.filesystem_file_id,
                filesystem_volume_uuid = excluded.filesystem_volume_uuid,
                filesystem_object_id = excluded.filesystem_object_id
             WHERE ?12",
            params![
                installation_id.as_str(),
                workspace_id.as_str(),
                path_text,
                display_name,
                parent_hint,
                selected_at,
                selection_order,
                filesystem_identity
                    .as_ref()
                    .map(|identity| identity.device_id as i64),
                filesystem_identity
                    .as_ref()
                    .map(|identity| identity.file_id as i64),
                persistent_identity
                    .as_ref()
                    .map(|identity| identity.volume_uuid.as_slice()),
                persistent_identity
                    .as_ref()
                    .map(|identity| identity.object_id.as_slice()),
                select,
            ],
        )?;
        transaction.commit()?;
        Ok(WorkspaceRecord {
            installation_id: installation_id.clone(),
            workspace_id: workspace_id.clone(),
            path: canonical_path,
            display_name,
            parent_hint,
            last_selected_at: selected_at,
            selection_order,
            missing_since: None,
            filesystem_identity,
        })
    }

    pub fn workspace(
        &self,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
    ) -> StoreResult<Option<WorkspaceRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let raw = connection
            .query_row(
                "SELECT path, display_name, parent_hint, last_selected_at,
                        selection_order, missing_since, filesystem_device_id,
                        filesystem_file_id
                 FROM workspaces WHERE installation_id = ?1 AND workspace_id = ?2",
                params![installation_id.as_str(), workspace_id.as_str()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, Option<i64>>(5)?,
                        row.get::<_, Option<i64>>(6)?,
                        row.get::<_, Option<i64>>(7)?,
                    ))
                },
            )
            .optional()?;
        raw.map(
            |(
                path,
                display_name,
                parent_hint,
                last_selected_at,
                selection_order,
                missing_since,
                filesystem_device_id,
                filesystem_file_id,
            )| {
                Ok(WorkspaceRecord {
                    installation_id: installation_id.clone(),
                    workspace_id: workspace_id.clone(),
                    path: PathBuf::from(path),
                    display_name,
                    parent_hint,
                    last_selected_at,
                    selection_order,
                    missing_since,
                    filesystem_identity: parse_filesystem_identity(
                        filesystem_device_id,
                        filesystem_file_id,
                    )?,
                })
            },
        )
        .transpose()
    }

    pub fn default_workspace(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Option<WorkspaceRecord>> {
        Ok(self.recent_workspaces(installation_id, 1)?.pop())
    }

    /// Revalidates the registered canonical path and filesystem object before
    /// the provider receives it. A missing, redirected, or replaced root is
    /// failed closed and marked unavailable instead of silently changing the
    /// project in which an existing conversation executes.
    pub fn verified_workspace(
        &self,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
        checked_at: i64,
    ) -> StoreResult<WorkspaceRecord> {
        let mut record = self
            .workspace(installation_id, workspace_id)?
            .ok_or_else(|| StoreError::WorkspaceUnavailable {
                workspace_id: workspace_id.to_string(),
            })?;
        let verified_canonical_path = fs::canonicalize(&record.path)
            .ok()
            .filter(|canonical| canonical == &record.path && canonical.is_dir());
        let Some(verified_canonical_path) = verified_canonical_path else {
            self.mark_workspace_unavailable(installation_id, workspace_id, checked_at)?;
            return Err(StoreError::WorkspaceUnavailable {
                workspace_id: workspace_id.to_string(),
            });
        };
        let current_identity = workspace_filesystem_identity(&verified_canonical_path)
            .ok()
            .flatten();
        let stored_persistent_identity =
            self.workspace_persistent_identity(installation_id, workspace_id)?;
        let current_persistent_identity = workspace_persistent_identity(&verified_canonical_path);
        if !workspace_filesystem_identity_matches(
            record.filesystem_identity.as_ref(),
            current_identity.as_ref(),
            stored_persistent_identity.as_ref(),
            current_persistent_identity.as_ref(),
        ) {
            self.mark_workspace_unavailable(installation_id, workspace_id, checked_at)?;
            return Err(StoreError::WorkspaceUnavailable {
                workspace_id: workspace_id.to_string(),
            });
        }

        if record.missing_since.is_some()
            || record.filesystem_identity != current_identity
            || stored_persistent_identity != current_persistent_identity
        {
            let connection = self.connection.lock().expect("bridge store poisoned");
            connection.execute(
                "UPDATE workspaces SET missing_since = NULL,
                    filesystem_device_id = ?3, filesystem_file_id = ?4,
                    filesystem_volume_uuid = ?5, filesystem_object_id = ?6
                 WHERE installation_id = ?1 AND workspace_id = ?2",
                params![
                    installation_id.as_str(),
                    workspace_id.as_str(),
                    current_identity
                        .as_ref()
                        .map(|identity| identity.device_id as i64),
                    current_identity
                        .as_ref()
                        .map(|identity| identity.file_id as i64),
                    current_persistent_identity
                        .as_ref()
                        .map(|identity| identity.volume_uuid.as_slice()),
                    current_persistent_identity
                        .as_ref()
                        .map(|identity| identity.object_id.as_slice()),
                ],
            )?;
            record.missing_since = None;
            record.filesystem_identity = current_identity;
        }
        Ok(record)
    }

    fn workspace_persistent_identity(
        &self,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
    ) -> StoreResult<Option<WorkspacePersistentIdentity>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let raw = connection
            .query_row(
                "SELECT filesystem_volume_uuid, filesystem_object_id
                 FROM workspaces WHERE installation_id = ?1 AND workspace_id = ?2",
                params![installation_id.as_str(), workspace_id.as_str()],
                |row| {
                    Ok((
                        row.get::<_, Option<Vec<u8>>>(0)?,
                        row.get::<_, Option<Vec<u8>>>(1)?,
                    ))
                },
            )
            .optional()?;
        raw.map(|(volume_uuid, object_id)| parse_persistent_identity(volume_uuid, object_id))
            .transpose()
            .map(Option::flatten)
    }

    /// Makes one workspace current for a conversation without removing that
    /// conversation's session bindings for previously selected workspaces.
    pub fn bind_chat_workspace(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
        workspace_id: &WorkspaceId,
        updated_at: i64,
    ) -> StoreResult<WorkspaceRecord> {
        let record = self.verified_workspace(installation_id, workspace_id, updated_at)?;
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        reject_conflicting_session_workspace(&transaction, installation_id, chat_id, workspace_id)?;
        transaction.execute(
            "INSERT INTO chat_workspaces (
                installation_id, chat_id, workspace_id, updated_at
             ) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(installation_id, chat_id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                updated_at = excluded.updated_at",
            params![
                installation_id.as_str(),
                chat_id,
                workspace_id.as_str(),
                updated_at,
            ],
        )?;
        transaction.commit()?;
        Ok(record)
    }

    pub fn chat_workspace(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
    ) -> StoreResult<Option<WorkspaceRecord>> {
        Ok(self
            .bound_chat_workspace(installation_id, chat_id)?
            .filter(|record| record.missing_since.is_none()))
    }

    /// Returns the conversation's durable workspace binding even when that
    /// folder has been marked unavailable. Runtime routing uses this to avoid
    /// silently switching a conversation to a different project.
    pub fn bound_chat_workspace(
        &self,
        installation_id: &InstallationId,
        chat_id: i64,
    ) -> StoreResult<Option<WorkspaceRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let raw = connection
            .query_row(
                "SELECT workspaces.workspace_id, workspaces.path,
                        workspaces.display_name, workspaces.parent_hint,
                        workspaces.last_selected_at, workspaces.selection_order,
                        workspaces.missing_since, workspaces.filesystem_device_id,
                        workspaces.filesystem_file_id
                 FROM chat_workspaces
                 JOIN workspaces USING (installation_id, workspace_id)
                 WHERE chat_workspaces.installation_id = ?1
                   AND chat_workspaces.chat_id = ?2",
                params![installation_id.as_str(), chat_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, Option<i64>>(6)?,
                        row.get::<_, Option<i64>>(7)?,
                        row.get::<_, Option<i64>>(8)?,
                    ))
                },
            )
            .optional()?;
        raw.map(
            |(
                workspace_id,
                path,
                display_name,
                parent_hint,
                last_selected_at,
                selection_order,
                missing_since,
                filesystem_device_id,
                filesystem_file_id,
            )| {
                Ok(WorkspaceRecord {
                    installation_id: installation_id.clone(),
                    workspace_id: parse_workspace_id(workspace_id)?,
                    path: PathBuf::from(path),
                    display_name,
                    parent_hint,
                    last_selected_at,
                    selection_order,
                    missing_since,
                    filesystem_identity: parse_filesystem_identity(
                        filesystem_device_id,
                        filesystem_file_id,
                    )?,
                })
            },
        )
        .transpose()
    }

    pub fn recent_workspaces(
        &self,
        installation_id: &InstallationId,
        limit: usize,
    ) -> StoreResult<Vec<WorkspaceRecord>> {
        self.workspace_records(installation_id, limit.clamp(1, MAX_RECENT_WORKSPACES))
    }

    fn workspace_records(
        &self,
        installation_id: &InstallationId,
        limit: usize,
    ) -> StoreResult<Vec<WorkspaceRecord>> {
        let limit = limit as i64;
        let connection = self.connection.lock().expect("bridge store poisoned");
        let mut statement = connection.prepare(
            "SELECT workspace_id, path, display_name, parent_hint,
                    last_selected_at, selection_order, missing_since,
                    filesystem_device_id, filesystem_file_id
             FROM workspaces
             WHERE installation_id = ?1 AND missing_since IS NULL
             ORDER BY selection_order DESC, display_name COLLATE NOCASE, workspace_id
             LIMIT ?2",
        )?;
        let rows = statement.query_map(params![installation_id.as_str(), limit], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, Option<i64>>(6)?,
                row.get::<_, Option<i64>>(7)?,
                row.get::<_, Option<i64>>(8)?,
            ))
        })?;
        rows.map(|row| {
            let (
                workspace_id,
                path,
                display_name,
                parent_hint,
                last_selected_at,
                selection_order,
                missing_since,
                filesystem_device_id,
                filesystem_file_id,
            ) = row?;
            Ok(WorkspaceRecord {
                installation_id: installation_id.clone(),
                workspace_id: parse_workspace_id(workspace_id)?,
                path: PathBuf::from(path),
                display_name,
                parent_hint,
                last_selected_at,
                selection_order,
                missing_since,
                filesystem_identity: parse_filesystem_identity(
                    filesystem_device_id,
                    filesystem_file_id,
                )?,
            })
        })
        .collect()
    }

    pub fn recent_workspace_choices(
        &self,
        installation_id: &InstallationId,
        selected_workspace_id: Option<&WorkspaceId>,
    ) -> StoreResult<Vec<WorkspaceChoice>> {
        let records = self.recent_workspaces(installation_id, MAX_RECENT_WORKSPACES)?;
        Ok(workspace_choices(records, selected_workspace_id))
    }

    /// Full project browser, independent of the eight-entry quick picker.
    pub fn project_workspace_choices(
        &self,
        installation_id: &InstallationId,
        selected_workspace_id: Option<&WorkspaceId>,
    ) -> StoreResult<Vec<WorkspaceChoice>> {
        let records = self.workspace_records(installation_id, 1_001)?;
        if records.len() > 1_000 {
            return Err(StoreError::InvalidWorkspacePath {
                path: "project catalog".to_string(),
                reason: "the project catalog exceeds 1000 folders",
            });
        }
        Ok(workspace_choices(records, selected_workspace_id))
    }

    /// Marks one observed workspace unavailable while preserving its durable
    /// record and every session/chat binding that refers to it.
    pub fn mark_workspace_unavailable(
        &self,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
        checked_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE workspaces SET missing_since = ?3
             WHERE installation_id = ?1 AND workspace_id = ?2
               AND missing_since IS NULL",
            params![installation_id.as_str(), workspace_id.as_str(), checked_at],
        )?;
        Ok(changed == 1)
    }

    /// Removes missing folders from recents without deleting their historical
    /// session bindings. Returns folders newly marked unavailable.
    pub fn refresh_workspace_availability(
        &self,
        installation_id: &InstallationId,
        checked_at: i64,
    ) -> StoreResult<Vec<WorkspaceRecord>> {
        let records = {
            let connection = self.connection.lock().expect("bridge store poisoned");
            let mut statement = connection.prepare(
                "SELECT workspace_id, path, display_name, parent_hint,
                        last_selected_at, selection_order, missing_since,
                        filesystem_device_id, filesystem_file_id
                 FROM workspaces
                 WHERE installation_id = ?1",
            )?;
            statement
                .query_map(params![installation_id.as_str()], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, Option<i64>>(6)?,
                        row.get::<_, Option<i64>>(7)?,
                        row.get::<_, Option<i64>>(8)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut missing = Vec::new();
        for row in records {
            let (
                workspace_id,
                path,
                display_name,
                parent_hint,
                last_selected_at,
                selection_order,
                previous_missing_since,
                filesystem_device_id,
                filesystem_file_id,
            ) = row;
            let workspace_id = parse_workspace_id(workspace_id)?;
            match self.verified_workspace(installation_id, &workspace_id, checked_at) {
                Ok(_) => {}
                Err(StoreError::WorkspaceUnavailable { .. }) => {
                    if previous_missing_since.is_none() {
                        missing.push(WorkspaceRecord {
                            installation_id: installation_id.clone(),
                            workspace_id,
                            path: PathBuf::from(path),
                            display_name,
                            parent_hint,
                            last_selected_at,
                            selection_order,
                            missing_since: Some(checked_at),
                            filesystem_identity: parse_filesystem_identity(
                                filesystem_device_id,
                                filesystem_file_id,
                            )?,
                        });
                    }
                }
                Err(error) => return Err(error),
            }
        }
        Ok(missing)
    }
}

pub(super) fn reject_conflicting_session_workspace(
    transaction: &Transaction<'_>,
    installation_id: &InstallationId,
    chat_id: i64,
    workspace_id: &WorkspaceId,
) -> StoreResult<()> {
    let conflicts = transaction.query_row(
        "SELECT EXISTS(
            SELECT 1 FROM session_thread_bindings
            WHERE installation_id = ?1
              AND thread_chat_id = ?2
              AND workspace_id <> ?3
         )",
        params![installation_id.as_str(), chat_id, workspace_id.as_str()],
        |row| row.get::<_, bool>(0),
    )?;
    if conflicts {
        return Err(StoreError::SessionThreadBindingConflict {
            thread_chat_id: chat_id,
        });
    }
    Ok(())
}

fn workspace_choices(
    records: Vec<WorkspaceRecord>,
    selected_workspace_id: Option<&WorkspaceId>,
) -> Vec<WorkspaceChoice> {
    let mut name_counts = HashMap::<String, usize>::new();
    for record in &records {
        *name_counts.entry(record.display_name.clone()).or_default() += 1;
    }
    records
        .into_iter()
        .map(|record| WorkspaceChoice {
            selected: selected_workspace_id == Some(&record.workspace_id),
            workspace_id: record.workspace_id,
            parent_hint: (name_counts[record.display_name.as_str()] > 1)
                .then_some(record.parent_hint)
                .flatten(),
            display_name: record.display_name,
        })
        .collect()
}

pub(super) fn migrate_v4(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE installations (
            installation_id TEXT PRIMARY KEY NOT NULL,
            provider_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
         );
         CREATE TABLE workspaces (
            installation_id TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            path TEXT NOT NULL,
            display_name TEXT NOT NULL,
            parent_hint TEXT,
            last_selected_at INTEGER NOT NULL,
            selection_order INTEGER NOT NULL,
            missing_since INTEGER,
            PRIMARY KEY (installation_id, workspace_id),
            UNIQUE (installation_id, path),
            FOREIGN KEY (installation_id) REFERENCES installations(installation_id)
                ON DELETE RESTRICT
         );
         CREATE INDEX workspaces_recent
         ON workspaces (installation_id, missing_since, selection_order DESC);
         CREATE TABLE chat_workspaces (
            installation_id TEXT NOT NULL,
            chat_id INTEGER NOT NULL,
            workspace_id TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (installation_id, chat_id),
            FOREIGN KEY (installation_id, workspace_id)
                REFERENCES workspaces(installation_id, workspace_id)
                ON DELETE RESTRICT
         );
         PRAGMA user_version = 4;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v12(connection: &Connection) -> StoreResult<()> {
    let transaction = connection.unchecked_transaction()?;
    transaction.execute_batch(
        "ALTER TABLE workspaces ADD COLUMN filesystem_device_id INTEGER;
         ALTER TABLE workspaces ADD COLUMN filesystem_file_id INTEGER;",
    )?;
    let rows = {
        let mut statement =
            transaction.prepare("SELECT installation_id, workspace_id, path FROM workspaces")?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (installation_id, workspace_id, path) in rows {
        let path = PathBuf::from(path);
        let canonical = canonical_workspace_path(&path).ok();
        let identity = canonical
            .as_ref()
            .and_then(|canonical| workspace_filesystem_identity(canonical).ok())
            .flatten();
        match identity {
            Some(identity) => {
                transaction.execute(
                    "UPDATE workspaces SET path = ?3, filesystem_device_id = ?4,
                        filesystem_file_id = ?5
                     WHERE installation_id = ?1 AND workspace_id = ?2",
                    params![
                        installation_id,
                        workspace_id,
                        canonical.and_then(|path| path.to_str().map(str::to_string)),
                        identity.device_id as i64,
                        identity.file_id as i64,
                    ],
                )?;
            }
            None => {
                transaction.execute(
                    "UPDATE workspaces SET missing_since = COALESCE(missing_since, 0)
                     WHERE installation_id = ?1 AND workspace_id = ?2",
                    params![installation_id, workspace_id],
                )?;
            }
        }
    }
    transaction.pragma_update(None, "user_version", 12)?;
    transaction.commit()?;
    Ok(())
}

pub(super) fn migrate_v26(connection: &Connection) -> StoreResult<()> {
    let rows = {
        let mut statement = connection.prepare(
            "SELECT installation_id, workspace_id, path,
                    filesystem_device_id, filesystem_file_id
             FROM workspaces",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    // Filesystem and getattrlist calls can block on removable or network
    // volumes. Resolve the optional backfill before opening SQLite's exclusive
    // migration transaction so bridge state is never locked behind I/O.
    let backfills = rows
        .into_iter()
        .filter_map(
            |(installation_id, workspace_id, path, stored_device_id, stored_file_id)| {
                let canonical = canonical_workspace_path(&PathBuf::from(path)).ok()?;
                let current_identity = workspace_filesystem_identity(&canonical).ok().flatten()?;
                if Some(current_identity.device_id as i64) != stored_device_id
                    || Some(current_identity.file_id as i64) != stored_file_id
                {
                    return None;
                }
                let persistent_identity = workspace_persistent_identity(&canonical)?;
                Some((
                    installation_id,
                    workspace_id,
                    current_identity,
                    persistent_identity,
                ))
            },
        )
        .collect::<Vec<_>>();
    let transaction = connection.unchecked_transaction()?;
    transaction.execute_batch(
        "ALTER TABLE workspaces ADD COLUMN filesystem_volume_uuid BLOB;
         ALTER TABLE workspaces ADD COLUMN filesystem_object_id BLOB;",
    )?;
    for (installation_id, workspace_id, current_identity, persistent_identity) in backfills {
        transaction.execute(
            "UPDATE workspaces
                 SET filesystem_device_id = ?3, filesystem_file_id = ?4,
                     filesystem_volume_uuid = ?5, filesystem_object_id = ?6,
                     missing_since = NULL
                 WHERE installation_id = ?1 AND workspace_id = ?2",
            params![
                installation_id,
                workspace_id,
                current_identity.device_id as i64,
                current_identity.file_id as i64,
                persistent_identity.volume_uuid.as_slice(),
                persistent_identity.object_id.as_slice(),
            ],
        )?;
    }
    transaction.pragma_update(None, "user_version", 26)?;
    transaction.commit()?;
    Ok(())
}

fn canonical_workspace_path(path: &Path) -> StoreResult<PathBuf> {
    if !path.is_absolute() {
        return Err(StoreError::InvalidWorkspacePath {
            path: path.display().to_string(),
            reason: "path must be absolute and canonical",
        });
    }
    if path.parent().is_none() {
        return Err(StoreError::InvalidWorkspacePath {
            path: path.display().to_string(),
            reason: "filesystem root cannot be a workspace",
        });
    }
    let canonical = fs::canonicalize(path).map_err(|_| StoreError::InvalidWorkspacePath {
        path: path.display().to_string(),
        reason: "path is not an existing directory",
    })?;
    if canonical.parent().is_none() {
        return Err(StoreError::InvalidWorkspacePath {
            path: path.display().to_string(),
            reason: "filesystem root cannot be a workspace",
        });
    }
    if !canonical.is_dir() {
        return Err(StoreError::InvalidWorkspacePath {
            path: path.display().to_string(),
            reason: "path is not an existing directory",
        });
    }
    Ok(canonical)
}

#[cfg(unix)]
fn workspace_filesystem_identity(path: &Path) -> StoreResult<Option<WorkspaceFilesystemIdentity>> {
    use std::os::unix::fs::MetadataExt;

    let metadata = fs::metadata(path)?;
    Ok(Some(WorkspaceFilesystemIdentity {
        device_id: metadata.dev(),
        file_id: metadata.ino(),
    }))
}

fn workspace_filesystem_identity_matches(
    stored: Option<&WorkspaceFilesystemIdentity>,
    current: Option<&WorkspaceFilesystemIdentity>,
    stored_persistent: Option<&WorkspacePersistentIdentity>,
    current_persistent: Option<&WorkspacePersistentIdentity>,
) -> bool {
    match (stored_persistent, current_persistent) {
        (Some(stored), Some(current)) => return stored == current,
        (Some(_), None) => return false,
        (None, Some(_)) | (None, None) => {}
    }
    stored == current
}

fn parse_persistent_identity(
    volume_uuid: Option<Vec<u8>>,
    object_id: Option<Vec<u8>>,
) -> StoreResult<Option<WorkspacePersistentIdentity>> {
    match (volume_uuid, object_id) {
        (None, None) => Ok(None),
        (Some(volume_uuid), Some(object_id)) => {
            let volume_uuid =
                volume_uuid
                    .try_into()
                    .map_err(|_| StoreError::InvalidWorkspacePath {
                        path: "<stored workspace>".to_string(),
                        reason: "persistent volume identity is malformed",
                    })?;
            let object_id = object_id
                .try_into()
                .map_err(|_| StoreError::InvalidWorkspacePath {
                    path: "<stored workspace>".to_string(),
                    reason: "persistent object identity is malformed",
                })?;
            Ok(Some(WorkspacePersistentIdentity {
                volume_uuid,
                object_id,
            }))
        }
        _ => Err(StoreError::InvalidWorkspacePath {
            path: "<stored workspace>".to_string(),
            reason: "persistent filesystem identity is incomplete",
        }),
    }
}

#[cfg(target_os = "macos")]
fn workspace_persistent_identity(path: &Path) -> Option<WorkspacePersistentIdentity> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    #[repr(C, align(8))]
    struct AttributeBuffer<const N: usize>([u8; N]);

    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut capability_attributes = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: 0,
        volattr: libc::ATTR_VOL_INFO | libc::ATTR_VOL_CAPABILITIES,
        dirattr: 0,
        fileattr: 0,
        forkattr: 0,
    };
    let mut capability_buffer = AttributeBuffer::<36>([0; 36]);
    // SAFETY: `path` is NUL-terminated, `attrlist` uses the Darwin C layout,
    // and the aligned writable byte buffer has the exact requested size.
    let capability_result = unsafe {
        libc::getattrlist(
            path.as_ptr(),
            std::ptr::addr_of_mut!(capability_attributes).cast(),
            capability_buffer.0.as_mut_ptr().cast(),
            capability_buffer.0.len(),
            libc::FSOPT_NOFOLLOW,
        )
    };
    if capability_result != 0
        || u32::from_ne_bytes(capability_buffer.0[..4].try_into().ok()?) as usize
            != capability_buffer.0.len()
    {
        return None;
    }
    let format_capabilities = u32::from_ne_bytes(capability_buffer.0[4..8].try_into().ok()?);
    let valid_format_capabilities =
        u32::from_ne_bytes(capability_buffer.0[20..24].try_into().ok()?);
    if valid_format_capabilities & libc::VOL_CAP_FMT_PERSISTENTOBJECTIDS == 0
        || format_capabilities & libc::VOL_CAP_FMT_PERSISTENTOBJECTIDS == 0
    {
        return None;
    }

    let mut volume_attributes = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: 0,
        volattr: libc::ATTR_VOL_INFO | libc::ATTR_VOL_UUID,
        dirattr: 0,
        fileattr: 0,
        forkattr: 0,
    };
    let mut volume_buffer = AttributeBuffer::<20>([0; 20]);
    // SAFETY: `path` is NUL-terminated, `attrlist` uses the Darwin C layout,
    // and the aligned writable byte buffer has the exact requested size.
    let volume_result = unsafe {
        libc::getattrlist(
            path.as_ptr(),
            std::ptr::addr_of_mut!(volume_attributes).cast(),
            volume_buffer.0.as_mut_ptr().cast(),
            volume_buffer.0.len(),
            libc::FSOPT_NOFOLLOW,
        )
    };
    if volume_result != 0
        || u32::from_ne_bytes(volume_buffer.0[..4].try_into().ok()?) as usize
            != volume_buffer.0.len()
    {
        return None;
    }

    let mut object_attributes = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: libc::ATTR_CMN_OBJPERMANENTID,
        volattr: 0,
        dirattr: 0,
        fileattr: 0,
        forkattr: 0,
    };
    let mut object_buffer = AttributeBuffer::<12>([0; 12]);
    // SAFETY: the same pointer and buffer guarantees as the volume request
    // apply. `ATTR_CMN_OBJPERMANENTID` returns one eight-byte `fsobj_id_t`.
    let object_result = unsafe {
        libc::getattrlist(
            path.as_ptr(),
            std::ptr::addr_of_mut!(object_attributes).cast(),
            object_buffer.0.as_mut_ptr().cast(),
            object_buffer.0.len(),
            libc::FSOPT_NOFOLLOW,
        )
    };
    if object_result != 0
        || u32::from_ne_bytes(object_buffer.0[..4].try_into().ok()?) as usize
            != object_buffer.0.len()
    {
        return None;
    }
    let mut volume_uuid = [0; 16];
    volume_uuid.copy_from_slice(&volume_buffer.0[4..20]);
    let mut object_id = [0; 8];
    object_id.copy_from_slice(&object_buffer.0[4..12]);
    Some(WorkspacePersistentIdentity {
        volume_uuid,
        object_id,
    })
}

#[cfg(not(target_os = "macos"))]
fn workspace_persistent_identity(_path: &Path) -> Option<WorkspacePersistentIdentity> {
    None
}

#[cfg(not(unix))]
fn workspace_filesystem_identity(path: &Path) -> StoreResult<Option<WorkspaceFilesystemIdentity>> {
    fs::metadata(path)?;
    Ok(None)
}

fn parse_filesystem_identity(
    device_id: Option<i64>,
    file_id: Option<i64>,
) -> StoreResult<Option<WorkspaceFilesystemIdentity>> {
    match (device_id, file_id) {
        (Some(device_id), Some(file_id)) => Ok(Some(WorkspaceFilesystemIdentity {
            device_id: device_id as u64,
            file_id: file_id as u64,
        })),
        (None, None) => Ok(None),
        _ => Err(StoreError::InvalidWorkspacePath {
            path: "<stored workspace>".to_string(),
            reason: "filesystem identity is incomplete",
        }),
    }
}

fn workspace_display_name(path: &Path) -> StoreResult<String> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| StoreError::InvalidWorkspacePath {
            path: path.display().to_string(),
            reason: "folder name is not valid UTF-8",
        })?;
    normalize_display_component(name, "project")
}

fn workspace_parent_hint(path: &Path) -> Option<String> {
    path.parent()
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        .and_then(|name| normalize_display_component(name, "folder").ok())
}

fn normalize_display_component(value: &str, kind: &'static str) -> StoreResult<String> {
    let value: String = value
        .trim()
        .chars()
        .map(|character| {
            if character.is_control() || matches!(character, '/' | '\\') {
                '·'
            } else {
                character
            }
        })
        .take(80)
        .collect();
    if value.is_empty() {
        return Err(StoreError::InvalidDisplayMetadata { kind });
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ProviderInstanceRef, ProviderSessionRef};

    fn installation() -> InstallationId {
        InstallationId::new("host-codex").expect("installation")
    }

    fn put_installation(store: &BridgeStore) {
        store
            .put_installation(&InstallationRecord {
                installation_id: installation(),
                provider_id: ProviderId::new("codex").expect("provider"),
                display_name: "Mo's Codex".to_string(),
                created_at: 1,
                updated_at: 1,
            })
            .expect("put installation");
    }

    #[test]
    fn selection_is_mru_and_defaults_to_the_last_selected_folder() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let project = std::env::current_dir().expect("cwd");
        let parent = project.parent().expect("parent").to_path_buf();
        store
            .select_workspace(
                &installation(),
                &WorkspaceId::new("workspace-parent").expect("id"),
                &parent,
                10,
            )
            .expect("select parent");
        store
            .select_workspace(
                &installation(),
                &WorkspaceId::new("workspace-project").expect("id"),
                &project,
                20,
            )
            .expect("select project");

        let recent = store.recent_workspaces(&installation(), 8).expect("recent");
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].workspace_id.as_str(), "workspace-project");
        assert_eq!(
            store
                .default_workspace(&installation())
                .expect("default")
                .expect("workspace")
                .workspace_id
                .as_str(),
            "workspace-project"
        );
        store
            .bind_chat_workspace(
                &installation(),
                42,
                &WorkspaceId::new("workspace-parent").expect("id"),
                30,
            )
            .expect("bind chat");
        assert_eq!(
            store
                .chat_workspace(&installation(), 42)
                .expect("chat workspace")
                .expect("workspace")
                .workspace_id
                .as_str(),
            "workspace-parent"
        );
        assert_eq!(
            store
                .default_workspace(&installation())
                .expect("default")
                .expect("workspace")
                .workspace_id
                .as_str(),
            "workspace-project",
            "binding a conversation must not rewrite the installation default"
        );
    }

    #[test]
    fn session_thread_workspace_cannot_be_rebound_by_chat_selection() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let directory = tempfile::tempdir().expect("workspaces");
        let first_path = directory.path().join("first");
        let second_path = directory.path().join("second");
        fs::create_dir(&first_path).expect("first workspace");
        fs::create_dir(&second_path).expect("second workspace");
        let first = WorkspaceId::new("workspace-first").expect("workspace");
        let second = WorkspaceId::new("workspace-second").expect("workspace");
        store
            .select_workspace(&installation(), &first, &first_path, 1)
            .expect("select first");
        store
            .select_workspace(&installation(), &second, &second_path, 2)
            .expect("select second");
        let provider =
            ProviderInstanceRef::new(installation(), ProviderId::new("codex").expect("provider"))
                .expect("provider instance");
        let session = ProviderSessionRef::new(
            provider,
            ProviderSessionId::new("session-1").expect("session"),
        )
        .expect("session ref");
        let binding = SessionThreadBinding::new(session, first.clone(), 10, 42).expect("binding");
        store
            .bind_session_thread(&binding, None, 3)
            .expect("bind session thread");

        assert!(matches!(
            store.bind_chat_workspace(&installation(), 42, &second, 4),
            Err(StoreError::SessionThreadBindingConflict { thread_chat_id: 42 })
        ));
        assert_eq!(
            store
                .bound_chat_workspace(&installation(), 42)
                .expect("bound workspace")
                .expect("workspace")
                .workspace_id,
            first
        );
    }

    #[test]
    fn recent_choices_are_bounded_and_disambiguate_duplicate_names() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let cwd = std::env::current_dir().expect("cwd");
        for (index, path) in cwd.ancestors().skip(1).take(2).enumerate() {
            store
                .select_workspace(
                    &installation(),
                    &WorkspaceId::new(format!("workspace-{index}")).expect("id"),
                    path,
                    index as i64,
                )
                .expect("select");
        }
        assert!(
            store
                .recent_workspace_choices(&installation(), None)
                .expect("choices")
                .len()
                <= MAX_RECENT_WORKSPACES
        );

        let duplicate = |id: &str, parent_hint: &str, selection_order| WorkspaceRecord {
            installation_id: installation(),
            workspace_id: WorkspaceId::new(id).expect("id"),
            path: PathBuf::from(format!("/tmp/{parent_hint}/inline")),
            display_name: "inline".to_string(),
            parent_hint: Some(parent_hint.to_string()),
            last_selected_at: 1,
            selection_order,
            missing_since: None,
            filesystem_identity: None,
        };
        let selected = WorkspaceId::new("one").expect("id");
        let choices = workspace_choices(
            vec![duplicate("one", "mo", 2), duplicate("two", "dev", 1)],
            Some(&selected),
        );
        assert_eq!(choices[0].parent_hint.as_deref(), Some("mo"));
        assert_eq!(choices[1].parent_hint.as_deref(), Some("dev"));
        assert!(choices[0].selected);
        assert!(!choices[1].selected);
    }

    #[test]
    fn root_relative_and_unknown_installation_are_rejected() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let workspace_id = WorkspaceId::new("workspace").expect("id");
        assert!(matches!(
            store.select_workspace(&installation(), &workspace_id, Path::new("relative"), 1),
            Err(StoreError::InvalidWorkspacePath { .. })
        ));
        let root = Path::new(std::path::MAIN_SEPARATOR_STR);
        assert!(matches!(
            store.select_workspace(&installation(), &workspace_id, root, 1),
            Err(StoreError::InvalidWorkspacePath { .. })
        ));
        #[cfg(unix)]
        assert!(matches!(
            store.select_workspace(&installation(), &workspace_id, &root.join("."), 1,),
            Err(StoreError::InvalidWorkspacePath { .. })
        ));
        assert!(
            store
                .select_workspace(
                    &InstallationId::new("missing").expect("installation"),
                    &workspace_id,
                    &std::env::current_dir().expect("cwd"),
                    1,
                )
                .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn replaced_workspace_root_is_rejected_even_at_the_same_path() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let parent = tempfile::tempdir().expect("parent");
        let project = parent.path().join("project");
        fs::create_dir(&project).expect("project");
        let project = fs::canonicalize(project).expect("canonical project");
        let workspace_id = WorkspaceId::new("workspace-replaced").expect("id");
        let original_persistent_identity = workspace_persistent_identity(&project);
        store
            .select_workspace(&installation(), &workspace_id, &project, 1)
            .expect("select workspace");

        let original = parent.path().join("original-project");
        fs::rename(&project, &original).expect("move original root");
        fs::create_dir(&project).expect("replacement root");
        assert_ne!(
            original_persistent_identity,
            workspace_persistent_identity(&project),
            "replacement directory must have a distinct persistent identity"
        );

        store
            .discover_workspace(&installation(), &workspace_id, &project)
            .expect("rediscovering must preserve the original filesystem identity");

        let missing = store
            .refresh_workspace_availability(&installation(), 2)
            .expect("refresh workspaces");
        assert_eq!(missing.len(), 1);
        assert_eq!(
            store
                .workspace(&installation(), &workspace_id)
                .expect("stored workspace")
                .expect("workspace")
                .missing_since,
            Some(2)
        );
    }

    #[test]
    fn verified_workspace_recovers_a_matching_folder_marked_unavailable() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let workspace_id = WorkspaceId::new("workspace-recovered").expect("id");
        let cwd = std::env::current_dir().expect("cwd");
        store
            .select_workspace(&installation(), &workspace_id, &cwd, 1)
            .expect("select");
        store
            .mark_workspace_unavailable(&installation(), &workspace_id, 2)
            .expect("mark unavailable");

        let newly_missing = store
            .refresh_workspace_availability(&installation(), 3)
            .expect("refresh matching workspace");
        assert!(newly_missing.is_empty());
        let recovered = store
            .workspace(&installation(), &workspace_id)
            .expect("workspace")
            .expect("record");

        assert_eq!(recovered.missing_since, None);
        assert_eq!(
            recovered.path,
            fs::canonicalize(cwd).expect("canonical cwd")
        );
        assert_eq!(
            store
                .workspace(&installation(), &workspace_id)
                .expect("workspace")
                .expect("record")
                .missing_since,
            None
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn verified_workspace_repairs_boot_variant_device_identity() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let workspace_id = WorkspaceId::new("workspace-remounted").expect("id");
        let cwd = std::env::current_dir().expect("cwd");
        let selected = store
            .select_workspace(&installation(), &workspace_id, &cwd, 1)
            .expect("select");
        let identity = selected.filesystem_identity.expect("filesystem identity");
        let stale_device_id = (identity.device_id as i64).wrapping_add(1);
        store
            .connection
            .lock()
            .expect("store")
            .execute(
                "UPDATE workspaces SET filesystem_device_id = ?3, missing_since = 2
                 WHERE installation_id = ?1 AND workspace_id = ?2",
                params![
                    installation().as_str(),
                    workspace_id.as_str(),
                    stale_device_id
                ],
            )
            .expect("simulate reboot device drift");

        let recovered = store
            .verified_workspace(&installation(), &workspace_id, 3)
            .expect("repair remounted workspace");

        assert_eq!(recovered.missing_since, None);
        assert_eq!(recovered.filesystem_identity, Some(identity));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn persistent_volume_identity_rejects_cross_volume_inode_collision() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let workspace_id = WorkspaceId::new("workspace-volume-replaced").expect("id");
        let cwd = std::env::current_dir().expect("cwd");
        store
            .select_workspace(&installation(), &workspace_id, &cwd, 1)
            .expect("select");
        let changed = store
            .connection
            .lock()
            .expect("store")
            .execute(
                "UPDATE workspaces SET filesystem_volume_uuid = ?3
                 WHERE installation_id = ?1 AND workspace_id = ?2",
                params![
                    installation().as_str(),
                    workspace_id.as_str(),
                    vec![0xff_u8; 16]
                ],
            )
            .expect("simulate another volume with a colliding inode");
        assert_eq!(changed, 1);

        assert!(matches!(
            store.verified_workspace(&installation(), &workspace_id, 2),
            Err(StoreError::WorkspaceUnavailable { .. })
        ));
    }

    #[test]
    fn missing_folder_is_removed_from_recents_without_deleting_record() {
        let store = BridgeStore::open_in_memory().expect("store");
        put_installation(&store);
        let workspace_id = WorkspaceId::new("workspace").expect("id");
        let cwd = std::env::current_dir().expect("cwd");
        store
            .select_workspace(&installation(), &workspace_id, &cwd, 1)
            .expect("select");
        store
            .bind_chat_workspace(&installation(), 42, &workspace_id, 2)
            .expect("bind");
        store
            .connection
            .lock()
            .expect("store")
            .execute(
                "UPDATE workspaces SET path = '/inline-test-folder-that-does-not-exist'",
                [],
            )
            .expect("simulate missing folder");

        let missing = store
            .refresh_workspace_availability(&installation(), 20)
            .expect("refresh");
        assert_eq!(missing.len(), 1);
        assert!(
            store
                .recent_workspaces(&installation(), 8)
                .expect("recent")
                .is_empty()
        );
        assert_eq!(
            store
                .workspace(&installation(), &workspace_id)
                .expect("workspace")
                .expect("record")
                .missing_since,
            Some(20)
        );
        assert_eq!(
            store
                .bound_chat_workspace(&installation(), 42)
                .expect("bound workspace"),
            store
                .workspace(&installation(), &workspace_id)
                .expect("record"),
            "the durable binding must survive folder loss"
        );
        assert!(
            store
                .chat_workspace(&installation(), 42)
                .expect("available workspace")
                .is_none()
        );
    }
}

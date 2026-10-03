//! Immutable public input snapshots and provider acceptance, in the existing inbox.

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};

use super::{BridgeStore, StoreError, StoreResult};
use crate::{BindingKey, DriverError, ProviderSessionId, TurnId, TurnInput};

/// Physical public message identity, including the version actually rendered.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ContextMessageRef {
    pub chat_id: i64,
    pub message_id: i64,
    pub revision: i64,
    #[serde(default)]
    pub source_snapshot: Option<String>,
    #[serde(default)]
    pub visible_fingerprint: Option<String>,
}

/// Current physical direction, distinct from any old material it quotes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextTriggerProof {
    pub chat_id: i64,
    pub message_id: i64,
    pub timestamp: i64,
}

/// The complete provider-neutral public input. No provider history is stored here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextInputSnapshot {
    pub binding: BindingKey,
    pub provider_session_id: ProviderSessionId,
    pub generation: i64,
    pub input: TurnInput,
    pub messages: Vec<ContextMessageRef>,
    /// Optional only for decoding old receipts. New submissions require proof.
    #[serde(default)]
    pub trigger: Option<ContextTriggerProof>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContextInputState {
    Prepared,
    Submitting,
    Accepted,
    Uncertain,
}

impl ContextInputState {
    fn parse(value: &str) -> StoreResult<Self> {
        match value {
            "prepared" => Ok(Self::Prepared),
            "submitting" => Ok(Self::Submitting),
            "accepted" => Ok(Self::Accepted),
            "uncertain" => Ok(Self::Uncertain),
            _ => Err(StoreError::InvalidContextInput("unknown acceptance state")),
        }
    }
}

/// Only accepted representations in the current provider session count as consumed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContextReceipt {
    pub chat_id: i64,
    pub provider_session_id: ProviderSessionId,
    pub generation: i64,
    pub reset_at: i64,
    pub reset_after_message_id: i64,
    pub consumed: HashSet<ContextMessageRef>,
    pub represented_outputs: HashSet<(i64, i64)>,
}

impl BridgeStore {
    pub fn is_represented_context_output(
        &self,
        installation: &crate::InstallationId,
        chat_id: i64,
        message_id: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        Ok(connection.query_row("SELECT EXISTS(SELECT 1 FROM inbound_directions
            WHERE installation_id = ?1 AND delivery_chat_id = ?2 AND context_input_state = 'accepted'
              AND (agent_output_message_id = ?3 OR EXISTS(SELECT 1 FROM json_each(context_output_ids_json)
                WHERE json_extract(value, '$[0]') = ?2 AND json_extract(value, '$[1]') = ?3)))",
            params![installation.as_str(), chat_id, message_id], |row| row.get(0))?)
    }
    pub fn has_bound_session_for_chat(
        &self,
        installation: &crate::InstallationId,
        chat_id: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        Ok(connection.query_row("SELECT EXISTS(SELECT 1 FROM session_bindings WHERE installation_id = ?1 AND chat_id = ?2)", params![installation.as_str(), chat_id], |row| row.get(0))?)
    }
    pub fn context_receipt(&self, binding: &BindingKey) -> StoreResult<ContextReceipt> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let (session, generation, reset_at, reset_after_message_id) =
            read_session(&connection, binding)?;
        let mut statement = connection.prepare(
            "SELECT context_input_json, agent_output_message_id, context_output_ids_json
             FROM inbound_directions
             WHERE installation_id = ?1 AND delivery_chat_id = ?2 AND workspace_id = ?3
               AND context_input_session_id = ?4 AND context_input_generation = ?5
               AND context_input_state = 'accepted'",
        )?;
        let rows = statement
            .query_map(
                params![
                    binding.installation_id.as_str(),
                    binding.chat_id,
                    binding.workspace_id.as_str(),
                    session,
                    generation,
                ],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<i64>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        let mut consumed = HashSet::new();
        let mut represented_outputs = HashSet::new();
        for (json, output, output_ids) in rows {
            let snapshot: ContextInputSnapshot = serde_json::from_str(&json)?;
            if snapshot.binding != *binding {
                return Err(StoreError::InvalidContextInput("receipt binding mismatch"));
            }
            consumed.extend(snapshot.messages);
            if let Some(ids) = output_ids {
                represented_outputs.extend(serde_json::from_str::<Vec<(i64, i64)>>(&ids)?);
            }
            if let Some(message_id) = output {
                represented_outputs.insert((binding.chat_id, message_id));
            }
        }
        Ok(ContextReceipt {
            chat_id: binding.chat_id,
            provider_session_id: ProviderSessionId::new(session)
                .map_err(|_| StoreError::InvalidContextInput("invalid provider session"))?,
            generation,
            reset_at,
            reset_after_message_id,
            consumed,
            represented_outputs,
        })
    }

    pub fn context_input(
        &self,
        event_id: &str,
    ) -> StoreResult<Option<(ContextInputSnapshot, ContextInputState)>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let raw = connection
            .query_row(
                "SELECT context_input_json, context_input_state FROM inbound_directions
             WHERE event_id = ?1 AND context_input_json IS NOT NULL",
                [event_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        raw.map(|(json, state)| {
            Ok((
                serde_json::from_str(&json)?,
                ContextInputState::parse(&state)?,
            ))
        })
        .transpose()
    }

    /// Compare-and-set an immutable snapshot before any provider call.
    /// Re-preparing an event may verify the same bytes, never replace them.
    pub fn prepare_context_input(
        &self,
        event_id: &str,
        snapshot: &ContextInputSnapshot,
    ) -> StoreResult<()> {
        if snapshot
            .messages
            .iter()
            .any(|message| message.chat_id <= 0 || message.message_id <= 0 || message.revision < 0)
        {
            return Err(StoreError::InvalidContextInput(
                "invalid physical message identity",
            ));
        }
        let json = serde_json::to_string(snapshot)?;
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        validate_session(&transaction, snapshot)?;
        validate_trigger(&transaction, event_id, snapshot)?;
        let changed = transaction.execute(
            "UPDATE inbound_directions
             SET context_input_json = ?2, context_input_state = 'prepared',
                 context_input_session_id = ?3, context_input_generation = ?4
             WHERE event_id = ?1 AND state = 'started' AND context_input_json IS NULL
               AND installation_id = ?5 AND delivery_chat_id = ?6 AND workspace_id = ?7",
            params![
                event_id,
                json,
                snapshot.provider_session_id.as_str(),
                snapshot.generation,
                snapshot.binding.installation_id.as_str(),
                snapshot.binding.chat_id,
                snapshot.binding.workspace_id.as_str()
            ],
        )?;
        if changed != 1 {
            let existing: Option<String> = transaction
                .query_row(
                    "SELECT context_input_json FROM inbound_directions WHERE event_id = ?1",
                    [event_id],
                    |row| row.get(0),
                )
                .optional()?
                .flatten();
            if existing.as_deref() != Some(&json) {
                return Err(StoreError::InvalidContextInput(
                    "input is absent or already immutable",
                ));
            }
        }
        transaction.commit()?;
        Ok(())
    }

    /// Persist uncertainty *before* crossing the provider boundary. A crash
    /// here must not replay the same direction on a restarted bridge.
    pub fn begin_context_input(
        &self,
        event_id: &str,
        binding: &BindingKey,
        session_id: &ProviderSessionId,
    ) -> StoreResult<ContextInputSnapshot> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let json: String = transaction
            .query_row(
                "SELECT context_input_json FROM inbound_directions
             WHERE event_id = ?1 AND state = 'started' AND context_input_state = 'prepared'",
                [event_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::InvalidContextInput(
                "input is not safe to submit",
            ))?;
        let snapshot: ContextInputSnapshot = serde_json::from_str(&json)?;
        if snapshot.binding != *binding || snapshot.provider_session_id != *session_id {
            return Err(StoreError::InvalidContextInput(
                "input targets an old binding or session",
            ));
        }
        validate_session(&transaction, &snapshot)?;
        validate_trigger(&transaction, event_id, &snapshot)?;
        transaction.execute(
            "UPDATE inbound_directions SET context_input_state = 'submitting' WHERE event_id = ?1",
            [event_id],
        )?;
        transaction.commit()?;
        Ok(snapshot)
    }

    /// Provider acknowledgement and the turn identity share one durable commit.
    pub fn accept_context_input(&self, event_id: &str, turn_id: &TurnId) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        Ok(connection.execute(
            "UPDATE inbound_directions SET context_input_state = 'accepted', provider_turn_id = ?2
             WHERE event_id = ?1 AND state = 'started' AND context_input_state = 'submitting'",
            params![event_id, turn_id.as_str()],
        )? == 1)
    }

    /// Only an authoritative rejection permits queueing this frozen input.
    /// Transports, timeouts, and process failures retain unknown acceptance.
    pub fn reject_context_input(&self, event_id: &str, error: &DriverError) -> StoreResult<bool> {
        let definitive = context_input_was_rejected(error);
        let connection = self.connection.lock().expect("bridge store poisoned");
        connection.execute(
            "UPDATE inbound_directions SET context_input_state = ?2
             WHERE event_id = ?1 AND context_input_state = 'submitting'",
            params![event_id, if definitive { "prepared" } else { "uncertain" }],
        )?;
        Ok(definitive)
    }

    /// Public output is already represented in its accepting provider session
    /// even when there is no server agent-session linkage.
    pub fn record_context_output_message(
        &self,
        event_id: &str,
        message_id: i64,
    ) -> StoreResult<()> {
        if message_id <= 0 {
            return Err(StoreError::InvalidContextInput(
                "invalid output message identity",
            ));
        }
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let row = transaction
            .query_row(
                "SELECT delivery_chat_id, context_output_ids_json FROM inbound_directions
            WHERE event_id = ?1 AND context_input_state = 'accepted'",
                [event_id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .optional()?;
        if let Some((chat_id, json)) = row {
            let mut ids = json
                .map(|json| serde_json::from_str::<Vec<(i64, i64)>>(&json))
                .transpose()?
                .unwrap_or_default();
            if !ids.contains(&(chat_id, message_id)) {
                ids.push((chat_id, message_id));
                transaction.execute("UPDATE inbound_directions SET context_output_ids_json = ?2 WHERE event_id = ?1", params![event_id, serde_json::to_string(&ids)?])?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    pub(crate) fn chat_has_submitted_input(&self, binding: &BindingKey) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        Ok(connection.query_row("SELECT EXISTS(SELECT 1 FROM inbound_directions
            WHERE installation_id = ?1 AND (chat_id = ?2 OR delivery_chat_id = ?2)
              AND state = 'started' AND terminal_state IS NULL
              AND (provider_turn_id IS NOT NULL OR context_input_state IN ('submitting', 'accepted')))",
            params![binding.installation_id.as_str(), binding.chat_id], |row| row.get(0))?)
    }
}

pub(crate) fn context_input_was_rejected(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::Rejected(_)
            | DriverError::Unsupported(_)
            | DriverError::SessionBusy(_)
            | DriverError::AuthenticationRequired(_)
            | DriverError::InvalidSession(_)
    )
}

fn read_session(
    connection: &Connection,
    binding: &BindingKey,
) -> StoreResult<(String, i64, i64, i64)> {
    let invalidated: bool = connection
        .query_row(
            "SELECT context_session_invalidated FROM session_bindings
        WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
            params![
                binding.installation_id.as_str(),
                binding.chat_id,
                binding.workspace_id.as_str()
            ],
            |row| row.get(0),
        )
        .optional()?
        .ok_or(StoreError::InvalidContextInput(
            "provider session is not bound",
        ))?;
    if invalidated {
        return Err(StoreError::InvalidContextInput(
            "provider history was invalidated by this chat's reset",
        ));
    }
    connection.query_row(
        "SELECT provider_session_id, context_generation, context_reset_at, context_reset_after_message_id
         FROM session_bindings WHERE installation_id = ?1 AND chat_id = ?2 AND workspace_id = ?3",
        params![binding.installation_id.as_str(), binding.chat_id, binding.workspace_id.as_str()],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    ).optional()?.ok_or(StoreError::InvalidContextInput("provider session is not bound"))
}

fn validate_session(connection: &Connection, snapshot: &ContextInputSnapshot) -> StoreResult<()> {
    let (session, generation, _, _) = read_session(connection, &snapshot.binding)?;
    if session != snapshot.provider_session_id.as_str() || generation != snapshot.generation {
        return Err(StoreError::InvalidContextInput(
            "input belongs to an old session generation",
        ));
    }
    Ok(())
}

fn validate_trigger(
    connection: &Connection,
    event_id: &str,
    snapshot: &ContextInputSnapshot,
) -> StoreResult<()> {
    let trigger = snapshot
        .trigger
        .as_ref()
        .ok_or(StoreError::InvalidContextInput(
            "legacy input has no physical trigger proof; send a new request",
        ))?;
    let (chat_id, message_id, source_json): (i64, i64, Option<String>) = connection.query_row(
        "SELECT chat_id, message_id, direction_source_json FROM inbound_directions WHERE event_id = ?1",
        [event_id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    let source = (chat_id, message_id);
    let source_version: crate::SourceMessageVersion = source_json
        .ok_or(StoreError::InvalidContextInput(
            "legacy queued direction has no source proof; send a new request",
        ))
        .and_then(|json| serde_json::from_str(&json).map_err(StoreError::from))?;
    if !fingerprint_is_valid(source_version.visible_fingerprint.as_deref())
        || source != (trigger.chat_id, trigger.message_id)
        || trigger.timestamp <= 0
        || !snapshot.messages.iter().any(|message| {
            (message.chat_id, message.message_id) == source
                && fingerprint_is_valid(message.visible_fingerprint.as_deref())
                && message.visible_fingerprint == source_version.visible_fingerprint
                && message.revision == source_version.revision
                && message.source_snapshot == source_version.source_snapshot
        })
        || snapshot
            .messages
            .iter()
            .any(|message| !fingerprint_is_valid(message.visible_fingerprint.as_deref()))
    {
        return Err(StoreError::InvalidContextInput(
            "unverified physical trigger representation",
        ));
    }
    let (_, _, reset_at, reset_after_message_id) = read_session(connection, &snapshot.binding)?;
    if trigger.timestamp <= reset_at
        || (trigger.chat_id == snapshot.binding.chat_id
            && trigger.message_id <= reset_after_message_id)
    {
        return Err(StoreError::InvalidContextInput(
            "physical trigger predates the current chat reset; send a new request",
        ));
    }
    Ok(())
}

fn fingerprint_is_valid(fingerprint: Option<&str>) -> bool {
    fingerprint.is_some_and(|value| {
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

/// Explicit reset is a chat boundary, including queued work in an old workspace.
/// Rows remain auditable; they are never deleted or replayed into the fresh session.
pub(super) fn reset_in_transaction(
    transaction: &Transaction<'_>,
    binding: &BindingKey,
    now: i64,
) -> StoreResult<()> {
    transaction.execute(
        "UPDATE session_bindings SET context_reset_at = ?3,
             context_generation = context_generation + 1,
             context_session_invalidated = workspace_id != ?4,
             context_reset_after_message_id = (SELECT COALESCE(MAX(message_id), 0)
                 FROM inbound_directions WHERE installation_id = ?1 AND chat_id = ?2)
         WHERE installation_id = ?1 AND chat_id = ?2",
        params![
            binding.installation_id.as_str(),
            binding.chat_id,
            now,
            binding.workspace_id.as_str()
        ],
    )?;
    transaction.execute(
        "UPDATE inbound_directions SET state = 'failed', failure = 'cancelled by explicit session reset'
         WHERE installation_id = ?1 AND (chat_id = ?2 OR delivery_chat_id = ?2)
           AND (state = 'accepted' OR (state = 'started' AND workspace_id != ?3
             AND (context_input_state IS NULL OR context_input_state = 'prepared')))
           AND terminal_state IS NULL",
        params![binding.installation_id.as_str(), binding.chat_id, binding.workspace_id.as_str()],
    )?;
    Ok(())
}

pub(super) fn migrate_v31(connection: &Connection) -> StoreResult<()> {
    let transaction = connection.unchecked_transaction()?;
    for (table, column, definition) in [
        (
            "session_bindings",
            "context_session_invalidated",
            "INTEGER NOT NULL DEFAULT 0 CHECK(context_session_invalidated IN (0, 1))",
        ),
        (
            "session_bindings",
            "context_generation",
            "INTEGER NOT NULL DEFAULT 1",
        ),
        (
            "session_bindings",
            "context_reset_at",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "session_bindings",
            "context_reset_after_message_id",
            "INTEGER NOT NULL DEFAULT 0",
        ),
        ("inbound_directions", "context_input_json", "TEXT"),
        ("inbound_directions", "direction_source_json", "TEXT"),
        ("inbound_directions", "context_output_ids_json", "TEXT"),
        ("inbound_directions", "context_input_session_id", "TEXT"),
        ("inbound_directions", "context_input_generation", "INTEGER"),
        (
            "inbound_directions",
            "context_input_state",
            "TEXT CHECK (context_input_state IN ('prepared', 'submitting', 'accepted', 'uncertain'))",
        ),
    ] {
        if !super::table_has_column(&transaction, table, column)? {
            transaction.execute_batch(&format!(
                "ALTER TABLE {table} ADD COLUMN {column} {definition};"
            ))?;
        }
    }
    transaction.execute_batch("PRAGMA user_version = 31;")?;
    transaction.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        Direction, DirectionId, InboundRecord, InboundState, InstallationId, ProviderId,
        WorkspaceId,
    };

    fn binding() -> BindingKey {
        BindingKey {
            installation_id: InstallationId::new("worker-a").unwrap(),
            chat_id: 10,
            workspace_id: WorkspaceId::new("workspace").unwrap(),
        }
    }

    fn record(id: i64) -> InboundRecord {
        InboundRecord {
            event_id: format!("event-{id}"),
            binding: binding(),
            message_id: id,
            delivery_chat_id: 10,
            sender_user_id: 7,
            direction: Direction::new(
                DirectionId::new(format!("direction-{id}")).unwrap(),
                "Current request",
            )
            .with_source_version(Some(crate::SourceMessageVersion {
                revision: 1,
                source_snapshot: None,
                visible_fingerprint: Some("b".repeat(64)),
                discretionary: false,
                text: "Current request".into(),
            })),
            state: InboundState::Accepted,
            accepted_at: 100,
            started_at: None,
            lease_expires_at: None,
            attempt_count: 0,
            provider_turn_id: None,
            stream_message_id: None,
            failure: None,
        }
    }

    fn setup() -> BridgeStore {
        let store = BridgeStore::open_in_memory().unwrap();
        store
            .put_binding(
                &binding(),
                &ProviderId::new("codex").unwrap(),
                &ProviderSessionId::new("session-a").unwrap(),
                100,
            )
            .unwrap();
        store
    }

    fn snapshot(store: &BridgeStore) -> ContextInputSnapshot {
        let receipt = store.context_receipt(&binding()).unwrap();
        ContextInputSnapshot {
            binding: binding(),
            provider_session_id: receipt.provider_session_id,
            generation: receipt.generation,
            input: TurnInput {
                text: "Frozen public context\nCurrent request".to_string(),
                attachments: Vec::new(),
                client_message_id: Some("direction-2".to_string()),
            },
            messages: vec![
                ContextMessageRef {
                    chat_id: 10,
                    message_id: 1,
                    revision: 0,
                    source_snapshot: None,
                    visible_fingerprint: Some("a".repeat(64)),
                },
                ContextMessageRef {
                    chat_id: 10,
                    message_id: 2,
                    revision: 1,
                    source_snapshot: None,
                    visible_fingerprint: Some("b".repeat(64)),
                },
            ],
            trigger: Some(ContextTriggerProof {
                chat_id: 10,
                message_id: 2,
                timestamp: 102,
            }),
        }
    }

    fn prepare(store: &BridgeStore) -> ContextInputSnapshot {
        store.accept_inbound(&record(2)).unwrap();
        store.start_inbound("event-2", 101).unwrap();
        let snapshot = snapshot(store);
        store.prepare_context_input("event-2", &snapshot).unwrap();
        snapshot
    }

    #[test]
    fn fresh_snapshot_cannot_renew_a_legacy_queued_direction_without_original_source_proof() {
        let store = setup();
        let mut legacy_record = record(2);
        legacy_record.direction.source_version = None;
        store.accept_inbound(&legacy_record).unwrap();
        store.start_inbound("event-2", 101).unwrap();
        assert!(
            store
                .prepare_context_input("event-2", &snapshot(&store))
                .is_err()
        );
        assert!(store.context_input("event-2").unwrap().is_none());
    }

    #[test]
    fn legacy_queued_snapshot_decodes_but_cannot_cross_submission_boundary() {
        let store = setup();
        let snapshot = prepare(&store);
        let mut legacy = serde_json::to_value(&snapshot).unwrap();
        legacy.as_object_mut().unwrap().remove("trigger");
        for message in legacy["messages"].as_array_mut().unwrap() {
            message
                .as_object_mut()
                .unwrap()
                .remove("visible_fingerprint");
        }
        let legacy_json = serde_json::to_string(&legacy).unwrap();
        let decoded: ContextInputSnapshot = serde_json::from_str(&legacy_json).unwrap();
        assert!(decoded.trigger.is_none());
        let connection = store.connection.lock().unwrap();
        connection
            .execute(
                "UPDATE inbound_directions SET context_input_json = ?2 WHERE event_id = ?1",
                params!["event-2", legacy_json],
            )
            .unwrap();
        drop(connection);
        assert!(
            store
                .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
                .is_err()
        );
        assert_eq!(
            store.context_input("event-2").unwrap().unwrap().1,
            ContextInputState::Prepared
        );
    }

    #[test]
    fn delayed_physical_input_cannot_adopt_the_post_reset_generation() {
        let store = setup();
        store
            .put_binding_with_configuration_and_reset(
                &binding(),
                &ProviderId::new("codex").unwrap(),
                &ProviderSessionId::new("session-a").unwrap(),
                None,
                110,
                true,
            )
            .unwrap();
        store.accept_inbound(&record(2)).unwrap();
        store.start_inbound("event-2", 111).unwrap();
        let mut candidate = snapshot(&store);
        assert!(store.prepare_context_input("event-2", &candidate).is_err());
        candidate.trigger.as_mut().unwrap().timestamp = 111;
        store.prepare_context_input("event-2", &candidate).unwrap();
        store
            .begin_context_input("event-2", &binding(), &candidate.provider_session_id)
            .unwrap();
    }

    #[test]
    fn completion_without_provider_input_does_not_consume_context() {
        let store = setup();
        store.accept_inbound(&record(2)).unwrap();
        store.start_inbound("event-2", 101).unwrap();
        store.complete_inbound("event-2").unwrap();
        assert!(
            store
                .context_receipt(&binding())
                .unwrap()
                .consumed
                .is_empty()
        );
    }

    #[test]
    fn source_version_and_response_contract_survive_queue_storage_before_lowering() {
        let store = setup();
        let mut record = record(2);
        record.direction.source_version = Some(crate::SourceMessageVersion {
            revision: 1,
            source_snapshot: Some("public-representation-v1".into()),
            visible_fingerprint: Some("a".repeat(64)),
            discretionary: true,
            text: "Original public source".into(),
        });
        record.direction.text = "Trusted specialization\nOriginal public source".into();
        store.accept_inbound(&record).unwrap();
        assert_eq!(
            store
                .get_inbound(&record.event_id)
                .unwrap()
                .unwrap()
                .direction,
            record.direction
        );
        assert_eq!(
            store
                .take_next_inbound(&record.binding, 101)
                .unwrap()
                .unwrap()
                .direction,
            record.direction
        );
        let legacy: crate::SourceMessageVersion =
            serde_json::from_str(r#"{"revision":1,"text":"source"}"#).unwrap();
        assert!(!legacy.discretionary);
        assert!(legacy.source_snapshot.is_none());
    }

    #[test]
    fn every_physical_output_survives_restart_without_representing_unseen_own_cron_content() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("context.sqlite");
        let store = BridgeStore::open(&database).unwrap();
        store
            .put_installation(&crate::InstallationRecord {
                installation_id: binding().installation_id.clone(),
                provider_id: ProviderId::new("codex").unwrap(),
                display_name: "Worker".into(),
                created_at: 1,
                updated_at: 1,
            })
            .unwrap();
        store
            .select_workspace(
                &binding().installation_id,
                &binding().workspace_id,
                directory.path(),
                1,
            )
            .unwrap();
        store
            .put_binding(
                &binding(),
                &ProviderId::new("codex").unwrap(),
                &ProviderSessionId::new("session-a").unwrap(),
                100,
            )
            .unwrap();
        let snapshot = prepare(&store);
        store
            .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
            .unwrap();
        store
            .accept_context_input("event-2", &TurnId::new("turn").unwrap())
            .unwrap();
        for id in [40, 41, 42, 40] {
            store.record_context_output_message("event-2", id).unwrap();
        }
        store
            .stage_inbound_final_send("event-2", InboundState::Completed, "Normal response", None)
            .unwrap();
        store.commit_inbound_final_send("event-2").unwrap();
        drop(store);
        let store = BridgeStore::open(&database).unwrap();
        let receipt = store.context_receipt(&binding()).unwrap();
        assert_eq!(
            receipt.represented_outputs,
            HashSet::from([(10, 40), (10, 41), (10, 42)])
        );
        assert!(
            store
                .is_represented_context_output(&binding().installation_id, 10, 40)
                .unwrap()
        );
        assert!(
            !store
                .is_represented_context_output(&binding().installation_id, 20, 40)
                .unwrap()
        );
        assert!(
            !store
                .is_represented_context_output(
                    &InstallationId::new("another-worker").unwrap(),
                    10,
                    40
                )
                .unwrap()
        );
        assert!(
            !store
                .is_represented_context_output(&binding().installation_id, 10, 99)
                .unwrap(),
            "an unseen brief authored by the same public bot is new evidence"
        );
    }

    #[test]
    fn restart_notice_distinguishes_unsubmitted_accepted_and_unknown_inputs_without_replay() {
        for (state, expected) in [
            (ContextInputState::Prepared, "before submission"),
            (ContextInputState::Submitting, "may have reached"),
            (ContextInputState::Accepted, "after the provider accepted"),
            (ContextInputState::Uncertain, "may have reached"),
        ] {
            let store = setup();
            let snapshot = prepare(&store);
            if state != ContextInputState::Prepared {
                store
                    .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
                    .unwrap();
                if state == ContextInputState::Accepted {
                    store
                        .accept_context_input("event-2", &TurnId::new("turn").unwrap())
                        .unwrap();
                }
                if state == ContextInputState::Uncertain {
                    store
                        .reject_context_input("event-2", &DriverError::Transient("lost ack".into()))
                        .unwrap();
                }
            }
            store
                .stage_interrupted_inbound_for_installation(
                    &binding().installation_id,
                    "restart",
                    "Interrupted before submission. Send a new request.",
                )
                .unwrap();
            let pending = store
                .pending_inbound_final_sends(&binding().installation_id)
                .unwrap();
            assert_eq!(pending.len(), 1);
            assert!(
                pending[0].final_text.contains(expected),
                "{}",
                pending[0].final_text
            );
            if state != ContextInputState::Prepared {
                assert!(
                    pending[0]
                        .final_text
                        .contains("won’t replay it automatically")
                );
                assert!(!pending[0].final_text.contains("Send a new request"));
                assert_eq!(store.recover_expired_inbound(1000).unwrap(), 0);
            }
        }
    }

    #[test]
    fn uncertain_input_is_immutable_and_never_recovered_or_deferred() {
        let store = setup();
        let snapshot = prepare(&store);
        let mut replacement = snapshot.clone();
        replacement.input.text = "Changed after admission".to_string();
        assert!(
            store
                .prepare_context_input("event-2", &replacement)
                .is_err()
        );
        assert_eq!(
            store
                .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
                .unwrap(),
            snapshot
        );
        assert_eq!(store.recover_expired_inbound(1000).unwrap(), 0);
        assert!(!store.defer_inbound("event-2").unwrap());
        assert!(
            !store
                .reject_context_input(
                    "event-2",
                    &DriverError::Transient("lost acknowledgement".to_string())
                )
                .unwrap()
        );
        assert_eq!(
            store.context_input("event-2").unwrap().unwrap().1,
            ContextInputState::Uncertain
        );
        assert!(
            store
                .context_receipt(&binding())
                .unwrap()
                .consumed
                .is_empty()
        );
        assert!(
            store
                .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
                .is_err()
        );
        assert!(!store.defer_inbound("event-2").unwrap());
    }

    #[test]
    fn definitive_rejection_retries_exact_input_and_acceptance_survives_turn_failure() {
        let store = setup();
        let snapshot = prepare(&store);
        store
            .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
            .unwrap();
        assert!(
            store
                .reject_context_input("event-2", &DriverError::Unsupported("steering"))
                .unwrap()
        );
        assert!(store.defer_inbound("event-2").unwrap());
        store.take_next_inbound(&binding(), 102).unwrap().unwrap();
        assert_eq!(
            store
                .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
                .unwrap(),
            snapshot
        );
        assert!(
            store
                .accept_context_input("event-2", &TurnId::new("turn").unwrap())
                .unwrap()
        );
        store.fail_inbound("event-2", "turn later failed").unwrap();
        assert_eq!(
            store.context_receipt(&binding()).unwrap().consumed,
            snapshot.messages.into_iter().collect()
        );
        assert_eq!(store.recover_expired_inbound(1000).unwrap(), 0);
    }

    #[test]
    fn receipts_use_physical_scope_versions_and_exact_provider_generation() {
        let store = setup();
        let mut snapshot = prepare(&store);
        // Immutable admission is already frozen; its equal numeric IDs in
        // another chat and later edit version are not consumed by this input.
        store
            .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
            .unwrap();
        store
            .accept_context_input("event-2", &TurnId::new("turn").unwrap())
            .unwrap();
        let receipt = store.context_receipt(&binding()).unwrap();
        assert!(!receipt.consumed.contains(&ContextMessageRef {
            chat_id: 20,
            message_id: 1,
            revision: 0,
            source_snapshot: None,
            visible_fingerprint: Some("b".repeat(64)),
        }));
        assert!(!receipt.consumed.contains(&ContextMessageRef {
            chat_id: 10,
            message_id: 2,
            revision: 2,
            source_snapshot: None,
            visible_fingerprint: Some("b".repeat(64)),
        }));
        store
            .put_binding(
                &binding(),
                &ProviderId::new("codex").unwrap(),
                &ProviderSessionId::new("session-b").unwrap(),
                105,
            )
            .unwrap();
        let receipt = store.context_receipt(&binding()).unwrap();
        assert!(receipt.consumed.is_empty());
        assert!(receipt.generation > snapshot.generation);
        snapshot.provider_session_id = receipt.provider_session_id;
        assert!(store.prepare_context_input("event-2", &snapshot).is_err());
    }

    #[test]
    fn reset_fences_old_queue_input_and_context_across_workspace_changes() {
        let store = setup();
        let snapshot = prepare(&store);
        store.accept_inbound(&record(3)).unwrap();
        let provider = ProviderId::new("codex").unwrap();
        store
            .put_binding_with_configuration_and_reset(
                &binding(),
                &provider,
                &snapshot.provider_session_id,
                None,
                110,
                true,
            )
            .unwrap();
        assert_eq!(
            store.get_inbound("event-3").unwrap().unwrap().state,
            InboundState::Failed
        );
        assert!(
            store
                .begin_context_input("event-2", &binding(), &snapshot.provider_session_id)
                .is_err()
        );
        let receipt = store.context_receipt(&binding()).unwrap();
        assert_eq!(receipt.reset_at, 110);
        assert!(receipt.generation > snapshot.generation);
        let another_workspace = BindingKey {
            workspace_id: WorkspaceId::new("second").unwrap(),
            ..binding()
        };
        store
            .put_binding(
                &another_workspace,
                &provider,
                &ProviderSessionId::new("session-c").unwrap(),
                111,
            )
            .unwrap();
        assert_eq!(
            store.context_receipt(&another_workspace).unwrap().reset_at,
            110
        );
        let other_worker = BindingKey {
            installation_id: InstallationId::new("worker-b").unwrap(),
            ..binding()
        };
        store
            .put_binding(
                &other_worker,
                &provider,
                &ProviderSessionId::new("session-d").unwrap(),
                111,
            )
            .unwrap();
        assert_eq!(store.context_receipt(&other_worker).unwrap().reset_at, 0);
    }
}

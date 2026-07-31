use rusqlite::{Connection, OptionalExtension, params};

use crate::{ProviderId, ProviderSessionId, TurnId};

use super::{
    BridgeStore, StoreResult, parse_provider_id, parse_provider_session_id, parse_turn_id,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostToolCallRecord {
    pub provider_id: ProviderId,
    pub session_id: ProviderSessionId,
    pub turn_id: TurnId,
    pub call_id: String,
    pub tool_name: String,
    pub arguments_digest: String,
    pub result_json: Option<String>,
    pub succeeded: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostToolCallClaim {
    Claimed,
    Cached(HostToolCallRecord),
    InFlight,
    Conflict,
}

impl BridgeStore {
    pub fn claim_host_tool_call(
        &self,
        record: &HostToolCallRecord,
        created_at: i64,
    ) -> StoreResult<HostToolCallClaim> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "INSERT OR IGNORE INTO host_tool_calls (
                provider_id, session_id, turn_id, call_id, tool_name,
                arguments_digest, state, result_json, succeeded, created_at, resolved_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', NULL, NULL, ?7, NULL)",
            params![
                record.provider_id.as_str(),
                record.session_id.as_str(),
                record.turn_id.as_str(),
                record.call_id,
                record.tool_name,
                record.arguments_digest,
                created_at,
            ],
        )?;
        if changed == 1 {
            return Ok(HostToolCallClaim::Claimed);
        }
        let existing = read_call(
            &connection,
            &record.provider_id,
            &record.session_id,
            &record.turn_id,
            &record.call_id,
        )?
        .expect("conflicting host tool call exists");
        if existing.tool_name != record.tool_name
            || existing.arguments_digest != record.arguments_digest
        {
            return Ok(HostToolCallClaim::Conflict);
        }
        if existing.result_json.is_some() {
            Ok(HostToolCallClaim::Cached(existing))
        } else {
            Ok(HostToolCallClaim::InFlight)
        }
    }

    pub fn finish_host_tool_call(
        &self,
        record: &HostToolCallRecord,
        result_json: &str,
        succeeded: bool,
        resolved_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE host_tool_calls SET state = 'completed', result_json = ?7,
                    succeeded = ?8, resolved_at = ?9
             WHERE provider_id = ?1 AND session_id = ?2 AND turn_id = ?3
               AND call_id = ?4 AND tool_name = ?5 AND arguments_digest = ?6
               AND state = 'running'",
            params![
                record.provider_id.as_str(),
                record.session_id.as_str(),
                record.turn_id.as_str(),
                record.call_id,
                record.tool_name,
                record.arguments_digest,
                result_json,
                succeeded,
                resolved_at,
            ],
        )?;
        Ok(changed == 1)
    }
}

fn read_call(
    connection: &Connection,
    provider_id: &ProviderId,
    session_id: &ProviderSessionId,
    turn_id: &TurnId,
    call_id: &str,
) -> StoreResult<Option<HostToolCallRecord>> {
    let raw = connection
        .query_row(
            "SELECT provider_id, session_id, turn_id, tool_name, arguments_digest,
                    result_json, succeeded
             FROM host_tool_calls
             WHERE provider_id = ?1 AND session_id = ?2 AND turn_id = ?3 AND call_id = ?4",
            params![
                provider_id.as_str(),
                session_id.as_str(),
                turn_id.as_str(),
                call_id
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<bool>>(6)?,
                ))
            },
        )
        .optional()?;
    let Some((
        provider_id,
        session_id,
        turn_id,
        tool_name,
        arguments_digest,
        result_json,
        succeeded,
    )) = raw
    else {
        return Ok(None);
    };
    Ok(Some(HostToolCallRecord {
        provider_id: parse_provider_id(provider_id)?,
        session_id: parse_provider_session_id(session_id)?,
        turn_id: parse_turn_id(turn_id)?,
        call_id: call_id.to_string(),
        tool_name,
        arguments_digest,
        result_json,
        succeeded,
    }))
}

pub(super) fn migrate_v14(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE host_tool_calls (
            provider_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            call_id TEXT NOT NULL,
            tool_name TEXT NOT NULL,
            arguments_digest TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('running', 'completed')),
            result_json TEXT,
            succeeded INTEGER,
            created_at INTEGER NOT NULL,
            resolved_at INTEGER,
            PRIMARY KEY (provider_id, session_id, turn_id, call_id)
         );
         PRAGMA user_version = 14;
         COMMIT;",
    )?;
    Ok(())
}

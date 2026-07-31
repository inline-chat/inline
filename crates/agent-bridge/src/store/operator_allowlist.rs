use rusqlite::{Connection, OptionalExtension, params};

use crate::{InstallationId, ProviderId};

use super::{BridgeStore, StoreError, StoreResult, parse_installation_id, parse_provider_id};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperatorAllowlistState {
    Pending,
    Applying,
    Applied,
    Cancelled,
    Expired,
    Failed,
}

impl OperatorAllowlistState {
    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "pending" => Ok(Self::Pending),
            "applying" => Ok(Self::Applying),
            "applied" => Ok(Self::Applied),
            "cancelled" => Ok(Self::Cancelled),
            "expired" => Ok(Self::Expired),
            "failed" => Ok(Self::Failed),
            _ => Err(StoreError::UnknownOperatorAllowlistState(value)),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperatorAllowlistDecision {
    Allow,
    Cancel,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingOperatorAllowlistRequest {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub owner_user_id: i64,
    pub target_user_id: i64,
    pub origin_chat_id: i64,
    pub created_at: i64,
    pub expires_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OperatorAllowlistRequest {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub owner_user_id: i64,
    pub target_user_id: i64,
    pub origin_chat_id: i64,
    pub card_message_id: Option<i64>,
    pub state: OperatorAllowlistState,
    pub claimed_event_id: Option<String>,
    pub resolved_by_user_id: Option<i64>,
    pub created_at: i64,
    pub expires_at: i64,
    pub resolved_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OperatorAllowlistClaimContext {
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub actor_user_id: i64,
    pub action_chat_id: i64,
    pub action_message_id: i64,
    pub event_id: String,
    pub now: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OperatorAllowlistClaimOutcome {
    Claimed(OperatorAllowlistRequest),
    Resumable(OperatorAllowlistRequest),
    Cancelled(OperatorAllowlistRequest),
    Unknown,
    Unauthorized,
    WrongContext,
    Expired,
    NotPending(OperatorAllowlistState),
}

impl BridgeStore {
    pub fn insert_operator_allowlist_request(
        &self,
        request: &PendingOperatorAllowlistRequest,
    ) -> StoreResult<bool> {
        validate_pending(request)?;
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "INSERT OR IGNORE INTO operator_allowlist_requests (
                callback_token, installation_id, provider_id, owner_user_id,
                target_user_id, origin_chat_id, card_message_id, state,
                claimed_event_id, resolved_by_user_id, created_at, expires_at, resolved_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, 'pending', NULL, NULL, ?7, ?8, NULL)",
            params![
                request.callback_token,
                request.installation_id.as_str(),
                request.provider_id.as_str(),
                request.owner_user_id,
                request.target_user_id,
                request.origin_chat_id,
                request.created_at,
                request.expires_at,
            ],
        )?;
        Ok(changed == 1)
    }

    pub fn attach_operator_allowlist_message(
        &self,
        callback_token: &str,
        message_id: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE operator_allowlist_requests SET card_message_id = ?2
             WHERE callback_token = ?1 AND state = 'pending' AND card_message_id IS NULL",
            params![callback_token, message_id],
        )?;
        Ok(changed == 1)
    }

    pub fn get_operator_allowlist_request(
        &self,
        callback_token: &str,
    ) -> StoreResult<Option<OperatorAllowlistRequest>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        read_request(&connection, callback_token)
    }

    pub fn claim_operator_allowlist_request(
        &self,
        callback_token: &str,
        decision: OperatorAllowlistDecision,
        context: &OperatorAllowlistClaimContext,
    ) -> StoreResult<OperatorAllowlistClaimOutcome> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let Some(mut record) = read_request(&transaction, callback_token)? else {
            transaction.commit()?;
            return Ok(OperatorAllowlistClaimOutcome::Unknown);
        };
        if context.actor_user_id != record.owner_user_id {
            transaction.commit()?;
            return Ok(OperatorAllowlistClaimOutcome::Unauthorized);
        }
        if context.installation_id != record.installation_id
            || context.provider_id != record.provider_id
            || context.action_chat_id != record.origin_chat_id
            || record.card_message_id != Some(context.action_message_id)
        {
            transaction.commit()?;
            return Ok(OperatorAllowlistClaimOutcome::WrongContext);
        }
        if record.state == OperatorAllowlistState::Applying
            && decision == OperatorAllowlistDecision::Allow
        {
            transaction.commit()?;
            return Ok(OperatorAllowlistClaimOutcome::Resumable(record));
        }
        if record.state != OperatorAllowlistState::Pending {
            let state = record.state;
            transaction.commit()?;
            return Ok(OperatorAllowlistClaimOutcome::NotPending(state));
        }
        if record.expires_at <= context.now {
            transaction.execute(
                "UPDATE operator_allowlist_requests SET state = 'expired', resolved_at = ?2
                 WHERE callback_token = ?1 AND state = 'pending'",
                params![callback_token, context.now],
            )?;
            transaction.commit()?;
            return Ok(OperatorAllowlistClaimOutcome::Expired);
        }
        let state = match decision {
            OperatorAllowlistDecision::Allow => "applying",
            OperatorAllowlistDecision::Cancel => "cancelled",
        };
        let changed = transaction.execute(
            "UPDATE operator_allowlist_requests SET state = ?2, claimed_event_id = ?3,
                    resolved_by_user_id = ?4, resolved_at = ?5
             WHERE callback_token = ?1 AND state = 'pending'",
            params![
                callback_token,
                state,
                context.event_id,
                context.actor_user_id,
                context.now
            ],
        )?;
        if changed != 1 {
            transaction.commit()?;
            return Ok(OperatorAllowlistClaimOutcome::NotPending(
                OperatorAllowlistState::Applying,
            ));
        }
        record.state = if decision == OperatorAllowlistDecision::Allow {
            OperatorAllowlistState::Applying
        } else {
            OperatorAllowlistState::Cancelled
        };
        record.resolved_at = Some(context.now);
        record.claimed_event_id = Some(context.event_id.clone());
        record.resolved_by_user_id = Some(context.actor_user_id);
        transaction.commit()?;
        Ok(match decision {
            OperatorAllowlistDecision::Allow => OperatorAllowlistClaimOutcome::Claimed(record),
            OperatorAllowlistDecision::Cancel => OperatorAllowlistClaimOutcome::Cancelled(record),
        })
    }

    pub fn finish_operator_allowlist_request(
        &self,
        callback_token: &str,
        succeeded: bool,
        resolved_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let state = if succeeded { "applied" } else { "failed" };
        let changed = connection.execute(
            "UPDATE operator_allowlist_requests SET state = ?2, resolved_at = ?3
             WHERE callback_token = ?1 AND state = 'applying'",
            params![callback_token, state, resolved_at],
        )?;
        Ok(changed == 1)
    }
}

fn validate_pending(request: &PendingOperatorAllowlistRequest) -> StoreResult<()> {
    if request.callback_token.trim().is_empty()
        || request.owner_user_id <= 0
        || request.target_user_id <= 0
        || request.origin_chat_id <= 0
        || request.expires_at <= request.created_at
    {
        return Err(StoreError::InvalidIdentifier {
            kind: "operator allowlist request",
            value: request.callback_token.clone(),
        });
    }
    Ok(())
}

fn read_request(
    connection: &Connection,
    callback_token: &str,
) -> StoreResult<Option<OperatorAllowlistRequest>> {
    let raw = connection
        .query_row(
            "SELECT installation_id, provider_id, owner_user_id, target_user_id,
                    origin_chat_id, card_message_id, state, claimed_event_id,
                    resolved_by_user_id, created_at, expires_at, resolved_at
             FROM operator_allowlist_requests WHERE callback_token = ?1",
            params![callback_token],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<i64>>(8)?,
                    row.get::<_, i64>(9)?,
                    row.get::<_, i64>(10)?,
                    row.get::<_, Option<i64>>(11)?,
                ))
            },
        )
        .optional()?;
    let Some((
        installation_id,
        provider_id,
        owner_user_id,
        target_user_id,
        origin_chat_id,
        card_message_id,
        state,
        claimed_event_id,
        resolved_by_user_id,
        created_at,
        expires_at,
        resolved_at,
    )) = raw
    else {
        return Ok(None);
    };
    Ok(Some(OperatorAllowlistRequest {
        callback_token: callback_token.to_string(),
        installation_id: parse_installation_id(installation_id)?,
        provider_id: parse_provider_id(provider_id)?,
        owner_user_id,
        target_user_id,
        origin_chat_id,
        card_message_id,
        state: OperatorAllowlistState::parse(state)?,
        claimed_event_id,
        resolved_by_user_id,
        created_at,
        expires_at,
        resolved_at,
    }))
}

pub(super) fn migrate_v13(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE operator_allowlist_requests (
            callback_token TEXT PRIMARY KEY NOT NULL,
            installation_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            owner_user_id INTEGER NOT NULL,
            target_user_id INTEGER NOT NULL,
            origin_chat_id INTEGER NOT NULL,
            card_message_id INTEGER,
            state TEXT NOT NULL CHECK (
                state IN ('pending', 'applying', 'applied', 'cancelled', 'expired', 'failed')
            ),
            claimed_event_id TEXT,
            resolved_by_user_id INTEGER,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            resolved_at INTEGER
         );
         CREATE INDEX operator_allowlist_requests_open
         ON operator_allowlist_requests (installation_id, provider_id, state, expires_at);
         PRAGMA user_version = 13;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending() -> PendingOperatorAllowlistRequest {
        PendingOperatorAllowlistRequest {
            callback_token: "allow-token".to_string(),
            installation_id: InstallationId::new("codex").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            owner_user_id: 7,
            target_user_id: 9,
            origin_chat_id: 11,
            created_at: 100,
            expires_at: 200,
        }
    }

    #[test]
    fn owner_claim_is_one_shot_and_context_bound() {
        let store = BridgeStore::open_in_memory().expect("store");
        assert!(
            store
                .insert_operator_allowlist_request(&pending())
                .expect("insert")
        );
        assert!(
            store
                .attach_operator_allowlist_message("allow-token", 13)
                .expect("attach")
        );
        let context = OperatorAllowlistClaimContext {
            installation_id: InstallationId::new("codex").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            actor_user_id: 7,
            action_chat_id: 11,
            action_message_id: 13,
            event_id: "action-1".to_string(),
            now: 110,
        };
        assert!(matches!(
            store
                .claim_operator_allowlist_request(
                    "allow-token",
                    OperatorAllowlistDecision::Allow,
                    &context,
                )
                .expect("claim"),
            OperatorAllowlistClaimOutcome::Claimed(_)
        ));
        assert!(matches!(
            store
                .claim_operator_allowlist_request(
                    "allow-token",
                    OperatorAllowlistDecision::Allow,
                    &context,
                )
                .expect("repeat"),
            OperatorAllowlistClaimOutcome::Resumable(_)
        ));
        assert!(
            store
                .finish_operator_allowlist_request("allow-token", true, 111)
                .expect("finish")
        );
    }

    #[test]
    fn non_owner_cannot_claim() {
        let store = BridgeStore::open_in_memory().expect("store");
        store
            .insert_operator_allowlist_request(&pending())
            .expect("insert");
        store
            .attach_operator_allowlist_message("allow-token", 13)
            .expect("attach");
        let outcome = store
            .claim_operator_allowlist_request(
                "allow-token",
                OperatorAllowlistDecision::Cancel,
                &OperatorAllowlistClaimContext {
                    installation_id: InstallationId::new("codex").expect("installation"),
                    provider_id: ProviderId::new("codex").expect("provider"),
                    actor_user_id: 8,
                    action_chat_id: 11,
                    action_message_id: 13,
                    event_id: "action-2".to_string(),
                    now: 110,
                },
            )
            .expect("claim");
        assert_eq!(outcome, OperatorAllowlistClaimOutcome::Unauthorized);
    }
}

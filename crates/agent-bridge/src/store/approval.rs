use rusqlite::{Connection, OptionalExtension, params};

use crate::{ApprovalDecision, InstallationId, ProviderId, TurnId};

use super::{
    BridgeStore, StoreError, StoreResult, parse_installation_id, parse_provider_id, parse_turn_id,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApprovalState {
    Pending,
    Resolving,
    Resolved,
    Invalidated,
    Expired,
}

impl ApprovalState {
    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "pending" => Ok(Self::Pending),
            "resolving" => Ok(Self::Resolving),
            "resolved" => Ok(Self::Resolved),
            "invalidated" => Ok(Self::Invalidated),
            "expired" => Ok(Self::Expired),
            _ => Err(StoreError::UnknownApprovalState(value)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingApproval {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub provider_approval_id: String,
    pub turn_id: TurnId,
    pub origin_chat_id: i64,
    pub action_chat_id: i64,
    pub message_id: Option<i64>,
    pub origin_status_message_id: Option<i64>,
    pub decisions: Vec<ApprovalDecision>,
    pub created_at: i64,
    pub expires_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovalRecord {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub provider_approval_id: String,
    pub turn_id: TurnId,
    pub origin_chat_id: i64,
    pub action_chat_id: i64,
    pub message_id: Option<i64>,
    pub origin_status_message_id: Option<i64>,
    pub decisions: Vec<ApprovalDecision>,
    pub state: ApprovalState,
    pub selected_option: Option<usize>,
    pub resolved_by_user_id: Option<i64>,
    pub created_at: i64,
    pub expires_at: i64,
    pub resolved_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovalClaim {
    pub record: ApprovalRecord,
    pub decision: ApprovalDecision,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovalClaimContext {
    pub installation_id: InstallationId,
    pub turn_id: TurnId,
    pub origin_chat_id: i64,
    pub action_chat_id: i64,
    pub actor_user_id: i64,
    pub allowed_actor_user_id: i64,
    pub now: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApprovalClaimOutcome {
    Claimed(Box<ApprovalClaim>),
    Unknown,
    Unauthorized,
    WrongContext,
    InvalidOption,
    Expired,
    NotPending(ApprovalState),
}

impl BridgeStore {
    pub fn insert_approval(&self, approval: &PendingApproval) -> StoreResult<bool> {
        validate_pending(approval)?;
        let decisions = serde_json::to_string(&approval.decisions)?;
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "INSERT OR IGNORE INTO approval_requests (
                callback_token, installation_id, provider_id, provider_approval_id,
                turn_id, chat_id, action_chat_id, message_id, decisions_json, state,
                origin_status_message_id, selected_option, resolved_by_user_id,
                created_at, expires_at, resolved_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'pending', ?10, NULL, NULL, ?11, ?12, NULL)",
            params![
                approval.callback_token,
                approval.installation_id.as_str(),
                approval.provider_id.as_str(),
                approval.provider_approval_id,
                approval.turn_id.as_str(),
                approval.origin_chat_id,
                approval.action_chat_id,
                approval.message_id,
                decisions,
                approval.origin_status_message_id,
                approval.created_at,
                approval.expires_at,
            ],
        )?;
        Ok(changed == 1)
    }

    pub fn attach_approval_message(
        &self,
        callback_token: &str,
        message_id: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE approval_requests SET message_id = ?2
             WHERE callback_token = ?1 AND state IN ('pending', 'resolving') AND message_id IS NULL",
            params![callback_token, message_id],
        )?;
        Ok(changed == 1)
    }

    pub fn attach_approval_origin_status_message(
        &self,
        callback_token: &str,
        message_id: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE approval_requests SET origin_status_message_id = ?2
             WHERE callback_token = ?1 AND state = 'pending'
               AND origin_status_message_id IS NULL",
            params![callback_token, message_id],
        )?;
        Ok(changed == 1)
    }

    pub fn get_approval(&self, callback_token: &str) -> StoreResult<Option<ApprovalRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        read_approval(&connection, callback_token)
    }

    pub fn close_provider_approval(
        &self,
        provider_id: &ProviderId,
        turn_id: &TurnId,
        provider_approval_id: &str,
        now: i64,
    ) -> StoreResult<Option<ApprovalRecord>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let token = transaction
            .query_row(
                "SELECT callback_token FROM approval_requests
                 WHERE provider_id = ?1 AND turn_id = ?2 AND provider_approval_id = ?3
                   AND state IN ('pending', 'resolving')",
                params![provider_id.as_str(), turn_id.as_str(), provider_approval_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(token) = token else {
            transaction.commit()?;
            return Ok(None);
        };
        let mut record =
            read_approval(&transaction, &token)?.ok_or_else(|| StoreError::InvalidIdentifier {
                kind: "approval callback token",
                value: token.clone(),
            })?;
        if transaction.execute(
            "UPDATE approval_requests SET state = 'invalidated', resolved_at = ?2
             WHERE callback_token = ?1 AND state IN ('pending', 'resolving')",
            params![token, now],
        )? != 1
        {
            transaction.commit()?;
            return Ok(None);
        }
        record.state = ApprovalState::Invalidated;
        record.resolved_at = Some(now);
        transaction.commit()?;
        Ok(Some(record))
    }

    /// Claims one choice before calling the provider. Only the configured
    /// approver can move a pending request into the resolving state.
    pub fn claim_approval(
        &self,
        callback_token: &str,
        option_index: usize,
        context: &ApprovalClaimContext,
    ) -> StoreResult<ApprovalClaimOutcome> {
        if context.actor_user_id <= 0 || context.actor_user_id != context.allowed_actor_user_id {
            return Ok(ApprovalClaimOutcome::Unauthorized);
        }
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let Some(mut record) = read_approval(&transaction, callback_token)? else {
            transaction.commit()?;
            return Ok(ApprovalClaimOutcome::Unknown);
        };
        if record.state != ApprovalState::Pending {
            let state = record.state;
            transaction.commit()?;
            return Ok(ApprovalClaimOutcome::NotPending(state));
        }
        if record.installation_id != context.installation_id
            || record.turn_id != context.turn_id
            || record.origin_chat_id != context.origin_chat_id
            || record.action_chat_id != context.action_chat_id
        {
            transaction.commit()?;
            return Ok(ApprovalClaimOutcome::WrongContext);
        }
        if record.expires_at <= context.now {
            transaction.execute(
                "UPDATE approval_requests SET state = 'expired', resolved_at = ?2
                 WHERE callback_token = ?1 AND state = 'pending'",
                params![callback_token, context.now],
            )?;
            transaction.commit()?;
            return Ok(ApprovalClaimOutcome::Expired);
        }
        let Some(decision) = record.decisions.get(option_index).cloned() else {
            transaction.commit()?;
            return Ok(ApprovalClaimOutcome::InvalidOption);
        };
        let changed = transaction.execute(
            "UPDATE approval_requests SET
                state = 'resolving', selected_option = ?2,
                resolved_by_user_id = ?3, resolved_at = ?4
             WHERE callback_token = ?1 AND state = 'pending'",
            params![
                callback_token,
                option_index as i64,
                context.actor_user_id,
                context.now
            ],
        )?;
        if changed != 1 {
            transaction.commit()?;
            return Ok(ApprovalClaimOutcome::NotPending(ApprovalState::Resolving));
        }
        record.state = ApprovalState::Resolving;
        record.selected_option = Some(option_index);
        record.resolved_by_user_id = Some(context.actor_user_id);
        record.resolved_at = Some(context.now);
        transaction.commit()?;
        Ok(ApprovalClaimOutcome::Claimed(Box::new(ApprovalClaim {
            record,
            decision,
        })))
    }

    pub fn complete_approval(
        &self,
        callback_token: &str,
        actor_user_id: i64,
        resolved_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE approval_requests SET state = 'resolved', resolved_at = ?3
             WHERE callback_token = ?1 AND state = 'resolving'
               AND resolved_by_user_id = ?2",
            params![callback_token, actor_user_id, resolved_at],
        )?;
        Ok(changed == 1)
    }

    /// Terminalizes a choice whose provider delivery began but could not be
    /// confirmed. The one-shot provider responder may already have acted, so
    /// this state must never become retryable.
    pub fn fail_approval_dispatch(
        &self,
        callback_token: &str,
        actor_user_id: i64,
        resolved_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE approval_requests SET state = 'invalidated', resolved_at = ?3
             WHERE callback_token = ?1 AND state = 'resolving'
               AND resolved_by_user_id = ?2",
            params![callback_token, actor_user_id, resolved_at],
        )?;
        Ok(changed == 1)
    }

    pub fn open_approvals_for_installation(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Vec<ApprovalRecord>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let tokens = {
            let mut statement = connection.prepare(
                "SELECT callback_token FROM approval_requests
                 WHERE installation_id = ?1 AND state IN ('pending', 'resolving')
                 ORDER BY created_at ASC, callback_token ASC",
            )?;
            statement
                .query_map(params![installation_id.as_str()], |row| {
                    row.get::<_, String>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        tokens
            .into_iter()
            .filter_map(|token| read_approval(&connection, &token).transpose())
            .collect()
    }

    pub fn invalidate_turn_approvals(&self, turn_id: &TurnId, now: i64) -> StoreResult<usize> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE approval_requests SET state = 'invalidated', resolved_at = ?2
             WHERE turn_id = ?1 AND state IN ('pending', 'resolving')",
            params![turn_id.as_str(), now],
        )?;
        Ok(changed)
    }

    /// Invalidates requests left open across a bridge process restart and
    /// returns their message locations so the host can remove stale buttons.
    pub fn invalidate_open_approvals(&self, now: i64) -> StoreResult<Vec<ApprovalRecord>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let tokens = {
            let mut statement = transaction.prepare(
                "SELECT callback_token FROM approval_requests
                 WHERE state IN ('pending', 'resolving')
                 ORDER BY created_at ASC, callback_token ASC",
            )?;
            statement
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut records = Vec::with_capacity(tokens.len());
        for token in tokens {
            if let Some(record) = read_approval(&transaction, &token)? {
                records.push(record);
            }
        }
        transaction.execute(
            "UPDATE approval_requests SET state = 'invalidated', resolved_at = ?1
             WHERE state IN ('pending', 'resolving')",
            params![now],
        )?;
        transaction.commit()?;
        Ok(records)
    }

    pub fn invalidate_open_approvals_for_installation(
        &self,
        installation_id: &InstallationId,
        now: i64,
    ) -> StoreResult<Vec<ApprovalRecord>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let tokens = {
            let mut statement = transaction.prepare(
                "SELECT callback_token FROM approval_requests
                 WHERE installation_id = ?1 AND state IN ('pending', 'resolving')
                 ORDER BY created_at ASC, callback_token ASC",
            )?;
            statement
                .query_map(params![installation_id.as_str()], |row| {
                    row.get::<_, String>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut records = Vec::with_capacity(tokens.len());
        for token in tokens {
            if let Some(record) = read_approval(&transaction, &token)? {
                records.push(record);
            }
        }
        transaction.execute(
            "UPDATE approval_requests SET state = 'invalidated', resolved_at = ?2
             WHERE installation_id = ?1 AND state IN ('pending', 'resolving')",
            params![installation_id.as_str(), now],
        )?;
        transaction.commit()?;
        Ok(records)
    }

    pub fn expire_approvals(&self, now: i64) -> StoreResult<usize> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE approval_requests SET state = 'expired', resolved_at = ?1
             WHERE state = 'pending' AND expires_at <= ?1",
            params![now],
        )?;
        Ok(changed)
    }

    /// Atomically expires pending approvals for one active turn and returns
    /// exactly the records won by this expiry pass.
    pub fn expire_turn_approvals(
        &self,
        turn_id: &TurnId,
        now: i64,
    ) -> StoreResult<Vec<ApprovalRecord>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let tokens = {
            let mut statement = transaction.prepare(
                "SELECT callback_token FROM approval_requests
                 WHERE turn_id = ?1 AND state = 'pending' AND expires_at <= ?2
                 ORDER BY created_at ASC, callback_token ASC",
            )?;
            statement
                .query_map(params![turn_id.as_str(), now], |row| {
                    row.get::<_, String>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut expired = Vec::with_capacity(tokens.len());
        for token in tokens {
            if transaction.execute(
                "UPDATE approval_requests SET state = 'expired', resolved_at = ?2
                 WHERE callback_token = ?1 AND state = 'pending' AND expires_at <= ?2",
                params![token, now],
            )? == 1
                && let Some(mut record) = read_approval(&transaction, &token)?
            {
                record.state = ApprovalState::Expired;
                record.resolved_at = Some(now);
                expired.push(record);
            }
        }
        transaction.commit()?;
        Ok(expired)
    }
}

pub(super) fn migrate_v3(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE approval_requests (
            callback_token TEXT PRIMARY KEY NOT NULL,
            installation_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            provider_approval_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            chat_id INTEGER NOT NULL,
            message_id INTEGER,
            decisions_json TEXT NOT NULL,
            state TEXT NOT NULL CHECK (
                state IN ('pending', 'resolving', 'resolved', 'invalidated', 'expired')
            ),
            selected_option INTEGER,
            resolved_by_user_id INTEGER,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            resolved_at INTEGER,
            UNIQUE (installation_id, provider_id, turn_id, provider_approval_id)
         );
         CREATE INDEX approval_requests_open_turn
         ON approval_requests (turn_id, state, created_at);
         CREATE INDEX approval_requests_expiry
         ON approval_requests (state, expires_at);
         PRAGMA user_version = 3;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v7(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE approval_requests ADD COLUMN action_chat_id INTEGER;
         UPDATE approval_requests SET action_chat_id = chat_id
         WHERE action_chat_id IS NULL;
         PRAGMA user_version = 7;
         COMMIT;",
    )?;
    Ok(())
}

pub(super) fn migrate_v8(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         ALTER TABLE approval_requests ADD COLUMN origin_status_message_id INTEGER;
         PRAGMA user_version = 8;
         COMMIT;",
    )?;
    Ok(())
}

fn validate_pending(approval: &PendingApproval) -> StoreResult<()> {
    if approval.callback_token.trim().is_empty() {
        return Err(invalid("approval callback token", &approval.callback_token));
    }
    if approval.provider_approval_id.trim().is_empty() {
        return Err(invalid(
            "provider approval id",
            &approval.provider_approval_id,
        ));
    }
    if approval.origin_chat_id <= 0 {
        return Err(invalid(
            "approval origin chat id",
            approval.origin_chat_id.to_string(),
        ));
    }
    if approval.action_chat_id <= 0 {
        return Err(invalid(
            "approval action chat id",
            approval.action_chat_id.to_string(),
        ));
    }
    if approval.decisions.is_empty() {
        return Err(invalid("approval decisions", "empty"));
    }
    if approval.expires_at <= approval.created_at {
        return Err(invalid("approval expiry", approval.expires_at.to_string()));
    }
    Ok(())
}

fn invalid(kind: &'static str, value: impl Into<String>) -> StoreError {
    StoreError::InvalidIdentifier {
        kind,
        value: value.into(),
    }
}

fn read_approval(
    connection: &Connection,
    callback_token: &str,
) -> StoreResult<Option<ApprovalRecord>> {
    let raw = connection
        .query_row(
            "SELECT installation_id, provider_id, provider_approval_id, turn_id,
                    chat_id, COALESCE(action_chat_id, chat_id), message_id,
                    origin_status_message_id, decisions_json, state,
                    selected_option, resolved_by_user_id, created_at,
                    expires_at, resolved_at
             FROM approval_requests WHERE callback_token = ?1",
            params![callback_token],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                    row.get::<_, Option<i64>>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, String>(9)?,
                    row.get::<_, Option<i64>>(10)?,
                    row.get::<_, Option<i64>>(11)?,
                    row.get::<_, i64>(12)?,
                    row.get::<_, i64>(13)?,
                    row.get::<_, Option<i64>>(14)?,
                ))
            },
        )
        .optional()?;
    let Some((
        installation_id,
        provider_id,
        provider_approval_id,
        turn_id,
        origin_chat_id,
        action_chat_id,
        message_id,
        origin_status_message_id,
        decisions,
        state,
        selected_option,
        resolved_by_user_id,
        created_at,
        expires_at,
        resolved_at,
    )) = raw
    else {
        return Ok(None);
    };
    let selected_option = selected_option
        .map(|value| {
            usize::try_from(value)
                .map_err(|_| invalid("approval selected option", value.to_string()))
        })
        .transpose()?;
    Ok(Some(ApprovalRecord {
        callback_token: callback_token.to_string(),
        installation_id: parse_installation_id(installation_id)?,
        provider_id: parse_provider_id(provider_id)?,
        provider_approval_id,
        turn_id: parse_turn_id(turn_id)?,
        origin_chat_id,
        action_chat_id,
        message_id,
        origin_status_message_id,
        decisions: serde_json::from_str(&decisions)?,
        state: ApprovalState::parse(state)?,
        selected_option,
        resolved_by_user_id,
        created_at,
        expires_at,
        resolved_at,
    }))
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Barrier};

    use super::*;

    fn pending(token: &str) -> PendingApproval {
        PendingApproval {
            callback_token: token.to_string(),
            installation_id: InstallationId::new("codex-install").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            provider_approval_id: format!("provider-{token}"),
            turn_id: TurnId::new(format!("turn-{token}")).expect("turn"),
            origin_chat_id: 42,
            action_chat_id: 84,
            message_id: None,
            origin_status_message_id: None,
            decisions: vec![ApprovalDecision::ApproveOnce, ApprovalDecision::Reject],
            created_at: 100,
            expires_at: 200,
        }
    }

    fn context(turn_id: &TurnId, actor_user_id: i64, now: i64) -> ApprovalClaimContext {
        ApprovalClaimContext {
            installation_id: InstallationId::new("codex-install").expect("installation"),
            turn_id: turn_id.clone(),
            origin_chat_id: 42,
            action_chat_id: 84,
            actor_user_id,
            allowed_actor_user_id: 7,
            now,
        }
    }

    #[test]
    fn approval_is_inserted_and_message_is_attached_once() {
        let store = BridgeStore::open_in_memory().expect("store");
        let approval = pending("a1");
        assert!(store.insert_approval(&approval).expect("insert"));
        assert!(!store.insert_approval(&approval).expect("duplicate"));
        assert!(store.attach_approval_message("a1", 7).expect("attach"));
        assert!(!store.attach_approval_message("a1", 8).expect("reattach"));
        assert!(
            store
                .attach_approval_origin_status_message("a1", 9)
                .expect("attach origin")
        );
        assert!(
            !store
                .attach_approval_origin_status_message("a1", 10)
                .expect("reattach origin")
        );
        let stored = store.get_approval("a1").expect("get").expect("approval");
        assert_eq!(stored.message_id, Some(7));
        assert_eq!(stored.origin_status_message_id, Some(9));
        assert_eq!(stored.origin_chat_id, 42);
        assert_eq!(stored.action_chat_id, 84);
        assert_eq!(stored.state, ApprovalState::Pending);
    }

    #[test]
    fn approval_claim_requires_both_origin_and_private_action_chat() {
        let store = BridgeStore::open_in_memory().expect("store");
        let approval = pending("a1");
        store.insert_approval(&approval).expect("insert");

        let mut wrong_origin = context(&approval.turn_id, 7, 150);
        wrong_origin.origin_chat_id = 43;
        assert_eq!(
            store
                .claim_approval("a1", 0, &wrong_origin)
                .expect("wrong origin"),
            ApprovalClaimOutcome::WrongContext
        );

        let mut wrong_action = context(&approval.turn_id, 7, 150);
        wrong_action.action_chat_id = 42;
        assert_eq!(
            store
                .claim_approval("a1", 0, &wrong_action)
                .expect("wrong action chat"),
            ApprovalClaimOutcome::WrongContext
        );

        assert!(matches!(
            store
                .claim_approval("a1", 0, &context(&approval.turn_id, 7, 150))
                .expect("valid claim"),
            ApprovalClaimOutcome::Claimed(_)
        ));
    }

    #[test]
    fn only_allowed_actor_can_claim_once() {
        let store = BridgeStore::open_in_memory().expect("store");
        let approval = pending("a1");
        store.insert_approval(&approval).expect("insert");
        assert_eq!(
            store
                .claim_approval("a1", 0, &context(&approval.turn_id, 8, 150))
                .expect("deny"),
            ApprovalClaimOutcome::Unauthorized
        );
        let claimed = store
            .claim_approval("a1", 0, &context(&approval.turn_id, 7, 150))
            .expect("claim");
        let ApprovalClaimOutcome::Claimed(claimed) = claimed else {
            panic!("expected claim");
        };
        assert_eq!(claimed.decision, ApprovalDecision::ApproveOnce);
        assert_eq!(claimed.record.resolved_by_user_id, Some(7));
        assert_eq!(
            store
                .claim_approval("a1", 0, &context(&approval.turn_id, 7, 151))
                .expect("repeat"),
            ApprovalClaimOutcome::NotPending(ApprovalState::Resolving)
        );
        assert!(store.complete_approval("a1", 7, 152).expect("complete"));
        assert!(
            !store
                .complete_approval("a1", 7, 153)
                .expect("repeat complete")
        );
    }

    #[test]
    fn ambiguous_provider_resolution_is_terminal() {
        let store = BridgeStore::open_in_memory().expect("store");
        let approval = pending("a1");
        store.insert_approval(&approval).expect("insert");
        let _ = store
            .claim_approval("a1", 1, &context(&approval.turn_id, 7, 150))
            .expect("claim");
        assert!(
            store
                .fail_approval_dispatch("a1", 7, 151)
                .expect("terminalize")
        );
        assert_eq!(
            store
                .claim_approval("a1", 1, &context(&approval.turn_id, 7, 151))
                .expect("retry denied"),
            ApprovalClaimOutcome::NotPending(ApprovalState::Invalidated)
        );
    }

    #[test]
    fn expired_and_invalid_choices_do_not_resolve() {
        let store = BridgeStore::open_in_memory().expect("store");
        let expired = pending("expired");
        store.insert_approval(&expired).expect("insert");
        assert_eq!(
            store
                .claim_approval("expired", 0, &context(&expired.turn_id, 7, 200))
                .expect("expire"),
            ApprovalClaimOutcome::Expired
        );
        let option = pending("option");
        store.insert_approval(&option).expect("insert");
        assert_eq!(
            store
                .claim_approval("option", 9, &context(&option.turn_id, 7, 150))
                .expect("invalid option"),
            ApprovalClaimOutcome::InvalidOption
        );
    }

    #[test]
    fn active_expiry_returns_only_the_pending_turn_winners() {
        let store = BridgeStore::open_in_memory().expect("store");
        let due = pending("due");
        let future = PendingApproval {
            expires_at: 300,
            ..pending("future")
        };
        store.insert_approval(&due).expect("insert due");
        store.insert_approval(&future).expect("insert future");

        let expired = store
            .expire_turn_approvals(&due.turn_id, 200)
            .expect("expire turn");
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].callback_token, "due");
        assert_eq!(expired[0].state, ApprovalState::Expired);
        assert!(
            store
                .expire_turn_approvals(&due.turn_id, 201)
                .expect("repeat expiry")
                .is_empty()
        );
        assert_eq!(
            store
                .get_approval("future")
                .expect("get future")
                .expect("future")
                .state,
            ApprovalState::Pending
        );
    }

    #[test]
    fn provider_withdrawal_closes_the_matching_card_once() {
        let store = BridgeStore::open_in_memory().expect("store");
        let approval = pending("withdrawn");
        store.insert_approval(&approval).expect("insert");
        let closed = store
            .close_provider_approval(
                &approval.provider_id,
                &approval.turn_id,
                &approval.provider_approval_id,
                150,
            )
            .expect("close")
            .expect("record");
        assert_eq!(closed.state, ApprovalState::Invalidated);
        assert!(
            store
                .close_provider_approval(
                    &approval.provider_id,
                    &approval.turn_id,
                    &approval.provider_approval_id,
                    151,
                )
                .expect("repeat close")
                .is_none()
        );
    }

    #[test]
    fn terminal_turn_invalidates_open_approvals() {
        let store = BridgeStore::open_in_memory().expect("store");
        let approval = pending("a1");
        let turn_id = approval.turn_id.clone();
        store.insert_approval(&approval).expect("insert");
        assert_eq!(
            store
                .invalidate_turn_approvals(&turn_id, 175)
                .expect("invalidate"),
            1
        );
        assert_eq!(
            store
                .claim_approval("a1", 0, &context(&turn_id, 7, 176))
                .expect("stale claim"),
            ApprovalClaimOutcome::NotPending(ApprovalState::Invalidated)
        );
    }

    #[test]
    fn terminal_invalidation_wins_the_race_with_an_owner_claim() {
        let store = Arc::new(BridgeStore::open_in_memory().expect("store"));
        let approval = pending("race");
        let turn_id = approval.turn_id.clone();
        store.insert_approval(&approval).expect("insert");
        let barrier = Arc::new(Barrier::new(3));

        let claim_store = store.clone();
        let claim_barrier = barrier.clone();
        let claim_approval = approval.clone();
        let claim = std::thread::spawn(move || {
            claim_barrier.wait();
            claim_store
                .claim_approval(
                    &claim_approval.callback_token,
                    0,
                    &context(&claim_approval.turn_id, 7, 150),
                )
                .expect("claim race")
        });
        let invalidate_store = store.clone();
        let invalidate_barrier = barrier.clone();
        let invalidate_turn = turn_id.clone();
        let invalidate = std::thread::spawn(move || {
            invalidate_barrier.wait();
            invalidate_store
                .invalidate_turn_approvals(&invalidate_turn, 151)
                .expect("invalidate race")
        });
        barrier.wait();

        let claim = claim.join().expect("claim thread");
        let invalidated = invalidate.join().expect("invalidate thread");
        assert!(matches!(
            claim,
            ApprovalClaimOutcome::Claimed(_)
                | ApprovalClaimOutcome::NotPending(ApprovalState::Invalidated)
        ));
        assert!(invalidated <= 1);
        assert_eq!(
            store
                .get_approval(&approval.callback_token)
                .expect("get")
                .expect("approval")
                .state,
            ApprovalState::Invalidated
        );
        assert!(
            !store
                .complete_approval(&approval.callback_token, 7, 152)
                .expect("late complete")
        );
        assert!(
            !store
                .fail_approval_dispatch(&approval.callback_token, 7, 153)
                .expect("late failure")
        );
    }

    #[test]
    fn restart_returns_and_invalidates_all_open_approval_messages() {
        let store = BridgeStore::open_in_memory().expect("store");
        let first = pending("a1");
        let second = pending("a2");
        store.insert_approval(&first).expect("insert first");
        store.insert_approval(&second).expect("insert second");
        store.attach_approval_message("a1", 10).expect("attach");
        let _ = store
            .claim_approval("a2", 0, &context(&second.turn_id, 7, 150))
            .expect("claim");

        let interrupted = store
            .invalidate_open_approvals(160)
            .expect("invalidate open");
        assert_eq!(interrupted.len(), 2);
        assert_eq!(interrupted[0].message_id, Some(10));
        assert!(interrupted.iter().any(|record| {
            record.callback_token == "a2" && record.state == ApprovalState::Resolving
        }));
        assert!(
            store
                .invalidate_open_approvals(161)
                .expect("already invalidated")
                .is_empty()
        );
    }
}

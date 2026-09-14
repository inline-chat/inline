use rusqlite::{Connection, OptionalExtension, params};

use crate::{InstallationId, ProviderId, WorkspaceId};

use super::{
    BridgeStore, StoreError, StoreResult, parse_installation_id, parse_provider_id,
    parse_workspace_id,
};

const MAX_PROMPT_BYTES: usize = 8 * 1024;
const MAX_CATALOG_FINGERPRINT_BYTES: usize = 128;
const MAX_DOCUMENT_REVISION_BYTES: usize = 256;
const MAX_SELECTED_VALUE_BYTES: usize = 512;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommandChoiceState {
    Pending,
    Applying,
    Applied,
    Cancelled,
    Expired,
    Failed,
}

impl CommandChoiceState {
    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "pending" => Ok(Self::Pending),
            "applying" => Ok(Self::Applying),
            "applied" => Ok(Self::Applied),
            "cancelled" => Ok(Self::Cancelled),
            "expired" => Ok(Self::Expired),
            "failed" => Ok(Self::Failed),
            _ => Err(StoreError::UnknownCommandChoiceState(value)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingCommandChoiceRequest {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub workspace_id: WorkspaceId,
    pub bot_user_id: i64,
    pub actor_user_id: i64,
    pub requires_owner: bool,
    pub origin_chat_id: i64,
    pub origin_message_id: i64,
    pub item_id: String,
    pub prompt_text: String,
    pub catalog_fingerprint: String,
    pub document_revision: String,
    pub page: i64,
    pub page_count: i64,
    pub created_at: i64,
    pub expires_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandChoiceRequest {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub workspace_id: WorkspaceId,
    pub bot_user_id: i64,
    pub actor_user_id: i64,
    pub requires_owner: bool,
    pub origin_chat_id: i64,
    pub origin_message_id: i64,
    pub card_message_id: Option<i64>,
    pub item_id: String,
    pub prompt_text: String,
    pub catalog_fingerprint: String,
    pub document_revision: String,
    pub page: i64,
    pub page_count: i64,
    pub state: CommandChoiceState,
    pub selected_value: Option<String>,
    pub claimed_event_id: Option<String>,
    pub resolved_by_user_id: Option<i64>,
    pub created_at: i64,
    pub expires_at: i64,
    pub resolved_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandChoiceClaimContext {
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub workspace_id: WorkspaceId,
    pub bot_user_id: i64,
    pub actor_user_id: i64,
    pub current_owner_user_id: i64,
    pub actor_still_authorized: bool,
    pub action_chat_id: i64,
    pub action_message_id: i64,
    pub event_id: String,
    pub catalog_fingerprint: String,
    pub document_revision: String,
    pub page_count: i64,
    pub now: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandChoiceAction {
    Select { value: String },
    Page { page: i64 },
    Cancel,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandChoiceClaimOutcome {
    Claimed(CommandChoiceRequest),
    Resumable(CommandChoiceRequest),
    Navigated(CommandChoiceRequest),
    Cancelled(CommandChoiceRequest),
    Unknown,
    Unauthorized,
    WrongContext,
    Refreshed(CommandChoiceRequest),
    InvalidChoice,
    Expired(CommandChoiceRequest),
    NotPending(CommandChoiceState),
}

impl BridgeStore {
    pub fn insert_command_choice_request(
        &self,
        request: &PendingCommandChoiceRequest,
    ) -> StoreResult<bool> {
        validate_pending(request)?;
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "INSERT OR IGNORE INTO command_choice_requests (
                callback_token, installation_id, provider_id, workspace_id,
                bot_user_id, actor_user_id, requires_owner, origin_chat_id, origin_message_id, card_message_id,
                item_id, prompt_text, catalog_fingerprint, document_revision,
                page, page_count, state, selected_value, claimed_event_id,
                resolved_by_user_id, created_at, expires_at, resolved_at
             ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL, ?10, ?11, ?12, ?13,
                ?14, ?15, 'pending', NULL, NULL, NULL, ?16, ?17, NULL
             )",
            params![
                request.callback_token,
                request.installation_id.as_str(),
                request.provider_id.as_str(),
                request.workspace_id.as_str(),
                request.bot_user_id,
                request.actor_user_id,
                request.requires_owner,
                request.origin_chat_id,
                request.origin_message_id,
                request.item_id,
                request.prompt_text,
                request.catalog_fingerprint,
                request.document_revision,
                request.page,
                request.page_count,
                request.created_at,
                request.expires_at,
            ],
        )?;
        Ok(changed == 1)
    }

    pub fn attach_command_choice_message(
        &self,
        callback_token: &str,
        message_id: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let changed = connection.execute(
            "UPDATE command_choice_requests SET card_message_id = ?2
             WHERE callback_token = ?1 AND state = 'pending' AND card_message_id IS NULL",
            params![callback_token, message_id],
        )?;
        Ok(changed == 1)
    }

    pub fn get_command_choice_request(
        &self,
        callback_token: &str,
    ) -> StoreResult<Option<CommandChoiceRequest>> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        read_request(&connection, callback_token)
    }

    pub fn claim_command_choice_request(
        &self,
        callback_token: &str,
        action: &CommandChoiceAction,
        legal_values: &[String],
        context: &CommandChoiceClaimContext,
    ) -> StoreResult<CommandChoiceClaimOutcome> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let Some(mut record) = read_request(&transaction, callback_token)? else {
            transaction.commit()?;
            return Ok(CommandChoiceClaimOutcome::Unknown);
        };
        if context.actor_user_id != record.actor_user_id
            || !context.actor_still_authorized
            || (record.requires_owner && context.actor_user_id != context.current_owner_user_id)
        {
            transaction.commit()?;
            return Ok(CommandChoiceClaimOutcome::Unauthorized);
        }
        let workspace_matches = context.workspace_id == record.workspace_id
            || (record.state == CommandChoiceState::Applying
                && record.item_id == "workspace.folder"
                && record.selected_value.as_deref() == Some(context.workspace_id.as_str()));
        if context.installation_id != record.installation_id
            || context.provider_id != record.provider_id
            || context.bot_user_id != record.bot_user_id
            || !workspace_matches
            || context.action_chat_id != record.origin_chat_id
            || record.card_message_id != Some(context.action_message_id)
        {
            transaction.commit()?;
            return Ok(CommandChoiceClaimOutcome::WrongContext);
        }
        if record.state == CommandChoiceState::Applying {
            if let CommandChoiceAction::Select { value } = action
                && record.selected_value.as_deref() == Some(value)
            {
                transaction.commit()?;
                return Ok(CommandChoiceClaimOutcome::Resumable(record));
            }
            let state = record.state;
            transaction.commit()?;
            return Ok(CommandChoiceClaimOutcome::NotPending(state));
        }
        if record.state != CommandChoiceState::Pending {
            let state = record.state;
            transaction.commit()?;
            return Ok(CommandChoiceClaimOutcome::NotPending(state));
        }
        if record.expires_at <= context.now {
            transaction.execute(
                "UPDATE command_choice_requests SET state = 'expired', resolved_at = ?2
                 WHERE callback_token = ?1 AND state = 'pending'",
                params![callback_token, context.now],
            )?;
            record.state = CommandChoiceState::Expired;
            record.resolved_at = Some(context.now);
            transaction.commit()?;
            return Ok(CommandChoiceClaimOutcome::Expired(record));
        }
        if record.catalog_fingerprint != context.catalog_fingerprint
            || record.document_revision != context.document_revision
            || record.page_count != context.page_count
        {
            transaction.execute(
                "UPDATE command_choice_requests SET catalog_fingerprint = ?2,
                        document_revision = ?3, page = 0, page_count = ?4
                 WHERE callback_token = ?1 AND state = 'pending'",
                params![
                    callback_token,
                    context.catalog_fingerprint,
                    context.document_revision,
                    context.page_count,
                ],
            )?;
            record.catalog_fingerprint = context.catalog_fingerprint.clone();
            record.document_revision = context.document_revision.clone();
            record.page = 0;
            record.page_count = context.page_count;
            transaction.commit()?;
            return Ok(CommandChoiceClaimOutcome::Refreshed(record));
        }
        match action {
            CommandChoiceAction::Page { page } => {
                if *page < 0 || *page >= record.page_count {
                    transaction.commit()?;
                    return Ok(CommandChoiceClaimOutcome::InvalidChoice);
                }
                transaction.execute(
                    "UPDATE command_choice_requests SET page = ?2
                     WHERE callback_token = ?1 AND state = 'pending'",
                    params![callback_token, page],
                )?;
                record.page = *page;
                transaction.commit()?;
                Ok(CommandChoiceClaimOutcome::Navigated(record))
            }
            CommandChoiceAction::Cancel => {
                transaction.execute(
                    "UPDATE command_choice_requests SET state = 'cancelled',
                            claimed_event_id = ?2, resolved_by_user_id = ?3, resolved_at = ?4
                     WHERE callback_token = ?1 AND state = 'pending'",
                    params![
                        callback_token,
                        context.event_id,
                        context.actor_user_id,
                        context.now
                    ],
                )?;
                record.state = CommandChoiceState::Cancelled;
                record.claimed_event_id = Some(context.event_id.clone());
                record.resolved_by_user_id = Some(context.actor_user_id);
                record.resolved_at = Some(context.now);
                transaction.commit()?;
                Ok(CommandChoiceClaimOutcome::Cancelled(record))
            }
            CommandChoiceAction::Select { value } => {
                if value.is_empty()
                    || value.len() > MAX_SELECTED_VALUE_BYTES
                    || !legal_values.iter().any(|legal| legal == value)
                {
                    transaction.commit()?;
                    return Ok(CommandChoiceClaimOutcome::InvalidChoice);
                }
                transaction.execute(
                    "UPDATE command_choice_requests SET state = 'applying',
                            selected_value = ?2, claimed_event_id = ?3,
                            resolved_by_user_id = ?4, resolved_at = ?5
                     WHERE callback_token = ?1 AND state = 'pending'",
                    params![
                        callback_token,
                        value,
                        context.event_id,
                        context.actor_user_id,
                        context.now
                    ],
                )?;
                record.state = CommandChoiceState::Applying;
                record.selected_value = Some(value.clone());
                record.claimed_event_id = Some(context.event_id.clone());
                record.resolved_by_user_id = Some(context.actor_user_id);
                record.resolved_at = Some(context.now);
                transaction.commit()?;
                Ok(CommandChoiceClaimOutcome::Claimed(record))
            }
        }
    }

    pub fn finish_command_choice_request(
        &self,
        callback_token: &str,
        succeeded: bool,
        resolved_at: i64,
    ) -> StoreResult<bool> {
        let connection = self.connection.lock().expect("bridge store poisoned");
        let state = if succeeded { "applied" } else { "failed" };
        let changed = connection.execute(
            "UPDATE command_choice_requests SET state = ?2, resolved_at = ?3
             WHERE callback_token = ?1 AND state = 'applying'",
            params![callback_token, state, resolved_at],
        )?;
        Ok(changed == 1)
    }

    pub fn expire_open_command_choice_requests_for_installation(
        &self,
        installation_id: &InstallationId,
        now: i64,
    ) -> StoreResult<Vec<CommandChoiceRequest>> {
        let mut connection = self.connection.lock().expect("bridge store poisoned");
        let transaction = connection.transaction()?;
        let tokens = {
            let mut statement = transaction.prepare(
                "SELECT callback_token FROM command_choice_requests
                 WHERE installation_id = ?1 AND state IN ('pending', 'applying')",
            )?;
            statement
                .query_map(params![installation_id.as_str()], |row| {
                    row.get::<_, String>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut records = Vec::with_capacity(tokens.len());
        for token in tokens {
            if transaction.execute(
                "UPDATE command_choice_requests SET state = 'expired', resolved_at = ?2
                 WHERE callback_token = ?1 AND state IN ('pending', 'applying')",
                params![token, now],
            )? == 1
                && let Some(mut record) = read_request(&transaction, &token)?
            {
                record.state = CommandChoiceState::Expired;
                record.resolved_at = Some(now);
                records.push(record);
            }
        }
        transaction.commit()?;
        Ok(records)
    }
}

fn validate_pending(request: &PendingCommandChoiceRequest) -> StoreResult<()> {
    let valid = !request.callback_token.trim().is_empty()
        && request.callback_token.len() <= 128
        && request.actor_user_id > 0
        && request.bot_user_id > 0
        && request.origin_chat_id > 0
        && request.origin_message_id > 0
        && !request.item_id.trim().is_empty()
        && request.item_id.len() <= 128
        && !request.prompt_text.trim().is_empty()
        && request.prompt_text.len() <= MAX_PROMPT_BYTES
        && !request.catalog_fingerprint.trim().is_empty()
        && request.catalog_fingerprint.len() <= MAX_CATALOG_FINGERPRINT_BYTES
        && !request.document_revision.trim().is_empty()
        && request.document_revision.len() <= MAX_DOCUMENT_REVISION_BYTES
        && request.page >= 0
        && request.page_count > 0
        && request.page < request.page_count
        && request.expires_at > request.created_at;
    if !valid {
        return Err(StoreError::InvalidIdentifier {
            kind: "command choice request",
            value: request.callback_token.clone(),
        });
    }
    Ok(())
}

fn read_request(
    connection: &Connection,
    callback_token: &str,
) -> StoreResult<Option<CommandChoiceRequest>> {
    let raw = connection
        .query_row(
            "SELECT installation_id, provider_id, workspace_id, bot_user_id, actor_user_id,
                    requires_owner, origin_chat_id, origin_message_id, card_message_id, item_id,
                    prompt_text, catalog_fingerprint, document_revision, page,
                    page_count, state, selected_value, claimed_event_id,
                    resolved_by_user_id, created_at, expires_at, resolved_at
             FROM command_choice_requests WHERE callback_token = ?1",
            params![callback_token],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, bool>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, Option<i64>>(8)?,
                    row.get::<_, String>(9)?,
                    row.get::<_, String>(10)?,
                    row.get::<_, String>(11)?,
                    row.get::<_, String>(12)?,
                    row.get::<_, i64>(13)?,
                    row.get::<_, i64>(14)?,
                    row.get::<_, String>(15)?,
                    row.get::<_, Option<String>>(16)?,
                    row.get::<_, Option<String>>(17)?,
                    row.get::<_, Option<i64>>(18)?,
                    row.get::<_, i64>(19)?,
                    row.get::<_, i64>(20)?,
                    row.get::<_, Option<i64>>(21)?,
                ))
            },
        )
        .optional()?;
    let Some((
        installation_id,
        provider_id,
        workspace_id,
        bot_user_id,
        actor_user_id,
        requires_owner,
        origin_chat_id,
        origin_message_id,
        card_message_id,
        item_id,
        prompt_text,
        catalog_fingerprint,
        document_revision,
        page,
        page_count,
        state,
        selected_value,
        claimed_event_id,
        resolved_by_user_id,
        created_at,
        expires_at,
        resolved_at,
    )) = raw
    else {
        return Ok(None);
    };
    Ok(Some(CommandChoiceRequest {
        callback_token: callback_token.to_string(),
        installation_id: parse_installation_id(installation_id)?,
        provider_id: parse_provider_id(provider_id)?,
        workspace_id: parse_workspace_id(workspace_id)?,
        bot_user_id,
        actor_user_id,
        requires_owner,
        origin_chat_id,
        origin_message_id,
        card_message_id,
        item_id,
        prompt_text,
        catalog_fingerprint,
        document_revision,
        page,
        page_count,
        state: CommandChoiceState::parse(state)?,
        selected_value,
        claimed_event_id,
        resolved_by_user_id,
        created_at,
        expires_at,
        resolved_at,
    }))
}

pub(super) fn migrate_v18(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "BEGIN IMMEDIATE;
         CREATE TABLE command_choice_requests (
            callback_token TEXT PRIMARY KEY NOT NULL,
            installation_id TEXT NOT NULL,
            provider_id TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            bot_user_id INTEGER NOT NULL,
            actor_user_id INTEGER NOT NULL,
            requires_owner INTEGER NOT NULL CHECK (requires_owner IN (0, 1)),
            origin_chat_id INTEGER NOT NULL,
            origin_message_id INTEGER NOT NULL,
            card_message_id INTEGER,
            item_id TEXT NOT NULL,
            prompt_text TEXT NOT NULL,
            catalog_fingerprint TEXT NOT NULL,
            document_revision TEXT NOT NULL,
            page INTEGER NOT NULL,
            page_count INTEGER NOT NULL,
            state TEXT NOT NULL CHECK (
                state IN ('pending', 'applying', 'applied', 'cancelled', 'expired', 'failed')
            ),
            selected_value TEXT,
            claimed_event_id TEXT,
            resolved_by_user_id INTEGER,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            resolved_at INTEGER
         );
         CREATE INDEX command_choice_requests_open
         ON command_choice_requests (installation_id, provider_id, state, expires_at);
         PRAGMA user_version = 18;
         COMMIT;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending() -> PendingCommandChoiceRequest {
        PendingCommandChoiceRequest {
            callback_token: "choice-token".to_string(),
            installation_id: InstallationId::new("host-1").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
            bot_user_id: 8,
            actor_user_id: 7,
            requires_owner: true,
            origin_chat_id: 11,
            origin_message_id: 12,
            item_id: "agent.model".to_string(),
            prompt_text: "Choose a model.".to_string(),
            catalog_fingerprint: "catalog-1".to_string(),
            document_revision: "revision-1".to_string(),
            page: 0,
            page_count: 2,
            created_at: 100,
            expires_at: 200,
        }
    }

    fn context() -> CommandChoiceClaimContext {
        CommandChoiceClaimContext {
            installation_id: InstallationId::new("host-1").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
            bot_user_id: 8,
            actor_user_id: 7,
            current_owner_user_id: 7,
            actor_still_authorized: true,
            action_chat_id: 11,
            action_message_id: 13,
            event_id: "action-1".to_string(),
            catalog_fingerprint: "catalog-1".to_string(),
            document_revision: "revision-1".to_string(),
            page_count: 2,
            now: 110,
        }
    }

    #[test]
    fn selection_is_owner_context_bound_and_replay_safe() {
        let store = BridgeStore::open_in_memory().expect("store");
        store
            .insert_command_choice_request(&pending())
            .expect("insert");
        store
            .attach_command_choice_message("choice-token", 13)
            .expect("attach");
        let action = CommandChoiceAction::Select {
            value: "gpt-5".to_string(),
        };
        assert!(matches!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &action,
                    &["gpt-5".to_string()],
                    &context(),
                )
                .expect("claim"),
            CommandChoiceClaimOutcome::Claimed(_)
        ));
        assert!(matches!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &action,
                    &["gpt-5".to_string()],
                    &context(),
                )
                .expect("replay"),
            CommandChoiceClaimOutcome::Resumable(_)
        ));
        assert!(
            store
                .finish_command_choice_request("choice-token", true, 111)
                .expect("finish")
        );
        assert!(matches!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &action,
                    &["gpt-5".to_string()],
                    &context(),
                )
                .expect("terminal replay"),
            CommandChoiceClaimOutcome::NotPending(CommandChoiceState::Applied)
        ));
    }

    #[test]
    fn paging_rechecks_actor_context_catalog_and_bounds() {
        let store = BridgeStore::open_in_memory().expect("store");
        store
            .insert_command_choice_request(&pending())
            .expect("insert");
        store
            .attach_command_choice_message("choice-token", 13)
            .expect("attach");
        let mut wrong_actor = context();
        wrong_actor.actor_user_id = 8;
        assert!(matches!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &CommandChoiceAction::Page { page: 1 },
                    &[],
                    &wrong_actor,
                )
                .expect("wrong actor"),
            CommandChoiceClaimOutcome::Unauthorized
        ));
        let mut stale = context();
        stale.catalog_fingerprint = "catalog-2".to_string();
        assert!(matches!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &CommandChoiceAction::Page { page: 1 },
                    &[],
                    &stale,
                )
                .expect("stale"),
            CommandChoiceClaimOutcome::Refreshed(CommandChoiceRequest { page: 0, .. })
        ));
        let mut refreshed = context();
        refreshed.catalog_fingerprint = "catalog-2".to_string();
        assert!(matches!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &CommandChoiceAction::Page { page: 1 },
                    &[],
                    &refreshed,
                )
                .expect("navigate"),
            CommandChoiceClaimOutcome::Navigated(CommandChoiceRequest { page: 1, .. })
        ));
    }

    #[test]
    fn delegated_actor_must_still_be_authorized_at_click_time() {
        let store = BridgeStore::open_in_memory().expect("store");
        let mut request = pending();
        request.actor_user_id = 9;
        request.requires_owner = false;
        store
            .insert_command_choice_request(&request)
            .expect("insert");
        store
            .attach_command_choice_message("choice-token", 13)
            .expect("attach");
        let mut revoked = context();
        revoked.actor_user_id = 9;
        revoked.actor_still_authorized = false;
        assert_eq!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &CommandChoiceAction::Select {
                        value: "safe".to_string(),
                    },
                    &["safe".to_string()],
                    &revoked,
                )
                .expect("revoked"),
            CommandChoiceClaimOutcome::Unauthorized
        );
        revoked.actor_still_authorized = true;
        assert!(matches!(
            store
                .claim_command_choice_request(
                    "choice-token",
                    &CommandChoiceAction::Select {
                        value: "safe".to_string(),
                    },
                    &["safe".to_string()],
                    &revoked,
                )
                .expect("authorized"),
            CommandChoiceClaimOutcome::Claimed(_)
        ));
    }

    #[test]
    fn expired_requests_are_terminal_and_recoverable() {
        let store = BridgeStore::open_in_memory().expect("store");
        store
            .insert_command_choice_request(&pending())
            .expect("insert");
        store
            .attach_command_choice_message("choice-token", 13)
            .expect("attach");
        let recovered = store
            .expire_open_command_choice_requests_for_installation(
                &InstallationId::new("host-1").expect("installation"),
                150,
            )
            .expect("recover");
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].state, CommandChoiceState::Expired);
    }
}

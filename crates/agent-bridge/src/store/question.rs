use rusqlite::{Connection, OptionalExtension, params};

use super::{
    BridgeStore, StoreError, StoreResult, parse_installation_id, parse_provider_id, parse_turn_id,
};
use crate::{InstallationId, ProviderId, TurnId};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuestionState {
    Pending,
    Resolving,
    Resolved,
    DeliveryFailed,
    Invalidated,
    Expired,
}
impl QuestionState {
    fn parse(value: String) -> StoreResult<Self> {
        match value.as_str() {
            "pending" => Ok(Self::Pending),
            "resolving" => Ok(Self::Resolving),
            "resolved" => Ok(Self::Resolved),
            "delivery_failed" => Ok(Self::DeliveryFailed),
            "invalidated" => Ok(Self::Invalidated),
            "expired" => Ok(Self::Expired),
            _ => Err(StoreError::UnknownQuestionState(value)),
        }
    }
    pub fn terminal_text(self) -> &'static str {
        match self {
            Self::Resolved => "Answered.",
            Self::Expired => "This question expired.",
            _ => "This question is no longer active.",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingQuestion {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub provider_question_id: String,
    pub turn_id: TurnId,
    pub chat_id: i64,
    pub message_id: Option<i64>,
    pub owner_user_id: i64,
    pub created_at: i64,
    pub expires_at: Option<i64>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuestionRecord {
    pub callback_token: String,
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub provider_question_id: String,
    pub turn_id: TurnId,
    pub chat_id: i64,
    pub message_id: Option<i64>,
    pub owner_user_id: i64,
    pub state: QuestionState,
    pub claimed_event_id: Option<String>,
    pub resolved_by_user_id: Option<i64>,
    pub created_at: i64,
    pub expires_at: Option<i64>,
    pub resolved_at: Option<i64>,
    pub ui_cleared_at: Option<i64>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QuestionClaimLocator {
    CallbackToken(String),
    Message { chat_id: i64, message_id: i64 },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuestionClaimContext {
    pub installation_id: InstallationId,
    pub provider_id: ProviderId,
    pub turn_id: TurnId,
    pub chat_id: i64,
    pub message_id: i64,
    pub actor_user_id: i64,
    pub event_id: String,
    pub now: i64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QuestionClaimOutcome {
    Claimed(Box<QuestionRecord>),
    Unknown,
    Unauthorized,
    WrongContext,
    Expired,
    NotPending(QuestionState),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuestionResolution {
    Resolved,
    DeliveryFailed,
}

impl BridgeStore {
    pub fn insert_question(&self, q: &PendingQuestion) -> StoreResult<bool> {
        validate(q)?;
        let c = self.connection.lock().expect("bridge store poisoned");
        Ok(c.execute("INSERT OR IGNORE INTO question_requests
            (callback_token,installation_id,provider_id,provider_question_id,turn_id,chat_id,message_id,owner_user_id,state,claimed_event_id,resolved_by_user_id,created_at,expires_at,resolved_at,ui_cleared_at)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'pending',NULL,NULL,?9,?10,NULL,NULL)", params![q.callback_token,q.installation_id.as_str(),q.provider_id.as_str(),q.provider_question_id,q.turn_id.as_str(),q.chat_id,q.message_id,q.owner_user_id,q.created_at,q.expires_at])? == 1)
    }
    pub fn attach_question_message(&self, token: &str, message_id: i64) -> StoreResult<bool> {
        if message_id <= 0 {
            return Err(invalid("question message id", message_id.to_string()));
        }
        let c = self.connection.lock().expect("bridge store poisoned");
        Ok(c.execute("UPDATE question_requests SET message_id=?2 WHERE callback_token=?1 AND state IN ('pending','resolving') AND message_id IS NULL", params![token,message_id])? == 1)
    }
    pub fn get_question(&self, token: &str) -> StoreResult<Option<QuestionRecord>> {
        let c = self.connection.lock().expect("bridge store poisoned");
        read_one(&c, "callback_token=?1", [token])
    }
    pub fn get_question_by_message(
        &self,
        chat_id: i64,
        message_id: i64,
    ) -> StoreResult<Option<QuestionRecord>> {
        let c = self.connection.lock().expect("bridge store poisoned");
        c.query_row(
            &format!("{SELECT} WHERE chat_id=?1 AND message_id=?2"),
            params![chat_id, message_id],
            row,
        )
        .optional()?
        .map(parse)
        .transpose()
    }
    pub fn open_questions_for_installation(
        &self,
        installation_id: &InstallationId,
    ) -> StoreResult<Vec<QuestionRecord>> {
        let c = self.connection.lock().expect("bridge store poisoned");
        read_many(
            &c,
            "installation_id=?1 AND state IN ('pending','resolving') ORDER BY created_at ASC, callback_token ASC",
            [installation_id.as_str()],
        )
    }
    pub fn claim_question(
        &self,
        locator: &QuestionClaimLocator,
        x: &QuestionClaimContext,
    ) -> StoreResult<QuestionClaimOutcome> {
        let mut c = self.connection.lock().expect("bridge store poisoned");
        let tx = c.transaction()?;
        let record = match locator {
            QuestionClaimLocator::CallbackToken(t) => {
                read_one(&tx, "callback_token=?1", [t.as_str()])?
            }
            QuestionClaimLocator::Message {
                chat_id,
                message_id,
            } => tx
                .query_row(
                    &format!("{SELECT} WHERE chat_id=?1 AND message_id=?2"),
                    params![chat_id, message_id],
                    row,
                )
                .optional()?
                .map(parse)
                .transpose()?,
        };
        let Some(mut r) = record else {
            return Ok(QuestionClaimOutcome::Unknown);
        };
        if x.actor_user_id != r.owner_user_id {
            return Ok(QuestionClaimOutcome::Unauthorized);
        }
        if x.installation_id != r.installation_id
            || x.provider_id != r.provider_id
            || x.turn_id != r.turn_id
            || x.chat_id != r.chat_id
            || Some(x.message_id) != r.message_id
        {
            return Ok(QuestionClaimOutcome::WrongContext);
        }
        if r.expires_at.is_some_and(|e| x.now >= e) {
            tx.execute("UPDATE question_requests SET state='expired',resolved_at=?2 WHERE callback_token=?1 AND state='pending'",params![r.callback_token,x.now])?;
            tx.commit()?;
            return Ok(QuestionClaimOutcome::Expired);
        }
        if r.state != QuestionState::Pending {
            return Ok(QuestionClaimOutcome::NotPending(r.state));
        }
        if tx.execute("UPDATE question_requests SET state='resolving',claimed_event_id=?2,resolved_by_user_id=?3 WHERE callback_token=?1 AND state='pending'",params![r.callback_token,x.event_id,x.actor_user_id])?!=1{return Ok(QuestionClaimOutcome::NotPending(QuestionState::Resolving))}
        tx.commit()?;
        r.state = QuestionState::Resolving;
        r.claimed_event_id = Some(x.event_id.clone());
        r.resolved_by_user_id = Some(x.actor_user_id);
        Ok(QuestionClaimOutcome::Claimed(Box::new(r)))
    }
    pub fn finish_question(
        &self,
        token: &str,
        event: &str,
        actor: i64,
        resolution: QuestionResolution,
        now: i64,
    ) -> StoreResult<bool> {
        let state = match resolution {
            QuestionResolution::Resolved => "resolved",
            QuestionResolution::DeliveryFailed => "delivery_failed",
        };
        let c = self.connection.lock().expect("bridge store poisoned");
        Ok(c.execute("UPDATE question_requests SET state=?4,resolved_at=?5 WHERE callback_token=?1 AND state='resolving' AND claimed_event_id=?2 AND resolved_by_user_id=?3",params![token,event,actor,state,now])?==1)
    }
    pub fn invalidate_turn_questions(&self, turn: &TurnId, now: i64) -> StoreResult<usize> {
        let c = self.connection.lock().expect("bridge store poisoned");
        Ok(c.execute("UPDATE question_requests SET state='invalidated',resolved_at=?2 WHERE turn_id=?1 AND state IN ('pending','resolving')",params![turn.as_str(),now])?)
    }
    /// Atomically expires pending questions for one active turn and returns
    /// exactly the records won by this expiry pass.
    pub fn expire_turn_questions(
        &self,
        turn: &TurnId,
        now: i64,
    ) -> StoreResult<Vec<QuestionRecord>> {
        let mut c = self.connection.lock().expect("bridge store poisoned");
        let tx = c.transaction()?;
        let records = read_many(
            &tx,
            "turn_id=?1 AND state='pending' AND expires_at IS NOT NULL AND expires_at<=?2 ORDER BY created_at ASC, callback_token ASC",
            params![turn.as_str(), now],
        )?;
        let mut expired = Vec::with_capacity(records.len());
        for mut record in records {
            if tx.execute(
                "UPDATE question_requests SET state='expired',resolved_at=?2 WHERE callback_token=?1 AND state='pending' AND expires_at IS NOT NULL AND expires_at<=?2",
                params![record.callback_token, now],
            )? == 1
            {
                record.state = QuestionState::Expired;
                record.resolved_at = Some(now);
                expired.push(record);
            }
        }
        tx.commit()?;
        Ok(expired)
    }
    pub fn invalidate_open_questions_for_installation(
        &self,
        id: &InstallationId,
        now: i64,
    ) -> StoreResult<Vec<QuestionRecord>> {
        let mut c = self.connection.lock().expect("bridge store poisoned");
        let tx = c.transaction()?;
        let records = read_many(
            &tx,
            "installation_id=?1 AND state IN ('pending','resolving')",
            [id.as_str()],
        )?;
        tx.execute("UPDATE question_requests SET state='invalidated',resolved_at=?2 WHERE installation_id=?1 AND state IN ('pending','resolving')",params![id.as_str(),now])?;
        tx.commit()?;
        Ok(records
            .into_iter()
            .map(|mut r| {
                r.state = QuestionState::Invalidated;
                r.resolved_at = Some(now);
                r
            })
            .collect())
    }
    pub fn questions_requiring_ui_cleanup_for_installation(
        &self,
        installation_id: &InstallationId,
        limit: usize,
    ) -> StoreResult<Vec<QuestionRecord>> {
        let c = self.connection.lock().expect("bridge store poisoned");
        let mut s=c.prepare(&format!("{SELECT} WHERE installation_id=?1 AND state IN ('resolved','delivery_failed','invalidated','expired') AND message_id IS NOT NULL AND ui_cleared_at IS NULL ORDER BY created_at LIMIT ?2"))?;
        s.query_map(
            params![
                installation_id.as_str(),
                i64::try_from(limit.min(1000)).unwrap_or(1000)
            ],
            row,
        )?
        .map(|v| v.map_err(StoreError::from).and_then(parse))
        .collect()
    }
    pub fn mark_question_ui_cleared(&self, token: &str, now: i64) -> StoreResult<bool> {
        let c = self.connection.lock().expect("bridge store poisoned");
        Ok(c.execute("UPDATE question_requests SET ui_cleared_at=?2 WHERE callback_token=?1 AND ui_cleared_at IS NULL AND state IN ('resolved','delivery_failed','invalidated','expired')",params![token,now])?==1)
    }
}

pub(super) fn migrate_v11(c: &Connection) -> StoreResult<()> {
    c.execute_batch("BEGIN IMMEDIATE;CREATE TABLE question_requests(callback_token TEXT PRIMARY KEY NOT NULL,installation_id TEXT NOT NULL,provider_id TEXT NOT NULL,provider_question_id TEXT NOT NULL,turn_id TEXT NOT NULL,chat_id INTEGER NOT NULL,message_id INTEGER,owner_user_id INTEGER NOT NULL,state TEXT NOT NULL CHECK(state IN ('pending','resolving','resolved','delivery_failed','invalidated','expired')),claimed_event_id TEXT,resolved_by_user_id INTEGER,created_at INTEGER NOT NULL,expires_at INTEGER,resolved_at INTEGER,ui_cleared_at INTEGER,UNIQUE(installation_id,provider_id,turn_id,provider_question_id));CREATE INDEX question_requests_open_turn ON question_requests(turn_id,state,created_at);CREATE INDEX question_requests_open_installation ON question_requests(installation_id,state);CREATE INDEX question_requests_ui_cleanup ON question_requests(state,ui_cleared_at,created_at);PRAGMA user_version=11;COMMIT;")?;
    Ok(())
}

const SELECT: &str = "SELECT callback_token,installation_id,provider_id,provider_question_id,turn_id,chat_id,message_id,owner_user_id,state,claimed_event_id,resolved_by_user_id,created_at,expires_at,resolved_at,ui_cleared_at FROM question_requests";
type Raw = (
    String,
    String,
    String,
    String,
    String,
    i64,
    Option<i64>,
    i64,
    String,
    Option<String>,
    Option<i64>,
    i64,
    Option<i64>,
    Option<i64>,
    Option<i64>,
);
fn row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Raw> {
    Ok((
        r.get(0)?,
        r.get(1)?,
        r.get(2)?,
        r.get(3)?,
        r.get(4)?,
        r.get(5)?,
        r.get(6)?,
        r.get(7)?,
        r.get(8)?,
        r.get(9)?,
        r.get(10)?,
        r.get(11)?,
        r.get(12)?,
        r.get(13)?,
        r.get(14)?,
    ))
}
fn parse(r: Raw) -> StoreResult<QuestionRecord> {
    Ok(QuestionRecord {
        callback_token: r.0,
        installation_id: parse_installation_id(r.1)?,
        provider_id: parse_provider_id(r.2)?,
        provider_question_id: r.3,
        turn_id: parse_turn_id(r.4)?,
        chat_id: r.5,
        message_id: r.6,
        owner_user_id: r.7,
        state: QuestionState::parse(r.8)?,
        claimed_event_id: r.9,
        resolved_by_user_id: r.10,
        created_at: r.11,
        expires_at: r.12,
        resolved_at: r.13,
        ui_cleared_at: r.14,
    })
}
fn read_one<P: rusqlite::Params>(
    c: &Connection,
    p: &str,
    x: P,
) -> StoreResult<Option<QuestionRecord>> {
    c.query_row(&format!("{SELECT} WHERE {p}"), x, row)
        .optional()?
        .map(parse)
        .transpose()
}
fn read_many<P: rusqlite::Params>(
    c: &Connection,
    p: &str,
    x: P,
) -> StoreResult<Vec<QuestionRecord>> {
    let mut s = c.prepare(&format!("{SELECT} WHERE {p}"))?;
    s.query_map(x, row)?
        .map(|v| v.map_err(StoreError::from).and_then(parse))
        .collect()
}
fn validate(q: &PendingQuestion) -> StoreResult<()> {
    if q.callback_token.trim().is_empty() {
        return Err(invalid("question callback token", "empty"));
    }
    if q.provider_question_id.trim().is_empty() {
        return Err(invalid("provider question id", "empty"));
    }
    if q.chat_id <= 0 {
        return Err(invalid("question chat id", q.chat_id.to_string()));
    }
    if q.owner_user_id <= 0 {
        return Err(invalid(
            "question owner user id",
            q.owner_user_id.to_string(),
        ));
    }
    if q.expires_at.is_some_and(|e| e <= q.created_at) {
        return Err(invalid("question expiry", "not after creation"));
    }
    Ok(())
}
fn invalid(kind: &'static str, value: impl Into<String>) -> StoreError {
    StoreError::InvalidIdentifier {
        kind,
        value: value.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pending() -> PendingQuestion {
        PendingQuestion {
            callback_token: "token-1".into(),
            installation_id: InstallationId::new("host-1").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            provider_question_id: "request-1".into(),
            turn_id: TurnId::new("turn-1").expect("turn"),
            chat_id: 42,
            message_id: None,
            owner_user_id: 7,
            created_at: 100,
            expires_at: Some(200),
        }
    }

    fn context(actor: i64, event: &str) -> QuestionClaimContext {
        QuestionClaimContext {
            installation_id: InstallationId::new("host-1").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            turn_id: TurnId::new("turn-1").expect("turn"),
            chat_id: 42,
            message_id: 99,
            actor_user_id: actor,
            event_id: event.into(),
            now: 150,
        }
    }

    #[test]
    fn owner_claim_is_single_winner_and_cleanup_is_durable() {
        let store = BridgeStore::open_in_memory().expect("store");
        let question = pending();
        assert!(store.insert_question(&question).expect("insert"));
        assert!(!store.insert_question(&question).expect("duplicate"));
        assert!(
            store
                .attach_question_message("token-1", 99)
                .expect("attach")
        );
        assert_eq!(
            store
                .get_question_by_message(42, 99)
                .expect("message lookup")
                .expect("question")
                .callback_token,
            "token-1"
        );
        assert!(matches!(
            store
                .claim_question(
                    &QuestionClaimLocator::Message {
                        chat_id: 42,
                        message_id: 99,
                    },
                    &context(8, "outsider"),
                )
                .expect("outsider claim"),
            QuestionClaimOutcome::Unauthorized
        ));
        assert!(matches!(
            store
                .claim_question(
                    &QuestionClaimLocator::CallbackToken("token-1".into()),
                    &context(7, "answer-1"),
                )
                .expect("owner claim"),
            QuestionClaimOutcome::Claimed(_)
        ));
        assert!(matches!(
            store
                .claim_question(
                    &QuestionClaimLocator::CallbackToken("token-1".into()),
                    &context(7, "answer-2"),
                )
                .expect("duplicate claim"),
            QuestionClaimOutcome::NotPending(QuestionState::Resolving)
        ));
        assert!(
            store
                .finish_question("token-1", "answer-1", 7, QuestionResolution::Resolved, 151,)
                .expect("finish")
        );
        let cleanup = store
            .questions_requiring_ui_cleanup_for_installation(&question.installation_id, 10)
            .expect("cleanup");
        assert_eq!(cleanup.len(), 1);
        assert_eq!(cleanup[0].state, QuestionState::Resolved);
        assert!(
            store
                .mark_question_ui_cleared("token-1", 152)
                .expect("clear")
        );
        assert!(
            store
                .questions_requiring_ui_cleanup_for_installation(&question.installation_id, 10)
                .expect("clean")
                .is_empty()
        );
    }

    #[test]
    fn restart_invalidates_only_the_target_installation() {
        let store = BridgeStore::open_in_memory().expect("store");
        let first = pending();
        let mut second = pending();
        second.callback_token = "token-2".into();
        second.installation_id = InstallationId::new("host-2").expect("installation");
        store.insert_question(&first).expect("first");
        store.insert_question(&second).expect("second");
        let invalidated = store
            .invalidate_open_questions_for_installation(&first.installation_id, 160)
            .expect("invalidate");
        assert_eq!(invalidated.len(), 1);
        assert_eq!(invalidated[0].state, QuestionState::Invalidated);
        assert_eq!(
            store
                .get_question("token-2")
                .expect("second")
                .expect("row")
                .state,
            QuestionState::Pending
        );
    }

    #[test]
    fn active_expiry_is_single_winner_and_requires_a_deadline() {
        let store = BridgeStore::open_in_memory().expect("store");
        let due = pending();
        let mut no_deadline = pending();
        no_deadline.callback_token = "no-deadline".into();
        no_deadline.provider_question_id = "request-2".into();
        no_deadline.expires_at = None;
        store.insert_question(&due).expect("insert due");
        store
            .insert_question(&no_deadline)
            .expect("insert no deadline");

        let expired = store
            .expire_turn_questions(&due.turn_id, 200)
            .expect("expire turn");
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].callback_token, "token-1");
        assert_eq!(expired[0].state, QuestionState::Expired);
        assert!(
            store
                .expire_turn_questions(&due.turn_id, 201)
                .expect("repeat expiry")
                .is_empty()
        );
        assert_eq!(
            store
                .get_question("no-deadline")
                .expect("get")
                .expect("question")
                .state,
            QuestionState::Pending
        );
    }
}

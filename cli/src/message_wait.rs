//! `inline messages wait`: block until new messages arrive in one chat.
//!
//! One bounded call replaces an agent's `messages list` polling loop. The wait
//! first reads everything after the `--after` cursor (so a reply that landed
//! between the agent's send and this call is not missed), then waits on the
//! same connection for the server to push an update about the chat, reading
//! newer history once per push. A slow safety read covers pushes that never
//! arrive. The cursor only moves forward, so a reconnect never reports a
//! message twice.

use std::error::Error;
use std::time::Duration;

use inline_protocol::proto;
use serde::Serialize;
use tokio::time::{Instant, sleep_until};

/// Exit status for a wait that ended without a matching message, following
/// the `timeout(1)` convention so scripts can tell it apart from failures.
pub(crate) const WAIT_TIMEOUT_EXIT_CODE: i32 = 124;

/// Newer-history page size; a full page is drained before sleeping.
pub(crate) const WAIT_PAGE_LIMIT: i32 = 100;

/// Upper bound on matches returned by one call. The cursor then points at the
/// last returned message, so the next call continues from there.
pub(crate) const WAIT_MAX_MATCHES: usize = 200;

pub(crate) const MAX_WAIT_TIMEOUT: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_RETRY_BACKOFF: Duration = Duration::from_secs(30);
/// With pushed updates, a quiet chat is still read this often in case a push
/// was lost (about 20 reads in 10 quiet minutes, against 200 at a 3 s poll).
pub(crate) const SAFETY_READ_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SenderFilter {
    /// Messages not sent by the signed-in account.
    Others,
    /// Messages from one author.
    Sender(i64),
    /// Every message, including your own.
    Anyone,
}

impl SenderFilter {
    fn matches(self, message: &proto::Message) -> bool {
        match self {
            Self::Others => !message.out,
            Self::Sender(user_id) => message.from_id == user_id,
            Self::Anyone => true,
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct WaitPlan {
    pub after_id: i64,
    pub filter: SenderFilter,
    pub timeout: Duration,
    /// After the first match, keep collecting until no new match arrives for
    /// this long, so a burst of short messages wakes the agent once.
    pub settle: Duration,
    pub poll_interval: Duration,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WaitResult {
    /// Matching messages, oldest first.
    pub messages: Vec<proto::Message>,
    /// Highest message ID examined. Pass it as `--after` to wait again.
    pub cursor: i64,
    pub timed_out: bool,
}

/// Reads chat history newer than a message ID.
pub(crate) trait HistorySource {
    async fn fetch_newer(
        &mut self,
        after_id: i64,
        limit: i32,
    ) -> Result<Vec<proto::Message>, Box<dyn Error>>;

    /// Whether a failed read is worth retrying (dropped connection, timeout,
    /// rate limit) rather than ending the wait.
    fn is_transient(&self, error: &(dyn Error + 'static)) -> bool;

    /// Whether the server is pushing updates for this wait right now. While it
    /// is, an idle wait reads only on a push or every [`SAFETY_READ_INTERVAL`];
    /// otherwise it reads every poll interval.
    fn receives_pushes(&self) -> bool {
        false
    }

    /// Returns at `until`, or earlier when the server pushes an update that
    /// may carry a new message in the chat; `true` when a push woke it.
    async fn wait_for_activity(&mut self, until: Instant) -> bool {
        sleep_until(until).await;
        false
    }
}

/// The chat a wait is watching, to tell its pushed updates from other chats'.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct WaitTarget {
    pub chat_id: Option<i64>,
    /// The other side of a DM, when the wait was given `--user-id`.
    pub peer_user_id: Option<i64>,
}

impl WaitTarget {
    /// Whether this pushed update may mean a new message in the target chat.
    /// It errs toward waking: a wasted read is cheap, a missed one is late.
    pub(crate) fn woken_by(&self, update: &proto::Update) -> bool {
        use proto::update::Update as Kind;
        match &update.update {
            Some(Kind::NewMessage(new)) => new
                .message
                .as_ref()
                .is_some_and(|message| self.names(Some(message.chat_id), message.peer_id.as_ref())),
            Some(Kind::NewMessageNotification(notification)) => notification
                .message
                .as_ref()
                .is_some_and(|message| self.names(Some(message.chat_id), message.peer_id.as_ref())),
            Some(Kind::ChatHasNewUpdates(hint)) => {
                self.names(Some(hint.chat_id), hint.peer_id.as_ref())
            }
            // The account's own bucket moved; a DM's messages can land there.
            Some(Kind::UserHasNewUpdates(_)) => self.peer_user_id.is_some(),
            _ => false,
        }
    }

    fn names(&self, chat_id: Option<i64>, peer: Option<&proto::Peer>) -> bool {
        if self.chat_id.is_some() && chat_id.filter(|id| *id != 0) == self.chat_id {
            return true;
        }
        match (
            self.peer_user_id,
            peer.and_then(|peer| peer.r#type.as_ref()),
        ) {
            (Some(user_id), Some(proto::peer::Type::User(user))) => user.user_id == user_id,
            (_, Some(proto::peer::Type::Chat(chat))) => Some(chat.chat_id) == self.chat_id,
            _ => false,
        }
    }
}

pub(crate) async fn wait_for_messages<S: HistorySource>(
    source: &mut S,
    plan: &WaitPlan,
) -> Result<WaitResult, Box<dyn Error>> {
    let deadline = Instant::now() + plan.timeout;
    let mut cursor = plan.after_id;
    let mut matched: Vec<proto::Message> = Vec::new();
    let mut settle_until: Option<Instant> = None;
    let mut retry_backoff = plan.poll_interval;

    loop {
        let mut drain_more = false;
        let last_failure: Option<Box<dyn Error>>;
        log::debug!("messages wait: reading after {cursor}");
        match source.fetch_newer(cursor, WAIT_PAGE_LIMIT).await {
            Ok(mut page) => {
                last_failure = None;
                retry_backoff = plan.poll_interval;
                drain_more = page.len() >= WAIT_PAGE_LIMIT as usize;
                page.sort_by_key(|message| message.id);
                let mut matched_now = false;
                for message in page {
                    if message.id <= cursor {
                        continue;
                    }
                    cursor = message.id;
                    if plan.filter.matches(&message) {
                        matched.push(message);
                        matched_now = true;
                        if matched.len() >= WAIT_MAX_MATCHES {
                            return Ok(finish(matched, cursor));
                        }
                    }
                }
                if matched_now {
                    settle_until = Some(Instant::now() + plan.settle);
                }
            }
            Err(error) if source.is_transient(error.as_ref()) => {
                log::debug!(
                    "messages wait: retrying after transient read failure: {}",
                    crate::diagnostics::safe_text(&error.to_string())
                );
                last_failure = Some(error);
            }
            Err(error) => return Err(error),
        }

        let now = Instant::now();
        if drain_more && now < deadline {
            continue;
        }
        if settle_until.is_some_and(|until| now >= until) {
            return Ok(finish(matched, cursor));
        }
        if now >= deadline {
            if !matched.is_empty() {
                return Ok(finish(matched, cursor));
            }
            // Never report "no reply" when the chat could not be read at all.
            if let Some(error) = last_failure {
                return Err(error);
            }
            return Ok(WaitResult {
                messages: matched,
                cursor,
                timed_out: true,
            });
        }

        if last_failure.is_some() {
            let delay = retry_backoff;
            retry_backoff = (retry_backoff * 2).min(MAX_RETRY_BACKOFF);
            sleep_until((now + delay).min(deadline)).await;
            continue;
        }
        let delay = if source.receives_pushes() {
            SAFETY_READ_INTERVAL.max(plan.poll_interval)
        } else {
            plan.poll_interval
        };
        let mut wake = (now + delay).min(deadline);
        if let Some(until) = settle_until {
            wake = wake.min(until);
        }
        if source.wait_for_activity(wake).await {
            log::debug!("messages wait: woken by a pushed update");
        }
    }
}

fn finish(messages: Vec<proto::Message>, cursor: i64) -> WaitResult {
    WaitResult {
        messages,
        cursor,
        timed_out: false,
    }
}

/// Parses `90`, `90s`, `30m`, `2h`, or `1d` into a duration.
pub(crate) fn parse_wait_duration(flag: &str, raw: &str) -> Result<Duration, String> {
    let value = raw.trim().to_ascii_lowercase();
    let split = value
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(value.len());
    let (digits, unit) = value.split_at(split);
    let amount: u64 = digits
        .parse()
        .map_err(|_| format!("{flag} expects a duration like 90s, 30m, or 2h (got {raw:?})"))?;
    let seconds_per_unit = match unit {
        "" | "s" | "sec" | "secs" => 1,
        "m" | "min" | "mins" => 60,
        "h" | "hr" | "hrs" => 60 * 60,
        "d" => 24 * 60 * 60,
        _ => {
            return Err(format!(
                "{flag} expects a duration like 90s, 30m, or 2h (got {raw:?})"
            ));
        }
    };
    amount
        .checked_mul(seconds_per_unit)
        .map(Duration::from_secs)
        .ok_or_else(|| format!("{flag} is too large"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::fmt;

    #[derive(Debug)]
    struct FakeDisconnect;

    impl fmt::Display for FakeDisconnect {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("connection closed")
        }
    }

    impl Error for FakeDisconnect {}

    #[derive(Debug)]
    struct FakeDenied;

    impl fmt::Display for FakeDenied {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("access denied")
        }
    }

    impl Error for FakeDenied {}

    enum Step {
        /// Messages that exist when this read happens (the source filters by cursor).
        Arrive(Vec<proto::Message>),
        Disconnect,
        Deny,
    }

    /// Simulated chat: each read first applies the next scripted step, then
    /// returns the stored messages after the cursor, newest first like the server.
    struct FakeChat {
        steps: VecDeque<Step>,
        history: Vec<proto::Message>,
        cursors: Vec<i64>,
    }

    impl FakeChat {
        fn new(history: Vec<proto::Message>, steps: Vec<Step>) -> Self {
            Self {
                steps: steps.into(),
                history,
                cursors: Vec::new(),
            }
        }
    }

    impl HistorySource for FakeChat {
        async fn fetch_newer(
            &mut self,
            after_id: i64,
            limit: i32,
        ) -> Result<Vec<proto::Message>, Box<dyn Error>> {
            self.cursors.push(after_id);
            match self.steps.pop_front() {
                Some(Step::Arrive(messages)) => self.history.extend(messages),
                Some(Step::Disconnect) => return Err(Box::new(FakeDisconnect)),
                Some(Step::Deny) => return Err(Box::new(FakeDenied)),
                None => {}
            }
            let mut page: Vec<_> = self
                .history
                .iter()
                .filter(|message| message.id > after_id)
                .cloned()
                .collect();
            page.sort_by_key(|message| message.id);
            page.truncate(limit as usize);
            page.reverse();
            Ok(page)
        }

        fn is_transient(&self, error: &(dyn Error + 'static)) -> bool {
            error.downcast_ref::<FakeDisconnect>().is_some()
        }
    }

    fn mine(id: i64) -> proto::Message {
        proto::Message {
            id,
            from_id: 1,
            out: true,
            ..Default::default()
        }
    }

    fn theirs(id: i64, from_id: i64) -> proto::Message {
        proto::Message {
            id,
            from_id,
            out: false,
            ..Default::default()
        }
    }

    fn plan(after_id: i64) -> WaitPlan {
        WaitPlan {
            after_id,
            filter: SenderFilter::Others,
            timeout: Duration::from_secs(60),
            settle: Duration::ZERO,
            poll_interval: Duration::from_secs(3),
        }
    }

    fn ids(result: &WaitResult) -> Vec<i64> {
        result.messages.iter().map(|message| message.id).collect()
    }

    #[tokio::test(start_paused = true)]
    async fn backfills_a_reply_that_landed_before_the_wait_started() {
        let mut chat = FakeChat::new(vec![mine(10), theirs(11, 2)], vec![]);
        let result = wait_for_messages(&mut chat, &plan(10)).await.unwrap();
        assert_eq!(ids(&result), vec![11]);
        assert_eq!(result.cursor, 11);
        assert!(!result.timed_out);
        assert_eq!(chat.cursors, vec![10]);
    }

    #[tokio::test(start_paused = true)]
    async fn skips_own_messages_and_waits_for_the_other_side() {
        let mut chat = FakeChat::new(
            vec![mine(10)],
            vec![
                Step::Arrive(vec![]),
                Step::Arrive(vec![mine(11)]),
                Step::Arrive(vec![theirs(12, 2)]),
            ],
        );
        let started = Instant::now();
        let result = wait_for_messages(&mut chat, &plan(10)).await.unwrap();
        assert_eq!(ids(&result), vec![12]);
        assert_eq!(result.cursor, 12);
        assert_eq!(chat.cursors, vec![10, 10, 11]);
        assert_eq!(started.elapsed(), Duration::from_secs(6));
    }

    #[tokio::test(start_paused = true)]
    async fn sender_filter_ignores_other_participants_but_advances_the_cursor() {
        let mut chat = FakeChat::new(
            vec![],
            vec![
                Step::Arrive(vec![theirs(5, 3)]),
                Step::Arrive(vec![theirs(6, 2)]),
            ],
        );
        let mut plan = plan(4);
        plan.filter = SenderFilter::Sender(2);
        let result = wait_for_messages(&mut chat, &plan).await.unwrap();
        assert_eq!(ids(&result), vec![6]);
        assert_eq!(chat.cursors, vec![4, 5]);
    }

    #[tokio::test(start_paused = true)]
    async fn times_out_with_the_cursor_of_everything_examined() {
        let mut chat = FakeChat::new(vec![], vec![Step::Arrive(vec![mine(8)])]);
        let mut plan = plan(7);
        plan.timeout = Duration::from_secs(10);
        let started = Instant::now();
        let result = wait_for_messages(&mut chat, &plan).await.unwrap();
        assert!(result.timed_out);
        assert!(result.messages.is_empty());
        assert_eq!(result.cursor, 8);
        assert_eq!(started.elapsed(), Duration::from_secs(10));
        // Reads at 0s, 3s, 6s, 9s, and a last look at the 10s deadline.
        assert_eq!(chat.cursors.len(), 5);
    }

    /// A chat whose server pushes an update at scripted times.
    struct PushedChat {
        chat: FakeChat,
        pushes: VecDeque<Duration>,
        started: Instant,
    }

    impl HistorySource for PushedChat {
        async fn fetch_newer(
            &mut self,
            after_id: i64,
            limit: i32,
        ) -> Result<Vec<proto::Message>, Box<dyn Error>> {
            self.chat.fetch_newer(after_id, limit).await
        }

        fn is_transient(&self, error: &(dyn Error + 'static)) -> bool {
            self.chat.is_transient(error)
        }

        fn receives_pushes(&self) -> bool {
            true
        }

        async fn wait_for_activity(&mut self, until: Instant) -> bool {
            match self.pushes.front().map(|at| self.started + *at) {
                Some(push) if push < until => {
                    self.pushes.pop_front();
                    sleep_until(push).await;
                    true
                }
                _ => {
                    sleep_until(until).await;
                    false
                }
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_pushed_update_wakes_the_wait_at_once() {
        let started = Instant::now();
        let mut chat = PushedChat {
            chat: FakeChat::new(
                vec![mine(10)],
                vec![Step::Arrive(vec![]), Step::Arrive(vec![theirs(11, 2)])],
            ),
            pushes: VecDeque::from([Duration::from_millis(1_200)]),
            started,
        };
        let result = wait_for_messages(&mut chat, &plan(10)).await.unwrap();
        assert_eq!(ids(&result), vec![11]);
        assert_eq!(started.elapsed(), Duration::from_millis(1_200));
        assert_eq!(chat.chat.cursors, vec![10, 10]);
    }

    #[tokio::test(start_paused = true)]
    async fn with_pushes_a_quiet_chat_is_read_only_by_the_safety_read() {
        let started = Instant::now();
        let mut chat = PushedChat {
            chat: FakeChat::new(vec![], vec![]),
            pushes: VecDeque::new(),
            started,
        };
        let result = wait_for_messages(&mut chat, &plan(7)).await.unwrap();
        assert!(result.timed_out);
        // 0 s, the 30 s safety read, and the 60 s deadline: 3 reads, not 21.
        assert_eq!(chat.chat.cursors.len(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn with_pushes_settle_still_ends_on_time() {
        let started = Instant::now();
        let mut chat = PushedChat {
            chat: FakeChat::new(
                vec![],
                vec![
                    Step::Arrive(vec![theirs(2, 9)]),
                    Step::Arrive(vec![theirs(3, 9)]),
                    Step::Arrive(vec![]),
                ],
            ),
            pushes: VecDeque::from([Duration::from_secs(1)]),
            started,
        };
        let mut plan = plan(1);
        plan.settle = Duration::from_secs(5);
        let result = wait_for_messages(&mut chat, &plan).await.unwrap();
        // 2 at 0 s, 3 on the 1 s push, then a last read when settle ends at 6 s.
        assert_eq!(ids(&result), vec![2, 3]);
        assert_eq!(started.elapsed(), Duration::from_secs(6));
        assert_eq!(chat.chat.cursors.len(), 3);
    }

    fn new_message(chat_id: i64, peer: Option<proto::peer::Type>) -> proto::Update {
        proto::Update {
            update: Some(proto::update::Update::NewMessage(proto::UpdateNewMessage {
                message: Some(proto::Message {
                    id: 1,
                    chat_id,
                    peer_id: peer.map(|r#type| proto::Peer {
                        r#type: Some(r#type),
                    }),
                    ..Default::default()
                }),
            })),
            ..Default::default()
        }
    }

    #[test]
    fn only_updates_about_the_target_chat_wake_the_wait() {
        let chat = WaitTarget {
            chat_id: Some(40),
            peer_user_id: None,
        };
        assert!(chat.woken_by(&new_message(40, None)));
        assert!(!chat.woken_by(&new_message(41, None)));

        let dm = WaitTarget {
            chat_id: None,
            peer_user_id: Some(7),
        };
        let from_peer = proto::peer::Type::User(proto::PeerUser { user_id: 7 });
        let from_other = proto::peer::Type::User(proto::PeerUser { user_id: 8 });
        assert!(dm.woken_by(&new_message(99, Some(from_peer))));
        assert!(!dm.woken_by(&new_message(98, Some(from_other))));

        let hint = proto::Update {
            update: Some(proto::update::Update::ChatHasNewUpdates(
                proto::UpdateChatHasNewUpdates {
                    chat_id: 40,
                    ..Default::default()
                },
            )),
            ..Default::default()
        };
        assert!(chat.woken_by(&hint));
        assert!(!dm.woken_by(&hint));

        let status = proto::Update {
            update: Some(proto::update::Update::UpdateUserStatus(Default::default())),
            ..Default::default()
        };
        assert!(!chat.woken_by(&status));

        let account = proto::Update {
            update: Some(proto::update::Update::UserHasNewUpdates(Default::default())),
            ..Default::default()
        };
        assert!(dm.woken_by(&account));
        assert!(!chat.woken_by(&account));
    }

    #[tokio::test(start_paused = true)]
    async fn settle_collects_a_burst_into_one_result() {
        let mut chat = FakeChat::new(
            vec![],
            vec![
                Step::Arrive(vec![theirs(2, 9)]),
                Step::Arrive(vec![theirs(3, 9)]),
                Step::Arrive(vec![]),
                Step::Arrive(vec![]),
                Step::Arrive(vec![theirs(4, 9)]),
            ],
        );
        let mut plan = plan(1);
        plan.settle = Duration::from_secs(5);
        let result = wait_for_messages(&mut chat, &plan).await.unwrap();
        // 2 at 0s, 3 at 3s, quiet at 6s, settle ends at 8s before 4 arrives.
        assert_eq!(ids(&result), vec![2, 3]);
        assert_eq!(result.cursor, 3);
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_does_not_repeat_or_skip_messages() {
        let mut chat = FakeChat::new(
            vec![],
            vec![
                Step::Arrive(vec![mine(21)]),
                Step::Disconnect,
                Step::Arrive(vec![theirs(22, 2), theirs(23, 2)]),
            ],
        );
        let mut plan = plan(20);
        plan.settle = Duration::from_secs(1);
        let result = wait_for_messages(&mut chat, &plan).await.unwrap();
        assert_eq!(ids(&result), vec![22, 23]);
        assert_eq!(chat.cursors, vec![20, 21, 21, 23]);
    }

    #[tokio::test(start_paused = true)]
    async fn permanent_failures_end_the_wait() {
        let mut chat = FakeChat::new(vec![], vec![Step::Deny]);
        let error = wait_for_messages(&mut chat, &plan(1)).await.unwrap_err();
        assert!(error.downcast_ref::<FakeDenied>().is_some());
    }

    #[tokio::test(start_paused = true)]
    async fn an_unreachable_chat_is_an_error_not_a_timeout() {
        let steps = (0..20).map(|_| Step::Disconnect).collect();
        let mut chat = FakeChat::new(vec![], steps);
        let mut plan = plan(1);
        plan.timeout = Duration::from_secs(20);
        let error = wait_for_messages(&mut chat, &plan).await.unwrap_err();
        assert!(error.downcast_ref::<FakeDisconnect>().is_some());
    }

    #[tokio::test(start_paused = true)]
    async fn drains_full_pages_and_caps_one_result() {
        let history: Vec<_> = (1..=450).map(|id| theirs(id, 2)).collect();
        let mut chat = FakeChat::new(history, vec![]);
        let result = wait_for_messages(&mut chat, &plan(0)).await.unwrap();
        assert_eq!(result.messages.len(), WAIT_MAX_MATCHES);
        assert_eq!(result.cursor, WAIT_MAX_MATCHES as i64);
        assert_eq!(chat.cursors, vec![0, 100]);
        assert_eq!(
            ids(&result),
            (1..=WAIT_MAX_MATCHES as i64).collect::<Vec<_>>()
        );
    }

    #[test]
    fn parses_durations() {
        assert_eq!(
            parse_wait_duration("--timeout", "90").unwrap(),
            Duration::from_secs(90)
        );
        assert_eq!(
            parse_wait_duration("--timeout", "30m").unwrap(),
            Duration::from_secs(1800)
        );
        assert_eq!(
            parse_wait_duration("--timeout", "2h").unwrap(),
            Duration::from_secs(7200)
        );
        assert_eq!(
            parse_wait_duration("--settle", "0s").unwrap(),
            Duration::ZERO
        );
        assert!(parse_wait_duration("--timeout", "soon").is_err());
        assert!(parse_wait_duration("--timeout", "5w").is_err());
        assert!(parse_wait_duration("--timeout", "").is_err());
    }
}

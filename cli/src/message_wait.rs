//! `inline messages wait`: block until new messages arrive in one chat.
//!
//! One bounded call replaces an agent's `messages list` polling loop. The wait
//! first reads everything after the `--after` cursor (so a reply that landed
//! between the agent's send and this call is not missed), then keeps reading
//! newer history on one connection. The cursor only moves forward, so a
//! reconnect never reports a message twice.

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

        let delay = if last_failure.is_some() {
            let delay = retry_backoff;
            retry_backoff = (retry_backoff * 2).min(MAX_RETRY_BACKOFF);
            delay
        } else {
            plan.poll_interval
        };
        let mut wake = (now + delay).min(deadline);
        if let Some(until) = settle_until {
            wake = wake.min(until);
        }
        sleep_until(wake).await;
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
        assert_eq!(parse_wait_duration("--timeout", "90").unwrap(), Duration::from_secs(90));
        assert_eq!(parse_wait_duration("--timeout", "30m").unwrap(), Duration::from_secs(1800));
        assert_eq!(parse_wait_duration("--timeout", "2h").unwrap(), Duration::from_secs(7200));
        assert_eq!(parse_wait_duration("--settle", "0s").unwrap(), Duration::ZERO);
        assert!(parse_wait_duration("--timeout", "soon").is_err());
        assert!(parse_wait_duration("--timeout", "5w").is_err());
        assert!(parse_wait_duration("--timeout", "").is_err());
    }
}

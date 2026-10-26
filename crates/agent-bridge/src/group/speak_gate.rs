//! The speak gate (spec §5.1 rule 5): whether a participating agent replies
//! to unaddressed human messages.
//!
//! The contract is the [`SpeakGate`] trait: a side evaluation over a batch at
//! a quiet boundary that returns speak / why / confidence and leaves no trace
//! in the session. Its mechanism (Codex `thread/sample`, a small Claude
//! `--bare` no-tool query) plugs in behind the trait. Without a gate the agent
//! behaves as mentions-only. The gate is off while the work is paused.

use std::future::Future;
use std::pin::Pin;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::caps::{BudgetOutcome, DailySpeakGateBudget, DayKey};
use super::participation::ParticipationMode;

/// Quiet time after the last candidate before one evaluation covers the
/// whole burst. Inline-chosen batching, not a cap.
pub const DEFAULT_QUIET_WINDOW_MS: u64 = 3_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GateAvailability {
    Available,
    Unavailable { reason: String },
}

/// One evaluation request. `guide` is trusted, static bridge text; `context`
/// is the untrusted rendered batch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpeakGateRequest {
    pub chat_id: i64,
    pub bot_user_id: i64,
    pub message_ids: Vec<i64>,
    pub guide: String,
    pub context: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SpeakVerdict {
    pub speak: bool,
    pub why: String,
    /// 0.0–1.0 as the gate reports it; recorded, not thresholded.
    pub confidence: f32,
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum SpeakGateError {
    #[error("speak gate unavailable: {0}")]
    Unavailable(String),
    #[error("speak gate failed: {0}")]
    Failed(String),
}

pub type SpeakGateFuture<'a> =
    Pin<Box<dyn Future<Output = Result<SpeakVerdict, SpeakGateError>> + Send + 'a>>;

pub trait SpeakGate: Send + Sync {
    fn availability(&self) -> GateAvailability;
    fn evaluate(&self, request: SpeakGateRequest) -> SpeakGateFuture<'_>;
}

/// The gate used until a mechanism is available for a runtime.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnavailableSpeakGate {
    reason: String,
}

impl UnavailableSpeakGate {
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }
}

impl SpeakGate for UnavailableSpeakGate {
    fn availability(&self) -> GateAvailability {
        GateAvailability::Unavailable {
            reason: self.reason.clone(),
        }
    }

    fn evaluate(&self, _request: SpeakGateRequest) -> SpeakGateFuture<'_> {
        let reason = self.reason.clone();
        Box::pin(async move { Err(SpeakGateError::Unavailable(reason)) })
    }
}

/// Active mode without a gate behaves as mentions-only in that thread.
pub fn effective_mode(mode: ParticipationMode, gate: &GateAvailability) -> ParticipationMode {
    match (mode, gate) {
        (ParticipationMode::Active, GateAvailability::Unavailable { .. }) => {
            ParticipationMode::MentionsOnly
        }
        (mode, _) => mode,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GateAdmission {
    Evaluate {
        remaining_today: u32,
    },
    Paused,
    NotActive,
    Unavailable,
    /// The daily budget is spent; `notify_owner` once per day.
    BudgetExhausted {
        notify_owner: bool,
    },
}

/// Whether a ready batch may be evaluated now. Spends one unit of the daily
/// budget only when it returns [`GateAdmission::Evaluate`].
pub fn gate_admission(
    mode: ParticipationMode,
    gate: &GateAvailability,
    paused: bool,
    budget: &mut DailySpeakGateBudget,
    today: DayKey,
) -> GateAdmission {
    if paused {
        return GateAdmission::Paused;
    }
    if mode != ParticipationMode::Active {
        return GateAdmission::NotActive;
    }
    if matches!(gate, GateAvailability::Unavailable { .. }) {
        return GateAdmission::Unavailable;
    }
    match budget.try_consume(today) {
        BudgetOutcome::Allowed { remaining } => GateAdmission::Evaluate {
            remaining_today: remaining,
        },
        BudgetOutcome::Exhausted { notify_owner, .. } => {
            GateAdmission::BudgetExhausted { notify_owner }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ConsiderReadiness {
    Empty,
    /// The session is mid-turn or an evaluation is in flight.
    Busy,
    WaitUntil {
        at_ms: u64,
    },
    Ready,
}

/// A batch handed to the gate. Stale once the queue is superseded.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConsiderTicket {
    epoch: u64,
    pub message_ids: Vec<i64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ConsiderOutcome {
    /// Start a turn for these messages (already delivered as passive context).
    Speak {
        message_ids: Vec<i64>,
        why: String,
    },
    Quiet {
        message_ids: Vec<i64>,
    },
    /// Direct input or a turn superseded the evaluation; nothing to do.
    Discarded,
}

/// Candidates for the speak gate in one thread, batched to a quiet boundary:
/// the session is idle and the thread has been quiet for the window.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConsiderQueue {
    quiet_window_ms: u64,
    pending: Vec<i64>,
    last_arrival_ms: Option<u64>,
    in_flight: bool,
    epoch: u64,
}

impl Default for ConsiderQueue {
    fn default() -> Self {
        Self::new(DEFAULT_QUIET_WINDOW_MS)
    }
}

impl ConsiderQueue {
    pub fn new(quiet_window_ms: u64) -> Self {
        Self {
            quiet_window_ms,
            pending: Vec::new(),
            last_arrival_ms: None,
            in_flight: false,
            epoch: 0,
        }
    }

    pub fn push(&mut self, message_id: i64, now_ms: u64) {
        if !self.pending.contains(&message_id) {
            self.pending.push(message_id);
        }
        self.last_arrival_ms = Some(now_ms);
    }

    pub fn readiness(&self, now_ms: u64, session_idle: bool) -> ConsiderReadiness {
        if self.pending.is_empty() {
            return ConsiderReadiness::Empty;
        }
        if !session_idle || self.in_flight {
            return ConsiderReadiness::Busy;
        }
        let at_ms = self
            .last_arrival_ms
            .unwrap_or(now_ms)
            .saturating_add(self.quiet_window_ms);
        if now_ms < at_ms {
            ConsiderReadiness::WaitUntil { at_ms }
        } else {
            ConsiderReadiness::Ready
        }
    }

    /// Takes the batch when ready. Messages arriving during the evaluation
    /// wait for the next round.
    pub fn take(&mut self, now_ms: u64, session_idle: bool) -> Option<ConsiderTicket> {
        if self.readiness(now_ms, session_idle) != ConsiderReadiness::Ready {
            return None;
        }
        self.in_flight = true;
        Some(ConsiderTicket {
            epoch: self.epoch,
            message_ids: std::mem::take(&mut self.pending),
        })
    }

    /// Resolves an evaluation. A failed evaluation is quiet: the agent does
    /// not speak on an error.
    pub fn finish(
        &mut self,
        ticket: ConsiderTicket,
        verdict: Result<SpeakVerdict, SpeakGateError>,
    ) -> ConsiderOutcome {
        if ticket.epoch != self.epoch {
            return ConsiderOutcome::Discarded;
        }
        self.in_flight = false;
        match verdict {
            Ok(SpeakVerdict {
                speak: true, why, ..
            }) => {
                // Speaking starts a turn that sees anything newer as context.
                self.pending.clear();
                ConsiderOutcome::Speak {
                    message_ids: ticket.message_ids,
                    why,
                }
            }
            _ => ConsiderOutcome::Quiet {
                message_ids: ticket.message_ids,
            },
        }
    }

    /// Drops the batch and any evaluation in flight, for example on direct
    /// input or pause: the next turn sees these messages as passive context.
    pub fn supersede(&mut self) {
        self.pending.clear();
        self.last_arrival_ms = None;
        self.in_flight = false;
        self.epoch += 1;
    }

    pub fn pending(&self) -> &[i64] {
        &self.pending
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verdict(speak: bool) -> Result<SpeakVerdict, SpeakGateError> {
        Ok(SpeakVerdict {
            speak,
            why: "asked about CI".into(),
            confidence: 0.8,
        })
    }

    #[test]
    fn active_without_a_gate_behaves_as_mentions_only() {
        let unavailable = GateAvailability::Unavailable {
            reason: "thread/sample needs Codex ≥ X".into(),
        };
        assert_eq!(
            effective_mode(ParticipationMode::Active, &unavailable),
            ParticipationMode::MentionsOnly
        );
        assert_eq!(
            effective_mode(ParticipationMode::Muted, &unavailable),
            ParticipationMode::Muted
        );
        assert_eq!(
            effective_mode(ParticipationMode::Active, &GateAvailability::Available),
            ParticipationMode::Active
        );
    }

    #[test]
    fn admission_checks_pause_mode_and_gate_before_spending_budget() {
        let mut budget = DailySpeakGateBudget::new(1);
        let today = DayKey(1);
        let available = GateAvailability::Available;
        assert_eq!(
            gate_admission(
                ParticipationMode::Active,
                &available,
                true,
                &mut budget,
                today
            ),
            GateAdmission::Paused
        );
        assert_eq!(
            gate_admission(
                ParticipationMode::MentionsOnly,
                &available,
                false,
                &mut budget,
                today
            ),
            GateAdmission::NotActive
        );
        assert_eq!(
            gate_admission(
                ParticipationMode::Active,
                &GateAvailability::Unavailable { reason: "x".into() },
                false,
                &mut budget,
                today
            ),
            GateAdmission::Unavailable
        );
        assert_eq!(budget.status(today), (0, 1));
        assert_eq!(
            gate_admission(
                ParticipationMode::Active,
                &available,
                false,
                &mut budget,
                today
            ),
            GateAdmission::Evaluate { remaining_today: 0 }
        );
        assert_eq!(
            gate_admission(
                ParticipationMode::Active,
                &available,
                false,
                &mut budget,
                today
            ),
            GateAdmission::BudgetExhausted { notify_owner: true }
        );
    }

    #[test]
    fn queue_waits_for_an_idle_session_and_a_quiet_thread() {
        let mut queue = ConsiderQueue::new(1_000);
        assert_eq!(queue.readiness(0, true), ConsiderReadiness::Empty);
        queue.push(1, 100);
        queue.push(2, 600);
        queue.push(2, 650);
        assert_eq!(queue.pending(), [1, 2]);
        assert_eq!(queue.readiness(1_000, false), ConsiderReadiness::Busy);
        assert_eq!(
            queue.readiness(1_000, true),
            ConsiderReadiness::WaitUntil { at_ms: 1_650 }
        );
        assert!(queue.take(1_000, true).is_none());
        let ticket = queue.take(1_650, true).expect("ready");
        assert_eq!(ticket.message_ids, [1, 2]);
        // One evaluation at a time; new candidates wait.
        queue.push(3, 1_700);
        assert_eq!(queue.readiness(5_000, true), ConsiderReadiness::Busy);
        assert_eq!(
            queue.finish(ticket, verdict(false)),
            ConsiderOutcome::Quiet {
                message_ids: vec![1, 2]
            }
        );
        assert_eq!(queue.readiness(5_000, true), ConsiderReadiness::Ready);
    }

    #[test]
    fn speaking_clears_newer_candidates() {
        let mut queue = ConsiderQueue::new(0);
        queue.push(1, 0);
        let ticket = queue.take(0, true).unwrap();
        queue.push(2, 1);
        assert_eq!(
            queue.finish(ticket, verdict(true)),
            ConsiderOutcome::Speak {
                message_ids: vec![1],
                why: "asked about CI".into()
            }
        );
        assert!(queue.pending().is_empty());
    }

    #[test]
    fn errors_are_quiet_and_superseded_evaluations_are_discarded() {
        let mut queue = ConsiderQueue::new(0);
        queue.push(1, 0);
        let ticket = queue.take(0, true).unwrap();
        assert_eq!(
            queue.finish(ticket, Err(SpeakGateError::Failed("timeout".into()))),
            ConsiderOutcome::Quiet {
                message_ids: vec![1]
            }
        );

        queue.push(2, 0);
        let ticket = queue.take(0, true).unwrap();
        queue.supersede();
        assert_eq!(
            queue.finish(ticket, verdict(true)),
            ConsiderOutcome::Discarded
        );
        assert_eq!(queue.readiness(0, true), ConsiderReadiness::Empty);
    }

    #[tokio::test]
    async fn the_unavailable_gate_reports_its_reason() {
        let gate = UnavailableSpeakGate::new("no sample method");
        assert_eq!(
            gate.availability(),
            GateAvailability::Unavailable {
                reason: "no sample method".into()
            }
        );
        let result = gate
            .evaluate(SpeakGateRequest {
                chat_id: 1,
                bot_user_id: 2,
                message_ids: vec![3],
                guide: String::new(),
                context: String::new(),
            })
            .await;
        assert_eq!(
            result,
            Err(SpeakGateError::Unavailable("no sample method".into()))
        );
    }
}

//! Hold, release and acquire for one native session (spec §4.6).
//!
//! - **Hold** while the session works. When it is idle with no live work,
//!   Codex is unsubscribed at once and the app-server unloads the thread after
//!   the user's own `thread_unload_delay_secs`; Claude has no idle unload, so
//!   stdin is closed after an Inline idle window (1800 s by default).
//! - **The idle timer never releases live work:** an active turn, background
//!   tasks, children, a pending interaction, queued input or a wakeup.
//! - **Explicit release wins.** `/release`, "Continue in terminal" and "Open
//!   in app" release now. With live work, the machine lists it for
//!   confirmation, then stops or hands over each item with a receipt.
//! - **Acquire** on direct input or `/resume`. A session held by another
//!   client keeps the input pending and shows "continue there, or Fork here";
//!   pending input runs once the session frees, if its sender still wants it.
//!
//! The machine is pure: the runtime feeds [`HoldEvent`]s with the current
//! time and executes the returned [`HoldEffect`]s.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::ProviderSurface;

/// Claude's idle window: Inline-chosen to match Codex's default unload delay,
/// tunable.
pub const CLAUDE_IDLE_WINDOW: Duration = Duration::from_secs(1_800);
/// Codex's own default for `thread_unload_delay_secs` when the user's
/// `config.toml` does not set it.
pub const CODEX_DEFAULT_UNLOAD_DELAY: Duration = Duration::from_secs(1_800);
/// How long Claude may take to exit after stdin closes before it is killed.
pub const CLAUDE_EXIT_GRACE: Duration = Duration::from_secs(10);
/// How long release waits for each stop or hand-over before recording it as
/// failed and releasing anyway.
pub const RELEASE_STEP_TIMEOUT: Duration = Duration::from_secs(15);
/// How often a session held elsewhere is probed while input waits for it.
pub const HELD_ELSEWHERE_PROBE_INTERVAL: Duration = Duration::from_secs(60);

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// How an idle, held session is let go.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IdleRelease {
    /// Codex: unsubscribe when idle; the app-server unloads the thread after
    /// the user's own unload delay, which frees its writer lock.
    Unsubscribe { native_unload_delay_ms: u64 },
    /// Claude: close stdin after the idle window, then kill after the grace.
    CloseStdin {
        idle_window_ms: u64,
        exit_grace_ms: u64,
    },
}

impl IdleRelease {
    /// `thread_unload_delay_secs` from the user's Codex config, if set.
    pub fn codex(thread_unload_delay_secs: Option<u64>) -> Self {
        Self::Unsubscribe {
            native_unload_delay_ms: thread_unload_delay_secs
                .map_or(millis(CODEX_DEFAULT_UNLOAD_DELAY), |secs| {
                    secs.saturating_mul(1_000)
                }),
        }
    }

    pub fn claude(idle_window: Duration) -> Self {
        Self::CloseStdin {
            idle_window_ms: millis(idle_window),
            exit_grace_ms: millis(CLAUDE_EXIT_GRACE),
        }
    }

    const fn idle_after_ms(self) -> u64 {
        match self {
            Self::Unsubscribe { .. } => 0,
            Self::CloseStdin { idle_window_ms, .. } => idle_window_ms,
        }
    }
}

/// One live piece of work, with a label for the confirmation and receipt.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveItem {
    pub id: String,
    pub label: String,
}

impl LiveItem {
    pub fn new(id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
        }
    }
}

/// Work that keeps a session held, as the driver last reported it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiveWork {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_turn: Option<LiveItem>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub background_tasks: Vec<LiveItem>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<LiveItem>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub interactions: Vec<LiveItem>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub queued_inputs: Vec<LiveItem>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub wakeups: Vec<LiveItem>,
}

impl LiveWork {
    pub fn is_empty(&self) -> bool {
        self.active_turn.is_none()
            && self.background_tasks.is_empty()
            && self.children.is_empty()
            && self.interactions.is_empty()
            && self.queued_inputs.is_empty()
            && self.wakeups.is_empty()
    }

    /// Release steps, ordered so nothing restarts while stopping: queued input
    /// leaves the native queue first (Claude runs its queue after an
    /// interrupt), then interactions close, then the turn, children and
    /// background tasks stop.
    pub fn release_steps(&self, wakeups: WakeupDisposition) -> Vec<ReleaseStep> {
        let step = |action, item: &LiveItem| ReleaseStep {
            action,
            item: item.clone(),
        };
        let wakeup_action = match wakeups {
            WakeupDisposition::LeaveForNextHolder => ReleaseAction::LeaveWakeup,
            WakeupDisposition::Cancel => ReleaseAction::CancelWakeup,
        };
        self.queued_inputs
            .iter()
            .map(|item| step(ReleaseAction::KeepQueuedPending, item))
            .chain(
                self.interactions
                    .iter()
                    .map(|item| step(ReleaseAction::CancelInteraction, item)),
            )
            .chain(
                self.active_turn
                    .iter()
                    .map(|item| step(ReleaseAction::InterruptTurn, item)),
            )
            .chain(
                self.children
                    .iter()
                    .map(|item| step(ReleaseAction::StopChild, item)),
            )
            .chain(
                self.background_tasks
                    .iter()
                    .map(|item| step(ReleaseAction::StopBackgroundTask, item)),
            )
            .chain(self.wakeups.iter().map(|item| step(wakeup_action, item)))
            .collect()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReleaseAction {
    /// Codex `turn/interrupt`, Claude `interrupt`.
    InterruptTurn,
    /// Through the parent, as the harness does (Codex sub-agents, Claude
    /// subagents).
    StopChild,
    /// Claude `stop_task`, Codex `thread/backgroundTerminals/terminate`.
    StopBackgroundTask,
    /// Cancel the pending approval or question.
    CancelInteraction,
    /// Take queued input out of the native queue and keep it pending in Inline.
    KeepQueuedPending,
    CancelWakeup,
    /// Leave a scheduled wakeup to whoever takes the session; no native call.
    LeaveWakeup,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReleaseStep {
    pub action: ReleaseAction,
    pub item: LiveItem,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ReleaseStepOutcome {
    Done,
    Failed { reason: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReleaseReceipt {
    pub step: ReleaseStep,
    pub outcome: ReleaseStepOutcome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReleaseCause {
    /// `/release`.
    Command,
    ContinueInTerminal,
    OpenInApp,
    /// The idle rule; silent, never with live work.
    Idle,
}

impl ReleaseCause {
    pub const fn is_explicit(self) -> bool {
        !matches!(self, Self::Idle)
    }

    const fn is_handoff(self) -> bool {
        matches!(self, Self::ContinueInTerminal | Self::OpenInApp)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WakeupDisposition {
    LeaveForNextHolder,
    Cancel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReleaseRequest {
    pub cause: ReleaseCause,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested_by: Option<i64>,
    pub wakeups: WakeupDisposition,
}

impl ReleaseRequest {
    /// Handoffs leave wakeups to the next client by default; `/release`
    /// cancels them. The confirmation can change it.
    pub fn new(cause: ReleaseCause, requested_by: Option<i64>) -> Self {
        Self {
            cause,
            requested_by,
            wakeups: if cause.is_handoff() {
                WakeupDisposition::LeaveForNextHolder
            } else {
                WakeupDisposition::Cancel
            },
        }
    }
}

/// The other client holding a session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeldBy {
    pub surface: ProviderSurface,
    /// Native detail, such as Codex's conflict message or a Claude agents
    /// listing entry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// Direct input waiting for the session, with its sender so the sender can be
/// asked whether it should still run.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingInput {
    pub id: String,
    pub sender_user_id: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ReleasePhase {
    Steps { deadline_ms: u64 },
    Closing { deadline_ms: u64 },
    Killing,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HoldState {
    Released,
    /// Codex after unsubscribe: the app-server keeps the thread loaded until
    /// its unload delay ends. Re-acquiring is a resubscribe.
    Unloading {
        unload_at_ms: u64,
    },
    Acquiring {
        /// Delivered once acquired.
        pending: Vec<PendingInput>,
        /// Offered back to their senders once acquired.
        offer: Vec<PendingInput>,
    },
    Held {
        last_activity_ms: u64,
        live: LiveWork,
    },
    ConfirmingRelease {
        request: ReleaseRequest,
        live: LiveWork,
        last_activity_ms: u64,
        pending: Vec<PendingInput>,
    },
    Releasing {
        request: ReleaseRequest,
        remaining: Vec<ReleaseStep>,
        receipts: Vec<ReleaseReceipt>,
        phase: ReleasePhase,
        pending: Vec<PendingInput>,
    },
    HeldElsewhere {
        by: HeldBy,
        pending: Vec<PendingInput>,
        next_probe_ms: u64,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HoldEvent {
    /// Direct input (`Some`) or `/resume` (`None`) wants the session.
    AcquireRequested {
        input: Option<PendingInput>,
    },
    Acquired,
    /// Another client holds it: Codex `Conflict` ("already has a live local
    /// writer"), Claude `session_held_by_background`, or a live entry in
    /// `claude agents --json`.
    AcquireConflict {
        by: HeldBy,
    },
    /// The driver's current live work, after any native event.
    Activity {
        live: LiveWork,
    },
    Tick,
    ReleaseRequested {
        request: ReleaseRequest,
    },
    ReleaseConfirmed,
    ReleaseCancelled,
    StepFinished {
        action: ReleaseAction,
        id: String,
        outcome: ReleaseStepOutcome,
    },
    /// The connection ended: Claude exited or the Codex subscription is gone.
    Detached,
    /// Codex reported the thread unloaded.
    NativeUnloaded,
    /// A probe found the session free.
    ElsewhereFreed,
    ForkHere,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HoldEffect {
    /// Codex: `thread/resume` and subscribe. Claude: spawn with `--resume`.
    Acquire,
    Deliver {
        inputs: Vec<PendingInput>,
    },
    /// The session freed or was acquired by `/resume`: ask each sender
    /// whether their pending input should still run.
    OfferPending {
        inputs: Vec<PendingInput>,
    },
    /// Show "Active in terminal / app: continue there, or Fork here".
    ShowHeldElsewhere {
        by: HeldBy,
    },
    ProbeHolder,
    /// List live work and ask to confirm the release.
    ConfirmRelease {
        request: ReleaseRequest,
        live: LiveWork,
    },
    Step(ReleaseStep),
    /// Codex.
    Unsubscribe,
    /// Claude: close stdin, then kill after `kill_after_ms`.
    CloseStdin {
        kill_after_ms: u64,
    },
    Kill,
    /// The session is released. Explicit causes post the receipts and the
    /// handoff instruction.
    Released {
        cause: ReleaseCause,
        receipts: Vec<ReleaseReceipt>,
    },
    /// Input that arrived during a release stays pending in Inline.
    PendingNotDelivered {
        inputs: Vec<PendingInput>,
    },
    /// Fork the held session here; the pending input goes to the fork.
    Fork {
        pending: Vec<PendingInput>,
    },
    /// The connection dropped while held; recover per the runtime's rules.
    Lost,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HoldMachine {
    policy: IdleRelease,
    state: HoldState,
}

impl HoldMachine {
    pub fn new(policy: IdleRelease) -> Self {
        Self {
            policy,
            state: HoldState::Released,
        }
    }

    pub fn state(&self) -> &HoldState {
        &self.state
    }

    pub fn is_held(&self) -> bool {
        matches!(
            self.state,
            HoldState::Held { .. }
                | HoldState::ConfirmingRelease { .. }
                | HoldState::Releasing { .. }
        )
    }

    pub fn held_elsewhere(&self) -> Option<&HeldBy> {
        match &self.state {
            HoldState::HeldElsewhere { by, .. } => Some(by),
            _ => None,
        }
    }

    pub fn handle(&mut self, event: HoldEvent, now_ms: u64) -> Vec<HoldEffect> {
        let state = std::mem::replace(&mut self.state, HoldState::Released);
        let mut effects = Vec::new();
        self.state = self.transition(state, event, now_ms, &mut effects);
        effects
    }

    fn transition(
        &self,
        state: HoldState,
        event: HoldEvent,
        now: u64,
        effects: &mut Vec<HoldEffect>,
    ) -> HoldState {
        use HoldEvent as E;
        use HoldState as S;
        match (state, event) {
            // Released or unloading: acquire on demand.
            (S::Released | S::Unloading { .. }, E::AcquireRequested { input }) => {
                effects.push(HoldEffect::Acquire);
                S::Acquiring {
                    pending: input.into_iter().collect(),
                    offer: Vec::new(),
                }
            }
            (state @ (S::Released | S::Unloading { .. }), E::ReleaseRequested { request }) => {
                effects.push(HoldEffect::Released {
                    cause: request.cause,
                    receipts: Vec::new(),
                });
                state
            }
            // A late acquisition nobody wants any more is let go again.
            (S::Released | S::Unloading { .. }, E::Acquired) => self.detach(
                ReleaseRequest::new(ReleaseCause::Idle, None),
                Vec::new(),
                Vec::new(),
                now,
                effects,
            ),
            (S::Unloading { unload_at_ms }, E::Tick) if now >= unload_at_ms => S::Released,
            (S::Unloading { .. }, E::NativeUnloaded) => S::Released,

            // Acquiring.
            (S::Acquiring { mut pending, offer }, E::AcquireRequested { input }) => {
                pending.extend(input);
                S::Acquiring { pending, offer }
            }
            (S::Acquiring { pending, offer }, E::Acquired) => {
                push_inputs(effects, HoldEffect::Deliver { inputs: pending });
                push_inputs(effects, HoldEffect::OfferPending { inputs: offer });
                S::Held {
                    last_activity_ms: now,
                    live: LiveWork::default(),
                }
            }
            (S::Acquiring { mut pending, offer }, E::AcquireConflict { by }) => {
                pending.extend(offer);
                effects.push(HoldEffect::ShowHeldElsewhere { by: by.clone() });
                S::HeldElsewhere {
                    by,
                    pending,
                    next_probe_ms: now + millis(HELD_ELSEWHERE_PROBE_INTERVAL),
                }
            }
            (S::Acquiring { mut pending, offer }, E::ReleaseRequested { request }) => {
                pending.extend(offer);
                push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
                effects.push(HoldEffect::Released {
                    cause: request.cause,
                    receipts: Vec::new(),
                });
                S::Released
            }
            (S::Acquiring { mut pending, offer }, E::Detached) => {
                pending.extend(offer);
                push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
                S::Released
            }

            // Held.
            (S::Held { live, .. }, E::AcquireRequested { input }) => {
                push_inputs(
                    effects,
                    HoldEffect::Deliver {
                        inputs: input.into_iter().collect(),
                    },
                );
                S::Held {
                    last_activity_ms: now,
                    live,
                }
            }
            (S::Held { .. }, E::Activity { live }) => S::Held {
                last_activity_ms: now,
                live,
            },
            (
                S::Held {
                    last_activity_ms,
                    live,
                },
                E::Tick,
            ) => {
                if live.is_empty()
                    && now.saturating_sub(last_activity_ms) >= self.policy.idle_after_ms()
                {
                    self.detach(
                        ReleaseRequest::new(ReleaseCause::Idle, None),
                        Vec::new(),
                        Vec::new(),
                        now,
                        effects,
                    )
                } else {
                    S::Held {
                        last_activity_ms,
                        live,
                    }
                }
            }
            (
                S::Held {
                    last_activity_ms,
                    live,
                },
                E::ReleaseRequested { request },
            ) => {
                if live.is_empty() {
                    self.detach(request, Vec::new(), Vec::new(), now, effects)
                } else {
                    effects.push(HoldEffect::ConfirmRelease {
                        request,
                        live: live.clone(),
                    });
                    S::ConfirmingRelease {
                        request,
                        live,
                        last_activity_ms,
                        pending: Vec::new(),
                    }
                }
            }
            (S::Held { .. }, E::Detached) => {
                effects.push(HoldEffect::Lost);
                S::Released
            }

            // Confirming an explicit release: nothing but the answer (or the
            // live work ending by itself) moves it on; input waits in Inline.
            (
                S::ConfirmingRelease {
                    request,
                    live,
                    last_activity_ms,
                    mut pending,
                },
                E::AcquireRequested { input },
            ) => {
                pending.extend(input);
                S::ConfirmingRelease {
                    request,
                    live,
                    last_activity_ms,
                    pending,
                }
            }
            (
                S::ConfirmingRelease {
                    request,
                    live: old,
                    pending,
                    ..
                },
                E::Activity { live },
            ) => {
                if live.is_empty() {
                    self.detach(request, Vec::new(), pending, now, effects)
                } else {
                    if live != old {
                        effects.push(HoldEffect::ConfirmRelease {
                            request,
                            live: live.clone(),
                        });
                    }
                    S::ConfirmingRelease {
                        request,
                        live,
                        last_activity_ms: now,
                        pending,
                    }
                }
            }
            (
                S::ConfirmingRelease {
                    live,
                    last_activity_ms,
                    pending,
                    ..
                },
                E::ReleaseRequested { request },
            ) => {
                effects.push(HoldEffect::ConfirmRelease {
                    request,
                    live: live.clone(),
                });
                S::ConfirmingRelease {
                    request,
                    live,
                    last_activity_ms,
                    pending,
                }
            }
            (
                S::ConfirmingRelease {
                    request,
                    live,
                    pending,
                    ..
                },
                E::ReleaseConfirmed,
            ) => self.run_steps(
                request,
                live.release_steps(request.wakeups),
                pending,
                now,
                effects,
            ),
            (
                S::ConfirmingRelease {
                    live,
                    last_activity_ms,
                    pending,
                    ..
                },
                E::ReleaseCancelled,
            ) => {
                push_inputs(effects, HoldEffect::Deliver { inputs: pending });
                S::Held {
                    last_activity_ms,
                    live,
                }
            }
            (S::ConfirmingRelease { pending, .. }, E::Detached) => {
                effects.push(HoldEffect::Lost);
                push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
                S::Released
            }

            // Releasing.
            (
                S::Releasing {
                    request,
                    remaining,
                    receipts,
                    phase,
                    mut pending,
                },
                E::AcquireRequested { input },
            ) => {
                pending.extend(input);
                S::Releasing {
                    request,
                    remaining,
                    receipts,
                    phase,
                    pending,
                }
            }
            (
                S::Releasing {
                    request,
                    mut remaining,
                    mut receipts,
                    phase: phase @ ReleasePhase::Steps { .. },
                    pending,
                },
                E::StepFinished {
                    action,
                    id,
                    outcome,
                },
            ) => {
                if let Some(index) = remaining
                    .iter()
                    .position(|step| step.action == action && step.item.id == id)
                {
                    receipts.push(ReleaseReceipt {
                        step: remaining.remove(index),
                        outcome,
                    });
                }
                if remaining.is_empty() {
                    self.detach(request, receipts, pending, now, effects)
                } else {
                    S::Releasing {
                        request,
                        remaining,
                        receipts,
                        phase,
                        pending,
                    }
                }
            }
            (
                S::Releasing {
                    request,
                    remaining,
                    mut receipts,
                    phase: ReleasePhase::Steps { deadline_ms },
                    pending,
                },
                E::Tick,
            ) if now >= deadline_ms => {
                fail_remaining(&mut receipts, remaining, "timed out; released anyway");
                self.detach(request, receipts, pending, now, effects)
            }
            (
                S::Releasing {
                    request,
                    remaining,
                    receipts,
                    phase: ReleasePhase::Closing { deadline_ms },
                    pending,
                },
                E::Tick,
            ) if now >= deadline_ms => {
                effects.push(HoldEffect::Kill);
                S::Releasing {
                    request,
                    remaining,
                    receipts,
                    phase: ReleasePhase::Killing,
                    pending,
                }
            }
            (
                S::Releasing {
                    request,
                    remaining,
                    mut receipts,
                    pending,
                    ..
                },
                E::Detached,
            ) => {
                fail_remaining(
                    &mut receipts,
                    remaining,
                    "the session exited before this was confirmed",
                );
                effects.push(HoldEffect::Released {
                    cause: request.cause,
                    receipts,
                });
                push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
                S::Released
            }

            // Held elsewhere.
            (
                S::HeldElsewhere {
                    by,
                    mut pending,
                    next_probe_ms,
                },
                E::AcquireRequested { input: Some(input) },
            ) => {
                pending.push(input);
                S::HeldElsewhere {
                    by,
                    pending,
                    next_probe_ms,
                }
            }
            // `/resume` tries now; waiting input is offered, not run blindly.
            (S::HeldElsewhere { pending, .. }, E::AcquireRequested { input: None }) => {
                effects.push(HoldEffect::Acquire);
                S::Acquiring {
                    pending: Vec::new(),
                    offer: pending,
                }
            }
            (
                S::HeldElsewhere {
                    by,
                    pending,
                    next_probe_ms,
                },
                E::Tick,
            ) if !pending.is_empty() && now >= next_probe_ms => {
                effects.push(HoldEffect::ProbeHolder);
                S::HeldElsewhere {
                    by,
                    pending,
                    next_probe_ms: now + millis(HELD_ELSEWHERE_PROBE_INTERVAL),
                }
            }
            (
                S::HeldElsewhere {
                    by: old,
                    pending,
                    next_probe_ms,
                },
                E::AcquireConflict { by },
            ) => {
                if by != old {
                    effects.push(HoldEffect::ShowHeldElsewhere { by: by.clone() });
                }
                S::HeldElsewhere {
                    by,
                    pending,
                    next_probe_ms,
                }
            }
            (S::HeldElsewhere { pending, .. }, E::ElsewhereFreed) => {
                push_inputs(effects, HoldEffect::OfferPending { inputs: pending });
                S::Released
            }
            // A probe that acquired (Codex resume succeeds once free).
            (S::HeldElsewhere { pending, .. }, E::Acquired) => {
                push_inputs(effects, HoldEffect::OfferPending { inputs: pending });
                S::Held {
                    last_activity_ms: now,
                    live: LiveWork::default(),
                }
            }
            (S::HeldElsewhere { pending, .. }, E::ForkHere) => {
                effects.push(HoldEffect::Fork { pending });
                S::Released
            }
            (state @ S::HeldElsewhere { .. }, E::ReleaseRequested { request }) => {
                effects.push(HoldEffect::Released {
                    cause: request.cause,
                    receipts: Vec::new(),
                });
                state
            }

            (state, _) => state,
        }
    }

    fn run_steps(
        &self,
        request: ReleaseRequest,
        steps: Vec<ReleaseStep>,
        pending: Vec<PendingInput>,
        now: u64,
        effects: &mut Vec<HoldEffect>,
    ) -> HoldState {
        let mut receipts = Vec::new();
        let mut remaining = Vec::new();
        for step in steps {
            if step.action == ReleaseAction::LeaveWakeup {
                receipts.push(ReleaseReceipt {
                    step,
                    outcome: ReleaseStepOutcome::Done,
                });
            } else {
                effects.push(HoldEffect::Step(step.clone()));
                remaining.push(step);
            }
        }
        if remaining.is_empty() {
            return self.detach(request, receipts, pending, now, effects);
        }
        HoldState::Releasing {
            request,
            remaining,
            receipts,
            phase: ReleasePhase::Steps {
                deadline_ms: now + millis(RELEASE_STEP_TIMEOUT),
            },
            pending,
        }
    }

    /// Lets the native session go once nothing live is left.
    fn detach(
        &self,
        request: ReleaseRequest,
        receipts: Vec<ReleaseReceipt>,
        pending: Vec<PendingInput>,
        now: u64,
        effects: &mut Vec<HoldEffect>,
    ) -> HoldState {
        match self.policy {
            IdleRelease::Unsubscribe {
                native_unload_delay_ms,
            } => {
                effects.push(HoldEffect::Unsubscribe);
                effects.push(HoldEffect::Released {
                    cause: request.cause,
                    receipts,
                });
                push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
                HoldState::Unloading {
                    unload_at_ms: now.saturating_add(native_unload_delay_ms),
                }
            }
            IdleRelease::CloseStdin { exit_grace_ms, .. } => {
                effects.push(HoldEffect::CloseStdin {
                    kill_after_ms: exit_grace_ms,
                });
                HoldState::Releasing {
                    request,
                    remaining: Vec::new(),
                    receipts,
                    phase: ReleasePhase::Closing {
                        deadline_ms: now.saturating_add(exit_grace_ms),
                    },
                    pending,
                }
            }
        }
    }
}

fn push_inputs(effects: &mut Vec<HoldEffect>, effect: HoldEffect) {
    let empty = match &effect {
        HoldEffect::Deliver { inputs }
        | HoldEffect::OfferPending { inputs }
        | HoldEffect::PendingNotDelivered { inputs } => inputs.is_empty(),
        _ => false,
    };
    if !empty {
        effects.push(effect);
    }
}

fn fail_remaining(receipts: &mut Vec<ReleaseReceipt>, remaining: Vec<ReleaseStep>, reason: &str) {
    receipts.extend(remaining.into_iter().map(|step| ReleaseReceipt {
        step,
        outcome: ReleaseStepOutcome::Failed {
            reason: reason.to_string(),
        },
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: u64 = 60_000;

    fn codex() -> HoldMachine {
        HoldMachine::new(IdleRelease::codex(None))
    }

    fn claude() -> HoldMachine {
        HoldMachine::new(IdleRelease::claude(CLAUDE_IDLE_WINDOW))
    }

    fn input(id: &str) -> PendingInput {
        PendingInput {
            id: id.into(),
            sender_user_id: 8,
        }
    }

    fn held(machine: &mut HoldMachine, now: u64) {
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("first")),
            },
            now,
        );
        assert_eq!(
            machine.handle(HoldEvent::Acquired, now),
            [HoldEffect::Deliver {
                inputs: vec![input("first")]
            }]
        );
        assert!(machine.is_held());
    }

    fn busy() -> LiveWork {
        LiveWork {
            active_turn: Some(LiveItem::new("turn-1", "Current turn")),
            background_tasks: vec![LiveItem::new("task-1", "npm test")],
            children: vec![LiveItem::new("child-1", "Explorer")],
            interactions: vec![LiveItem::new("approval-1", "Run rm -rf build?")],
            queued_inputs: vec![LiveItem::new("queued-1", "and the docs")],
            wakeups: vec![LiveItem::new("wake-1", "Check CI in 10 min")],
        }
    }

    fn release(cause: ReleaseCause) -> HoldEvent {
        HoldEvent::ReleaseRequested {
            request: ReleaseRequest::new(cause, Some(7)),
        }
    }

    #[test]
    fn codex_policy_uses_the_users_unload_delay() {
        assert_eq!(
            IdleRelease::codex(None),
            IdleRelease::Unsubscribe {
                native_unload_delay_ms: 1_800_000
            }
        );
        assert_eq!(
            IdleRelease::codex(Some(120)),
            IdleRelease::Unsubscribe {
                native_unload_delay_ms: 120_000
            }
        );
        assert_eq!(
            IdleRelease::claude(CLAUDE_IDLE_WINDOW),
            IdleRelease::CloseStdin {
                idle_window_ms: 1_800_000,
                exit_grace_ms: 10_000
            }
        );
    }

    #[test]
    fn codex_unsubscribes_as_soon_as_idle_and_unloads_natively() {
        let mut machine = codex();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 1_000);
        assert!(machine.handle(HoldEvent::Tick, 10 * MIN).is_empty());
        machine.handle(
            HoldEvent::Activity {
                live: LiveWork::default(),
            },
            11 * MIN,
        );
        assert_eq!(
            machine.handle(HoldEvent::Tick, 11 * MIN + 5_000),
            [
                HoldEffect::Unsubscribe,
                HoldEffect::Released {
                    cause: ReleaseCause::Idle,
                    receipts: Vec::new()
                }
            ]
        );
        assert_eq!(
            machine.state(),
            &HoldState::Unloading {
                unload_at_ms: 11 * MIN + 5_000 + 30 * MIN
            }
        );
        // Re-acquiring while still loaded is a resubscribe.
        let mut resubscribed = machine.clone();
        assert_eq!(
            resubscribed.handle(HoldEvent::AcquireRequested { input: None }, 12 * MIN),
            [HoldEffect::Acquire]
        );
        machine.handle(HoldEvent::Tick, 41 * MIN + 5_000);
        assert_eq!(machine.state(), &HoldState::Released);
    }

    #[test]
    fn claude_closes_stdin_after_the_idle_window_then_kills() {
        let mut machine = claude();
        held(&mut machine, 0);
        assert!(machine.handle(HoldEvent::Tick, 29 * MIN).is_empty());
        assert_eq!(
            machine.handle(HoldEvent::Tick, 30 * MIN),
            [HoldEffect::CloseStdin {
                kill_after_ms: 10_000
            }]
        );
        assert!(machine.handle(HoldEvent::Tick, 30 * MIN + 5_000).is_empty());
        assert_eq!(
            machine.handle(HoldEvent::Tick, 30 * MIN + 10_000),
            [HoldEffect::Kill]
        );
        assert!(
            machine
                .handle(HoldEvent::Tick, 30 * MIN + 20_000)
                .is_empty()
        );
        assert_eq!(
            machine.handle(HoldEvent::Detached, 30 * MIN + 21_000),
            [HoldEffect::Released {
                cause: ReleaseCause::Idle,
                receipts: Vec::new()
            }]
        );
        assert_eq!(machine.state(), &HoldState::Released);
    }

    #[test]
    fn the_idle_timer_never_releases_live_work() {
        for live in [
            LiveWork {
                active_turn: Some(LiveItem::new("t", "turn")),
                ..LiveWork::default()
            },
            LiveWork {
                background_tasks: vec![LiveItem::new("b", "task")],
                ..LiveWork::default()
            },
            LiveWork {
                children: vec![LiveItem::new("c", "child")],
                ..LiveWork::default()
            },
            LiveWork {
                interactions: vec![LiveItem::new("i", "question")],
                ..LiveWork::default()
            },
            LiveWork {
                queued_inputs: vec![LiveItem::new("q", "queued")],
                ..LiveWork::default()
            },
            LiveWork {
                wakeups: vec![LiveItem::new("w", "wakeup")],
                ..LiveWork::default()
            },
        ] {
            for mut machine in [codex(), claude()] {
                held(&mut machine, 0);
                machine.handle(HoldEvent::Activity { live: live.clone() }, 0);
                assert!(machine.handle(HoldEvent::Tick, 24 * 60 * MIN).is_empty());
                assert!(machine.is_held());
            }
        }
    }

    #[test]
    fn explicit_release_of_an_idle_session_is_immediate() {
        let mut machine = codex();
        held(&mut machine, 0);
        assert_eq!(
            machine.handle(release(ReleaseCause::ContinueInTerminal), 1_000),
            [
                HoldEffect::Unsubscribe,
                HoldEffect::Released {
                    cause: ReleaseCause::ContinueInTerminal,
                    receipts: Vec::new()
                }
            ]
        );

        let mut machine = claude();
        held(&mut machine, 0);
        assert_eq!(
            machine.handle(release(ReleaseCause::Command), 1_000),
            [HoldEffect::CloseStdin {
                kill_after_ms: 10_000
            }]
        );
        assert_eq!(
            machine.handle(HoldEvent::Detached, 2_000),
            [HoldEffect::Released {
                cause: ReleaseCause::Command,
                receipts: Vec::new()
            }]
        );
    }

    #[test]
    fn explicit_release_lists_live_work_then_stops_each_with_a_receipt() {
        let mut machine = claude();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        let request = ReleaseRequest::new(ReleaseCause::ContinueInTerminal, Some(7));
        assert_eq!(
            machine.handle(HoldEvent::ReleaseRequested { request }, 1_000),
            [HoldEffect::ConfirmRelease {
                request,
                live: busy()
            }]
        );
        // Input while confirming waits in Inline; the idle timer does nothing.
        assert!(
            machine
                .handle(
                    HoldEvent::AcquireRequested {
                        input: Some(input("late"))
                    },
                    2_000
                )
                .is_empty()
        );
        assert!(machine.handle(HoldEvent::Tick, 60 * MIN).is_empty());

        let effects = machine.handle(HoldEvent::ReleaseConfirmed, 60 * MIN);
        let actions = effects
            .iter()
            .map(|effect| match effect {
                HoldEffect::Step(step) => step.action,
                other => panic!("unexpected {other:?}"),
            })
            .collect::<Vec<_>>();
        assert_eq!(
            actions,
            [
                ReleaseAction::KeepQueuedPending,
                ReleaseAction::CancelInteraction,
                ReleaseAction::InterruptTurn,
                ReleaseAction::StopChild,
                ReleaseAction::StopBackgroundTask,
            ]
        );
        for (action, id) in [
            (ReleaseAction::KeepQueuedPending, "queued-1"),
            (ReleaseAction::CancelInteraction, "approval-1"),
            (ReleaseAction::InterruptTurn, "turn-1"),
            (ReleaseAction::StopChild, "child-1"),
        ] {
            assert!(
                machine
                    .handle(
                        HoldEvent::StepFinished {
                            action,
                            id: id.into(),
                            outcome: ReleaseStepOutcome::Done
                        },
                        60 * MIN + 1_000
                    )
                    .is_empty()
            );
        }
        assert_eq!(
            machine.handle(
                HoldEvent::StepFinished {
                    action: ReleaseAction::StopBackgroundTask,
                    id: "task-1".into(),
                    outcome: ReleaseStepOutcome::Failed {
                        reason: "stop_task failed".into()
                    }
                },
                60 * MIN + 2_000
            ),
            [HoldEffect::CloseStdin {
                kill_after_ms: 10_000
            }]
        );
        let effects = machine.handle(HoldEvent::Detached, 60 * MIN + 3_000);
        let [
            HoldEffect::Released { cause, receipts },
            HoldEffect::PendingNotDelivered { inputs },
        ] = effects.as_slice()
        else {
            panic!("unexpected {effects:?}");
        };
        assert_eq!(*cause, ReleaseCause::ContinueInTerminal);
        assert_eq!(inputs, &[input("late")]);
        assert_eq!(receipts.len(), 6);
        // Handoff leaves the wakeup to the next holder, with a receipt.
        assert_eq!(receipts[0].step.action, ReleaseAction::LeaveWakeup);
        assert!(
            receipts
                .iter()
                .any(|receipt| matches!(receipt.outcome, ReleaseStepOutcome::Failed { .. }))
        );
    }

    #[test]
    fn release_command_cancels_wakeups_and_steps_time_out() {
        let mut machine = codex();
        held(&mut machine, 0);
        machine.handle(
            HoldEvent::Activity {
                live: LiveWork {
                    wakeups: vec![LiveItem::new("wake-1", "later")],
                    background_tasks: vec![LiveItem::new("term-1", "dev server")],
                    ..LiveWork::default()
                },
            },
            0,
        );
        machine.handle(release(ReleaseCause::Command), 0);
        let effects = machine.handle(HoldEvent::ReleaseConfirmed, 0);
        assert!(effects.contains(&HoldEffect::Step(ReleaseStep {
            action: ReleaseAction::CancelWakeup,
            item: LiveItem::new("wake-1", "later")
        })));
        assert!(machine.handle(HoldEvent::Tick, 14_000).is_empty());
        let effects = machine.handle(HoldEvent::Tick, 15_000);
        assert_eq!(effects[0], HoldEffect::Unsubscribe);
        let HoldEffect::Released { receipts, .. } = &effects[1] else {
            panic!("unexpected {effects:?}");
        };
        assert!(
            receipts
                .iter()
                .all(|receipt| matches!(receipt.outcome, ReleaseStepOutcome::Failed { .. }))
        );
        assert!(matches!(machine.state(), HoldState::Unloading { .. }));
    }

    #[test]
    fn confirmation_can_be_cancelled_or_resolved_by_work_ending() {
        let mut machine = codex();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        machine.handle(release(ReleaseCause::Command), 0);
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("meanwhile")),
            },
            1,
        );
        assert_eq!(
            machine.handle(HoldEvent::ReleaseCancelled, 2),
            [HoldEffect::Deliver {
                inputs: vec![input("meanwhile")]
            }]
        );
        assert!(matches!(machine.state(), HoldState::Held { .. }));

        machine.handle(release(ReleaseCause::OpenInApp), 3);
        assert_eq!(
            machine.handle(
                HoldEvent::Activity {
                    live: LiveWork::default()
                },
                4
            ),
            [
                HoldEffect::Unsubscribe,
                HoldEffect::Released {
                    cause: ReleaseCause::OpenInApp,
                    receipts: Vec::new()
                }
            ]
        );
    }

    #[test]
    fn held_elsewhere_keeps_input_pending_probes_and_offers_it_back() {
        let mut machine = codex();
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("a")),
            },
            0,
        );
        let by = HeldBy {
            surface: ProviderSurface::Cli,
            detail: Some("already has a live local writer".into()),
        };
        assert_eq!(
            machine.handle(HoldEvent::AcquireConflict { by: by.clone() }, 0),
            [HoldEffect::ShowHeldElsewhere { by: by.clone() }]
        );
        assert_eq!(machine.held_elsewhere(), Some(&by));
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("b")),
            },
            1_000,
        );
        assert!(machine.handle(HoldEvent::Tick, 30_000).is_empty());
        assert_eq!(
            machine.handle(HoldEvent::Tick, 60_000),
            [HoldEffect::ProbeHolder]
        );
        assert!(
            machine
                .handle(HoldEvent::AcquireConflict { by: by.clone() }, 60_500)
                .is_empty()
        );
        assert_eq!(
            machine.handle(HoldEvent::ElsewhereFreed, 61_000),
            [HoldEffect::OfferPending {
                inputs: vec![input("a"), input("b")]
            }]
        );
        assert_eq!(machine.state(), &HoldState::Released);
    }

    #[test]
    fn no_probes_without_pending_input() {
        let mut machine = claude();
        machine.handle(HoldEvent::AcquireRequested { input: None }, 0);
        machine.handle(
            HoldEvent::AcquireConflict {
                by: HeldBy {
                    surface: ProviderSurface::Desktop,
                    detail: None,
                },
            },
            0,
        );
        assert!(machine.handle(HoldEvent::Tick, 10 * MIN).is_empty());
    }

    #[test]
    fn resume_while_held_elsewhere_tries_now_and_offers_waiting_input() {
        let mut machine = codex();
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("a")),
            },
            0,
        );
        machine.handle(
            HoldEvent::AcquireConflict {
                by: HeldBy {
                    surface: ProviderSurface::Desktop,
                    detail: None,
                },
            },
            0,
        );
        assert_eq!(
            machine.handle(HoldEvent::AcquireRequested { input: None }, 1),
            [HoldEffect::Acquire]
        );
        assert_eq!(
            machine.handle(HoldEvent::Acquired, 2),
            [HoldEffect::OfferPending {
                inputs: vec![input("a")]
            }]
        );
    }

    #[test]
    fn fork_here_moves_pending_input_to_the_fork() {
        let mut machine = claude();
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("a")),
            },
            0,
        );
        machine.handle(
            HoldEvent::AcquireConflict {
                by: HeldBy {
                    surface: ProviderSurface::Cli,
                    detail: None,
                },
            },
            0,
        );
        assert_eq!(
            machine.handle(HoldEvent::ForkHere, 1),
            [HoldEffect::Fork {
                pending: vec![input("a")]
            }]
        );
        assert_eq!(machine.state(), &HoldState::Released);
    }

    #[test]
    fn release_during_acquire_wins_and_a_late_acquire_is_let_go() {
        let mut machine = codex();
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("a")),
            },
            0,
        );
        assert_eq!(
            machine.handle(release(ReleaseCause::Command), 1),
            [
                HoldEffect::PendingNotDelivered {
                    inputs: vec![input("a")]
                },
                HoldEffect::Released {
                    cause: ReleaseCause::Command,
                    receipts: Vec::new()
                }
            ]
        );
        assert_eq!(
            machine.handle(HoldEvent::Acquired, 2),
            [
                HoldEffect::Unsubscribe,
                HoldEffect::Released {
                    cause: ReleaseCause::Idle,
                    receipts: Vec::new()
                }
            ]
        );
    }

    #[test]
    fn releasing_nothing_still_answers() {
        let mut machine = claude();
        assert_eq!(
            machine.handle(release(ReleaseCause::ContinueInTerminal), 0),
            [HoldEffect::Released {
                cause: ReleaseCause::ContinueInTerminal,
                receipts: Vec::new()
            }]
        );
    }

    #[test]
    fn a_dropped_connection_while_held_is_reported() {
        let mut machine = claude();
        held(&mut machine, 0);
        assert_eq!(machine.handle(HoldEvent::Detached, 1), [HoldEffect::Lost]);
        assert_eq!(machine.state(), &HoldState::Released);
    }

    #[test]
    fn direct_input_while_held_is_delivered() {
        let mut machine = codex();
        held(&mut machine, 0);
        assert_eq!(
            machine.handle(
                HoldEvent::AcquireRequested {
                    input: Some(input("next"))
                },
                5
            ),
            [HoldEffect::Deliver {
                inputs: vec![input("next")]
            }]
        );
    }

    #[test]
    fn state_round_trips_for_the_journal() {
        let mut machine = claude();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        machine.handle(release(ReleaseCause::Command), 0);
        let json = serde_json::to_string(&machine).unwrap();
        let back: HoldMachine = serde_json::from_str(&json).unwrap();
        assert_eq!(back, machine);
    }
}

//! Hold, release and acquire for one native session (spec §4.6).
//!
//! - **Hold** while the session works. When it is idle with no live work,
//!   Codex is unsubscribed and the app-server unloads the thread after the
//!   user's own `thread_unload_delay_secs`; Claude has no idle unload, so stdin
//!   is closed after an Inline idle window (1800 s by default).
//! - **The idle timer never releases live work** ([`LiveWork::is_idle`]).
//! - **Explicit release wins.** `/release`, "Continue in terminal" and "Open
//!   in app" stop Inline's admission at once; new input stays pending in
//!   Inline. With live work, the machine lists it for confirmation, then runs
//!   one step at a time, each waiting on its receipt. Queued input is
//!   confirmed kept or removed before the interrupt that could drain it.
//! - **Release is confirmed, not assumed.** A failed or unknown step fences
//!   the release and is reported; the owner retries or cancels. Nothing is
//!   released anyway. The session counts as released only when the harness
//!   confirms: Codex `thread/closed`, or the Claude process exiting. There is
//!   no timer for that and no shorter global timeout, and the shared Codex
//!   app-server is never killed.
//! - **Acquire** on direct input or `/resume`. A session held by another
//!   client keeps the input pending and shows "continue there, or Fork here";
//!   pending input runs once the session frees, if its sender still wants it.
//!
//! Pending inputs carry the operation they need. The runtime rechecks it
//! against the sender's current grants before delivering or offering them.
//!
//! The machine is pure: the runtime feeds [`HoldEvent`]s with the current
//! time and executes the returned [`HoldEffect`]s.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::permissions::Operation;
use crate::TurnId;
use crate::harness::{
    ChildRef, HeldBy, InputId, InteractionId, LiveWork, QueuedInput, ReleaseOutcome, Released,
    RunState, UserId,
};

/// Claude's idle window: Inline-chosen to match Codex's default unload delay,
/// tunable.
pub const CLAUDE_IDLE_WINDOW: Duration = Duration::from_secs(1_800);
/// Codex's own default for `thread_unload_delay_secs`, shown while waiting for
/// `thread/closed` when the user's config does not set it.
pub const CODEX_DEFAULT_UNLOAD_DELAY: Duration = Duration::from_secs(1_800);
/// How long the Claude process this bridge owns may take to exit after stdin
/// closes before it is killed.
pub const CLAUDE_EXIT_GRACE: Duration = Duration::from_secs(10);
/// How long a release step may go without a receipt before its outcome is
/// recorded as unknown, which fences the release.
pub const RELEASE_STEP_TIMEOUT: Duration = Duration::from_secs(15);
/// How often a session held elsewhere is probed while input waits for it.
pub const HELD_ELSEWHERE_PROBE_INTERVAL: Duration = Duration::from_secs(60);

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

/// How a held session is let go.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IdleRelease {
    /// Codex: unsubscribe when idle; the app-server unloads the thread after
    /// the user's own delay and reports `thread/closed`.
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

/// One stop or hand-over during an explicit release.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ReleaseStep {
    /// Take the entry out of the native queue and keep it pending in Inline.
    KeepQueuedPending {
        queued: QueuedInput,
    },
    /// Cancel the pending approval or question.
    CancelInteraction {
        interaction: InteractionId,
    },
    /// Codex `turn/interrupt`, Claude `interrupt`.
    InterruptTurn {
        turn: TurnId,
    },
    /// Through the parent: Claude `stop_task`, Codex
    /// `thread/backgroundTerminals/terminate` or sub-agent stop.
    StopChild {
        child: ChildRef,
    },
    CancelWakeup {
        wakeup: String,
    },
    /// Leave a scheduled wakeup to whoever takes the session; no native call.
    LeaveWakeup {
        wakeup: String,
    },
}

/// Release steps for `live`, in the order that keeps anything from
/// restarting: queued input leaves the native queue first (Claude runs its
/// queue after an interrupt), then interactions close, then the turn and
/// children stop, then wakeups.
pub fn release_steps(live: &LiveWork, wakeups: WakeupDisposition) -> Vec<ReleaseStep> {
    let queued = live
        .queued
        .iter()
        .map(|queued| ReleaseStep::KeepQueuedPending {
            queued: queued.clone(),
        });
    let interactions = live
        .interactions
        .iter()
        .map(|interaction| ReleaseStep::CancelInteraction {
            interaction: interaction.clone(),
        });
    let turn = live
        .turn
        .iter()
        .map(|turn| ReleaseStep::InterruptTurn { turn: turn.clone() });
    let children = live.children.iter().map(|child| ReleaseStep::StopChild {
        child: child.clone(),
    });
    let wakeup_steps = live.wakeups.iter().map(|wakeup| match wakeups {
        WakeupDisposition::LeaveForNextHolder => ReleaseStep::LeaveWakeup {
            wakeup: wakeup.clone(),
        },
        WakeupDisposition::Cancel => ReleaseStep::CancelWakeup {
            wakeup: wakeup.clone(),
        },
    });
    queued
        .chain(interactions)
        .chain(turn)
        .chain(children)
        .chain(wakeup_steps)
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ReleaseStepOutcome {
    Done,
    Failed {
        reason: String,
    },
    /// The harness may or may not have done it (a timeout or a lost reply).
    /// Treated like a failure: fenced until reconciled.
    Unknown {
        reason: String,
    },
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
    pub requested_by: Option<UserId>,
    pub wakeups: WakeupDisposition,
}

impl ReleaseRequest {
    /// Handoffs leave wakeups to the next client by default; `/release`
    /// cancels them. The confirmation can change it.
    pub fn new(cause: ReleaseCause, requested_by: Option<UserId>) -> Self {
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

/// Direct input waiting for the session, with its sender and the operation
/// it needs, so both can be rechecked before it runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingInput {
    pub id: InputId,
    pub sender: UserId,
    pub required: Operation,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DetachPhase {
    /// Codex: unsubscribed, waiting for `thread/closed`.
    AwaitingNativeClose,
    /// Claude: stdin closed, waiting for the process to exit.
    Closing {
        deadline_ms: u64,
    },
    Killing,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HoldState {
    Released,
    Acquiring {
        /// Delivered once acquired.
        pending: Vec<PendingInput>,
        /// Offered back to their senders once acquired.
        offer: Vec<PendingInput>,
        /// An explicit release requested while acquiring.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        release: Option<ReleaseRequest>,
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
        current: ReleaseStep,
        deadline_ms: u64,
        remaining: Vec<ReleaseStep>,
        receipts: Vec<ReleaseReceipt>,
        pending: Vec<PendingInput>,
        live: LiveWork,
        last_activity_ms: u64,
    },
    /// A step failed or its outcome is unknown. Admission stays stopped until
    /// the owner retries or cancels the release.
    ReleaseFenced {
        request: ReleaseRequest,
        failed: ReleaseReceipt,
        remaining: Vec<ReleaseStep>,
        receipts: Vec<ReleaseReceipt>,
        pending: Vec<PendingInput>,
        live: LiveWork,
        last_activity_ms: u64,
    },
    Detaching {
        request: ReleaseRequest,
        receipts: Vec<ReleaseReceipt>,
        pending: Vec<PendingInput>,
        phase: DetachPhase,
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
    /// The session's current [`LiveWork`] (`Session::live_work`).
    Activity {
        live: LiveWork,
    },
    Tick,
    ReleaseRequested {
        request: ReleaseRequest,
    },
    ReleaseConfirmed,
    ReleaseCancelled,
    /// Run the fenced step again.
    ReleaseRetry,
    StepFinished {
        step: ReleaseStep,
        outcome: ReleaseStepOutcome,
    },
    /// The connection ended: the Claude process exited, or the Codex
    /// app-server went away.
    Detached,
    /// The harness released native ownership: `Released { outcome:
    /// NativeReleased }`, or `RunState::Released` on the stream (Codex
    /// `thread/closed`). `Unsubscribed` is not this; see [`release_event`].
    NativeReleased,
    /// A probe found the session free.
    ElsewhereFreed,
    ForkHere,
}

/// The hold event for a contract release receipt. `Unsubscribed` means the
/// harness still owns the session ("releasing"), so it is no event at all;
/// only `NativeReleased` confirms and lets the handoff instruction post.
pub fn release_event(released: &Released) -> Option<HoldEvent> {
    match released.outcome {
        ReleaseOutcome::NativeReleased => Some(HoldEvent::NativeReleased),
        ReleaseOutcome::Unsubscribed => None,
    }
}

/// The hold event for a run state from the session stream.
pub fn run_state_event(state: &RunState) -> Option<HoldEvent> {
    match state {
        RunState::Released => Some(HoldEvent::NativeReleased),
        RunState::HeldElsewhere { by } => Some(HoldEvent::AcquireConflict { by: by.clone() }),
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HoldEffect {
    /// Codex: `thread/resume` and subscribe. Claude: spawn with `--resume`.
    Acquire,
    /// Deliver after rechecking each input's `required` operation.
    Deliver {
        inputs: Vec<PendingInput>,
    },
    /// The session freed or was acquired by `/resume`: ask each sender
    /// (still permitted) whether their pending input should run.
    OfferPending {
        inputs: Vec<PendingInput>,
    },
    /// Show "Active in terminal / app: continue there, or Fork here".
    ShowHeldElsewhere {
        by: HeldBy,
    },
    ProbeHolder,
    /// Admission stopped: show "releasing".
    ReleaseStarted {
        cause: ReleaseCause,
    },
    /// The release was cancelled; admission resumes.
    ReleaseAbandoned,
    /// List live work and ask to confirm the release.
    ConfirmRelease {
        request: ReleaseRequest,
        live: LiveWork,
    },
    Step(ReleaseStep),
    /// Report the failed or unknown step and offer retry or cancel.
    ReleaseFenced {
        failed: ReleaseReceipt,
        receipts: Vec<ReleaseReceipt>,
    },
    /// Codex: `Session::release` (unsubscribe). Its `Unsubscribed` receipt
    /// keeps the thread "releasing".
    Unsubscribe,
    /// Claude: close stdin, then kill after `kill_after_ms`.
    CloseStdin {
        kill_after_ms: u64,
    },
    /// Claude only: the process this bridge owns did not exit.
    Kill,
    /// The harness confirmed the session is free. Explicit causes post the
    /// receipts and the handoff instruction. Receipts with an unknown outcome
    /// stay fenced in the delivery ledger.
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

    /// Whether Inline admits input into the session right now.
    pub fn admits(&self) -> bool {
        matches!(self.state, HoldState::Held { .. })
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
            // Released.
            (S::Released, E::AcquireRequested { input }) => {
                effects.push(HoldEffect::Acquire);
                S::Acquiring {
                    pending: input.into_iter().collect(),
                    offer: Vec::new(),
                    release: None,
                }
            }
            (S::Released, E::ReleaseRequested { request }) => {
                effects.push(HoldEffect::Released {
                    cause: request.cause,
                    receipts: Vec::new(),
                });
                S::Released
            }
            // A late acquisition nobody wants any more is let go again.
            (S::Released, E::Acquired) => self.detach(
                ReleaseRequest::new(ReleaseCause::Idle, None),
                Vec::new(),
                Vec::new(),
                now,
                effects,
            ),

            // Acquiring.
            (
                S::Acquiring {
                    mut pending,
                    offer,
                    release,
                },
                E::AcquireRequested { input },
            ) => {
                pending.extend(input);
                S::Acquiring {
                    pending,
                    offer,
                    release,
                }
            }
            (
                S::Acquiring {
                    pending,
                    offer,
                    release: None,
                },
                E::Acquired,
            ) => {
                push_inputs(effects, HoldEffect::Deliver { inputs: pending });
                push_inputs(effects, HoldEffect::OfferPending { inputs: offer });
                S::Held {
                    last_activity_ms: now,
                    live: LiveWork::default(),
                }
            }
            (
                S::Acquiring {
                    mut pending,
                    offer,
                    release: Some(request),
                },
                E::Acquired,
            ) => {
                pending.extend(offer);
                self.detach(request, Vec::new(), pending, now, effects)
            }
            (
                S::Acquiring {
                    mut pending,
                    offer,
                    release,
                },
                E::AcquireConflict { by },
            ) => {
                pending.extend(offer);
                if let Some(request) = release {
                    // Another client already holds it; nothing of ours to let go.
                    effects.push(HoldEffect::Released {
                        cause: request.cause,
                        receipts: Vec::new(),
                    });
                    push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
                    return S::Released;
                }
                effects.push(HoldEffect::ShowHeldElsewhere { by: by.clone() });
                S::HeldElsewhere {
                    by,
                    pending,
                    next_probe_ms: now + millis(HELD_ELSEWHERE_PROBE_INTERVAL),
                }
            }
            (
                S::Acquiring {
                    pending,
                    offer,
                    release: None,
                },
                E::ReleaseRequested { request },
            ) if request.cause.is_explicit() => {
                effects.push(HoldEffect::ReleaseStarted {
                    cause: request.cause,
                });
                S::Acquiring {
                    pending,
                    offer,
                    release: Some(request),
                }
            }
            (
                S::Acquiring {
                    mut pending,
                    offer,
                    release,
                },
                E::Detached,
            ) => {
                pending.extend(offer);
                if let Some(request) = release {
                    effects.push(HoldEffect::Released {
                        cause: request.cause,
                        receipts: Vec::new(),
                    });
                }
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
                if live.is_idle()
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
            ) if request.cause.is_explicit() => {
                effects.push(HoldEffect::ReleaseStarted {
                    cause: request.cause,
                });
                if live.is_idle() {
                    return self.detach(request, Vec::new(), Vec::new(), now, effects);
                }
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
            (S::Held { .. }, E::Detached) => {
                effects.push(HoldEffect::Lost);
                S::Released
            }

            // Confirming: admission is stopped; only the answer, or the live
            // work ending by itself, moves on.
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
                if live.is_idle() {
                    return self.detach(request, Vec::new(), pending, now, effects);
                }
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
            (
                S::ConfirmingRelease {
                    live,
                    last_activity_ms,
                    pending,
                    ..
                },
                E::ReleaseRequested { request },
            ) if request.cause.is_explicit() => {
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
                    last_activity_ms,
                    pending,
                },
                E::ReleaseConfirmed,
            ) => {
                let steps = release_steps(&live, request.wakeups);
                self.next_step(
                    request,
                    steps,
                    Vec::new(),
                    pending,
                    live,
                    last_activity_ms,
                    now,
                    effects,
                )
            }
            (
                S::ConfirmingRelease {
                    live,
                    last_activity_ms,
                    pending,
                    ..
                },
                E::ReleaseCancelled,
            ) => resume_admission(live, last_activity_ms, pending, effects),
            (S::ConfirmingRelease { pending, .. }, E::Detached) => {
                effects.push(HoldEffect::Lost);
                push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
                S::Released
            }

            // Releasing: one step at a time.
            (
                S::Releasing {
                    request,
                    current,
                    deadline_ms,
                    remaining,
                    mut receipts,
                    pending,
                    live,
                    last_activity_ms,
                },
                E::StepFinished { step, outcome },
            ) => {
                if step != current {
                    return S::Releasing {
                        request,
                        current,
                        deadline_ms,
                        remaining,
                        receipts,
                        pending,
                        live,
                        last_activity_ms,
                    };
                }
                let receipt = ReleaseReceipt { step, outcome };
                if receipt.outcome != ReleaseStepOutcome::Done {
                    return fence(
                        request,
                        receipt,
                        remaining,
                        receipts,
                        pending,
                        live,
                        last_activity_ms,
                        effects,
                    );
                }
                receipts.push(receipt);
                self.next_step(
                    request,
                    remaining,
                    receipts,
                    pending,
                    live,
                    last_activity_ms,
                    now,
                    effects,
                )
            }
            (
                S::Releasing {
                    request,
                    current,
                    deadline_ms,
                    remaining,
                    receipts,
                    pending,
                    live,
                    last_activity_ms,
                },
                E::Tick,
            ) if now >= deadline_ms => fence(
                request,
                ReleaseReceipt {
                    step: current,
                    outcome: ReleaseStepOutcome::Unknown {
                        reason: "no receipt from the harness".to_string(),
                    },
                },
                remaining,
                receipts,
                pending,
                live,
                last_activity_ms,
                effects,
            ),
            (
                S::Releasing {
                    request,
                    current,
                    remaining,
                    receipts,
                    pending,
                    ..
                },
                E::Detached,
            ) => exited_mid_release(
                request,
                std::iter::once(current).chain(remaining).collect(),
                receipts,
                pending,
                effects,
            ),

            // Fenced.
            (
                S::ReleaseFenced {
                    request,
                    failed,
                    remaining,
                    receipts,
                    pending,
                    live,
                    last_activity_ms,
                },
                E::ReleaseRetry,
            ) => {
                effects.push(HoldEffect::Step(failed.step.clone()));
                S::Releasing {
                    request,
                    current: failed.step,
                    deadline_ms: now + millis(RELEASE_STEP_TIMEOUT),
                    remaining,
                    receipts,
                    pending,
                    live,
                    last_activity_ms,
                }
            }
            // A late receipt resolves the unknown step.
            (
                S::ReleaseFenced {
                    request,
                    failed,
                    remaining,
                    mut receipts,
                    pending,
                    live,
                    last_activity_ms,
                },
                E::StepFinished {
                    step,
                    outcome: ReleaseStepOutcome::Done,
                },
            ) if step == failed.step => {
                receipts.push(ReleaseReceipt {
                    step,
                    outcome: ReleaseStepOutcome::Done,
                });
                self.next_step(
                    request,
                    remaining,
                    receipts,
                    pending,
                    live,
                    last_activity_ms,
                    now,
                    effects,
                )
            }
            (
                S::ReleaseFenced {
                    live,
                    last_activity_ms,
                    pending,
                    ..
                },
                E::ReleaseCancelled,
            ) => resume_admission(live, last_activity_ms, pending, effects),
            (
                S::ReleaseFenced {
                    request,
                    failed,
                    remaining,
                    receipts,
                    pending,
                    ..
                },
                E::Detached,
            ) => exited_mid_release(
                request,
                std::iter::once(failed.step).chain(remaining).collect(),
                receipts,
                pending,
                effects,
            ),

            // Input and live-work updates while releasing or fenced.
            (
                S::Releasing {
                    request,
                    current,
                    deadline_ms,
                    remaining,
                    receipts,
                    mut pending,
                    mut live,
                    last_activity_ms,
                },
                event @ (E::AcquireRequested { .. } | E::Activity { .. }),
            ) => {
                absorb(event, &mut pending, &mut live);
                S::Releasing {
                    request,
                    current,
                    deadline_ms,
                    remaining,
                    receipts,
                    pending,
                    live,
                    last_activity_ms,
                }
            }
            (
                S::ReleaseFenced {
                    request,
                    failed,
                    remaining,
                    receipts,
                    mut pending,
                    mut live,
                    last_activity_ms,
                },
                event @ (E::AcquireRequested { .. } | E::Activity { .. }),
            ) => {
                absorb(event, &mut pending, &mut live);
                S::ReleaseFenced {
                    request,
                    failed,
                    remaining,
                    receipts,
                    pending,
                    live,
                    last_activity_ms,
                }
            }

            // Detaching: wait for the harness, never a timer.
            (
                S::Detaching {
                    request,
                    receipts,
                    mut pending,
                    phase,
                },
                E::AcquireRequested { input },
            ) => {
                if !request.cause.is_explicit() && phase == DetachPhase::AwaitingNativeClose {
                    // Idle Codex unsubscribe: the app-server still has the
                    // thread loaded, so resubscribing takes it back.
                    pending.extend(input);
                    effects.push(HoldEffect::Acquire);
                    return S::Acquiring {
                        pending,
                        offer: Vec::new(),
                        release: None,
                    };
                }
                pending.extend(input);
                S::Detaching {
                    request,
                    receipts,
                    pending,
                    phase,
                }
            }
            (
                S::Detaching {
                    request,
                    receipts,
                    pending,
                    phase: DetachPhase::Closing { deadline_ms },
                },
                E::Tick,
            ) if now >= deadline_ms => {
                effects.push(HoldEffect::Kill);
                S::Detaching {
                    request,
                    receipts,
                    pending,
                    phase: DetachPhase::Killing,
                }
            }
            // The harness's own confirmation, or the process exiting.
            (
                S::Detaching {
                    request,
                    receipts,
                    pending,
                    ..
                },
                E::NativeReleased | E::Detached,
            ) => {
                effects.push(HoldEffect::Released {
                    cause: request.cause,
                    receipts,
                });
                if !request.cause.is_explicit() && !pending.is_empty() {
                    // Input arrived while an idle Claude process was exiting.
                    effects.push(HoldEffect::Acquire);
                    return S::Acquiring {
                        pending,
                        offer: Vec::new(),
                        release: None,
                    };
                }
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
                    release: None,
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

    /// Emits the next step that needs the harness, or detaches when none is
    /// left. Leaving a wakeup needs no native call and is receipted at once.
    #[allow(clippy::too_many_arguments)]
    fn next_step(
        &self,
        request: ReleaseRequest,
        steps: Vec<ReleaseStep>,
        mut receipts: Vec<ReleaseReceipt>,
        pending: Vec<PendingInput>,
        live: LiveWork,
        last_activity_ms: u64,
        now: u64,
        effects: &mut Vec<HoldEffect>,
    ) -> HoldState {
        let mut steps = steps.into_iter();
        for step in steps.by_ref() {
            if matches!(step, ReleaseStep::LeaveWakeup { .. }) {
                receipts.push(ReleaseReceipt {
                    step,
                    outcome: ReleaseStepOutcome::Done,
                });
                continue;
            }
            effects.push(HoldEffect::Step(step.clone()));
            return HoldState::Releasing {
                request,
                current: step,
                deadline_ms: now + millis(RELEASE_STEP_TIMEOUT),
                remaining: steps.collect(),
                receipts,
                pending,
                live,
                last_activity_ms,
            };
        }
        self.detach(request, receipts, pending, now, effects)
    }

    /// Asks the harness to let the session go; [`HoldEffect::Released`]
    /// follows only its confirmation.
    fn detach(
        &self,
        request: ReleaseRequest,
        receipts: Vec<ReleaseReceipt>,
        pending: Vec<PendingInput>,
        now: u64,
        effects: &mut Vec<HoldEffect>,
    ) -> HoldState {
        let phase = match self.policy {
            IdleRelease::Unsubscribe { .. } => {
                effects.push(HoldEffect::Unsubscribe);
                DetachPhase::AwaitingNativeClose
            }
            IdleRelease::CloseStdin { exit_grace_ms, .. } => {
                effects.push(HoldEffect::CloseStdin {
                    kill_after_ms: exit_grace_ms,
                });
                DetachPhase::Closing {
                    deadline_ms: now.saturating_add(exit_grace_ms),
                }
            }
        };
        HoldState::Detaching {
            request,
            receipts,
            pending,
            phase,
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn fence(
    request: ReleaseRequest,
    failed: ReleaseReceipt,
    remaining: Vec<ReleaseStep>,
    receipts: Vec<ReleaseReceipt>,
    pending: Vec<PendingInput>,
    live: LiveWork,
    last_activity_ms: u64,
    effects: &mut Vec<HoldEffect>,
) -> HoldState {
    effects.push(HoldEffect::ReleaseFenced {
        failed: failed.clone(),
        receipts: receipts.clone(),
    });
    HoldState::ReleaseFenced {
        request,
        failed,
        remaining,
        receipts,
        pending,
        live,
        last_activity_ms,
    }
}

fn resume_admission(
    live: LiveWork,
    last_activity_ms: u64,
    pending: Vec<PendingInput>,
    effects: &mut Vec<HoldEffect>,
) -> HoldState {
    effects.push(HoldEffect::ReleaseAbandoned);
    push_inputs(effects, HoldEffect::Deliver { inputs: pending });
    HoldState::Held {
        last_activity_ms,
        live,
    }
}

/// The process exited mid-release: the session is free, but the unfinished
/// steps were never confirmed and stay unknown.
fn exited_mid_release(
    request: ReleaseRequest,
    unconfirmed: Vec<ReleaseStep>,
    mut receipts: Vec<ReleaseReceipt>,
    pending: Vec<PendingInput>,
    effects: &mut Vec<HoldEffect>,
) -> HoldState {
    receipts.extend(unconfirmed.into_iter().map(|step| ReleaseReceipt {
        step,
        outcome: ReleaseStepOutcome::Unknown {
            reason: "the session exited before this was confirmed".to_string(),
        },
    }));
    effects.push(HoldEffect::Lost);
    effects.push(HoldEffect::Released {
        cause: request.cause,
        receipts,
    });
    push_inputs(effects, HoldEffect::PendingNotDelivered { inputs: pending });
    HoldState::Released
}

fn absorb(event: HoldEvent, pending: &mut Vec<PendingInput>, live: &mut LiveWork) {
    match event {
        HoldEvent::AcquireRequested { input } => pending.extend(input),
        HoldEvent::Activity { live: next } => *live = next,
        _ => {}
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::harness::{ChildId, ChildKind, HeldSurface, QueueEntryId};

    const MIN: u64 = 60_000;

    fn codex() -> HoldMachine {
        HoldMachine::new(IdleRelease::codex(None))
    }

    fn claude() -> HoldMachine {
        HoldMachine::new(IdleRelease::claude(CLAUDE_IDLE_WINDOW))
    }

    fn input(id: &str) -> PendingInput {
        PendingInput {
            id: InputId::new(id).unwrap(),
            sender: UserId(8),
            required: Operation::Steer,
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
        assert!(machine.admits());
    }

    fn queued() -> QueuedInput {
        QueuedInput {
            entry: QueueEntryId::new("q-1").unwrap(),
            input: Some(InputId::new("in-q").unwrap()),
            preview: "and the docs".into(),
        }
    }

    fn child(id: &str, kind: ChildKind) -> ChildRef {
        ChildRef {
            id: ChildId::new(id).unwrap(),
            kind,
        }
    }

    fn busy() -> LiveWork {
        LiveWork {
            turn: Some(TurnId::new("turn-1").unwrap()),
            children: vec![
                child("explorer", ChildKind::Subagent),
                child("npm-test", ChildKind::BackgroundTask),
            ],
            interactions: vec![InteractionId::new("approval-1").unwrap()],
            queued: vec![queued()],
            wakeups: vec!["Check CI in 10 min".into()],
        }
    }

    fn release(cause: ReleaseCause) -> HoldEvent {
        HoldEvent::ReleaseRequested {
            request: ReleaseRequest::new(cause, Some(UserId(7))),
        }
    }

    fn step_of(effects: &[HoldEffect]) -> ReleaseStep {
        match effects {
            [HoldEffect::Step(step)] => step.clone(),
            other => panic!("expected one step, got {other:?}"),
        }
    }

    fn done(step: ReleaseStep) -> HoldEvent {
        HoldEvent::StepFinished {
            step,
            outcome: ReleaseStepOutcome::Done,
        }
    }

    #[test]
    fn only_native_release_confirms() {
        let key = crate::harness::SessionKey {
            provider: crate::ProviderId::new("codex").unwrap(),
            session: crate::ProviderSessionId::new("thr").unwrap(),
        };
        let released = |outcome| Released {
            key: key.clone(),
            outcome,
            cancelled_interactions: Vec::new(),
            pending_inputs: Vec::new(),
            stopped_children: Vec::new(),
        };
        assert_eq!(release_event(&released(ReleaseOutcome::Unsubscribed)), None);
        assert_eq!(
            release_event(&released(ReleaseOutcome::NativeReleased)),
            Some(HoldEvent::NativeReleased)
        );
        assert_eq!(run_state_event(&RunState::Releasing), None);
        assert_eq!(
            run_state_event(&RunState::Released),
            Some(HoldEvent::NativeReleased)
        );

        // An Unsubscribed receipt leaves the explicit release showing
        // "releasing": no handoff instruction yet.
        let mut machine = codex();
        held(&mut machine, 0);
        machine.handle(release(ReleaseCause::ContinueInTerminal), 1);
        assert!(release_event(&released(ReleaseOutcome::Unsubscribed)).is_none());
        assert!(matches!(machine.state(), HoldState::Detaching { .. }));
        assert_eq!(
            machine.handle(HoldEvent::NativeReleased, 2),
            [HoldEffect::Released {
                cause: ReleaseCause::ContinueInTerminal,
                receipts: Vec::new()
            }]
        );
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
    fn codex_idle_unsubscribe_waits_for_thread_closed_without_a_timer() {
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
            [HoldEffect::Unsubscribe]
        );
        // Unsubscribed is not released: no amount of time changes that.
        assert!(machine.handle(HoldEvent::Tick, 24 * 60 * MIN).is_empty());
        assert!(matches!(machine.state(), HoldState::Detaching { .. }));

        // Before thread/closed, direct input resubscribes.
        let mut resubscribed = machine.clone();
        assert_eq!(
            resubscribed.handle(
                HoldEvent::AcquireRequested {
                    input: Some(input("again"))
                },
                12 * MIN
            ),
            [HoldEffect::Acquire]
        );

        assert_eq!(
            machine.handle(HoldEvent::NativeReleased, 41 * MIN),
            [HoldEffect::Released {
                cause: ReleaseCause::Idle,
                receipts: Vec::new()
            }]
        );
        assert_eq!(machine.state(), &HoldState::Released);
    }

    #[test]
    fn explicit_codex_release_stops_admission_and_shows_releasing_until_closed() {
        let mut machine = codex();
        held(&mut machine, 0);
        assert_eq!(
            machine.handle(release(ReleaseCause::ContinueInTerminal), 1_000),
            [
                HoldEffect::ReleaseStarted {
                    cause: ReleaseCause::ContinueInTerminal
                },
                HoldEffect::Unsubscribe
            ]
        );
        assert!(!machine.admits());
        // Input waits in Inline; it never resubscribes an explicit release.
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
        assert_eq!(
            machine.handle(HoldEvent::NativeReleased, 61 * MIN),
            [
                HoldEffect::Released {
                    cause: ReleaseCause::ContinueInTerminal,
                    receipts: Vec::new()
                },
                HoldEffect::PendingNotDelivered {
                    inputs: vec![input("late")]
                }
            ]
        );
    }

    #[test]
    fn claude_closes_stdin_after_the_idle_window_and_waits_for_exit() {
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
        // Closing stdin is not a release: only exit or a native release is.
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
    fn input_during_an_idle_claude_exit_respawns_after_it() {
        let mut machine = claude();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Tick, 30 * MIN);
        assert!(
            machine
                .handle(
                    HoldEvent::AcquireRequested {
                        input: Some(input("next"))
                    },
                    30 * MIN + 1
                )
                .is_empty()
        );
        assert_eq!(
            machine.handle(HoldEvent::Detached, 30 * MIN + 2),
            [
                HoldEffect::Released {
                    cause: ReleaseCause::Idle,
                    receipts: Vec::new()
                },
                HoldEffect::Acquire
            ]
        );
        assert_eq!(
            machine.handle(HoldEvent::Acquired, 30 * MIN + 3),
            [HoldEffect::Deliver {
                inputs: vec![input("next")]
            }]
        );
    }

    #[test]
    fn the_idle_timer_never_releases_live_work() {
        for live in [
            LiveWork {
                turn: Some(TurnId::new("t").unwrap()),
                ..LiveWork::default()
            },
            LiveWork {
                children: vec![child("b", ChildKind::BackgroundTask)],
                ..LiveWork::default()
            },
            LiveWork {
                children: vec![child("c", ChildKind::Subagent)],
                ..LiveWork::default()
            },
            LiveWork {
                interactions: vec![InteractionId::new("i").unwrap()],
                ..LiveWork::default()
            },
            LiveWork {
                queued: vec![queued()],
                ..LiveWork::default()
            },
            LiveWork {
                wakeups: vec!["w".into()],
                ..LiveWork::default()
            },
        ] {
            for mut machine in [codex(), claude()] {
                held(&mut machine, 0);
                machine.handle(HoldEvent::Activity { live: live.clone() }, 0);
                assert!(machine.handle(HoldEvent::Tick, 24 * 60 * MIN).is_empty());
                assert!(machine.admits());
            }
        }
    }

    #[test]
    fn release_steps_run_in_order_each_after_its_receipt() {
        let mut machine = claude();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        let request = ReleaseRequest::new(ReleaseCause::ContinueInTerminal, Some(UserId(7)));
        assert_eq!(
            machine.handle(HoldEvent::ReleaseRequested { request }, 1_000),
            [
                HoldEffect::ReleaseStarted {
                    cause: ReleaseCause::ContinueInTerminal
                },
                HoldEffect::ConfirmRelease {
                    request,
                    live: busy()
                }
            ]
        );
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

        // Only the queue step goes out first; the interrupt that could drain
        // the queue waits for its receipt.
        let first = step_of(&machine.handle(HoldEvent::ReleaseConfirmed, 3_000));
        assert_eq!(first, ReleaseStep::KeepQueuedPending { queued: queued() });
        let second = step_of(&machine.handle(done(first), 4_000));
        assert!(matches!(second, ReleaseStep::CancelInteraction { .. }));
        let third = step_of(&machine.handle(done(second), 5_000));
        assert!(matches!(third, ReleaseStep::InterruptTurn { .. }));
        let fourth = step_of(&machine.handle(done(third), 6_000));
        let fifth = step_of(&machine.handle(done(fourth.clone()), 7_000));
        assert!(matches!(
            (&fourth, &fifth),
            (ReleaseStep::StopChild { .. }, ReleaseStep::StopChild { .. })
        ));
        // The handoff leaves the wakeup to the next holder without a call.
        assert_eq!(
            machine.handle(done(fifth), 8_000),
            [HoldEffect::CloseStdin {
                kill_after_ms: 10_000
            }]
        );
        let effects = machine.handle(HoldEvent::Detached, 9_000);
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
        assert!(
            receipts
                .iter()
                .all(|receipt| receipt.outcome == ReleaseStepOutcome::Done)
        );
        assert!(matches!(
            receipts.last().unwrap().step,
            ReleaseStep::LeaveWakeup { .. }
        ));
    }

    #[test]
    fn a_failed_queue_step_fences_the_release_and_never_interrupts() {
        let mut machine = codex();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        machine.handle(release(ReleaseCause::Command), 0);
        let first = step_of(&machine.handle(HoldEvent::ReleaseConfirmed, 0));
        let failed = ReleaseReceipt {
            step: first.clone(),
            outcome: ReleaseStepOutcome::Failed {
                reason: "thread/queue/delete failed".into(),
            },
        };
        assert_eq!(
            machine.handle(
                HoldEvent::StepFinished {
                    step: first.clone(),
                    outcome: failed.outcome.clone()
                },
                1_000
            ),
            [HoldEffect::ReleaseFenced {
                failed,
                receipts: Vec::new()
            }]
        );
        assert!(!machine.admits());
        // Fenced means fenced: no interrupt, no unsubscribe, however long.
        assert!(machine.handle(HoldEvent::Tick, 24 * 60 * MIN).is_empty());
        // Retrying re-runs exactly the failed step.
        assert_eq!(
            step_of(&machine.handle(HoldEvent::ReleaseRetry, 24 * 60 * MIN)),
            first
        );
        let next = step_of(&machine.handle(done(first), 24 * 60 * MIN + 1));
        assert!(matches!(next, ReleaseStep::CancelInteraction { .. }));
    }

    #[test]
    fn a_step_without_a_receipt_becomes_unknown_and_fenced() {
        let mut machine = codex();
        held(&mut machine, 0);
        machine.handle(
            HoldEvent::Activity {
                live: LiveWork {
                    children: vec![child("dev-server", ChildKind::BackgroundTask)],
                    wakeups: vec!["later".into()],
                    ..LiveWork::default()
                },
            },
            0,
        );
        machine.handle(release(ReleaseCause::Command), 0);
        let stop = step_of(&machine.handle(HoldEvent::ReleaseConfirmed, 0));
        assert!(machine.handle(HoldEvent::Tick, 14_000).is_empty());
        let effects = machine.handle(HoldEvent::Tick, 15_000);
        assert!(matches!(
            effects.as_slice(),
            [HoldEffect::ReleaseFenced {
                failed: ReleaseReceipt {
                    outcome: ReleaseStepOutcome::Unknown { .. },
                    ..
                },
                ..
            }]
        ));
        // A late success resolves it, and `/release` cancels the wakeup.
        let cancel_wakeup = step_of(&machine.handle(done(stop), 20_000));
        assert_eq!(
            cancel_wakeup,
            ReleaseStep::CancelWakeup {
                wakeup: "later".into()
            }
        );
        assert_eq!(
            machine.handle(done(cancel_wakeup), 21_000),
            [HoldEffect::Unsubscribe]
        );
        assert!(matches!(machine.state(), HoldState::Detaching { .. }));
    }

    #[test]
    fn stale_receipts_do_not_advance_the_release() {
        let mut machine = claude();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        machine.handle(release(ReleaseCause::Command), 0);
        machine.handle(HoldEvent::ReleaseConfirmed, 0);
        assert!(
            machine
                .handle(
                    done(ReleaseStep::InterruptTurn {
                        turn: TurnId::new("turn-1").unwrap()
                    }),
                    1
                )
                .is_empty()
        );
        assert!(matches!(
            machine.state(),
            HoldState::Releasing {
                current: ReleaseStep::KeepQueuedPending { .. },
                ..
            }
        ));
    }

    #[test]
    fn cancelling_a_confirmation_or_a_fenced_release_resumes_admission() {
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
            [
                HoldEffect::ReleaseAbandoned,
                HoldEffect::Deliver {
                    inputs: vec![input("meanwhile")]
                }
            ]
        );
        assert!(machine.admits());

        machine.handle(release(ReleaseCause::Command), 3);
        let first = step_of(&machine.handle(HoldEvent::ReleaseConfirmed, 3));
        machine.handle(
            HoldEvent::StepFinished {
                step: first,
                outcome: ReleaseStepOutcome::Failed { reason: "x".into() },
            },
            4,
        );
        assert_eq!(
            machine.handle(HoldEvent::ReleaseCancelled, 5),
            [HoldEffect::ReleaseAbandoned]
        );
        assert!(machine.admits());
    }

    #[test]
    fn work_ending_during_confirmation_detaches_without_steps() {
        let mut machine = codex();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        machine.handle(release(ReleaseCause::OpenInApp), 1);
        assert_eq!(
            machine.handle(
                HoldEvent::Activity {
                    live: LiveWork::default()
                },
                2
            ),
            [HoldEffect::Unsubscribe]
        );
    }

    #[test]
    fn exit_mid_release_reports_unconfirmed_steps_as_unknown() {
        let mut machine = claude();
        held(&mut machine, 0);
        machine.handle(HoldEvent::Activity { live: busy() }, 0);
        machine.handle(release(ReleaseCause::Command), 0);
        let first = step_of(&machine.handle(HoldEvent::ReleaseConfirmed, 0));
        machine.handle(done(first), 1);
        let effects = machine.handle(HoldEvent::Detached, 2);
        let [HoldEffect::Lost, HoldEffect::Released { receipts, .. }] = effects.as_slice() else {
            panic!("unexpected {effects:?}");
        };
        assert_eq!(receipts[0].outcome, ReleaseStepOutcome::Done);
        assert!(
            receipts[1..]
                .iter()
                .all(|receipt| matches!(receipt.outcome, ReleaseStepOutcome::Unknown { .. }))
        );
        assert_eq!(machine.state(), &HoldState::Released);
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
            surface: HeldSurface::Terminal,
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
                    surface: HeldSurface::DesktopApp,
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
                    surface: HeldSurface::DesktopApp,
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
                    surface: HeldSurface::Terminal,
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
    fn release_during_acquire_detaches_once_acquired_and_confirms_natively() {
        let mut machine = codex();
        machine.handle(
            HoldEvent::AcquireRequested {
                input: Some(input("a")),
            },
            0,
        );
        assert_eq!(
            machine.handle(release(ReleaseCause::Command), 1),
            [HoldEffect::ReleaseStarted {
                cause: ReleaseCause::Command
            }]
        );
        assert_eq!(
            machine.handle(HoldEvent::Acquired, 2),
            [HoldEffect::Unsubscribe]
        );
        assert_eq!(
            machine.handle(HoldEvent::NativeReleased, 3),
            [
                HoldEffect::Released {
                    cause: ReleaseCause::Command,
                    receipts: Vec::new()
                },
                HoldEffect::PendingNotDelivered {
                    inputs: vec![input("a")]
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
        machine.handle(HoldEvent::ReleaseConfirmed, 0);
        let json = serde_json::to_string(&machine).unwrap();
        let back: HoldMachine = serde_json::from_str(&json).unwrap();
        assert_eq!(back, machine);
    }
}

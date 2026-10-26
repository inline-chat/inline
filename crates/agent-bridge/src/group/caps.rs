//! Safety caps (spec §5.1 rule 6): large, surfaced and extendable, never
//! throttles.
//!
//! - A daily speak-gate budget per agent, visible to the owner, with one
//!   notice when reached and one tap to raise it.
//! - An agent-only loop cap per conversation: consecutive agent-authored
//!   messages since the last human message. Reaching it is surfaced to both
//!   owners; it is extendable in place and reset by any human message.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Speak-gate evaluations per agent per day before the owner is asked to
/// raise the budget. Large on purpose: a safety cap, not a throttle.
pub const DEFAULT_DAILY_SPEAK_GATE_BUDGET: u32 = 1_000;

/// Consecutive agent-only messages in one conversation before agent-addressed
/// input stops starting turns ("in the tens of hops").
pub const DEFAULT_LOOP_CAP_HOPS: u32 = 30;

/// A calendar day in the owner's local time, as days since the Unix epoch.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DayKey(pub i64);

impl DayKey {
    pub fn from_unix(unix_seconds: i64, utc_offset_seconds: i32) -> Self {
        Self((unix_seconds + i64::from(utc_offset_seconds)).div_euclid(86_400))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BudgetOutcome {
    Allowed {
        remaining: u32,
    },
    /// No evaluation today. `notify_owner` is set once per day, on the first
    /// refusal, so the owner sees one notice with a raise action.
    Exhausted {
        used: u32,
        allowance: u32,
        notify_owner: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DailySpeakGateBudget {
    /// The configured daily allowance (Agent Settings).
    limit: u32,
    day: Option<DayKey>,
    used: u32,
    /// Extra allowance granted today by the owner's raise action.
    raised: u32,
    notified: bool,
}

impl Default for DailySpeakGateBudget {
    fn default() -> Self {
        Self::new(DEFAULT_DAILY_SPEAK_GATE_BUDGET)
    }
}

impl DailySpeakGateBudget {
    pub fn new(limit: u32) -> Self {
        Self {
            limit,
            day: None,
            used: 0,
            raised: 0,
            notified: false,
        }
    }

    fn roll(&mut self, today: DayKey) {
        if self.day != Some(today) {
            self.day = Some(today);
            self.used = 0;
            self.raised = 0;
            self.notified = false;
        }
    }

    pub fn allowance(&self) -> u32 {
        self.limit.saturating_add(self.raised)
    }

    /// Used and allowed evaluations today, for the owner's view.
    pub fn status(&mut self, today: DayKey) -> (u32, u32) {
        self.roll(today);
        (self.used, self.allowance())
    }

    /// Spends one evaluation if today's allowance has room.
    pub fn try_consume(&mut self, today: DayKey) -> BudgetOutcome {
        self.roll(today);
        let allowance = self.allowance();
        if self.used < allowance {
            self.used += 1;
            return BudgetOutcome::Allowed {
                remaining: allowance - self.used,
            };
        }
        let notify_owner = !self.notified;
        self.notified = true;
        BudgetOutcome::Exhausted {
            used: self.used,
            allowance,
            notify_owner,
        }
    }

    /// The owner's one-tap raise: more allowance for the rest of today.
    pub fn raise_today(&mut self, today: DayKey, by: u32) {
        self.roll(today);
        self.raised = self.raised.saturating_add(by);
        self.notified = false;
    }

    pub fn set_limit(&mut self, limit: u32) {
        self.limit = limit;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LoopVerdict {
    Allowed {
        hops: u32,
    },
    /// Agent-addressed input stays passive context. `notify_owners` is set the
    /// first time the cap is hit since the last reset or extension.
    CapReached {
        hops: u32,
        limit: u32,
        notify_owners: bool,
    },
}

/// Agent-only hop counter for one conversation. Every message in the
/// conversation is recorded, including this agent's own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoopGuard {
    hops: u32,
    limit: u32,
    notified: bool,
}

impl LoopGuard {
    pub fn new(limit: u32) -> Self {
        Self {
            hops: 0,
            limit,
            notified: false,
        }
    }

    pub fn hops(&self) -> u32 {
        self.hops
    }

    pub fn limit(&self) -> u32 {
        self.limit
    }

    /// Records one message. Any human message resets the guard.
    pub fn record(&mut self, author_is_agent: bool, default_limit: u32) {
        if author_is_agent {
            self.hops = self.hops.saturating_add(1);
        } else {
            *self = Self::new(default_limit);
        }
    }

    /// Verdict for agent-addressed input after the latest message was recorded.
    pub fn verdict(&mut self) -> LoopVerdict {
        if self.hops <= self.limit {
            return LoopVerdict::Allowed { hops: self.hops };
        }
        let notify_owners = !self.notified;
        self.notified = true;
        LoopVerdict::CapReached {
            hops: self.hops,
            limit: self.limit,
            notify_owners,
        }
    }

    /// An owner's in-place extension: more agent-only hops from here.
    pub fn extend(&mut self, by: u32) {
        self.limit = self.hops.max(self.limit).saturating_add(by);
        self.notified = false;
    }
}

/// Loop guards keyed by conversation scope (the root thread of a subthread
/// tree, so delegation through subthreads shares one count). Scopes return to
/// the default on the next human message and are then dropped.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoopGuards {
    default_limit: u32,
    guards: BTreeMap<i64, LoopGuard>,
}

impl Default for LoopGuards {
    fn default() -> Self {
        Self::new(DEFAULT_LOOP_CAP_HOPS)
    }
}

impl LoopGuards {
    pub fn new(default_limit: u32) -> Self {
        Self {
            default_limit,
            guards: BTreeMap::new(),
        }
    }

    /// Records one message in `scope` and returns the verdict for it.
    pub fn record(&mut self, scope: i64, author_is_agent: bool) -> LoopVerdict {
        if !author_is_agent {
            self.guards.remove(&scope);
            return LoopVerdict::Allowed { hops: 0 };
        }
        let default_limit = self.default_limit;
        let guard = self
            .guards
            .entry(scope)
            .or_insert_with(|| LoopGuard::new(default_limit));
        guard.record(true, default_limit);
        guard.verdict()
    }

    pub fn extend(&mut self, scope: i64, by: u32) {
        let default_limit = self.default_limit;
        self.guards
            .entry(scope)
            .or_insert_with(|| LoopGuard::new(default_limit))
            .extend(by);
    }

    pub fn guard(&self, scope: i64) -> Option<&LoopGuard> {
        self.guards.get(&scope)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn day_keys_follow_the_owner_offset() {
        // 2026-10-26T23:30:00Z is already the 27th at UTC+1.
        let instant = 1_793_057_400;
        assert_eq!(DayKey::from_unix(instant, 0), DayKey(20_752));
        assert_eq!(DayKey::from_unix(instant, 3_600), DayKey(20_753));
        assert_eq!(DayKey::from_unix(-1, 0), DayKey(-1));
    }

    #[test]
    fn budget_allows_up_to_the_allowance_then_notifies_once() {
        let mut budget = DailySpeakGateBudget::new(2);
        let today = DayKey(1);
        assert_eq!(
            budget.try_consume(today),
            BudgetOutcome::Allowed { remaining: 1 }
        );
        assert_eq!(
            budget.try_consume(today),
            BudgetOutcome::Allowed { remaining: 0 }
        );
        assert_eq!(
            budget.try_consume(today),
            BudgetOutcome::Exhausted {
                used: 2,
                allowance: 2,
                notify_owner: true
            }
        );
        assert_eq!(
            budget.try_consume(today),
            BudgetOutcome::Exhausted {
                used: 2,
                allowance: 2,
                notify_owner: false
            }
        );
        assert_eq!(budget.status(today), (2, 2));
    }

    #[test]
    fn raising_adds_allowance_for_today_only() {
        let mut budget = DailySpeakGateBudget::new(1);
        let today = DayKey(1);
        budget.try_consume(today);
        assert!(matches!(
            budget.try_consume(today),
            BudgetOutcome::Exhausted { .. }
        ));
        budget.raise_today(today, 10);
        assert_eq!(
            budget.try_consume(today),
            BudgetOutcome::Allowed { remaining: 9 }
        );
        // A new day restores the configured limit and clears the raise.
        assert_eq!(budget.status(DayKey(2)), (0, 1));
    }

    #[test]
    fn default_budget_is_large() {
        let mut budget = DailySpeakGateBudget::default();
        assert_eq!(
            budget.status(DayKey(0)),
            (0, DEFAULT_DAILY_SPEAK_GATE_BUDGET)
        );
        assert!(DEFAULT_DAILY_SPEAK_GATE_BUDGET >= 100);
    }

    #[test]
    fn loop_cap_counts_agent_only_hops_and_resets_on_humans() {
        let mut guards = LoopGuards::new(3);
        for hop in 1..=3 {
            assert_eq!(guards.record(1, true), LoopVerdict::Allowed { hops: hop });
        }
        assert_eq!(
            guards.record(1, true),
            LoopVerdict::CapReached {
                hops: 4,
                limit: 3,
                notify_owners: true
            }
        );
        assert_eq!(
            guards.record(1, true),
            LoopVerdict::CapReached {
                hops: 5,
                limit: 3,
                notify_owners: false
            }
        );
        // Other conversations are independent.
        assert_eq!(guards.record(2, true), LoopVerdict::Allowed { hops: 1 });
        // Any human message resets and forgets the scope.
        assert_eq!(guards.record(1, false), LoopVerdict::Allowed { hops: 0 });
        assert!(guards.guard(1).is_none());
        assert_eq!(guards.record(1, true), LoopVerdict::Allowed { hops: 1 });
    }

    #[test]
    fn extending_in_place_allows_more_hops_and_notifies_again_later() {
        let mut guards = LoopGuards::new(2);
        guards.record(1, true);
        guards.record(1, true);
        assert!(matches!(
            guards.record(1, true),
            LoopVerdict::CapReached { hops: 3, .. }
        ));
        guards.extend(1, 2);
        assert_eq!(guards.guard(1).unwrap().limit(), 5);
        assert_eq!(guards.record(1, true), LoopVerdict::Allowed { hops: 4 });
        assert_eq!(guards.record(1, true), LoopVerdict::Allowed { hops: 5 });
        assert_eq!(
            guards.record(1, true),
            LoopVerdict::CapReached {
                hops: 6,
                limit: 5,
                notify_owners: true
            }
        );
        // The next human message brings back the default limit.
        guards.record(1, false);
        guards.record(1, true);
        assert_eq!(guards.guard(1).unwrap().limit(), 2);
    }

    #[test]
    fn default_loop_cap_is_in_the_tens() {
        assert!((10..100).contains(&DEFAULT_LOOP_CAP_HOPS));
    }
}

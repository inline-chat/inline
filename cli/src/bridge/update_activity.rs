//! One account process's admission boundary, shared with the update control socket.
use std::{
    collections::HashSet,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone)]
pub(crate) struct Activity(Arc<Mutex<State>>);
struct State {
    active: usize,
    busy: HashSet<u64>,
    last_work: Instant,
    requested: Option<Instant>,
    draining: bool,
}
pub(crate) struct Lease {
    activity: Activity,
    work: bool,
}
pub(crate) struct BusyKey {
    activity: Activity,
    id: u64,
}
static NEXT_KEY: AtomicU64 = AtomicU64::new(1);
static GLOBAL: OnceLock<Activity> = OnceLock::new();
pub(crate) fn global() -> &'static Activity {
    GLOBAL.get_or_init(Activity::new)
}

impl Activity {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(State {
            active: 0,
            busy: HashSet::new(),
            last_work: Instant::now(),
            requested: None,
            draining: false,
        })))
    }
    pub fn enter(&self) -> Option<Lease> {
        self.reserve(true)
    }
    pub fn maintenance(&self) -> Option<Lease> {
        self.reserve(false)
    }
    fn reserve(&self, work: bool) -> Option<Lease> {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if state.draining {
            return None;
        }
        state.active += 1;
        Some(Lease {
            activity: self.clone(),
            work,
        })
    }
    pub fn key(&self) -> BusyKey {
        BusyKey {
            activity: self.clone(),
            id: NEXT_KEY.fetch_add(1, Ordering::Relaxed),
        }
    }
    pub fn draining(&self) -> bool {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).draining
    }
    pub fn cancel(&self) {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        state.draining = false;
        state.requested = None;
    }
    pub fn prepare(&self) -> bool {
        self.prepare_with_quiet(Duration::from_secs(120))
    }
    fn prepare_with_quiet(&self, quiet: Duration) -> bool {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        let requested = *state.requested.get_or_insert(now);
        let quiet = if now.duration_since(requested) >= Duration::from_secs(24 * 60 * 60) {
            Duration::ZERO
        } else {
            quiet
        };
        if state.active == 0
            && state.busy.is_empty()
            && now.duration_since(state.last_work) >= quiet
        {
            state.draining = true;
        }
        state.draining
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        let mut state = self.activity.0.lock().unwrap_or_else(|e| e.into_inner());
        state.active = state.active.saturating_sub(1);
        if self.work {
            state.last_work = Instant::now();
        }
    }
}
impl BusyKey {
    pub fn set(&self, busy: bool) {
        let mut state = self.activity.0.lock().unwrap_or_else(|e| e.into_inner());
        let changed = if busy {
            state.busy.insert(self.id)
        } else {
            state.busy.remove(&self.id)
        };
        if changed {
            state.last_work = Instant::now();
        }
    }
}
impl Drop for BusyKey {
    fn drop(&mut self) {
        self.set(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn updater_housekeeping_does_not_prevent_a_quiet_handoff() {
        let activity = Activity::new();
        activity.0.lock().unwrap().last_work = Instant::now() - Duration::from_secs(180);
        for _ in 0..10 {
            drop(activity.maintenance().unwrap());
        }
        assert!(activity.prepare());
        assert!(activity.enter().is_none());
    }

    #[test]
    fn queued_work_and_questions_close_the_admission_race() {
        let activity = Activity::new();
        let queued = activity.enter().unwrap();
        assert!(!activity.prepare_with_quiet(Duration::ZERO));
        let question = activity.key();
        question.set(true);
        drop(queued);
        assert!(!activity.prepare_with_quiet(Duration::ZERO));
        question.set(false);
        assert!(activity.prepare_with_quiet(Duration::ZERO));
        assert!(activity.enter().is_none());
        activity.cancel();
        assert!(activity.enter().is_some());
    }
}

//! One account process's admission boundary, shared with the update control socket.
use std::{
    collections::HashSet,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

#[derive(Clone)]
pub(crate) struct Activity(Arc<Mutex<State>>);
struct State {
    active: usize,
    busy: HashSet<u64>,
    draining: bool,
}
pub(crate) struct Lease {
    activity: Activity,
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
            draining: false,
        })))
    }
    pub fn enter(&self) -> Option<Lease> {
        self.reserve()
    }
    pub fn maintenance(&self) -> Option<Lease> {
        self.reserve()
    }
    fn reserve(&self) -> Option<Lease> {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if state.draining {
            return None;
        }
        state.active += 1;
        Some(Lease {
            activity: self.clone(),
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
    }
    pub fn prepare(&self) -> bool {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        // The admission lock and the work leases provide the handoff boundary.
        // A time window also counts unrelated bot events as work, so an idle
        // bridge could otherwise wait indefinitely on its own traffic.
        if state.active == 0 && state.busy.is_empty() {
            state.draining = true;
        }
        state.draining
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        let mut state = self.activity.0.lock().unwrap_or_else(|e| e.into_inner());
        state.active = state.active.saturating_sub(1);
    }
}
impl BusyKey {
    pub fn set(&self, busy: bool) {
        let mut state = self.activity.0.lock().unwrap_or_else(|e| e.into_inner());
        if busy {
            state.busy.insert(self.id);
        } else {
            state.busy.remove(&self.id);
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
    fn finished_deliveries_and_housekeeping_do_not_delay_an_idle_handoff() {
        let activity = Activity::new();
        for _ in 0..10 {
            drop(activity.enter().unwrap());
            drop(activity.maintenance().unwrap());
        }
        assert!(activity.prepare());
        assert!(activity.enter().is_none());
    }

    #[test]
    fn queued_work_and_questions_close_the_admission_race() {
        let activity = Activity::new();
        let queued = activity.enter().unwrap();
        assert!(!activity.prepare());
        let question = activity.key();
        question.set(true);
        drop(queued);
        assert!(!activity.prepare());
        question.set(false);
        assert!(activity.prepare());
        assert!(activity.enter().is_none());
        activity.cancel();
        assert!(activity.enter().is_some());
    }
}

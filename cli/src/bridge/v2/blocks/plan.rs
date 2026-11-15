//! Claude `TodoWrite`, Codex `update_plan`: the task list.
//!
//! Claude's desktop app pins it as an untitled card under the latest message
//! while the turn runs (a spinner on the running step, a dashed circle on
//! pending ones, a check on done ones) and updates it in place. Here it is a
//! standalone `steps` block at the bottom of the live progress message,
//! under the latest prose and activity rows, rewritten on every plan change.
//! Once the turn ends it stays in the finished message, compact.

use inline_agent_bridge::{PlanStep, PlanStepStatus};

use super::clip;
use crate::bridge::v2::doc::{DocBuilder, Status};

/// Step text a finished turn keeps.
const COMPACT_STEP_CHARS: usize = 120;

pub(crate) fn status(status: PlanStepStatus) -> Status {
    match status {
        PlanStepStatus::Completed => Status::Done,
        PlanStepStatus::InProgress => Status::Running,
        PlanStepStatus::Pending => Status::Pending,
    }
}

/// The plan's steps as one untitled `steps` block; `compact` once the turn
/// ended (each step on one short line).
pub(crate) fn pinned(builder: &mut DocBuilder, steps: &[PlanStep], compact: bool) {
    let steps: Vec<(String, Status)> = steps
        .iter()
        .filter(|step| !step.text.trim().is_empty())
        .map(|step| {
            let text = if compact {
                clip(&step.text, COMPACT_STEP_CHARS)
            } else {
                step.text.trim().to_owned()
            };
            (text, status(step.status))
        })
        .collect();
    if !steps.is_empty() {
        builder.steps(&steps);
    }
}

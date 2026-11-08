//! The lead session in the owner's DM and its task subthreads.
//!
//! The DM keeps one long-lived session, the lead. It starts tasks in
//! subthreads of the DM (`spawn_thread`); each task is an ordinary work with
//! its own native session, connected to the lead's as a delegation, which
//! the owner can also talk to directly. Like Codex's `send_input`, steering
//! a task is what typing in its subthread does: it starts a turn, or steers
//! the running one. Like Codex's sub-agent notifications, a task's result
//! reaches the lead without starting a turn: it travels with the lead's next
//! input (the owner's next message, or a steer of its running turn), and
//! survives a restart until the lead's harness takes it. The owner already
//! sees the result in the task's subthread and on the lead's card.

use inline_agent_bridge::HostToolResult;
use inline_agent_bridge::TurnOutcome;
use tokio::sync::oneshot;
use uuid::Uuid;

/// A task's status, on its card and in `list_tasks`, while work its lead
/// gave it runs. Otherwise the status is how its last directed turn ended.
pub(crate) const DIRECTED: &str = "running";
/// Running tasks one lead may have at once.
pub(crate) const MAX_RUNNING_TASKS: usize = 5;
/// The part of a task's answer its report carries; the full answer stays in
/// the subthread.
const MAX_REPORT_ANSWER_CHARS: usize = 6_000;

/// A lead tool call, answered by the runtime, which owns every work.
pub(crate) enum LeadRequest {
    Spawn {
        /// The chat of the work that called the tool.
        caller: i64,
        task: SpawnTask,
        reply: oneshot::Sender<HostToolResult>,
    },
    Send {
        caller: i64,
        target: i64,
        text: String,
        mode: SendMode,
        interrupt: bool,
        call_id: String,
        reply: oneshot::Sender<HostToolResult>,
    },
    Stop {
        caller: i64,
        target: i64,
        reply: oneshot::Sender<HostToolResult>,
    },
    List {
        caller: i64,
        reply: oneshot::Sender<HostToolResult>,
    },
    /// Answered when a task the lead directed finishes; the tool gives up
    /// on its own after a few seconds.
    Wait {
        caller: i64,
        /// Tasks to wait on; empty is any running task.
        targets: Vec<i64>,
        reply: oneshot::Sender<HostToolResult>,
    },
    /// A work outside the DM tells the owner there; the lead sees it too.
    NotifyOwner {
        caller: i64,
        text: String,
        call_id: String,
        reply: oneshot::Sender<HostToolResult>,
    },
    /// A task's turn ended (from its work, not a tool).
    Report(TaskReport),
}

/// How `send_to_thread` delivers, after Codex's `send_input` / `followup_task`
/// / queue-only `send_message` and OpenClaw's `sessions_send` modes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SendMode {
    /// Like a message typed in the thread: a new turn, or a steer of the
    /// running one.
    Steer,
    /// After the running turn ends, as `/queue` does.
    Queue,
    /// Context for the task's next turn, without starting one.
    Note,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SpawnTask {
    pub title: String,
    pub brief: String,
    pub model: Option<String>,
    pub reasoning: Option<String>,
    /// A folder id from the agent's projects, or No project.
    pub project: Option<String>,
    /// Start from a fork of the lead's session instead of the brief alone.
    pub fork: bool,
    pub call_id: String,
}

#[derive(Clone, Debug)]
pub(crate) struct TaskReport {
    pub child_chat_id: i64,
    /// The native turn, so a replayed report is kept once.
    pub turn: String,
    pub outcome: TurnOutcome,
    pub answer: Option<String>,
    /// The lead directed the turn; otherwise the owner worked with the task
    /// directly and the lead gets only a note.
    pub directed: bool,
}

/// How an owner-driven note starts, so a newer one replaces it.
pub(crate) const OWNER_NOTE_PREFIX: &str = "Task note: ";

/// The lead's note that its owner worked with a task directly.
pub(crate) fn note_text(title: &str, child_chat_id: i64, outcome: TurnOutcome) -> String {
    format!(
        "{OWNER_NOTE_PREFIX}your owner worked with task \"{title}\" (inline://chat?id={child_chat_id}) directly; its latest turn {}. Read the thread if you need what was said.",
        status_word(outcome)
    )
}

/// One word for how a task's turn ended, for its card and its lead.
pub(crate) fn status_word(outcome: TurnOutcome) -> &'static str {
    match outcome {
        TurnOutcome::Completed => "completed",
        TurnOutcome::Interrupted => "stopped",
        TurnOutcome::TokenLimit | TurnOutcome::TurnLimit => "stopped at a limit",
        TurnOutcome::AuthenticationRequired => "needs sign-in",
        TurnOutcome::Failed | TurnOutcome::ConnectionLost => "failed",
    }
}

/// One report's identity: its task, turn and answer, so a replayed report
/// is kept once even where a harness reuses turn IDs.
pub(crate) fn report_event_id(
    bot_user_id: i64,
    child_chat_id: i64,
    turn: &str,
    answer: &str,
) -> String {
    Uuid::new_v5(
        &Uuid::NAMESPACE_OID,
        format!("inline:lead-report:{bot_user_id}:{child_chat_id}:{turn}:{answer}").as_bytes(),
    )
    .to_string()
}

/// What the lead reads when a task's turn ends. Titles and answers are the
/// task's own words, so they are marked as a report rather than the owner's.
pub(crate) fn report_text(title: &str, child_chat_id: i64, report: &TaskReport) -> String {
    let mut text = format!(
        "Task update (from your task subthread, not a message from your owner)\n\
         Task: {title}\n\
         Thread: inline://chat?id={child_chat_id}\n\
         Status: {}",
        status_word(report.outcome)
    );
    match report
        .answer
        .as_deref()
        .map(str::trim)
        .filter(|answer| !answer.is_empty())
    {
        Some(answer) => {
            text.push_str("\nFinal answer:\n");
            let mut chars = answer.chars();
            let shown: String = chars.by_ref().take(MAX_REPORT_ANSWER_CHARS).collect();
            text.push_str(&shown);
            if chars.next().is_some() {
                text.push_str("\n[cut; the full answer is in the task's thread]");
            }
        }
        None => text.push_str("\nFinal answer: none"),
    }
    text
}

/// The reports an input carries, as context for the lead.
pub(crate) fn batch_text(reports: &[&str]) -> String {
    if reports.len() == 1 {
        return reports[0].to_owned();
    }
    let mut text = format!("{} task updates since your last turn.", reports.len());
    for report in reports {
        text.push_str("\n\n");
        text.push_str(report);
    }
    text
}

/// The lead's card in the DM for one task.
pub(crate) fn card_text(agent_name: &str, title: &str, child_chat_id: i64, status: &str) -> String {
    let title: String = title
        .chars()
        .filter(|character| !matches!(character, '[' | ']'))
        .collect();
    format!("{agent_name} started [{title}](inline://chat?id={child_chat_id}).\n\nStatus: {status}")
}

/// The trusted note a task's first input carries.
pub(crate) const TASK_INSTRUCTIONS: &str = "You are working on a task that your lead session in your \
owner's DM started in this subthread. Work here; your owner may also talk to you here directly. \
When you finish, end with a concise final answer: it is shown here and reported to your lead.";

#[cfg(test)]
mod tests {
    use super::*;

    fn report(outcome: TurnOutcome, answer: Option<&str>) -> TaskReport {
        TaskReport {
            child_chat_id: 5,
            turn: "t1".to_owned(),
            outcome,
            answer: answer.map(str::to_owned),
            directed: true,
        }
    }

    #[test]
    fn a_report_names_the_task_status_and_answer() {
        let text = report_text(
            "Fix CI",
            5,
            &report(TurnOutcome::Completed, Some("All green.")),
        );
        assert!(text.contains("not a message from your owner"));
        assert!(text.contains("Task: Fix CI"));
        assert!(text.contains("inline://chat?id=5"));
        assert!(text.contains("Status: completed"));
        assert!(text.ends_with("All green."));
        let failed = report_text("Fix CI", 5, &report(TurnOutcome::Failed, None));
        assert!(failed.contains("Status: failed"));
        assert!(failed.contains("Final answer: none"));
    }

    #[test]
    fn an_owner_note_names_the_task_without_its_answer() {
        let note = note_text("Fix CI", 5, TurnOutcome::Completed);
        assert!(note.starts_with(OWNER_NOTE_PREFIX));
        assert!(note.contains("inline://chat?id=5") && note.contains("completed"));
    }

    #[test]
    fn a_long_answer_is_cut_and_points_to_the_thread() {
        let long = "x".repeat(MAX_REPORT_ANSWER_CHARS + 10);
        let text = report_text("T", 5, &report(TurnOutcome::Completed, Some(&long)));
        assert!(text.contains("the full answer is in the task's thread"));
        assert!(text.len() < long.len() + 300);
    }

    #[test]
    fn report_ids_are_stable_per_turn_and_batches_combine() {
        assert_eq!(
            report_event_id(1, 5, "t1", "a"),
            report_event_id(1, 5, "t1", "a")
        );
        assert_ne!(
            report_event_id(1, 5, "t1", "a"),
            report_event_id(1, 5, "t2", "a")
        );
        assert_ne!(
            report_event_id(1, 5, "turn", "a"),
            report_event_id(1, 5, "turn", "b")
        );
        assert_eq!(batch_text(&["one"]), "one");
        let both = batch_text(&["one", "two"]);
        assert!(both.starts_with("2 task updates since your last turn"));
        assert!(both.contains("one") && both.contains("two"));
    }

    #[test]
    fn card_links_the_task_and_keeps_its_title_inside_the_link() {
        let text = card_text("Claude", "Fix [CI]", 5, "running");
        assert_eq!(
            text,
            "Claude started [Fix CI](inline://chat?id=5).\n\nStatus: running"
        );
    }
}

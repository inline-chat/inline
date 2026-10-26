//! Claude Code on the bridge v2 session contract (spec §4.1, §4.2).
//!
//! Inline spawns the user's own `claude` per session and speaks stream-json.
//! Every native frame lands in the session stream; approvals offer Claude's
//! own choices (allow, each suggested permission update, deny with a
//! message); AskUserQuestion is a question form.

mod delivery;
mod mapper;
mod session;

pub use delivery::{INLINE_CHANNEL, OpPlan, op_plan, origin, user_message};
pub use mapper::{ALLOW, AnswerPlan, ClaudeMapper, DENY, RequestMapped};
pub use session::{
    ClaudeHarness, ClaudeHarnessConfig, ClaudeSession, availability, parse_permission_modes,
};

use inline_agent_bridge::harness::SetupReason;

use crate::version::ClaudeVersion;

/// The oldest CLI the core runs on: the oldest version in the conformance
/// matrix (spec §4.3). Raised when CI drops a version.
pub const CORE_FLOOR: ClaudeVersion = ClaudeVersion::new(2, 0, 32);

/// A typed Claude startup failure as a setup state with its fix.
pub fn setup_reason(reason: &str, message: &str) -> SetupReason {
    match reason {
        "cli_version_too_old" => SetupReason::UpdateRuntime {
            min_version: "the minimum Anthropic requires".into(),
            found: None,
        },
        "cwd_unavailable" => SetupReason::FolderUnavailable {
            path: String::new(),
        },
        "gateway_signin_required" | "org_config_refused" => SetupReason::SignIn,
        _ => SetupReason::Harness {
            code: reason.to_string(),
            message: message.to_string(),
        },
    }
}

#[cfg(test)]
mod fixture_tests;

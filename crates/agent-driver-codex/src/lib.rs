//! Direct Codex app-server driver for Inline's local agent bridge.

mod driver;
mod peer;
mod process;
mod protocol;

pub use driver::CodexAppServerDriver;
pub use peer::{CodexPeer, IncomingMessage, PeerError, PeerResult};
pub use process::{
    CodexLaunchConfig, CodexLaunchError, CodexProcessStatus, CodexVersionProbe, RedactedStderrTail,
    SpawnedCodexDriver, minimum_codex_version, parse_codex_version, probe_codex_version,
    should_scrub_codex_environment_name, spawn_codex_driver,
};
pub use protocol::{
    ClientInfo, CodexNotification, CompactThreadParams, DynamicToolSpec, InitializeParams,
    InterruptTurnParams, ProtocolError, ResumeThreadParams, StartThreadParams, StartTurnParams,
    SteerTurnParams, UserInput, approval_result, normalize_notification,
    normalize_question_request, normalize_server_request, provider_session_id_from_response,
    question_result, turn_id_from_response, unsupported_notification_diagnostic,
};

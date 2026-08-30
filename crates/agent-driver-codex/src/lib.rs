//! Direct Codex app-server driver for Inline's local agent bridge.

mod driver;
mod peer;
mod process;
mod protocol;
mod runtime_discovery;
mod session_catalog;
mod session_connection;
mod session_wire;

pub(crate) const INLINE_CLIENT_MESSAGE_ID_PREFIX: &str = "inline-agent-bridge:v1:";

pub use driver::CodexAppServerDriver;
pub use peer::{CodexPeer, IncomingMessage, PeerError, PeerResult};
pub use process::{
    CodexAppServerTransport, CodexDriverWriter, CodexLaunchConfig, CodexLaunchError,
    CodexProcessStatus, CodexVersionPolicy, CodexVersionProbe, RedactedStderrTail,
    SpawnedCodexDriver, is_certified_codex_version, latest_certified_codex_version,
    minimum_codex_version, parse_codex_version, probe_codex_version,
    should_scrub_codex_environment_name, spawn_codex_driver,
};
pub use protocol::{
    ClientInfo, CodexNotification, CompactThreadParams, DynamicToolSpec, InitializeParams,
    InterruptTurnParams, ProtocolError, ResumeThreadParams, StartThreadParams, StartTurnParams,
    SteerTurnParams, UserInput, approval_result, normalize_notification,
    normalize_question_request, normalize_server_request, provider_session_id_from_response,
    question_result, turn_id_from_response, unsupported_notification_diagnostic,
};
pub use runtime_discovery::{
    CodexRuntime, CodexRuntimeAttempt, CodexRuntimeCapabilities, CodexRuntimeDiscoveryConfig,
    CodexRuntimeDiscoveryError, CodexRuntimeFailure, CodexRuntimeSource, discover_codex_runtime,
    discover_codex_turn_runtime, discover_codex_turn_runtime_in_paths,
};
pub use session_catalog::{CodexRpc, CodexRpcFuture, CodexSessionCatalog, CodexUnsubscribeOutcome};
pub use session_connection::CodexSessionConnection;

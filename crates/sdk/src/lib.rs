//! Thin Rust SDK for Inline.
//!
//! This crate contains the reusable pieces for API calls, uploads, client
//! metadata, and the realtime RPC transport. It deliberately stays lower-level
//! than the stateful `inline-client` crate: callers own cache and sync
//! policy here.
//!
//! The SDK follows normal Rust library logging practice: it emits diagnostics
//! through the `log` facade and never initializes a logger. Parent applications
//! decide whether to install `env_logger`, `tracing-log`, a platform logger, or
//! no logger at all. SDK logs avoid bearer tokens, auth challenges, request and
//! response bodies, local file paths, URL query strings, message text, and
//! attachment contents. Public `Debug` implementations on token-bearing SDK
//! types, URL-bearing builders/errors, and local-file upload inputs redact
//! secret fields, credentials, query strings, and local paths for the same
//! reason.
//!
//! Public error enums are `#[non_exhaustive]` so the SDK can add more precise
//! API and transport failures without a breaking release. Match specific
//! variants when useful and keep a fallback arm for future variants.
//!
//! ```no_run
//! use inline_sdk::{ApiClient, ClientIdentity};
//!
//! # async fn example() -> Result<(), Box<dyn std::error::Error>> {
//! let api = ApiClient::builder("https://api.inline.chat/v1")
//!     .identity(ClientIdentity::try_new("my-agent", "0.1.0")?)
//!     .build()?;
//! # let _ = api;
//! # Ok(())
//! # }
//! ```

#![warn(missing_docs)]
#![forbid(unsafe_code)]

pub mod api;
pub mod client_info;
pub mod realtime;

pub use api::{
    ApiClient, ApiClientBuilder, ApiError, CreateLinearIssueInput, CreateLinearIssueResult,
    CreateNotionTaskInput, CreateNotionTaskResult, CreatePrivateChatResult, DEFAULT_API_TIMEOUT,
    PeerId, ReadMessagesInput, ReadMessagesResult, SendCodeResult, UploadFileBytesInput,
    UploadFileInput, UploadFileResult, UploadFileType, UploadFileTypeParseError,
    UploadVideoMetadata, VerifyCodeResult,
};
pub use client_info::{AuthMetadata, ClientIdentity, ClientIdentityError};
pub use inline_protocol::proto;
pub use realtime::{
    DEFAULT_CONNECT_TIMEOUT, DEFAULT_HEARTBEAT_INTERVAL, DEFAULT_HEARTBEAT_TIMEOUT,
    DEFAULT_RPC_TIMEOUT, DEFAULT_SESSION_COMMAND_CAPACITY, DEFAULT_SESSION_EVENT_CAPACITY,
    DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS, RealtimeClient, RealtimeClientBuilder, RealtimeError,
    RealtimeEvent, RealtimeEventReceiver, RealtimeSession, RpcRequest,
};

/// Convenient imports for common SDK consumers.
pub mod prelude {
    pub use crate::{
        ApiClient, ApiClientBuilder, ApiError, AuthMetadata, ClientIdentity, ClientIdentityError,
        CreateLinearIssueInput, CreateLinearIssueResult, CreateNotionTaskInput,
        CreateNotionTaskResult, CreatePrivateChatResult, DEFAULT_API_TIMEOUT,
        DEFAULT_CONNECT_TIMEOUT, DEFAULT_HEARTBEAT_INTERVAL, DEFAULT_HEARTBEAT_TIMEOUT,
        DEFAULT_RPC_TIMEOUT, DEFAULT_SESSION_COMMAND_CAPACITY, DEFAULT_SESSION_EVENT_CAPACITY,
        DEFAULT_SESSION_MAX_IN_FLIGHT_RPCS, PeerId, ReadMessagesInput, ReadMessagesResult,
        RealtimeClient, RealtimeClientBuilder, RealtimeError, RealtimeEvent, RealtimeEventReceiver,
        RealtimeSession, RpcRequest, SendCodeResult, UploadFileBytesInput, UploadFileInput,
        UploadFileResult, UploadFileType, UploadFileTypeParseError, UploadVideoMetadata,
        VerifyCodeResult, proto,
    };
}

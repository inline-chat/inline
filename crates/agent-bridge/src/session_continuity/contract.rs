//! Object-safe catalog and attachment boundaries for provider sessions.
//!
//! `AgentSessionConnection` observes work started on any provider surface. It
//! does not replace [`crate::AgentDriver`]: the existing driver remains the
//! sole execution and control-resolution path. A bridge hub validates the
//! attachment/controller context from session control events before routing an
//! approval or question to that driver.

use std::fmt;
use std::pin::Pin;

use futures_util::Stream;

use crate::{DriverFuture, DriverResult, WorkspaceId};

use super::{
    AttachSessionRequest, DetachSessionRequest, ProviderHealth, RenameSessionRequest,
    SessionCapabilities, SessionControllerEpoch, SessionEvent, SessionPage, SessionProjectionAck,
    SessionQuery, SessionReadRequest, SessionSnapshot, SessionStreamPosition,
};

pub type SessionEventStream =
    Pin<Box<dyn Stream<Item = DriverResult<SessionEvent>> + Send + 'static>>;

pub struct AttachedSession {
    pub snapshot: SessionSnapshot,
    pub position: SessionStreamPosition,
    pub controller_epoch: Option<SessionControllerEpoch>,
    pub events: SessionEventStream,
}

impl fmt::Debug for AttachedSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AttachedSession")
            .field("snapshot_items", &self.snapshot.items().len())
            .field("position", &self.position)
            .field("controller_epoch", &self.controller_epoch)
            .field("events", &"<session event stream>")
            .finish()
    }
}

pub trait AgentSessionCatalog: Send + Sync {
    fn session_capabilities(&self) -> SessionCapabilities;

    fn provider_health<'a>(
        &'a self,
        workspace_id: &'a WorkspaceId,
    ) -> DriverFuture<'a, ProviderHealth>;

    fn list_sessions<'a>(&'a self, query: SessionQuery) -> DriverFuture<'a, SessionPage>;

    fn read_session<'a>(&'a self, request: SessionReadRequest)
    -> DriverFuture<'a, SessionSnapshot>;

    fn rename_session<'a>(&'a self, _request: RenameSessionRequest) -> DriverFuture<'a, ()> {
        Box::pin(async { Err(crate::DriverError::Unsupported("rename session")) })
    }
}

pub trait AgentSessionConnection: Send + Sync {
    fn attach_session<'a>(
        &'a self,
        request: AttachSessionRequest,
    ) -> DriverFuture<'a, AttachedSession>;

    /// Commits the provider checkpoint only after the corresponding Inline
    /// projection has been durably acknowledged. Implementations must reject
    /// acknowledgements that skip/regress, come from stale attachments, or
    /// precede durable projection of any earlier sequence.
    fn acknowledge_projection<'a>(&'a self, ack: SessionProjectionAck) -> DriverFuture<'a, ()>;

    fn detach_session<'a>(&'a self, request: DetachSessionRequest) -> DriverFuture<'a, ()>;
}

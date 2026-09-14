//! Workspace-scoped Codex session browsing over the stable app-server API.

use std::future::Future;
use std::path::Path;
use std::pin::Pin;

use inline_agent_bridge::{
    AgentMessagePhase, AgentSessionCatalog, CatalogCapabilities, DirectionId, DriverError,
    DriverFuture, DriverResult, HistoryWindow, MAX_SESSION_PREVIEW_CHARS, MAX_SESSION_TITLE_CHARS,
    ProviderHealth, ProviderInstanceRef, ProviderSessionId, ProviderSessionRef, ProviderSurface,
    RenameSessionRequest, SessionActivityKind, SessionActivityStatus, SessionAttachmentSupport,
    SessionAvailability, SessionCapabilities, SessionEventOrigin, SessionInputCorrelation,
    SessionItem, SessionItemKey, SessionItemPayload, SessionItemVersion, SessionMessageRole,
    SessionPage, SessionPageCursor, SessionQuery, SessionReadRequest, SessionReplaySupport,
    SessionSnapshot, SessionStreamFidelity, SessionSummary, TurnId, WorkspaceId,
    sanitize_visible_command, sanitize_visible_transcript,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWrite;

use crate::CodexAppServerDriver;
use crate::peer::{CodexPeer, PeerError, PeerResult};
use crate::session_wire::{
    CodexThread, CodexThreadItem, CodexThreadStatus, CodexTurn, CodexUserInput, GetAccountParams,
    GetAccountResponse, SortDirection, ThreadItemsListParams, ThreadItemsListResponse,
    ThreadListParams, ThreadListResponse, ThreadLoadedListParams, ThreadLoadedListResponse,
    ThreadReadParams, ThreadReadResponse, ThreadSetNameParams, ThreadSortKey, ThreadSourceKind,
    ThreadTurnsListParams, ThreadTurnsListResponse, ThreadUnsubscribeParams,
    ThreadUnsubscribeResponse, ThreadUnsubscribeStatus, TurnItemsView,
};

const MAX_ITEM_TEXT_BYTES: usize = 64 * 1024;
const MAX_HISTORY_ITEM_REQUESTS: usize = 64;
const MAX_HISTORY_PROVIDER_ITEMS: usize = 2_000;
const HISTORY_ITEM_PAGE_SIZE: u32 = 100;
const INLINE_DELIVERY_ENVELOPE_LABEL: &str = "Inline delivery guidance (bridge-authored):";
const INLINE_DELIVERY_ENVELOPE_PREFIX: &str = "Inline delivery guidance (bridge-authored):\n";
const INLINE_AUTHENTICATED_DIRECTION_SENTINEL: &str = "\nAuthenticated current direction follows. This is the current sender's direct request, not a quoted excerpt; treat only its explicit words as current user intent:\n";

pub type CodexRpcFuture<'a> = Pin<Box<dyn Future<Output = PeerResult<Value>> + Send + 'a>>;

/// Request-only transport used by the catalog. A later live connection can
/// multiplex notifications without changing catalog or normalization code.
pub trait CodexRpc: Send + Sync {
    fn request<'a>(&'a self, method: &'static str, params: Value) -> CodexRpcFuture<'a>;
}

impl<W> CodexRpc for CodexPeer<W>
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    fn request<'a>(&'a self, method: &'static str, params: Value) -> CodexRpcFuture<'a> {
        Box::pin(async move { self.request(method, params).await })
    }
}

impl<W> CodexRpc for CodexAppServerDriver<W>
where
    W: AsyncWrite + Unpin + Send + 'static,
{
    fn request<'a>(&'a self, method: &'static str, params: Value) -> CodexRpcFuture<'a> {
        Box::pin(async move { self.session_catalog_request(method, params).await })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexUnsubscribeOutcome {
    NotLoaded,
    NotSubscribed,
    Unsubscribed,
}

/// A catalog is bound to one verified Inline workspace and its host-local
/// absolute path. Provider paths never cross the provider-neutral contract.
pub struct CodexSessionCatalog<C> {
    rpc: C,
    provider: ProviderInstanceRef,
    workspace_id: WorkspaceId,
    workspace_path: String,
}

struct ThreadHistoryRead {
    thread: CodexThread,
    provider_has_older: bool,
}

impl<C> std::fmt::Debug for CodexSessionCatalog<C> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CodexSessionCatalog")
            .field("provider", &self.provider)
            .field("workspace_id", &self.workspace_id)
            .field("workspace_path", &"<workspace path>")
            .finish_non_exhaustive()
    }
}

impl<C> CodexSessionCatalog<C>
where
    C: CodexRpc,
{
    pub fn new(
        rpc: C,
        provider: ProviderInstanceRef,
        workspace_id: WorkspaceId,
        workspace_path: &Path,
    ) -> DriverResult<Self> {
        if !workspace_path.is_absolute() {
            return Err(DriverError::Protocol(
                "Codex session catalog requires an absolute workspace path".to_string(),
            ));
        }
        let workspace_path = workspace_path.to_str().ok_or_else(|| {
            DriverError::Protocol("Codex workspace path is not valid UTF-8".to_string())
        })?;
        Ok(Self {
            rpc,
            provider,
            workspace_id,
            workspace_path: workspace_path.to_owned(),
        })
    }

    pub async fn is_session_loaded(&self, session: &ProviderSessionRef) -> DriverResult<bool> {
        self.read_thread_in_workspace(session, false).await?;
        let mut cursor = None;
        let mut seen_cursors = std::collections::HashSet::new();
        for _ in 0..10 {
            let response: ThreadLoadedListResponse = self
                .request(
                    "thread/loaded/list",
                    ThreadLoadedListParams {
                        cursor,
                        limit: Some(100),
                    },
                )
                .await?;
            if response
                .data
                .iter()
                .any(|id| id == session.session_id().as_str())
            {
                return Ok(true);
            }
            let Some(next_cursor) = response.next_cursor else {
                return Ok(false);
            };
            let next_cursor = SessionPageCursor::new(next_cursor).map_err(contract_error)?;
            if !seen_cursors.insert(next_cursor.to_string()) {
                return Err(DriverError::Protocol(
                    "Codex thread/loaded/list repeated a pagination cursor".to_string(),
                ));
            }
            cursor = Some(next_cursor.to_string());
        }
        Err(DriverError::Protocol(
            "Codex thread/loaded/list exceeded its bounded pagination window".to_string(),
        ))
    }

    pub async fn unsubscribe_current_connection(
        &self,
        session: &ProviderSessionRef,
    ) -> DriverResult<CodexUnsubscribeOutcome> {
        self.validate_provider(session.provider())?;
        self.read_thread_in_workspace(session, false).await?;
        self.unsubscribe_prevalidated_current_connection(session)
            .await
    }

    pub(crate) async fn validate_session_for_attachment(
        &self,
        session: &ProviderSessionRef,
    ) -> DriverResult<()> {
        self.read_thread_in_workspace(session, false)
            .await
            .map(|_| ())
    }

    /// Unsubscribes the current app-server connection after the caller has
    /// already validated provider/session/workspace scope. Cleanup must not
    /// perform another scoped read: a failed resume can subscribe before it
    /// returns an error, and that subscription still has to be released.
    pub(crate) async fn unsubscribe_prevalidated_current_connection(
        &self,
        session: &ProviderSessionRef,
    ) -> DriverResult<CodexUnsubscribeOutcome> {
        self.validate_provider(session.provider())?;
        let response: ThreadUnsubscribeResponse = self
            .request(
                "thread/unsubscribe",
                ThreadUnsubscribeParams {
                    thread_id: session.session_id().to_string(),
                },
            )
            .await?;
        Ok(match response.status {
            ThreadUnsubscribeStatus::NotLoaded => CodexUnsubscribeOutcome::NotLoaded,
            ThreadUnsubscribeStatus::NotSubscribed => CodexUnsubscribeOutcome::NotSubscribed,
            ThreadUnsubscribeStatus::Unsubscribed => CodexUnsubscribeOutcome::Unsubscribed,
            ThreadUnsubscribeStatus::Unknown => {
                return Err(DriverError::Protocol(
                    "Codex returned an unconfirmed thread unsubscribe state".to_string(),
                ));
            }
        })
    }

    async fn request<P, R>(&self, method: &'static str, params: P) -> DriverResult<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let params = serde_json::to_value(params)
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        let response = self.rpc.request(method, params).await.map_err(peer_error)?;
        serde_json::from_value(response).map_err(|error| {
            DriverError::Protocol(format!(
                "Codex {method} returned an invalid stable response: {error}"
            ))
        })
    }

    fn validate_provider(&self, provider: &ProviderInstanceRef) -> DriverResult<()> {
        if provider != &self.provider {
            return Err(DriverError::Protocol(
                "Codex session request crossed its provider instance".to_string(),
            ));
        }
        Ok(())
    }

    pub(crate) fn validate_workspace(&self, workspace_id: &WorkspaceId) -> DriverResult<()> {
        if workspace_id != &self.workspace_id {
            return Err(DriverError::Protocol(
                "Codex session request crossed its workspace".to_string(),
            ));
        }
        Ok(())
    }

    pub(crate) fn provider_session(&self, id: String) -> DriverResult<ProviderSessionRef> {
        let id =
            ProviderSessionId::new(id).map_err(|error| DriverError::Protocol(error.to_string()))?;
        ProviderSessionRef::new(self.provider.clone(), id).map_err(contract_error)
    }

    async fn read_thread_in_workspace(
        &self,
        session: &ProviderSessionRef,
        include_turns: bool,
    ) -> DriverResult<CodexThread> {
        self.validate_provider(session.provider())?;
        let response: ThreadReadResponse = self
            .request(
                "thread/read",
                ThreadReadParams {
                    thread_id: session.session_id().to_string(),
                    include_turns,
                },
            )
            .await?;
        let response_session = self.provider_session(response.thread.id.clone())?;
        let identity_matches = &response_session == session;
        let workspace_matches = same_workspace_path(&self.workspace_path, &response.thread.cwd);
        if !identity_matches || !workspace_matches {
            return Err(DriverError::Protocol(format!(
                "Codex thread/read returned a session outside the requested scope \
                     (identity_match={identity_matches}, workspace_match={workspace_matches})"
            )));
        }
        Ok(response.thread)
    }

    async fn read_thread_history(
        &self,
        session: &ProviderSessionRef,
        window: &HistoryWindow,
    ) -> DriverResult<ThreadHistoryRead> {
        let mut thread = self.read_thread_in_workspace(session, false).await?;
        match &thread.status {
            CodexThreadStatus::Idle | CodexThreadStatus::NotLoaded => {}
            CodexThreadStatus::Active { .. } => {
                return Err(DriverError::SessionBusy(
                    "Codex reports that this session still has an active turn".to_string(),
                ));
            }
            CodexThreadStatus::SystemError => {
                return Err(DriverError::Unavailable(
                    "Codex reports that this session is unavailable".to_string(),
                ));
            }
            CodexThreadStatus::Unknown => {
                return Err(DriverError::Protocol(
                    "Codex returned an unknown session status".to_string(),
                ));
            }
        }
        if let Some((turns, provider_has_older)) =
            self.read_paginated_turns(session, window).await?
        {
            thread.turns = turns;
            return Ok(ThreadHistoryRead {
                thread,
                provider_has_older,
            });
        }

        // Old app-servers without bounded history paging retain the legacy
        // full-history read. The peer's frame limit remains the hard memory
        // bound; every newer paging-capable runtime stays on the bounded path.
        let response: serde_json::Value = self
            .request(
                "thread/read",
                ThreadReadParams {
                    thread_id: session.session_id().to_string(),
                    include_turns: true,
                },
            )
            .await?;
        if !response
            .get("thread")
            .and_then(|thread| thread.get("turns"))
            .is_some_and(serde_json::Value::is_array)
        {
            return Err(DriverError::Protocol(
                "Codex legacy thread/read omitted requested history".to_string(),
            ));
        }
        let response: ThreadReadResponse = serde_json::from_value(response).map_err(|error| {
            DriverError::Protocol(format!(
                "Codex legacy thread/read returned an invalid history response: {error}"
            ))
        })?;
        self.validate_thread_scope(session, &response.thread)?;
        Ok(ThreadHistoryRead {
            thread: response.thread,
            provider_has_older: false,
        })
    }

    async fn read_paginated_turns(
        &self,
        session: &ProviderSessionRef,
        window: &HistoryWindow,
    ) -> DriverResult<Option<(Vec<CodexTurn>, bool)>> {
        let Some((turns, provider_has_older)) = self
            .read_turn_pages(session, window, TurnItemsView::Summary)
            .await?
        else {
            return Ok(None);
        };
        if let Some((turns, incomplete_items)) =
            self.hydrate_paginated_turn_items(session, turns).await?
        {
            return Ok(Some((turns, provider_has_older || incomplete_items)));
        }

        // Older paging implementations expose complete items directly on turn
        // pages. This is a compatibility fallback only; future runtimes use
        // the independently negotiated thread/items/list method above.
        self.read_turn_pages(session, window, TurnItemsView::Full)
            .await
    }

    async fn read_turn_pages(
        &self,
        session: &ProviderSessionRef,
        window: &HistoryWindow,
        items_view: TurnItemsView,
    ) -> DriverResult<Option<(Vec<CodexTurn>, bool)>> {
        let mut cursor = None;
        let mut seen_cursors = std::collections::HashSet::new();
        let mut turns = Vec::new();
        let mut visible_messages = 0usize;
        let mut provider_has_older = false;
        for page_index in 0..5 {
            let params = serde_json::to_value(ThreadTurnsListParams {
                thread_id: session.session_id().to_string(),
                cursor: cursor.clone(),
                limit: 50,
                sort_direction: SortDirection::Desc,
                items_view,
            })
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
            let response = match self.rpc.request("thread/turns/list", params).await {
                Ok(response) => serde_json::from_value::<ThreadTurnsListResponse>(response)
                    .map_err(|error| {
                        DriverError::Protocol(format!(
                            "Codex thread/turns/list returned an invalid stable response: {error}"
                        ))
                    })?,
                Err(PeerError::Remote(error))
                    if page_index == 0 && matches!(error.code, Some(-32601) | Some(-32602)) =>
                {
                    return Ok(None);
                }
                Err(error) => return Err(peer_error(error)),
            };
            if items_view == TurnItemsView::Full
                && response
                    .data
                    .iter()
                    .any(|turn| turn.items_view != TurnItemsView::Full)
            {
                return Err(DriverError::Protocol(
                    "Codex did not honor the requested full turn item view".to_string(),
                ));
            }
            visible_messages = visible_messages.saturating_add(
                response
                    .data
                    .iter()
                    .map(normalizable_visible_message_count)
                    .sum::<usize>(),
            );
            turns.extend(response.data);
            let next_cursor = response
                .next_cursor
                .map(SessionPageCursor::new)
                .transpose()
                .map_err(contract_error)?;
            if visible_messages >= window.message_limit() {
                provider_has_older = next_cursor.is_some();
                break;
            }
            if page_index == 4 {
                provider_has_older = next_cursor.is_some();
                break;
            }
            let Some(next_cursor) = next_cursor else {
                break;
            };
            if !seen_cursors.insert(next_cursor.to_string()) {
                return Err(DriverError::Protocol(
                    "Codex thread/turns/list repeated a pagination cursor".to_string(),
                ));
            }
            cursor = Some(next_cursor.to_string())
        }
        turns.reverse();
        Ok(Some((turns, provider_has_older)))
    }

    async fn hydrate_paginated_turn_items(
        &self,
        session: &ProviderSessionRef,
        mut turns: Vec<CodexTurn>,
    ) -> DriverResult<Option<(Vec<CodexTurn>, bool)>> {
        let mut requests = 0usize;
        let mut provider_items = 0usize;
        let mut incomplete = false;
        for turn in &mut turns {
            if turn.items_view == TurnItemsView::Full {
                continue;
            }
            let summary_items = std::mem::take(&mut turn.items);
            let mut hydrated_items = Vec::new();
            let mut cursor = None;
            let mut seen_cursors = std::collections::HashSet::new();
            let mut complete = false;
            loop {
                if requests >= MAX_HISTORY_ITEM_REQUESTS
                    || provider_items >= MAX_HISTORY_PROVIDER_ITEMS
                {
                    break;
                }
                requests += 1;
                let params = serde_json::to_value(ThreadItemsListParams {
                    thread_id: session.session_id().to_string(),
                    turn_id: turn.id.clone(),
                    cursor: cursor.clone(),
                    limit: HISTORY_ITEM_PAGE_SIZE,
                    sort_direction: SortDirection::Asc,
                })
                .map_err(|error| DriverError::Protocol(error.to_string()))?;
                let response = match self.rpc.request("thread/items/list", params).await {
                    Ok(response) => serde_json::from_value::<ThreadItemsListResponse>(response)
                        .map_err(|error| {
                            DriverError::Protocol(format!(
                                "Codex thread/items/list returned an invalid stable response: {error}"
                            ))
                        })?,
                    Err(PeerError::Remote(error))
                        if matches!(error.code, Some(-32601) | Some(-32602)) =>
                    {
                        return Ok(None);
                    }
                    Err(error) => return Err(peer_error(error)),
                };
                if response.data.iter().any(|entry| entry.turn_id != turn.id) {
                    return Err(DriverError::Protocol(
                        "Codex thread/items/list returned an item for another turn".to_string(),
                    ));
                }
                let remaining = MAX_HISTORY_PROVIDER_ITEMS.saturating_sub(provider_items);
                let returned = response.data.len();
                hydrated_items.extend(
                    response
                        .data
                        .into_iter()
                        .take(remaining)
                        .map(|entry| entry.item),
                );
                provider_items = provider_items.saturating_add(returned.min(remaining));
                let next_cursor = response
                    .next_cursor
                    .map(SessionPageCursor::new)
                    .transpose()
                    .map_err(contract_error)?;
                if returned > remaining {
                    break;
                }
                let Some(next_cursor) = next_cursor else {
                    complete = true;
                    break;
                };
                if !seen_cursors.insert(next_cursor.to_string()) {
                    return Err(DriverError::Protocol(
                        "Codex thread/items/list repeated a pagination cursor".to_string(),
                    ));
                }
                cursor = Some(next_cursor.to_string());
            }
            if complete {
                turn.items = hydrated_items;
                turn.items_view = TurnItemsView::Full;
            } else {
                turn.items = merge_summary_and_hydrated_items(summary_items, hydrated_items);
                incomplete = true;
            }
        }
        Ok(Some((turns, incomplete)))
    }

    pub(crate) fn validate_thread_scope(
        &self,
        session: &ProviderSessionRef,
        thread: &CodexThread,
    ) -> DriverResult<()> {
        self.validate_provider(session.provider())?;
        let response_session = self.provider_session(thread.id.clone())?;
        let identity_matches = &response_session == session;
        let workspace_matches = same_workspace_path(&self.workspace_path, &thread.cwd);
        if !identity_matches || !workspace_matches {
            return Err(DriverError::Protocol(format!(
                "Codex returned a session outside the requested scope \
                 (identity_match={identity_matches}, workspace_match={workspace_matches})"
            )));
        }
        Ok(())
    }

    pub(crate) fn snapshot(
        &self,
        session: ProviderSessionRef,
        thread: CodexThread,
        window: HistoryWindow,
    ) -> DriverResult<SessionSnapshot> {
        self.snapshot_with_provider_boundary(session, thread, window, false)
    }

    fn snapshot_with_provider_boundary(
        &self,
        session: ProviderSessionRef,
        thread: CodexThread,
        window: HistoryWindow,
        provider_has_older: bool,
    ) -> DriverResult<SessionSnapshot> {
        let fallback_timestamp = valid_history_timestamp(thread.updated_at)?;
        let has_unsupported_items = thread.turns.iter().any(|turn| {
            turn.items
                .iter()
                .any(|item| matches!(item, CodexThreadItem::Unknown))
        });
        let mut items = Vec::new();
        let active_tail = matches!(thread.status, CodexThreadStatus::Active { .. })
            .then_some(thread.turns.len().saturating_sub(1));
        for (index, turn) in thread.turns.into_iter().enumerate() {
            items.extend(normalize_snapshot_turn(
                turn,
                active_tail == Some(index),
                fallback_timestamp,
            )?);
        }

        // An additive item kind must never make the projected window look
        // complete. It remains omitted until Inline can classify it safely,
        // while the snapshot explicitly reports incomplete provider history.
        let mut has_older = provider_has_older || has_unsupported_items;
        let message_count = items
            .iter()
            .filter(|item| item.is_visible_message())
            .count();
        if message_count > window.message_limit() {
            let messages_to_drop = message_count - window.message_limit();
            let mut seen = 0usize;
            let cut = items
                .iter()
                .position(|item| {
                    if item.is_visible_message() {
                        seen += 1;
                    }
                    seen > messages_to_drop
                })
                .unwrap_or(items.len());
            items.drain(..cut);
            has_older = true;
        }

        if items.len() > 256 {
            let excess = items.len() - 256;
            items.drain(..excess);
            has_older = true;
        }

        let mut truncated_by_bytes = false;
        let mut total_bytes = items.iter().map(item_text_bytes).sum::<usize>();
        let mut cut = 0usize;
        while total_bytes > window.max_text_bytes() && cut < items.len() {
            total_bytes = total_bytes.saturating_sub(item_text_bytes(&items[cut]));
            cut += 1;
        }
        if cut > 0 {
            items.drain(..cut);
            has_older = true;
            truncated_by_bytes = true;
        }

        SessionSnapshot::new(session, items, None, has_older, truncated_by_bytes, window)
            .map_err(contract_error)
    }
}

impl<C> AgentSessionCatalog for CodexSessionCatalog<C>
where
    C: CodexRpc,
{
    fn session_capabilities(&self) -> SessionCapabilities {
        SessionCapabilities {
            catalog: CatalogCapabilities {
                list: true,
                read: true,
                rename: true,
            },
            attachment: SessionAttachmentSupport::Exclusive,
            replay: SessionReplaySupport::Snapshot,
            stream_fidelity: SessionStreamFidelity::Semantic,
            external_input: false,
            external_surface_interop: true,
            control_replay: Default::default(),
        }
    }

    fn provider_health<'a>(
        &'a self,
        workspace_id: &'a WorkspaceId,
    ) -> DriverFuture<'a, ProviderHealth> {
        Box::pin(async move {
            self.validate_workspace(workspace_id)?;
            let params = serde_json::to_value(GetAccountParams {
                refresh_token: false,
            })
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
            let response = match self.rpc.request("account/read", params).await {
                Ok(response) => response,
                Err(PeerError::Remote(error)) if error.code == Some(-32601) => {
                    return Ok(ProviderHealth::UnsupportedVersion);
                }
                Err(PeerError::Io(_) | PeerError::Closed | PeerError::Timeout(_)) => {
                    return Ok(ProviderHealth::DaemonUnavailable);
                }
                Err(error) => return Err(peer_error(error)),
            };
            let Ok(response) = serde_json::from_value::<GetAccountResponse>(response) else {
                return Ok(ProviderHealth::UnsupportedVersion);
            };
            match (response.account, response.requires_openai_auth) {
                (Some(_), _) => Ok(ProviderHealth::Ready),
                (None, true) => Ok(ProviderHealth::Unauthenticated),
                (None, false) => Ok(ProviderHealth::UnsupportedVersion),
            }
        })
    }

    fn list_sessions<'a>(&'a self, query: SessionQuery) -> DriverFuture<'a, SessionPage> {
        Box::pin(async move {
            self.validate_provider(&query.provider)?;
            self.validate_workspace(&query.workspace_id)?;
            let response: ThreadListResponse = self
                .request(
                    "thread/list",
                    ThreadListParams {
                        cursor: query.cursor.as_ref().map(ToString::to_string),
                        limit: u32::try_from(query.page_size.get()).unwrap_or(100),
                        sort_key: ThreadSortKey::UpdatedAt,
                        sort_direction: SortDirection::Desc,
                        // Include bridge/app-server sessions as well as the
                        // default CLI/editor sources and completed headless
                        // work. Internal subagents remain excluded.
                        source_kinds: vec![
                            ThreadSourceKind::Cli,
                            ThreadSourceKind::VsCode,
                            ThreadSourceKind::AppServer,
                            ThreadSourceKind::Exec,
                        ],
                        archived: false,
                        cwd: workspace_path_filters(&self.workspace_path),
                        use_state_db_only: true,
                    },
                )
                .await?;
            // Real Codex catalogs can repeat one provider session identity.
            // Select by the durable timestamp instead of trusting response
            // ordering, then restore newest-first picker order.
            let mut unique_threads = std::collections::HashMap::<String, CodexThread>::new();
            for thread in response.data {
                if !same_workspace_path(&self.workspace_path, &thread.cwd) {
                    return Err(DriverError::Protocol(
                        "Codex thread/list returned a session outside the requested workspace"
                            .to_string(),
                    ));
                }
                match unique_threads.entry(thread.id.clone()) {
                    std::collections::hash_map::Entry::Vacant(entry) => {
                        entry.insert(thread);
                    }
                    std::collections::hash_map::Entry::Occupied(mut entry)
                        if thread.updated_at > entry.get().updated_at =>
                    {
                        entry.insert(thread);
                    }
                    std::collections::hash_map::Entry::Occupied(_) => {}
                }
            }
            let mut unique_threads = unique_threads.into_values().collect::<Vec<_>>();
            unique_threads.sort_by(|left, right| {
                right
                    .updated_at
                    .cmp(&left.updated_at)
                    .then_with(|| left.id.cmp(&right.id))
            });
            let mut summaries = Vec::with_capacity(unique_threads.len());
            for thread in unique_threads {
                let session = self.provider_session(thread.id)?;
                summaries.push(
                    SessionSummary::new(
                        session,
                        self.workspace_id.clone(),
                        bounded_historical_summary_text(
                            thread.name.as_deref(),
                            MAX_SESSION_TITLE_CHARS,
                        ),
                        bounded_historical_summary_text(
                            Some(thread.preview.as_str()),
                            MAX_SESSION_PREVIEW_CHARS,
                        ),
                        Some(thread.updated_at),
                        availability(thread.status),
                    )
                    .map_err(contract_error)?,
                );
            }
            let next_cursor = response
                .next_cursor
                .map(SessionPageCursor::new)
                .transpose()
                .map_err(contract_error)?;
            SessionPage::new(&query, summaries, next_cursor).map_err(contract_error)
        })
    }

    fn read_session<'a>(
        &'a self,
        request: SessionReadRequest,
    ) -> DriverFuture<'a, SessionSnapshot> {
        Box::pin(async move {
            self.validate_workspace(&request.workspace_id)?;
            let history = self
                .read_thread_history(&request.session, &request.window)
                .await?;
            self.snapshot_with_provider_boundary(
                request.session,
                history.thread,
                request.window,
                history.provider_has_older,
            )
        })
    }

    fn rename_session<'a>(&'a self, request: RenameSessionRequest) -> DriverFuture<'a, ()> {
        Box::pin(async move {
            self.read_thread_in_workspace(request.session(), false)
                .await?;
            let _: Value = self
                .request(
                    "thread/name/set",
                    ThreadSetNameParams {
                        thread_id: request.session().session_id().to_string(),
                        name: request.title().to_owned(),
                    },
                )
                .await?;
            Ok(())
        })
    }
}

fn historical_user_content(content: &[CodexUserInput]) -> String {
    content
        .iter()
        .map(|input| match input {
            CodexUserInput::Text { text } => text.as_str(),
            CodexUserInput::Image { .. } | CodexUserInput::LocalImage { .. } => {
                "[Image attachment]"
            }
            CodexUserInput::Audio { .. } | CodexUserInput::LocalAudio { .. } => {
                "[Audio attachment]"
            }
            CodexUserInput::Skill { .. } => "[Codex skill input]",
            CodexUserInput::Mention { .. } => "[Codex mention]",
            CodexUserInput::Unknown => "[Unsupported Codex input]",
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn codex_thread_item_id(item: &CodexThreadItem) -> Option<&str> {
    match item {
        CodexThreadItem::UserMessage { id, .. }
        | CodexThreadItem::AgentMessage { id, .. }
        | CodexThreadItem::Plan { id, .. }
        | CodexThreadItem::CommandExecution { id, .. }
        | CodexThreadItem::FileChange { id, .. } => Some(id),
        CodexThreadItem::Unknown => None,
    }
}

fn merge_summary_and_hydrated_items(
    summary: Vec<CodexThreadItem>,
    hydrated: Vec<CodexThreadItem>,
) -> Vec<CodexThreadItem> {
    let hydrated_ids = hydrated
        .iter()
        .filter_map(codex_thread_item_id)
        .collect::<std::collections::HashSet<_>>();
    let mut leading = Vec::new();
    let mut trailing = Vec::new();
    for item in summary {
        if codex_thread_item_id(&item).is_some_and(|id| hydrated_ids.contains(id)) {
            continue;
        }
        if matches!(item, CodexThreadItem::UserMessage { .. }) {
            leading.push(item);
        } else {
            trailing.push(item);
        }
    }
    drop(hydrated_ids);
    leading.extend(hydrated);
    leading.extend(trailing);
    leading
}

fn normalizable_visible_message_count(turn: &CodexTurn) -> usize {
    let has_final = turn_has_final_answer(turn);
    turn.items
        .iter()
        .filter(|item| match item {
            CodexThreadItem::UserMessage { content, .. } => {
                let text = historical_user_content(content);
                bounded_transcript(historical_user_text(&text)).is_some()
            }
            CodexThreadItem::AgentMessage { text, phase, .. } => {
                import_assistant_phase(*phase, has_final) && bounded_transcript(text).is_some()
            }
            _ => false,
        })
        .count()
}

fn turn_has_final_answer(turn: &CodexTurn) -> bool {
    turn.items.iter().any(|item| {
        matches!(item,
            CodexThreadItem::AgentMessage { phase: Some(AgentMessagePhase::FinalAnswer), text, .. }
                if bounded_transcript(text).is_some()
        )
    })
}

fn import_assistant_phase(phase: Option<AgentMessagePhase>, has_final: bool) -> bool {
    phase != Some(AgentMessagePhase::Commentary)
        && (!has_final || phase == Some(AgentMessagePhase::FinalAnswer))
}

pub(crate) fn normalize_turn(turn: CodexTurn) -> DriverResult<Vec<SessionItem>> {
    let run_id =
        TurnId::new(turn.id.clone()).map_err(|error| DriverError::Protocol(error.to_string()))?;
    let has_final = turn_has_final_answer(&turn);
    let mut normalized = Vec::new();
    for item in turn.items {
        let (provider_item_id, kind, payload, origin) = match item {
            CodexThreadItem::UserMessage {
                id,
                client_id,
                content,
            } => {
                let text = historical_user_content(&content);
                let Some(text) = bounded_transcript(historical_user_text(&text)) else {
                    continue;
                };
                let origin = client_id
                    .as_deref()
                    .and_then(inline_echo_origin)
                    .unwrap_or_else(|| SessionEventOrigin::provider(ProviderSurface::Unknown));
                (
                    id,
                    "user",
                    SessionItemPayload::Message {
                        role: SessionMessageRole::User,
                        text,
                        created_at: turn.started_at,
                    },
                    origin,
                )
            }
            CodexThreadItem::AgentMessage { id, text, phase } => {
                // Commentary already lives in the bridge progress message. Do
                // not import it again as the durable answer on session resume.
                if !import_assistant_phase(phase, has_final) {
                    continue;
                }
                let Some(text) = bounded_transcript(&text) else {
                    continue;
                };
                (
                    id,
                    "assistant",
                    SessionItemPayload::Message {
                        role: SessionMessageRole::Assistant,
                        text,
                        created_at: turn.completed_at.or(turn.started_at),
                    },
                    SessionEventOrigin::provider(ProviderSurface::Unknown),
                )
            }
            CodexThreadItem::Plan { id: _, text } => {
                let Some(detail) = bounded_transcript(&text) else {
                    continue;
                };
                (
                    // `turn/plan/updated` is an authoritative replacement for
                    // the current per-turn plan and has no provider item id.
                    // Use the same per-turn identity for snapshot, lifecycle,
                    // and live forms so repair cannot leave duplicate plans.
                    "current".to_string(),
                    "plan",
                    SessionItemPayload::Activity {
                        activity_kind: SessionActivityKind::Plan,
                        status: SessionActivityStatus::Completed,
                        title: "Plan".to_string(),
                        detail: Some(detail),
                    },
                    SessionEventOrigin::provider(ProviderSurface::Unknown),
                )
            }
            CodexThreadItem::CommandExecution {
                id,
                command,
                status,
            } => {
                let detail = sanitize_visible_command(&command);
                (
                    id,
                    "command",
                    SessionItemPayload::Activity {
                        activity_kind: SessionActivityKind::Command,
                        status: activity_status(&status),
                        title: "Command".to_string(),
                        detail,
                    },
                    SessionEventOrigin::provider(ProviderSurface::Unknown),
                )
            }
            CodexThreadItem::FileChange {
                id,
                changes,
                status,
            } => (
                id,
                "file_change",
                SessionItemPayload::Activity {
                    activity_kind: SessionActivityKind::FileChange,
                    status: activity_status(&status),
                    title: match changes.len() {
                        1 => "Changed 1 file".to_string(),
                        count => format!("Changed {count} files"),
                    },
                    detail: None,
                },
                SessionEventOrigin::provider(ProviderSurface::Unknown),
            ),
            CodexThreadItem::Unknown => continue,
        };
        normalized.push(SessionItem {
            key: stable_item_key(&turn.id, kind, &provider_item_id)?,
            revision: SessionItemVersion::snapshot_baseline(),
            run_id: Some(run_id.clone()),
            // Codex `thread.source` identifies where the session began, not
            // the surface that authored each historical item. A thread can be
            // continued from several clients, so per-item provenance remains
            // unknown until Codex exposes it on the item itself.
            origin,
            payload,
        });
    }
    Ok(normalized)
}

fn normalize_snapshot_turn(
    mut turn: CodexTurn,
    active_tail: bool,
    fallback_timestamp: i64,
) -> DriverResult<Vec<SessionItem>> {
    if let Some(started_at) = turn.started_at {
        valid_history_timestamp(started_at)?;
    }
    if let Some(completed_at) = turn.completed_at {
        valid_history_timestamp(completed_at)?;
    }
    if active_tail && turn.completed_at.is_none() {
        // Codex may expose a growing agent message in the last turn of an
        // active thread. Hydration must not certify that partial text as a
        // complete Inline history row: the server intentionally refuses blind
        // edits to completed rows. Idle historical turns often omit timing, so
        // active-thread state is the authoritative suppression boundary.
        turn.items
            .retain(|item| !matches!(item, CodexThreadItem::AgentMessage { .. }));
    }
    if turn.started_at.is_none() {
        turn.started_at = Some(fallback_timestamp);
    }
    if !active_tail && turn.completed_at.is_none() {
        turn.completed_at = turn.started_at;
    }
    normalize_turn(turn)
}

fn valid_history_timestamp(timestamp: i64) -> DriverResult<i64> {
    const MAX_JAVASCRIPT_DATE_SECONDS: i64 = 8_640_000_000_000;
    if !(0..=MAX_JAVASCRIPT_DATE_SECONDS).contains(&timestamp) {
        return Err(DriverError::Protocol(
            "Codex history contained an invalid source timestamp".to_string(),
        ));
    }
    Ok(timestamp)
}

fn inline_echo_origin(client_id: &str) -> Option<SessionEventOrigin> {
    let direction = client_id.strip_prefix(crate::INLINE_CLIENT_MESSAGE_ID_PREFIX)?;
    let direction_id = DirectionId::new(direction.to_owned()).ok()?;
    let correlation = SessionInputCorrelation::new(client_id.to_owned()).ok()?;
    Some(SessionEventOrigin::confirmed_inline_echo(
        direction_id,
        correlation,
    ))
}

pub(crate) fn stable_item_key(
    turn_id: &str,
    kind: &str,
    item_id: &str,
) -> DriverResult<SessionItemKey> {
    let digest = Sha256::digest(format!("{turn_id}\0{kind}\0{item_id}").as_bytes());
    let mut key = String::with_capacity(6 + digest.len() * 2);
    key.push_str("codex:");
    for byte in digest {
        use std::fmt::Write as _;
        write!(&mut key, "{byte:02x}").expect("writing to String cannot fail");
    }
    SessionItemKey::new(key).map_err(contract_error)
}

fn bounded_summary_text(value: Option<&str>, max_chars: usize) -> Option<String> {
    let value = sanitize_visible_transcript(value?)?
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if value.is_empty() {
        return None;
    }
    Some(value.chars().take(max_chars).collect())
}

fn bounded_historical_summary_text(value: Option<&str>, max_chars: usize) -> Option<String> {
    let value = value?;
    if value.starts_with(INLINE_DELIVERY_ENVELOPE_LABEL) {
        return None;
    }
    bounded_summary_text(Some(value), max_chars)
}

fn same_workspace_path(expected: &str, actual: &str) -> bool {
    if expected == actual {
        return true;
    }
    let Ok(expected) = std::fs::canonicalize(expected) else {
        return false;
    };
    let Ok(actual) = std::fs::canonicalize(actual) else {
        return false;
    };
    expected == actual
}

fn workspace_path_filters(workspace_path: &str) -> Vec<String> {
    let mut paths = vec![workspace_path.to_owned()];
    if let Ok(canonical) = std::fs::canonicalize(workspace_path)
        && let Some(canonical) = canonical.to_str()
        && canonical != workspace_path
    {
        paths.push(canonical.to_owned());
    }
    paths
}

pub(crate) fn bounded_transcript(value: &str) -> Option<String> {
    let sanitized = sanitize_visible_transcript(value)?;
    Some(truncate_utf8_bytes(&sanitized, MAX_ITEM_TEXT_BYTES))
}

fn historical_user_text(value: &str) -> &str {
    if !value.starts_with(INLINE_DELIVERY_ENVELOPE_PREFIX) {
        return value;
    }
    value
        .rsplit_once(INLINE_AUTHENTICATED_DIRECTION_SENTINEL)
        .map_or(value, |(_, direction)| direction)
}

fn truncate_utf8_bytes(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_owned();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn availability(status: CodexThreadStatus) -> SessionAvailability {
    match status {
        CodexThreadStatus::Active { .. } => SessionAvailability::Active,
        CodexThreadStatus::Idle | CodexThreadStatus::NotLoaded => SessionAvailability::Available,
        CodexThreadStatus::SystemError => SessionAvailability::Unavailable,
        CodexThreadStatus::Unknown => SessionAvailability::Unknown,
    }
}

fn activity_status(status: &str) -> SessionActivityStatus {
    match status {
        "inProgress" => SessionActivityStatus::Active,
        "completed" => SessionActivityStatus::Completed,
        "failed" | "declined" => SessionActivityStatus::Failed,
        _ => SessionActivityStatus::Waiting,
    }
}

fn item_text_bytes(item: &SessionItem) -> usize {
    match &item.payload {
        SessionItemPayload::Message { text, .. } => text.len(),
        SessionItemPayload::Activity { title, detail, .. } => {
            title.len() + detail.as_ref().map_or(0, String::len)
        }
    }
}

fn contract_error(error: impl std::fmt::Display) -> DriverError {
    DriverError::Protocol(error.to_string())
}

fn peer_error(error: PeerError) -> DriverError {
    match error {
        PeerError::Io(error) => DriverError::Unavailable(error.to_string()),
        PeerError::Remote(error) => DriverError::Rejected(match error.code {
            Some(code) => format!("Codex rejected the session request (code {code})"),
            None => "Codex rejected the session request".to_string(),
        }),
        PeerError::Closed => DriverError::ProcessExited("Codex app-server closed".to_string()),
        PeerError::Json(error) => DriverError::Protocol(error.to_string()),
        PeerError::InvalidMessage(error) => DriverError::Protocol(error),
        PeerError::IncomingAlreadyClaimed => DriverError::Protocol(
            "Codex app-server incoming stream already has an owner".to_string(),
        ),
        PeerError::Timeout(method) => DriverError::Transient(format!("Codex {method} timed out")),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use inline_agent_bridge::{AgentSessionCatalog, InstallationId, ProviderId, SessionPageSize};
    use serde_json::json;

    use super::*;

    #[test]
    fn history_prefers_final_phase_and_never_imports_commentary_as_an_answer() {
        let turn: CodexTurn = serde_json::from_value(serde_json::json!({
            "id":"turn-1", "items":[
                {"id":"a", "type":"agentMessage", "text":"Interim", "phase":"commentary"},
                {"id":"b", "type":"agentMessage", "text":"Answer", "phase":"final_answer"},
                {"id":"c", "type":"agentMessage", "text":"Late commentary", "phase":"commentary"},
                {"id":"d", "type":"agentMessage", "text":"Unphased"}
            ]
        }))
        .unwrap();
        assert_eq!(normalizable_visible_message_count(&turn), 1);
        let items = normalize_turn(turn).unwrap();
        assert_eq!(items.len(), 1);
        assert!(
            matches!(&items[0].payload, SessionItemPayload::Message { text, .. } if text == "Answer")
        );
    }

    #[test]
    fn history_paging_counts_only_visible_messages_without_a_final_phase() {
        let turn: CodexTurn = serde_json::from_value(json!({
            "id":"turn-1", "items":[
                {"id":"a", "type":"agentMessage", "text":"Interim", "phase":"commentary"},
                {"id":"b", "type":"agentMessage", "text":"\u{1b}[0m", "phase":"final_answer"},
                {"id":"c", "type":"agentMessage", "text":"Legacy answer"},
                {"id":"d", "type":"agentMessage", "text":"Future answer", "phase":"future_phase"}
            ]
        }))
        .unwrap();
        let count = normalizable_visible_message_count(&turn);
        let items = normalize_turn(turn).unwrap();
        assert_eq!(count, 2);
        assert_eq!(items.len(), count);
    }

    #[test]
    fn legacy_inline_delivery_envelope_projects_only_the_authenticated_direction() {
        let wrapped = format!(
            "{INLINE_DELIVERY_ENVELOPE_PREFIX}- guidance\nRecent Inline context follows.\n[Participant] quoted\n{INLINE_AUTHENTICATED_DIRECTION_SENTINEL}ship the clean prompt"
        );
        assert_eq!(historical_user_text(&wrapped), "ship the clean prompt");
    }

    #[test]
    fn native_user_text_that_only_resembles_the_envelope_is_preserved() {
        let native = format!(
            "Please discuss this text:{INLINE_AUTHENTICATED_DIRECTION_SENTINEL}keep all of it"
        );
        assert_eq!(historical_user_text(&native), native);
        assert_eq!(
            historical_user_text(INLINE_DELIVERY_ENVELOPE_PREFIX),
            INLINE_DELIVERY_ENVELOPE_PREFIX
        );
    }

    #[test]
    fn active_snapshot_tail_omits_partial_agent_message_without_hiding_idle_history() {
        let turn = |completed_at| CodexTurn {
            id: "turn-1".to_string(),
            items: vec![CodexThreadItem::AgentMessage {
                phase: None,
                id: "agent-1".to_string(),
                text: "Final answer".to_string(),
            }],
            items_view: TurnItemsView::Full,
            started_at: Some(10),
            completed_at,
        };

        assert!(
            normalize_snapshot_turn(turn(None), true, 30)
                .expect("active snapshot tail")
                .is_empty()
        );
        let idle = normalize_snapshot_turn(turn(None), false, 30).expect("idle history");
        assert_eq!(idle.len(), 1);
        let completed = normalize_snapshot_turn(turn(Some(20)), true, 30).expect("completed turn");
        assert_eq!(completed.len(), 1);
        assert!(matches!(
            &completed[0].payload,
            SessionItemPayload::Message {
                role: SessionMessageRole::Assistant,
                text,
                created_at: Some(20),
            } if text == "Final answer"
        ));
    }

    #[test]
    fn legacy_delivery_envelope_never_becomes_a_session_label() {
        assert_eq!(
            bounded_historical_summary_text(
                Some("Inline delivery guidance (bridge-authored): continue the work"),
                MAX_SESSION_TITLE_CHARS,
            ),
            None
        );
        assert_eq!(
            bounded_historical_summary_text(
                Some("Review Inline delivery guidance (bridge-authored):"),
                MAX_SESSION_TITLE_CHARS,
            ),
            Some("Review Inline delivery guidance (bridge-authored):".to_string())
        );
    }

    struct FakeRpc {
        responses: Mutex<VecDeque<Value>>,
        requests: Mutex<Vec<(&'static str, Value)>>,
    }

    impl FakeRpc {
        fn new(responses: impl IntoIterator<Item = Value>) -> Self {
            Self {
                responses: Mutex::new(responses.into_iter().collect()),
                requests: Mutex::new(Vec::new()),
            }
        }

        fn requests(&self) -> Vec<(&'static str, Value)> {
            self.requests.lock().expect("requests").clone()
        }
    }

    impl CodexRpc for FakeRpc {
        fn request<'a>(&'a self, method: &'static str, params: Value) -> CodexRpcFuture<'a> {
            self.requests
                .lock()
                .expect("requests")
                .push((method, params));
            let response = self
                .responses
                .lock()
                .expect("responses")
                .pop_front()
                .expect("fake response");
            Box::pin(async move { Ok(response) })
        }
    }

    struct ResultRpc {
        responses: Mutex<VecDeque<PeerResult<Value>>>,
        requests: Mutex<Vec<(&'static str, Value)>>,
    }

    impl ResultRpc {
        fn new(responses: impl IntoIterator<Item = PeerResult<Value>>) -> Self {
            Self {
                responses: Mutex::new(responses.into_iter().collect()),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl CodexRpc for ResultRpc {
        fn request<'a>(&'a self, method: &'static str, params: Value) -> CodexRpcFuture<'a> {
            self.requests
                .lock()
                .expect("requests")
                .push((method, params));
            let response = self
                .responses
                .lock()
                .expect("responses")
                .pop_front()
                .expect("fake response");
            Box::pin(async move { response })
        }
    }

    struct PaginatedRpc {
        calls: AtomicUsize,
        requests: Mutex<Vec<(&'static str, Value)>>,
    }

    impl PaginatedRpc {
        fn new() -> Self {
            Self {
                calls: AtomicUsize::new(0),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl CodexRpc for PaginatedRpc {
        fn request<'a>(&'a self, method: &'static str, params: Value) -> CodexRpcFuture<'a> {
            self.requests
                .lock()
                .expect("requests")
                .push((method, params));
            let call = self.calls.fetch_add(1, Ordering::SeqCst);
            Box::pin(async move {
                match call {
                    0 => Ok(json!({
                        "thread": thread("thread-1", "/project", json!([]))
                    })),
                    1 => Ok(json!({
                        "data": [
                            {
                                "id": "turn-new",
                                "itemsView": "summary",
                                "items": [{
                                    "type": "agentMessage",
                                    "id": "agent-new",
                                    "text": "New response"
                                }]
                            },
                            {
                                "id": "turn-old",
                                "itemsView": "summary",
                                "items": [{
                                    "type": "userMessage",
                                    "id": "user-old",
                                    "clientId": null,
                                    "content": [{ "type": "text", "text": "Old request" }]
                                }]
                            }
                        ],
                        "nextCursor": null,
                        "backwardsCursor": "newer"
                    })),
                    2 => Ok(json!({
                        "data": [{
                            "turnId": "turn-old",
                            "item": {
                                "type": "userMessage",
                                "id": "user-old",
                                "clientId": null,
                                "content": [{ "type": "text", "text": "Old request" }]
                            }
                        }],
                        "nextCursor": null
                    })),
                    3 => Ok(json!({
                        "data": [
                            {
                                "turnId": "turn-new",
                                "item": {
                                    "type": "commandExecution",
                                    "id": "command-new",
                                    "command": "cargo test",
                                    "status": "completed"
                                }
                            },
                            {
                                "turnId": "turn-new",
                                "item": {
                                    "type": "agentMessage",
                                    "id": "agent-new",
                                    "text": "New response"
                                }
                            }
                        ],
                        "nextCursor": null
                    })),
                    _ => panic!("unexpected paginated RPC call"),
                }
            })
        }
    }

    fn provider() -> ProviderInstanceRef {
        ProviderInstanceRef::new(
            InstallationId::new("installation-1").expect("installation"),
            ProviderId::new("codex").expect("provider"),
        )
        .expect("provider instance")
    }

    fn workspace() -> WorkspaceId {
        WorkspaceId::new("workspace-1").expect("workspace")
    }

    fn session(id: &str) -> ProviderSessionRef {
        ProviderSessionRef::new(provider(), ProviderSessionId::new(id).expect("session id"))
            .expect("session")
    }

    fn thread(id: &str, cwd: &str, turns: Value) -> Value {
        json!({
            "id": id,
            "sessionId": id,
            "preview": "Fix the reconnect race",
            "createdAt": 1_777_000_000,
            "updatedAt": 1_777_000_100,
            "status": { "type": "idle" },
            "cwd": cwd,
            "name": "Reconnect repair",
            "turns": turns,
            "modelProvider": "openai",
            "source": "cli",
            "unknownAdditiveField": true
        })
    }

    #[tokio::test]
    async fn lists_named_and_previewed_sessions_with_exact_workspace_filter() {
        let rpc = FakeRpc::new([json!({
            "data": [thread("thread-1", "/project", json!([]))],
            "nextCursor": "next",
            "backwardsCursor": "back"
        })]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let page = catalog
            .list_sessions(SessionQuery {
                provider: provider(),
                workspace_id: workspace(),
                cursor: None,
                page_size: SessionPageSize::new(20),
            })
            .await
            .expect("list");

        assert_eq!(page.sessions()[0].title(), Some("Reconnect repair"));
        assert_eq!(page.sessions()[0].preview(), Some("Fix the reconnect race"));
        assert_eq!(
            page.sessions()[0].availability(),
            SessionAvailability::Available
        );
        assert_eq!(
            page.next_cursor().map(ToString::to_string).as_deref(),
            Some("next")
        );
        let request = &catalog.rpc.requests()[0];
        assert_eq!(request.0, "thread/list");
        assert_eq!(request.1["cwd"], json!(["/project"]));
        assert_eq!(request.1["sortKey"], "updated_at");
        assert_eq!(request.1["useStateDbOnly"], true);
        assert_eq!(
            request.1["sourceKinds"],
            json!(["cli", "vscode", "appServer", "exec"])
        );
    }

    #[tokio::test]
    async fn list_deduplicates_provider_session_identity_and_preserves_newest_row() {
        let first = thread("thread-1", "/project", json!([]));
        let mut duplicate = thread("thread-1", "/project", json!([]));
        duplicate["name"] = json!("Older duplicate");
        duplicate["updatedAt"] = json!(1_776_000_000);
        let rpc = FakeRpc::new([json!({
            "data": [duplicate, first, thread("thread-2", "/project", json!([]))],
            "nextCursor": null
        })]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let page = catalog
            .list_sessions(SessionQuery {
                provider: provider(),
                workspace_id: workspace(),
                cursor: None,
                page_size: SessionPageSize::new(20),
            })
            .await
            .expect("list");

        assert_eq!(page.sessions().len(), 2);
        assert_eq!(
            page.sessions()[0].session().session_id().as_str(),
            "thread-1"
        );
        assert_eq!(page.sessions()[0].title(), Some("Reconnect repair"));
        assert_eq!(
            page.sessions()[1].session().session_id().as_str(),
            "thread-2"
        );
    }

    #[tokio::test]
    async fn list_sanitizes_provider_title_and_preview_before_projection() {
        let mut sensitive_thread = thread("thread-1", "/project", json!([]));
        sensitive_thread["name"] = json!("Repair /Users/alice/private TOKEN=secret-value");
        sensitive_thread["preview"] =
            json!("Authorization: Bearer historical-secret\nContinue the reconnect repair");
        let rpc = FakeRpc::new([json!({
            "data": [sensitive_thread],
            "nextCursor": null
        })]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let page = catalog
            .list_sessions(SessionQuery {
                provider: provider(),
                workspace_id: workspace(),
                cursor: None,
                page_size: SessionPageSize::new(20),
            })
            .await
            .expect("list");

        let summary = &page.sessions()[0];
        let projected = format!(
            "{} {}",
            summary.title().expect("title"),
            summary.preview().expect("preview")
        );
        assert!(!projected.contains("/Users/alice"));
        assert!(!projected.contains("secret-value"));
        assert!(!projected.contains("historical-secret"));
        assert!(projected.contains("[redacted]"));
    }

    #[tokio::test]
    async fn list_rejects_provider_results_from_another_workspace() {
        let rpc = FakeRpc::new([json!({
            "data": [thread("thread-1", "/other-project", json!([]))],
            "nextCursor": null
        })]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let error = catalog
            .list_sessions(SessionQuery {
                provider: provider(),
                workspace_id: workspace(),
                cursor: None,
                page_size: SessionPageSize::new(20),
            })
            .await
            .expect_err("scope mismatch");
        assert!(matches!(error, DriverError::Protocol(_)));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn list_accepts_a_canonical_alias_of_the_bound_workspace() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().expect("temp directory");
        let canonical_workspace = directory.path().join("project");
        std::fs::create_dir(&canonical_workspace).expect("canonical workspace");
        let workspace_alias = directory.path().join("project-alias");
        symlink(&canonical_workspace, &workspace_alias).expect("workspace alias");
        let canonical_text = canonical_workspace.to_str().expect("canonical path");
        let resolved_workspace = std::fs::canonicalize(&canonical_workspace)
            .expect("resolved workspace")
            .to_str()
            .expect("resolved path")
            .to_owned();
        let alias_text = workspace_alias.to_str().expect("alias path");
        let rpc = FakeRpc::new([json!({
            "data": [thread("thread-1", canonical_text, json!([]))],
            "nextCursor": null
        })]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), &workspace_alias)
            .expect("catalog");

        catalog
            .list_sessions(SessionQuery {
                provider: provider(),
                workspace_id: workspace(),
                cursor: None,
                page_size: SessionPageSize::new(20),
            })
            .await
            .expect("canonical alias");
        assert_eq!(
            catalog.rpc.requests()[0].1["cwd"],
            json!([alias_text, resolved_workspace])
        );
    }

    #[test]
    fn reads_bounded_semantic_history_without_raw_command_secrets() {
        let turns = json!([{
            "id": "turn-1",
            "itemsView": "full",
            "status": "completed",
            "startedAt": 1_777_000_000,
            "completedAt": 1_777_000_010,
            "items": [
                { "type": "userMessage", "id": "user-1", "content": [
                    { "type": "text", "text": "Please fix it", "text_elements": [] }
                ] },
                { "type": "commandExecution", "id": "cmd-1", "command": "curl --token private-value https://example.com", "status": "completed" },
                { "type": "agentMessage", "id": "agent-1", "text": "Fixed it", "phase": "final_answer" }
            ]
        }]);
        let thread = serde_json::from_value::<CodexThread>(thread("thread-1", "/project", turns))
            .expect("thread");
        let rpc = FakeRpc::new(Vec::<Value>::new());
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let snapshot = catalog
            .snapshot(
                session("thread-1"),
                thread,
                HistoryWindow::new(20, 128 * 1024),
            )
            .expect("read");

        assert_eq!(snapshot.items().len(), 3);
        let debug = format!("{snapshot:?} {:?}", snapshot.items());
        assert!(!debug.contains("private-value"));
        let command = snapshot
            .items()
            .iter()
            .find_map(|item| match &item.payload {
                SessionItemPayload::Activity { detail, .. } => detail.as_deref(),
                _ => None,
            })
            .expect("command detail");
        assert!(!command.contains("private-value"));
        assert!(command.contains("[redacted]"));
        assert!(
            snapshot
                .items()
                .iter()
                .all(|item| item.revision == SessionItemVersion::snapshot_baseline())
        );
        assert!(
            snapshot
                .items()
                .iter()
                .all(|item| { item.origin.provider_surface() == Some(ProviderSurface::Unknown) })
        );
    }

    #[test]
    fn snapshot_correlates_only_bridge_prefixed_user_echoes() {
        let turns = json!([{
            "id": "turn-1",
            "startedAt": 1_777_000_000,
            "items": [
                {
                    "type": "userMessage",
                    "id": "user-1",
                    "clientId": "inline-agent-bridge:v1:inline-event-1",
                    "content": [{ "type": "text", "text": "From Inline" }]
                },
                {
                    "type": "userMessage",
                    "id": "user-2",
                    "clientId": "another-client",
                    "content": [{ "type": "text", "text": "From Codex" }]
                }
            ]
        }]);
        let thread = serde_json::from_value::<CodexThread>(thread("thread-1", "/project", turns))
            .expect("thread");
        let rpc = FakeRpc::new(Vec::<Value>::new());
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let snapshot = catalog
            .snapshot(session("thread-1"), thread, HistoryWindow::default())
            .expect("read");

        assert_eq!(
            snapshot.items()[0]
                .confirmed_inline_echo()
                .map(ToString::to_string),
            Some("inline-event-1".to_string())
        );
        assert!(snapshot.items()[1].confirmed_inline_echo().is_none());
        assert_eq!(
            snapshot.items()[1].origin.provider_surface(),
            Some(ProviderSurface::Unknown)
        );
    }

    #[tokio::test]
    async fn paginated_threads_use_bounded_summary_pages_in_chronological_order() {
        let rpc = PaginatedRpc::new();
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let snapshot = catalog
            .read_session(SessionReadRequest {
                session: session("thread-1"),
                workspace_id: workspace(),
                window: HistoryWindow::default(),
            })
            .await
            .expect("paginated history");

        assert_eq!(snapshot.items().len(), 3);
        assert!(matches!(
            &snapshot.items()[0].payload,
            SessionItemPayload::Message { text, .. } if text == "Old request"
        ));
        assert!(matches!(
            &snapshot.items()[2].payload,
            SessionItemPayload::Message { text, .. } if text == "New response"
        ));
        let requests = catalog.rpc.requests.lock().expect("requests");
        assert_eq!(
            requests
                .iter()
                .map(|(method, _)| *method)
                .collect::<Vec<_>>(),
            [
                "thread/read",
                "thread/turns/list",
                "thread/items/list",
                "thread/items/list"
            ]
        );
        assert_eq!(requests[1].1["sortDirection"], "desc");
        assert_eq!(requests[1].1["itemsView"], "summary");
        assert_eq!(requests[2].1["sortDirection"], "asc");
        assert_eq!(requests[2].1["turnId"], "turn-old");
    }

    #[tokio::test]
    async fn exact_history_limit_still_rejects_malformed_remaining_cursors() {
        for cursor in [String::new(), "bad\ncursor".to_string(), "x".repeat(5000)] {
            let rpc = FakeRpc::new([
                json!({ "thread": thread("thread-1", "/project", json!([])) }),
                json!({ "data": [{ "id": "turn-1", "items": [{
                    "type": "userMessage", "id": "user-1",
                    "content": [{ "type": "text", "text": "visible" }]
                }] }], "nextCursor": cursor }),
            ]);
            let catalog =
                CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
                    .expect("catalog");
            assert!(
                catalog
                    .read_session(SessionReadRequest {
                        session: session("thread-1"),
                        workspace_id: workspace(),
                        window: HistoryWindow::new(1, 16 * 1024),
                    })
                    .await
                    .is_err()
            );
        }
    }

    #[tokio::test]
    async fn active_or_unknown_sessions_cannot_be_imported_after_selection() {
        for status in [
            json!({"type":"active", "activeFlags":[]}),
            json!({"type":"futureStatus", "extra":true}),
        ] {
            let mut value = thread("thread-1", "/project", json!([]));
            value["status"] = status;
            let rpc = FakeRpc::new([json!({ "thread": value })]);
            let catalog =
                CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
                    .expect("catalog");
            assert!(
                catalog
                    .read_session(SessionReadRequest {
                        session: session("thread-1"),
                        workspace_id: workspace(),
                        window: HistoryWindow::new(1, 16 * 1024),
                    })
                    .await
                    .is_err()
            );
            assert_eq!(catalog.rpc.requests().len(), 1);
        }
    }

    #[tokio::test]
    async fn exact_history_limit_marks_a_valid_remaining_cursor_as_older() {
        let rpc = FakeRpc::new([
            json!({ "thread": thread("thread-1", "/project", json!([])) }),
            json!({
                "data": [{
                    "id": "turn-1",
                    "items": [{
                        "type": "userMessage",
                        "id": "user-1",
                        "content": [{ "type": "text", "text": "One visible message" }]
                    }]
                }],
                "nextCursor": "older-cursor"
            }),
        ]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");

        let snapshot = catalog
            .read_session(SessionReadRequest {
                session: session("thread-1"),
                workspace_id: workspace(),
                window: HistoryWindow::new(1, 16 * 1024),
            })
            .await
            .expect("bounded history");

        assert_eq!(snapshot.items().len(), 1);
        assert!(snapshot.has_older());
    }

    #[tokio::test]
    async fn legacy_history_fallback_rejects_a_missing_turns_field() {
        let mut legacy_thread = thread("thread-1", "/project", json!([]));
        legacy_thread
            .as_object_mut()
            .expect("thread object")
            .remove("turns");
        let rpc = ResultRpc::new([
            Ok(json!({ "thread": thread("thread-1", "/project", json!([])) })),
            Err(PeerError::Remote(crate::peer::RemoteError {
                code: Some(-32601),
                message: "method not found".to_string(),
            })),
            Ok(json!({ "thread": legacy_thread })),
        ]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");

        assert!(matches!(
            catalog
                .read_session(SessionReadRequest {
                    session: session("thread-1"),
                    workspace_id: workspace(),
                    window: HistoryWindow::default(),
                })
                .await,
            Err(DriverError::Protocol(message))
                if message.contains("omitted requested history")
        ));
    }

    #[tokio::test]
    async fn older_turn_paging_falls_back_to_bounded_full_turn_pages() {
        let summary_turn = json!({
            "id": "turn-1",
            "itemsView": "summary",
            "items": [{
                "type": "userMessage",
                "id": "user-1",
                "content": [{ "type": "text", "text": "Question" }]
            }]
        });
        let full_turn = json!({
            "id": "turn-1",
            "itemsView": "full",
            "items": [
                {
                    "type": "userMessage",
                    "id": "user-1",
                    "content": [{ "type": "text", "text": "Question" }]
                },
                {
                    "type": "agentMessage",
                    "id": "agent-1",
                    "text": "Answer"
                }
            ]
        });
        let rpc = ResultRpc::new([
            Ok(json!({ "thread": thread("thread-1", "/project", json!([])) })),
            Ok(json!({ "data": [summary_turn], "nextCursor": null })),
            Err(PeerError::Remote(crate::peer::RemoteError {
                code: Some(-32601),
                message: "method not found".to_string(),
            })),
            Ok(json!({ "data": [full_turn], "nextCursor": null })),
        ]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");

        let snapshot = catalog
            .read_session(SessionReadRequest {
                session: session("thread-1"),
                workspace_id: workspace(),
                window: HistoryWindow::default(),
            })
            .await
            .expect("bounded old-runtime history");

        assert_eq!(snapshot.items().len(), 2);
        assert!(!snapshot.has_older());
    }

    #[test]
    fn session_source_is_not_invented_as_per_item_history_provenance() {
        let turns = json!([{
            "id": "turn-1",
            "startedAt": 1_777_000_000,
            "items": [
                { "type": "agentMessage", "id": "agent-1", "text": "Continued remotely" }
            ]
        }]);
        let mut chatgpt_thread = thread("thread-1", "/project", turns);
        chatgpt_thread["source"] = json!({ "custom": "chatgpt" });
        let chatgpt_thread = serde_json::from_value::<CodexThread>(chatgpt_thread).expect("thread");
        let rpc = FakeRpc::new(Vec::<Value>::new());
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        let snapshot = catalog
            .snapshot(
                session("thread-1"),
                chatgpt_thread,
                HistoryWindow::default(),
            )
            .expect("read");

        assert_eq!(
            snapshot.items()[0].origin.provider_surface(),
            Some(ProviderSurface::Unknown)
        );
    }

    #[tokio::test]
    async fn rename_verifies_workspace_before_mutating_provider_state() {
        let rpc = FakeRpc::new([
            json!({ "thread": thread("thread-1", "/project", json!([])) }),
            json!({}),
        ]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        catalog
            .rename_session(
                RenameSessionRequest::new(session("thread-1"), "New title".to_string())
                    .expect("rename"),
            )
            .await
            .expect("renamed");
        let requests = catalog.rpc.requests();
        assert_eq!(requests[0].0, "thread/read");
        assert_eq!(requests[1].0, "thread/name/set");
        assert_eq!(requests[1].1["name"], "New title");
    }

    #[tokio::test]
    async fn health_distinguishes_existing_codex_auth_from_missing_auth() {
        let unauthenticated = CodexSessionCatalog::new(
            FakeRpc::new([json!({ "account": null, "requiresOpenaiAuth": true })]),
            provider(),
            workspace(),
            Path::new("/project"),
        )
        .expect("catalog");
        assert_eq!(
            unauthenticated
                .provider_health(&workspace())
                .await
                .expect("health"),
            ProviderHealth::Unauthenticated
        );

        let authenticated = CodexSessionCatalog::new(
            FakeRpc::new([json!({
                "account": {
                    "type": "chatgpt",
                    "email": "private@example.com",
                    "planType": "plus"
                },
                "requiresOpenaiAuth": true
            })]),
            provider(),
            workspace(),
            Path::new("/project"),
        )
        .expect("catalog");
        assert_eq!(
            authenticated
                .provider_health(&workspace())
                .await
                .expect("health"),
            ProviderHealth::Ready
        );

        let malformed = CodexSessionCatalog::new(
            FakeRpc::new([json!({
                "account": {},
                "requiresOpenaiAuth": true
            })]),
            provider(),
            workspace(),
            Path::new("/project"),
        )
        .expect("catalog");
        assert_eq!(
            malformed
                .provider_health(&workspace())
                .await
                .expect("health"),
            ProviderHealth::UnsupportedVersion
        );

        let impossible_null_account = CodexSessionCatalog::new(
            FakeRpc::new([json!({
                "account": null,
                "requiresOpenaiAuth": false
            })]),
            provider(),
            workspace(),
            Path::new("/project"),
        )
        .expect("catalog");
        assert_eq!(
            impossible_null_account
                .provider_health(&workspace())
                .await
                .expect("health"),
            ProviderHealth::UnsupportedVersion
        );

        let bedrock_default = CodexSessionCatalog::new(
            FakeRpc::new([json!({
                "account": { "type": "amazonBedrock" },
                "requiresOpenaiAuth": false
            })]),
            provider(),
            workspace(),
            Path::new("/project"),
        )
        .expect("catalog");
        assert_eq!(
            bedrock_default
                .provider_health(&workspace())
                .await
                .expect("health"),
            ProviderHealth::Ready
        );
    }

    #[tokio::test]
    async fn loaded_state_and_unsubscribe_are_session_scoped() {
        let rpc = FakeRpc::new([
            json!({ "thread": thread("thread-1", "/project", json!([])) }),
            json!({ "data": ["thread-1"], "nextCursor": null }),
            json!({ "thread": thread("thread-1", "/project", json!([])) }),
            json!({ "status": "unsubscribed" }),
        ]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");
        assert!(
            catalog
                .is_session_loaded(&session("thread-1"))
                .await
                .expect("loaded")
        );
        assert_eq!(
            catalog
                .unsubscribe_current_connection(&session("thread-1"))
                .await
                .expect("unsubscribe"),
            CodexUnsubscribeOutcome::Unsubscribed
        );
    }

    #[tokio::test]
    async fn unknown_future_unsubscribe_status_is_not_certified_as_cleanup() {
        let rpc = FakeRpc::new([
            json!({ "thread": thread("thread-1", "/project", json!([])) }),
            json!({ "status": "pendingFutureCleanup" }),
        ]);
        let catalog = CodexSessionCatalog::new(rpc, provider(), workspace(), Path::new("/project"))
            .expect("catalog");

        assert!(matches!(
            catalog
                .unsubscribe_current_connection(&session("thread-1"))
                .await,
            Err(DriverError::Protocol(message))
                if message.contains("unconfirmed thread unsubscribe")
        ));
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore = "reads the authenticated user's installed Codex session catalog"]
    async fn installed_chatgpt_app_server_matches_catalog_contract() {
        use crate::{CodexLaunchConfig, spawn_codex_driver};
        use inline_agent_bridge::AgentDriver;

        let spawned = spawn_codex_driver(
            CodexLaunchConfig {
                executable: std::env::var_os("INLINE_CODEX_SMOKE_EXECUTABLE")
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| "/Applications/ChatGPT.app/Contents/Resources/codex".into()),
                ..CodexLaunchConfig::default()
            },
            "catalog-contract-test",
        )
        .await
        .expect("spawn supervised installed app-server");
        let driver = spawned.driver;

        let workspace_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .expect("workspace root");
        let any_page: ThreadListResponse = serde_json::from_value(
            driver
                .session_catalog_request(
                    "thread/list",
                    json!({
                        "limit": 10,
                        "sortKey": "updated_at",
                        "sortDirection": "desc",
                        "useStateDbOnly": true,
                        "archived": false
                    }),
                )
                .await
                .expect("list any stored session"),
        )
        .expect("stable list response");
        let stored_thread = any_page
            .data
            .iter()
            .find(|thread| {
                matches!(
                    thread.status,
                    CodexThreadStatus::Idle | CodexThreadStatus::NotLoaded
                )
            })
            .expect("at least one idle stored Codex session");
        let stored_catalog = CodexSessionCatalog::new(
            driver.clone(),
            provider(),
            workspace(),
            Path::new(&stored_thread.cwd),
        )
        .expect("stored session catalog");
        stored_catalog
            .read_session(SessionReadRequest {
                session: stored_catalog
                    .provider_session(stored_thread.id.clone())
                    .expect("stored session identity"),
                workspace_id: workspace(),
                window: HistoryWindow::new(5, 32 * 1024),
            })
            .await
            .expect("read stored session");

        let catalog =
            CodexSessionCatalog::new(driver.clone(), provider(), workspace(), workspace_path)
                .expect("catalog");
        assert_eq!(
            catalog.provider_health(&workspace()).await.expect("health"),
            ProviderHealth::Ready
        );
        let page = catalog
            .list_sessions(SessionQuery {
                provider: provider(),
                workspace_id: workspace(),
                cursor: None,
                page_size: SessionPageSize::new(5),
            })
            .await
            .expect("list sessions");
        let _ = page.sessions();

        driver.shutdown().await.expect("stop supervised app-server");
    }
}

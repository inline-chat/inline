//! Provider-session browsing and bounded reply-thread hydration.
//!
//! Codex uses a sequential-continuation beta contract: bounded history is hydrated
//! before the exact provider session is resumed by the existing turn driver.

use std::collections::HashMap;
use std::path::Path;

use inline_agent_bridge::{
    AgentSessionCatalog, DriverError, DriverResult, HistoryWindow, MAX_HISTORY_MESSAGE_LIMIT,
    MAX_HISTORY_TEXT_BYTES, ProviderInstanceRef, ProviderSessionId, ProviderSessionRef,
    SessionAvailability, SessionCapabilities, SessionItem, SessionItemPayload, SessionMessageRole,
    SessionPage, SessionPageCursor, SessionPageSize, SessionQuery, SessionReadRequest,
    SessionSnapshot, SessionSummary, SessionThreadBindOutcome, SessionThreadBinding,
    SessionThreadOpening, TurnId,
};
use inline_agent_driver_codex::CodexSessionCatalog;
use serde::{Deserialize, Serialize};

use super::*;

const CALLBACK_VERSION: u32 = 1;
const ACTION_PREFIX: &str = "bridge_agent_sessions_";
const PICKER_TTL_SECONDS: i64 = 10 * 60;
const PICKER_PAGE_SIZE: usize = SESSION_PICKER_PAGE_SIZE;
const MAX_SESSION_RESULTS: usize = 50;
const SESSION_OPEN_LEASE_SECONDS: i64 = 2 * 60;
const SESSION_OPEN_DEADLINE: Duration = Duration::from_secs(90);
const SESSION_PAGE_DEADLINE: Duration = Duration::from_secs(10);
const SESSION_CATALOG_DEADLINE: Duration = Duration::from_secs(5);
const MAX_CATALOG_PAGE_READS: usize = 5;
const MAX_INLINE_TEXT_UTF16: usize = 100_000;
const MAX_INLINE_TEXT_BYTES: usize = 400_000;
const MAX_BUTTON_TEXT_UTF16: usize = 64;
const AGENT_SESSION_SYNC_BATCH_SIZE: usize = 25;
const FRESH_THREAD_MESSAGE_LIMIT: u32 = 15;

pub(super) trait SessionCatalogSource: AgentDriver {
    fn session_catalog(
        &self,
        provider: ProviderInstanceRef,
        workspace_id: WorkspaceId,
        workspace_path: &Path,
    ) -> DriverResult<Option<Box<dyn AgentSessionCatalog>>>;
}

impl SessionCatalogSource for ProviderDriver {
    fn session_catalog(
        &self,
        provider: ProviderInstanceRef,
        workspace_id: WorkspaceId,
        workspace_path: &Path,
    ) -> DriverResult<Option<Box<dyn AgentSessionCatalog>>> {
        match self {
            Self::Codex(driver) => Ok(Some(Box::new(CodexSessionCatalog::new(
                driver.clone(),
                provider,
                workspace_id,
                workspace_path,
            )?))),
            Self::Acp(_) => Ok(None),
        }
    }
}

#[derive(Clone)]
struct SessionBrowserPicker {
    provider_id: ProviderId,
    workspace_label: String,
    sessions: Vec<SessionSummary>,
    has_older: bool,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SessionBrowserCallbackAction {
    Open { index: usize },
    Confirm { index: usize },
    Page { page: usize },
    LoadOlder { expected_count: usize },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct SessionBrowserCallback {
    version: u32,
    token: String,
    action: SessionBrowserCallbackAction,
}

#[derive(Clone)]
struct SessionBrowserOpen {
    token: String,
    lease_owner: String,
    parent_chat_id: i64,
    picker_message_id: i64,
    workspace_id: WorkspaceId,
    workspace_label: String,
    session: SessionSummary,
    session_index: usize,
    thread_chat_id: Option<i64>,
    confirmed: bool,
}

struct ClaimedSessionBrowserAction {
    lease_owner: String,
    outcome: SessionPickerClaimOutcome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SessionBrowserCommand {
    Sessions,
    Resume,
}

fn presentation_picker(record: &SessionPickerRecord) -> SessionBrowserPicker {
    SessionBrowserPicker {
        provider_id: record.provider_id.clone(),
        workspace_label: record.workspace_label.clone(),
        sessions: record.sessions.clone(),
        has_older: record.catalog_cursor.is_some(),
    }
}

pub(super) async fn handle_session_browser_command<D>(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
) -> Result<bool, Box<dyn std::error::Error>>
where
    D: AgentDriver + SessionCatalogSource + 'static,
{
    let Some(command) = session_browser_command(
        &route.provider_id,
        &record.direction.text,
        &route.bot_username,
    ) else {
        return Ok(false);
    };
    if !ensure_session_command_started(&route.store, record)? {
        return Ok(true);
    }
    let result = handle_session_browser_command_inner(bot, record, route, settings, command).await;
    match result {
        Ok(()) => {
            route.store.complete_inbound(&record.event_id)?;
            Ok(true)
        }
        Err(error) => {
            if let Some(picker) = route
                .store
                .session_picker_for_origin_event(&route.installation_id, &record.event_id)?
                && picker.state == SessionPickerState::Publishing
            {
                route.store.record_session_picker_publication_failure(
                    &picker.callback_token,
                    "Session picker publication failed",
                    now_seconds(),
                )?;
            }
            let diagnostic = safe_diagnostic(&error.to_string());
            eprintln!("Session browser command failed: {diagnostic}");
            // Keep the failure notice in the same durable final-send journal
            // as turn results. A missing send acknowledgement must not consume
            // the command without either a picker or a recoverable response.
            if let Err(delivery_error) = publish_inbound_final_send(
                bot,
                &route.store,
                &record.event_id,
                record.binding.chat_id,
                None,
                "",
                if command == SessionBrowserCommand::Resume {
                    "I couldn’t finish resuming and refreshing this session. Its link is unchanged and no prompt was sent. Try /resume again, or /stop to release Inline’s connection."
                } else {
                    "I couldn’t load provider sessions. If the agent connection restarted, wait a moment and try /sessions again."
                },
                InboundState::Failed,
                Some("session browser command failed"),
            )
            .await
            {
                eprintln!(
                    "Session command failure notice needs recovery: {}",
                    safe_diagnostic(&delivery_error.to_string())
                );
            }
            if session_command_ends_provider_epoch(error.as_ref()) {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "provider connection ended during session command",
                )
                .into());
            }
            Ok(true)
        }
    }
}

fn session_command_ends_provider_epoch(error: &(dyn std::error::Error + 'static)) -> bool {
    error
        .downcast_ref::<DriverError>()
        .is_some_and(DriverError::ends_epoch)
        || matches!(error.downcast_ref::<SessionManagerError>(),
            Some(SessionManagerError::Driver(error)) if error.ends_epoch())
}

pub(super) async fn handle_session_browser_action<D>(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
) -> Result<bool, Box<dyn std::error::Error>>
where
    D: AgentDriver + SessionCatalogSource + 'static,
{
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        action_id,
        data,
        ..
    } = event
    else {
        return Ok(false);
    };
    let Some(callback) = parse_session_browser_callback(action_id, data) else {
        return Ok(false);
    };
    let is_navigation = matches!(
        callback.action,
        SessionBrowserCallbackAction::Page { .. } | SessionBrowserCallbackAction::LoadOlder { .. }
    );
    // Local pages never touch Codex. Loading older results does: cancelling
    // a timed-out provider read must not interrupt a running turn.
    if session_action_uses_provider(callback.action) && settings.turn_active {
        let _ = answer_session_action(
            bot,
            *interaction_id,
            "Finish the active Codex turn, then try this session action again.",
        )
        .await;
        return Ok(true);
    }
    let permit = match route.control_lane.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            let _ = answer_session_action(
                bot,
                *interaction_id,
                "Another session operation is finishing. Try Open again in a moment.",
            )
            .await;
            return Ok(true);
        }
    };
    let Some(claimed) = claim_session_browser_action(route, event, callback.clone())? else {
        drop(permit);
        return handle_session_browser_action_inner(bot, event, route, settings, None).await;
    };
    if !matches!(
        &claimed.outcome,
        SessionPickerClaimOutcome::Claimed(_)
            | SessionPickerClaimOutcome::Resumable(_)
            | SessionPickerClaimOutcome::Navigated(_)
            | SessionPickerClaimOutcome::LoadRequested(_)
    ) {
        drop(permit);
        return handle_session_browser_action_inner(bot, event, route, settings, Some(claimed))
            .await;
    }
    let bot = bot.clone();
    let event = event.clone();
    let route = route.clone();
    let sessions = settings.sessions.clone();
    let active = settings.active.clone();
    let identity = settings.identity.clone();
    let action_chat_id = *chat_id;
    let action_message_id = *message_id;
    let action_interaction_id = *interaction_id;
    let operation_deadline = if is_navigation {
        SESSION_PAGE_DEADLINE
    } else {
        SESSION_OPEN_DEADLINE
    };
    let mut control_epoch = route.control_epoch.subscribe();
    let _ = control_epoch.borrow_and_update();
    tokio::spawn(async move {
        let _permit = permit;
        let runtime = SettingsRuntime {
            sessions: &sessions,
            store: &route.store,
            active: &active,
            identity: &identity,
            turn_active: false,
        };
        let diagnostic = tokio::select! {
            biased;
            changed = control_epoch.changed() => {
                let _ = changed;
                eprintln!("Cancelled a session control operation because the provider epoch ended.");
                return;
            }
            result = tokio::time::timeout(
                operation_deadline,
                handle_session_browser_action_inner(&bot, &event, &route, &runtime, Some(claimed)),
            ) => match result {
                Ok(Ok(_)) => return,
                Ok(Err(error)) => safe_diagnostic(&error.to_string()),
                Err(_) => {
                    // Cancellation cannot tell whether the last remote mutation
                    // committed. Keep Open in its leased state; once the lease
                    // expires, the next tap reconciles durable checkpoints and
                    // idempotent server identities instead of starting blind.
                    eprintln!("Session control operation reached its deadline; waiting for durable reconciliation.");
                    return;
                }
            }
        };
        {
            repair_failed_session_action(
                &bot,
                &route,
                &callback,
                action_chat_id,
                action_message_id,
                action_interaction_id,
                diagnostic,
            )
            .await;
        }
    });
    Ok(true)
}

pub(super) async fn handle_provider_unavailable_session_browser_action(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
) -> Result<bool, Box<dyn std::error::Error>> {
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id,
        action_id,
        data,
        ..
    } = event
    else {
        return Ok(false);
    };
    let Some(callback) = parse_session_browser_callback(action_id, data) else {
        return Ok(false);
    };
    let picker = route.store.session_picker(&callback.token)?;
    let bound_workspace = route
        .store
        .bound_chat_workspace(&route.installation_id, chat_id.get())?;
    let authorized = picker.as_ref().is_some_and(|picker| {
        actor_user_id.get() == route.owner_user_id
            && actor_user_id.get() == picker.owner_user_id
            && picker.installation_id == route.installation_id
            && picker.provider_id == route.provider_id
            && picker.chat_id == chat_id.get()
            && picker.picker_message_id == Some(message_id.get())
            && bound_workspace
                .as_ref()
                .is_some_and(|workspace| workspace.workspace_id == picker.workspace_id)
    });
    let toast = if actor_user_id.get() != route.owner_user_id {
        "Only the bot owner can open these sessions."
    } else if !authorized {
        "This session picker is no longer active. Run /sessions again."
    } else {
        "The local provider is restarting. Try this action again when Codex reconnects."
    };
    answer_session_action(bot, *interaction_id, toast).await?;
    Ok(true)
}

fn claim_session_browser_action(
    route: &InboundRoute,
    event: &ClientEvent,
    callback: SessionBrowserCallback,
) -> Result<Option<ClaimedSessionBrowserAction>, Box<dyn std::error::Error>> {
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id,
        ..
    } = event
    else {
        return Ok(None);
    };
    let Some(bound_workspace) = route
        .store
        .bound_chat_workspace(&route.installation_id, chat_id.get())?
    else {
        return Ok(None);
    };
    let now = now_seconds();
    let lease_owner = format!("session-open-{}", interaction_id.get());
    let action = match callback.action {
        SessionBrowserCallbackAction::Open { index }
        | SessionBrowserCallbackAction::Confirm { index } => SessionPickerAction::Open { index },
        SessionBrowserCallbackAction::Page { page } => SessionPickerAction::Page { page },
        SessionBrowserCallbackAction::LoadOlder { expected_count } => {
            SessionPickerAction::LoadOlder { expected_count }
        }
    };
    let outcome = route.store.claim_session_picker(
        &callback.token,
        action,
        &SessionPickerClaimContext {
            installation_id: route.installation_id.clone(),
            provider_id: route.provider_id.clone(),
            owner_user_id: route.owner_user_id,
            actor_user_id: actor_user_id.get(),
            chat_id: chat_id.get(),
            message_id: message_id.get(),
            workspace_id: bound_workspace.workspace_id,
            lease_owner: lease_owner.clone(),
            now,
            lease_expires_at: now.saturating_add(SESSION_OPEN_LEASE_SECONDS),
        },
    )?;
    Ok(Some(ClaimedSessionBrowserAction {
        lease_owner,
        outcome,
    }))
}

#[allow(clippy::too_many_arguments)]
async fn repair_failed_session_action(
    bot: &InlineClient,
    route: &InboundRoute,
    callback: &SessionBrowserCallback,
    chat_id: InlineId,
    message_id: InlineId,
    interaction_id: InlineId,
    diagnostic: String,
) {
    let lease_owner = format!("session-open-{}", interaction_id.get());
    let repaired = route.store.retry_session_picker_open(
        &callback.token,
        &lease_owner,
        &diagnostic,
        now_seconds(),
    );
    eprintln!("Session picker action failed: {diagnostic}");
    if !matches!(repaired, Ok(true)) {
        return;
    }
    if let Ok(Some(record)) = route.store.session_picker(&callback.token) {
        let card = session_picker_record_card(&record).ok();
        if let Some((text, actions)) = card {
            let _ = edit_interactive_message_with_retry(
                bot,
                EditInteractiveMessageRequest {
                    message: EditMessageRequest {
                        chat_id,
                        message_id,
                        text,
                        external_id: None,
                        parse_markdown: true,
                    },
                    actions,
                },
            )
            .await;
        }
    }
}

async fn handle_session_browser_action_inner<D>(
    bot: &InlineClient,
    event: &ClientEvent,
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
    claimed: Option<ClaimedSessionBrowserAction>,
) -> Result<bool, Box<dyn std::error::Error>>
where
    D: AgentDriver + SessionCatalogSource + 'static,
{
    let ClientEvent::MessageActionInvoked {
        interaction_id,
        chat_id,
        message_id,
        actor_user_id: _,
        action_id,
        data,
        ..
    } = event
    else {
        return Ok(false);
    };
    let Some(callback) = parse_session_browser_callback(action_id, data) else {
        return Ok(false);
    };
    let claimed = match claimed {
        Some(claimed) => claimed,
        None => {
            let Some(claimed) = claim_session_browser_action(route, event, callback.clone())?
            else {
                answer_session_action(
                    bot,
                    *interaction_id,
                    "This session picker is no longer active.",
                )
                .await?;
                return Ok(true);
            };
            claimed
        }
    };
    let lease_owner = claimed.lease_owner;
    let claim = claimed.outcome;
    match claim {
        SessionPickerClaimOutcome::LoadRequested(record) => {
            let result = load_older_session_picker_page(route, settings, &record)
                .await
                .map_err(|error| safe_diagnostic(&error.to_string()));
            let updated = match result {
                Ok(Some(updated)) => updated,
                Ok(None) => {
                    answer_session_action(
                        bot,
                        *interaction_id,
                        "This list changed. Use its latest buttons.",
                    )
                    .await?;
                    return Ok(true);
                }
                Err(error) => {
                    eprintln!(
                        "Session catalog pagination failed: {}",
                        safe_diagnostic(&error.to_string())
                    );
                    answer_session_action(
                        bot,
                        *interaction_id,
                        "Couldn’t load older sessions. The current list is unchanged; try again.",
                    )
                    .await?;
                    return Ok(true);
                }
            };
            let (text, actions) = session_picker_card(
                &callback.token,
                &presentation_picker(&updated),
                updated.page,
            )?;
            let _ = answer_session_action(bot, *interaction_id, "Updated").await;
            edit_interactive_message_with_retry(
                bot,
                EditInteractiveMessageRequest {
                    message: EditMessageRequest {
                        chat_id: *chat_id,
                        message_id: *message_id,
                        text,
                        external_id: None,
                        parse_markdown: true,
                    },
                    actions,
                },
            )
            .await?;
        }
        SessionPickerClaimOutcome::Navigated(record) => {
            let (text, actions) = session_picker_record_card(&record)?;
            let _ = answer_session_action(bot, *interaction_id, "Updated").await;
            edit_interactive_message_with_retry(
                bot,
                EditInteractiveMessageRequest {
                    message: EditMessageRequest {
                        chat_id: *chat_id,
                        message_id: *message_id,
                        text,
                        external_id: None,
                        parse_markdown: true,
                    },
                    actions,
                },
            )
            .await?;
        }
        SessionPickerClaimOutcome::Claimed(record)
        | SessionPickerClaimOutcome::Resumable(record) => {
            let session_index = record
                .selected_index
                .ok_or_else(|| io::Error::other("claimed session picker has no selection"))?;
            let session =
                record.sessions.get(session_index).cloned().ok_or_else(|| {
                    io::Error::other("claimed session picker selection is invalid")
                })?;
            let open = SessionBrowserOpen {
                token: callback.token.clone(),
                lease_owner: lease_owner.clone(),
                parent_chat_id: record.chat_id,
                picker_message_id: message_id.get(),
                workspace_id: record.workspace_id,
                workspace_label: record.workspace_label,
                session,
                session_index,
                thread_chat_id: record.thread_chat_id,
                confirmed: matches!(
                    callback.action,
                    SessionBrowserCallbackAction::Confirm { .. }
                ),
            };
            let _ = answer_session_action(bot, *interaction_id, "Opening…").await;
            let workspace = match route.store.verified_workspace(
                &route.installation_id,
                &open.workspace_id,
                now_seconds(),
            ) {
                Ok(workspace) => workspace,
                Err(StoreError::WorkspaceUnavailable { .. }) => {
                    route.store.retry_session_picker_open(
                        &open.token,
                        &open.lease_owner,
                        "The selected project is unavailable.",
                        now_seconds(),
                    )?;
                    return Ok(true);
                }
                Err(error) => return Err(error.into()),
            };
            let _provider_work_lease = match settings.sessions.try_begin_provider_work() {
                Ok(Some(lease)) => lease,
                Ok(None) => {
                    route.store.retry_session_picker_open(
                        &open.token,
                        &open.lease_owner,
                        "The provider connection is closing.",
                        now_seconds(),
                    )?;
                    let _ = answer_session_action(
                        bot,
                        *interaction_id,
                        "Inline is releasing the provider connection. Try Open again in a moment.",
                    )
                    .await;
                    return Ok(true);
                }
                Err(error) => {
                    answer_session_action(
                        bot,
                        *interaction_id,
                        "The provider connection restarted. Try Open again.",
                    )
                    .await?;
                    return Err(error.into());
                }
            };
            let reverse_binding = route.store.session_thread_binding(open.session.session())?;
            if let Some(binding) = reverse_binding.as_ref()
                && binding.workspace_id() != &open.workspace_id
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "the local session binding belongs to another project",
                )
                .into());
            }
            if reverse_binding.is_none()
                && !route
                    .store
                    .provider_session_binding_chats(open.session.session())?
                    .is_empty()
            {
                route.store.retry_session_picker_open(
                    &open.token,
                    &open.lease_owner,
                    "The session is already open in another Inline conversation.",
                    now_seconds(),
                )?;
                let _ = answer_session_action(
                    bot,
                    *interaction_id,
                    "This session is already open in another Inline conversation.",
                )
                .await;
                return Ok(true);
            }
            let mut checkpoint_thread_chat_id = open.thread_chat_id;
            if let Some(binding) = reverse_binding.as_ref() {
                let canonical_thread_chat_id = binding.thread_chat_id();
                if let Some(checkpoint) = checkpoint_thread_chat_id
                    && checkpoint != canonical_thread_chat_id
                    && !route.store.reconcile_session_picker_open_thread(
                        &open.token,
                        &open.lease_owner,
                        checkpoint,
                        canonical_thread_chat_id,
                        now_seconds(),
                    )?
                {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "the session picker conflicts with its canonical local thread",
                    )
                    .into());
                }
                checkpoint_thread_chat_id = Some(canonical_thread_chat_id);
            } else if checkpoint_thread_chat_id.is_none()
                && open.parent_chat_id != route.owner_dm_chat_id
                && open.confirmed
            {
                checkpoint_thread_chat_id = Some(open.parent_chat_id);
            }
            if let Some(thread_chat_id) = checkpoint_thread_chat_id
                && !route.store.update_session_picker_open_progress(
                    &open.token,
                    &open.lease_owner,
                    Some(thread_chat_id),
                    None,
                    None,
                    now_seconds(),
                )?
            {
                return Err(
                    io::Error::other("session picker could not persist its target thread").into(),
                );
            }
            let Some(catalog) = enabled_catalog(settings, &workspace)? else {
                route.store.retry_session_picker_open(
                    &open.token,
                    &open.lease_owner,
                    "Session continuation is unavailable.",
                    now_seconds(),
                )?;
                let _ = answer_session_action(
                    bot,
                    *interaction_id,
                    "Session continuation is not available yet.",
                )
                .await;
                return Ok(true);
            };
            let provider_health = match classify_session_open_catalog_result(
                &route.provider_id,
                catalog.provider_health(&workspace.workspace_id).await,
            )? {
                Ok(health) => health,
                Err(toast) => {
                    route.store.retry_session_picker_open(
                        &open.token,
                        &open.lease_owner,
                        &toast,
                        now_seconds(),
                    )?;
                    let _ = answer_session_action(bot, *interaction_id, &toast).await;
                    return Ok(true);
                }
            };
            if let Some(toast) = session_open_health_toast(&route.provider_id, provider_health) {
                route.store.retry_session_picker_open(
                    &open.token,
                    &open.lease_owner,
                    &toast,
                    now_seconds(),
                )?;
                let _ = answer_session_action(bot, *interaction_id, &toast).await;
                return Ok(true);
            }
            let owner_control = route.owner_control.as_ref().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    "owner authorization is unavailable for session connection",
                )
            })?;
            let server_canonical_session = if reverse_binding.is_none() {
                canonical_agent_session_lookup(
                    owner_control
                        .connect_agent_session(agent_session_lookup_input(
                            route,
                            open.session.session(),
                            &open.workspace_id,
                        )?)
                        .await?,
                    route.bot_user_id,
                    agent_session_provider(&route.provider_id)?,
                )?
            } else {
                None
            };
            if reverse_binding.is_none()
                && server_canonical_session.is_none()
                && open.parent_chat_id != route.owner_dm_chat_id
                && !open.confirmed
                && thread_needs_explicit_connection(&route.bot_store, open.parent_chat_id).await?
            {
                let (text, actions) = session_connection_confirmation(&open)?;
                answer_session_action(
                    bot,
                    *interaction_id,
                    "Confirm connecting this established thread",
                )
                .await?;
                edit_interactive_message_with_retry(
                    bot,
                    EditInteractiveMessageRequest {
                        message: EditMessageRequest {
                            chat_id: *chat_id,
                            message_id: *message_id,
                            text,
                            external_id: None,
                            parse_markdown: true,
                        },
                        actions,
                    },
                )
                .await?;
                route.store.retry_session_picker_open(
                    &open.token,
                    &open.lease_owner,
                    "Waiting for explicit connection confirmation.",
                    now_seconds(),
                )?;
                return Ok(true);
            }
            let mut prepared = None;
            let mut binding_parent_chat_id = open.parent_chat_id;
            let canonical_target = if let Some(binding) = reverse_binding.as_ref() {
                Some((binding.thread_chat_id(), binding.parent_chat_id()))
            } else if let Some(agent_session) = server_canonical_session.as_ref() {
                let thread_id = connected_agent_session_chat_id(agent_session)?;
                Some((
                    thread_id,
                    session_thread_parent_chat_id(agent_session, thread_id)?,
                ))
            } else {
                None
            };
            if let (Some(checkpoint), Some((canonical_thread_chat_id, _))) =
                (checkpoint_thread_chat_id, canonical_target)
                && checkpoint != canonical_thread_chat_id
            {
                if !route.store.reconcile_session_picker_open_thread(
                    &open.token,
                    &open.lease_owner,
                    checkpoint,
                    canonical_thread_chat_id,
                    now_seconds(),
                )? {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "the session picker conflicts with Inline’s canonical session thread",
                    )
                    .into());
                }
                checkpoint_thread_chat_id = Some(canonical_thread_chat_id);
            }
            let candidate_thread_id = if let Some((thread_id, parent_chat_id)) = canonical_target {
                binding_parent_chat_id = parent_chat_id;
                thread_id
            } else if let Some(thread_id) = checkpoint_thread_chat_id {
                thread_id
            } else if open.parent_chat_id != route.owner_dm_chat_id {
                // An ordinary unbound conversation adopts itself. The owner DM
                // remains the multi-session lobby and creates a child thread.
                open.parent_chat_id
            } else {
                let proposed = SessionThreadOpening::new(
                    open.session.session().clone(),
                    open.workspace_id.clone(),
                    open.parent_chat_id,
                    open.picker_message_id,
                )?;
                let opening = settings
                    .sessions
                    .prepare_session_thread(&proposed, now_seconds())
                    .await?;
                if let Some(binding) = opening.binding() {
                    binding.thread_chat_id()
                } else {
                    let anchor_message_id = opening
                        .opening()
                        .expect("prepared session thread has one state")
                        .anchor_message_id();
                    let provider_label =
                        session_provider_label(open.session.session().provider().provider_id());
                    let thread_id = bot
                        .create_reply_thread(CreateReplyThreadRequest {
                            parent_chat_id: InlineId::new(open.parent_chat_id),
                            parent_message_id: Some(InlineId::new(anchor_message_id)),
                            title: Some(session_thread_title(&open.session)),
                            description: Some(format!(
                                "{provider_label} session in {}",
                                open.workspace_label
                            )),
                            emoji: None,
                            participants: Vec::new(),
                        })
                        .await?
                        .chat_id
                        .get();
                    prepared = Some(opening);
                    thread_id
                }
            };
            if !route.store.update_session_picker_open_progress(
                &open.token,
                &open.lease_owner,
                Some(candidate_thread_id),
                None,
                None,
                now_seconds(),
            )? {
                return Err(
                    io::Error::other("session picker could not persist its target thread").into(),
                );
            }
            let snapshot = match classify_session_open_catalog_result(
                &route.provider_id,
                catalog
                    .read_session(SessionReadRequest {
                        session: open.session.session().clone(),
                        workspace_id: open.workspace_id.clone(),
                        window: HistoryWindow::new(
                            MAX_HISTORY_MESSAGE_LIMIT,
                            MAX_HISTORY_TEXT_BYTES,
                        ),
                    })
                    .await,
            )? {
                Ok(snapshot) => snapshot,
                Err(toast) => {
                    route.store.retry_session_picker_open(
                        &open.token,
                        &open.lease_owner,
                        &toast,
                        now_seconds(),
                    )?;
                    let _ = answer_session_action(bot, *interaction_id, &toast).await;
                    return Ok(true);
                }
            };
            let connected = owner_control
                .connect_agent_session(agent_session_connect_input(
                    route,
                    open.session.session(),
                    &open.workspace_id,
                    candidate_thread_id,
                    None,
                )?)
                .await?;
            let connected_state = connect_agent_session_state(&connected)?;
            if connected_state == proto::ConnectAgentSessionState::ConnectedElsewhere {
                route.store.retry_session_picker_open(
                    &open.token,
                    &open.lease_owner,
                    "The session is already open in another Inline conversation.",
                    now_seconds(),
                )?;
                let _ = answer_session_action(
                    bot,
                    *interaction_id,
                    "This session is already open in another Inline conversation.",
                )
                .await;
                return Ok(true);
            }
            let (agent_session, connected_state) = validated_agent_session_connection(
                connected,
                candidate_thread_id,
                route.bot_user_id,
                agent_session_provider(&route.provider_id)?,
            )?;
            let thread_id = candidate_thread_id;
            if !route.store.update_session_picker_open_progress(
                &open.token,
                &open.lease_owner,
                Some(thread_id),
                Some(agent_session.id),
                None,
                now_seconds(),
            )? {
                return Err(io::Error::other(
                    "session picker could not persist its agent session connection",
                )
                .into());
            }
            let correlation_for_direction = |direction_id: &DirectionId| {
                settings
                    .sessions
                    .driver()
                    .session_input_correlation(direction_id)
                    .map(|correlation| correlation.as_str().to_owned())
            };
            sync_agent_session_snapshot(
                bot,
                agent_session.id,
                &snapshot,
                &AgentSessionHistoryContext {
                    store: &route.store,
                    installation_id: &route.installation_id,
                    workspace_id: &open.workspace_id,
                    thread_id,
                    correlation_for_direction: &correlation_for_direction,
                },
            )
            .await?;
            // Keep the durable picker gate authoritative until history has
            // converged. Exposing the local session binding earlier would let
            // an ordinary phone turn interleave with a partial import.
            let local_outcome = if let Some(opening) = prepared {
                Some(
                    settings
                        .sessions
                        .complete_prepared_session_thread(opening, thread_id, now_seconds())
                        .await?,
                )
            } else if reverse_binding.is_none() {
                Some(
                    settings
                        .sessions
                        .bind_session_thread(
                            &SessionThreadBinding::new(
                                open.session.session().clone(),
                                open.workspace_id.clone(),
                                binding_parent_chat_id,
                                thread_id,
                            )?,
                            now_seconds(),
                        )
                        .await?,
                )
            } else {
                None
            };
            let created = matches!(connected_state, proto::ConnectAgentSessionState::Created)
                || matches!(local_outcome, Some(SessionThreadBindOutcome::Created(_)));
            inherit_session_thread_settings(
                &route.store,
                &route.installation_id,
                binding_parent_chat_id,
                thread_id,
                &open.workspace_id,
            )?;
            let status_message_id = match agent_session.status_message_id {
                Some(message_id) => message_id,
                None => {
                    let message_id = send_agent_session_status_card(
                        bot,
                        thread_id,
                        &open.workspace_label,
                        &open.session,
                        snapshot.has_older(),
                    )
                    .await?;
                    let repaired = owner_control
                        .connect_agent_session(agent_session_connect_input(
                            route,
                            open.session.session(),
                            &open.workspace_id,
                            thread_id,
                            Some(message_id),
                        )?)
                        .await?;
                    validated_agent_session_connection(
                        repaired,
                        thread_id,
                        route.bot_user_id,
                        agent_session_provider(&route.provider_id)?,
                    )?;
                    message_id
                }
            };
            edit_message_with_retry(
                bot,
                EditMessageRequest {
                    chat_id: InlineId::new(thread_id),
                    message_id: InlineId::new(status_message_id),
                    text: agent_session_status_text(
                        &open.workspace_label,
                        &open.session,
                        snapshot.has_older(),
                    ),
                    external_id: None,
                    parse_markdown: true,
                },
            )
            .await?;
            if !route.store.update_session_picker_open_progress(
                &open.token,
                &open.lease_owner,
                Some(thread_id),
                Some(agent_session.id),
                Some(status_message_id),
                now_seconds(),
            )? {
                return Err(io::Error::other(
                    "session picker could not persist its status projection",
                )
                .into());
            }
            let status_pinned = bot
                .pin_message(inline_client::PinMessageRequest {
                    chat_id: InlineId::new(thread_id),
                    message_id: InlineId::new(status_message_id),
                    unpin: false,
                })
                .await
                .is_ok();
            if !route.store.complete_session_picker_open(
                &open.token,
                &open.lease_owner,
                SessionPickerCompletion {
                    thread_chat_id: thread_id,
                    agent_session_id: agent_session.id,
                    status_message_id,
                    status_pinned,
                    completed_at: now_seconds(),
                },
            )? {
                return Err(
                    io::Error::other("session picker completion lost its durable lease").into(),
                );
            }
            if !status_pinned {
                eprintln!(
                    "warning: connected session status pin needs repair for thread {thread_id}"
                );
            } else if created {
                eprintln!("connected provider session in Inline thread {thread_id}");
            }
            edit_session_opened(bot, chat_id.get(), message_id.get(), thread_id).await?;
            if !route
                .store
                .mark_session_picker_terminal_projected(&open.token, now_seconds())?
            {
                return Err(io::Error::other(
                    "session picker terminal projection was not persisted",
                )
                .into());
            }
        }
        SessionPickerClaimOutcome::InProgress(_) => {
            let _ = answer_session_action(bot, *interaction_id, "Opening…").await;
        }
        SessionPickerClaimOutcome::Completed(record) => {
            let _ = answer_session_action(bot, *interaction_id, "Already opened").await;
            repair_completed_session_picker(bot, &route.store, &record).await?;
        }
        SessionPickerClaimOutcome::Unauthorized => {
            let _ = answer_session_action(
                bot,
                *interaction_id,
                "Only the bot owner can open sessions.",
            )
            .await;
        }
        SessionPickerClaimOutcome::Expired(_) => {
            let _ = answer_session_action(
                bot,
                *interaction_id,
                "This session picker has expired. Send /sessions for a fresh list.",
            )
            .await;
        }
        SessionPickerClaimOutcome::Failed(_) => {
            let _ = answer_session_action(
                bot,
                *interaction_id,
                "This session picker failed. Send /sessions for a fresh list.",
            )
            .await;
        }
        SessionPickerClaimOutcome::InvalidChoice => {
            let _ = answer_session_action(bot, *interaction_id,
                "This choice is unavailable or the list changed. Active sessions must finish before opening; send /sessions to refresh.").await;
        }
        SessionPickerClaimOutcome::Unknown | SessionPickerClaimOutcome::WrongContext => {
            let _ = answer_session_action(
                bot,
                *interaction_id,
                "This session picker is no longer active.",
            )
            .await;
        }
    }
    Ok(true)
}

fn session_action_uses_provider(action: SessionBrowserCallbackAction) -> bool {
    !matches!(action, SessionBrowserCallbackAction::Page { .. })
}

async fn read_catalog_page(
    catalog: &dyn AgentSessionCatalog,
    mut query: SessionQuery,
    known: &[SessionSummary],
) -> DriverResult<SessionPage> {
    let known = known
        .iter()
        .map(|summary| summary.session().session_id().as_str())
        .collect::<std::collections::HashSet<_>>();
    let mut seen = std::collections::HashSet::new();
    if let Some(cursor) = query.cursor.as_ref() {
        seen.insert(cursor.to_string());
    }
    for attempt in 0..MAX_CATALOG_PAGE_READS {
        let page = catalog.list_sessions(query.clone()).await?;
        if let Some(cursor) = page.next_cursor()
            && !seen.insert(cursor.to_string())
        {
            return Err(DriverError::Protocol(
                "Codex repeated a session catalog cursor".into(),
            ));
        }
        let has_new = page
            .sessions()
            .iter()
            .any(|summary| !known.contains(summary.session().session_id().as_str()));
        if has_new || page.next_cursor().is_none() || attempt + 1 == MAX_CATALOG_PAGE_READS {
            return Ok(page);
        }
        query.cursor = page.next_cursor().cloned();
    }
    unreachable!("catalog page budget is nonzero")
}

async fn load_older_session_picker_page<D>(
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
    record: &SessionPickerRecord,
) -> Result<Option<SessionPickerRecord>, Box<dyn std::error::Error>>
where
    D: AgentDriver + SessionCatalogSource + 'static,
{
    let _provider_work = settings
        .sessions
        .try_begin_provider_work()?
        .ok_or_else(|| io::Error::other("provider connection is closing"))?;
    let workspace = route.store.verified_workspace(
        &route.installation_id,
        &record.workspace_id,
        now_seconds(),
    )?;
    let catalog = enabled_catalog(settings, &workspace)?
        .ok_or_else(|| io::Error::other("session catalog is unavailable"))?;
    let cursor = record
        .catalog_cursor
        .clone()
        .ok_or_else(|| io::Error::other("session catalog is exhausted"))?;
    let remaining = MAX_SESSION_PICKER_ITEMS.saturating_sub(record.sessions.len());
    if remaining == 0 {
        return Ok(None);
    }
    let page = tokio::time::timeout(
        SESSION_CATALOG_DEADLINE,
        read_catalog_page(
            catalog.as_ref(),
            SessionQuery {
                provider: ProviderInstanceRef::new(
                    route.installation_id.clone(),
                    route.provider_id.clone(),
                )?,
                workspace_id: record.workspace_id.clone(),
                cursor: Some(SessionPageCursor::new(cursor)?),
                page_size: SessionPageSize::new(remaining.min(MAX_SESSION_RESULTS)),
            },
            &record.sessions,
        ),
    )
    .await??;
    Ok(route.store.append_session_picker_sessions(
        record,
        page.sessions(),
        page.next_cursor().map(ToString::to_string),
        now_seconds(),
    )?)
}

async fn resume_linked_session<D>(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
) -> Result<(), Box<dyn std::error::Error>>
where
    D: AgentDriver + SessionCatalogSource + 'static,
{
    if settings.turn_active {
        return send_session_reply(
            bot,
            record,
            "This session is already running in Inline. Use /stop to stop and release it.",
            "resume-running",
        )
        .await;
    }
    let Ok(_control) = route.control_lane.clone().try_acquire_owned() else {
        return send_session_reply(
            bot,
            record,
            "Another session operation is finishing. Try /resume again in a moment.",
            "resume-busy",
        )
        .await;
    };
    let _work = match settings.sessions.try_begin_provider_work()? {
        Some(work) => work,
        None => {
            return send_session_reply(
                bot,
                record,
                "Inline is releasing its Codex connection. Try /resume again in a moment.",
                "resume-closing",
            )
            .await;
        }
    };
    let Some(linked) = route
        .store
        .session_thread_binding_for_chat(&record.binding.installation_id, record.binding.chat_id)?
    else {
        return send_session_reply(bot, record,
            "Open a Codex session from /sessions in the bot’s private DM first, then use /resume in its linked thread.",
            "resume-unlinked").await;
    };
    if linked.workspace_id() != &record.binding.workspace_id
        || linked.session().provider().installation_id() != &route.installation_id
        || linked.session().provider().provider_id() != &route.provider_id
        || route.store.get_binding(&record.binding)?
            != Some((
                route.provider_id.clone(),
                linked.session().session_id().clone(),
            ))
    {
        return Err(
            io::Error::other("saved session link does not match its provider binding").into(),
        );
    }
    settings
        .sessions
        .set_session_history_ready(&record.binding, linked.session().session_id(), false)
        .await;
    let workspace = route.store.verified_workspace(
        &record.binding.installation_id,
        &record.binding.workspace_id,
        now_seconds(),
    )?;
    let Some(catalog) = enabled_catalog(settings, &workspace)? else {
        return send_session_reply(
            bot,
            record,
            "This Codex version cannot safely resume linked sessions. Update Codex and try again.",
            "resume-unsupported",
        )
        .await;
    };
    // Validate the saved identity and workspace before acquiring its writer.
    // Read again after acquisition so external work completed at the boundary
    // is included in the snapshot we publish.
    let request = SessionReadRequest {
        session: linked.session().clone(),
        workspace_id: linked.workspace_id().clone(),
        window: HistoryWindow::new(MAX_HISTORY_MESSAGE_LIMIT, MAX_HISTORY_TEXT_BYTES),
    };
    let result: Result<_, Box<dyn std::error::Error>> = async {
        tokio::time::timeout(
            SESSION_CATALOG_DEADLINE,
            catalog.read_session(request.clone()),
        )
        .await??;
        let prepared = prepare_agent_session_input(
            settings.sessions,
            &route.store,
            route,
            &record.binding,
            record,
        )
        .await?
        .ok_or_else(|| io::Error::other("linked session disappeared"))?;
        let opened = settings
            .sessions
            .ensure_session(&record.binding, now_seconds())
            .await?;
        if opened.session_id() != linked.session().session_id() {
            return Err(io::Error::other("resume returned a different provider session").into());
        }
        let snapshot =
            tokio::time::timeout(SESSION_CATALOG_DEADLINE, catalog.read_session(request)).await??;
        let correlation_for_direction = |direction_id: &DirectionId| {
            settings
                .sessions
                .driver()
                .session_input_correlation(direction_id)
                .map(|correlation| correlation.as_str().to_owned())
        };
        sync_agent_session_snapshot(
            bot,
            prepared.agent_session_id,
            &snapshot,
            &AgentSessionHistoryContext {
                store: &route.store,
                installation_id: &route.installation_id,
                workspace_id: linked.workspace_id(),
                thread_id: record.binding.chat_id,
                correlation_for_direction: &correlation_for_direction,
            },
        )
        .await?;
        if !settings
            .sessions
            .set_session_history_ready(&record.binding, linked.session().session_id(), true)
            .await
        {
            return Err(
                io::Error::other("session changed before history refresh completed").into(),
            );
        }
        Ok(())
    }
    .await;
    match result {
        Ok(()) => send_session_reply(bot, record,
            "Resumed in Inline and refreshed recent history. Send your next message here. Use /stop to release this session for ChatGPT Desktop or Codex CLI.",
            "resumed").await,
        Err(error) => {
            let busy = matches!(error.downcast_ref::<DriverError>(), Some(DriverError::SessionBusy(_)))
                || matches!(error.downcast_ref::<SessionManagerError>(), Some(SessionManagerError::Driver(DriverError::SessionBusy(_))));
            if busy {
                return send_session_reply(bot, record,
                    BridgeNotice::SessionActiveElsewhere.message(), "resume-active-elsewhere").await;
            }
            Err(error)
        }
    }
}

async fn handle_session_browser_command_inner<D>(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
    command: SessionBrowserCommand,
) -> Result<(), Box<dyn std::error::Error>>
where
    D: AgentDriver + SessionCatalogSource + 'static,
{
    let invocation = parse_command(&record.direction.text, &route.bot_username)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing session command"))?;
    if !invocation.arguments.is_empty() {
        return send_session_reply(
            bot,
            record,
            &format!("/{} doesn’t take arguments.", invocation.name),
            "usage",
        )
        .await;
    }
    if record.sender_user_id != route.owner_user_id {
        return send_session_reply(
            bot,
            record,
            "Only the bot owner can browse provider sessions.",
            "owner-only",
        )
        .await;
    }
    if command == SessionBrowserCommand::Resume {
        return resume_linked_session(bot, record, route, settings).await;
    }
    if record.binding.chat_id != route.owner_dm_chat_id {
        return send_session_reply(
            bot,
            record,
            "For privacy, browse provider sessions in your direct chat with this bot.",
            "owner-dm-only",
        )
        .await;
    }
    if let Some(existing) = route
        .store
        .session_picker_for_origin_event(&route.installation_id, &record.event_id)?
    {
        return match existing.state {
            SessionPickerState::Publishing | SessionPickerState::Active => {
                publish_session_picker(bot, record, &route.store, &existing).await
            }
            SessionPickerState::Opening
            | SessionPickerState::Retryable
            | SessionPickerState::Completed => Ok(()),
            SessionPickerState::Expired | SessionPickerState::Failed => {
                send_session_reply(
                    bot,
                    record,
                    "That session picker operation is no longer active. Send /sessions again.",
                    "picker-terminal",
                )
                .await
            }
        };
    }
    if settings.turn_active {
        return send_session_reply(
            bot,
            record,
            "Wait for the current agent response or use /stop, then send /sessions again.",
            "turn-active",
        )
        .await;
    }
    let _provider_work_lease = match settings.sessions.try_begin_provider_work() {
        Ok(Some(lease)) => lease,
        Ok(None) => {
            return send_session_reply(
                bot,
                record,
                "Inline is releasing the provider connection. Try /sessions again in a moment.",
                "connection-closing",
            )
            .await;
        }
        Err(error) => {
            send_session_reply(
                bot,
                record,
                "The provider connection restarted. Try /sessions again.",
                "connection-restarted",
            )
            .await?;
            return Err(error.into());
        }
    };
    let workspace = match route.store.verified_workspace(
        &record.binding.installation_id,
        &record.binding.workspace_id,
        now_seconds(),
    ) {
        Ok(workspace) => workspace,
        Err(StoreError::WorkspaceUnavailable { .. }) => {
            return send_session_reply(
                bot,
                record,
                "The selected project is unavailable. Choose a project with /projects and try again.",
                "workspace-unavailable",
            )
            .await;
        }
        Err(error) => return Err(error.into()),
    };
    let Some(catalog) = enabled_catalog(settings, &workspace)? else {
        return send_session_reply(
            bot,
            record,
            &session_unavailable_message(&route.provider_id),
            "unavailable",
        )
        .await;
    };
    let provider =
        ProviderInstanceRef::new(route.installation_id.clone(), route.provider_id.clone())?;
    let query = SessionQuery {
        provider,
        workspace_id: workspace.workspace_id.clone(),
        cursor: None,
        page_size: SessionPageSize::new(MAX_SESSION_RESULTS),
    };
    let catalog_result = tokio::time::timeout(SESSION_CATALOG_DEADLINE, async {
        let health = catalog.provider_health(&workspace.workspace_id).await?;
        let page = if health == inline_agent_bridge::ProviderHealth::Ready {
            Some(read_catalog_page(catalog.as_ref(), query, &[]).await?)
        } else {
            None
        };
        Ok::<_, DriverError>((health, page))
    })
    .await;
    let (provider_health, page) = match catalog_result {
        Ok(Ok(result)) => result,
        Err(_) | Ok(Err(DriverError::Transient(_))) => {
            return send_session_reply(
                bot,
                record,
                &session_catalog_timeout_message(&route.provider_id),
                "catalog-timeout",
            )
            .await;
        }
        Ok(Err(error)) => return Err(error.into()),
    };
    match provider_health {
        inline_agent_bridge::ProviderHealth::Ready => {}
        inline_agent_bridge::ProviderHealth::Unauthenticated => {
            return send_session_reply(
                bot,
                record,
                &provider_sign_in_message(&route.provider_id),
                "unauthenticated",
            )
            .await;
        }
        inline_agent_bridge::ProviderHealth::UnsupportedVersion => {
            return send_session_reply(
                bot,
                record,
                &format!(
                    "{} needs an update before Inline can browse its sessions.",
                    session_provider_label(&route.provider_id)
                ),
                "unsupported-version",
            )
            .await;
        }
        _ => {
            return send_session_reply(
                bot,
                record,
                &format!(
                    "{} sessions are temporarily unavailable. Try again after the provider reconnects.",
                    session_provider_label(&route.provider_id)
                ),
                "provider-unavailable",
            )
            .await;
        }
    }
    let page = page.expect("ready provider catalog returns a page");
    // Discovery includes busy sessions; only a provider-confirmed available
    // choice can be claimed for Open. Never make running work disappear.
    let sessions = page.sessions().to_vec();
    if sessions.is_empty() {
        if page.next_cursor().is_some() {
            return send_session_reply(
                bot,
                record,
                "Codex’s session catalog is still catching up. Try /sessions again in a moment.",
                "catalog-incomplete",
            )
            .await;
        }
        return send_session_reply(
            bot,
            record,
            &format!(
                "No {} sessions were found for this project. You can chat here to start a new session, or choose another project with /projects.",
                session_provider_label(&route.provider_id)
            ),
            "empty",
        )
        .await;
    }
    let token = generate_control_token();
    let picker_created_at = now_seconds();
    if !route.store.insert_session_picker(&PendingSessionPicker {
        callback_token: token.clone(),
        origin_event_id: record.event_id.clone(),
        installation_id: route.installation_id.clone(),
        provider_id: route.provider_id.clone(),
        owner_user_id: route.owner_user_id,
        chat_id: record.binding.chat_id,
        workspace_id: workspace.workspace_id,
        workspace_label: workspace.display_name,
        sessions,
        catalog_cursor: page.next_cursor().map(ToString::to_string),
        created_at: picker_created_at,
        expires_at: picker_created_at.saturating_add(PICKER_TTL_SECONDS),
    })? {
        if let Some(existing) = route
            .store
            .session_picker_for_origin_event(&route.installation_id, &record.event_id)?
        {
            return match existing.state {
                SessionPickerState::Publishing => {
                    publish_session_picker(bot, record, &route.store, &existing).await
                }
                _ => Ok(()),
            };
        }
        return send_session_reply(
            bot,
            record,
            "Too many session pickers are active. Let an older picker expire and try again.",
            "picker-capacity",
        )
        .await;
    }
    let stored = route
        .store
        .session_picker(&token)?
        .ok_or_else(|| io::Error::other("session picker disappeared before publication"))?;
    publish_session_picker(bot, record, &route.store, &stored).await
}

async fn publish_session_picker(
    bot: &InlineClient,
    record: &InboundRecord,
    store: &BridgeStore,
    picker: &SessionPickerRecord,
) -> Result<(), Box<dyn std::error::Error>> {
    let presentation = presentation_picker(picker);
    let (text, actions) = session_picker_card(&picker.callback_token, &presentation, picker.page)?;
    let reconcile_text = text.clone();
    let reconcile_actions = actions.clone();
    let mut message = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(record.binding.chat_id),
        },
        text,
    );
    message.reply_to_message_id = Some(InlineId::new(record.message_id));
    message.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("{}-provider-sessions", record.event_id),
    )?);
    message.random_id = Some(interaction_random_id(
        "provider-sessions",
        &picker.callback_token,
    ));
    message.parse_markdown = true;
    message.notification_mode = SendNotificationMode::Silent;
    let request = SendInteractiveTextRequest { message, actions };
    let mut confirmed = None;
    let mut last_error: Option<Box<dyn std::error::Error>> = None;
    for attempt in 0..3 {
        match bot.send_interactive_text(request.clone()).await {
            Ok(mutation) if mutation.message_id.is_some() => {
                confirmed = Some(mutation);
                break;
            }
            Ok(_) => {
                last_error = Some(
                    io::Error::other(
                        "session picker send was acknowledged without a message identity",
                    )
                    .into(),
                );
            }
            Err(error) => last_error = Some(error.into()),
        }
        if attempt < 2 {
            tokio::time::sleep(message_retry_delay(attempt)).await;
        }
    }
    let mutation = confirmed.ok_or_else(|| {
        last_error.unwrap_or_else(|| io::Error::other("session picker was not delivered").into())
    })?;
    let message_id = mutation.message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "session picker has no message identity",
        )
    })?;
    if !store.attach_session_picker_message(
        &picker.callback_token,
        message_id.get(),
        now_seconds(),
    )? {
        return Err(io::Error::other("session picker expired before publication").into());
    }
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(record.binding.chat_id),
                message_id,
                text: reconcile_text,
                external_id: None,
                parse_markdown: true,
            },
            actions: reconcile_actions,
        },
    )
    .await?;
    Ok(())
}

pub(super) async fn recover_session_picker_commands(
    bot: &InlineClient,
    store: &BridgeStore,
    installation_id: &InstallationId,
) -> Result<(), Box<dyn std::error::Error>> {
    for picker in store.session_picker_recovery_cards(installation_id)? {
        if let Err(error) = repair_recovered_session_picker_card(bot, store, &picker).await {
            eprintln!(
                "Could not repair an interrupted session picker card: {}",
                safe_diagnostic(&error.to_string())
            );
        }
    }
    for picker in store.recoverable_session_picker_commands(installation_id)? {
        let Some(record) = store.get_inbound(&picker.origin_event_id)? else {
            continue;
        };
        if matches!(
            picker.state,
            SessionPickerState::Publishing | SessionPickerState::Active
        ) && let Err(error) = publish_session_picker(bot, &record, store, &picker).await
        {
            eprintln!(
                "Could not recover a pending session picker publication: {}",
                safe_diagnostic(&error.to_string())
            );
            continue;
        }
        let published_or_terminal = picker.state != SessionPickerState::Publishing
            || store
                .session_picker(&picker.callback_token)?
                .is_some_and(|picker| picker.state == SessionPickerState::Active);
        if published_or_terminal {
            let _ = store.complete_inbound(&picker.origin_event_id)?;
        }
    }
    for picker in store.session_picker_projection_repairs(installation_id)? {
        if let Err(error) = repair_completed_session_picker(bot, store, &picker).await {
            eprintln!(
                "Could not repair a completed session picker projection: {}",
                safe_diagnostic(&error.to_string())
            );
        }
    }
    Ok(())
}

async fn repair_recovered_session_picker_card(
    bot: &InlineClient,
    store: &BridgeStore,
    picker: &SessionPickerRecord,
) -> Result<(), Box<dyn std::error::Error>> {
    let message_id = picker.picker_message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "session picker recovery is missing its message identity",
        )
    })?;
    let (text, actions, terminal) = match picker.state {
        SessionPickerState::Retryable => {
            let (card, actions) = session_picker_record_card(picker)?;
            (card, actions, false)
        }
        SessionPickerState::Failed => (
            "This session did not finish opening. Run /sessions again before sending more messages in its reply thread."
                .to_string(),
            MessageActions { rows: Vec::new() },
            true,
        ),
        SessionPickerState::Expired => (
            "This session picker expired. Run /sessions to load a fresh list.".to_string(),
            MessageActions { rows: Vec::new() },
            true,
        ),
        _ => return Ok(()),
    };
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(picker.chat_id),
                message_id: InlineId::new(message_id),
                text,
                external_id: None,
                parse_markdown: true,
            },
            actions,
        },
    )
    .await?;
    if terminal {
        store.mark_session_picker_terminal_projected(&picker.callback_token, now_seconds())?;
    }
    Ok(())
}

async fn repair_completed_session_picker(
    bot: &InlineClient,
    store: &BridgeStore,
    picker: &SessionPickerRecord,
) -> Result<(), Box<dyn std::error::Error>> {
    let thread_id = picker
        .thread_chat_id
        .ok_or_else(|| io::Error::other("completed session picker is missing its thread"))?;
    let picker_message_id = picker
        .picker_message_id
        .ok_or_else(|| io::Error::other("completed session picker is missing its card message"))?;
    let mut first_error = None;
    if !picker.status_pinned {
        let status_message_id = picker.status_message_id.ok_or_else(|| {
            io::Error::other("completed session picker is missing its status message")
        })?;
        let pin_result = async {
            bot.pin_message(inline_client::PinMessageRequest {
                chat_id: InlineId::new(thread_id),
                message_id: InlineId::new(status_message_id),
                unpin: false,
            })
            .await?;
            if !store.mark_session_picker_status_pinned(&picker.callback_token, now_seconds())? {
                return Err(
                    io::Error::other("session status pin repair lost its operation").into(),
                );
            }
            Ok::<_, Box<dyn std::error::Error>>(())
        }
        .await;
        if let Err(error) = pin_result {
            first_error = Some(safe_diagnostic(&error.to_string()));
        }
    }
    if !picker.terminal_projected {
        let projection_result = async {
            edit_session_opened(bot, picker.chat_id, picker_message_id, thread_id).await?;
            if !store
                .mark_session_picker_terminal_projected(&picker.callback_token, now_seconds())?
            {
                return Err(
                    io::Error::other("session picker card repair lost its operation").into(),
                );
            }
            Ok::<_, Box<dyn std::error::Error>>(())
        }
        .await;
        if let Err(error) = projection_result
            && first_error.is_none()
        {
            first_error = Some(safe_diagnostic(&error.to_string()));
        }
    }
    match first_error {
        Some(error) => Err(io::Error::other(error).into()),
        None => Ok(()),
    }
}

fn enabled_catalog<D>(
    settings: &SettingsRuntime<'_, D>,
    workspace: &WorkspaceRecord,
) -> DriverResult<Option<Box<dyn AgentSessionCatalog>>>
where
    D: AgentDriver + SessionCatalogSource + 'static,
{
    let provider = ProviderInstanceRef::new(
        workspace.installation_id.clone(),
        settings.sessions.provider_id().clone(),
    )
    .map_err(|error| DriverError::Protocol(error.to_string()))?;
    let Some(catalog) = settings.sessions.driver().session_catalog(
        provider,
        workspace.workspace_id.clone(),
        &workspace.path,
    )?
    else {
        return Ok(None);
    };
    if !session_browser_enabled(
        &catalog.session_capabilities(),
        &settings.sessions.driver().capabilities(),
    ) {
        return Ok(None);
    }
    Ok(Some(catalog))
}

fn session_browser_enabled(
    capabilities: &SessionCapabilities,
    turn: &inline_agent_bridge::DriverCapabilities,
) -> bool {
    capabilities.supports_continuation_with(turn)
}

fn session_browser_command(
    provider_id: &ProviderId,
    text: &str,
    bot_username: &str,
) -> Option<SessionBrowserCommand> {
    let command = parse_command(text, bot_username).ok()??;
    if command.explicit_target && !command.targets_this_bot {
        return None;
    }
    match command.name.as_str() {
        "sessions" | "open" => Some(SessionBrowserCommand::Sessions),
        "resume" if provider_id.as_str() == "codex" => Some(SessionBrowserCommand::Resume),
        _ => None,
    }
}

fn session_unavailable_message(provider_id: &ProviderId) -> String {
    if provider_id.as_str() == "codex" {
        "Codex session continuation is not available in this beta build yet. This bot still works as a normal Codex chat."
            .to_string()
    } else if provider_id.as_str() == "claude" {
        "Native Claude session continuation is coming soon. Use /history for a read-only local transcript import; this bot still works as a normal Claude chat."
            .to_string()
    } else {
        format!(
            "Native session continuation is coming soon for {}. This ACP bot still works as a normal chat.",
            provider_display_name(provider_id.as_str()).unwrap_or("this provider")
        )
    }
}

fn ensure_session_command_started(
    store: &BridgeStore,
    record: &InboundRecord,
) -> Result<bool, Box<dyn std::error::Error>> {
    match store.get_inbound(&record.event_id)? {
        Some(existing) if existing.state == InboundState::Started => Ok(true),
        Some(existing) if existing.state == InboundState::Accepted => {
            Ok(store.start_inbound(&record.event_id, now_seconds())?)
        }
        Some(_) => Ok(false),
        None => {
            if !store.accept_inbound(record)? {
                return Ok(false);
            }
            Ok(store.start_inbound(&record.event_id, now_seconds())?)
        }
    }
}

fn session_picker_record_card(
    record: &SessionPickerRecord,
) -> Result<(String, MessageActions), Box<dyn std::error::Error>> {
    if record.state == SessionPickerState::Retryable {
        let index = record
            .selected_index
            .ok_or_else(|| io::Error::other("retryable picker has no selection"))?;
        let session = record
            .sessions
            .get(index)
            .ok_or_else(|| io::Error::other("retryable picker selection is invalid"))?;
        return retry_session_picker_card(&record.callback_token, session, index);
    }
    session_picker_card(
        &record.callback_token,
        &presentation_picker(record),
        record.page,
    )
}

fn retry_session_picker_card(
    token: &str,
    session: &SessionSummary,
    index: usize,
) -> Result<(String, MessageActions), Box<dyn std::error::Error>> {
    Ok((
        format!(
            "Opening **{}** did not finish. Tap **Retry Open** to continue with this session. Run /sessions to choose another session.",
            markdown_escape(&session_thread_title(session))
        ),
        MessageActions {
            rows: vec![MessageActionRow {
                actions: vec![MessageActionButton {
                    action_id: session_open_action_id(index),
                    text: "Retry Open".to_string(),
                    kind: MessageActionKind::Callback {
                        data: session_browser_callback_data(
                            token,
                            SessionBrowserCallbackAction::Open { index },
                        )?,
                    },
                }],
            }],
        },
    ))
}

fn session_picker_card(
    token: &str,
    picker: &SessionBrowserPicker,
    page: usize,
) -> Result<(String, MessageActions), Box<dyn std::error::Error>> {
    let (start, end, page_count) = picker_page(&picker.sessions, page)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid session page"))?;
    let text = format!(
        "Recent {} sessions for **{}** — page {} of {}.\n\nChoose a session to open its recent history, then send a message in the linked thread to continue. Use /projects to switch projects.",
        session_provider_label(&picker.provider_id),
        markdown_escape(&picker.workspace_label),
        page + 1,
        page_count,
    );
    let text = if picker.has_older && picker.sessions.len() >= MAX_SESSION_PICKER_ITEMS {
        format!(
            "{text}\n\nShowing the first {MAX_SESSION_PICKER_ITEMS} sessions for this project; older sessions remain in Codex."
        )
    } else if picker.has_older {
        format!("{text}\n\nOlder sessions are available after the last loaded page.")
    } else {
        text
    };
    let mut rows = picker.sessions[start..end]
        .iter()
        .enumerate()
        .map(|(offset, session)| {
            let index = start + offset;
            Ok(MessageActionRow {
                actions: vec![MessageActionButton {
                    action_id: session_open_action_id(index),
                    text: session_button_text(session, index + 1),
                    kind: MessageActionKind::Callback {
                        data: session_browser_callback_data(
                            token,
                            SessionBrowserCallbackAction::Open { index },
                        )?,
                    },
                }],
            })
        })
        .collect::<Result<Vec<_>, serde_json::Error>>()?;
    let mut navigation = Vec::new();
    if page > 0 {
        navigation.push(MessageActionButton {
            action_id: format!("{ACTION_PREFIX}back"),
            text: "Back".to_string(),
            kind: MessageActionKind::Callback {
                data: session_browser_callback_data(
                    token,
                    SessionBrowserCallbackAction::Page { page: page - 1 },
                )?,
            },
        });
    }
    if end < picker.sessions.len() {
        navigation.push(MessageActionButton {
            action_id: format!("{ACTION_PREFIX}more"),
            text: "Show More".to_string(),
            kind: MessageActionKind::Callback {
                data: session_browser_callback_data(
                    token,
                    SessionBrowserCallbackAction::Page { page: page + 1 },
                )?,
            },
        });
    } else if picker.has_older && picker.sessions.len() < MAX_SESSION_PICKER_ITEMS {
        navigation.push(MessageActionButton {
            action_id: format!("{ACTION_PREFIX}older"),
            text: "Load Older Sessions".to_string(),
            kind: MessageActionKind::Callback {
                data: session_browser_callback_data(
                    token,
                    SessionBrowserCallbackAction::LoadOlder {
                        expected_count: picker.sessions.len(),
                    },
                )?,
            },
        });
    }
    if !navigation.is_empty() {
        rows.push(MessageActionRow {
            actions: navigation,
        });
    }
    Ok((text, MessageActions { rows }))
}

async fn thread_needs_explicit_connection(
    store: &SqliteStore,
    chat_id: i64,
) -> Result<bool, Box<dyn std::error::Error>> {
    let history = store
        .history(HistoryRequest {
            chat_id: InlineId::new(chat_id),
            limit: Some(FRESH_THREAD_MESSAGE_LIMIT),
            before_message_id: None,
            after_message_id: None,
        })
        .await?;
    Ok(history.messages.len() >= FRESH_THREAD_MESSAGE_LIMIT as usize)
}

fn session_connection_confirmation(
    open: &SessionBrowserOpen,
) -> Result<(String, MessageActions), Box<dyn std::error::Error>> {
    let provider = session_provider_label(open.session.session().provider().provider_id());
    let text = format!(
        "This thread already has at least {FRESH_THREAD_MESSAGE_LIMIT} messages. Connect it to **{provider}** session **{}**? Existing messages and participants stay here.",
        markdown_escape(&session_thread_title(&open.session)),
    );
    let actions = MessageActions {
        rows: vec![MessageActionRow {
            actions: vec![MessageActionButton {
                action_id: format!("{ACTION_PREFIX}confirm"),
                text: "Connect This Thread".to_string(),
                kind: MessageActionKind::Callback {
                    data: session_browser_callback_data(
                        &open.token,
                        SessionBrowserCallbackAction::Confirm {
                            index: open.session_index,
                        },
                    )?,
                },
            }],
        }],
    };
    Ok((text, actions))
}

fn picker_page(sessions: &[SessionSummary], page: usize) -> Option<(usize, usize, usize)> {
    if sessions.is_empty() {
        return None;
    }
    let page_count = sessions.len().div_ceil(PICKER_PAGE_SIZE);
    if page >= page_count {
        return None;
    }
    let start = page.checked_mul(PICKER_PAGE_SIZE)?;
    let end = start.saturating_add(PICKER_PAGE_SIZE).min(sessions.len());
    Some((start, end, page_count))
}

fn session_button_text(session: &SessionSummary, ordinal: usize) -> String {
    let label = session
        .title()
        .or_else(|| session.preview())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            format!(
                "{} session {ordinal}",
                session_provider_label(session.session().provider().provider_id())
            )
        });
    let suffix = match session.availability() {
        SessionAvailability::Active => " · Active",
        SessionAvailability::ActiveElsewhere => " · Active elsewhere",
        SessionAvailability::Unavailable => " · Unavailable",
        SessionAvailability::Unknown => " · Status unavailable",
        SessionAvailability::Available => "",
    };
    truncate_utf16(
        &label,
        MAX_BUTTON_TEXT_UTF16.saturating_sub(suffix.encode_utf16().count()),
    ) + suffix
}

fn session_thread_title(session: &SessionSummary) -> String {
    session
        .title()
        .or_else(|| session.preview())
        .map(|title| truncate(title, 90))
        .unwrap_or_else(|| {
            format!(
                "{} session",
                session_provider_label(session.session().provider().provider_id())
            )
        })
}

fn session_provider_label(provider_id: &ProviderId) -> &'static str {
    provider_display_name(provider_id.as_str()).unwrap_or("Agent")
}

fn provider_sign_in_message(provider_id: &ProviderId) -> String {
    if provider_id.as_str() == "codex" {
        "Sign in to Codex using Codex or ChatGPT, then try again.".to_string()
    } else {
        format!(
            "Sign in to {} using its native app or CLI, then try again.",
            session_provider_label(provider_id)
        )
    }
}

fn session_catalog_timeout_message(provider_id: &ProviderId) -> String {
    format!(
        "{} took too long to load sessions, so its connection is restarting. Try /sessions again in a moment.",
        session_provider_label(provider_id)
    )
}

fn classify_session_open_catalog_result<T>(
    provider_id: &ProviderId,
    result: DriverResult<T>,
) -> DriverResult<Result<T, String>> {
    match result {
        Ok(value) => Ok(Ok(value)),
        Err(DriverError::Transient(_)) => Ok(Err(format!(
            "{} took too long to open this session. Try Open again.",
            session_provider_label(provider_id)
        ))),
        Err(error) => Err(error),
    }
}

fn session_open_health_toast(
    provider_id: &ProviderId,
    health: inline_agent_bridge::ProviderHealth,
) -> Option<String> {
    match health {
        inline_agent_bridge::ProviderHealth::Ready => None,
        inline_agent_bridge::ProviderHealth::Unauthenticated => {
            Some(provider_sign_in_message(provider_id))
        }
        inline_agent_bridge::ProviderHealth::UnsupportedVersion => Some(format!(
            "{} needs an update before Inline can open this session.",
            session_provider_label(provider_id)
        )),
        _ => Some(format!(
            "{} sessions are temporarily unavailable. Try Open again after the provider reconnects.",
            session_provider_label(provider_id)
        )),
    }
}

fn session_browser_callback_data(
    token: &str,
    action: SessionBrowserCallbackAction,
) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(&SessionBrowserCallback {
        version: CALLBACK_VERSION,
        token: token.to_string(),
        action,
    })
}

fn session_open_action_id(index: usize) -> String {
    format!("{ACTION_PREFIX}open_{index}")
}

fn parse_session_browser_callback(action_id: &str, data: &[u8]) -> Option<SessionBrowserCallback> {
    let callback = serde_json::from_slice::<SessionBrowserCallback>(data)
        .ok()
        .filter(|callback| callback.version == CALLBACK_VERSION)?;
    let matching_action = match callback.action {
        SessionBrowserCallbackAction::Open { index } => action_id == session_open_action_id(index),
        SessionBrowserCallbackAction::Confirm { .. } => {
            action_id == format!("{ACTION_PREFIX}confirm")
        }
        SessionBrowserCallbackAction::Page { .. } => {
            action_id == format!("{ACTION_PREFIX}back")
                || action_id == format!("{ACTION_PREFIX}more")
        }
        SessionBrowserCallbackAction::LoadOlder { .. } => {
            action_id == format!("{ACTION_PREFIX}older")
        }
    };
    matching_action.then_some(callback)
}

fn inherit_session_thread_settings(
    store: &BridgeStore,
    installation_id: &InstallationId,
    parent_chat_id: i64,
    thread_chat_id: i64,
    workspace_id: &WorkspaceId,
) -> Result<(), StoreError> {
    let source = BindingKey {
        installation_id: installation_id.clone(),
        chat_id: parent_chat_id,
        workspace_id: workspace_id.clone(),
    };
    let target = BindingKey {
        installation_id: installation_id.clone(),
        chat_id: thread_chat_id,
        workspace_id: workspace_id.clone(),
    };
    let now = now_seconds();
    let _ = store.chat_settings(&source, now)?;
    let _ = store.inherit_chat_settings(&source, &target, now)?;
    Ok(())
}

fn agent_session_connect_input(
    route: &InboundRoute,
    session: &ProviderSessionRef,
    workspace_id: &WorkspaceId,
    chat_id: i64,
    status_message_id: Option<i64>,
) -> io::Result<proto::ConnectAgentSessionInput> {
    if chat_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid Inline thread",
        ));
    }
    let provider = agent_session_provider(session.provider().provider_id())?;
    Ok(proto::ConnectAgentSessionInput {
        peer_id: agent_session_peer(chat_id),
        bot_user_id: route.bot_user_id,
        provider: provider as i32,
        instance_ref: session.provider().installation_id().as_str().to_owned(),
        session_ref: session.session_id().as_str().to_owned(),
        project_ref: Some(workspace_id.as_str().to_owned()),
        status_message_id,
    })
}

fn agent_session_lookup_input(
    route: &InboundRoute,
    session: &ProviderSessionRef,
    workspace_id: &WorkspaceId,
) -> io::Result<proto::ConnectAgentSessionInput> {
    let provider = agent_session_provider(session.provider().provider_id())?;
    Ok(proto::ConnectAgentSessionInput {
        peer_id: None,
        bot_user_id: route.bot_user_id,
        provider: provider as i32,
        instance_ref: session.provider().installation_id().as_str().to_owned(),
        session_ref: session.session_id().as_str().to_owned(),
        project_ref: Some(workspace_id.as_str().to_owned()),
        status_message_id: None,
    })
}

fn agent_session_provider(provider_id: &ProviderId) -> io::Result<proto::AgentSessionProvider> {
    let provider = match provider_id.as_str() {
        "codex" => proto::AgentSessionProvider::Codex,
        "codex-cloud" | "codex_cloud" => proto::AgentSessionProvider::CodexCloud,
        "claude" => proto::AgentSessionProvider::Claude,
        "open-code" | "open_code" | "opencode" => proto::AgentSessionProvider::OpenCode,
        "amp" => proto::AgentSessionProvider::Amp,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "this provider does not implement Inline agent sessions",
            ));
        }
    };
    Ok(provider)
}

fn agent_session_peer(chat_id: i64) -> Option<proto::InputPeer> {
    Some(proto::InputPeer {
        r#type: Some(proto::input_peer::Type::Chat(proto::InputPeerChat {
            chat_id,
        })),
    })
}

fn connected_agent_session_chat_id(
    session: &proto::AgentSession,
) -> Result<i64, Box<dyn std::error::Error>> {
    let chat_id = match session
        .peer_id
        .as_ref()
        .and_then(|peer| peer.r#type.as_ref())
    {
        Some(proto::peer::Type::Chat(chat)) => chat.chat_id,
        Some(proto::peer::Type::User(_)) | None => 0,
    };
    if chat_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an invalid agent session thread",
        )
        .into());
    }
    Ok(chat_id)
}

fn connect_agent_session_state(
    result: &proto::ConnectAgentSessionResult,
) -> Result<proto::ConnectAgentSessionState, Box<dyn std::error::Error>> {
    proto::ConnectAgentSessionState::try_from(result.state).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an unknown agent session connection state",
        )
        .into()
    })
}

fn canonical_agent_session_lookup(
    result: proto::ConnectAgentSessionResult,
    expected_bot_user_id: i64,
    expected_provider: proto::AgentSessionProvider,
) -> Result<Option<proto::AgentSession>, Box<dyn std::error::Error>> {
    match (connect_agent_session_state(&result)?, result.agent_session) {
        (proto::ConnectAgentSessionState::Unspecified, None) => Ok(None),
        (proto::ConnectAgentSessionState::AlreadyConnected, Some(session)) => {
            connected_agent_session_chat_id(&session)?;
            validate_agent_session_identity(&session, expected_bot_user_id, expected_provider)?;
            Ok(Some(session))
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an inconsistent agent session lookup",
        )
        .into()),
    }
}

fn validated_agent_session_connection(
    result: proto::ConnectAgentSessionResult,
    expected_chat_id: i64,
    expected_bot_user_id: i64,
    expected_provider: proto::AgentSessionProvider,
) -> Result<(proto::AgentSession, proto::ConnectAgentSessionState), Box<dyn std::error::Error>> {
    let state = connect_agent_session_state(&result)?;
    if !matches!(
        state,
        proto::ConnectAgentSessionState::Created
            | proto::ConnectAgentSessionState::AlreadyConnected
    ) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline did not confirm the requested agent session connection",
        )
        .into());
    }
    let session = result.agent_session.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an empty agent session connection",
        )
    })?;
    validate_agent_session_identity(&session, expected_bot_user_id, expected_provider)?;
    if connected_agent_session_chat_id(&session)? != expected_chat_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an agent session for another conversation",
        )
        .into());
    }
    Ok((session, state))
}

fn validate_agent_session_identity(
    session: &proto::AgentSession,
    expected_bot_user_id: i64,
    expected_provider: proto::AgentSessionProvider,
) -> Result<(), Box<dyn std::error::Error>> {
    if session.id <= 0
        || session.bot_user_id != expected_bot_user_id
        || session.provider != expected_provider as i32
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an agent session for another bot or provider",
        )
        .into());
    }
    Ok(())
}

fn session_thread_parent_chat_id(
    session: &proto::AgentSession,
    thread_chat_id: i64,
) -> Result<i64, Box<dyn std::error::Error>> {
    if let Some(parent_chat_id) = session.parent_chat_id {
        if parent_chat_id <= 0 || parent_chat_id == thread_chat_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Inline returned an invalid agent session parent",
            )
            .into());
        }
        return Ok(parent_chat_id);
    }
    // SdkBackend resolves absent parent metadata through GetChat for older
    // servers. Absence now means an authoritative top-level conversation.
    Ok(thread_chat_id)
}

pub(super) struct PreparedAgentSessionInput {
    pub(super) agent_session_id: i64,
    correlation: inline_agent_bridge::SessionInputCorrelation,
}

/// Resolve and validate the exact session before sending provider work, without
/// claiming that the provider has accepted this prompt yet.
pub(super) async fn prepare_agent_session_input<D: AgentDriver + 'static>(
    sessions: &ProviderSessionManager<D>,
    store: &BridgeStore,
    route: &InboundRoute,
    binding: &BindingKey,
    record: &InboundRecord,
) -> Result<Option<PreparedAgentSessionInput>, Box<dyn std::error::Error>> {
    let owner_control = route.owner_control.as_ref().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotConnected,
            "owner authorization is unavailable for agent session input",
        )
    })?;
    let (session_thread, recovered_agent_session) =
        match store.session_thread_binding_for_chat(&binding.installation_id, binding.chat_id)? {
            Some(session_thread) => (session_thread, None),
            None => {
                let Some((session_thread, agent_session)) =
                    recover_agent_session_binding(owner_control, route, binding).await?
                else {
                    return Ok(None);
                };
                sessions
                    .bind_session_thread(&session_thread, now_seconds())
                    .await?;
                (session_thread, Some(agent_session))
            }
        };
    let Some(correlation) = sessions
        .driver()
        .session_input_correlation(&record.direction.id)
    else {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "this provider cannot correlate Inline prompts with session history",
        )
        .into());
    };
    let agent_session = if let Some(agent_session) = recovered_agent_session {
        agent_session
    } else {
        validated_agent_session_connection(
            owner_control
                .connect_agent_session(agent_session_connect_input(
                    route,
                    session_thread.session(),
                    session_thread.workspace_id(),
                    binding.chat_id,
                    None,
                )?)
                .await?,
            binding.chat_id,
            route.bot_user_id,
            agent_session_provider(&route.provider_id)?,
        )?
        .0
    };
    Ok(Some(PreparedAgentSessionInput {
        agent_session_id: agent_session.id,
        correlation,
    }))
}

/// Only called after provider acceptance. If this projection RPC fails, the
/// existing durable inbound/correlation is repaired by the next history resync.
pub(super) async fn link_accepted_agent_session_input(
    bot: &InlineClient,
    prepared: &PreparedAgentSessionInput,
    message_id: i64,
) -> Result<(), Box<dyn std::error::Error>> {
    let result = bot
        .sync_agent_session_messages(proto::SyncAgentSessionMessagesInput {
            agent_session_id: prepared.agent_session_id,
            mode: proto::AgentSessionSyncMode::Live as i32,
            messages: vec![proto::AgentSessionMessageSync {
                role: proto::AgentSessionMessageRole::User as i32,
                item_ref: None,
                correlation_ref: Some(prepared.correlation.as_str().to_owned()),
                source_date: None,
                revision_ref: None,
                base_revision_ref: None,
                complete: false,
                operation: Some(proto::agent_session_message_sync::Operation::Link(
                    proto::AgentSessionMessageLink { message_id },
                )),
            }],
        })
        .await?;
    let accepted = result.messages.len() == 1
        && matches!(
            proto::AgentSessionMessageSyncState::try_from(result.messages[0].state),
            Ok(proto::AgentSessionMessageSyncState::Linked)
                | Ok(proto::AgentSessionMessageSyncState::Unchanged)
        );
    if !accepted {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline could not link this prompt to its agent session",
        )
        .into());
    }
    Ok(())
}

async fn recover_agent_session_binding(
    owner_control: &OwnerControl,
    route: &InboundRoute,
    binding: &BindingKey,
) -> Result<Option<(SessionThreadBinding, proto::AgentSession)>, Box<dyn std::error::Error>> {
    let recovered = owner_control
        .get_agent_session(proto::GetAgentSessionInput {
            peer_id: agent_session_peer(binding.chat_id),
            bot_user_id: route.bot_user_id,
        })
        .await?;
    let Some(connection) = recovered.connection else {
        return Ok(None);
    };
    let agent_session = connection.agent_session.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an incomplete agent session connection",
        )
    })?;
    validate_agent_session_identity(
        &agent_session,
        route.bot_user_id,
        agent_session_provider(&route.provider_id)?,
    )?;
    if connected_agent_session_chat_id(&agent_session)? != binding.chat_id
        || agent_session.provider != agent_session_provider(&route.provider_id)? as i32
        || connection.instance_ref != route.installation_id.as_str()
        || connection.project_ref.as_deref() != Some(binding.workspace_id.as_str())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the durable Inline agent session does not match this bridge workspace",
        )
        .into());
    }
    let provider =
        ProviderInstanceRef::new(route.installation_id.clone(), route.provider_id.clone())?;
    let session =
        ProviderSessionRef::new(provider, ProviderSessionId::new(connection.session_ref)?)?;
    let session_thread = SessionThreadBinding::new(
        session,
        binding.workspace_id.clone(),
        session_thread_parent_chat_id(&agent_session, binding.chat_id)?,
        binding.chat_id,
    )?;
    Ok(Some((session_thread, agent_session)))
}

pub(super) async fn link_agent_session_assistant_output(
    bot: &InlineClient,
    agent_session_id: i64,
    turn_id: &TurnId,
    message_id: i64,
) -> Result<(), Box<dyn std::error::Error>> {
    let result = bot
        .sync_agent_session_messages(proto::SyncAgentSessionMessagesInput {
            agent_session_id,
            mode: proto::AgentSessionSyncMode::Live as i32,
            messages: vec![proto::AgentSessionMessageSync {
                role: proto::AgentSessionMessageRole::Assistant as i32,
                item_ref: None,
                correlation_ref: Some(agent_output_correlation(turn_id)),
                source_date: None,
                revision_ref: None,
                base_revision_ref: None,
                complete: true,
                operation: Some(proto::agent_session_message_sync::Operation::Link(
                    proto::AgentSessionMessageLink { message_id },
                )),
            }],
        })
        .await?;
    if result.messages.len() != 1
        || !matches!(
            proto::AgentSessionMessageSyncState::try_from(result.messages[0].state),
            Ok(proto::AgentSessionMessageSyncState::Linked)
                | Ok(proto::AgentSessionMessageSyncState::Unchanged)
        )
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline could not link the agent response to its session",
        )
        .into());
    }
    Ok(())
}

fn agent_output_correlation(turn_id: &TurnId) -> String {
    format!("inline-agent-output:v1:{}", turn_id.as_str())
}

pub(super) fn assistant_final_random_id(turn_id: &TurnId) -> RandomId {
    interaction_random_id("agent-session-final", &agent_output_correlation(turn_id))
}

fn bounded_agent_message_text(text: &str) -> String {
    const TRUNCATED: &str = "\n\n[Turn truncated by Inline’s beta message limit.]";
    if text.encode_utf16().count() <= MAX_INLINE_TEXT_UTF16 && text.len() <= MAX_INLINE_TEXT_BYTES {
        return text.to_owned();
    }
    let maximum_utf16 = MAX_INLINE_TEXT_UTF16.saturating_sub(TRUNCATED.encode_utf16().count());
    let maximum_bytes = MAX_INLINE_TEXT_BYTES.saturating_sub(TRUNCATED.len());
    let prefix = text_chunks(text, maximum_utf16, maximum_bytes)
        .into_iter()
        .next()
        .unwrap_or_default();
    format!("{prefix}{TRUNCATED}")
}

struct AgentSessionHistoryContext<'a> {
    store: &'a BridgeStore,
    installation_id: &'a InstallationId,
    workspace_id: &'a WorkspaceId,
    thread_id: i64,
    correlation_for_direction: &'a (dyn Fn(&DirectionId) -> Option<String> + Send + Sync),
}

async fn sync_agent_session_snapshot(
    bot: &InlineClient,
    agent_session_id: i64,
    snapshot: &SessionSnapshot,
    context: &AgentSessionHistoryContext<'_>,
) -> Result<(), Box<dyn std::error::Error>> {
    if agent_session_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Inline returned an invalid agent session identity",
        )
        .into());
    }
    let last_assistant_items = snapshot
        .items()
        .iter()
        .filter_map(|item| match (&item.run_id, &item.payload) {
            (
                Some(turn_id),
                SessionItemPayload::Message {
                    role: SessionMessageRole::Assistant,
                    ..
                },
            ) => Some((turn_id.as_str().to_owned(), item.key.as_str().to_owned())),
            _ => None,
        })
        .collect::<HashMap<_, _>>();
    let mut legacy_user_item_counts = HashMap::<(&str, &str), usize>::new();
    for item in snapshot.items() {
        let (
            Some(turn_id),
            SessionItemPayload::Message {
                role: SessionMessageRole::User,
                text,
                ..
            },
        ) = (&item.run_id, &item.payload)
        else {
            continue;
        };
        if item.confirmed_inline_echo().is_none() {
            *legacy_user_item_counts
                .entry((turn_id.as_str(), text.as_str()))
                .or_default() += 1;
        }
    }
    let mut messages = Vec::new();
    for item in snapshot.items() {
        let SessionItemPayload::Message {
            role,
            text,
            created_at,
        } = &item.payload
        else {
            continue;
        };
        let role = match role {
            SessionMessageRole::User => proto::AgentSessionMessageRole::User,
            SessionMessageRole::Assistant => {
                if item.run_id.as_ref().is_some_and(|turn_id| {
                    last_assistant_items
                        .get(turn_id.as_str())
                        .is_some_and(|key| key != item.key.as_str())
                }) {
                    continue;
                }
                proto::AgentSessionMessageRole::Assistant
            }
            SessionMessageRole::System => continue,
        };
        let known_inline_history = match role {
            proto::AgentSessionMessageRole::User => known_inline_user_history(
                item,
                item.run_id.as_ref().is_some_and(|turn_id| {
                    legacy_user_item_counts
                        .get(&(turn_id.as_str(), text.as_str()))
                        .copied()
                        == Some(1)
                }),
                context,
            )?,
            proto::AgentSessionMessageRole::Assistant
            | proto::AgentSessionMessageRole::Unspecified => None,
        };
        if role == proto::AgentSessionMessageRole::User
            && item.confirmed_inline_echo().is_some()
            && known_inline_history.is_none()
        {
            // A confirmed Inline echo is never safe to re-import from its
            // provider-facing text. The local source row is authoritative and
            // may contain a bridge envelope or private specialization. If the
            // local bridge store was lost, the original Inline message remains
            // visible and the server's correlation ledger still deduplicates
            // future delivery; omit the echo rather than duplicate or expose it.
            continue;
        }
        let text = bounded_agent_message_text(
            known_inline_history
                .as_ref()
                .map_or(text.as_str(), |history| history.text.as_str()),
        );
        let assistant_random_id = match (&item.run_id, role) {
            (Some(turn_id), proto::AgentSessionMessageRole::Assistant) => {
                known_inline_assistant_random_id(context, turn_id)?
                    .or_else(|| Some(assistant_final_random_id(turn_id).get()))
            }
            _ => None,
        };
        let linked_user_message = known_inline_history
            .as_ref()
            .and_then(|history| history.linked_message_id);
        let (correlation_ref, source_date, revision_ref, operation) =
            if let Some(message_id) = linked_user_message {
                let Some(correlation_ref) = known_inline_history
                    .as_ref()
                    .and_then(|history| history.correlation_ref.clone())
                else {
                    // This row already exists in the adopted Inline thread. If
                    // the driver cannot provide its provider-visible identity,
                    // leaving it unprojected is safer than duplicating it.
                    continue;
                };
                (
                    Some(correlation_ref),
                    None,
                    None,
                    proto::agent_session_message_sync::Operation::Link(
                        proto::AgentSessionMessageLink { message_id },
                    ),
                )
            } else {
                if created_at.is_none() && assistant_random_id.is_none() {
                    continue;
                }
                (
                    match role {
                        proto::AgentSessionMessageRole::User => known_inline_history
                            .as_ref()
                            .and_then(|history| history.correlation_ref.clone()),
                        proto::AgentSessionMessageRole::Assistant => {
                            item.run_id.as_ref().map(agent_output_correlation)
                        }
                        proto::AgentSessionMessageRole::Unspecified => None,
                    },
                    *created_at,
                    Some(agent_item_revision(item, &text)),
                    proto::agent_session_message_sync::Operation::Upsert(
                        proto::AgentSessionMessageUpsert {
                            text,
                            entities: None,
                            assistant_random_id,
                        },
                    ),
                )
            };
        messages.push(proto::AgentSessionMessageSync {
            role: role as i32,
            item_ref: Some(item.key.as_str().to_owned()),
            correlation_ref,
            source_date,
            revision_ref,
            base_revision_ref: None,
            complete: true,
            operation: Some(operation),
        });
    }
    sync_agent_session_items(bot, agent_session_id, messages).await?;
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct KnownInlineUserHistory {
    text: String,
    correlation_ref: Option<String>,
    linked_message_id: Option<i64>,
}

fn known_inline_user_history(
    item: &SessionItem,
    allow_legacy_turn_match: bool,
    context: &AgentSessionHistoryContext<'_>,
) -> Result<Option<KnownInlineUserHistory>, StoreError> {
    let record = if let Some(direction_id) = item.confirmed_inline_echo() {
        context
            .store
            .get_inbound(direction_id.as_str())?
            .filter(|record| record.direction.id == *direction_id)
    } else if allow_legacy_turn_match {
        let (
            Some(turn_id),
            SessionItemPayload::Message {
                role: SessionMessageRole::User,
                text,
                ..
            },
        ) = (&item.run_id, &item.payload)
        else {
            return Ok(None);
        };
        context.store.completed_inbound_for_provider_turn_input(
            turn_id,
            &BindingKey {
                installation_id: context.installation_id.clone(),
                chat_id: context.thread_id,
                workspace_id: context.workspace_id.clone(),
            },
            text,
        )?
    } else {
        None
    };
    let Some(record) = record else {
        return Ok(None);
    };
    if record.binding.installation_id != *context.installation_id
        || record.binding.workspace_id != *context.workspace_id
    {
        return Ok(None);
    }
    let same_thread =
        record.binding.chat_id == context.thread_id && record.delivery_chat_id == context.thread_id;
    if !same_thread {
        return Ok(None);
    }
    let correlation_ref = item
        .confirmed_inline_correlation()
        .map(|correlation| correlation.as_str().to_owned())
        .or_else(|| (context.correlation_for_direction)(&record.direction.id));
    Ok(Some(KnownInlineUserHistory {
        text: record.direction.text,
        correlation_ref,
        linked_message_id: Some(record.message_id),
    }))
}

fn known_inline_assistant_random_id(
    context: &AgentSessionHistoryContext<'_>,
    turn_id: &TurnId,
) -> Result<Option<i64>, StoreError> {
    context
        .store
        .completed_terminal_random_id_for_provider_turn(
            turn_id,
            &BindingKey {
                installation_id: context.installation_id.clone(),
                chat_id: context.thread_id,
                workspace_id: context.workspace_id.clone(),
            },
        )
}

async fn sync_agent_session_items(
    bot: &InlineClient,
    agent_session_id: i64,
    messages: Vec<proto::AgentSessionMessageSync>,
) -> Result<(), Box<dyn std::error::Error>> {
    if messages.is_empty() {
        return Ok(());
    }
    for batch in messages.chunks(AGENT_SESSION_SYNC_BATCH_SIZE) {
        let result = bot
            .sync_agent_session_messages(proto::SyncAgentSessionMessagesInput {
                agent_session_id,
                mode: proto::AgentSessionSyncMode::History as i32,
                messages: batch.to_vec(),
            })
            .await?;
        if result.messages.len() != batch.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Inline returned an incomplete agent history result",
            )
            .into());
        }
        for outcome in result.messages {
            match proto::AgentSessionMessageSyncState::try_from(outcome.state) {
                Ok(proto::AgentSessionMessageSyncState::Created)
                | Ok(proto::AgentSessionMessageSyncState::Edited)
                | Ok(proto::AgentSessionMessageSyncState::Linked)
                | Ok(proto::AgentSessionMessageSyncState::Unchanged)
                | Ok(proto::AgentSessionMessageSyncState::Stale)
                | Ok(proto::AgentSessionMessageSyncState::Tombstoned) => {}
                Ok(proto::AgentSessionMessageSyncState::Conflict)
                | Ok(proto::AgentSessionMessageSyncState::Unspecified)
                | Err(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "agent history conflicted with its existing Inline ledger; the stored row was preserved",
                    )
                    .into());
                }
            }
        }
    }
    Ok(())
}

fn stable_session_token(session: &ProviderSessionRef) -> String {
    stable_hash(&[
        "inline-provider-session-v1",
        session.provider().installation_id().as_str(),
        session.provider().provider_id().as_str(),
        session.session_id().as_str(),
    ])
}

fn agent_item_revision(item: &SessionItem, text: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"inline-agent-session-item-revision-v1\0");
    digest.update(item.key.as_str().as_bytes());
    digest.update([0]);
    digest.update(item.revision.get().to_be_bytes());
    digest.update([0]);
    digest.update(text.as_bytes());
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn stable_hash(values: &[&str]) -> String {
    let mut digest = Sha256::new();
    for value in values {
        digest.update([0]);
        digest.update(value.as_bytes());
    }
    digest.finalize()[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

async fn send_agent_session_status_card(
    bot: &InlineClient,
    chat_id: i64,
    workspace_label: &str,
    summary: &SessionSummary,
    history_incomplete: bool,
) -> Result<i64, Box<dyn std::error::Error>> {
    let session_token = stable_session_token(summary.session());
    let mut request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(chat_id),
        },
        agent_session_status_text(workspace_label, summary, history_incomplete),
    );
    request.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("provider-session-{session_token}-status"),
    )?);
    request.parse_markdown = true;
    request.notification_mode = SendNotificationMode::Silent;
    send_text_with_retry(bot, request)
        .await?
        .message_id
        .map(InlineId::get)
        .ok_or_else(|| {
            io::Error::other("Inline did not confirm the agent session status message").into()
        })
}

fn agent_session_status_text(
    workspace_label: &str,
    summary: &SessionSummary,
    history_incomplete: bool,
) -> String {
    let provider_label = session_provider_label(summary.session().provider().provider_id());
    let history_note = if history_incomplete {
        "Recent user messages and final answers only. Older or unsupported content was omitted; the full transcript remains in Codex."
    } else {
        "User messages and final answers are shown here. Tool activity and intermediate responses remain in Codex."
    };
    format!(
        "**{provider_label} session linked**\n\nSession: **{}**\nProject: **{}**\n\n/resume — sync recent history, then enable prompts in Inline.\n/stop — stop and release for ChatGPT Desktop or Codex CLI.\n\nUse /resume before sending prompts after opening or reconnecting. Use one interface at a time; close the session in the other interface before /resume. Wait for Inline’s release confirmation before continuing elsewhere. Other running Inline tasks may delay release.\n\n{history_note}",
        markdown_escape(&session_thread_title(summary)),
        markdown_escape(workspace_label),
    )
}

async fn send_session_reply(
    bot: &InlineClient,
    record: &InboundRecord,
    text: &str,
    suffix: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(record.binding.chat_id),
        },
        text,
    );
    request.reply_to_message_id = Some(InlineId::new(record.message_id));
    request.external_id = Some(ExternalId::try_new(
        "agent-bridge",
        format!("{}-provider-sessions-{suffix}", record.event_id),
    )?);
    request.notification_mode = SendNotificationMode::Silent;
    send_text_with_retry(bot, request)
        .await?
        .message_id
        .ok_or_else(|| {
            io::Error::other("session command reply has no confirmed message identity")
        })?;
    Ok(())
}

async fn answer_session_action(
    bot: &InlineClient,
    interaction_id: InlineId,
    toast: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    bot.answer_message_action(inline_client::AnswerMessageActionRequest {
        interaction_id,
        toast: Some(toast.to_string()),
    })
    .await?;
    Ok(())
}

async fn edit_session_opened(
    bot: &InlineClient,
    chat_id: i64,
    message_id: i64,
    thread_id: i64,
) -> Result<(), Box<dyn std::error::Error>> {
    edit_interactive_message_with_retry(
        bot,
        EditInteractiveMessageRequest {
            message: EditMessageRequest {
                chat_id: InlineId::new(chat_id),
                message_id: InlineId::new(message_id),
                text: format!(
                    "Session history opened in [Open thread](inline://thread?id={thread_id}). Use /resume there to sync history and enable prompts."
                ),
                external_id: None,
                parse_markdown: true,
            },
            actions: MessageActions::default(),
        },
    )
    .await
}

fn markdown_escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('*', "\\*")
        .replace('_', "\\_")
        .replace('[', "\\[")
        .replace(']', "\\]")
        .replace('`', "\\`")
}

fn truncate_utf16(value: &str, maximum: usize) -> String {
    if value.encode_utf16().count() <= maximum {
        return value.to_string();
    }
    if maximum <= 1 {
        return "…".chars().take(maximum).collect();
    }
    let mut output = String::new();
    let mut used = 0usize;
    for character in value.chars() {
        let width = character.len_utf16();
        if used.saturating_add(width) > maximum - 1 {
            break;
        }
        output.push(character);
        used += width;
    }
    output.push('…');
    output
}

fn text_chunks(text: &str, maximum_utf16: usize, maximum_bytes: usize) -> Vec<String> {
    if text.is_empty() {
        return vec![String::new()];
    }
    let mut chunks = Vec::new();
    let mut current = String::new();
    let mut utf16 = 0usize;
    for character in text.chars() {
        let character_utf16 = character.len_utf16();
        if !current.is_empty()
            && (utf16.saturating_add(character_utf16) > maximum_utf16
                || current.len().saturating_add(character.len_utf8()) > maximum_bytes)
        {
            chunks.push(std::mem::take(&mut current));
            utf16 = 0;
        }
        current.push(character);
        utf16 += character_utf16;
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    chunks
}

#[cfg(test)]
mod tests {
    use super::*;
    use inline_agent_bridge::{
        CatalogCapabilities, DriverCapabilities, InstallationId, ProviderId, ProviderSessionId,
        ProviderSurface, SessionAttachmentSupport, SessionEventOrigin, SessionInputCorrelation,
        SessionItemKey, SessionItemVersion, SessionReplaySupport, SessionStreamFidelity,
        SteeringSupport,
    };

    fn provider_session(value: &str) -> ProviderSessionRef {
        ProviderSessionRef::new(
            ProviderInstanceRef::new(
                InstallationId::new("installation-1").expect("installation"),
                ProviderId::new("codex").expect("provider"),
            )
            .expect("provider instance"),
            ProviderSessionId::new(value).expect("session"),
        )
        .expect("session ref")
    }

    fn connected_session(chat_id: i64, bot_user_id: i64) -> proto::AgentSession {
        proto::AgentSession {
            id: 30,
            peer_id: Some(proto::Peer {
                r#type: Some(proto::peer::Type::Chat(proto::PeerChat { chat_id })),
            }),
            bot_user_id,
            provider: proto::AgentSessionProvider::Codex as i32,
            ..Default::default()
        }
    }

    fn connection_result(
        state: proto::ConnectAgentSessionState,
        session: Option<proto::AgentSession>,
    ) -> proto::ConnectAgentSessionResult {
        proto::ConnectAgentSessionResult {
            agent_session: session,
            state: state as i32,
        }
    }

    #[test]
    fn session_thread_parent_uses_authoritative_metadata_without_a_dialog_cache() {
        let mut session = connected_session(20, 7);
        session.parent_chat_id = Some(10);
        assert_eq!(session_thread_parent_chat_id(&session, 20).unwrap(), 10);
        session.parent_chat_id = None;
        assert_eq!(session_thread_parent_chat_id(&session, 20).unwrap(), 20);
        for invalid in [0, -1, 20] {
            session.parent_chat_id = Some(invalid);
            assert!(session_thread_parent_chat_id(&session, 20).is_err());
        }
    }

    #[test]
    fn agent_session_connections_fail_closed_on_state_scope_and_identity_drift() {
        let valid = connected_session(20, 7);
        assert!(
            canonical_agent_session_lookup(
                connection_result(
                    proto::ConnectAgentSessionState::AlreadyConnected,
                    Some(valid.clone()),
                ),
                7,
                proto::AgentSessionProvider::Codex,
            )
            .expect("canonical lookup")
            .is_some()
        );
        assert!(
            validated_agent_session_connection(
                connection_result(
                    proto::ConnectAgentSessionState::Created,
                    Some(valid.clone()),
                ),
                20,
                7,
                proto::AgentSessionProvider::Codex,
            )
            .is_ok()
        );

        let mut wrong_bot = valid.clone();
        wrong_bot.bot_user_id = 8;
        assert!(
            validated_agent_session_connection(
                connection_result(
                    proto::ConnectAgentSessionState::AlreadyConnected,
                    Some(wrong_bot),
                ),
                20,
                7,
                proto::AgentSessionProvider::Codex,
            )
            .is_err()
        );
        let mut wrong_provider = valid.clone();
        wrong_provider.provider = proto::AgentSessionProvider::Claude as i32;
        assert!(
            canonical_agent_session_lookup(
                connection_result(
                    proto::ConnectAgentSessionState::AlreadyConnected,
                    Some(wrong_provider),
                ),
                7,
                proto::AgentSessionProvider::Codex,
            )
            .is_err()
        );
        assert!(
            validated_agent_session_connection(
                connection_result(
                    proto::ConnectAgentSessionState::ConnectedElsewhere,
                    Some(valid.clone()),
                ),
                20,
                7,
                proto::AgentSessionProvider::Codex,
            )
            .is_err()
        );
        assert!(
            validated_agent_session_connection(
                connection_result(
                    proto::ConnectAgentSessionState::Created,
                    Some(valid.clone()),
                ),
                21,
                7,
                proto::AgentSessionProvider::Codex,
            )
            .is_err()
        );
        let unknown = proto::ConnectAgentSessionResult {
            agent_session: Some(valid),
            state: 99,
        };
        assert!(connect_agent_session_state(&unknown).is_err());
    }

    fn summary(value: &str, title: &str) -> SessionSummary {
        SessionSummary::new(
            provider_session(value),
            WorkspaceId::new("workspace-1").expect("workspace"),
            Some(title.to_string()),
            None,
            Some(1),
            SessionAvailability::Available,
        )
        .expect("summary")
    }

    struct PagedCatalog {
        pages: std::sync::Mutex<std::collections::VecDeque<(Option<String>, SessionPage)>>,
    }

    impl AgentSessionCatalog for PagedCatalog {
        fn session_capabilities(&self) -> SessionCapabilities {
            enabled_capabilities().0
        }

        fn provider_health<'a>(
            &'a self,
            _: &'a WorkspaceId,
        ) -> inline_agent_bridge::DriverFuture<'a, inline_agent_bridge::ProviderHealth> {
            Box::pin(async { Err(DriverError::Unsupported("health in paging test")) })
        }

        fn list_sessions<'a>(
            &'a self,
            query: SessionQuery,
        ) -> inline_agent_bridge::DriverFuture<'a, SessionPage> {
            Box::pin(async move {
                let (cursor, page) = self
                    .pages
                    .lock()
                    .expect("pages")
                    .pop_front()
                    .expect("unexpected catalog request");
                assert_eq!(query.cursor.as_ref().map(ToString::to_string), cursor);
                Ok(page)
            })
        }

        fn read_session<'a>(
            &'a self,
            _: SessionReadRequest,
        ) -> inline_agent_bridge::DriverFuture<'a, SessionSnapshot> {
            Box::pin(async { Err(DriverError::Unsupported("history in paging test")) })
        }
    }

    fn catalog_query() -> SessionQuery {
        SessionQuery {
            provider: provider_session("session").provider().clone(),
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
            cursor: None,
            page_size: SessionPageSize::new(MAX_SESSION_RESULTS),
        }
    }

    fn catalog_page(sessions: Vec<SessionSummary>, next: Option<&str>) -> SessionPage {
        SessionPage::new(
            &catalog_query(),
            sessions,
            next.map(|cursor| SessionPageCursor::new(cursor).expect("cursor")),
        )
        .expect("page")
    }

    #[tokio::test]
    async fn catalog_skips_empty_and_duplicate_pages_without_losing_new_sessions() {
        let known = summary("known", "Known");
        let older = summary("older", "Older");
        let catalog = PagedCatalog {
            pages: std::sync::Mutex::new(
                [
                    (None, catalog_page(vec![], Some("2"))),
                    (
                        Some("2".into()),
                        catalog_page(vec![known.clone()], Some("3")),
                    ),
                    (Some("3".into()), catalog_page(vec![older.clone()], None)),
                ]
                .into(),
            ),
        };
        let page = read_catalog_page(&catalog, catalog_query(), &[known])
            .await
            .expect("page");
        assert_eq!(page.sessions(), &[older]);
        assert!(page.next_cursor().is_none());
        assert!(catalog.pages.lock().expect("pages").is_empty());
    }

    #[tokio::test]
    async fn catalog_rejects_cursor_cycles() {
        let catalog = PagedCatalog {
            pages: std::sync::Mutex::new(
                [
                    (None, catalog_page(vec![], Some("2"))),
                    (Some("2".into()), catalog_page(vec![], Some("3"))),
                    (Some("3".into()), catalog_page(vec![], Some("2"))),
                ]
                .into(),
            ),
        };
        assert!(matches!(
            read_catalog_page(&catalog, catalog_query(), &[]).await,
            Err(DriverError::Protocol(_))
        ));
    }

    #[tokio::test]
    async fn catalog_empty_page_search_has_a_request_budget_and_preserves_the_next_cursor() {
        let pages = (0..MAX_CATALOG_PAGE_READS)
            .map(|index| {
                (
                    (index > 0).then(|| index.to_string()),
                    catalog_page(vec![], Some(&(index + 1).to_string())),
                )
            })
            .collect();
        let catalog = PagedCatalog {
            pages: std::sync::Mutex::new(pages),
        };
        let page = read_catalog_page(&catalog, catalog_query(), &[])
            .await
            .expect("bounded page");
        assert!(page.sessions().is_empty());
        assert_eq!(
            page.next_cursor().map(ToString::to_string),
            Some(MAX_CATALOG_PAGE_READS.to_string())
        );
    }

    #[test]
    fn only_local_page_navigation_can_run_during_a_turn() {
        assert!(!session_action_uses_provider(
            SessionBrowserCallbackAction::Page { page: 1 }
        ));
        assert!(session_action_uses_provider(
            SessionBrowserCallbackAction::LoadOlder { expected_count: 50 }
        ));
        assert!(session_action_uses_provider(
            SessionBrowserCallbackAction::Open { index: 0 }
        ));
    }

    fn enabled_capabilities() -> (SessionCapabilities, DriverCapabilities) {
        (
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
            },
            DriverCapabilities {
                resume_session: true,
                steering: SteeringSupport::Native,
                cancel_turn: true,
                ..DriverCapabilities::default()
            },
        )
    }

    fn inline_user_history_item(event_id: &str) -> SessionItem {
        SessionItem {
            key: SessionItemKey::new("provider-user-item").expect("item key"),
            revision: SessionItemVersion::snapshot_baseline(),
            run_id: None,
            origin: SessionEventOrigin::confirmed_inline_echo(
                DirectionId::new(event_id).expect("direction"),
                SessionInputCorrelation::new(format!("inline-agent-bridge:v1:{event_id}"))
                    .expect("correlation"),
            ),
            payload: SessionItemPayload::Message {
                role: SessionMessageRole::User,
                text: "bridge-authored delivery envelope".to_string(),
                created_at: Some(1),
            },
        }
    }

    fn provider_user_history_item(turn_id: &str, text: &str) -> SessionItem {
        SessionItem {
            key: SessionItemKey::new("legacy-provider-user-item").expect("item key"),
            revision: SessionItemVersion::snapshot_baseline(),
            run_id: Some(TurnId::new(turn_id).expect("turn")),
            origin: SessionEventOrigin::provider(ProviderSurface::Unknown),
            payload: SessionItemPayload::Message {
                role: SessionMessageRole::User,
                text: text.to_string(),
                created_at: Some(1),
            },
        }
    }

    fn accept_inline_history(
        store: &BridgeStore,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
        chat_id: i64,
        event_id: &str,
    ) {
        accept_inline_history_with_state(
            store,
            installation_id,
            workspace_id,
            chat_id,
            event_id,
            InboundState::Completed,
        );
    }

    fn accept_inline_history_with_state(
        store: &BridgeStore,
        installation_id: &InstallationId,
        workspace_id: &WorkspaceId,
        chat_id: i64,
        event_id: &str,
        state: InboundState,
    ) {
        assert!(
            store
                .accept_inbound(&InboundRecord {
                    event_id: event_id.to_string(),
                    binding: BindingKey {
                        installation_id: installation_id.clone(),
                        chat_id,
                        workspace_id: workspace_id.clone(),
                    },
                    message_id: 11,
                    delivery_chat_id: chat_id,
                    sender_user_id: 7,
                    direction: Direction::new(
                        DirectionId::new(event_id).expect("direction"),
                        "clean Inline prompt",
                    ),
                    state,
                    accepted_at: 1,
                    started_at: Some(1),
                    lease_expires_at: None,
                    attempt_count: 1,
                    provider_turn_id: None,
                    stream_message_id: None,
                    failure: None,
                })
                .expect("accept history")
        );
    }

    fn test_history_correlation(direction_id: &DirectionId) -> Option<String> {
        Some(format!("inline-agent-bridge:v1:{direction_id}"))
    }

    fn history_context<'a>(
        store: &'a BridgeStore,
        installation_id: &'a InstallationId,
        workspace_id: &'a WorkspaceId,
        thread_id: i64,
    ) -> AgentSessionHistoryContext<'a> {
        AgentSessionHistoryContext {
            store,
            installation_id,
            workspace_id,
            thread_id,
            correlation_for_direction: &test_history_correlation,
        }
    }

    #[test]
    fn confirmed_provider_echo_repairs_an_ambiguous_start_without_a_local_turn_id() {
        for state in [InboundState::Started, InboundState::Failed] {
            let store = BridgeStore::open_in_memory().expect("store");
            let installation_id = InstallationId::new("installation-1").expect("installation");
            let workspace_id = WorkspaceId::new("workspace-1").expect("workspace");
            let event_id = "ambiguous-start";
            accept_inline_history_with_state(
                &store,
                &installation_id,
                &workspace_id,
                10,
                event_id,
                state,
            );
            let repaired = known_inline_user_history(
                &inline_user_history_item(event_id),
                false,
                &history_context(&store, &installation_id, &workspace_id, 10),
            )
            .expect("repair")
            .expect("confirmed echo");
            assert_eq!(repaired.linked_message_id, Some(11));
            assert_eq!(repaired.text, "clean Inline prompt");
        }
    }

    #[test]
    fn known_inline_history_links_only_within_the_same_thread() {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("installation-1").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-1").expect("workspace");
        let event_id = "inline-message-10-11";
        accept_inline_history(&store, &installation_id, &workspace_id, 10, event_id);
        let item = inline_user_history_item(event_id);

        assert_eq!(
            known_inline_user_history(
                &item,
                false,
                &history_context(&store, &installation_id, &workspace_id, 10),
            )
            .expect("same thread"),
            Some(KnownInlineUserHistory {
                text: "clean Inline prompt".to_string(),
                correlation_ref: Some(format!("inline-agent-bridge:v1:{event_id}")),
                linked_message_id: Some(11),
            })
        );
        assert_eq!(
            known_inline_user_history(
                &item,
                false,
                &history_context(&store, &installation_id, &workspace_id, 20),
            )
            .expect("different thread"),
            None
        );
    }

    #[test]
    fn provider_correlation_cannot_claim_another_installations_inline_history() {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("installation-1").expect("installation");
        let other_installation = InstallationId::new("installation-2").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-1").expect("workspace");
        let event_id = "inline-message-10-11";
        accept_inline_history(&store, &other_installation, &workspace_id, 10, event_id);

        assert_eq!(
            known_inline_user_history(
                &inline_user_history_item(event_id),
                false,
                &history_context(&store, &installation_id, &workspace_id, 10),
            )
            .expect("untrusted correlation"),
            None
        );
    }

    #[test]
    fn confirmed_inline_echo_without_local_history_is_not_provider_owned_history() {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("installation-1").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-1").expect("workspace");
        let item = inline_user_history_item("missing-inline-message");

        assert!(item.confirmed_inline_echo().is_some());
        assert_eq!(
            known_inline_user_history(
                &item,
                false,
                &history_context(&store, &installation_id, &workspace_id, 10),
            )
            .expect("missing local history"),
            None
        );
    }

    #[test]
    fn legacy_same_thread_turn_adopts_its_existing_prompt_and_terminal_answer() {
        let store = BridgeStore::open_in_memory().expect("store");
        let installation_id = InstallationId::new("installation-1").expect("installation");
        let workspace_id = WorkspaceId::new("workspace-1").expect("workspace");
        let event_id = "inline-message-10-11";
        let turn_id = TurnId::new("provider-turn-1").expect("turn");
        assert!(
            store
                .accept_inbound(&InboundRecord {
                    event_id: event_id.to_string(),
                    binding: BindingKey {
                        installation_id: installation_id.clone(),
                        chat_id: 10,
                        workspace_id: workspace_id.clone(),
                    },
                    message_id: 11,
                    delivery_chat_id: 10,
                    sender_user_id: 7,
                    direction: Direction::new(
                        DirectionId::new(event_id).expect("direction"),
                        "clean legacy prompt",
                    ),
                    state: InboundState::Accepted,
                    accepted_at: 1,
                    started_at: None,
                    lease_expires_at: None,
                    attempt_count: 0,
                    provider_turn_id: None,
                    stream_message_id: None,
                    failure: None,
                })
                .expect("accept")
        );
        assert!(store.start_inbound(event_id, 2).expect("start"));
        assert!(
            store
                .attach_inbound_turn(event_id, &turn_id, Some(12))
                .expect("attach turn")
        );
        assert!(
            store
                .stage_inbound_final_send(event_id, InboundState::Completed, "done", None)
                .expect("stage final")
        );
        assert_eq!(
            store
                .ensure_inbound_final_send_random_id(event_id, 8_000_000_000_000_001)
                .expect("terminal identity"),
            Some(8_000_000_000_000_001)
        );
        assert!(
            store
                .commit_inbound_final_send(event_id)
                .expect("commit final")
        );

        assert_eq!(
            known_inline_user_history(
                &provider_user_history_item(turn_id.as_str(), "clean legacy prompt"),
                true,
                &history_context(&store, &installation_id, &workspace_id, 10),
            )
            .expect("legacy prompt"),
            Some(KnownInlineUserHistory {
                text: "clean legacy prompt".to_string(),
                correlation_ref: Some(format!("inline-agent-bridge:v1:{event_id}")),
                linked_message_id: Some(11),
            })
        );
        assert_eq!(
            known_inline_user_history(
                &provider_user_history_item(turn_id.as_str(), "another client's prompt"),
                true,
                &history_context(&store, &installation_id, &workspace_id, 10),
            )
            .expect("foreign provider item"),
            None
        );
        assert_eq!(
            known_inline_user_history(
                &provider_user_history_item(turn_id.as_str(), "clean legacy prompt"),
                false,
                &history_context(&store, &installation_id, &workspace_id, 10),
            )
            .expect("ambiguous provider item"),
            None
        );
        assert_eq!(
            known_inline_assistant_random_id(
                &history_context(&store, &installation_id, &workspace_id, 10),
                &turn_id,
            )
            .expect("legacy answer"),
            Some(8_000_000_000_000_001)
        );
    }

    #[test]
    fn browser_gate_accepts_exclusive_codex_continuation() {
        let (session, turn) = enabled_capabilities();
        assert!(session_browser_enabled(&session, &turn));
        let mut missing = session.clone();
        missing.attachment = SessionAttachmentSupport::Unsupported;
        assert!(!session_browser_enabled(&missing, &turn));
        let mut missing_turn = turn;
        missing_turn.steering = SteeringSupport::Unsupported;
        assert!(!session_browser_enabled(&session, &missing_turn));
    }

    #[test]
    fn transient_open_catalog_work_returns_a_truthful_action_retry() {
        let provider_id = ProviderId::new("codex").expect("provider");
        assert_eq!(
            classify_session_open_catalog_result::<u8>(
                &provider_id,
                Err(DriverError::Transient("session read".to_string())),
            )
            .expect("transient result is handled"),
            Err("Codex took too long to open this session. Try Open again.".to_string())
        );
        assert!(matches!(
            classify_session_open_catalog_result::<u8>(
                &provider_id,
                Err(DriverError::Protocol("bad catalog".to_string())),
            ),
            Err(DriverError::Protocol(_))
        ));
    }

    #[test]
    fn open_health_copy_distinguishes_sign_in_from_temporary_provider_loss() {
        let provider_id = ProviderId::new("codex").expect("provider");
        assert!(
            session_open_health_toast(&provider_id, inline_agent_bridge::ProviderHealth::Ready,)
                .is_none()
        );
        assert!(
            session_open_health_toast(
                &provider_id,
                inline_agent_bridge::ProviderHealth::Unauthenticated,
            )
            .expect("sign-in copy")
            .contains("Sign in")
        );
        let unavailable = session_open_health_toast(
            &provider_id,
            inline_agent_bridge::ProviderHealth::DaemonUnavailable,
        )
        .expect("temporary provider copy");
        assert!(unavailable.contains("temporarily unavailable"));
        assert!(unavailable.contains("reconnects"));
        assert!(!unavailable.contains("sign in"));
    }

    #[test]
    fn provider_session_commands_are_claimed_but_unrelated_commands_are_not() {
        for (provider, text, expected) in [
            ("codex", "/resume", Some(SessionBrowserCommand::Resume)),
            (
                "codex",
                "/resume@codex_bot",
                Some(SessionBrowserCommand::Resume),
            ),
            ("codex", "/resume@other_bot", None),
            ("claude", "/resume", None),
        ] {
            assert_eq!(
                session_browser_command(&ProviderId::new(provider).unwrap(), text, "codex_bot"),
                expected
            );
        }
        assert_eq!(
            session_browser_command(
                &ProviderId::new("claude").expect("provider"),
                "/sessions",
                "claude_bot",
            ),
            Some(SessionBrowserCommand::Sessions)
        );
        assert_eq!(
            session_browser_command(
                &ProviderId::new("codex").expect("provider"),
                "/status",
                "codex_bot",
            ),
            None
        );
        assert_eq!(
            session_browser_command(
                &ProviderId::new("codex").expect("provider"),
                "/sessions",
                "codex_bot",
            ),
            Some(SessionBrowserCommand::Sessions)
        );
        assert!(
            session_unavailable_message(&ProviderId::new("claude").expect("provider"))
                .contains("/history")
        );
    }

    #[test]
    fn session_command_restarts_dead_connections_but_keeps_retryable_failures_local() {
        for error in [
            DriverError::ProcessExited("closed".into()),
            DriverError::EpochEnded("closed".into()),
        ] {
            assert!(session_command_ends_provider_epoch(&error));
            assert!(session_command_ends_provider_epoch(
                &SessionManagerError::Driver(error)
            ));
        }
        for error in [
            DriverError::SessionBusy("other interface".into()),
            DriverError::Transient("retry".into()),
            DriverError::InvalidSession("missing".into()),
        ] {
            assert!(!session_command_ends_provider_epoch(&error));
            assert!(!session_command_ends_provider_epoch(
                &SessionManagerError::Driver(error)
            ));
        }
        assert!(!session_command_ends_provider_epoch(&io::Error::other(
            "Inline history sync failed"
        )));
    }

    #[test]
    fn callback_contains_only_token_and_index() {
        let data = session_browser_callback_data(
            "opaque-picker-token",
            SessionBrowserCallbackAction::Open { index: 3 },
        )
        .expect("callback");
        let text = String::from_utf8(data.clone()).expect("utf8 callback");
        assert!(!text.contains("private-provider-session"));
        let callback =
            parse_session_browser_callback(&session_open_action_id(3), &data).expect("callback");
        assert!(matches!(
            callback.action,
            SessionBrowserCallbackAction::Open { index: 3 }
        ));
        assert!(parse_session_browser_callback(&format!("{ACTION_PREFIX}more"), &data).is_none());
        assert!(parse_session_browser_callback(&session_open_action_id(2), &data).is_none());
    }

    #[test]
    fn picker_actions_never_embed_provider_session_identity() {
        let picker = SessionBrowserPicker {
            provider_id: ProviderId::new("codex").expect("provider"),
            workspace_label: "Project".to_string(),
            has_older: false,
            sessions: vec![summary("private-provider-session", "Fix tests")],
        };
        let (text, actions) = session_picker_card("opaque-token", &picker, 0).expect("card");
        let actions = serde_json::to_string(&actions).expect("actions");
        assert!(!text.contains("private-provider-session"));
        assert!(!actions.contains("private-provider-session"));
        assert!(text.starts_with("Recent Codex sessions"));
    }

    #[test]
    fn retry_card_exposes_only_the_original_open_target() {
        let (text, actions) =
            retry_session_picker_card("opaque", &summary("private-id", "Selected task"), 49)
                .expect("card");
        assert!(text.contains("Selected task"));
        assert!(text.contains("/sessions"));
        assert_eq!(actions.rows.len(), 1);
        assert_eq!(actions.rows[0].actions.len(), 1);
        let button = &actions.rows[0].actions[0];
        assert_eq!(button.text, "Retry Open");
        let MessageActionKind::Callback { data } = &button.kind else {
            panic!("callback")
        };
        let callback =
            parse_session_browser_callback(&button.action_id, data).expect("valid action");
        assert!(matches!(
            callback.action,
            SessionBrowserCallbackAction::Open { index: 49 }
        ));
        assert!(!String::from_utf8_lossy(data).contains("private-id"));
    }

    #[test]
    fn last_loaded_page_offers_an_opaque_restart_safe_older_action() {
        let picker = SessionBrowserPicker {
            provider_id: ProviderId::new("codex").expect("provider"),
            workspace_label: "Project".into(),
            sessions: vec![summary("private-session", "Work")],
            has_older: true,
        };
        let (text, actions) = session_picker_card("opaque-token", &picker, 0).expect("card");
        assert!(text.contains("Older sessions"));
        let button = &actions.rows.last().expect("navigation").actions[0];
        assert_eq!(button.text, "Load Older Sessions");
        let MessageActionKind::Callback { data } = &button.kind else {
            panic!("callback")
        };
        assert!(!String::from_utf8_lossy(data).contains("private-session"));
        let callback = parse_session_browser_callback(&button.action_id, data).expect("parse");
        assert!(matches!(
            callback.action,
            SessionBrowserCallbackAction::LoadOlder { expected_count: 1 }
        ));
        assert!(parse_session_browser_callback(&session_open_action_id(0), data).is_none());
    }

    #[test]
    fn untitled_picker_rows_remain_distinguishable() {
        let untitled = SessionSummary::new(
            provider_session("private-provider-session"),
            WorkspaceId::new("workspace-1").expect("workspace"),
            None,
            None,
            Some(1),
            SessionAvailability::Available,
        )
        .expect("summary");

        assert_eq!(session_button_text(&untitled, 2), "Codex session 2");
    }

    #[test]
    fn picker_pages_are_bounded_and_every_action_id_is_unique() {
        let sessions = (0..MAX_SESSION_RESULTS)
            .map(|index| {
                summary(
                    &format!("private-session-{index}"),
                    &format!("Session {index}"),
                )
            })
            .collect::<Vec<_>>();
        let picker = SessionBrowserPicker {
            provider_id: ProviderId::new("codex").expect("provider"),
            workspace_label: "Project".to_string(),
            has_older: false,
            sessions,
        };

        let (_, first_page) = session_picker_card("opaque-token", &picker, 0).expect("first page");
        assert_eq!(first_page.rows.len(), PICKER_PAGE_SIZE + 1);
        assert_eq!(
            first_page.rows[..PICKER_PAGE_SIZE]
                .iter()
                .map(|row| row.actions.len())
                .sum::<usize>(),
            PICKER_PAGE_SIZE
        );
        assert_eq!(first_page.rows[PICKER_PAGE_SIZE].actions.len(), 1);

        let action_ids = first_page
            .rows
            .iter()
            .flat_map(|row| row.actions.iter().map(|action| action.action_id.as_str()))
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(action_ids.len(), PICKER_PAGE_SIZE + 1);

        let last_page = MAX_SESSION_RESULTS.div_ceil(PICKER_PAGE_SIZE) - 1;
        assert_eq!(
            picker_page(&picker.sessions, last_page),
            Some((48, MAX_SESSION_RESULTS, last_page + 1))
        );
        let (_, last_page_actions) =
            session_picker_card("opaque-token", &picker, last_page).expect("last page");
        assert_eq!(last_page_actions.rows.len(), 3);
        assert_eq!(
            last_page_actions.rows[0].actions[0].action_id,
            session_open_action_id(48)
        );
        assert_eq!(
            last_page_actions.rows[1].actions[0].action_id,
            session_open_action_id(49)
        );
        assert_eq!(last_page_actions.rows[2].actions[0].text, "Back");
    }

    #[test]
    fn stable_external_tokens_hide_provider_ids_and_are_repeatable() {
        let session = provider_session("private-provider-session");
        let token = stable_session_token(&session);
        assert_eq!(token, stable_session_token(&session));
        assert!(!token.contains("private-provider-session"));
        assert_eq!(token.len(), 32);
    }

    #[test]
    fn titles_buttons_and_chunks_are_bounded_without_splitting_unicode() {
        let long = "🦀".repeat(100);
        let button = session_button_text(&summary("session-1", &long), 1);
        assert!(button.encode_utf16().count() <= MAX_BUTTON_TEXT_UTF16);
        assert_eq!(
            session_thread_title(&summary("session-1", "Fix the failing tests")),
            "Fix the failing tests"
        );
        let preview_only = SessionSummary::new(
            provider_session("session-preview"),
            WorkspaceId::new("workspace-1").expect("workspace"),
            None,
            Some("Investigate the flaky build".to_string()),
            Some(1),
            SessionAvailability::Available,
        )
        .expect("preview summary");
        assert_eq!(
            session_thread_title(&preview_only),
            "Investigate the flaky build"
        );
        let chunks = text_chunks(&long, 9, 20);
        assert!(chunks.len() > 1);
        assert!(
            chunks
                .iter()
                .all(|chunk| chunk.encode_utf16().count() <= 9 && chunk.len() <= 20)
        );
        let bounded = bounded_agent_message_text(&"🦀".repeat(MAX_INLINE_TEXT_UTF16));
        assert!(bounded.encode_utf16().count() <= MAX_INLINE_TEXT_UTF16);
        assert!(bounded.len() <= MAX_INLINE_TEXT_BYTES);
        assert!(bounded.ends_with("[Turn truncated by Inline’s beta message limit.]"));
    }

    #[test]
    fn assistant_output_correlation_is_stable_per_provider_turn() {
        let turn = TurnId::new("turn-1").expect("turn");
        assert_eq!(
            agent_output_correlation(&turn),
            "inline-agent-output:v1:turn-1"
        );
        assert_eq!(
            assistant_final_random_id(&turn),
            assistant_final_random_id(&turn)
        );
        assert_ne!(
            assistant_final_random_id(&turn),
            assistant_final_random_id(&TurnId::new("turn-2").expect("other turn"))
        );
        assert!(assistant_final_random_id(&turn).get() > 0);
    }
}

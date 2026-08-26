//! Provider-session browsing and bounded reply-thread hydration.
//!
//! Codex uses an exclusive-worker beta contract: bounded history is hydrated
//! before the exact provider session is resumed by the existing turn driver.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use inline_agent_bridge::{
    AgentSessionCatalog, DriverResult, HistoryWindow, MAX_HISTORY_MESSAGE_LIMIT,
    MAX_HISTORY_TEXT_BYTES, ProviderInstanceRef, ProviderSessionId, ProviderSessionRef,
    SessionAvailability, SessionCapabilities, SessionItem, SessionItemPayload, SessionMessageRole,
    SessionPageSize, SessionQuery, SessionReadRequest, SessionSnapshot, SessionSummary,
    SessionThreadBindOutcome, SessionThreadBinding, SessionThreadOpening, TurnId,
};
use inline_agent_driver_codex::CodexSessionCatalog;
use serde::{Deserialize, Serialize};

use super::*;

const CALLBACK_VERSION: u32 = 1;
const ACTION_PREFIX: &str = "bridge_agent_sessions_";
const PICKER_TTL_SECONDS: i64 = 10 * 60;
const MAX_PICKERS: usize = 32;
const PICKER_PAGE_SIZE: usize = 6;
const MAX_SESSION_RESULTS: usize = 100;
const MAX_INLINE_TEXT_UTF16: usize = 12_000;
const MAX_INLINE_TEXT_BYTES: usize = 20_000;
const MAX_BUTTON_TEXT_UTF16: usize = 64;
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

#[derive(Clone, Default)]
pub(super) struct SessionBrowserRuntime {
    registry: Arc<Mutex<SessionBrowserRegistry>>,
}

impl std::fmt::Debug for SessionBrowserRuntime {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SessionBrowserRuntime(<private registry>)")
    }
}

#[derive(Default)]
struct SessionBrowserRegistry {
    pickers: HashMap<String, SessionBrowserPicker>,
}

#[derive(Clone)]
struct SessionBrowserPicker {
    installation_id: InstallationId,
    provider_id: ProviderId,
    owner_user_id: i64,
    chat_id: i64,
    message_id: Option<i64>,
    workspace_id: WorkspaceId,
    workspace_label: String,
    sessions: Vec<SessionSummary>,
    expires_at: i64,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SessionBrowserCallbackAction {
    Open { index: usize },
    Confirm { index: usize },
    Page { page: usize },
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
    parent_chat_id: i64,
    picker_message_id: i64,
    workspace_id: WorkspaceId,
    workspace_label: String,
    session: SessionSummary,
    session_index: usize,
    confirmed: bool,
}

enum SessionBrowserClaim {
    Open(SessionBrowserOpen),
    Page(SessionBrowserPicker, usize),
    Unauthorized,
    Stale,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SessionBrowserCommand {
    Sessions,
}

impl SessionBrowserRuntime {
    fn insert_picker(&self, token: String, picker: SessionBrowserPicker, now: i64) -> bool {
        let mut registry = self.registry.lock().expect("session browser poisoned");
        registry.prune(now);
        if registry.pickers.len() >= MAX_PICKERS || registry.pickers.contains_key(&token) {
            return false;
        }
        registry.pickers.insert(token, picker);
        true
    }

    fn attach_picker_message(&self, token: &str, message_id: i64) -> bool {
        if message_id <= 0 {
            return false;
        }
        let mut registry = self.registry.lock().expect("session browser poisoned");
        let Some(picker) = registry.pickers.get_mut(token) else {
            return false;
        };
        picker.message_id = Some(message_id);
        true
    }

    fn remove_picker(&self, token: &str) {
        self.registry
            .lock()
            .expect("session browser poisoned")
            .pickers
            .remove(token);
    }

    #[allow(clippy::too_many_arguments)]
    fn claim(
        &self,
        callback: &SessionBrowserCallback,
        installation_id: &InstallationId,
        provider_id: &ProviderId,
        owner_user_id: i64,
        actor_user_id: i64,
        chat_id: i64,
        message_id: i64,
        workspace_id: Option<&WorkspaceId>,
        now: i64,
    ) -> SessionBrowserClaim {
        let mut registry = self.registry.lock().expect("session browser poisoned");
        registry.prune(now);
        let Some(picker) = registry.pickers.get(&callback.token).cloned() else {
            return SessionBrowserClaim::Stale;
        };
        if actor_user_id != owner_user_id || actor_user_id != picker.owner_user_id {
            return SessionBrowserClaim::Unauthorized;
        }
        if &picker.installation_id != installation_id
            || &picker.provider_id != provider_id
            || picker.chat_id != chat_id
            || picker.message_id != Some(message_id)
            || workspace_id != Some(&picker.workspace_id)
        {
            return SessionBrowserClaim::Stale;
        }
        match callback.action {
            SessionBrowserCallbackAction::Open { index }
            | SessionBrowserCallbackAction::Confirm { index } => {
                let Some(session) = picker.sessions.get(index).cloned() else {
                    return SessionBrowserClaim::Stale;
                };
                SessionBrowserClaim::Open(SessionBrowserOpen {
                    token: callback.token.clone(),
                    parent_chat_id: picker.chat_id,
                    picker_message_id: message_id,
                    workspace_id: picker.workspace_id.clone(),
                    workspace_label: picker.workspace_label.clone(),
                    session,
                    session_index: index,
                    confirmed: matches!(
                        callback.action,
                        SessionBrowserCallbackAction::Confirm { .. }
                    ),
                })
            }
            SessionBrowserCallbackAction::Page { page } => {
                if picker_page(&picker.sessions, page).is_none() {
                    return SessionBrowserClaim::Stale;
                }
                SessionBrowserClaim::Page(picker, page)
            }
        }
    }
}

impl SessionBrowserRegistry {
    fn prune(&mut self, now: i64) {
        self.pickers.retain(|_, picker| picker.expires_at > now);
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
            route
                .store
                .fail_inbound(&record.event_id, "session browser command failed")?;
            Err(error)
        }
    }
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
    let workspace = match route
        .store
        .chat_workspace(&route.installation_id, chat_id.get())
    {
        Ok(workspace) => workspace,
        Err(StoreError::WorkspaceUnavailable { .. }) => None,
        Err(error) => return Err(error.into()),
    };
    let claim = route.session_browser.claim(
        &callback,
        &route.installation_id,
        &route.provider_id,
        route.owner_user_id,
        actor_user_id.get(),
        chat_id.get(),
        message_id.get(),
        workspace.as_ref().map(|workspace| &workspace.workspace_id),
        now_seconds(),
    );
    match claim {
        SessionBrowserClaim::Page(picker, page) => {
            let (text, actions) = session_picker_card(&callback.token, &picker, page)?;
            answer_session_action(bot, *interaction_id, "Updated").await?;
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
        SessionBrowserClaim::Open(open) => {
            let Some(workspace) = workspace else {
                answer_session_action(bot, *interaction_id, "This project is unavailable.").await?;
                return Ok(true);
            };
            let _provider_work_lease = match settings.sessions.try_begin_provider_work() {
                Ok(Some(lease)) => lease,
                Ok(None) => {
                    answer_session_action(
                        bot,
                        *interaction_id,
                        "Inline is releasing the Codex connection. Try Open again in a moment.",
                    )
                    .await?;
                    return Ok(true);
                }
                Err(error) => {
                    answer_session_action(
                        bot,
                        *interaction_id,
                        "The Codex connection restarted. Try Open again.",
                    )
                    .await?;
                    return Err(error.into());
                }
            };
            let Some(catalog) = enabled_catalog(settings, &workspace)? else {
                answer_session_action(
                    bot,
                    *interaction_id,
                    "Session continuation is not available yet.",
                )
                .await?;
                return Ok(true);
            };
            if !catalog
                .provider_health(&workspace.workspace_id)
                .await?
                .is_ready()
            {
                answer_session_action(
                    bot,
                    *interaction_id,
                    &format!(
                        "{} needs setup or sign-in repair.",
                        session_provider_label(&route.provider_id)
                    ),
                )
                .await?;
                return Ok(true);
            }
            let snapshot = catalog
                .read_session(SessionReadRequest {
                    session: open.session.session().clone(),
                    workspace_id: open.workspace_id.clone(),
                    window: HistoryWindow::new(MAX_HISTORY_MESSAGE_LIMIT, MAX_HISTORY_TEXT_BYTES),
                })
                .await?;
            let reverse_binding = route.store.session_thread_binding(open.session.session())?;
            if reverse_binding.is_none()
                && !route
                    .store
                    .provider_session_binding_chats(open.session.session())?
                    .is_empty()
            {
                answer_session_action(
                    bot,
                    *interaction_id,
                    "This session is already open in another Inline conversation.",
                )
                .await?;
                return Ok(true);
            }
            if reverse_binding.is_none()
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
                return Ok(true);
            }
            let owner_control = route.owner_control.as_ref().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    "owner authorization is unavailable for session connection",
                )
            })?;
            let mut prepared = None;
            let candidate_thread_id = if let Some(binding) = reverse_binding.as_ref() {
                binding.thread_chat_id()
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
            let connected = owner_control
                .connect_agent_session(agent_session_connect_input(
                    route,
                    open.session.session(),
                    &open.workspace_id,
                    candidate_thread_id,
                    None,
                )?)
                .await?;
            let agent_session = connected.agent_session.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Inline returned an empty agent session connection",
                )
            })?;
            let thread_id = connected_agent_session_chat_id(&agent_session)?;
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
                                open.parent_chat_id,
                                thread_id,
                            )?,
                            now_seconds(),
                        )
                        .await?,
                )
            } else {
                None
            };
            let created = matches!(
                proto::ConnectAgentSessionState::try_from(connected.state),
                Ok(proto::ConnectAgentSessionState::Created)
            ) || matches!(local_outcome, Some(SessionThreadBindOutcome::Created(_)));
            inherit_session_thread_settings(
                &route.store,
                &route.installation_id,
                open.parent_chat_id,
                thread_id,
                &open.workspace_id,
            )?;
            sync_agent_session_snapshot(bot, agent_session.id, &snapshot).await?;
            let status_message_id = match agent_session.status_message_id {
                Some(message_id) => message_id,
                None => {
                    let message_id = send_agent_session_status_card(
                        bot,
                        thread_id,
                        &open.workspace_label,
                        &open.session,
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
                    if connected_agent_session_chat_id(
                        repaired.agent_session.as_ref().ok_or_else(|| {
                            io::Error::new(
                                io::ErrorKind::InvalidData,
                                "Inline returned an empty repaired agent session",
                            )
                        })?,
                    )? != thread_id
                    {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "agent session moved while its status card was being attached",
                        )
                        .into());
                    }
                    message_id
                }
            };
            let pin_needs_repair = bot
                .pin_message(inline_client::PinMessageRequest {
                    chat_id: InlineId::new(thread_id),
                    message_id: InlineId::new(status_message_id),
                    unpin: false,
                })
                .await
                .is_err();
            route.session_browser.remove_picker(&open.token);
            answer_session_action(
                bot,
                *interaction_id,
                if pin_needs_repair {
                    "Connected; the status pin needs repair"
                } else if created {
                    "Connected"
                } else {
                    "Already connected"
                },
            )
            .await?;
            edit_session_opened(bot, chat_id.get(), message_id.get(), thread_id).await?;
        }
        SessionBrowserClaim::Unauthorized => {
            answer_session_action(
                bot,
                *interaction_id,
                "Only the bot owner can open sessions.",
            )
            .await?;
        }
        SessionBrowserClaim::Stale => {
            answer_session_action(
                bot,
                *interaction_id,
                "This session picker is no longer active.",
            )
            .await?;
        }
    }
    Ok(true)
}

async fn handle_session_browser_command_inner<D>(
    bot: &InlineClient,
    record: &InboundRecord,
    route: &InboundRoute,
    settings: &SettingsRuntime<'_, D>,
    _command: SessionBrowserCommand,
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
    let _provider_work_lease = match settings.sessions.try_begin_provider_work() {
        Ok(Some(lease)) => lease,
        Ok(None) => {
            return send_session_reply(
                bot,
                record,
                "Inline is releasing the Codex connection. Try /sessions again in a moment.",
                "connection-closing",
            )
            .await;
        }
        Err(error) => {
            send_session_reply(
                bot,
                record,
                "The Codex connection restarted. Try /sessions again.",
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
    match catalog.provider_health(&workspace.workspace_id).await? {
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
    let provider =
        ProviderInstanceRef::new(route.installation_id.clone(), route.provider_id.clone())?;
    let query = SessionQuery {
        provider,
        workspace_id: workspace.workspace_id.clone(),
        cursor: None,
        page_size: SessionPageSize::new(MAX_SESSION_RESULTS),
    };
    let page = catalog.list_sessions(query).await?;
    let sessions = page
        .sessions()
        .iter()
        .filter(|session| session.availability() != SessionAvailability::Unavailable)
        .cloned()
        .collect::<Vec<_>>();
    if sessions.is_empty() {
        return send_session_reply(
            bot,
            record,
            &format!(
                "No resumable {} sessions were found for this project.",
                session_provider_label(&route.provider_id)
            ),
            "empty",
        )
        .await;
    }
    let token = generate_control_token();
    let picker = SessionBrowserPicker {
        installation_id: route.installation_id.clone(),
        provider_id: route.provider_id.clone(),
        owner_user_id: route.owner_user_id,
        chat_id: record.binding.chat_id,
        message_id: None,
        workspace_id: workspace.workspace_id,
        workspace_label: workspace.display_name,
        sessions,
        expires_at: now_seconds().saturating_add(PICKER_TTL_SECONDS),
    };
    let (text, actions) = session_picker_card(&token, &picker, 0)?;
    if !route
        .session_browser
        .insert_picker(token.clone(), picker, now_seconds())
    {
        return send_session_reply(
            bot,
            record,
            "Too many session pickers are active. Let an older picker expire and try again.",
            "picker-capacity",
        )
        .await;
    }
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
    message.random_id = Some(interaction_random_id("provider-sessions", &token));
    message.parse_markdown = true;
    message.notification_mode = SendNotificationMode::Silent;
    let mutation = match send_interactive_text_with_retry(
        bot,
        SendInteractiveTextRequest { message, actions },
    )
    .await
    {
        Ok(mutation) => mutation,
        Err(error) => {
            route.session_browser.remove_picker(&token);
            return Err(error);
        }
    };
    let message_id = mutation.message_id.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "session picker has no message identity",
        )
    })?;
    if !route
        .session_browser
        .attach_picker_message(&token, message_id.get())
    {
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
    _provider_id: &ProviderId,
    text: &str,
    bot_username: &str,
) -> Option<SessionBrowserCommand> {
    let command = parse_command(text, bot_username).ok()??;
    if command.explicit_target && !command.targets_this_bot {
        return None;
    }
    match command.name.as_str() {
        "sessions" | "open" => Some(SessionBrowserCommand::Sessions),
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

fn session_picker_card(
    token: &str,
    picker: &SessionBrowserPicker,
    page: usize,
) -> Result<(String, MessageActions), Box<dyn std::error::Error>> {
    let (start, end, page_count) = picker_page(&picker.sessions, page)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid session page"))?;
    let text = format!(
        "Recent {} sessions for **{}** — page {} of {}. Opening one reuses its Inline reply thread and loads bounded recent context without taking control. Your first message there resumes the exact provider session in Inline.",
        session_provider_label(&picker.provider_id),
        markdown_escape(&picker.workspace_label),
        page + 1,
        page_count,
    );
    let mut rows = picker.sessions[start..end]
        .iter()
        .enumerate()
        .map(|(offset, session)| {
            let index = start + offset;
            Ok(MessageActionRow {
                actions: vec![MessageActionButton {
                    action_id: format!("{ACTION_PREFIX}open"),
                    text: session_button_text(session),
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

fn session_button_text(session: &SessionSummary) -> String {
    let label = session
        .title()
        .or_else(|| session.preview())
        .unwrap_or("Untitled session");
    let suffix = match session.availability() {
        SessionAvailability::Active => " · Active",
        SessionAvailability::ActiveElsewhere => " · Active elsewhere",
        SessionAvailability::Unavailable => " · Unavailable",
        SessionAvailability::Unknown | SessionAvailability::Available => "",
    };
    truncate_utf16(
        label,
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

fn parse_session_browser_callback(action_id: &str, data: &[u8]) -> Option<SessionBrowserCallback> {
    let callback = serde_json::from_slice::<SessionBrowserCallback>(data)
        .ok()
        .filter(|callback| callback.version == CALLBACK_VERSION)?;
    let matching_action = match callback.action {
        SessionBrowserCallbackAction::Open { .. } => action_id == format!("{ACTION_PREFIX}open"),
        SessionBrowserCallbackAction::Confirm { .. } => {
            action_id == format!("{ACTION_PREFIX}confirm")
        }
        SessionBrowserCallbackAction::Page { .. } => {
            action_id == format!("{ACTION_PREFIX}back")
                || action_id == format!("{ACTION_PREFIX}more")
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
) -> Result<proto::ConnectAgentSessionInput, Box<dyn std::error::Error>> {
    if chat_id <= 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid Inline thread").into());
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

fn agent_session_provider(
    provider_id: &ProviderId,
) -> Result<proto::AgentSessionProvider, Box<dyn std::error::Error>> {
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
            )
            .into());
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

pub(super) async fn link_agent_session_input<D: AgentDriver + 'static>(
    bot: &InlineClient,
    sessions: &ProviderSessionManager<D>,
    store: &BridgeStore,
    route: &InboundRoute,
    binding: &BindingKey,
    record: &InboundRecord,
) -> Result<Option<i64>, Box<dyn std::error::Error>> {
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
        owner_control
            .connect_agent_session(agent_session_connect_input(
                route,
                session_thread.session(),
                session_thread.workspace_id(),
                binding.chat_id,
                None,
            )?)
            .await?
            .agent_session
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Inline returned an empty agent session connection",
                )
            })?
    };
    if connected_agent_session_chat_id(&agent_session)? != binding.chat_id {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "this provider session is connected to another Inline thread",
        )
        .into());
    }
    let result = bot
        .sync_agent_session_messages(proto::SyncAgentSessionMessagesInput {
            agent_session_id: agent_session.id,
            mode: proto::AgentSessionSyncMode::Live as i32,
            messages: vec![proto::AgentSessionMessageSync {
                role: proto::AgentSessionMessageRole::User as i32,
                item_ref: None,
                correlation_ref: Some(correlation.as_str().to_owned()),
                source_date: None,
                revision_ref: None,
                base_revision_ref: None,
                complete: false,
                operation: Some(proto::agent_session_message_sync::Operation::Link(
                    proto::AgentSessionMessageLink {
                        message_id: record.message_id,
                    },
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
    Ok(Some(agent_session.id))
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
        binding.chat_id,
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

async fn sync_agent_session_snapshot(
    bot: &InlineClient,
    agent_session_id: i64,
    snapshot: &SessionSnapshot,
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
        let text = bounded_agent_message_text(text);
        let correlation_ref = match role {
            proto::AgentSessionMessageRole::User => item
                .confirmed_inline_correlation()
                .map(|correlation| correlation.as_str().to_owned()),
            proto::AgentSessionMessageRole::Assistant => {
                item.run_id.as_ref().map(agent_output_correlation)
            }
            proto::AgentSessionMessageRole::Unspecified => None,
        };
        let assistant_random_id = match (&item.run_id, role) {
            (Some(turn_id), proto::AgentSessionMessageRole::Assistant) => {
                Some(assistant_final_random_id(turn_id).get())
            }
            _ => None,
        };
        if created_at.is_none() && assistant_random_id.is_none() {
            continue;
        }
        let source_date = *created_at;
        let revision_ref = Some(agent_item_revision(item, &text));
        let operation = proto::agent_session_message_sync::Operation::Upsert(
            proto::AgentSessionMessageUpsert {
                text,
                entities: None,
                assistant_random_id,
            },
        );
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

async fn sync_agent_session_items(
    bot: &InlineClient,
    agent_session_id: i64,
    messages: Vec<proto::AgentSessionMessageSync>,
) -> Result<(), Box<dyn std::error::Error>> {
    if messages.is_empty() {
        return Ok(());
    }
    let result = bot
        .sync_agent_session_messages(proto::SyncAgentSessionMessagesInput {
            agent_session_id,
            mode: proto::AgentSessionSyncMode::History as i32,
            messages: messages.clone(),
        })
        .await?;
    if result.messages.len() != messages.len() {
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
) -> Result<i64, Box<dyn std::error::Error>> {
    let provider_label = session_provider_label(summary.session().provider().provider_id());
    let session_title = session_thread_title(summary);
    let session_token = stable_session_token(summary.session());
    let mut request = SendTextRequest::new(
        PeerRef::Chat {
            chat_id: InlineId::new(chat_id),
        },
        format!(
            "**Connected to {provider_label}**\n\nSession: **{}**\nProject: **{}**",
            markdown_escape(&session_title),
            markdown_escape(workspace_label),
        ),
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
    send_text_with_retry(bot, request).await?;
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
                    "Session history opened in [Open thread](inline://thread?id={thread_id}). Send there to resume it in Inline."
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
        SessionAttachmentSupport, SessionReplaySupport, SessionStreamFidelity, SteeringSupport,
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
    fn provider_session_commands_are_claimed_but_unrelated_commands_are_not() {
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
    fn callback_contains_only_token_and_index() {
        let data = session_browser_callback_data(
            "opaque-picker-token",
            SessionBrowserCallbackAction::Open { index: 3 },
        )
        .expect("callback");
        let text = String::from_utf8(data.clone()).expect("utf8 callback");
        assert!(!text.contains("private-provider-session"));
        let callback = parse_session_browser_callback(&format!("{ACTION_PREFIX}open"), &data)
            .expect("callback");
        assert!(matches!(
            callback.action,
            SessionBrowserCallbackAction::Open { index: 3 }
        ));
        assert!(parse_session_browser_callback(&format!("{ACTION_PREFIX}more"), &data).is_none());
    }

    #[test]
    fn picker_actions_never_embed_provider_session_identity() {
        let picker = SessionBrowserPicker {
            installation_id: InstallationId::new("installation-1").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            owner_user_id: 7,
            chat_id: 10,
            message_id: None,
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
            workspace_label: "Project".to_string(),
            sessions: vec![summary("private-provider-session", "Fix tests")],
            expires_at: 100,
        };
        let (text, actions) = session_picker_card("opaque-token", &picker, 0).expect("card");
        let actions = serde_json::to_string(&actions).expect("actions");
        assert!(!text.contains("private-provider-session"));
        assert!(!actions.contains("private-provider-session"));
        assert!(text.starts_with("Recent Codex sessions"));
    }

    #[test]
    fn picker_registry_is_bounded_and_prunes_expired_entries() {
        let runtime = SessionBrowserRuntime::default();
        for index in 0..MAX_PICKERS {
            let picker = SessionBrowserPicker {
                installation_id: InstallationId::new("installation-1").expect("installation"),
                provider_id: ProviderId::new("codex").expect("provider"),
                owner_user_id: 7,
                chat_id: 10,
                message_id: None,
                workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
                workspace_label: "Project".to_string(),
                sessions: vec![summary(&format!("session-{index}"), "Fix tests")],
                expires_at: 10,
            };
            assert!(runtime.insert_picker(format!("token-{index}"), picker, 1));
        }
        let extra = SessionBrowserPicker {
            installation_id: InstallationId::new("installation-1").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            owner_user_id: 7,
            chat_id: 10,
            message_id: None,
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
            workspace_label: "Project".to_string(),
            sessions: vec![summary("extra-session", "Fix tests")],
            expires_at: 20,
        };
        assert!(!runtime.insert_picker("extra".to_string(), extra.clone(), 1));
        assert!(runtime.insert_picker("extra".to_string(), extra, 10));
    }

    #[test]
    fn picker_claim_is_bound_and_remains_retryable_until_publication() {
        let runtime = SessionBrowserRuntime::default();
        let picker = SessionBrowserPicker {
            installation_id: InstallationId::new("installation-1").expect("installation"),
            provider_id: ProviderId::new("codex").expect("provider"),
            owner_user_id: 7,
            chat_id: 10,
            message_id: Some(11),
            workspace_id: WorkspaceId::new("workspace-1").expect("workspace"),
            workspace_label: "Project".to_string(),
            sessions: vec![summary("private-provider-session", "Fix tests")],
            expires_at: 100,
        };
        assert!(runtime.insert_picker("token".to_string(), picker, 1));
        let callback = SessionBrowserCallback {
            version: CALLBACK_VERSION,
            token: "token".to_string(),
            action: SessionBrowserCallbackAction::Open { index: 0 },
        };
        assert!(matches!(
            runtime.claim(
                &callback,
                &InstallationId::new("installation-1").expect("installation"),
                &ProviderId::new("codex").expect("provider"),
                7,
                8,
                10,
                11,
                Some(&WorkspaceId::new("workspace-1").expect("workspace")),
                2,
            ),
            SessionBrowserClaim::Unauthorized
        ));
        assert!(matches!(
            runtime.claim(
                &callback,
                &InstallationId::new("installation-1").expect("installation"),
                &ProviderId::new("codex").expect("provider"),
                7,
                7,
                10,
                12,
                Some(&WorkspaceId::new("workspace-1").expect("workspace")),
                2,
            ),
            SessionBrowserClaim::Stale
        ));
        assert!(matches!(
            runtime.claim(
                &callback,
                &InstallationId::new("installation-1").expect("installation"),
                &ProviderId::new("codex").expect("provider"),
                7,
                7,
                10,
                11,
                Some(&WorkspaceId::new("workspace-1").expect("workspace")),
                2,
            ),
            SessionBrowserClaim::Open(_)
        ));
        assert!(matches!(
            runtime.claim(
                &callback,
                &InstallationId::new("installation-1").expect("installation"),
                &ProviderId::new("codex").expect("provider"),
                7,
                7,
                10,
                11,
                Some(&WorkspaceId::new("workspace-1").expect("workspace")),
                2,
            ),
            SessionBrowserClaim::Open(_)
        ));
        runtime.remove_picker("token");
        assert!(matches!(
            runtime.claim(
                &callback,
                &InstallationId::new("installation-1").expect("installation"),
                &ProviderId::new("codex").expect("provider"),
                7,
                7,
                10,
                11,
                Some(&WorkspaceId::new("workspace-1").expect("workspace")),
                2,
            ),
            SessionBrowserClaim::Stale
        ));
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
        let button = session_button_text(&summary("session-1", &long));
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

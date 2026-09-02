//! Resolves an Inline chat to its durable local workspace binding.

use super::*;

#[derive(Debug)]
pub(in crate::bridge) enum ConversationResolutionError {
    MissingWorkspace,
    ClientStore(inline_client::StoreError),
    Store(inline_agent_bridge::StoreError),
}

const MAX_PARENT_CHAT_DEPTH: usize = 16;

pub(in crate::bridge) enum SettingsConversationResolution {
    Unauthorized,
    Ready(ActiveConversation),
}

impl std::fmt::Display for ConversationResolutionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingWorkspace => formatter.write_str(BridgeNotice::MissingWorkspace.message()),
            Self::ClientStore(error) => std::fmt::Display::fmt(error, formatter),
            Self::Store(error) => std::fmt::Display::fmt(error, formatter),
        }
    }
}

impl std::error::Error for ConversationResolutionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::MissingWorkspace => None,
            Self::ClientStore(error) => Some(error),
            Self::Store(error) => Some(error),
        }
    }
}

impl From<inline_agent_bridge::StoreError> for ConversationResolutionError {
    fn from(error: inline_agent_bridge::StoreError) -> Self {
        Self::Store(error)
    }
}

impl From<inline_client::StoreError> for ConversationResolutionError {
    fn from(error: inline_client::StoreError) -> Self {
        Self::ClientStore(error)
    }
}

pub(in crate::bridge) fn conversation_for_chat(
    route: &InboundRoute,
    chat_id: i64,
) -> Result<ActiveConversation, ConversationResolutionError> {
    conversation_for_chat_with_fallback(route, chat_id, None)
}

pub(in crate::bridge) async fn conversation_for_chat_inheriting_parent(
    route: &InboundRoute,
    chat_id: i64,
) -> Result<ActiveConversation, ConversationResolutionError> {
    if route
        .store
        .bound_chat_workspace(&route.installation_id, chat_id)?
        .is_some()
    {
        return conversation_for_chat(route, chat_id);
    }
    let inherited = inherited_parent_workspace(route, chat_id).await?;
    conversation_for_chat_with_fallback(route, chat_id, inherited)
}

fn conversation_for_chat_with_fallback(
    route: &InboundRoute,
    chat_id: i64,
    inherited: Option<WorkspaceRecord>,
) -> Result<ActiveConversation, ConversationResolutionError> {
    let workspace = match route
        .store
        .bound_chat_workspace(&route.installation_id, chat_id)?
    {
        Some(workspace) => route
            .store
            .verified_workspace(
                &route.installation_id,
                &workspace.workspace_id,
                now_seconds(),
            )
            .map_err(|error| match error {
                inline_agent_bridge::StoreError::WorkspaceUnavailable { .. } => {
                    ConversationResolutionError::MissingWorkspace
                }
                error => ConversationResolutionError::Store(error),
            })?,
        None => {
            let workspace = match inherited {
                Some(workspace) => workspace,
                None => default_workspace_or_home(route)?,
            };
            bind_chat_workspace(route, chat_id, workspace)?
        }
    };
    Ok(ActiveConversation::new(
        BindingKey {
            installation_id: route.installation_id.clone(),
            chat_id,
            workspace_id: workspace.workspace_id,
        },
        workspace.path,
    ))
}

async fn inherited_parent_workspace(
    route: &InboundRoute,
    chat_id: i64,
) -> Result<Option<WorkspaceRecord>, ConversationResolutionError> {
    let mut current_chat_id = chat_id;
    let mut visited = HashSet::new();
    for _ in 0..MAX_PARENT_CHAT_DEPTH {
        if !visited.insert(current_chat_id) {
            return Ok(None);
        }
        let Some(dialog) = route
            .bot_store
            .dialog(InlineId::new(current_chat_id))
            .await?
        else {
            return Ok(None);
        };
        let Some(parent_chat_id) = dialog.parent_chat_id.map(InlineId::get) else {
            return Ok(None);
        };
        if let Some(workspace) = route
            .store
            .bound_chat_workspace(&route.installation_id, parent_chat_id)?
        {
            return Ok(Some(workspace));
        }
        current_chat_id = parent_chat_id;
    }
    Ok(None)
}

fn default_workspace_or_home(
    route: &InboundRoute,
) -> Result<WorkspaceRecord, ConversationResolutionError> {
    let selected_at = now_seconds();
    route
        .store
        .refresh_workspace_availability(&route.installation_id, selected_at)?;
    if let Some(workspace) = route.store.default_workspace(&route.installation_id)? {
        match route.store.verified_workspace(
            &route.installation_id,
            &workspace.workspace_id,
            selected_at,
        ) {
            Ok(workspace) => return Ok(workspace),
            Err(inline_agent_bridge::StoreError::WorkspaceUnavailable { .. }) => {}
            Err(error) => return Err(error.into()),
        }
    }

    home_workspace(route)
}

fn home_workspace(route: &InboundRoute) -> Result<WorkspaceRecord, ConversationResolutionError> {
    let selected_at = now_seconds();
    let home =
        resolve_setup_workspace(None).map_err(|_| ConversationResolutionError::MissingWorkspace)?;
    let home_id = workspace_id(&home).map_err(|_| ConversationResolutionError::MissingWorkspace)?;
    Ok(route
        .store
        .select_workspace(&route.installation_id, &home_id, &home, selected_at)?)
}

fn bind_chat_workspace(
    route: &InboundRoute,
    chat_id: i64,
    workspace: WorkspaceRecord,
) -> Result<WorkspaceRecord, ConversationResolutionError> {
    match route.store.bind_chat_workspace(
        &route.installation_id,
        chat_id,
        &workspace.workspace_id,
        now_seconds(),
    ) {
        Ok(workspace) => Ok(workspace),
        Err(inline_agent_bridge::StoreError::WorkspaceUnavailable { .. }) => {
            Err(ConversationResolutionError::MissingWorkspace)
        }
        Err(error) => Err(error.into()),
    }
}

pub(in crate::bridge) async fn conversation_for_settings_event(
    route: &InboundRoute,
    event: &ClientEvent,
    existing: Option<&ActiveConversation>,
) -> Result<SettingsConversationResolution, ConversationResolutionError> {
    let actor_user_id = match event {
        ClientEvent::BotInteraction(
            BotInteractionEvent::ChatSettingsRequested { actor_user_id, .. }
            | BotInteractionEvent::ChatSettingsItemInvoked { actor_user_id, .. },
        ) => actor_user_id.get(),
        _ => return Ok(SettingsConversationResolution::Unauthorized),
    };
    if actor_user_id != route.owner_user_id {
        return Ok(SettingsConversationResolution::Unauthorized);
    }
    let chat_id = actionable_event_chat_id(event)
        .expect("bot settings events always carry an actionable chat id");
    if let Some(existing) = existing
        && existing.snapshot().binding.chat_id == chat_id
    {
        return Ok(SettingsConversationResolution::Ready(existing.clone()));
    }
    conversation_for_workspace_selection_inheriting_parent(route, chat_id)
        .await
        .map(SettingsConversationResolution::Ready)
}

pub(in crate::bridge) async fn conversation_for_workspace_selection_inheriting_parent(
    route: &InboundRoute,
    chat_id: i64,
) -> Result<ActiveConversation, ConversationResolutionError> {
    let inherited = if route
        .store
        .bound_chat_workspace(&route.installation_id, chat_id)?
        .is_some()
    {
        None
    } else {
        inherited_parent_workspace(route, chat_id).await?
    };
    conversation_for_workspace_selection_with_fallback(route, chat_id, inherited)
}

fn conversation_for_workspace_selection_with_fallback(
    route: &InboundRoute,
    chat_id: i64,
    inherited: Option<WorkspaceRecord>,
) -> Result<ActiveConversation, ConversationResolutionError> {
    match conversation_for_chat_with_fallback(route, chat_id, inherited.clone()) {
        Ok(conversation) => Ok(conversation),
        Err(ConversationResolutionError::MissingWorkspace) => {
            // Settings and /projects are recovery surfaces for a disappeared or
            // replaced folder. Preserve the unavailable binding for display
            // and folder selection only; normal turns still fail closed in
            // `conversation_for_chat` until the owner chooses a verified path.
            let workspace = route
                .store
                .bound_chat_workspace(&route.installation_id, chat_id)?
                .or(inherited);
            let Some(workspace) = workspace else {
                return Err(ConversationResolutionError::MissingWorkspace);
            };
            Ok(ActiveConversation::new(
                BindingKey {
                    installation_id: route.installation_id.clone(),
                    chat_id,
                    workspace_id: workspace.workspace_id,
                },
                workspace.path,
            ))
        }
        Err(error) => Err(error),
    }
}

pub(in crate::bridge) fn repair_promoted_conversation_cache(
    route: &InboundRoute,
    conversations: &mut HashMap<i64, ActiveConversation>,
    source_chat_id: i64,
    delivery_chat_id: i64,
) -> Result<(), ConversationResolutionError> {
    if let Some(promoted) = conversations.remove(&source_chat_id)
        && promoted.snapshot().binding.chat_id == delivery_chat_id
    {
        conversations.insert(delivery_chat_id, promoted);
    }
    let source = conversation_for_chat(route, source_chat_id)?;
    conversations.insert(source_chat_id, source);
    Ok(())
}

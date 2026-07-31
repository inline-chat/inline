//! Resolves an Inline chat to its durable local workspace binding.

use super::*;

#[derive(Debug)]
pub(in crate::bridge) enum ConversationResolutionError {
    MissingWorkspace,
    Store(inline_agent_bridge::StoreError),
}

pub(in crate::bridge) enum SettingsConversationResolution {
    Unauthorized,
    Ready(ActiveConversation),
}

impl std::fmt::Display for ConversationResolutionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingWorkspace => formatter.write_str(BridgeNotice::MissingWorkspace.message()),
            Self::Store(error) => std::fmt::Display::fmt(error, formatter),
        }
    }
}

impl std::error::Error for ConversationResolutionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::MissingWorkspace => None,
            Self::Store(error) => Some(error),
        }
    }
}

impl From<inline_agent_bridge::StoreError> for ConversationResolutionError {
    fn from(error: inline_agent_bridge::StoreError) -> Self {
        Self::Store(error)
    }
}

pub(in crate::bridge) fn conversation_for_chat(
    route: &InboundRoute,
    chat_id: i64,
) -> Result<ActiveConversation, ConversationResolutionError> {
    let workspace = match route
        .store
        .bound_chat_workspace(&route.installation_id, chat_id)?
    {
        Some(workspace) if workspace.missing_since.is_none() => route
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
        Some(workspace) => {
            if workspace.missing_since.is_none() {
                route.store.mark_workspace_unavailable(
                    &route.installation_id,
                    &workspace.workspace_id,
                    now_seconds(),
                )?;
            }
            return Err(ConversationResolutionError::MissingWorkspace);
        }
        None => {
            route
                .store
                .refresh_workspace_availability(&route.installation_id, now_seconds())?;
            let Some(workspace) = route.store.default_workspace(&route.installation_id)? else {
                return Err(ConversationResolutionError::MissingWorkspace);
            };
            match route.store.bind_chat_workspace(
                &route.installation_id,
                chat_id,
                &workspace.workspace_id,
                now_seconds(),
            ) {
                Ok(workspace) => workspace,
                Err(inline_agent_bridge::StoreError::WorkspaceUnavailable { .. }) => {
                    return Err(ConversationResolutionError::MissingWorkspace);
                }
                Err(error) => return Err(error.into()),
            }
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

pub(in crate::bridge) fn conversation_for_settings_event(
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
    if let Some(existing) = existing {
        return Ok(SettingsConversationResolution::Ready(existing.clone()));
    }
    conversation_for_chat(route, chat_id).map(SettingsConversationResolution::Ready)
}

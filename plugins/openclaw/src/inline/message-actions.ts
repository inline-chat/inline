export type InlineMessageActionOwner = "agent" | "system"

export type InlineMessageActionOwnership = {
  owner: InlineMessageActionOwner
  explicit: boolean
}

export const INLINE_AGENT_ACTION_PREFIX = "agent:"
export const INLINE_SYSTEM_ACTION_PREFIX = "system:"

/**
 * Inline callback actions have one owner. Agent-owned actions become model
 * turns; system-owned actions stay inside deterministic adapter handlers.
 *
 * Ownership lives in actionId, never callback data: callback data is opaque
 * agent/application input and may legitimately resemble a native command.
 * Unprefixed IDs are legacy. They remain eligible for existing system parsers,
 * then fall through to the agent path when no system handler consumes them.
 */
export function resolveInlineMessageActionOwnership(actionId: string): InlineMessageActionOwnership {
  if (actionId.startsWith(INLINE_AGENT_ACTION_PREFIX)) {
    return { owner: "agent", explicit: true }
  }
  if (actionId.startsWith(INLINE_SYSTEM_ACTION_PREFIX)) {
    return { owner: "system", explicit: true }
  }
  return { owner: "agent", explicit: false }
}

export function buildInlineMessageActionId(
  owner: InlineMessageActionOwner,
  rowIndex: number,
  actionIndex: number,
): string {
  return `${owner}:${rowIndex + 1}:${actionIndex + 1}`
}

export function buildInlineAgentActionBody(params: {
  actor: string
  targetMessageId: bigint
}): string {
  return `Inline action button pressed on message #${String(params.targetMessageId)} by ${params.actor}.`
}

export function buildInlineAgentActionStructuredContext(params: {
  actorUserId: bigint
  chatId: bigint
  targetMessageId: bigint
  interactionId: bigint
  actionId: string
  callbackDataBase64: string
  callbackDataUtf8?: string
}) {
  return {
    label: "Inline action button press",
    source: "inline" as const,
    type: "message_action",
    payload: {
      event_kind: "message.action.invoke",
      actor_user_id: String(params.actorUserId),
      chat_id: String(params.chatId),
      target_message_id: String(params.targetMessageId),
      interaction_id: String(params.interactionId),
      action_id: params.actionId,
      callback_data_base64: params.callbackDataBase64,
      ...(params.callbackDataUtf8 ? { callback_data_utf8: params.callbackDataUtf8 } : {}),
    },
  }
}

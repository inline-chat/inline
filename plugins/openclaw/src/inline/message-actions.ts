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
  widgetCall?: InlineWidgetCall | null
  widgetInteraction?: boolean
}) {
  const widget = params.widgetInteraction === true || params.widgetCall != null
  return {
    label: widget ? "Inline widget call" : "Inline action button press",
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
      ...(params.widgetCall
        ? {
            widget_call: {
              widget_id: params.actionId,
              name: params.widgetCall.name,
              ...(params.widgetCall.payloadJson !== undefined ? { payload_json: params.widgetCall.payloadJson } : {}),
              trust: "untrusted_viewer_input",
            },
          }
        : {}),
    },
  }
}

/** A viewer's `inline.action(name, payload)` call from inside a widget. */
export type InlineWidgetCall = {
  name: string
  /** The UTF-8 JSON payload as sent, when present and decodable. */
  payloadJson?: string
}

const INLINE_WIDGET_CALL_NAME_MAX_LENGTH = 64
const INLINE_WIDGET_CALL_PAYLOAD_MAX_LENGTH = 4096

/** Reads the `widgetCall` of a message action event; null when absent or malformed. */
export function readInlineWidgetCall(raw: unknown): InlineWidgetCall | null {
  if (raw == null || typeof raw !== "object") return null
  const record = raw as { name?: unknown; payload?: unknown }
  const name = typeof record.name === "string"
    ? record.name.trim().slice(0, INLINE_WIDGET_CALL_NAME_MAX_LENGTH)
    : ""
  if (!name) return null
  if (!(record.payload instanceof Uint8Array) || record.payload.byteLength === 0) return { name }
  let payloadJson: string
  try {
    payloadJson = new TextDecoder("utf-8", { fatal: true }).decode(record.payload)
  } catch {
    return { name }
  }
  return { name, payloadJson: payloadJson.slice(0, INLINE_WIDGET_CALL_PAYLOAD_MAX_LENGTH) }
}

/**
 * A widget call names its widget in action_id and carries no callback data.
 * Buttons this plugin sends always carry an `agent:`/`system:` id and data, so
 * an unprefixed, data-less action is treated as coming from a widget even when
 * the SDK does not expose its `widgetCall`.
 */
export function isInlineWidgetInteraction(params: {
  actionId: string
  data: Uint8Array
  widgetCall?: InlineWidgetCall | null
}): boolean {
  if (params.widgetCall) return true
  return params.data.byteLength === 0 && !resolveInlineMessageActionOwnership(params.actionId).explicit
}

export function buildInlineWidgetCallBody(params: {
  actor: string
  targetMessageId: bigint
  widgetId: string
  widgetCall?: InlineWidgetCall | null
}): string {
  const where = `Inline widget ${JSON.stringify(params.widgetId)} on message #${String(params.targetMessageId)}`
  const call = params.widgetCall
  if (!call) return `${where} was used by ${params.actor}; the call details are unavailable.`
  const payload = call.payloadJson !== undefined
    ? ` Payload (untrusted viewer input, JSON): ${call.payloadJson}`
    : " No payload."
  return `${where} called ${JSON.stringify(call.name)}, by ${params.actor}.${payload}`
}

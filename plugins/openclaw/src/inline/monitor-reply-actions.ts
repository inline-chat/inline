import {
  InlineSdkClient,
  Method,
  type MessageActions,
  type MessageActionResponseUi,
} from "@inline-chat/realtime-sdk"
import { buildInlinePresentationButtons, resolveInlineMessageActionsParam } from "./actions.js"
import { normalizeMessagePresentation } from "openclaw/plugin-sdk/interactive-runtime"
import type { InlineMessageActionOwner } from "./message-actions.js"
import { sanitizeInlineVisibleText } from "./outbound-sanitize.js"
import { isRecord } from "./monitor-shared.js"
import { normalizeInlineCommandBody, parseInlineNativeCommandCallbackData } from "./monitor-addressing.js"
import {
  mapInlineModelPickerCallbackToCommand,
  parseInlineModelPickerCallback,
} from "./monitor-model-menu.js"

export function callbackDataToBase64(data: Uint8Array): string {
  return Buffer.from(data).toString("base64")
}

export function callbackDataToUtf8(data: Uint8Array): string | undefined {
  try {
    const decoded = new TextDecoder("utf-8", { fatal: true }).decode(data).trim()
    return decoded || undefined
  } catch {
    return undefined
  }
}

const INLINE_CALLBACK_TOAST_MAX_LENGTH = 256

function normalizeInlineCallbackToastText(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined

  const visible = sanitizeInlineVisibleText(raw)
  if (visible.shouldSkip) return undefined

  const text = visible.text.replace(/\s+/g, " ").trim()
  if (!text) return undefined

  if (text.length <= INLINE_CALLBACK_TOAST_MAX_LENGTH) {
    return text
  }

  return text.slice(0, INLINE_CALLBACK_TOAST_MAX_LENGTH).trimEnd()
}

export function resolveInlineCallbackResponseUi(data: Uint8Array): MessageActionResponseUi | undefined {
  const decoded = callbackDataToUtf8(data)
  if (!decoded) return undefined

  let parsed: unknown
  try {
    parsed = JSON.parse(decoded)
  } catch {
    return undefined
  }

  if (!isRecord(parsed)) return undefined

  const text =
    normalizeInlineCallbackToastText(parsed.callbackToast) ??
    normalizeInlineCallbackToastText(parsed.callback_toast) ??
    normalizeInlineCallbackToastText(parsed.toast)

  if (!text) return undefined

  return {
    kind: {
      oneofKind: "toast",
      toast: { text },
    },
  }
}

function normalizeInlineActionCallbackData(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ""
  const nativeCommandText = parseInlineNativeCommandCallbackData(trimmed)
  if (nativeCommandText) return nativeCommandText
  return mapInlineModelPickerCallbackToCommand(trimmed) ?? trimmed
}

function normalizeCompatibleButtonCallbackData(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ""
  if (parseInlineModelPickerCallback(trimmed)) return trimmed
  return normalizeInlineActionCallbackData(trimmed)
}

export function resolveInlineReplyActions(
  payload: Record<string, unknown>,
  options?: { owner?: InlineMessageActionOwner },
): MessageActions | undefined {
  const owner = options?.owner ?? "agent"
  const channelData = isRecord(payload.channelData) ? payload.channelData : undefined
  const inlineData = channelData && isRecord(channelData.inline) ? channelData.inline : undefined
  const telegramData = channelData && isRecord(channelData.telegram) ? channelData.telegram : undefined

  let rawButtons: unknown = undefined
  let hasExplicitButtons = false
  let mapCallbackData: ((value: string) => string) | undefined

  if (inlineData && Object.prototype.hasOwnProperty.call(inlineData, "buttons")) {
    rawButtons = inlineData.buttons
    hasExplicitButtons = true
  } else if (telegramData && Object.prototype.hasOwnProperty.call(telegramData, "buttons")) {
    // Backwards compatibility for replies emitted before Inline had its own command surface.
    rawButtons = telegramData.buttons
    hasExplicitButtons = true
    mapCallbackData = normalizeCompatibleButtonCallbackData
  } else if (Object.prototype.hasOwnProperty.call(payload, "buttons")) {
    rawButtons = payload.buttons
    hasExplicitButtons = true
  }

  if (!hasExplicitButtons) {
    const legacyActions = resolveInlineMessageActionsParam(payload, { owner })
    if (legacyActions) return legacyActions
    // Host replies can carry buttons only as a MessagePresentation.
    const presentation = normalizeMessagePresentation(payload.presentation)
    if (!presentation) return undefined
    rawButtons = buildInlinePresentationButtons(presentation).filter((row) => row.length > 0)
    if ((rawButtons as unknown[]).length === 0) return undefined
  }

  return resolveInlineMessageActionsParam(
    { buttons: rawButtons },
    { owner, ...(mapCallbackData ? { mapCallbackData } : {}) },
  )
}

export async function answerInlineMessageAction(
  client: InlineSdkClient,
  interactionId: bigint,
  ui?: MessageActionResponseUi,
): Promise<void> {
  const withAnswer = client as InlineSdkClient & {
    answerMessageAction?: (params: { interactionId: bigint; ui?: MessageActionResponseUi }) => Promise<void>
    invokeUncheckedRaw?: (
      method: Method,
      input?: {
        oneofKind?: string
        answerMessageAction?: { interactionId: bigint; ui?: MessageActionResponseUi }
      },
    ) => Promise<unknown>
  }

  if (typeof withAnswer.answerMessageAction === "function") {
    await withAnswer.answerMessageAction({ interactionId, ...(ui ? { ui } : {}) })
    return
  }

  const answerMethod = (Method as Record<string, unknown>)["ANSWER_MESSAGE_ACTION"]
  if (typeof answerMethod === "number" && typeof withAnswer.invokeUncheckedRaw === "function") {
    await withAnswer.invokeUncheckedRaw(answerMethod as Method, {
      oneofKind: "answerMessageAction",
      answerMessageAction: { interactionId, ...(ui ? { ui } : {}) },
    })
  }
}

export function resolveCallbackCommandBodyFromActionData(params: {
  data: Uint8Array
  botUsername?: string
}): string | undefined {
  const decoded = callbackDataToUtf8(params.data)
  if (!decoded) return undefined
  const normalized = normalizeInlineActionCallbackData(decoded)
  if (!normalized.startsWith("/")) return undefined
  return normalizeInlineCommandBody(normalized, params.botUsername)
}

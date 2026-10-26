import {
  AgentGrantRequirement,
  MessageAction,
  MessageAction_Style,
  MessageActionCallback,
  MessageActionResponseUi,
  MessageActions,
  MessageActionRow,
  type BlockContent,
  type MessageActionConfirm,
} from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { findForm } from "@in/server/modules/message/messageForms"

const maxRows = 8
const maxActionsPerRow = 8
const maxActionIdLength = 64
const maxButtonTextLength = 64
const maxCallbackBytes = 1024
const maxCopyTextLength = 4096
const maxToastTextLength = 256
const maxAlertTitleLength = 128
const maxAlertTextLength = 2048
const maxUrlLength = 2048
const maxConfirmTitleLength = 128
const maxConfirmTextLength = 1024

const actionIdPattern = /^[a-zA-Z0-9_.:-]+$/
const urlSchemePattern = /^([a-z][a-z0-9+.-]*):/i
/** Schemes that run code or read local data in the client. */
const blockedUrlSchemes = new Set(["javascript", "data", "file", "vbscript", "about", "blob"])

function boundedText(value: string | undefined, maxLength: number, required: boolean): string | undefined {
  const text = value?.trim()
  if (!text) {
    if (required) throw RealtimeRpcError.BadRequest()
    return undefined
  }
  if (text.length > maxLength) throw RealtimeRpcError.BadRequest()
  return text
}

/** Web URLs and app links such as codex://threads/<id>; never script or local schemes. */
export function validActionUrl(value: string): string {
  const url = value.trim()
  if (url.length < 1 || url.length > maxUrlLength || /\s/.test(url)) throw RealtimeRpcError.BadRequest()
  const scheme = urlSchemePattern.exec(url)?.[1]?.toLowerCase()
  if (!scheme || blockedUrlSchemes.has(scheme)) throw RealtimeRpcError.BadRequest()
  try {
    new URL(url)
  } catch {
    throw RealtimeRpcError.BadRequest()
  }
  return url
}

function normalizeConfirm(confirm: MessageActionConfirm | undefined): MessageActionConfirm | undefined {
  if (!confirm) return undefined
  return {
    title: boundedText(confirm.title, maxConfirmTitleLength, true)!,
    text: boundedText(confirm.text, maxConfirmTextLength, false),
    confirmText: boundedText(confirm.confirmText, maxButtonTextLength, false),
  }
}

function normalizeAction(action: MessageAction): MessageAction["action"] {
  switch (action.action.oneofKind) {
    case "callback":
      if (action.action.callback.data.length > maxCallbackBytes) throw RealtimeRpcError.BadRequest()
      return { oneofKind: "callback", callback: MessageActionCallback.create({ data: action.action.callback.data }) }
    case "copyText":
      return {
        oneofKind: "copyText",
        copyText: { text: boundedText(action.action.copyText.text, maxCopyTextLength, true)! },
      }
    case "openUrl":
      return { oneofKind: "openUrl", openUrl: { url: validActionUrl(action.action.openUrl.url) } }
    case "openLink": {
      const { peerId, messageId } = action.action.openLink
      const target = peerId?.type.oneofKind === "chat"
        ? peerId.type.chat.chatId
        : peerId?.type.oneofKind === "user" ? peerId.type.user.userId : undefined
      if (target === undefined || target <= 0n || (messageId !== undefined && messageId <= 0n)) {
        throw RealtimeRpcError.BadRequest()
      }
      return { oneofKind: "openLink", openLink: { peerId, messageId } }
    }
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

export function normalizeAndValidateMessageActions(
  actions: MessageActions | undefined,
  blockContent?: BlockContent | null,
): MessageActions | undefined {
  if (actions === undefined) {
    return undefined
  }

  if (actions.rows.length > maxRows) {
    throw RealtimeRpcError.BadRequest()
  }

  // Forms are submitted through their form_id, so action IDs must not collide.
  const usedActionIds = new Set<string>()
  const normalizedRows: MessageActionRow[] = []

  for (const row of actions.rows) {
    if (row.actions.length > maxActionsPerRow) {
      throw RealtimeRpcError.BadRequest()
    }

    const normalizedActions: MessageAction[] = []

    for (const action of row.actions) {
      const actionId = action.actionId.trim()
      const text = action.text.trim()

      if (
        actionId.length < 1 ||
        actionId.length > maxActionIdLength ||
        !actionIdPattern.test(actionId) ||
        usedActionIds.has(actionId) ||
        findForm(blockContent, actionId) !== undefined
      ) {
        throw RealtimeRpcError.BadRequest()
      }

      if (text.length < 1 || text.length > maxButtonTextLength) {
        throw RealtimeRpcError.BadRequest()
      }
      if (action.style < MessageAction_Style.DEFAULT || action.style > MessageAction_Style.DESTRUCTIVE) {
        throw RealtimeRpcError.BadRequest()
      }
      if (action.requiredGrant < AgentGrantRequirement.NONE || action.requiredGrant > AgentGrantRequirement.OWNER) {
        throw RealtimeRpcError.BadRequest()
      }

      usedActionIds.add(actionId)
      normalizedActions.push(MessageAction.create({
        actionId,
        text,
        action: normalizeAction(action),
        style: action.style,
        confirm: normalizeConfirm(action.confirm),
        requiredGrant: action.requiredGrant,
      }))
    }

    normalizedRows.push(
      MessageActionRow.create({
        actions: normalizedActions,
      }),
    )
  }

  return MessageActions.create({
    rows: normalizedRows,
  })
}

export function findCallbackActionById(input: {
  actions: MessageActions | null | undefined
  actionId: string
}): MessageActionCallback | null {
  return findCallbackAction(input)?.callback ?? null
}

/** A callback action and the grant it requires, or null for client-only and missing actions. */
export function findCallbackAction(input: {
  actions: MessageActions | null | undefined
  actionId: string
}): { callback: MessageActionCallback; requiredGrant: AgentGrantRequirement } | null {
  const targetActionId = input.actionId.trim()
  if (!targetActionId) return null
  if (!input.actions) return null

  for (const row of input.actions.rows) {
    for (const action of row.actions) {
      if (action.actionId !== targetActionId) continue
      if (action.action.oneofKind !== "callback") return null
      return { callback: action.action.callback, requiredGrant: action.requiredGrant }
    }
  }

  return null
}

export function normalizeActionResponseUi(
  ui: MessageActionResponseUi | undefined,
): MessageActionResponseUi | undefined {
  if (ui === undefined || ui.kind.oneofKind === undefined) {
    return undefined
  }

  switch (ui.kind.oneofKind) {
    case "toast":
      return MessageActionResponseUi.create({
        kind: { oneofKind: "toast", toast: { text: boundedText(ui.kind.toast.text, maxToastTextLength, true)! } },
      })
    case "alert":
      return MessageActionResponseUi.create({
        kind: {
          oneofKind: "alert",
          alert: {
            title: boundedText(ui.kind.alert.title, maxAlertTitleLength, false),
            text: boundedText(ui.kind.alert.text, maxAlertTextLength, true)!,
          },
        },
      })
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

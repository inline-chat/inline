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
import { collectBlockActionIds } from "@in/server/modules/message/blockContent"

const maxRows = 8
const maxActionsPerRow = 8
const maxActionIdLength = 64
const maxButtonTextLength = 64
const maxCallbackBytes = 1024
const maxCopyTextLength = 4096
const maxComposeTextLength = 4000
const maxToastTextLength = 256
const maxAlertTitleLength = 128
const maxAlertTextLength = 2048
const maxUrlLength = 2048
// One-time login links (OpenClaw bootstrap tokens) run longer than buttons.
const maxResponseUrlLength = 4096
const maxHostLabelLength = 128
const maxUnreachableTextLength = 1024
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
export function validActionUrl(value: string, maxLength: number = maxUrlLength): string {
  const url = value.trim()
  if (url.length < 1 || url.length > maxLength || /\s/.test(url)) throw RealtimeRpcError.BadRequest()
  const scheme = urlSchemePattern.exec(url)?.[1]?.toLowerCase()
  if (!scheme || blockedUrlSchemes.has(scheme)) throw RealtimeRpcError.BadRequest()
  try {
    new URL(url)
  } catch {
    throw RealtimeRpcError.BadRequest()
  }
  return url
}

/** A URL a bot answers with. A user:password part would hide the real host. */
function validResponseUrl(value: string): string {
  const url = validActionUrl(value, maxResponseUrlLength)
  const parsed = new URL(url)
  if (parsed.username || parsed.password) throw RealtimeRpcError.BadRequest()
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
    // Client-side, like copy_text: fills the viewer's composer and never reaches the bot.
    case "compose":
      return {
        oneofKind: "compose",
        compose: { text: boundedText(action.action.compose.text, maxComposeTextLength, true)! },
      }
    case undefined:
      throw RealtimeRpcError.BadRequest()
    default:
      action.action satisfies never
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

/**
 * Every action a block draws as its own button (`action_ids`, a review finding's `action_id`)
 * must be one of the message's actions. Call with what the message will hold after the write.
 */
export function validateBlockActionReferences(
  blockContent: BlockContent | null | undefined,
  actions: MessageActions | null | undefined,
): void {
  if (!blockContent) return
  const referenced = collectBlockActionIds(blockContent.blocks)
  if (referenced.length === 0) return
  const available = new Set(actions?.rows.flatMap((row) => row.actions.map((action) => action.actionId)) ?? [])
  if (referenced.some((actionId) => !available.has(actionId))) throw RealtimeRpcError.BadRequest()
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
    case "openUrl":
      return MessageActionResponseUi.create({
        kind: {
          oneofKind: "openUrl",
          openUrl: {
            url: validResponseUrl(ui.kind.openUrl.url),
            sensitive: ui.kind.openUrl.sensitive,
            hostLabel: boundedText(ui.kind.openUrl.hostLabel, maxHostLabelLength, false),
            unreachableText: boundedText(ui.kind.openUrl.unreachableText, maxUnreachableTextLength, false),
          },
        },
      })
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

/**
 * The copy of an answer kept for sync. A sensitive URL is a credential, so only
 * the live delivery carries it; apps never open answers from catch-up anyway.
 */
export function storedActionResponseUi(
  ui: MessageActionResponseUi | undefined,
): MessageActionResponseUi | undefined {
  if (ui?.kind.oneofKind !== "openUrl" || !ui.kind.openUrl.sensitive) return ui
  return MessageActionResponseUi.create({
    kind: { oneofKind: "openUrl", openUrl: { ...ui.kind.openUrl, url: "" } },
  })
}

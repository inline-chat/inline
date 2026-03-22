import {
  MessageAction,
  MessageActionCallback,
  MessageActionCopyText,
  MessageActionResponseUi,
  MessageActionToast,
  MessageActions,
  MessageActionRow,
} from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"

const maxRows = 8
const maxActionsPerRow = 8
const maxActionIdLength = 64
const maxButtonTextLength = 64
const maxCallbackBytes = 1024
const maxCopyTextLength = 4096
const maxToastTextLength = 256

const actionIdPattern = /^[a-zA-Z0-9_.:-]+$/

export function normalizeAndValidateMessageActions(actions: MessageActions | undefined): MessageActions | undefined {
  if (actions === undefined) {
    return undefined
  }

  if (actions.rows.length > maxRows) {
    throw RealtimeRpcError.BadRequest()
  }

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
        usedActionIds.has(actionId)
      ) {
        throw RealtimeRpcError.BadRequest()
      }

      if (text.length < 1 || text.length > maxButtonTextLength) {
        throw RealtimeRpcError.BadRequest()
      }

      usedActionIds.add(actionId)

      if (action.action.oneofKind === "callback") {
        if (action.action.callback.data.length > maxCallbackBytes) {
          throw RealtimeRpcError.BadRequest()
        }

        normalizedActions.push(
          MessageAction.create({
            actionId,
            text,
            action: {
              oneofKind: "callback",
              callback: MessageActionCallback.create({
                data: action.action.callback.data,
              }),
            },
          }),
        )
        continue
      }

      if (action.action.oneofKind === "copyText") {
        const copyText = action.action.copyText.text.trim()
        if (copyText.length < 1 || copyText.length > maxCopyTextLength) {
          throw RealtimeRpcError.BadRequest()
        }

        normalizedActions.push(
          MessageAction.create({
            actionId,
            text,
            action: {
              oneofKind: "copyText",
              copyText: MessageActionCopyText.create({
                text: copyText,
              }),
            },
          }),
        )
        continue
      }

      throw RealtimeRpcError.BadRequest()
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
  const targetActionId = input.actionId.trim()
  if (!targetActionId) return null
  if (!input.actions) return null

  for (const row of input.actions.rows) {
    for (const action of row.actions) {
      if (action.actionId !== targetActionId) continue
      if (action.action.oneofKind !== "callback") return null
      return action.action.callback
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

  // v1 supports only toast while keeping schema expandable.
  if (ui.kind.oneofKind !== "toast") {
    throw RealtimeRpcError.BadRequest()
  }

  const text = ui.kind.toast.text.trim()
  if (text.length < 1 || text.length > maxToastTextLength) {
    throw RealtimeRpcError.BadRequest()
  }

  return MessageActionResponseUi.create({
    kind: {
      oneofKind: "toast",
      toast: MessageActionToast.create({
        text,
      }),
    },
  })
}

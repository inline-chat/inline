import {
  type RpcResult,
  Update,
  type Message as ProtocolMessage,
} from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  type DeferredUpdate,
} from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import {
  applyResidentReactionUpdate,
  reactionUpdateTargetKey,
} from "./message-reaction-update"
import {
  applyResidentMessageAttachmentUpdate,
  messageAttachmentUpdateTargetKey,
} from "./message-attachment-update"

export type DeferredMessageReplayReport = {
  applied: number
  retained: number
}

const compareDeferredUpdates = (
  left: DeferredUpdate,
  right: DeferredUpdate,
) => {
  if (left.seq != null && right.seq != null && left.seq !== right.seq) {
    return left.seq - right.seq
  }
  if (left.date != null && right.date != null && left.date !== right.date) {
    return left.date - right.date
  }
  return left.id.localeCompare(right.id)
}

export const protocolMessageKey = (
  message: ProtocolMessage,
) => messageKey(chatId(message.chatId), messageId(message.id))

export const deferredMessageKeysFromUpdates = (
  updates: readonly Update[],
) =>
  Array.from(
    new Set(
      updates.flatMap((update) => {
        const targetKey =
          reactionUpdateTargetKey(update) ??
          messageAttachmentUpdateTargetKey(update)
        if (targetKey) return [targetKey]
        switch (update.update.oneofKind) {
          case "newMessage":
            return update.update.newMessage.message
              ? [protocolMessageKey(update.update.newMessage.message)]
              : []
          case "editMessage":
            return update.update.editMessage.message
              ? [protocolMessageKey(update.update.editMessage.message)]
              : []
          default:
            return []
        }
      }),
    ),
  )

export const deferredMessageKeysFromRpcResult = (
  result: RpcResult["result"] | undefined,
): string[] => {
  if (!result) return []
  switch (result.oneofKind) {
    case "getChats":
      return result.getChats.messages.map(protocolMessageKey)
    case "getChatHistory":
      return result.getChatHistory.messages.map(protocolMessageKey)
    case "getMessages":
      return result.getMessages.messages.map(protocolMessageKey)
    case "getChat":
      return result.getChat.anchorMessage
        ? [protocolMessageKey(result.getChat.anchorMessage)]
        : []
    case "addReaction":
      return deferredMessageKeysFromUpdates(
        result.addReaction.updates,
      )
    case "deleteMessages":
      return deferredMessageKeysFromUpdates(
        result.deleteMessages.updates,
      )
    case "deleteReaction":
      return deferredMessageKeysFromUpdates(
        result.deleteReaction.updates,
      )
    case "deleteMessageAttachment":
      return deferredMessageKeysFromUpdates(
        result.deleteMessageAttachment.updates,
      )
    case "editMessage":
      return deferredMessageKeysFromUpdates(
        result.editMessage.updates,
      )
    case "markAsUnread":
      return deferredMessageKeysFromUpdates(
        result.markAsUnread.updates,
      )
    case "readMessages":
      return deferredMessageKeysFromUpdates(
        result.readMessages.updates,
      )
    case "sendMessage":
      return deferredMessageKeysFromUpdates(
        result.sendMessage.updates,
      )
    default:
      return []
  }
}

/**
 * Consume only valid, target-matching message payloads. Malformed and future
 * update kinds remain losslessly persisted for a later owner or migration.
 */
export const replayDeferredMessageUpdates = (
  db: Db,
  targetKey: string,
): DeferredMessageReplayReport => {
  const candidates = db
    .queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.DeferredUpdate,
      (update) => update.targetKey === targetKey,
    )
    .sort(compareDeferredUpdates)
  const report = { applied: 0, retained: 0 }

  for (const candidate of candidates) {
    if (candidate.payloadType !== "Update") {
      report.retained += 1
      continue
    }
    let update: Update
    try {
      update = Update.fromBinary(candidate.payload)
    } catch {
      report.retained += 1
      continue
    }
    const decodedTargetKey =
      reactionUpdateTargetKey(update) ??
      messageAttachmentUpdateTargetKey(update)
    if (decodedTargetKey !== targetKey) {
      report.retained += 1
      continue
    }
    const disposition =
      update.update.oneofKind === "messageAttachment"
        ? applyResidentMessageAttachmentUpdate(db, update)
        : applyResidentReactionUpdate(db, update)
    if (disposition !== "applied") {
      report.retained += 1
      continue
    }
    db.delete(
      db.ref(DbObjectKind.DeferredUpdate, candidate.id),
    )
    report.applied += 1
  }
  return report
}

export class DeferredMessageUpdateOwner {
  private readonly detach: () => void

  constructor(private readonly db: Db) {
    this.detach = db.subscribeToResidentChanges((batch) => {
      const keys = new Set<string>()
      for (const change of batch.changes) {
        if (
          change.kind === DbObjectKind.Message &&
          change.object?.kind === DbObjectKind.Message
        ) {
          keys.add(change.object.id)
        }
      }
      if (keys.size === 0) return
      db.batch(() => {
        for (const key of keys) {
          replayDeferredMessageUpdates(db, key)
        }
      })
    })
  }

  close() {
    this.detach()
  }
}

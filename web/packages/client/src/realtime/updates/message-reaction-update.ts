import { Update } from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
} from "../../database/models"

export type ResidentReactionUpdateDisposition =
  | "applied"
  | "missingMessage"
  | "invalid"
  | "unsupported"

export const reactionUpdateTargetKey = (
  update: Update,
): string | undefined => {
  switch (update.update.oneofKind) {
    case "updateReaction": {
      const reaction = update.update.updateReaction.reaction
      return reaction
        ? messageKey(
            chatId(reaction.chatId),
            messageId(reaction.messageId),
          )
        : undefined
    }
    case "deleteReaction":
      return messageKey(
        chatId(update.update.deleteReaction.chatId),
        messageId(update.update.deleteReaction.messageId),
      )
    default:
      return undefined
  }
}

/** Idempotent resident-cache recipe shared by live application and replay. */
export const applyResidentReactionUpdate = (
  db: Db,
  update: Update,
): ResidentReactionUpdateDisposition => {
  switch (update.update.oneofKind) {
    case "updateReaction": {
      const reaction = update.update.updateReaction.reaction
      if (!reaction) return "invalid"
      const ref = db.ref(
        DbObjectKind.Message,
        messageKey(
          chatId(reaction.chatId),
          messageId(reaction.messageId),
        ),
      )
      const message = db.get(ref)
      if (!message) return "missingMessage"
      const reactions = message.reactions?.reactions ?? []
      const withoutPrevious = reactions.filter(
        (existing) =>
          existing.userId !== reaction.userId ||
          existing.emoji !== reaction.emoji,
      )
      db.replace({
        ...message,
        reactions: {
          reactions: [...withoutPrevious, reaction],
        },
      })
      return "applied"
    }
    case "deleteReaction": {
      const deleted = update.update.deleteReaction
      const ref = db.ref(
        DbObjectKind.Message,
        messageKey(
          chatId(deleted.chatId),
          messageId(deleted.messageId),
        ),
      )
      const message = db.get(ref)
      if (!message) return "missingMessage"
      const remaining = (
        message.reactions?.reactions ?? []
      ).filter(
        (reaction) =>
          reaction.userId !== deleted.userId ||
          reaction.emoji !== deleted.emoji,
      )
      db.replace({
        ...message,
        reactions:
          remaining.length > 0
            ? { reactions: remaining }
            : undefined,
      })
      return "applied"
    }
    default:
      return "unsupported"
  }
}

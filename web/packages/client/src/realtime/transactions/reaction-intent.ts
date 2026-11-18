import type { AuthStore } from "../../auth"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
  type ReactionMutationIntent,
} from "../../database/models"
import type { ChatID, MessageID } from "@inline/ids"

export type ReactionIntentContext = {
  chatId: ChatID
  messageId: MessageID
  emoji: string
  intentId: string
}

export const applyReactionIntent = (
  db: Db,
  auth: AuthStore,
  context: ReactionIntentContext,
  action: ReactionMutationIntent["action"],
) => {
  const currentUserId = auth.getState().currentUserId
  if (currentUserId == null) return
  const ref = db.ref(
    DbObjectKind.Message,
    messageKey(context.chatId, context.messageId),
  )
  const message = db.get(ref)
  if (!message) return
  const intents = message.reactionIntents ?? []
  if (intents.some((intent) => intent.id === context.intentId)) return
  db.replace({
    ...message,
    reactionIntents: [
      ...intents,
      {
        id: context.intentId,
        emoji: context.emoji,
        userId: currentUserId,
        action,
      },
    ],
  })
}

export const clearReactionIntent = (
  db: Db,
  context: ReactionIntentContext,
) => {
  const ref = db.ref(
    DbObjectKind.Message,
    messageKey(context.chatId, context.messageId),
  )
  const message = db.get(ref)
  if (!message?.reactionIntents?.length) return
  const reactionIntents = message.reactionIntents.filter(
    (intent) => intent.id !== context.intentId,
  )
  if (reactionIntents.length === message.reactionIntents.length) return
  db.replace({
    ...message,
    reactionIntents:
      reactionIntents.length > 0 ? reactionIntents : undefined,
  })
}

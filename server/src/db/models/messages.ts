import { db } from "@in/server/db"
import { ModelError } from "@in/server/db/models/_errors"
import { ChatModel } from "@in/server/db/models/chats"
import { messages } from "@in/server/db/schema"
import { Log, LogLevel } from "@in/server/utils/log"
import { and, eq, inArray } from "drizzle-orm"

const log = new Log("MessageModel", LogLevel.TRACE)

export const MessageModel = {
  deleteMessage: deleteMessage,
  deleteMessages: deleteMessages,
}

/** Deletes a message from a chat */
async function deleteMessage(messageId: number, chatId: number) {
  log.trace("deleteMessage", { messageId, chatId })

  let deleted = await db
    .delete(messages)
    .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
    .returning()

  if (deleted.length === 0) {
    log.trace("message not found", { messageId, chatId })
    throw ModelError.MessageInvalid
  }

  await ChatModel.refreshLastMessageId(chatId)
  log.trace("refreshed last message id after deletion")
}

/** Deletes multiple messages from a chat */
async function deleteMessages(messageIds: bigint[], chatId: number) {
  log.trace("deleteMessages", { messageIds, chatId })

  let deleted = await db
    .delete(messages)
    .where(
      and(
        eq(messages.chatId, chatId),
        inArray(
          messages.messageId,
          messageIds.map((id) => Number(id)),
        ),
      ),
    )
    .returning()

  if (deleted.length === 0) {
    log.trace("messages not found", { messageIds, chatId })
    throw ModelError.MessageInvalid
  }

  await ChatModel.refreshLastMessageId(chatId)
  log.trace("refreshed last message id after deletion")
}

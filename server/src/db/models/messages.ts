import type { InputPeer } from "@in/protocol/core"
import { db } from "@in/server/db"
import { ModelError } from "@in/server/db/models/_errors"
import { ChatModel } from "@in/server/db/models/chats"
import {
  FileModel,
  type DbFullDocument,
  type DbFullPhoto,
  type DbFullVideo,
  type InputDbFullDocument,
  type InputDbFullPhoto,
  type InputDbFullVideo,
} from "@in/server/db/models/files"
import {
  chats,
  messages,
  type DbChat,
  type DbMessage,
  type DbNewMessage,
  type DbReaction,
  type DbUser,
} from "@in/server/db/schema"
import { decryptMessage, encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log, LogLevel } from "@in/server/utils/log"
import { and, desc, eq, gt, inArray, lt } from "drizzle-orm"

const log = new Log("MessageModel", LogLevel.TRACE)

export const MessageModel = {
  deleteMessage: deleteMessage,
  deleteMessages: deleteMessages,
  insertMessage: insertMessage,
  getMessages: getMessages,
  getMessage: getMessage, // 1 msg
  processMessage: processMessage,
  editMessage: editMessage,
}

export type DbInputFullMessage = DbMessage & {
  from: DbUser
  reactions: DbReaction[]
  photo: InputDbFullPhoto | null
  video: InputDbFullVideo | null
  document: InputDbFullDocument | null
}

export type DbFullMessage = Omit<DbMessage, "textEncrypted" | "textIv" | "textTag"> & {
  from: DbUser
  reactions: DbReaction[]
  photo: DbFullPhoto | null
  video: DbFullVideo | null
  document: DbFullDocument | null
}

async function getMessages(
  inputPeer: InputPeer,
  { currentUserId, offsetId, limit }: { currentUserId: number; offsetId?: bigint; limit?: number },
): Promise<DbFullMessage[]> {
  let chatId = await ChatModel.getChatIdFromInputPeer(inputPeer, { currentUserId })

  if (!chatId) {
    throw ModelError.ChatInvalid
  }

  const offsetIdNumber = offsetId ? Number(offsetId) : undefined

  let result = await db.query.messages.findMany({
    where: offsetIdNumber
      ? and(eq(messages.chatId, chatId), lt(messages.messageId, offsetIdNumber))
      : eq(messages.chatId, chatId),
    orderBy: desc(messages.messageId),
    limit: limit ?? 60,
    with: {
      from: true,
      reactions: true,
      photo: {
        with: {
          photoSizes: {
            with: {
              file: true,
            },
          },
        },
      },
      video: {
        with: {
          file: true,
          photo: {
            with: {
              photoSizes: {
                with: {
                  file: true,
                },
              },
            },
          },
        },
      },
      document: {
        with: {
          file: true,
        },
      },
    },
  })

  return result.map(processMessage)
}

function processMessage(message: DbInputFullMessage): DbFullMessage {
  return {
    ...message,
    text:
      message.textEncrypted && message.textIv && message.textTag
        ? decryptMessage({
            encrypted: message.textEncrypted,
            iv: message.textIv,
            authTag: message.textTag,
          })
        : message.text,
    photo: message.photo ? FileModel.processFullPhoto(message.photo) : null,
    video: message.video ? FileModel.processFullVideo(message.video) : null,
    document: message.document ? FileModel.processFullDocument(message.document) : null,
  }
}

async function insertMessage(message: Omit<DbNewMessage, "messageId">): Promise<DbMessage> {
  let chatId = message.chatId

  // Insert new message with nested select for messageId sequence
  const newMessage = await db.transaction(async (tx) => {
    // First lock the specific chat row
    const [chat] = await tx
      .select()
      .from(chats)
      .where(eq(chats.id, message.chatId))
      .for("update") // This locks the row
      .limit(1)

    if (!chat) {
      throw ModelError.ChatInvalid
    }

    const nextId = (chat.lastMsgId ?? 0) + 1

    // Insert the new message
    const [newDbMessage] = await tx
      .insert(messages)
      .values({
        ...message,
        chatId: chatId,
        messageId: nextId,
      })
      .returning()

    // Update the lastMsgId
    await tx.update(chats).set({ lastMsgId: nextId }).where(eq(chats.id, chatId))

    return newDbMessage
  })

  if (!newMessage) {
    throw ModelError.Failed
  }

  return newMessage
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

  await ChatModel.refreshLastMessageIdTransaction(chatId, async (tx) => {
    let deleted = await tx
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
  })

  //await ChatModel.refreshLastMessageId(chatId)
  //log.trace("refreshed last message id after deletion")
}

async function editMessage(messageId: number, chatId: number, text: string) {
  log.trace("editMessage", { messageId, chatId, text })
  const encryptedMessage = text ? encryptMessage(text) : undefined

  let updated = await db
    .update(messages)
    .set({
      text: text,
      textEncrypted: encryptedMessage?.encrypted,
      textIv: encryptedMessage?.iv,
      textTag: encryptedMessage?.authTag,
    })
    .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
    .returning()

  if (updated.length === 0) {
    log.trace("message not found", { messageId, chatId })
    throw ModelError.MessageInvalid
  }

  return updated[0]
}

async function getMessage(messageId: number, chatId: number): Promise<DbFullMessage> {
  let result = await db.query.messages.findFirst({
    where: and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)),
    with: {
      from: true,
      reactions: true,
      photo: {
        with: {
          photoSizes: {
            with: {
              file: true,
            },
          },
        },
      },
      video: {
        with: {
          file: true,
          photo: {
            with: {
              photoSizes: {
                with: {
                  file: true,
                },
              },
            },
          },
        },
      },
      document: {
        with: {
          file: true,
        },
      },
    },
  })

  if (!result) {
    throw ModelError.MessageInvalid
  }

  return processMessage(result)
}

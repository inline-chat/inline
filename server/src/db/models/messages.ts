import { MessageEntities, type InputPeer, type MessageTranslation } from "@in/protocol/core"
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
  type DbTranslation,
  type DbUser,
} from "@in/server/db/schema"
import { type DbMessageAttachment } from "@in/server/db/schema/attachments"
import { decryptMessage, encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log, LogLevel } from "@in/server/utils/log"
import { and, asc, desc, eq, gt, inArray, lt, or } from "drizzle-orm"
import { decrypt, decryptBinary, encryptBinary } from "@in/server/modules/encryption/encryption"
import type { DbExternalTask, DbLinkEmbed } from "@in/server/db/schema/attachments"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { updates } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"

const log = new Log("MessageModel", LogLevel.INFO)

export const MessageModel = {
  deleteMessage: deleteMessage,
  deleteMessages: deleteMessages,
  insertMessage: insertMessage,
  getMessages: getMessages,
  getMessage: getMessage, // 1 msg
  getMessagesByIds: getMessagesByIds,
  getMessagesAroundTarget: getMessagesAroundTarget,
  getNonFullMessagesRange: getNonFullMessagesRange,
  processMessage: processMessage,
  editMessage: editMessage,
  processAttachments: processAttachments,
  getNonFullMessagesFromNewToOld: getNonFullMessagesFromNewToOld,
  getSenderIdForMessage: getSenderIdForMessage,
}

export type DbInputFullAttachment = DbMessageAttachment & {
  externalTask?: DbExternalTask | null
  linkEmbed?: DbLinkEmbed | null
}

export type DbInputFullMessage = DbMessage & {
  from: DbUser
  reactions: DbReaction[]
  photo: InputDbFullPhoto | null
  video: InputDbFullVideo | null
  document: InputDbFullDocument | null
  messageAttachments?: DbInputFullAttachment[]
}

export type ProcessedMessage = Omit<
  DbMessage,
  "textEncrypted" | "textIv" | "textTag" | "entitiesEncrypted" | "entitiesIv" | "entitiesTag"
> & {
  text: string | null
  entities: MessageEntities | null
}

export type ProcessedMessageTranslation = Omit<
  DbTranslation,
  "translation" | "translationIv" | "translationTag" | "entities"
> & {
  translation: string | null

  /** entities in the translation */
  entities: MessageEntities | null
}

export type ProcessedMessageAndTranslation = ProcessedMessage & {
  translation: ProcessedMessageTranslation | null
}

export type DbFullMessage = Omit<
  DbMessage,
  "textEncrypted" | "textIv" | "textTag" | "entitiesEncrypted" | "entitiesIv" | "entitiesTag"
> & {
  entities: MessageEntities | null
  from: DbUser
  reactions: DbReaction[]
  photo: DbFullPhoto | null
  video: DbFullVideo | null
  document: DbFullDocument | null
  messageAttachments?: ProcessedAttachment[]
}

export type ProcessedExternalTask = Omit<DbExternalTask, "title" | "titleIv" | "titleTag"> & {
  title: string | null
}

export type ProcessedLinkEmbed = Omit<
  DbLinkEmbed,
  "url" | "urlIv" | "urlTag" | "title" | "titleIv" | "titleTag" | "description" | "descriptionIv" | "descriptionTag"
> & {
  url: string | null
  title: string | null
  description: string | null
  photo?: DbFullPhoto | null
}

export type ProcessedAttachment = Omit<DbMessageAttachment, "externalTask" | "linkEmbed"> & {
  externalTask?: ProcessedExternalTask | null
  linkEmbed?: ProcessedLinkEmbed | null
}

export type ProcessedMessageAttachment = Omit<DbMessageAttachment, "externalTask" | "linkEmbed"> & {
  externalTask?: ProcessedExternalTask | null
  linkEmbed?: ProcessedLinkEmbed | null
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

  let result = await db._query.messages.findMany({
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
      messageAttachments: {
        with: {
          externalTask: true,
          linkEmbed: {
            with: {
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
    entities:
      message.entitiesEncrypted && message.entitiesIv && message.entitiesTag
        ? MessageEntities.fromBinary(
            decryptBinary({
              encrypted: message.entitiesEncrypted,
              iv: message.entitiesIv,
              authTag: message.entitiesTag,
            }),
          )
        : null,
    photo: message.photo ? FileModel.processFullPhoto(message.photo) : null,
    video: message.video ? FileModel.processFullVideo(message.video) : null,
    document: message.document ? FileModel.processFullDocument(message.document) : null,
    messageAttachments: message.messageAttachments ? processAttachments(message.messageAttachments) : [],
  }
}

type InsertMessageOutput = {
  message: DbMessage
  pts: number
}

async function insertMessage(message: Omit<DbNewMessage, "messageId">): Promise<InsertMessageOutput> {
  let chatId = message.chatId

  // Insert new message with nested select for messageId sequence
  const { message: newMessage, pts } = await db.transaction(async (tx) => {
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
    const nextPts = (chat.pts ?? 0) + 1

    // Insert the new message
    const [newDbMessage] = await tx
      .insert(messages)
      .values({
        ...message,
        chatId: chatId,
        messageId: nextId,
      })
      .returning()

    // Build update
    const update = UpdatesModel.build({
      update: {
        oneofKind: "newMessage",
        newMessage: {
          chatId: BigInt(chatId),
          msgId: BigInt(nextId),
          pts: nextPts,
        },
      },
    })

    // Update chat's PTS and lastMsgId
    await Promise.all([
      tx
        .update(chats)
        .set({
          lastMsgId: nextId,
          pts: nextPts,
          // Set to now
          lastUpdateDate: new Date(),
        })
        .where(eq(chats.id, chatId)),

      tx.insert(updates).values({
        box: "c",
        chatId: chatId,
        pts: nextPts,
        update: update.encrypted,
        updateIv: update.iv,
        updateTag: update.authTag,
      }),
    ])

    return {
      message: newDbMessage,
      pts: nextPts,
    }
  })

  if (!newMessage) {
    throw ModelError.Failed
  }

  return {
    message: newMessage,
    pts,
  }
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

/**
 * Deletes multiple messages from a chat
 **/
async function deleteMessages(
  messageIds: bigint[],
  chatId: number,
): Promise<{
  pts: number
}> {
  log.trace("deleteMessages", { messageIds, chatId })

  // Use a transaction with FOR UPDATE to lock the row while we're working with it
  let { pts } = await db.transaction(async (tx) => {
    let [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update")

    if (!chat) throw ModelError.ChatInvalid

    const pts = (chat.pts ?? 0) + 1

    // Clear first to allow for deleting
    await tx.update(chats).set({ lastMsgId: null }).where(eq(chats.id, chatId))

    // Delete message
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

    let [message] = await tx
      .select({ messageId: messages.messageId })
      .from(messages)
      .where(eq(messages.chatId, chatId))
      .orderBy(desc(messages.messageId))
      .limit(1)

    const newLastMsgId = message?.messageId ?? null

    await tx
      .update(chats)
      .set({
        // Update last message
        lastMsgId: newLastMsgId,
        // Update PTS and update date
        pts,
        lastUpdateDate: new Date(),
      })
      .where(eq(chats.id, chatId))

    return { pts }
  })

  return { pts }
}

type EditMessageInput = {
  messageId: number
  chatId: number
  text: string
  entities?: MessageEntities
}

async function editMessage(input: EditMessageInput): Promise<{
  message: DbMessage
  pts: number
  /**
   * The date of the update recorded on Chat's lastUpdateDate
   */
  date: Date
}> {
  let { messageId, chatId, text, entities } = input

  const encryptedMessage = text ? encryptMessage(text) : undefined
  const binaryEntities = entities ? MessageEntities.toBinary(entities) : undefined
  const encryptedEntities = binaryEntities && binaryEntities?.length > 0 ? encryptBinary(binaryEntities) : undefined

  let { message, pts, date } = await db.transaction(async (tx) => {
    // First lock the specific chat row
    const [chat] = await tx
      .select()
      .from(chats)
      .where(eq(chats.id, chatId))
      .for("update") // This locks the row
      .limit(1)

    if (!chat) {
      throw ModelError.ChatInvalid
    }

    const nextPts = (chat.pts ?? 0) + 1
    const lastUpdateDate = new Date()

    // Build update
    const update = UpdatesModel.build({
      update: {
        oneofKind: "editMessage",
        editMessage: {
          chatId: BigInt(chatId),
          msgId: BigInt(messageId),
          pts: nextPts,
        },
      },
    })

    let [msgs] = await Promise.all([
      // Edit message
      await db
        .update(messages)
        .set({
          editDate: new Date(),
          // text
          textEncrypted: encryptedMessage?.encrypted,
          textIv: encryptedMessage?.iv,
          textTag: encryptedMessage?.authTag,
          // entities
          entitiesEncrypted: encryptedEntities?.encrypted,
          entitiesIv: encryptedEntities?.iv,
          entitiesTag: encryptedEntities?.authTag,
        })
        .where(and(eq(messages.chatId, chatId), eq(messages.messageId, messageId)))
        .returning(),

      // Insert update
      tx.insert(updates).values({
        box: "c",
        chatId: chatId,
        pts: nextPts,
        update: update.encrypted,
        updateIv: update.iv,
        updateTag: update.authTag,
      }),

      // Update chat
      tx
        .update(chats)
        .set({
          pts: nextPts,
          lastUpdateDate: lastUpdateDate,
        })
        .where(eq(chats.id, chatId)),
    ])

    return { message: msgs[0], pts: nextPts, date: lastUpdateDate }
  })

  if (!message) {
    log.trace("message not found", { messageId, chatId })
    throw ModelError.MessageInvalid
  }

  return { message, pts, date }
}

async function getMessage(messageId: number, chatId: number): Promise<DbFullMessage> {
  let result = await db._query.messages.findFirst({
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
      messageAttachments: {
        with: {
          externalTask: true,
          linkEmbed: {
            with: {
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
        },
      },
    },
  })

  if (!result) {
    throw ModelError.MessageInvalid
  }

  return processMessage(result)
}

/**
 * Decrypts a message translation
 * @param translation - The translation to decrypt
 * @returns The decrypted translation
 */
export function processMessageTranslation(translation: DbTranslation): ProcessedMessageTranslation {
  return {
    ...translation,
    translation:
      translation.translation && translation.translationIv && translation.translationTag
        ? decrypt({
            encrypted: translation.translation,
            iv: translation.translationIv,
            authTag: translation.translationTag,
          })
        : null,

    entities: translation.entities ? MessageEntities.fromBinary(Encryption2.decryptBinary(translation.entities)) : null,
  }
}

export function processAttachments(
  attachments: (DbMessageAttachment & {
    externalTask?: DbExternalTask | null
    linkEmbed?: (DbLinkEmbed & { photo?: any | null }) | null
  })[],
): ProcessedMessageAttachment[] {
  return attachments.map((attachment) => {
    // Omit externalTask and linkEmbed from the initial spread
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const { externalTask, linkEmbed, ...rest } = attachment
    let processed: ProcessedMessageAttachment = { ...rest }

    // Process externalTask if present
    if (attachment.externalTask) {
      // Omit encrypted fields from the spread
      const { title, titleIv, titleTag, ...rest } = attachment.externalTask
      processed.externalTask = {
        ...rest,
        title:
          title && titleIv && titleTag
            ? decrypt({
                encrypted: title,
                iv: titleIv,
                authTag: titleTag,
              })
            : null,
      }
    }

    // Process linkEmbed (url preview) if present
    if (attachment.linkEmbed) {
      const {
        url,
        urlIv,
        urlTag,
        title: linkTitle,
        titleIv: linkTitleIv,
        titleTag: linkTitleTag,
        description,
        descriptionIv,
        descriptionTag,
        photo,
        ...rest
      } = attachment.linkEmbed
      processed.linkEmbed = {
        ...rest,
        url:
          url && urlIv && urlTag
            ? decrypt({
                encrypted: url,
                iv: urlIv,
                authTag: urlTag,
              })
            : null,
        title:
          linkTitle && linkTitleIv && linkTitleTag
            ? decrypt({
                encrypted: linkTitle,
                iv: linkTitleIv,
                authTag: linkTitleTag,
              })
            : null,
        description:
          description && descriptionIv && descriptionTag
            ? decrypt({
                encrypted: description,
                iv: descriptionIv,
                authTag: descriptionTag,
              })
            : null,
        photo: photo ? FileModel.processFullPhoto(photo) : null,
      }
    }

    return processed
  })
}

async function getNonFullMessagesRange(chatId: number, offsetId: number, limit: number): Promise<ProcessedMessage[]> {
  let result = await db._query.messages.findMany({
    where: and(eq(messages.chatId, chatId), gt(messages.messageId, offsetId)),
    orderBy: desc(messages.messageId),
    limit: limit ?? 60,
  })

  return result.map((msg) => ({
    ...msg,
    text:
      msg.textEncrypted && msg.textIv && msg.textTag
        ? decryptMessage({
            encrypted: msg.textEncrypted,
            iv: msg.textIv,
            authTag: msg.textTag,
          })
        : // legacy fallback
          msg.text,
    entities:
      msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
        ? MessageEntities.fromBinary(
            decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
          )
        : null,
  }))
}

async function getNonFullMessagesFromNewToOld(input: {
  chatId: number
  newestMsgId: number
  limit: number
}): Promise<ProcessedMessage[]> {
  let result = await db._query.messages.findMany({
    where: and(eq(messages.chatId, input.chatId), lt(messages.messageId, input.newestMsgId)),
    orderBy: desc(messages.messageId),
    limit: input.limit,
  })

  result.reverse()

  return result.map((msg) => ({
    ...msg,
    text:
      msg.textEncrypted && msg.textIv && msg.textTag
        ? decryptMessage({
            encrypted: msg.textEncrypted,
            iv: msg.textIv,
            authTag: msg.textTag,
          })
        : // legacy fallback
          msg.text,
    entities:
      msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
        ? MessageEntities.fromBinary(
            decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
          )
        : null,
  }))
}

async function getMessagesAroundTarget(
  chatId: number,
  targetMessageId: number,
  beforeCount: number = 15,
  afterCount: number = 15,
): Promise<ProcessedMessage[]> {
  const [messagesBefore, messagesAfter] = await Promise.all([
    // Get messages before the target (older messages) - optimized query
    db._query.messages.findMany({
      where: and(eq(messages.chatId, chatId), lt(messages.messageId, targetMessageId)),
      orderBy: desc(messages.messageId),
      limit: beforeCount,
    }),
    // Get messages after the target (newer messages) - optimized query
    db._query.messages.findMany({
      where: and(eq(messages.chatId, chatId), gt(messages.messageId, targetMessageId)),
      orderBy: asc(messages.messageId),
      limit: afterCount,
    }),
  ])

  // Reverse messagesBefore to get chronological order (oldest first)
  messagesBefore.reverse()

  // Combine in chronological order
  const combinedMessages = [...messagesBefore, ...messagesAfter]

  return combinedMessages.map((msg) => ({
    ...msg,
    text:
      msg.textEncrypted && msg.textIv && msg.textTag
        ? decryptMessage({
            encrypted: msg.textEncrypted,
            iv: msg.textIv,
            authTag: msg.textTag,
          })
        : // legacy fallback
          msg.text,
    entities:
      msg.entitiesEncrypted && msg.entitiesIv && msg.entitiesTag
        ? MessageEntities.fromBinary(
            decryptBinary({ encrypted: msg.entitiesEncrypted, iv: msg.entitiesIv, authTag: msg.entitiesTag }),
          )
        : null,
  }))
}

/**
 * Get the sender ID for a message
 * @param input - The input object containing the chat ID and message IDs
 * @returns The sender ID or null if the message is not found
 */
async function getSenderIdForMessage({
  chatId,
  messageId,
}: {
  chatId: number
  messageId: number
}): Promise<number | undefined> {
  const message = await db.query.messages.findFirst({
    where: {
      chatId,
      messageId,
    },
    columns: {
      fromId: true,
    },
  })

  return message?.fromId ?? undefined
}

async function getMessagesByIds(chatId: number, messageIds: bigint[]): Promise<DbFullMessage[]> {
  if (messageIds.length === 0) {
    return []
  }

  let result = await db._query.messages.findMany({
    where: and(
      eq(messages.chatId, chatId),
      inArray(
        messages.messageId,
        messageIds.map((id) => Number(id)),
      ),
    ),
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
      messageAttachments: {
        with: {
          externalTask: true,
          linkEmbed: {
            with: {
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
        },
      },
    },
  })

  return result.map(processMessage)
}

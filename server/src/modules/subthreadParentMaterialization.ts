import {
  MessageEntities,
  MessageEntity_Type,
  type MessageEntities as MessageEntitiesType,
  type Update,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import {
  subthreadParentMessages,
  messages as messagesTable,
  type DbChat,
  type DbMessage,
} from "@in/server/db/schema"
import { updateThreadInfo } from "@in/server/functions/messages.updateChatInfo"
import {
  getMessageThreadProjectionsMap,
  getChatById,
} from "@in/server/modules/subthreads"
import {
  maybeScheduleThreadTitleGeneration,
  type ThreadTitleAttachmentContext,
} from "@in/server/modules/threadTitles"
import { getUpdateGroup } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { encryptMessage, encryptMessageEntities } from "@in/server/modules/encryption/encryptMessage"
import { Log } from "@in/server/utils/log"
import { and, eq, isNull, lt } from "drizzle-orm"

const log = new Log("modules.subthreadParentMaterialization")
const TITLE_EXCERPT_LENGTH = 60
const FALLBACK_TITLE = "New subthread"
const FALLBACK_PREFIX = "Started a subthread: "

type FirstMessageExperienceInput = {
  chat: Pick<
    DbChat,
    | "id"
    | "type"
    | "parentChatId"
    | "parentMessageId"
    | "createdBy"
  >
  message: Pick<
    DbMessage,
    | "messageId"
    | "mediaType"
    | "fwdFromPeerUserId"
    | "fwdFromPeerChatId"
    | "fwdFromMessageId"
    | "fwdFromSenderId"
  >
  text: string | undefined
  entities: MessageEntitiesType | undefined
  attachments?: ThreadTitleAttachmentContext[]
  currentUserId: number
}

export function queueFirstMessageExperience(input: FirstMessageExperienceInput): void {
  // sendMessage is the live authored-message path. All of its user-visible
  // variants, including forwards and nudges, qualify. Service/import/replay
  // paths never call this hook; the async worker checks durable prior content.
  if (
    input.chat.type !== "thread" ||
    input.chat.parentChatId == null ||
    input.chat.parentMessageId != null
  ) {
    return
  }

  queueMicrotask(() => {
    void materializeFirstMessageExperience(input).catch((error) => {
      log.warn("First-message subthread experience failed", {
        chatId: input.chat.id,
        messageId: input.message.messageId,
        error,
      })
    })
  })
}

export async function materializeFirstMessageExperience(
  input: FirstMessageExperienceInput,
): Promise<void> {
  if (!(await isFirstQualifyingMessage(input.chat.id, input.message.messageId))) {
    return
  }

  const chat = await initializeSubthreadTitle(input)
  await materializeSubthreadParentMessage({
    childChat: chat,
    currentUserId: input.currentUserId,
  })
  maybeScheduleThreadTitleGeneration({
    chat,
    message: input.message,
    text: input.text,
    entities: input.entities,
    attachments: input.attachments,
    currentUserId: input.currentUserId,
  })
}

async function isFirstQualifyingMessage(chatId: number, messageId: number): Promise<boolean> {
  const [priorMessage] = await db
    .select({ globalId: messagesTable.globalId })
    .from(messagesTable)
    .where(and(
      eq(messagesTable.chatId, chatId),
      lt(messagesTable.messageId, messageId),
      isNull(messagesTable.systemMessageEncrypted),
    ))
    .limit(1)

  return priorMessage == null
}

async function initializeSubthreadTitle(
  input: FirstMessageExperienceInput,
): Promise<DbChat> {
  const currentChat = await getChatById(input.chat.id)
  if (!currentChat || currentChat.parentChatId == null || currentChat.parentMessageId != null) {
    throw new Error("Subthread is no longer eligible for parent materialization")
  }

  const existingTitle = normalizedTitle(currentChat.title)
  if (existingTitle) {
    return currentChat
  }

  const placeholderTitle = firstMessageTitle(input.text, input.message.mediaType)
  const result = await updateThreadInfo({
    chatId: currentChat.id,
    title: placeholderTitle,
    currentUserId: input.currentUserId,
    titleGuard: { kind: "empty" },
    isUntitled: true,
  })

  return result.chat
}

async function materializeSubthreadParentMessage(input: {
  childChat: DbChat
  currentUserId: number
}): Promise<void> {
  const parentChatId = input.childChat.parentChatId
  const authorId = input.childChat.createdBy ?? input.currentUserId
  const title = normalizedTitle(input.childChat.title) ?? FALLBACK_TITLE
  if (parentChatId == null) {
    return
  }

  const fallbackText = `${FALLBACK_PREFIX}${title}`
  const entities: MessageEntitiesType = {
    entities: [{
      type: MessageEntity_Type.THREAD,
      offset: BigInt(FALLBACK_PREFIX.length),
      length: BigInt(title.length),
      entity: {
        oneofKind: "thread",
        thread: { chatId: BigInt(input.childChat.id) },
      },
    }],
  }
  const encryptedMessage = encryptMessage(fallbackText)
  const encryptedEntities = encryptMessageEntities(MessageEntities.toBinary(entities))

  const inserted = await db.transaction(async (tx) => {
    const [claim] = await tx
      .insert(subthreadParentMessages)
      .values({ childChatId: input.childChat.id, parentMessageGlobalId: null })
      .onConflictDoNothing()
      .returning({ childChatId: subthreadParentMessages.childChatId })

    if (!claim) {
      return undefined
    }

    const result = await MessageModel.insertMessage({
      chatId: parentChatId,
      fromId: authorId,
      textEncrypted: encryptedMessage.encrypted,
      textIv: encryptedMessage.iv,
      textTag: encryptedMessage.authTag,
      entitiesEncrypted: encryptedEntities.encrypted,
      entitiesIv: encryptedEntities.iv,
      entitiesTag: encryptedEntities.authTag,
      countsAsUnread: true,
    }, undefined, tx)

    await tx
      .update(subthreadParentMessages)
      .set({ parentMessageGlobalId: result.message.globalId })
      .where(eq(subthreadParentMessages.childChatId, input.childChat.id))

    return result
  })

  if (!inserted) {
    return
  }

  const [parentChat, parentMessage] = await Promise.all([
    getChatById(parentChatId),
    MessageModel.getMessagesByIds(parentChatId, [BigInt(inserted.message.messageId)]).then((rows) => rows[0]),
  ])
  if (!parentChat || !parentMessage) {
    return
  }

  const updateGroup = await getUpdateGroup(
    { threadId: parentChatId },
    { currentUserId: input.currentUserId },
  )
  for (const userId of updateGroup.userIds) {
    const threadProjection = (
      await getMessageThreadProjectionsMap({
        parentChatId,
        parentMessageIds: [parentMessage.messageId],
        userId,
      })
    ).get(parentMessage.messageId)

    const update: Update = {
      seq: inserted.update.seq,
      date: encodeDateStrict(inserted.update.date),
      update: {
        oneofKind: "newMessage",
        newMessage: {
          message: Encoders.fullMessage({
            message: parentMessage,
            encodingForUserId: userId,
            encodingForPeer: {
              inputPeer: encodePeerFromChat(parentChat, { currentUserId: userId }),
            },
            subthread: threadProjection?.subthread,
          }),
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [update])
  }
}

function firstMessageTitle(text: string | undefined, mediaType: DbMessage["mediaType"]): string {
  const normalizedText = normalizedTitle(text?.replace(/\s+/g, " ") ?? null)
  if (normalizedText) {
    return Array.from(normalizedText).slice(0, TITLE_EXCERPT_LENGTH).join("").trim()
  }

  switch (mediaType) {
    case "photo": return "Photo"
    case "video": return "Video"
    case "document": return "Document"
    case "voice": return "Voice message"
    default: return FALLBACK_TITLE
  }
}

const normalizedTitle = (value: string | null): string | undefined => {
  const title = value?.trim()
  return title ? title : undefined
}

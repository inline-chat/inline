import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { chats, type DbChat, type DbMessage } from "@in/server/db/schema"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { encryptSystemMessagePayload, type SystemMessage } from "@in/server/modules/systemMessages/payload"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import type { Update } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"

const log = new Log("systemMessages")

type InsertSystemMessageInput = {
  chatId: number
  actorUserId: number
  payload: SystemMessage
  fallbackText: string
  date?: Date
  publish?: boolean
}

type InsertSystemMessageOutput = {
  message: DbMessage
  update: UpdateSeqAndDate
}

export async function insertSystemMessage(input: InsertSystemMessageInput): Promise<InsertSystemMessageOutput> {
  const encrypted = encryptSystemMessagePayload(input.payload)
  const encryptedText = encryptMessage(input.fallbackText)

  const result = await MessageModel.insertMessage({
    chatId: input.chatId,
    fromId: input.actorUserId,
    date: input.date ?? new Date(),
    textEncrypted: encryptedText.encrypted,
    textIv: encryptedText.iv,
    textTag: encryptedText.authTag,
    entitiesEncrypted: null,
    entitiesIv: null,
    entitiesTag: null,
    actionsEncrypted: null,
    actionsIv: null,
    actionsTag: null,
    systemMessageEncrypted: encrypted.encrypted,
    systemMessageIv: encrypted.iv,
    systemMessageTag: encrypted.authTag,
    hasLink: false,
  })

  if (input.publish !== false) {
    const message = {
      ...result.message,
      systemMessage: input.payload,
    }

    try {
      await publishSystemMessage({
        actorUserId: input.actorUserId,
        message,
        update: result.update,
      })
    } catch (error) {
      log.error("Failed to publish system message", {
        chatId: input.chatId,
        actorUserId: input.actorUserId,
        messageId: result.message.messageId,
        error,
      })
    }
  }

  return result
}

export function buildSystemMessageUpdate(input: {
  chat: DbChat
  message: DbMessage & { systemMessage: SystemMessage }
  targetUserId: number
  update: UpdateSeqAndDate
}): Update {
  return {
    update: {
      oneofKind: "newMessage",
      newMessage: {
        message: Encoders.message({
          message: input.message,
          encodingForUserId: input.targetUserId,
          encodingForPeer: {
            peer: Encoders.peerFromChat(input.chat, { currentUserId: input.targetUserId }),
          },
        }),
      },
    },
    seq: input.update.seq,
    date: encodeDateStrict(input.update.date),
  }
}

async function publishSystemMessage(input: {
  actorUserId: number
  message: DbMessage & { systemMessage: SystemMessage }
  update: UpdateSeqAndDate
}) {
  const chat = await getChat(input.message.chatId)
  if (!chat) {
    log.error("Failed to publish system message: chat missing", {
      chatId: input.message.chatId,
      messageId: input.message.messageId,
    })
    return
  }

  const inputPeer = encodePeerFromChat(chat, { currentUserId: input.actorUserId })
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId: input.actorUserId })

  if (updateGroup.type === "spaceUsers") {
    return
  }

  for (const userId of updateGroup.userIds) {
    RealtimeUpdates.pushToUser(userId, [
      buildSystemMessageUpdate({
        chat,
        message: input.message,
        targetUserId: userId,
        update: input.update,
      }),
    ])
  }
}

async function getChat(chatId: number): Promise<DbChat | null> {
  const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
  return chat ?? null
}

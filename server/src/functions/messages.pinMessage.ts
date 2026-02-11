import type { InputPeer, Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UpdatesModel } from "@in/server/db/models/updates"
import { chats, messages } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { FunctionContext } from "@in/server/functions/_types"
import { Log } from "@in/server/utils/log"
import { and, desc, eq, isNull, not } from "drizzle-orm"

type Input = {
  peer: InputPeer
  messageId: bigint
  unpin: boolean
}

type Output = {
  updates: Update[]
}

const log = new Log("functions.pinMessage")

export const pinMessage = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peer, context)

  try {
    await AccessGuards.ensureChatAccess(chat, context.currentUserId)
  } catch (error) {
    log.error("pinMessage blocked: chat access denied", {
      chatId: chat.id,
      currentUserId: context.currentUserId,
      peer: input.peer,
      error,
    })
    throw error
  }

  const messageId = Number(input.messageId)
  if (!Number.isSafeInteger(messageId) || messageId <= 0) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const unpin = Boolean(input.unpin)

  const { update, pinnedMessageIds } = await db.transaction(async (tx) => {
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
    if (!lockedChat) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    const [existingMessage] = await tx
      .select({ messageId: messages.messageId })
      .from(messages)
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, messageId)))
      .limit(1)

    if (!existingMessage) {
      throw RealtimeRpcError.MessageIdInvalid()
    }

    await tx
      .update(messages)
      .set({ pinnedAt: unpin ? null : new Date() })
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, messageId)))

    const pinnedRows = await tx
      .select({ messageId: messages.messageId })
      .from(messages)
      .where(and(eq(messages.chatId, chat.id), not(isNull(messages.pinnedAt))))
      .orderBy(desc(messages.pinnedAt), desc(messages.messageId))

    const pinnedMessageIds = pinnedRows.map((row) => BigInt(row.messageId))

    const updatePayload: ServerUpdate["update"] = {
      oneofKind: "pinnedMessages",
      pinnedMessages: {
        chatId: BigInt(chat.id),
        messageIds: pinnedMessageIds,
      },
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: updatePayload,
      bucket: UpdateBucket.Chat,
      entity: lockedChat,
    })

    const [updatedChat] = await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chat.id))
      .returning()

    if (!updatedChat) {
      throw RealtimeRpcError.InternalError()
    }

    return { update, pinnedMessageIds }
  })

  const { selfUpdates } = await pushUpdates({
    inputPeer: input.peer,
    currentUserId: context.currentUserId,
    update,
    pinnedMessageIds,
  })

  return { updates: selfUpdates }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

const pushUpdates = async ({
  inputPeer,
  currentUserId,
  update,
  pinnedMessageIds,
}: {
  inputPeer: InputPeer
  currentUserId: number
  update: { seq: number; date: Date }
  pinnedMessageIds: bigint[]
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

  let selfUpdates: Update[] = []

  if (updateGroup.type === "dmUsers") {
    updateGroup.userIds.forEach((userId) => {
      const encodingForInputPeer: InputPeer =
        userId === currentUserId
          ? inputPeer
          : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

      const updatePayload: Update = {
        update: {
          oneofKind: "pinnedMessages",
          pinnedMessages: {
            peerId: Encoders.peerFromInputPeer({ inputPeer: encodingForInputPeer, currentUserId }),
            messageIds: pinnedMessageIds,
          },
        },
        seq: update.seq,
        date: encodeDateStrict(update.date),
      }

      if (userId === currentUserId) {
        RealtimeUpdates.pushToUser(userId, [updatePayload])
        selfUpdates = [updatePayload]
      } else {
        RealtimeUpdates.pushToUser(userId, [updatePayload])
      }
    })
  } else if (updateGroup.type === "threadUsers") {
    updateGroup.userIds.forEach((userId) => {
      const updatePayload: Update = {
        update: {
          oneofKind: "pinnedMessages",
          pinnedMessages: {
            peerId: Encoders.peerFromInputPeer({ inputPeer, currentUserId }),
            messageIds: pinnedMessageIds,
          },
        },
        seq: update.seq,
        date: encodeDateStrict(update.date),
      }

      if (userId === currentUserId) {
        RealtimeUpdates.pushToUser(userId, [updatePayload])
        selfUpdates = [updatePayload]
      } else {
        RealtimeUpdates.pushToUser(userId, [updatePayload])
      }
    })
  }

  return { selfUpdates, updateGroup }
}

import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { users } from "@in/server/db/schema/users"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroup } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import type { Update } from "@inline-chat/protocol/core"
import { UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export async function removeChatParticipant(
  input: {
    chatId: number
    userId: number
  },
  context: FunctionContext,
): Promise<void> {
  try {
    const { update } = await db.transaction(async (tx): Promise<{ update: UpdateSeqAndDate }> => {
      const [chat] = await tx.select().from(chats).where(eq(chats.id, input.chatId)).for("update").limit(1)

      if (!chat) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
      }

      if (chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
      }

      if (chat.spaceId == null && chat.createdBy !== context.currentUserId) {
        throw RealtimeRpcError.PeerIdInvalid()
      }

      const user = await tx.select().from(users).where(eq(users.id, input.userId)).limit(1)
      if (!user || user.length === 0) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `User with ID ${input.userId} not found`, 404)
      }

      const [participant] = await tx
        .select()
        .from(chatParticipants)
        .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, input.userId)))

      if (!participant) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "User is not a participant of this chat", 404)
      }

      await tx
        .delete(chatParticipants)
        .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, input.userId)))

      AccessGuardsCache.resetChatParticipant(input.chatId, input.userId)

      const chatServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "participantDelete",
        participantDelete: {
          chatId: BigInt(input.chatId),
          userId: BigInt(input.userId),
        },
      }

      const userServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "userChatParticipantDelete",
        userChatParticipantDelete: {
          chatId: BigInt(input.chatId),
        },
      }

      const update = await UpdatesModel.insertUpdate(tx, {
        update: chatServerUpdatePayload,
        bucket: UpdateBucket.Chat,
        entity: chat,
      })

      await tx
        .update(chats)
        .set({
          updateSeq: update.seq,
          lastUpdateDate: update.date,
        })
        .where(eq(chats.id, chat.id))

      await UserBucketUpdates.enqueue(
        {
          userId: input.userId,
          update: userServerUpdatePayload,
        },
        { tx },
      )

      return { update }
    })

    await pushUpdates({
      chatId: input.chatId,
      userId: input.userId,
      currentUserId: context.currentUserId,
      update,
    })
  } catch (error) {
    Log.shared.error(`Failed to remove participant from chat ${input.chatId}: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to remove chat participant", 500)
  }
}

/** Push updates for new chat creation */
const pushUpdates = async ({
  chatId,
  userId,
  currentUserId,
  update,
}: {
  chatId: number
  userId: number
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chatId }, { currentUserId })

  let selfUpdates: Update[] = []

  const chatParticipantDelete: Update = {
    seq: update.seq,
    date: encodeDateStrict(update.date),
    update: {
      oneofKind: "participantDelete",
      participantDelete: {
        chatId: BigInt(chatId),
        userId: BigInt(userId),
      },
    },
  }
  updateGroup.userIds.forEach((updateUserId) => {
    RealtimeUpdates.pushToUser(updateUserId, [chatParticipantDelete])

    if (updateUserId === currentUserId) {
      selfUpdates = [chatParticipantDelete]
    }
  })

  // Send to deleted user.
  // Because they're no longer in the chat topic we still need to deliver the realtime
  // event directly (the user-bucket update handles offline sync).
  RealtimeUpdates.pushToUser(userId, [chatParticipantDelete])

  return { selfUpdates, updateGroup }
}

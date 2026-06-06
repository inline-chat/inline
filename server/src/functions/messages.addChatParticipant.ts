import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import { ChatParticipant, Update } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { userNotDeleted, users } from "@in/server/db/schema/users"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroup } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"
import { UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import {
  ensureCanManageChatParticipants,
  ensureUserCanParticipateInChat,
} from "@in/server/modules/authorization/spaceThreadGuards"

export async function addChatParticipant(
  input: {
    chatId: number
    userId: number
  },
  context: FunctionContext,
): Promise<ChatParticipant> {
  try {
    const result = await db.transaction(async (tx): Promise<{ participant: ChatParticipant; update: UpdateSeqAndDate | null }> => {
      // Check if chat exists
      const [chat] = await tx.select().from(chats).where(eq(chats.id, input.chatId)).for("update").limit(1)

      if (!chat) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
      }

      if (chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
      }

      await ensureCanManageChatParticipants(chat, context.currentUserId)
      await ensureUserCanParticipateInChat(chat, input.userId)

      // Check if user exists
      const user = await tx
        .select()
        .from(users)
        .where(and(eq(users.id, input.userId), userNotDeleted()))
        .limit(1)
      if (!user || user.length === 0) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `User with ID ${input.userId} not found`, 404)
      }

      // check if user is already a participant return the participant
      const [participant] = await tx
        .select()
        .from(chatParticipants)
        .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, input.userId)))

      if (participant != null) {
        return {
          participant: {
            userId: BigInt(participant.userId),
            date: encodeDateStrict(participant.date),
          },
          update: null,
        }
      }

      const [newParticipant] = await tx
        .insert(chatParticipants)
        .values({
          chatId: input.chatId,
          userId: input.userId,
          date: new Date(),
        })
        .returning()
      if (!newParticipant) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create chat participant", 500)
      }

      const participantForUpdate: ChatParticipant = {
        userId: BigInt(newParticipant.userId),
        date: encodeDateStrict(newParticipant.date),
      }

      const chatServerUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "participantAdd",
        participantAdd: {
          chatId: BigInt(input.chatId),
          participant: participantForUpdate,
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
          update: {
            oneofKind: "userChatParticipantAdd",
            userChatParticipantAdd: {
              chatId: BigInt(input.chatId),
              participant: participantForUpdate,
            },
          },
        },
        { tx },
      )

      return {
        participant: participantForUpdate,
        update,
      }
    })

    AccessGuardsCache.setChatParticipant(input.chatId, input.userId)

    if (result.update) {
      await pushUpdates({
        chatId: input.chatId,
        currentUserId: context.currentUserId,
        participant: result.participant,
        update: result.update,
      })
    }

    return result.participant
  } catch (error) {
    Log.shared.error(`Failed to add participant to chat ${input.chatId}: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to add chat participant", 500)
  }
}

/** Push participant-add updates to currently connected clients. */
const pushUpdates = async ({
  chatId,
  currentUserId,
  participant,
  update,
}: {
  chatId: number
  currentUserId: number
  participant: ChatParticipant
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chatId }, { currentUserId })

  let selfUpdates: Update[] = []

  updateGroup.userIds.forEach((userId) => {
    const chatParticipantAdd: Update = {
      seq: update.seq,
      date: encodeDateStrict(update.date),
      update: {
        oneofKind: "participantAdd",
        participantAdd: {
          chatId: BigInt(chatId),
          participant: participant,
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [chatParticipantAdd])

    if (userId === currentUserId) {
      selfUpdates = [chatParticipantAdd]
    }
  })

  return { selfUpdates, updateGroup }
}

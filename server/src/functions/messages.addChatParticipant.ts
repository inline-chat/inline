import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import { ChatParticipant, Update } from "@in/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { users } from "@in/server/db/schema/users"
import type { UpdateGroup } from "../modules/updates"
import { getUpdateGroup } from "../modules/updates"
import { RealtimeUpdates } from "../realtime/message"

export async function addChatParticipant(
  input: {
    chatId: number
    userId: number
  },
  context: FunctionContext,
): Promise<ChatParticipant> {
  try {
    // Check if chat exists
    const chat = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)

    if (!chat || chat.length === 0) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
    }

    // Check if user exists
    const user = await db.select().from(users).where(eq(users.id, input.userId)).limit(1)
    if (!user || user.length === 0) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `User with ID ${input.userId} not found`, 404)
    }

    // check if user is already a participant return the participant
    const [participant] = await db
      .select()
      .from(chatParticipants)
      .where(and(eq(chatParticipants.chatId, input.chatId), eq(chatParticipants.userId, input.userId)))

    if (participant != null) {
      const participantForUpdate: ChatParticipant = {
        userId: BigInt(participant.userId),
        date: encodeDateStrict(participant.date),
      }

      pushUpdates({
        chatId: input.chatId,
        currentUserId: context.currentUserId,
        participant: participantForUpdate,
      })

      return {
        userId: BigInt(participant.userId),
        date: encodeDateStrict(participant.date),
      }
    } else {
      const newParticipant = await db
        .insert(chatParticipants)
        .values({
          chatId: input.chatId,
          userId: input.userId,
          date: new Date(),
        })
        .returning()
      if (!newParticipant[0]) {
        throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create chat participant", 500)
      }

      const participantForUpdate: ChatParticipant = {
        userId: BigInt(newParticipant[0].userId),
        date: encodeDateStrict(newParticipant[0].date),
      }

      pushUpdates({
        chatId: input.chatId,
        currentUserId: context.currentUserId,
        participant: participantForUpdate,
      })

      return {
        userId: BigInt(newParticipant[0].userId),
        date: encodeDateStrict(newParticipant[0].date),
      }
    }
  } catch (error) {
    Log.shared.error(`Failed to get participants for chat ${input.chatId}: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to get chat participants", 500)
  }
}

// push updates

/** Push updates for new chat creation */
const pushUpdates = async ({
  chatId,
  currentUserId,
  participant,
}: {
  chatId: number
  currentUserId: number
  participant: ChatParticipant
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chatId }, { currentUserId })

  let selfUpdates: Update[] = []

  updateGroup.userIds.forEach((userId) => {
    const chatParticipantAdd: Update = {
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

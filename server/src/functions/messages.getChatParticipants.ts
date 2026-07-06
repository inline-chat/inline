import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema/chats"
import { chatParticipantGroups } from "@in/server/db/schema/userGroups"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"
import { ChatParticipant, ChatParticipantGroup, User, UserGroup } from "@inline-chat/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Encoders } from "../realtime/encoders/encoders"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  encodeChatParticipantGroup,
  encodeUserGroup,
  loadChatParticipantGroups,
  loadProtocolUsers,
} from "@in/server/modules/userGroups"

export async function getChatParticipants(
  input: {
    chatId: number
  },
  context: FunctionContext,
): Promise<{
  participants: ChatParticipant[]
  groupParticipants: ChatParticipantGroup[]
  users: User[]
  groups: UserGroup[]
}> {
  try {
    const [chat] = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)

    if (!chat) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
    }

    await AccessGuards.ensureChatAccess(chat, context.currentUserId)

    const participants = await db.query.chatParticipants.findMany({
      where: {
        chatId: input.chatId,
      },
      with: {
        user: {
          with: {
            photoFile: true,
          },
        },
      },
    })

    const participantGroups = await db
      .select()
      .from(chatParticipantGroups)
      .where(eq(chatParticipantGroups.chatId, input.chatId))

    const groups = await loadChatParticipantGroups(input.chatId)

    if ((!participants || participants.length === 0) && participantGroups.length === 0) {
      return {
        participants: [],
        groupParticipants: [],
        users: [],
        groups: [],
      }
    }

    const directUsers = participants
      .map((participant) => {
        if (!participant.user) return null

        return Encoders.user({
          user: participant.user,
          photoFile: participant.user.photoFile ?? undefined,
          min: true,
        })
      })
      .filter((user) => user !== null)

    const groupUsers = await loadProtocolUsers(groups.flatMap((group) => group.userIds))

    return {
      participants: participants.map((participant) => Encoders.chatParticipant(participant)),
      groupParticipants: participantGroups.map((group) => encodeChatParticipantGroup(group)),
      users: mergeProtocolUsers(directUsers, groupUsers),
      groups: groups.map((group) => encodeUserGroup(group, context.currentUserId)),
    }
  } catch (error) {
    Log.shared.error(`Failed to get participants for chat ${input.chatId}: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to get chat participants", 500)
  }
}

function mergeProtocolUsers(...userLists: User[][]): User[] {
  const usersById = new Map<bigint, User>()
  for (const user of userLists.flat()) {
    usersById.set(user.id, user)
  }
  return [...usersById.values()]
}

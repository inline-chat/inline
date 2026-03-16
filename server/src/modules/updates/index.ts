import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { dialogs, members } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { ChatModel, getChatFromPeer } from "@in/server/db/models/chats"
import { getEffectiveAccessUserIds } from "@in/server/modules/subthreads"

export type UpdateGroup =
  // Used for DMs and non-public threads
  | { type: "dmUsers"; userIds: number[] }
  // Used for public threads
  | { type: "threadUsers"; spaceId?: number; userIds: number[] }
  // Used for spaces
  | { type: "spaceUsers"; spaceId: number; userIds: number[] }

import type { TPeerInfo } from "@in/server/api-types"
import invariant from "tiny-invariant"
import type { InputPeer } from "@inline-chat/protocol/core"

/**
 * Get the group of users that need to receive an update for an event
 */
export const getUpdateGroup = async (peerId: TPeerInfo, context: { currentUserId: number }): Promise<UpdateGroup> => {
  const chat = await getChatFromPeer(peerId, context)

  if (chat.type === "private") {
    invariant(chat.minUserId && chat.maxUserId, "Private chat must have minUserId and maxUserId")
    if (chat.minUserId === chat.maxUserId) {
      // Saved message
      return { type: "dmUsers", userIds: [chat.minUserId] }
    }
    // DMs
    return { type: "dmUsers", userIds: [chat.minUserId, chat.maxUserId] }
  } else if (chat.type === "thread") {
    const userIds = await getEffectiveAccessUserIds(chat)
    return chat.spaceId != null
      ? { type: "threadUsers", spaceId: chat.spaceId, userIds }
      : { type: "threadUsers", userIds }
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

/**
 * Get the group of users that need to receive an update for an event
 */
export const getUpdateGroupFromInputPeer = async (
  inputPeer: InputPeer,
  context: { currentUserId: number },
): Promise<UpdateGroup> => {
  const chat = await ChatModel.getChatFromInputPeer(inputPeer, context)

  if (chat.type === "private") {
    invariant(chat.minUserId && chat.maxUserId, "Private chat must have minUserId and maxUserId")
    if (chat.minUserId === chat.maxUserId) {
      // Saved message
      return { type: "dmUsers", userIds: [chat.minUserId] }
    }
    // DMs
    return { type: "dmUsers", userIds: [chat.minUserId, chat.maxUserId] }
  } else if (chat.type === "thread") {
    const userIds = await getEffectiveAccessUserIds(chat)
    return chat.spaceId != null
      ? { type: "threadUsers", spaceId: chat.spaceId, userIds }
      : { type: "threadUsers", userIds }
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

export const getUpdateGroupForSpace = async (
  spaceId: number,
  context: { currentUserId: number },
): Promise<UpdateGroup> => {
  const users = await db.select({ userId: members.userId }).from(members).where(eq(members.spaceId, spaceId))
  return { type: "spaceUsers", spaceId, userIds: users.map((user) => user.userId) }
}

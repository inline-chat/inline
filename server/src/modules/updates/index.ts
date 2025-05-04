import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { chatParticipants, dialogs, members } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { ChatModel, getChatFromPeer } from "@in/server/db/models/chats"

export type UpdateGroup =
  // Used for DMs and non-public threads
  | { type: "users"; userIds: number[] }
  // Used for public threads
  | { type: "space"; spaceId: number }

import type { TPeerInfo } from "@in/server/api-types"
import invariant from "tiny-invariant"
import type { InputPeer } from "@in/protocol/core"

/**
 * Get the group of users that need to receive an update for an event
 */
export const getUpdateGroup = async (peerId: TPeerInfo, context: { currentUserId: number }): Promise<UpdateGroup> => {
  const chat = await getChatFromPeer(peerId, context)

  if (chat.type === "private") {
    invariant(chat.minUserId && chat.maxUserId, "Private chat must have minUserId and maxUserId")
    if (chat.minUserId === chat.maxUserId) {
      // Saved message
      return { type: "users", userIds: [chat.minUserId] }
    }
    // DMs
    return { type: "users", userIds: [chat.minUserId, chat.maxUserId] }
  } else if (chat.type === "thread") {
    if (!chat.spaceId) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    if (chat.publicThread) {
      // Legacy
      //return { type: "space", spaceId: chat.spaceId }

      // For now, fetch all users in the space
      const users = await db.select({ userId: members.userId }).from(members).where(eq(members.spaceId, chat.spaceId))
      return { type: "users", userIds: users.map((user) => user.userId) }
    } else {
      // get participant ids from chatParticipants
      const participantIds = await db
        .select({ userId: chatParticipants.userId })
        .from(chatParticipants)
        .where(eq(chatParticipants.chatId, chat.id))
        // TODO: Possible memory OOM issue can happen here for larger chats which will require pagination and batching
        .then((result) => result.map(({ userId }) => userId))
      return { type: "users", userIds: participantIds }
    }
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
      return { type: "users", userIds: [chat.minUserId] }
    }
    // DMs
    return { type: "users", userIds: [chat.minUserId, chat.maxUserId] }
  } else if (chat.type === "thread") {
    if (!chat.spaceId) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    if (chat.publicThread) {
      // Legacy
      //return { type: "space", spaceId: chat.spaceId }

      // For now, fetch all users in the space
      const users = await db.select({ userId: members.userId }).from(members).where(eq(members.spaceId, chat.spaceId))
      return { type: "users", userIds: users.map((user) => user.userId) }
    } else {
      // get participant ids from chatParticipants
      const participantIds = await db
        .select({ userId: chatParticipants.userId })
        .from(chatParticipants)
        .where(eq(chatParticipants.chatId, chat.id))
        // TODO: Possible memory OOM issue can happen here for larger chats which will require pagination and batching
        .then((result) => result.map(({ userId }) => userId))
      return { type: "users", userIds: participantIds }
    }
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

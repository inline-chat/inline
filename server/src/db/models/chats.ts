import { db } from "@in/server/db"
import { eq, and } from "drizzle-orm"
import { chats, type DbChat } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { TPeerInfo } from "@in/server/api-types"

export async function getChatFromPeer(peer: TPeerInfo, context: { currentUserId: number }): Promise<DbChat> {
  if ("userId" in peer) {
    const userId = peer.userId
    if (!userId || isNaN(userId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    // For self-chat, both minUserId and maxUserId will be currentUserId
    const minUserId = Math.min(context.currentUserId, userId)
    const maxUserId = Math.max(context.currentUserId, userId)

    let chat = await db
      .select()
      .from(chats)
      .where(and(eq(chats.type, "private"), eq(chats.minUserId, minUserId), eq(chats.maxUserId, maxUserId)))
      .then((result) => result[0])

    if (!chat) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    return chat
  } else if ("threadId" in peer) {
    const threadId = peer.threadId
    if (!threadId || isNaN(threadId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    let chat = await db
      .select()
      .from(chats)
      .where(eq(chats.id, threadId))
      .then((result) => result[0])

    if (!chat) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    return chat
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

// todo: optimize to only select lastMsgId
export async function getLastMessageId(
  peer: TPeerInfo,
  context: { currentUserId: number },
): Promise<number | undefined> {
  let chat = await getChatFromPeer(peer, context)
  return chat.lastMsgId ?? undefined
}

import { db } from "@in/server/db"
import { and, eq, or } from "drizzle-orm"
import { chats, dialogs, messages, users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Optional, type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { TInputId } from "@in/server/types/methods"
import { getLastMessageId } from "@in/server/db/models/chats"

export const Input = Type.Object({
  peerUserId: Optional(TInputId),
  peerThreadId: Optional(TInputId),

  maxId: Optional(Type.Integer()), // max message id to mark as read
})

export const Response = Type.Object({
  // unreadCount: Type.Integer(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const peerUserId = input.peerUserId ? Number(input.peerUserId) : undefined
  const peerThreadId = input.peerThreadId ? Number(input.peerThreadId) : undefined
  const peer = peerUserId ? { userId: peerUserId! } : { threadId: peerThreadId! }

  if (!peerUserId && !peerThreadId) {
    // requires either peerUserId or peerThreadId
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  if (peerUserId && peerThreadId) {
    // cannot have both peerUserId and peerThreadId
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  let maxId = input.maxId
  if (maxId === undefined) {
    // Get last message id for peer user
    const lastMsgId = await getLastMessageId(peer, context)
    maxId = lastMsgId ?? undefined
  }

  if (maxId === undefined) {
    // chat is empty or last message is nil
    //throw new InlineError(InlineError.ApiError.INTERNAL)
    return {}
  }

  const _ = await db
    .update(dialogs)
    .set({ readInboxMaxId: maxId })
    .where(
      and(
        peerUserId ? eq(dialogs.peerUserId, peerUserId) : eq(dialogs.chatId, peerThreadId!),
        eq(dialogs.userId, context.currentUserId),
      ),
    )

  return {}
}

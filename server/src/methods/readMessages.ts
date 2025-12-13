import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { dialogs } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Optional, type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { TInputId } from "@in/server/types/methods"
import { getLastMessageId } from "@in/server/db/models/chats"
import type { InputPeer, Update } from "@in/protocol/core"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { DialogsModel } from "@in/server/db/models/dialogs"

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

  const inputPeer: InputPeer = peerUserId
    ? { type: { oneofKind: "user", user: { userId: BigInt(peerUserId) } } }
    : { type: { oneofKind: "chat", chat: { chatId: BigInt(peerThreadId!) } } }
  const outputPeer = encodePeerFromInputPeer({ inputPeer, currentUserId: context.currentUserId })

  let maxId = input.maxId
  if (maxId === undefined) {
    // Get last message id for peer user
    const lastMsgId = await getLastMessageId(peer, context)
    maxId = lastMsgId ?? undefined
  }

  if (maxId === undefined) {
    // chat is empty or last message is nil, but we still want to clear unreadMark
    const updated = await db
      .update(dialogs)
      .set({ unreadMark: false })
      .where(
        and(
          peerUserId ? eq(dialogs.peerUserId, peerUserId) : eq(dialogs.chatId, peerThreadId!),
          eq(dialogs.userId, context.currentUserId),
        ),
      )
      .returning({ chatId: dialogs.chatId })

    if (updated.length > 0) {
      const updates: Update[] = [
        {
          update: {
            oneofKind: "markAsUnread",
            markAsUnread: { peerId: outputPeer, unreadMark: false },
          },
        },
      ]

      RealtimeUpdates.pushToUser(context.currentUserId, updates, { skipSessionId: context.currentSessionId })
    }

    return {}
  }

  const updated = await db
    .update(dialogs)
    .set({ readInboxMaxId: maxId, unreadMark: false })
    .where(
      and(
        peerUserId ? eq(dialogs.peerUserId, peerUserId) : eq(dialogs.chatId, peerThreadId!),
        eq(dialogs.userId, context.currentUserId),
      ),
    )
    .returning({ chatId: dialogs.chatId })

  if (updated.length > 0) {
    const chatId = updated[0]?.chatId
    const unreadCount = chatId ? await DialogsModel.getUnreadCount(chatId, context.currentUserId) : 0

    const updates: Update[] = [
      {
        update: {
          oneofKind: "updateReadMaxId",
          updateReadMaxId: {
            peerId: outputPeer,
            readMaxId: BigInt(maxId),
            unreadCount,
          },
        },
      },
    ]

    RealtimeUpdates.pushToUser(context.currentUserId, updates, { skipSessionId: context.currentSessionId })
  }

  return {}
}

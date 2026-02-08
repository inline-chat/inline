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
import { Notifications } from "@in/server/modules/notifications/notifications"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@in/protocol/server"

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
          eq(dialogs.unreadMark, true),
        ),
      )
      .returning({ chatId: dialogs.chatId })

    if (updated.length > 0) {
      const userUpdatePayload: ServerUpdate["update"] = {
        oneofKind: "userMarkAsUnread",
        userMarkAsUnread: {
          peerId: outputPeer,
          unreadMark: false,
        },
      }
      await UserBucketUpdates.enqueue({ userId: context.currentUserId, update: userUpdatePayload })

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

  const existing = await db
    .select({
      chatId: dialogs.chatId,
      readInboxMaxId: dialogs.readInboxMaxId,
      unreadMark: dialogs.unreadMark,
    })
    .from(dialogs)
    .where(
      and(
        peerUserId ? eq(dialogs.peerUserId, peerUserId) : eq(dialogs.chatId, peerThreadId!),
        eq(dialogs.userId, context.currentUserId),
      ),
    )
    .limit(1)
    .then((rows) => rows[0])

  const previousReadMaxId = existing?.readInboxMaxId ?? 0
  const didClearUnreadMark = existing?.unreadMark === true
  // Never allow read max id to move backwards due to stale client state.
  const effectiveMaxId = Math.max(previousReadMaxId, maxId)
  const didAdvanceReadMaxId = effectiveMaxId > previousReadMaxId

  if (!didAdvanceReadMaxId && !didClearUnreadMark) {
    return {}
  }

  const set: Partial<typeof dialogs.$inferInsert> = {
    unreadMark: false,
  }
  if (didAdvanceReadMaxId) {
    set.readInboxMaxId = effectiveMaxId
  }

  const updated = await db
    .update(dialogs)
    .set(set)
    .where(
      and(
        peerUserId ? eq(dialogs.peerUserId, peerUserId) : eq(dialogs.chatId, peerThreadId!),
        eq(dialogs.userId, context.currentUserId),
      ),
    )
    .returning({ chatId: dialogs.chatId })

  if (updated.length === 0) {
    return {}
  }

  const chatId = updated[0]?.chatId
  const unreadCount =
    didAdvanceReadMaxId && chatId ? await DialogsModel.getUnreadCount(chatId, context.currentUserId) : 0

  // Persist read state changes in the user bucket so other sessions/devices can repair via catch-up.
  // Note: we only persist when readMaxId advances (not when we merely clear unreadMark).
  if (didAdvanceReadMaxId) {
    const userUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "userReadMaxId",
      userReadMaxId: {
        peerId: outputPeer,
        readMaxId: BigInt(effectiveMaxId),
        unreadCount,
      },
    }
    await UserBucketUpdates.enqueue({ userId: context.currentUserId, update: userUpdatePayload })
  } else if (didClearUnreadMark) {
    const userUpdatePayload: ServerUpdate["update"] = {
      oneofKind: "userMarkAsUnread",
      userMarkAsUnread: {
        peerId: outputPeer,
        unreadMark: false,
      },
    }
    await UserBucketUpdates.enqueue({ userId: context.currentUserId, update: userUpdatePayload })
  }

  if (didAdvanceReadMaxId) {
    const updates: Update[] = [
      {
        update: {
          oneofKind: "updateReadMaxId",
          updateReadMaxId: {
            peerId: outputPeer,
            readMaxId: BigInt(effectiveMaxId),
            unreadCount,
          },
        },
      },
    ]
    RealtimeUpdates.pushToUser(context.currentUserId, updates, { skipSessionId: context.currentSessionId })
  } else if (didClearUnreadMark) {
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

  // Clear any delivered iOS notifications up to maxId across all iOS sessions.
  if (chatId && didAdvanceReadMaxId) {
    try {
      await Notifications.sendToUser({
        userId: context.currentUserId,
        payload: {
          kind: "messages_read",
          threadId: `chat_${chatId}`,
          readUpToMessageId: String(effectiveMaxId),
        },
      })
    } catch {
      // best-effort only; skip if session lookup fails
    }
  }

  return {}
}

import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { dialogs } from "@in/server/db/schema"
import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import type { FunctionContext } from "@in/server/functions/_types"
import { getLastMessageId } from "@in/server/db/models/chats"
import { InlineError } from "@in/server/types/errors"

type Input = {
  peer: InputPeer
  maxId?: number
}

type Output = {
  updates: Update[]
}

export const readMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  const peerUserId =
    input.peer.type.oneofKind === "user"
      ? Number(input.peer.type.user.userId)
      : input.peer.type.oneofKind === "self"
        ? context.currentUserId
        : undefined
  const peerThreadId = input.peer.type.oneofKind === "chat" ? Number(input.peer.type.chat.chatId) : undefined
  let peer: { userId: number } | { threadId: number }
  let dialogPeerCondition: ReturnType<typeof eq>
  if (peerUserId !== undefined) {
    peer = { userId: peerUserId }
    dialogPeerCondition = eq(dialogs.peerUserId, peerUserId)
  } else if (peerThreadId !== undefined) {
    peer = { threadId: peerThreadId }
    dialogPeerCondition = eq(dialogs.chatId, peerThreadId)
  } else {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  const outputPeer = encodePeerFromInputPeer({ inputPeer: input.peer, currentUserId: context.currentUserId })

  let maxId = input.maxId
  if (maxId === undefined) {
    const lastMsgId = await getLastMessageId(peer, context)
    maxId = lastMsgId ?? undefined
  }

  if (maxId === undefined) {
    const updated = await db
      .update(dialogs)
      .set({ unreadMark: false })
      .where(
        and(
          dialogPeerCondition,
          eq(dialogs.userId, context.currentUserId),
          eq(dialogs.unreadMark, true),
        ),
      )
      .returning({ chatId: dialogs.chatId })

    if (updated.length === 0) {
      return { updates: [] }
    }

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
    return { updates }
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
        dialogPeerCondition,
        eq(dialogs.userId, context.currentUserId),
      ),
    )
    .limit(1)
    .then((rows) => rows[0])

  const previousReadMaxId = existing?.readInboxMaxId ?? 0
  const didClearUnreadMark = existing?.unreadMark === true
  const effectiveMaxId = Math.max(previousReadMaxId, maxId)
  const didAdvanceReadMaxId = effectiveMaxId > previousReadMaxId

  if (!didAdvanceReadMaxId && !didClearUnreadMark) {
    return { updates: [] }
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
        dialogPeerCondition,
        eq(dialogs.userId, context.currentUserId),
      ),
    )
    .returning({ chatId: dialogs.chatId })

  if (updated.length === 0) {
    return { updates: [] }
  }

  const chatId = updated[0]?.chatId
  const unreadCount =
    didAdvanceReadMaxId && chatId ? await DialogsModel.getUnreadCount(chatId, context.currentUserId) : 0

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

  let updates: Update[] = []
  if (didAdvanceReadMaxId) {
    updates = [
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
  } else if (didClearUnreadMark) {
    updates = [
      {
        update: {
          oneofKind: "markAsUnread",
          markAsUnread: { peerId: outputPeer, unreadMark: false },
        },
      },
    ]
  }

  if (updates.length > 0) {
    RealtimeUpdates.pushToUser(context.currentUserId, updates, { skipSessionId: context.currentSessionId })
  }

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

  return { updates }
}

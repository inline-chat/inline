import { db } from "@in/server/db"
import { and, eq, sql } from "drizzle-orm"
import { dialogs, users } from "@in/server/db/schema"
import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { FunctionContext } from "@in/server/functions/_types"
import type { ServerUpdate } from "@in/server/protocol/server"
import { ChatModel, getLastMessageId } from "@in/server/db/models/chats"
import { InlineError } from "@in/server/types/errors"
import {
  emitMessageSubthreadUpdateIfNeeded,
  isLinkedSubthread,
  isReplyThread,
  queueSubthreadParentUpdate,
} from "@in/server/modules/subthreads"
import { ModelError } from "@in/server/db/models/_errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"

type Input = {
  peer: InputPeer
  maxId?: number
}

type Output = {
  updates: Update[]
}

export const readMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getChatFromInputPeer(input.peer, context).catch((error) => {
    if (error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID) {
      if (input.peer.type.oneofKind === "chat") throw RealtimeRpcError.ChatIdInvalid()
      throw RealtimeRpcError.PeerIdInvalid()
    }
    throw error
  })
  // Dialog state survives list placement changes and may briefly survive revoked membership.
  // Reauthorize the chat before reading or mutating that per-user projection.
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

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

  const mutation = await db.transaction(async (tx): Promise<{
    updated: boolean
    chatId?: number
    effectiveMaxId?: number
    didAdvanceReadMaxId: boolean
    didClearUnreadMark: boolean
    unreadCount: number
  }> => {
    // User-bucket sequence allocation and dialog mutation share the same
    // deterministic owner order: users, then dialogs. This makes the durable
    // projection commit in the same order as the state it describes.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, context.currentUserId)).for("update").limit(1)

    const existing = await tx
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
      .for("update")
      .limit(1)
      .then((rows) => rows[0])

    if (maxId === undefined) {
      if (existing?.unreadMark !== true) {
        return { updated: false, didAdvanceReadMaxId: false, didClearUnreadMark: false, unreadCount: 0 }
      }

      const updated = await tx
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
        return { updated: false, didAdvanceReadMaxId: false, didClearUnreadMark: false, unreadCount: 0 }
      }

      await UserBucketUpdates.enqueue(
        {
          userId: context.currentUserId,
          update: {
            oneofKind: "userMarkAsUnread",
            userMarkAsUnread: {
              peerId: outputPeer,
              unreadMark: false,
            },
          },
        },
        { tx },
      )

      return {
        updated: true,
        chatId: updated[0]?.chatId,
        didAdvanceReadMaxId: false,
        didClearUnreadMark: true,
        unreadCount: 0,
      }
    }

    const previousReadMaxId = existing?.readInboxMaxId ?? 0
    const didClearUnreadMark = existing?.unreadMark === true
    const effectiveMaxId = Math.max(previousReadMaxId, maxId)
    const didAdvanceReadMaxId = effectiveMaxId > previousReadMaxId

    if (!didAdvanceReadMaxId && !didClearUnreadMark) {
      return { updated: false, didAdvanceReadMaxId: false, didClearUnreadMark: false, unreadCount: 0 }
    }

    const updated = await tx
      .update(dialogs)
      .set({
        unreadMark: false,
        ...(didAdvanceReadMaxId
          ? { readInboxMaxId: sql<number>`GREATEST(COALESCE(${dialogs.readInboxMaxId}, 0), ${maxId})` }
          : {}),
      })
      .where(
        and(
          dialogPeerCondition,
          eq(dialogs.userId, context.currentUserId),
        ),
      )
      .returning({ chatId: dialogs.chatId })

    if (updated.length === 0) {
      return { updated: false, didAdvanceReadMaxId: false, didClearUnreadMark: false, unreadCount: 0 }
    }

    const unreadCount =
      didAdvanceReadMaxId && updated[0]?.chatId
        ? await DialogsModel.getUnreadCount(updated[0].chatId, context.currentUserId, tx)
        : 0
    const userUpdatePayload: ServerUpdate["update"] = didAdvanceReadMaxId
      ? {
          oneofKind: "userReadMaxId",
          userReadMaxId: {
            peerId: outputPeer,
            readMaxId: BigInt(effectiveMaxId),
            unreadCount,
          },
        }
      : {
          oneofKind: "userMarkAsUnread",
          userMarkAsUnread: {
            peerId: outputPeer,
            unreadMark: false,
          },
        }
    await UserBucketUpdates.enqueue(
      {
        userId: context.currentUserId,
        update: userUpdatePayload,
      },
      { tx },
    )

    return {
      updated: true,
      chatId: updated[0]?.chatId,
      effectiveMaxId,
      didAdvanceReadMaxId,
      didClearUnreadMark,
      unreadCount,
    }
  })

  if (!mutation.updated) {
    return { updates: [] }
  }

  const { chatId, didAdvanceReadMaxId, didClearUnreadMark, effectiveMaxId, unreadCount } = mutation

  let updates: Update[] = []
  if (didAdvanceReadMaxId && effectiveMaxId !== undefined) {
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

  if (chatId) {
    if (isReplyThread(chat)) {
      await emitMessageSubthreadUpdateIfNeeded({
        chatId,
        currentUserId: context.currentUserId,
      })
    } else if (isLinkedSubthread(chat)) {
      queueSubthreadParentUpdate({
        chatId,
        currentUserId: context.currentUserId,
        reason: "read state",
      })
    }
  }

  if (chatId && didAdvanceReadMaxId && effectiveMaxId !== undefined) {
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

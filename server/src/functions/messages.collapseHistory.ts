import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { chats, dialogs, messages, type DbChat } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { emitReplyThreadParentRepliesUpdateIfNeeded } from "@in/server/modules/subthreads"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@in/server/protocol/server"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { decodeDate, encodeDate, encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { and, eq, gt, isNull, ne, sql } from "drizzle-orm"

type Input = {
  peerId: InputPeer
  maxId?: number
}

type Output = {
  updates: Update[]
}

export const collapseHistory = async (input: Input, context: FunctionContext): Promise<Output> => {
  if (input.maxId !== undefined && (!Number.isSafeInteger(input.maxId) || input.maxId <= 0)) {
    throw RealtimeRpcError.MessageIdInvalid()
  }

  const accessibleChat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(accessibleChat, context.currentUserId)

  const result = await db.transaction(async (tx) => {
    const [chat] = await tx
      .select()
      .from(chats)
      .where(eq(chats.id, accessibleChat.id))
      .for("update")
      .limit(1)

    if (!chat) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    if (input.maxId !== undefined && input.maxId > chat.messageIdHighWater) {
      throw RealtimeRpcError.MessageIdInvalid()
    }

    const [existing] = await tx
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId)))
      .for("update")
      .limit(1)

    const peerId = encodeOutputPeerFromChat(chat, { currentUserId: context.currentUserId })

    if (input.maxId === undefined) {
      if (!existing?.collapsedMaxId) {
        return { updates: [] as Update[], chatId: chat.id, didAdvanceRead: false, readMaxId: undefined }
      }

      await tx
        .update(dialogs)
        .set({ collapsedMaxId: null, collapsedAt: null })
        .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId)))

      await UserBucketUpdates.enqueue(
        {
          userId: context.currentUserId,
          update: {
            oneofKind: "userCollapseHistory",
            userCollapseHistory: { peerId, maxId: undefined, collapsedAt: undefined },
          },
        },
        { tx },
      )

      return {
        updates: [collapseUpdate(peerId, undefined, undefined)],
        chatId: chat.id,
        didAdvanceRead: false,
        readMaxId: undefined,
      }
    }

    // The locked high-water mark is the atomic definition of "all messages that existed
    // when clear ran". The client max ID is still validated and drives optimistic UI, but
    // may lag because local Chat.lastMsgId can temporarily point at an optimistic message.
    const collapsedMaxId = Math.max(existing?.collapsedMaxId ?? 0, chat.messageIdHighWater)
    const nowGeneration = encodeDateStrict(new Date())
    const previousGeneration = encodeDate(existing?.collapsedAt ?? undefined)
    const collapsedAt = decodeDate(
      previousGeneration !== undefined && previousGeneration >= nowGeneration
        ? previousGeneration + 1n
        : nowGeneration,
    )
    const readMaxId = Math.max(existing?.readInboxMaxId ?? 0, collapsedMaxId)
    const didAdvanceRead = readMaxId > (existing?.readInboxMaxId ?? 0)
    const didClearUnreadMark = existing?.unreadMark === true

    if (existing) {
      await tx
        .update(dialogs)
        .set({ collapsedMaxId, collapsedAt, readInboxMaxId: readMaxId, unreadMark: false })
        .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId)))
    } else {
      await tx.insert(dialogs).values({
        chatId: chat.id,
        userId: context.currentUserId,
        peerUserId: peerUserIdFor(chat, context.currentUserId),
        spaceId: chat.spaceId ?? null,
        ...dialogOpenDefaultsForChat(chat),
        collapsedMaxId,
        collapsedAt,
        readInboxMaxId: readMaxId,
        unreadMark: false,
      })
    }

    const [unread] = await tx
      .select({ count: sql<number>`count(*)::int` })
      .from(messages)
      .where(
        and(
          eq(messages.chatId, chat.id),
          gt(messages.messageId, readMaxId),
          ne(messages.fromId, context.currentUserId),
          isNull(messages.systemMessageEncrypted),
        ),
      )
    const unreadCount = unread?.count ?? 0

    const bucketUpdates: { userId: number; update: ServerUpdate["update"] }[] = []
    const updates: Update[] = []

    bucketUpdates.push({
      userId: context.currentUserId,
      update: {
        oneofKind: "userCollapseHistory",
        userCollapseHistory: {
          peerId,
          maxId: BigInt(collapsedMaxId),
          collapsedAt: encodeDate(collapsedAt),
        },
      },
    })
    updates.push(collapseUpdate(peerId, collapsedMaxId, collapsedAt))

    if (didAdvanceRead) {
      bucketUpdates.push({
        userId: context.currentUserId,
        update: {
          oneofKind: "userReadMaxId",
          userReadMaxId: { peerId, readMaxId: BigInt(readMaxId), unreadCount },
        },
      })
      updates.push({
        update: {
          oneofKind: "updateReadMaxId",
          updateReadMaxId: { peerId, readMaxId: BigInt(readMaxId), unreadCount },
        },
      })
    } else if (didClearUnreadMark) {
      bucketUpdates.push({
        userId: context.currentUserId,
        update: {
          oneofKind: "userMarkAsUnread",
          userMarkAsUnread: { peerId, unreadMark: false },
        },
      })
      updates.push({
        update: {
          oneofKind: "markAsUnread",
          markAsUnread: { peerId, unreadMark: false },
        },
      })
    }

    await UserBucketUpdates.enqueueMany(bucketUpdates, { tx })

    return { updates, chatId: chat.id, didAdvanceRead, readMaxId }
  })

  if (result.updates.length > 0) {
    RealtimeUpdates.pushToUser(context.currentUserId, result.updates, { skipSessionId: context.currentSessionId })
  }

  if (result.didAdvanceRead && result.readMaxId !== undefined) {
    await emitReplyThreadParentRepliesUpdateIfNeeded({
      chatId: result.chatId,
      currentUserId: context.currentUserId,
    })

    try {
      await Notifications.sendToUser({
        userId: context.currentUserId,
        payload: {
          kind: "messages_read",
          threadId: `chat_${result.chatId}`,
          readUpToMessageId: String(result.readMaxId),
        },
      })
    } catch {
      // Best-effort only; the durable dialog and user-bucket writes already committed.
    }
  }

  return { updates: result.updates }
}

function collapseUpdate(
  peerId: ReturnType<typeof encodeOutputPeerFromChat>,
  maxId?: number,
  collapsedAt?: Date,
): Update {
  return {
    update: {
      oneofKind: "collapseHistory",
      collapseHistory: {
        peerId,
        maxId: maxId === undefined ? undefined : BigInt(maxId),
        collapsedAt: encodeDate(collapsedAt),
      },
    },
  }
}

function peerUserIdFor(chat: DbChat, userId: number): number | null {
  if (chat.type !== "private" || chat.minUserId == null || chat.maxUserId == null) {
    return null
  }
  return chat.minUserId === userId ? chat.maxUserId : chat.minUserId
}

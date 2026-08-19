import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { dialogs, users } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { emitReplyThreadParentRepliesUpdateIfNeeded } from "@in/server/modules/subthreads"

type Input = {
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const markAsUnread = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)
  const peer = encodePeerFromInputPeer({ inputPeer: input.peer, currentUserId: context.currentUserId })

  const result = await db.transaction(async (tx) => {
    // Keep the user-bucket sequence owner ahead of the dialog row owner so
    // this projection commits in the same order as the durable dialog state.
    await tx.select({ id: users.id }).from(users).where(eq(users.id, context.currentUserId)).for("update").limit(1)

    const [existing] = await tx
      .select({ unreadMark: dialogs.unreadMark })
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chatId), eq(dialogs.userId, context.currentUserId)))
      .for("update")
      .limit(1)

    // No-op if already marked unread.
    if (existing?.unreadMark === true) {
      return undefined
    }

    const updated = await tx
      .update(dialogs)
      .set({ unreadMark: true })
      .where(
        and(
          eq(dialogs.chatId, chatId),
          eq(dialogs.userId, context.currentUserId),
        ),
      )
      .returning()

    if (updated.length === 0) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    await UserBucketUpdates.enqueue(
      {
        userId: context.currentUserId,
        update: {
          oneofKind: "userMarkAsUnread",
          userMarkAsUnread: {
            peerId: peer,
            unreadMark: true,
          },
        },
      },
      { tx },
    )

    return updated
  })

  // The transaction serialized this no-op against a concurrent read or mark.
  if (result === undefined) {
    return { updates: [] }
  }

  // Create an update for the dialog change
  const update: Update = {
    update: {
      oneofKind: "markAsUnread",
      markAsUnread: {
        peerId: peer,
        unreadMark: true,
      },
    },
  }

  const updates: Update[] = [update]

  // Mark-as-unread is per-user; push to all sessions for this user (skip the initiating session).
  RealtimeUpdates.pushToUser(context.currentUserId, updates, { skipSessionId: context.currentSessionId })

  await emitReplyThreadParentRepliesUpdateIfNeeded({
    chatId,
    currentUserId: context.currentUserId,
  })

  return { updates }
} 

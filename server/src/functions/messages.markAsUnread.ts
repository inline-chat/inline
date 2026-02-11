import type { InputPeer, Update } from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import type { ServerUpdate } from "@inline-chat/protocol/server"

type Input = {
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const markAsUnread = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)

  const existing = await db
    .select({ unreadMark: dialogs.unreadMark })
    .from(dialogs)
    .where(and(eq(dialogs.chatId, chatId), eq(dialogs.userId, context.currentUserId)))
    .limit(1)
    .then((rows) => rows[0])

  // No-op if already marked unread.
  if (existing?.unreadMark === true) {
    return { updates: [] }
  }

  // Update the dialog to mark as unread
  const result = await db
    .update(dialogs)
    .set({ unreadMark: true })
    .where(
      and(
        eq(dialogs.chatId, chatId),
        eq(dialogs.userId, context.currentUserId)
      )
    )
    .returning()

  if (result.length === 0) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  // Create an update for the dialog change
  const peer = encodePeerFromInputPeer({ inputPeer: input.peer, currentUserId: context.currentUserId })
  
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

  const userUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "userMarkAsUnread",
    userMarkAsUnread: {
      peerId: peer,
      unreadMark: true,
    },
  }
  await UserBucketUpdates.enqueue({ userId: context.currentUserId, update: userUpdatePayload })

  // Mark-as-unread is per-user; push to all sessions for this user (skip the initiating session).
  RealtimeUpdates.pushToUser(context.currentUserId, updates, { skipSessionId: context.currentSessionId })

  return { updates }
} 

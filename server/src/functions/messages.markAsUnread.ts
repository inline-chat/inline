import type { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { dialogs } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import {  updatesModule } from "@in/server/modules/updates/updates"

type Input = {
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

export const markAsUnread = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chatId = await ChatModel.getChatIdFromInputPeer(input.peer, context)

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
    throw RealtimeRpcError.ChatIdInvalid
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

  // Push update to connected clients using dynamic import to avoid circular dependency
  await updatesModule.pushUpdate(updates, { peerId: input.peer, currentUserId: context.currentUserId })

  return { updates }
} 
import type { InputPeer } from "@in/protocol/core"
import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { dialogs } from "@in/server/db/schema/dialogs"
import { members } from "@in/server/db/schema/members"
import { Log, LogLevel } from "@in/server/utils/log"
import { ChatModel } from "@in/server/db/models/chats"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"

const log = new Log("functions.deleteChat")
/**
 * Deletes a chat (space thread) if the user is an admin/owner of the space.
 * Also deletes participants and dialogs for the chat.
 */
export async function deleteChat(input: { peer: InputPeer }, context: FunctionContext): Promise<{}> {
  const { peer } = input
  const { currentUserId } = context

  // Get chat
  const chat = await ChatModel.getChatFromInputPeer(peer, { currentUserId })
  if (!chat.spaceId || chat.type !== "thread") {
    log.error("Chat is not a space thread", { chatId: chat.id })
    throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a space thread", 400)
  }

  // Check user role in space
  const member = await db.query.members.findFirst({
    where: and(eq(members.spaceId, chat.spaceId), eq(members.userId, currentUserId)),
  })
  if (!member || (member.role !== "admin" && member.role !== "owner")) {
    log.error("User is not admin/owner in space", { userId: currentUserId, spaceId: chat.spaceId })
    throw new RealtimeRpcError(RealtimeRpcError.Code.UNAUTHENTICATED, "Not allowed", 403)
  }

  // Delete chat, participants, dialogs in a transaction
  try {
    await db.transaction(async (tx) => {
      await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chat.id))
      await tx.delete(dialogs).where(eq(dialogs.chatId, chat.id))
      await tx.delete(chats).where(eq(chats.id, chat.id))
    })
    log.info("Deleted chat and related data", { chatId: chat.id })
    return {}
  } catch (err) {
    log.error("Failed to delete chat", { chatId: chat.id, error: err })
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to delete chat", 500)
  }
}

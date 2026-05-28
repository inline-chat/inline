import { db } from "@in/server/db"
import { chats, type DbChat } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { InlineError } from "@in/server/types/errors"
import { eq } from "drizzle-orm"

export async function getAuthorizedChat(chatId: number, userId: number): Promise<DbChat> {
  const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
  if (!chat) {
    throw new InlineError(InlineError.ApiError.PEER_INVALID)
  }

  try {
    await AccessGuards.ensureChatAccess(chat, userId)
  } catch (error) {
    if (error instanceof RealtimeRpcError) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    throw error
  }

  return chat
}

import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"
import { ChatParticipant } from "@in/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export async function getChatParticipants(
  input: {
    chatId: number
  },
  context: FunctionContext,
): Promise<ChatParticipant[]> {
  try {
    const chat = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)

    if (!chat || chat.length === 0) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, `Chat with ID ${input.chatId} not found`, 404)
    }

    const participants = await db.select().from(chatParticipants).where(eq(chatParticipants.chatId, input.chatId))

    if (!participants || participants.length === 0) {
      return []
    }

    return participants.map((participant) => ({
      userId: BigInt(participant.userId),
      date: encodeDateStrict(participant.date),
    }))
  } catch (error) {
    Log.shared.error(`Failed to get participants for chat ${input.chatId}: ${error}`)
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to get chat participants", 500)
  }
}

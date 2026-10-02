import { createHash } from "node:crypto"
import { chatIdReservations, type DbChat } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { getEffectiveChatAccessUserIds, lockChatAndAncestors } from "@in/server/modules/authorization/chatAccessProjection"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { eq } from "drizzle-orm"

/** Hash normalized public create inputs, never mutable chat state or provider defaults. */
export function chatCreationIntentHash(intent: object): string {
  return createHash("sha256").update(JSON.stringify(intent)).digest("hex")
}

/** The reservation row serializes a first claim and every later retry. */
export async function lockChatCreationReservation(
  tx: Transaction,
  input: { chatId: number; userId: number; intentHash: string },
): Promise<DbChat | undefined> {
  const [reservation] = await tx
    .select()
    .from(chatIdReservations)
    .where(eq(chatIdReservations.chatId, input.chatId))
    .for("update")
    .limit(1)

  if (!reservation || reservation.userId !== input.userId) {
    throw RealtimeRpcError.BadRequest()
  }

  if (reservation.claimedAt !== null) {
    if (reservation.creationIntentHash !== input.intentHash) {
      throw RealtimeRpcError.BadRequest()
    }
    const resolvedChatId = reservation.resolvedChatId ?? input.chatId
    const chat = await lockChatAndAncestors(tx, resolvedChatId, "share")
    if (!chat || (resolvedChatId === input.chatId && chat.createdBy !== input.userId)) {
      // A consumed/deleted reservation cannot create a replacement destination.
      throw RealtimeRpcError.ChatIdInvalid()
    }
    const access = await getEffectiveChatAccessUserIds(tx, [chat.id], { userIds: [input.userId] })
    if (!access.get(chat.id)?.has(input.userId)) {
      throw RealtimeRpcError.ChatIdInvalid()
    }
    return chat
  }

  if (reservation.expiresAt.getTime() <= Date.now()) {
    throw RealtimeRpcError.BadRequest()
  }
  return undefined
}

export async function claimChatCreationReservation(
  tx: Transaction,
  input: { chatId: number; intentHash: string; resolvedChatId?: number },
): Promise<void> {
  await tx
    .update(chatIdReservations)
    .set({ claimedAt: new Date(), creationIntentHash: input.intentHash, resolvedChatId: input.resolvedChatId ?? input.chatId })
    .where(eq(chatIdReservations.chatId, input.chatId))
}

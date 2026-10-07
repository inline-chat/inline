import { and, asc, eq, gt, inArray, lte, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { chats, mcpReactionEvents, type DbReaction } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"

export type ReactionEventData = {
  kind: "reaction" | "reactionDeleted"
  chatId: string
  messageId: string
  userId: string
  emoji: string
}

/** The caller holds the chat lock and mutates state in this same transaction. */
export async function appendReactionEvent(tx: Transaction, reaction: DbReaction, added: boolean): Promise<void> {
  const [head] = await tx.update(chats).set({ mcpReactionSeq: sql`${chats.mcpReactionSeq} + 1` })
    .where(eq(chats.id, reaction.chatId)).returning({ seq: chats.mcpReactionSeq })
  if (!head) throw new Error("Reaction event chat missing")
  const data: ReactionEventData = { kind: added ? "reaction" : "reactionDeleted", chatId: String(reaction.chatId),
    messageId: String(reaction.messageId), userId: String(reaction.userId), emoji: reaction.emoji }
  await tx.insert(mcpReactionEvents).values({ chatId: reaction.chatId, seq: head.seq, occurredAt: new Date(),
    payloadEncrypted: Encryption2.encrypt(Buffer.from(JSON.stringify(data))) })
}

export async function reactionEventPage(chatId: number, startSeq: number, tx: Transaction) {
  // One snapshot covers the owner counter and retained rows, including cleanup.
  const [head] = await tx.select({ seq: chats.mcpReactionSeq }).from(chats).where(eq(chats.id, chatId)).limit(1)
  const rows = await tx.select().from(mcpReactionEvents).where(and(eq(mcpReactionEvents.chatId, chatId), gt(mcpReactionEvents.seq, startSeq)))
    .orderBy(asc(mcpReactionEvents.seq)).limit(100)
  const latestSeq = head?.seq ?? 0
  const through = rows.at(-1)?.seq ?? startSeq
  const gap = rows.some((row, index) => row.seq !== startSeq + index + 1) || (rows.length < 100 && through < latestSeq)
  return { rows, latestSeq, through, gap }
}

export function decryptReactionEvent(payload: Buffer): ReactionEventData {
  const value: unknown = JSON.parse(Encryption2.decryptToString(payload))
  if (!value || typeof value !== "object" || !("kind" in value) || (value.kind !== "reaction" && value.kind !== "reactionDeleted") ||
    !("chatId" in value) || typeof value.chatId !== "string" || !("messageId" in value) || typeof value.messageId !== "string" ||
    !("userId" in value) || typeof value.userId !== "string" || !("emoji" in value) || typeof value.emoji !== "string") {
    throw new Error("Invalid encrypted reaction occurrence")
  }
  return { kind: value.kind, chatId: value.chatId, messageId: value.messageId, userId: value.userId, emoji: value.emoji }
}

/** A bounded batch per worker minute; the counter survives even an empty log. */
export async function purgeExpiredReactionEvents(limit = 1000): Promise<number> {
  return db.transaction(async (tx) => {
    const expired = await tx.select({ chatId: mcpReactionEvents.chatId, seq: mcpReactionEvents.seq }).from(mcpReactionEvents)
      .where(lte(mcpReactionEvents.occurredAt, new Date(Date.now() - 24 * 60 * 60_000)))
      .orderBy(asc(mcpReactionEvents.occurredAt), asc(mcpReactionEvents.chatId), asc(mcpReactionEvents.seq))
      .limit(Math.min(1000, Math.max(1, limit))).for("update", { skipLocked: true })
    if (expired.length === 0) return 0
    await tx.delete(mcpReactionEvents).where(inArray(sql`(${mcpReactionEvents.chatId}, ${mcpReactionEvents.seq})`, expired.map((row) => sql`(${row.chatId}, ${row.seq})`)))
    return expired.length
  })
}

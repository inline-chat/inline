import { and, eq, isNull, or, sql } from "drizzle-orm"
import { db } from ".."
import { chats, reactions, type DbNewReaction } from "../schema"
import type { Transaction } from "../types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { appendReactionEvent } from "./mcpReactionEvents"
import { contentLookup } from "../../modules/encryption/contentEncryption"

export const reactionEmojiHash = (reaction: Pick<DbNewReaction, "chatId" | "messageId" | "userId" | "emoji">) =>
  contentLookup("reaction-emoji", [reaction.chatId, reaction.messageId, reaction.userId], reaction.emoji)

export const ReactionModel = {
  insertReaction: insertReaction,
  getReactions: getReactions,
  deleteReaction: deleteReaction,
}

async function lockReactionChat(tx: Transaction, chatId: number, userId: number) {
  // Chat-first lock ordering serializes add/remove and protects replay commit order.
  const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
  if (!chat) throw RealtimeRpcError.PeerIdInvalid()
  await AccessGuards.ensureChatAccess(chat, userId, tx)
}

async function insertReaction(reaction: DbNewReaction) {
  const emojiHash = reactionEmojiHash(reaction)
  return db.transaction(async (tx) => {
    await lockReactionChat(tx, reaction.chatId, reaction.userId)
    // Index a matching old row before insertion, including during mixed-format backfill.
    // Its row lock plus the new unique constraint preserve concurrent duplicate handling.
    await tx.update(reactions).set({ emojiHash }).where(and(
      eq(reactions.chatId, reaction.chatId), eq(reactions.messageId, reaction.messageId),
      eq(reactions.userId, reaction.userId), isNull(reactions.emojiHash),
      sql`${reactions.emoji} = ${reaction.emoji}`,
    ))
    const [inserted] = await tx.insert(reactions).values({ ...reaction, emojiHash }).onConflictDoNothing().returning()
    if (inserted) await appendReactionEvent(tx, inserted, true)
    return inserted
  })
}

async function getReactions(messageId: bigint, chatId: bigint) {
  return await db
    .select()
    .from(reactions)
    .where(and(eq(reactions.messageId, Number(messageId)), eq(reactions.chatId, Number(chatId))))
}

async function deleteReaction(messageId: bigint, chatId: number, emoji: string, currentUserId: number) {
  return db.transaction(async (tx) => {
    await lockReactionChat(tx, chatId, currentUserId)
    const result = await tx
      .delete(reactions)
      .where(
        and(
          eq(reactions.messageId, Number(messageId)),
          eq(reactions.chatId, chatId),
          or(
            eq(reactions.emojiHash, reactionEmojiHash({ chatId, messageId: Number(messageId), userId: currentUserId, emoji })),
            and(isNull(reactions.emojiHash), sql`${reactions.emoji} = ${emoji}`),
          ),
          eq(reactions.userId, currentUserId),
        ),
      )
      .returning()

    if (result[0]) await appendReactionEvent(tx, result[0], false)
    return result
  })
}

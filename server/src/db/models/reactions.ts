import { and, eq, isNull, or, sql } from "drizzle-orm"
import { db } from ".."
import { reactions, type DbNewReaction } from "../schema"
import { contentLookup } from "../../modules/encryption/contentEncryption"

export const reactionEmojiHash = (reaction: Pick<DbNewReaction, "chatId" | "messageId" | "userId" | "emoji">) =>
  contentLookup("reaction-emoji", [reaction.chatId, reaction.messageId, reaction.userId], reaction.emoji)

export const ReactionModel = {
  insertReaction: insertReaction,
  getReactions: getReactions,
  deleteReaction: deleteReaction,
}

async function insertReaction(reaction: DbNewReaction) {
  const emojiHash = reactionEmojiHash(reaction)
  return db.transaction(async (tx) => {
    // Index a matching old row before insertion, including during mixed-format backfill.
    // Its row lock plus the new unique constraint preserve concurrent duplicate handling.
    await tx.update(reactions).set({ emojiHash }).where(and(
      eq(reactions.chatId, reaction.chatId), eq(reactions.messageId, reaction.messageId),
      eq(reactions.userId, reaction.userId), isNull(reactions.emojiHash),
      sql`${reactions.emoji} = ${reaction.emoji}`,
    ))
    const [inserted] = await tx.insert(reactions).values({ ...reaction, emojiHash }).onConflictDoNothing().returning()
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
  const result = await db
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

  return result
}

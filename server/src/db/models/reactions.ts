import { and, eq } from "drizzle-orm"
import { db } from ".."
import { reactions, type DbNewReaction, type DbReaction } from "../schema"

export const ReactionModel = {
  insertReaction: insertReaction,
  getReactions: getReactions,
  deleteReaction: deleteReaction,
}

async function insertReaction(reaction: DbNewReaction) {
  const result = await db.insert(reactions).values(reaction).returning()
  return result[0]
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
        eq(reactions.emoji, emoji),
        eq(reactions.userId, currentUserId),
      ),
    )
    .returning()

  return result
}

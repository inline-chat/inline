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
  console.log("result", result)
  return result[0]
}

async function getReactions(messageId: bigint, chatId: bigint) {
  return await db
    .select()
    .from(reactions)
    .where(and(eq(reactions.messageId, Number(messageId)), eq(reactions.chatId, Number(chatId))))
}

async function deleteReaction(messageId: bigint, chatId: bigint, reactionId: bigint) {
  await db
    .delete(reactions)
    .where(
      and(
        eq(reactions.messageId, Number(messageId)),
        eq(reactions.chatId, Number(chatId)),
        eq(reactions.id, Number(reactionId)),
      ),
    )
}

import { and, eq } from "drizzle-orm"
import { db } from ".."
import { chats, reactions, type DbNewReaction, type DbReaction } from "../schema"
import { UpdateBucket } from "../schema/updates"
import { UpdatesModel, type UpdateSeqAndDate } from "./updates"
import type { Transaction } from "../types"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export const ReactionModel = {
  insertReaction: insertReaction,
  insertReactionWithUpdate,
  getReactions: getReactions,
  deleteReaction: deleteReaction,
  deleteReactionWithUpdate,
}

export type ReactionMutation = {
  reaction: DbReaction
  update: UpdateSeqAndDate
}

async function insertReaction(reaction: DbNewReaction) {
  const result = await db
    .insert(reactions)
    .values(reaction)
    .onConflictDoNothing({
      target: [reactions.chatId, reactions.messageId, reactions.userId, reactions.emoji],
    })
    .returning()
  return result[0]
}

/** Persist a reaction and its chat-bucket update under one chat-row lock. */
async function insertReactionWithUpdate(reaction: DbNewReaction): Promise<ReactionMutation | undefined> {
  return db.transaction(async (tx) => {
    const chat = await lockChat(tx, reaction.chatId)
    const [inserted] = await tx
      .insert(reactions)
      .values(reaction)
      .onConflictDoNothing({
        target: [reactions.chatId, reactions.messageId, reactions.userId, reactions.emoji],
      })
      .returning()

    if (!inserted) {
      return undefined
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "reaction",
        reaction: {
          reaction: {
            emoji: inserted.emoji,
            userId: BigInt(inserted.userId),
            messageId: BigInt(inserted.messageId),
            chatId: BigInt(inserted.chatId),
            date: encodeDateStrict(inserted.date),
          },
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    await updateChatSequence(tx, chat.id, update)
    return { reaction: inserted, update }
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
        eq(reactions.emoji, emoji),
        eq(reactions.userId, currentUserId),
      ),
    )
    .returning()

  return result
}

/** Delete a reaction and its chat-bucket update under one chat-row lock. */
async function deleteReactionWithUpdate(
  messageId: bigint,
  chatId: number,
  emoji: string,
  currentUserId: number,
): Promise<ReactionMutation | undefined> {
  return db.transaction(async (tx) => {
    const chat = await lockChat(tx, chatId)
    const [deleted] = await tx
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

    if (!deleted) {
      return undefined
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "reactionDeleted",
        reactionDeleted: {
          emoji: deleted.emoji,
          chatId: BigInt(deleted.chatId),
          messageId: BigInt(deleted.messageId),
          userId: BigInt(deleted.userId),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    await updateChatSequence(tx, chat.id, update)
    return { reaction: deleted, update }
  })
}

async function lockChat(tx: Transaction, chatId: number): Promise<typeof chats.$inferSelect> {
  const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
  if (!chat) {
    throw new Error(`Chat not found: ${chatId}`)
  }
  return chat
}

async function updateChatSequence(tx: Transaction, chatId: number, update: UpdateSeqAndDate): Promise<void> {
  await tx
    .update(chats)
    .set({ updateSeq: update.seq, lastUpdateDate: update.date })
    .where(eq(chats.id, chatId))
}

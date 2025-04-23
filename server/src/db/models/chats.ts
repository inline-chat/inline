import { db } from "@in/server/db"
import { eq, and, desc, type ExtractTablesWithRelations } from "drizzle-orm"
import { chats, messages, type DbChat } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { TPeerInfo } from "@in/server/api-types"
import { ModelError } from "@in/server/db/models/_errors"
import type { InputPeer } from "@in/protocol/core"
import { Log } from "@in/server/utils/log"
import type { PgTransaction } from "drizzle-orm/pg-core"
import type { PostgresJsQueryResultHKT } from "drizzle-orm/postgres-js"

export const ChatModel = {
  getChatFromPeer: getChatFromPeer,
  getLastMessageId: getLastMessageId,
  refreshLastMessageId: refreshLastMessageId,
  refreshLastMessageIdTransaction: refreshLastMessageIdTransaction,
  getChatIdFromInputPeer: getChatIdFromInputPeer,
  getChatFromInputPeer: getChatFromInputPeer,
}

async function getChatIdFromInputPeer(peer: InputPeer, context: { currentUserId: number }): Promise<number> {
  switch (peer.type.oneofKind) {
    case "user":
      let userId = peer.type.user.userId

      // For self-chat, both minUserId and maxUserId will be currentUserId
      const minUserId = Math.min(context.currentUserId, Number(userId))
      const maxUserId = Math.max(context.currentUserId, Number(userId))

      let chat = await db
        .select({ id: chats.id })
        .from(chats)
        .where(and(eq(chats.type, "private"), eq(chats.minUserId, minUserId), eq(chats.maxUserId, maxUserId)))
        .then((result) => result[0])

      if (!chat) {
        throw ModelError.ChatInvalid
      }

      return chat.id

    case "chat":
      let chatId = peer.type.chat.chatId
      return Number(chatId)

    case "self":
      return getChatIdFromInputPeer(
        { type: { oneofKind: "user", user: { userId: BigInt(context.currentUserId) } } },
        context,
      )
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

async function getChatFromInputPeer(peer: InputPeer, context: { currentUserId: number }): Promise<DbChat> {
  switch (peer.type.oneofKind) {
    case "user": {
      let userId = peer.type.user.userId

      // For self-chat, both minUserId and maxUserId will be currentUserId
      const minUserId = Math.min(context.currentUserId, Number(userId))
      const maxUserId = Math.max(context.currentUserId, Number(userId))

      let chat = await db
        .select()
        .from(chats)
        .where(and(eq(chats.type, "private"), eq(chats.minUserId, minUserId), eq(chats.maxUserId, maxUserId)))
        .then((result) => result[0])

      if (!chat) {
        throw ModelError.ChatInvalid
      }

      return chat
    }

    case "chat": {
      let chatId = peer.type.chat.chatId
      let chat = await db
        .select()
        .from(chats)
        .where(eq(chats.id, Number(chatId)))
        .then((result) => result[0])
      if (!chat) {
        throw ModelError.ChatInvalid
      }
      return chat
    }

    case "self": {
      return getChatFromInputPeer(
        { type: { oneofKind: "user", user: { userId: BigInt(context.currentUserId) } } },
        context,
      )
    }
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

export async function getChatFromPeer(peer: TPeerInfo, context: { currentUserId: number }): Promise<DbChat> {
  if ("userId" in peer) {
    const userId = peer.userId
    if (!userId || isNaN(userId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    // For self-chat, both minUserId and maxUserId will be currentUserId
    const minUserId = Math.min(context.currentUserId, userId)
    const maxUserId = Math.max(context.currentUserId, userId)

    let chat = await db
      .select()
      .from(chats)
      .where(and(eq(chats.type, "private"), eq(chats.minUserId, minUserId), eq(chats.maxUserId, maxUserId)))
      .then((result) => result[0])

    if (!chat) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    return chat
  } else if ("threadId" in peer) {
    const threadId = peer.threadId
    if (!threadId || isNaN(threadId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    let chat = await db
      .select()
      .from(chats)
      .where(eq(chats.id, threadId))
      .then((result) => result[0])

    if (!chat) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    return chat
  }

  throw new InlineError(InlineError.ApiError.PEER_INVALID)
}

// todo: optimize to only select lastMsgId
export async function getLastMessageId(
  peer: TPeerInfo,
  context: { currentUserId: number },
): Promise<number | undefined> {
  let chat = await getChatFromPeer(peer, context)
  return chat.lastMsgId ?? undefined
}

/** Updates lastMsgId for a chat by selecting the highest messageId */
async function refreshLastMessageId(chatId: number) {
  // Use a transaction with FOR UPDATE to lock the row while we're working with it
  return await db.transaction(async (tx) => {
    let [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update")
    if (!chat) {
      throw ModelError.ChatInvalid
    }

    let [message] = await tx
      .select()
      .from(messages)
      .where(eq(messages.chatId, chatId))
      .orderBy(desc(messages.messageId))
      .limit(1)

    const newLastMsgId = message?.messageId ?? null
    await tx.update(chats).set({ lastMsgId: newLastMsgId }).where(eq(chats.id, chatId))

    return newLastMsgId
  })
}

/** Updates lastMsgId for a chat by selecting the highest messageId */
async function refreshLastMessageIdTransaction(chatId: number, transaction: (tx: DrizzleTx) => Promise<void>) {
  // Use a transaction with FOR UPDATE to lock the row while we're working with it
  return await db.transaction(async (tx) => {
    let [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update")
    if (!chat) {
      throw ModelError.ChatInvalid
    }

    // clear first
    await tx.update(chats).set({ lastMsgId: null }).where(eq(chats.id, chatId))

    await transaction(tx)

    let [message] = await tx
      .select()
      .from(messages)
      .where(eq(messages.chatId, chatId))
      .orderBy(desc(messages.messageId))
      .limit(1)

    const newLastMsgId = message?.messageId ?? null
    await tx.update(chats).set({ lastMsgId: newLastMsgId }).where(eq(chats.id, chatId))

    return newLastMsgId
  })
}

type DrizzleTx = PgTransaction<
  PostgresJsQueryResultHKT,
  typeof import("../schema/index"),
  ExtractTablesWithRelations<typeof import("../schema/index")>
>

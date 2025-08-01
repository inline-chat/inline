import { db } from "@in/server/db"
import { eq, and, desc } from "drizzle-orm"
import { type ExtractTablesWithRelations } from "drizzle-orm/_relations"
import { chats, dialogs, messages, type DbChat, type DbDialog } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { TPeerInfo } from "@in/server/api-types"
import { ModelError } from "@in/server/db/models/_errors"
import type { InputPeer } from "@in/protocol/core"
import { Log } from "@in/server/utils/log"
import type { PgTransaction } from "drizzle-orm/pg-core"
import type { PostgresJsQueryResultHKT } from "drizzle-orm/postgres-js"

const log = new Log("chats")

export const ChatModel = {
  getChatFromPeer: getChatFromPeer,
  getLastMessageId: getLastMessageId,
  refreshLastMessageId: refreshLastMessageId,
  refreshLastMessageIdTransaction: refreshLastMessageIdTransaction,
  getChatIdFromInputPeer: getChatIdFromInputPeer,
  getChatFromInputPeer: getChatFromInputPeer,
  createUserChatAndDialog: createUserChatAndDialog,
  getUserChats,
}

/**
 * Creates a chat and dialog for a target user
 *
 * @param input - The input
 * @returns The chat and dialog
 */
async function createUserChatAndDialog(input: {
  peerUserId: number
  currentUserId: number
}): Promise<{ chat: DbChat; dialog: DbDialog }> {
  let minUserId = Math.min(input.peerUserId, input.currentUserId)
  let maxUserId = Math.max(input.peerUserId, input.currentUserId)

  const result = await db.transaction(async (tx) => {
    let chat: DbChat | undefined

    // Check if already a chat, fetch it
    chat = await tx._query.chats.findFirst({
      where: and(eq(chats.type, "private"), eq(chats.minUserId, minUserId), eq(chats.maxUserId, maxUserId)),
    })

    if (!chat) {
      // Create chat
      ;[chat] = await tx
        .insert(chats)
        .values({
          type: "private",
          minUserId,
          maxUserId,
        })
        .returning()
    }

    if (!chat) {
      log.error("Failed to create chat", { input })
      throw ModelError.Failed
    }

    // check if dialog already exists
    let dialog = await tx._query.dialogs.findFirst({
      where: and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, input.currentUserId)),
    })

    if (!dialog) {
      ;[dialog] = await tx
        .insert(dialogs)
        .values({
          chatId: chat.id,
          userId: input.currentUserId,
          peerUserId: input.peerUserId,
        })
        .returning()
    }

    if (!dialog) {
      log.error("Failed to create dialog", { input })
      throw ModelError.Failed
    }

    return { chat, dialog }
  })

  return result
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
async function refreshLastMessageIdTransaction(chatId: number, transaction: (tx: any) => Promise<void>) {
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

// type DrizzleTx = PgTransaction<
//   PostgresJsQueryResultHKT,
//   typeof import("../schema/index"),
//   ExtractTablesWithRelations<typeof import("../schema/index")>
// >

type GetUserChatsInput = {
  userId: number
  where?: {
    lastUpdateAtGreaterThanEqual: Date
  }
}

type GetUserChatsOutput = {
  chats: DbChat[]
}

export async function getUserChats(input: GetUserChatsInput): Promise<GetUserChatsOutput> {
  let { userId, where } = input

  // Fetch a list of public threads the user is a part of and don't have a dialog
  const chats = await db.query.chats.findMany({
    where: {
      ...(where && "lastUpdateAtGreaterThanEqual" in where
        ? {
            lastUpdateDate: {
              gte: where.lastUpdateAtGreaterThanEqual,
            },
          }
        : {}),

      OR: [
        // DMs
        {
          type: "private",
          // that are between this user and another user
          OR: [
            {
              minUserId: userId,
            },
            {
              maxUserId: userId,
            },
          ],
        },

        // Public threads
        {
          type: "thread",
          publicThread: true,
          // that we are a participant in
          space: {
            deleted: {
              isNull: true,
            },
            members: {
              userId,
            },
          },
        },

        // Private threads
        {
          type: "thread",
          publicThread: false,
          // that we are a participant in
          participants: {
            userId,
          },
          // extra safety check until we clean up our database so if it's removed from space we remove from participants
          space: {
            deleted: {
              isNull: true,
            },
            members: {
              userId,
            },
          },
        },
      ],
    },
  })

  return { chats }
}

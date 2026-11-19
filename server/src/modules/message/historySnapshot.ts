import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { ModelError } from "@in/server/db/models/_errors"
import { UsersModel } from "@in/server/db/models/users"
import { chats, type DbChat } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { ensureCanMessageBot } from "@in/server/modules/agents/access"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { InputPeer } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"

// Message identities are PostgreSQL integers. Validate before bigint -> number.
export const MAX_HISTORY_ID = 2_147_483_647n
// The wire limit is int32; anything outside it is malformed and rejected.
export const MAX_HISTORY_LIMIT = 2_147_483_647
// Larger in-range pages are clamped, not rejected. It stays above 501 so CLI
// `--limit 500` plus the Rust client's one-row lookahead is never truncated.
export const MAX_HISTORY_PAGE = 1_000

export function validateHistoryId(id: bigint | undefined): void {
  if (id !== undefined && (id <= 0n || id > MAX_HISTORY_ID)) {
    throw RealtimeRpcError.BadRequest()
  }
}

export function historyLimit(value: number | undefined, fallback: number, allowZero = false): number {
  const limit = value ?? fallback
  if (!Number.isInteger(limit) || limit < (allowZero ? 0 : 1) || limit > MAX_HISTORY_LIMIT) {
    throw RealtimeRpcError.BadRequest()
  }
  return Math.min(limit, MAX_HISTORY_PAGE)
}

export function validateHistoryPeer(peer: InputPeer): void {
  switch (peer.type.oneofKind) {
    case "chat":
      validateHistoryId(peer.type.chat.chatId)
      return
    case "user":
      validateHistoryId(peer.type.user.userId)
      return
    case "self":
      return
    default:
      throw RealtimeRpcError.PeerIdInvalid()
  }
}

/** Creation is outside the read transaction; all response state is read inside it. */
export async function withHistorySnapshot<T>(
  peer: InputPeer,
  currentUserId: number,
  read: (tx: Transaction, chat: DbChat) => Promise<T>,
): Promise<T> {
  validateHistoryPeer(peer)
  let chatId: number
  if (peer.type.oneofKind === "chat") {
    // The validated ID is enough to enter the snapshot. Read the chat and
    // authorize it there rather than loading the same row twice.
    chatId = Number(peer.type.chat.chatId)
  } else {
    let chat: DbChat
    try {
      chat = await ChatModel.getChatFromInputPeerUnchecked(peer, { currentUserId })
    } catch (error) {
      if (!(error instanceof ModelError && error.code === ModelError.Codes.CHAT_INVALID)) throw error
      if (peer.type.oneofKind !== "user" && peer.type.oneofKind !== "self") {
        throw RealtimeRpcError.ChatIdInvalid()
      }
      const peerUserId = peer.type.oneofKind === "self" ? currentUserId : Number(peer.type.user.userId)
      const user = await UsersModel.getUserById(peerUserId)
      if (!user || UsersModel.isDeleted(user)) throw RealtimeRpcError.UserIdInvalid()
      await ensureCanMessageBot(user, currentUserId)
      await ChatModel.createUserChatAndDialog({ peerUserId, currentUserId })
      await ChatModel.createUserChatAndDialog({ peerUserId: currentUserId, currentUserId: peerUserId })
      chat = await ChatModel.getChatFromInputPeerUnchecked(peer, { currentUserId })
    }
    chatId = chat.id
  }
  return withHistoryReadSnapshot(async (tx) => {
    const [snapshotChat] = await tx.select().from(chats).where(eq(chats.id, chatId)).limit(1)
    if (!snapshotChat) throw RealtimeRpcError.ChatIdInvalid()
    await AccessGuards.ensureChatReadAccess(snapshotChat, currentUserId, tx)
    return read(tx, snapshotChat)
  })
}

/** Multi-chat catalog reads share the same coherence boundary as history pages. */
export function withHistoryReadSnapshot<T>(read: (tx: Transaction) => Promise<T>): Promise<T> {
  return db.transaction(read, { isolationLevel: "repeatable read", accessMode: "read only" })
}

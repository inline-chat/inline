import { db } from "@in/server/db"
import { chats, messages, users, type DbChat, type DbMessage } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { TPeerInfo } from "@in/server/api-types"
import { and, eq } from "drizzle-orm"

export interface ProviderActionContext {
  readonly chat: DbChat
  readonly message: DbMessage
  readonly peerId: TPeerInfo
  readonly spaceId: number
}

export async function resolveProviderActionContext(input: {
  chatId: number
  messageId: number
  currentUserId: number
  claimedSpaceId?: number | undefined
}): Promise<ProviderActionContext> {
  await rejectBotConnectorAccess(input.currentUserId)
  const [chat] = await db
    .select()
    .from(chats)
    .where(eq(chats.id, input.chatId))
    .limit(1)
  if (!chat) throw RealtimeRpcError.PeerIdInvalid()
  await AccessGuards.ensureChatAccess(chat, input.currentUserId)

  const spaceId = chat.spaceId ?? input.claimedSpaceId
  if (!spaceId) throw RealtimeRpcError.SpaceIdInvalid()
  if (chat.spaceId !== null && input.claimedSpaceId !== undefined && input.claimedSpaceId !== chat.spaceId) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }
  if (chat.spaceId === null) {
    await AccessGuards.ensureSpaceMember(spaceId, input.currentUserId)
  }

  const [message] = await db
    .select()
    .from(messages)
    .where(and(
      eq(messages.chatId, chat.id),
      eq(messages.messageId, input.messageId),
    ))
    .limit(1)
  if (!message) throw RealtimeRpcError.MessageIdInvalid()

  const peerId: TPeerInfo = chat.type === "private"
    ? {
        userId: chat.minUserId === input.currentUserId
          ? chat.maxUserId!
          : chat.minUserId!,
      }
    : { threadId: chat.id }
  return { chat, message, peerId, spaceId }
}

export async function rejectBotConnectorAccess(userId: number): Promise<void> {
  const [user] = await db
    .select({ bot: users.bot })
    .from(users)
    .where(eq(users.id, userId))
    .limit(1)
  if (!user || user.bot) throw RealtimeRpcError.UserIdInvalid()
}

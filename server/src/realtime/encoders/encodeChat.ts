import { Chat, Peer, type ChatPermissions } from "@inline-chat/protocol/core"
import type { DbChat } from "@in/server/db/schema"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log } from "@in/server/utils/log"
import {
  resolveChatPermissions,
  resolveChatPermissionsBatch,
  resolveChatPermissionsForUsers,
} from "@in/server/modules/authorization/chatPermissions"

type EncodeChatOptions = {
  encodingForUserId: number
  permissions?: ChatPermissions
}

export function encodeChat(chat: DbChat, { encodingForUserId, permissions }: EncodeChatOptions): Chat {
  let peerId: Peer | undefined

  if (chat.type === "private") {
    const userId = chat.minUserId == encodingForUserId ? chat.maxUserId : chat.minUserId

    if (!userId) {
      Log.shared.error("User ID is required for private chat", { chatId: chat.id })
      throw new Error("User ID is required")
    }

    peerId = {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(userId) },
      },
    }
  } else if (chat.type === "thread") {
    peerId = {
      type: {
        oneofKind: "chat",
        chat: { chatId: BigInt(chat.id) },
      },
    }
  }

  return {
    id: BigInt(chat.id),
    title: chat.title ?? "",
    spaceId: chat.spaceId ? BigInt(chat.spaceId) : undefined,
    description: chat.description ?? undefined,

    emoji: chat.emoji ?? undefined,
    isPublic: chat.publicThread ?? false,
    lastMsgId: chat.lastMsgId ? BigInt(chat.lastMsgId) : undefined,
    peerId: peerId,
    date: encodeDateStrict(chat.date),
    createdBy: chat.createdBy ? BigInt(chat.createdBy) : undefined,
    parentChatId: chat.parentChatId ? BigInt(chat.parentChatId) : undefined,
    parentMessageId: chat.parentMessageId ? BigInt(chat.parentMessageId) : undefined,
    untitled: chat.isUntitled === true ? true : undefined,
    number: chat.threadNumber ?? undefined,
    permissions,
  }
}

export async function encodeChatForUser(chat: DbChat, options: { encodingForUserId: number }): Promise<Chat> {
  const permissions = await resolveChatPermissions(chat, options.encodingForUserId)
  return encodeChat(chat, { ...options, permissions })
}

export async function encodeChatsForUser(
  chats: DbChat[],
  options: { encodingForUserId: number },
): Promise<Chat[]> {
  const permissionsByChatId = await resolveChatPermissionsBatch(chats, options.encodingForUserId)
  return chats.map((chat) =>
    encodeChat(chat, {
      ...options,
      permissions: permissionsByChatId.get(chat.id) ?? { canUpdateInfo: false },
    }),
  )
}

export async function encodeChatForUsers(chat: DbChat, userIds: number[]): Promise<Map<number, Chat>> {
  const permissionsByUserId = await resolveChatPermissionsForUsers([chat], userIds)
  return new Map(
    userIds.map((userId) => [
      userId,
      encodeChat(chat, {
        encodingForUserId: userId,
        permissions: permissionsByUserId.get(userId)?.get(chat.id) ?? { canUpdateInfo: false },
      }),
    ]),
  )
}

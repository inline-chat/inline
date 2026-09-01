import { getChatAcknowledgements } from "@in/server/db/models/acknowledgements"
import { Chat, Peer, type ChatPermissions } from "@inline-chat/protocol/core"
import type { DbChat } from "@in/server/db/schema"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log } from "@in/server/utils/log"
import {
  resolveChatPermissions,
  resolveChatPermissionsBatch,
  resolveChatPermissionsForUsers,
} from "@in/server/modules/authorization/chatPermissions"
import type { Transaction } from "@in/server/db/types"

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
    seq: chat.updateSeq ?? undefined,
  }
}

export async function encodeChatForUser(
  chat: DbChat,
  options: { encodingForUserId: number; tx?: Transaction },
): Promise<Chat> {
  const permissions = await resolveChatPermissions(chat, options.encodingForUserId, options.tx)
  const acknowledgements = await getChatAcknowledgements([chat.id], { tx: options.tx })
  return {
    ...encodeChat(chat, { encodingForUserId: options.encodingForUserId, permissions }),
    acknowledgements: { cursors: acknowledgements.get(chat.id) ?? [] },
  }
}

export async function encodeChatsForUser(
  chats: DbChat[],
  options: { encodingForUserId: number },
): Promise<Chat[]> {
  const permissionsByChatId = await resolveChatPermissionsBatch(chats, options.encodingForUserId)
  const acknowledgements = await getChatAcknowledgements(chats.map(chat => chat.id))
  return chats.map((chat) =>
    ({ ...encodeChat(chat, {
      ...options,
      permissions: permissionsByChatId.get(chat.id) ?? { canUpdateInfo: false },
    }), acknowledgements: { cursors: acknowledgements.get(chat.id) ?? [] } }),
  )
}

export async function encodeChatForUsers(chat: DbChat, userIds: number[]): Promise<Map<number, Chat>> {
  const permissionsByUserId = await resolveChatPermissionsForUsers([chat], userIds)
  const acknowledgements = { cursors: (await getChatAcknowledgements([chat.id])).get(chat.id) ?? [] }
  return new Map(
    userIds.map((userId) => [
      userId,
      { ...encodeChat(chat, {
        encodingForUserId: userId,
        permissions: permissionsByUserId.get(userId)?.get(chat.id) ?? { canUpdateInfo: false },
      }), acknowledgements },
    ]),
  )
}

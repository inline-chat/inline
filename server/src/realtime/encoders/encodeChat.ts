import { Chat, Peer } from "@inline-chat/protocol/core"
import type { DbChat } from "@in/server/db/schema"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log } from "@in/server/utils/log"

export function encodeChat(chat: DbChat, { encodingForUserId }: { encodingForUserId: number }): Chat {
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
  }
}

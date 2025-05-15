import { Chat, Dialog, Peer, PeerChat } from "@in/protocol/core"
import type { chats, DbChat } from "@in/server/db/schema"
import { encodePeer } from "@in/server/realtime/encoders/encodePeer"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { Log } from "@in/server/utils/log"
import type { InferSelectModel } from "drizzle-orm"

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
  }
}

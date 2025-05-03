import { Chat, Dialog, Peer, PeerChat } from "@in/protocol/core"
import type { chats, DbChat } from "@in/server/db/schema"
import type { InferSelectModel } from "drizzle-orm"

export function encodeChat(chat: DbChat): Chat {
  return {
    id: BigInt(chat.id),
    title: chat.title ?? "",
    spaceId: chat.spaceId ? BigInt(chat.spaceId) : undefined,
    description: chat.description ?? undefined,
    emoji: chat.emoji ?? undefined,
    isPublic: chat.publicThread ?? false,
    lastMsgId: chat.lastMsgId ? BigInt(chat.lastMsgId) : undefined,
  }
}

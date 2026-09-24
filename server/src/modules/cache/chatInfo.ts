import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { LocalCache } from "./localCache"

export type CachedChatInfo = {
  type: "thread" | "private"
  public: boolean
  title: string | null
  spaceId: number | null
  participantUserIds: number[]
  // ---
  cacheDate: number
}

// Recipient IDs share this projection, so use the short authority-adjacent TTL.
const cachedChatInfo = new LocalCache<number, CachedChatInfo | undefined>({
  ttlMs: 15_000, negativeTtlMs: 5_000, maxEntries: 10_000,
  isNegative: (value) => value === undefined,
})

export function clearChatInfoCache() {
  cachedChatInfo.clear()
}

export function invalidateChatInfoCache(chatId: number) {
  cachedChatInfo.invalidate(chatId)
}

export async function getCachedChatInfo(chatId: number): Promise<CachedChatInfo | undefined> {
  return cachedChatInfo.get(chatId, async () => {
  const chat = await db.query.chats.findFirst({
    where: {
      id: chatId,
    },
    with: {
      participants: {
        columns: {
          userId: true,
        },
      },
    },
  })

  if (!chat) {
    return
  }

  let participantUserIds: number[] = []
  if (chat.type === "thread" && chat.publicThread && chat.spaceId) {
    let spaceInfo = await getCachedSpaceInfo(chat.spaceId)
    participantUserIds = spaceInfo?.memberUserIds ?? []
  } else if (chat.type === "thread" && !chat.publicThread) {
    participantUserIds = await UsersModel.getActiveUserIds(chat.participants.map((p) => p.userId))
  } else if (chat.minUserId && chat.maxUserId) {
    participantUserIds = await UsersModel.getActiveUserIds([chat.minUserId, chat.maxUserId])
  }

  const chatInfo: CachedChatInfo = {
    title: chat.title,
    public: chat.publicThread ?? false,
    spaceId: chat.spaceId,
    type: chat.type,
    participantUserIds,
    cacheDate: Date.now(),
  }

  return chatInfo
  })
}

import { db } from "@in/server/db"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"

export type CachedChatInfo = {
  type: "thread" | "private"
  public: boolean
  title: string | null
  spaceId: number | null
  participantUserIds: number[]
  // ---
  cacheDate: number
}

const cachedChatInfo = new Map<number, CachedChatInfo>()
const cacheValidTime = 10 * 60 * 1000 // 10 minutes
const maxCacheSize = 10000 // 10k chats

export function clearChatInfoCache() {
  cachedChatInfo.clear()
}

export async function getCachedChatInfo(chatId: number): Promise<CachedChatInfo | undefined> {
  let cached = cachedChatInfo.get(chatId)
  if (cached) {
    if (cached.cacheDate + cacheValidTime > Date.now()) {
      return cached
    }
  }

  if (cachedChatInfo.size >= maxCacheSize) {
    cachedChatInfo.clear()
  }

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
    participantUserIds = chat.participants.map((p) => p.userId)
  } else if (chat.minUserId && chat.maxUserId) {
    participantUserIds = [chat.minUserId, chat.maxUserId]
  }

  const chatInfo: CachedChatInfo = {
    title: chat.title,
    public: chat.publicThread ?? false,
    spaceId: chat.spaceId,
    type: chat.type,
    participantUserIds,
    cacheDate: Date.now(),
  }

  cachedChatInfo.set(chatId, chatInfo)

  return chatInfo
}

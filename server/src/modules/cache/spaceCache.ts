import { db } from "@in/server/db"

export type CachedSpaceInfo = {
  id: number
  name: string | null
  memberUserIds: number[]
  // ---
  cacheDate: number
}

const cachedSpaceInfo = new Map<number, CachedSpaceInfo>()
const cacheValidTime = 10 * 60 * 1000 // 10 minutes
const maxCacheSize = 10000 // 10k chats

export async function getCachedSpaceInfo(spaceId: number): Promise<CachedSpaceInfo | undefined> {
  let cached = cachedSpaceInfo.get(spaceId)
  if (cached) {
    if (cached.cacheDate + cacheValidTime > Date.now()) {
      return cached
    }
  }

  if (cachedSpaceInfo.size >= maxCacheSize) {
    cachedSpaceInfo.clear()
  }

  const space = await db.query.spaces.findFirst({
    where: {
      id: spaceId,
    },
    with: {
      members: {
        columns: {
          userId: true,
        },
      },
    },
  })

  if (!space) {
    return
  }

  let memberUserIds = space.members.map((m) => m.userId)

  const spaceInfo: CachedSpaceInfo = {
    id: space.id,
    name: space.name,
    memberUserIds,
    cacheDate: Date.now(),
  }

  cachedSpaceInfo.set(spaceId, spaceInfo)

  return spaceInfo
}

export const clearSpaceCache = () => {
  cachedSpaceInfo.clear()
}

import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import { LocalCache } from "./localCache"

export type CachedSpaceInfo = {
  id: number
  name: string | null
  memberUserIds: number[]
  // ---
  cacheDate: number
}

const cachedSpaceInfo = new LocalCache<number, CachedSpaceInfo | undefined>({
  ttlMs: 15_000, negativeTtlMs: 5_000, maxEntries: 10_000,
  isNegative: (value) => value === undefined,
})

export const invalidateSpaceCache = (spaceId: number): void => cachedSpaceInfo.invalidate(spaceId)

export async function getCachedSpaceInfo(spaceId: number): Promise<CachedSpaceInfo | undefined> {
  return cachedSpaceInfo.get(spaceId, async () => {
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

  let memberUserIds = await UsersModel.getActiveUserIds(space.members.map((m) => m.userId))

  const spaceInfo: CachedSpaceInfo = {
    id: space.id,
    name: space.name,
    memberUserIds,
    cacheDate: Date.now(),
  }

  return spaceInfo
  })
}

export const clearSpaceCache = () => {
  cachedSpaceInfo.clear()
}

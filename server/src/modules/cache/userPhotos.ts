import { UsersModel } from "@in/server/db/models/users"
import { getSignedMediaPhotoUrl } from "@in/server/modules/files/path"
import { Log } from "@in/server/utils/log"
import { LocalCache } from "./localCache"

const log = new Log("cache.userPhotos")

export type UserPhotoCacheEntry = {
  userId: number
  cdnUrl?: string
  hasPhoto: boolean
  cacheDate: number
}

const cachedUserPhotos = new LocalCache<number, UserPhotoCacheEntry | undefined>({
  ttlMs: 240_000, negativeTtlMs: 15_000, maxEntries: 10_000,
  isNegative: (value) => value === undefined,
})
export const invalidateUserPhotoCache = (userId: number): void => cachedUserPhotos.invalidate(userId)
export const clearUserPhotoCache = (): void => cachedUserPhotos.clear()

export async function getCachedUserProfilePhotoUrl(userId: number): Promise<string | undefined> {
  return (await getCachedUserProfilePhoto(userId))?.cdnUrl
}

export async function getCachedUserProfilePhoto(userId: number): Promise<UserPhotoCacheEntry | undefined> {
  return cachedUserPhotos.get(userId, async () => {
  try {
    const user = await UsersModel.getUserWithPhoto(userId)
    if (!user) return undefined
    const photoFile = user?.photo

    let cdnUrl: string | undefined
    if (photoFile) {
      cdnUrl = getSignedMediaPhotoUrl(photoFile) ?? undefined
    }

    const entry = {
      userId,
      cdnUrl,
      hasPhoto: user.photoFileId != null,
      cacheDate: Date.now(),
    }
    return entry
  } catch (error) {
    log.error("Failed to fetch user profile photo", { userId, error })
    return undefined
  }
  })
}

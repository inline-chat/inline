import { UsersModel } from "@in/server/db/models/users"
import { getSignedMediaPhotoUrl } from "@in/server/modules/files/path"
import { Log } from "@in/server/utils/log"

const log = new Log("cache.userPhotos")

export type UserPhotoCacheEntry = {
  userId: number
  cdnUrl?: string
  cacheDate: number
}

const cachedUserPhotos = new Map<number, UserPhotoCacheEntry>()
// Match username cache TTL (240s)
const cacheValidTime = 240 * 1000

export async function getCachedUserProfilePhotoUrl(userId: number): Promise<string | undefined> {
  const cached = cachedUserPhotos.get(userId)
  if (cached && cached.cacheDate + cacheValidTime > Date.now()) {
    return cached.cdnUrl
  }

  try {
    const user = await UsersModel.getUserWithPhoto(userId)
    const photoFile = user?.photo

    let cdnUrl: string | undefined
    if (photoFile) {
      cdnUrl = getSignedMediaPhotoUrl(photoFile.fileUniqueId) ?? undefined
    }

    cachedUserPhotos.set(userId, {
      userId,
      cdnUrl,
      cacheDate: Date.now(),
    })

    return cdnUrl
  } catch (error) {
    log.error("Failed to fetch user profile photo", { userId, error })
    return undefined
  }
}

import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { LocalCache } from "./localCache"

export type UserName = {
  id: number
  firstName: string | null
  lastName: string | null
  username: string | null
  email: string | null
  phone: string | null
  timeZone: string | null
  cacheDate: number
}

const cachedUserNames = new LocalCache<number, UserName | undefined>({
  ttlMs: 120_000, negativeTtlMs: 15_000, maxEntries: 10_000,
  isNegative: (value) => value === undefined,
})
export const invalidateUserNameCache = (userId: number): void => cachedUserNames.invalidate(userId)
export const clearUserNameCache = (): void => cachedUserNames.clear()

export const UserNamesCache = {
  getCachedUserName,
  getDisplayName,
}

export async function getCachedUserName(userId: number): Promise<UserName | undefined> {
  return cachedUserNames.get(userId, async () => {
  const user = await db
    .select()
    .from(users)
    .where(eq(users.id, userId))
    .then(([user]) => user)

  if (!user) {
    return
  }

  const userName: UserName = {
    id: userId,
    firstName: user.firstName,
    lastName: user.lastName,
    username: user.username,
    email: user.emailVerified ? user.email : null,
    phone: user.phoneVerified ? user.phoneNumber : null,
    cacheDate: Date.now(),
    timeZone: user.timeZone,
  }

  return userName
  })
}

/**
 * Get the display name of a user
 * @param userName - The user name cache object
 * @returns The display name
 */
function getDisplayName(userName: UserName): string | null {
  if (userName.firstName) {
    return userName.firstName
  }

  if (userName.lastName) {
    return userName.lastName
  }

  if (userName.username) {
    return userName.username
  }

  if (userName.email) {
    return userName.email
  }

  if (userName.phone) {
    return userName.phone
  }

  return null
}

import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

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

const cachedUserNames = new Map<number, UserName>()
const cacheValidTime = 120 * 1000 // 120s

export const UserNamesCache = {
  getCachedUserName,
  getDisplayName,
}

export async function getCachedUserName(userId: number): Promise<UserName | undefined> {
  let cached = cachedUserNames.get(userId)
  if (cached) {
    if (cached.cacheDate + cacheValidTime > Date.now()) {
      return cached
    }
  }

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

  cachedUserNames.set(userId, userName)

  return userName
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

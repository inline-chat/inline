import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

type UserName = {
  firstName: string | null
  lastName: string | null
  username: string | null
  email: string | null
  cacheDate: number
}

const cachedUserNames = new Map<number, UserName>()
const cacheValidTime = 120 * 1000 // 120s

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
    firstName: user.firstName,
    lastName: user.lastName,
    username: user.username,
    email: user.email,
    cacheDate: Date.now(),
  }

  cachedUserNames.set(userId, userName)

  return userName
}

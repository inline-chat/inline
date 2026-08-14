import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema/sessions"
import { users, type DbUser } from "@in/server/db/schema/users"
import { and, eq, sql } from "drizzle-orm"

export async function syncTimeZoneForElectedAppleSession({
  userId,
  sessionId,
  timeZone,
}: {
  userId: number
  sessionId: number
  timeZone: string
}): Promise<DbUser | undefined> {
  const [user] = await db
    .update(users)
    .set({ timeZone })
    .where(
      and(
        eq(users.id, userId),
        sql`${sessionId} = (
          select max(${sessions.id})
          from ${sessions}
          where ${sessions.userId} = ${userId}
            and ${sessions.revoked} is null
            and ${sessions.clientType} in ('ios', 'macos')
        )`,
      ),
    )
    .returning()

  return user
}

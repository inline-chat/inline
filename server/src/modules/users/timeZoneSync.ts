import { db } from "@in/server/db"
import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { SessionsModel } from "@in/server/db/models/sessions"
import { sessions } from "@in/server/db/schema/sessions"
import { users, type DbUser } from "@in/server/db/schema/users"
import type { Transaction } from "@in/server/db/types"
import { and, desc, eq, inArray, isNull, sql } from "drizzle-orm"

/** Writes a device's time zone unless the user picked one in privacy settings. */
export async function syncTimeZoneForElectedAppleSession({
  userId,
  sessionId,
  timeZone,
}: {
  userId: number
  sessionId: number
  timeZone: string
}): Promise<DbUser | undefined> {
  // The session keeps its own time zone either way, so automatic can restore it.
  const general = await UserSettingsModel.getGeneral(userId)
  if (general?.privacy.manualTimeZone) return undefined

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

/** The time zone last reported by the Apple session that owns automatic time zone writes. */
export async function electedAppleSessionTimeZone(tx: Transaction, userId: number): Promise<string | undefined> {
  const [session] = await tx
    .select()
    .from(sessions)
    .where(and(eq(sessions.userId, userId), isNull(sessions.revoked), inArray(sessions.clientType, ["ios", "macos"])))
    .orderBy(desc(sessions.id))
    .limit(1)
  return session ? SessionsModel.decryptPersonalData(session).timezone || undefined : undefined
}

import { db } from "@in/server/db"
import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { SessionsModel } from "@in/server/db/models/sessions"
import { sessions } from "@in/server/db/schema/sessions"
import { users, type DbUser } from "@in/server/db/schema/users"
import type { Transaction } from "@in/server/db/types"
import { Log } from "@in/server/utils/log"
import { and, eq, gt, inArray, isNull, or } from "drizzle-orm"

const log = new Log("timeZoneSync")

/** A device that has not connected for this long no longer speaks for where the user is. */
export const LIVE_DEVICE_WINDOW_MS = 30 * 24 * 60 * 60 * 1000

/**
 * The user's automatic time zone is derived from their devices, never owned by one session:
 * it is the zone that most recently took effect on a live Apple device.
 *
 * - Sessions are never expired, so only devices seen within `LIVE_DEVICE_WINDOW_MS` (or the one
 *   reporting right now) count. An abandoned install cannot hold the time zone.
 * - A launch that reports an unchanged zone keeps its old `timezoneSince`, so a desk machine at
 *   home cannot flip the user back while their phone travels.
 * - A manual time zone wins until the user returns to automatic.
 *
 * Call it after anything stores a device time zone. It is idempotent and returns the user only
 * when their time zone changed.
 */
export async function recomputeUserTimeZone(
  userId: number,
  { reportingSessionId }: { reportingSessionId?: number } = {},
): Promise<DbUser | undefined> {
  return db.transaction(async (tx) => {
    // Serializes recomputes for this user, so the last one sees every committed report.
    const [user] = await tx.select().from(users).where(eq(users.id, userId)).for("update").limit(1)
    if (!user) return undefined

    const general = (await UserSettingsModel.getGeneralForUsers(tx, [userId])).get(userId)
    if (general?.privacy.manualTimeZone) return undefined

    const device = await latestLiveDeviceTimeZone(tx, userId, { reportingSessionId })
    if (!device || device.timeZone === user.timeZone) return undefined

    const [updated] = await tx.update(users).set({ timeZone: device.timeZone }).where(eq(users.id, userId)).returning()
    log.info("User time zone follows device", { userId, sessionId: device.sessionId })
    return updated
  })
}

/** The zone that most recently took effect on one of the user's live Apple devices. */
export async function latestLiveDeviceTimeZone(
  tx: Transaction,
  userId: number,
  { reportingSessionId, now = new Date() }: { reportingSessionId?: number; now?: Date } = {},
): Promise<{ timeZone: string; sessionId: number } | undefined> {
  const liveSince = new Date(now.getTime() - LIVE_DEVICE_WINDOW_MS)
  const rows = await tx
    .select()
    .from(sessions)
    .where(
      and(
        eq(sessions.userId, userId),
        isNull(sessions.revoked),
        inArray(sessions.clientType, ["ios", "macos"]),
        // The reporting session's lastActive touch is best-effort and may not have landed yet.
        reportingSessionId === undefined
          ? gt(sessions.lastActive, liveSince)
          : or(gt(sessions.lastActive, liveSince), eq(sessions.id, reportingSessionId)),
      ),
    )

  let best: { timeZone: string; sessionId: number; since: number; lastActive: number } | undefined
  for (const row of rows) {
    const personalData = SessionsModel.decryptPersonalData(row)
    const timeZone = personalData.timezone
    if (!timeZone) continue
    // A zone never changed since sign-in dates from the sign-in.
    const candidate = {
      timeZone,
      sessionId: row.id,
      since: personalData.timezoneSince ?? row.date?.getTime() ?? 0,
      lastActive: row.lastActive?.getTime() ?? 0,
    }
    if (
      !best ||
      candidate.since > best.since ||
      (candidate.since === best.since && candidate.lastActive > best.lastActive) ||
      (candidate.since === best.since && candidate.lastActive === best.lastActive && candidate.sessionId > best.sessionId)
    ) {
      best = candidate
    }
  }

  return best && { timeZone: best.timeZone, sessionId: best.sessionId }
}

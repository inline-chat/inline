import type { DbUser } from "@in/server/db/schema"
import { getCachedUserSettings } from "@in/server/modules/cache/userSettings"
import { canSeeWithRule, effectiveTimeZoneRule } from "@in/server/modules/privacy/privacyRules"
import { Log } from "@in/server/utils/log"

const log = new Log("privacy.timeZoneVisibility")

/**
 * Returns the owners whose time zone `viewerId` may see.
 *
 * `users.share_time_zone` is true only for a rule open to everyone with no
 * exceptions, so those owners need no settings read. Other owners are checked
 * against their full rule, and an unreadable rule hides the time zone.
 */
export const resolveTimeZoneVisibility = async (
  viewerId: number,
  owners: Iterable<Pick<DbUser, "id" | "shareTimeZone">>,
): Promise<Set<number>> => {
  const visible = new Set<number>()
  const restricted = new Set<number>()
  for (const owner of owners) {
    if (owner.id === viewerId || owner.shareTimeZone !== false) visible.add(owner.id)
    else restricted.add(owner.id)
  }

  await Promise.all(
    Array.from(restricted, async (ownerId) => {
      try {
        const general = await getCachedUserSettings(ownerId)
        if (general && canSeeWithRule(effectiveTimeZoneRule(general.privacy), ownerId, viewerId)) {
          visible.add(ownerId)
        }
      } catch (error) {
        log.warn("Could not read time zone rule; hiding it", { ownerId, error })
      }
    }),
  )

  return visible
}

import type { DbUser } from "@in/server/db/schema"
import { UserSettingsModel } from "@in/server/db/models/userSettings/userSettings"
import type { Transaction } from "@in/server/db/types"
import { canSeeWithRule, effectiveTimeZoneRule } from "@in/server/modules/privacy/privacyRules"

/**
 * Returns the owners whose time zone `viewerId` may see.
 *
 * `users.share_time_zone` is true only for a rule open to everyone with no
 * exceptions, so those owners need no settings read. Other owners are checked
 * against their full rule, and an unreadable rule hides the time zone.
 */
export const resolveTimeZoneVisibility = async (
  tx: Transaction,
  viewerId: number,
  owners: Iterable<Pick<DbUser, "id" | "shareTimeZone">>,
): Promise<Set<number>> => {
  const visible = new Set<number>()
  const restricted = new Set<number>()
  for (const owner of owners) {
    if (owner.id === viewerId || owner.shareTimeZone !== false) visible.add(owner.id)
    else restricted.add(owner.id)
  }

  const settings = await UserSettingsModel.getGeneralForUsers(tx, [...restricted])
  for (const [ownerId, general] of settings) {
    if (general && canSeeWithRule(effectiveTimeZoneRule(general.privacy), ownerId, viewerId)) visible.add(ownerId)
  }
  return visible
}

import { UserSettingsModel } from "@in/server/db/models/userSettings/userSettings"
import type { Transaction } from "@in/server/db/types"
import type { FocusStatus } from "@inline-chat/protocol/core"
import type { DbUser } from "@in/server/db/schema"
import { getCachedUserSettings } from "@in/server/modules/cache/userSettings"
import { canSeeWithRule, effectiveFocusRule } from "@in/server/modules/privacy/privacyRules"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import { Log } from "@in/server/utils/log"

const log = new Log("privacy.focusStatus")

/** A focused report older than this is treated as off. Clients apply the same window. */
export const FOCUS_STALE_MS = 24 * 60 * 60 * 1000

export type FocusState = Pick<DbUser, "focused" | "focusUpdatedAt">

/** True when the owner's last report says focused and is recent enough to trust. */
export const isCurrentlyFocused = (state: FocusState, now = Date.now()): boolean =>
  state.focused === true &&
  state.focusUpdatedAt != null &&
  now - state.focusUpdatedAt.getTime() < FOCUS_STALE_MS

/**
 * The authoritative Focus value for one viewer. A hidden, stale, or off
 * status all read as not focused, so the viewer cannot tell them apart.
 */
export const encodeFocusForViewer = (state: FocusState, visible: boolean, now = Date.now()): FocusStatus =>
  visible && isCurrentlyFocused(state, now)
    ? { focused: true, updatedAt: encodeDate(state.focusUpdatedAt!) }
    : { focused: false }

/** Viewers among `viewerIds` that the owner's Focus rule allows. Unreadable rules allow nobody. */
export const focusViewersAllowed = async (ownerId: number, viewerIds: Iterable<number>): Promise<Set<number>> => {
  const allowed = new Set<number>()
  try {
    const rule = effectiveFocusRule((await getCachedUserSettings(ownerId))?.privacy)
    for (const viewerId of viewerIds) {
      if (canSeeWithRule(rule, ownerId, viewerId)) allowed.add(viewerId)
    }
  } catch (error) {
    log.warn("Could not read Focus rule; hiding it", { ownerId, error })
  }
  return allowed
}

/**
 * Focus values for `owners` as seen by `viewerId`. Only owners who are
 * currently focused need their rule read; everyone else reads as off.
 */
export const resolveFocusForViewer = async (
  tx: Transaction,
  viewerId: number,
  owners: Iterable<Pick<DbUser, "id"> & FocusState>,
): Promise<Map<number, FocusStatus>> => {
  const now = Date.now()
  const result = new Map<number, FocusStatus>()
  const focused = Array.from(owners).filter(owner => {
    result.set(owner.id, { focused: false })
    return isCurrentlyFocused(owner, now)
  })
  const settings = await UserSettingsModel.getGeneralForUsers(tx, focused.map(owner => owner.id))
  for (const owner of focused) {
    const rule = effectiveFocusRule(settings.get(owner.id)?.privacy)
    result.set(owner.id, encodeFocusForViewer(owner, canSeeWithRule(rule, owner.id, viewerId), now))
  }
  return result
}

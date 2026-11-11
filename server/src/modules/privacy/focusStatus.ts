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
  viewerId: number,
  owners: Iterable<Pick<DbUser, "id"> & FocusState>,
): Promise<Map<number, FocusStatus>> => {
  const now = Date.now()
  const result = new Map<number, FocusStatus>()
  await Promise.all(
    Array.from(owners, async (owner) => {
      if (!isCurrentlyFocused(owner, now)) {
        result.set(owner.id, { focused: false })
        return
      }
      const visible = (await focusViewersAllowed(owner.id, [viewerId])).has(viewerId)
      result.set(owner.id, encodeFocusForViewer(owner, visible, now))
    }),
  )
  return result
}

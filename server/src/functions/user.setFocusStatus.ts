import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { isCurrentlyFocused } from "@in/server/modules/privacy/focusStatus"
import { sendTransientUpdateFor } from "@in/server/modules/updates/sendUpdate"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"

const log = new Log("functions.setFocusStatus")

/** Repeat reports of an unchanged Focus re-announce it this often, keeping viewers inside the stale window. */
const FOCUS_REANNOUNCE_MS = 6 * 60 * 60 * 1000

export const setFocusStatus = async (input: { focused: boolean }, context: FunctionContext): Promise<void> => {
  const now = new Date()
  const [previous] = await db
    .select({ focused: users.focused, focusUpdatedAt: users.focusUpdatedAt })
    .from(users)
    .where(eq(users.id, context.currentUserId))
    .limit(1)
  if (!previous) throw RealtimeRpcError.UserIdInvalid()

  const [next] = await db
    .update(users)
    .set({ focused: input.focused, focusUpdatedAt: now })
    .where(eq(users.id, context.currentUserId))
    .returning({
      online: users.online,
      lastOnline: users.lastOnline,
      focused: users.focused,
      focusUpdatedAt: users.focusUpdatedAt,
    })
  if (!next) throw RealtimeRpcError.UserIdInvalid()

  const wasFocused = isCurrentlyFocused(previous, now.getTime())
  const reannounce =
    input.focused &&
    previous.focusUpdatedAt != null &&
    now.getTime() - previous.focusUpdatedAt.getTime() >= FOCUS_REANNOUNCE_MS
  if (wasFocused === input.focused && !reannounce) return

  // Viewers outside the rule already read "not focused", so only allowed ones need this.
  await sendTransientUpdateFor({
    reason: {
      userPresenceUpdate: {
        userId: context.currentUserId,
        online: next.online,
        lastOnline: next.lastOnline,
        focus: next,
        focusAudienceOnly: true,
      },
    },
  }).catch((error: unknown) => {
    log.warn("Could not publish Focus status", { userId: context.currentUserId, error })
  })
}

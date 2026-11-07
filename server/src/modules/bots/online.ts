/**
 * Bot online status
 *
 * People report their own presence; bots never do, so the server derives it.
 * A bot is online while it holds a realtime connection (SDK bots, OpenClaw,
 * Hermes, CLI bridges) or has called the Bot HTTP API recently.
 *
 * - `users.online` is the published state, `users.last_online` is the last
 *   time the bot was seen active, so "last seen" stays accurate after it stops.
 * - Socket close goes offline through PresenceManager like any user.
 * - HTTP-only bots go offline from a shared sweep once their activity lapses.
 *   The sweep is database-driven, so any process can sweep and a restart
 *   cannot strand a bot online.
 */

import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { userNotDeleted } from "@in/server/db/schema/users"
import { connectionDirectory } from "@in/server/modules/internalMessaging/directory"
import { sendTransientUpdateFor } from "@in/server/modules/updates/sendUpdate"
import { Log } from "@in/server/utils/log"
import { and, eq, inArray, isNull, lt, or } from "drizzle-orm"

const log = new Log("Bots.online")

/** A bot without a connection counts as online this long after its last API call. */
export const BOT_HTTP_ACTIVE_WINDOW_MS = 5 * 60_000
/** At most one activity write per bot per process in this window. */
const TOUCH_THROTTLE_MS = 60_000
const SWEEP_INTERVAL_MS = 60_000
const MAX_TRACKED_TOUCHES = 10_000
const MAX_SWEEP_BATCH = 500

const lastTouchAt = new Map<number, number>()

/** Bot HTTP API request. Cheap to call on every request. */
export function touchBotOnline(botUserId: number, now = Date.now()): void {
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) return
  const last = lastTouchAt.get(botUserId)
  if (last !== undefined && now - last < TOUCH_THROTTLE_MS) return
  if (last === undefined && lastTouchAt.size >= MAX_TRACKED_TOUCHES) lastTouchAt.clear()
  lastTouchAt.set(botUserId, now)
  void markBotOnline(botUserId, new Date(now)).catch((error: unknown) => {
    log.warn("Failed to mark bot online", { botUserId, error })
  })
}

/** Records activity and publishes the transition when the bot was offline. */
export async function markBotOnline(botUserId: number, now = new Date()): Promise<boolean> {
  const turnedOnline = await db
    .update(users)
    .set({ online: true, lastOnline: now })
    .where(and(eq(users.id, botUserId), eq(users.bot, true), userNotDeleted(), eq(users.online, false)))
    .returning({ id: users.id })
  if (turnedOnline.length === 0) {
    // Already online (or not a bot): refresh activity only.
    await db
      .update(users)
      .set({ lastOnline: now })
      .where(and(eq(users.id, botUserId), eq(users.bot, true), userNotDeleted()))
    return false
  }
  await publishBotPresence(botUserId, true, now)
  return true
}

/**
 * Marks bots offline whose API activity lapsed and that hold no connection.
 * Connected bots get their activity refreshed so they skip the next sweeps.
 */
export async function sweepLapsedBotOnline(now = Date.now()): Promise<number> {
  const cutoff = new Date(now - BOT_HTTP_ACTIVE_WINDOW_MS)
  const candidates = await db
    .select({ id: users.id })
    .from(users)
    .where(and(eq(users.bot, true), eq(users.online, true), or(isNull(users.lastOnline), lt(users.lastOnline, cutoff))))
    .limit(MAX_SWEEP_BATCH)

  const connected: number[] = []
  let swept = 0
  for (const { id } of candidates) {
    const view = await connectionDirectory.list(id)
    // Unknown directory state never turns a live remote socket offline.
    if (view.status === "unavailable" || !view.complete) continue
    if (view.connections.length > 0) {
      connected.push(id)
      continue
    }
    const [offline] = await db
      .update(users)
      .set({ online: false })
      .where(
        and(
          eq(users.id, id),
          eq(users.online, true),
          // A touch that landed after the select keeps the bot online.
          or(isNull(users.lastOnline), lt(users.lastOnline, cutoff)),
        ),
      )
      .returning({ lastOnline: users.lastOnline })
    if (!offline) continue
    swept += 1
    lastTouchAt.delete(id)
    await publishBotPresence(id, false, offline.lastOnline)
  }
  if (connected.length > 0) {
    await db.update(users).set({ lastOnline: new Date(now) }).where(inArray(users.id, connected))
  }
  return swept
}

async function publishBotPresence(botUserId: number, online: boolean, lastOnline: Date | null): Promise<void> {
  await sendTransientUpdateFor({
    reason: { userPresenceUpdate: { userId: botUserId, online, lastOnline } },
  }).catch((error: unknown) => {
    log.warn("Could not publish bot presence", { botUserId, error })
  })
}

let sweepTimer: ReturnType<typeof setInterval> | undefined
let sweepInFlight: Promise<unknown> | undefined

export function startBotOnlineSweeper(): void {
  if (sweepTimer) return
  sweepTimer = setInterval(() => {
    if (sweepInFlight) return
    sweepInFlight = sweepLapsedBotOnline()
      .catch((error: unknown) => log.warn("Bot online sweep failed", { error }))
      .finally(() => {
        sweepInFlight = undefined
      })
  }, SWEEP_INTERVAL_MS)
  sweepTimer.unref?.()
}

export async function stopBotOnlineSweeper(): Promise<void> {
  if (sweepTimer) clearInterval(sweepTimer)
  sweepTimer = undefined
  await sweepInFlight
}

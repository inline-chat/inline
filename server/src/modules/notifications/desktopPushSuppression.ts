import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { and, eq, isNull } from "drizzle-orm"

type SessionClientType = "ios" | "macos" | "web" | "api" | "android" | "windows" | "linux" | "cli"

const DESKTOP_CLIENT_TYPES = new Set<SessionClientType>(["macos"])

export type DesktopPushSuppressionReason =
  | "active_desktop_chat"
  | "urgent_nudge"
  | "no_recent_desktop_activity"

export type DesktopPushSuppressionDecision = {
  suppress: boolean
  reason: DesktopPushSuppressionReason
}

export type RecordChatActivityInput = {
  userId: number
  sessionId: number
  chatId: number
  now?: number
}

export type ShouldSuppressIOSSendMessagePushInput = {
  userId: number
  chatId: number
  isUrgentNudge: boolean
  now?: number
}

type SessionActivity = {
  userId: number
  chatId: number
  lastActiveAt: number
}

type SessionClientTypeResolver = (input: { userId: number; sessionId: number }) => Promise<SessionClientType | null>

type DesktopPushSuppressionTrackerOptions = {
  activityTtlMs?: number
  now?: () => number
  resolveSessionClientType?: SessionClientTypeResolver
}

export type DesktopPushSuppressionMetrics = {
  checksTotal: number
  suppressedTotal: number
  allowedTotal: number
  allowedUrgentNudgeTotal: number
  allowedNoRecentDesktopActivityTotal: number
  activityRecordedTotal: number
  activityIgnoredNonDesktopTotal: number
  activityIgnoredUnknownSessionTypeTotal: number
  errorsTotal: number
  trackedDesktopSessions: number
  trackedDesktopChatActivities: number
  lastSuppressedAt: number | null
}

const DEFAULT_ACTIVITY_TTL_MS = 60_000

// NOTE: This module keeps activity state in memory and is only correct in single-instance deployments.
// For multi-instance deployments, move activity/session-type state to a shared store (e.g. Redis/Postgres).
export class DesktopPushSuppressionTracker {
  private readonly activityTtlMs: number
  private readonly now: () => number
  private readonly resolveSessionClientType: SessionClientTypeResolver

  private readonly sessionActivity = new Map<number, SessionActivity>()
  private readonly sessionsByUser = new Map<number, Set<number>>()
  private readonly sessionClientTypeCache = new Map<number, SessionClientType | null>()

  private checksTotal = 0
  private suppressedTotal = 0
  private allowedTotal = 0
  private allowedUrgentNudgeTotal = 0
  private allowedNoRecentDesktopActivityTotal = 0
  private activityRecordedTotal = 0
  private activityIgnoredNonDesktopTotal = 0
  private activityIgnoredUnknownSessionTypeTotal = 0
  private errorsTotal = 0
  private lastSuppressedAt: number | null = null

  constructor(options: DesktopPushSuppressionTrackerOptions = {}) {
    this.activityTtlMs = options.activityTtlMs ?? DEFAULT_ACTIVITY_TTL_MS
    this.now = options.now ?? Date.now
    this.resolveSessionClientType = options.resolveSessionClientType ?? defaultSessionClientTypeResolver
  }

  async recordChatActivity(input: RecordChatActivityInput): Promise<void> {
    const now = input.now ?? this.now()
    this.pruneStale(now)

    let clientType: SessionClientType | null
    try {
      clientType = await this.getSessionClientType({ userId: input.userId, sessionId: input.sessionId })
    } catch {
      this.errorsTotal += 1
      return
    }

    if (!clientType) {
      this.activityIgnoredUnknownSessionTypeTotal += 1
      return
    }

    if (!DESKTOP_CLIENT_TYPES.has(clientType)) {
      this.activityIgnoredNonDesktopTotal += 1
      return
    }

    this.sessionActivity.set(input.sessionId, {
      userId: input.userId,
      chatId: input.chatId,
      lastActiveAt: now,
    })

    let userSessionIds = this.sessionsByUser.get(input.userId)
    if (!userSessionIds) {
      userSessionIds = new Set<number>()
      this.sessionsByUser.set(input.userId, userSessionIds)
    }
    userSessionIds.add(input.sessionId)

    this.activityRecordedTotal += 1
  }

  shouldSuppressIOSSendMessagePush(input: ShouldSuppressIOSSendMessagePushInput): DesktopPushSuppressionDecision {
    const now = input.now ?? this.now()
    this.pruneStale(now)

    this.checksTotal += 1

    if (input.isUrgentNudge) {
      this.allowedTotal += 1
      this.allowedUrgentNudgeTotal += 1
      return { suppress: false, reason: "urgent_nudge" }
    }

    const userSessionIds = this.sessionsByUser.get(input.userId)
    if (!userSessionIds || userSessionIds.size === 0) {
      this.allowedTotal += 1
      this.allowedNoRecentDesktopActivityTotal += 1
      return { suppress: false, reason: "no_recent_desktop_activity" }
    }

    for (const sessionId of userSessionIds) {
      const activity = this.sessionActivity.get(sessionId)
      if (!activity) {
        continue
      }
      if (activity.chatId !== input.chatId) {
        continue
      }

      this.suppressedTotal += 1
      this.lastSuppressedAt = now
      return { suppress: true, reason: "active_desktop_chat" }
    }

    this.allowedTotal += 1
    this.allowedNoRecentDesktopActivityTotal += 1
    return { suppress: false, reason: "no_recent_desktop_activity" }
  }

  getMetrics(): DesktopPushSuppressionMetrics {
    this.pruneStale(this.now())

    const uniqueUserChatPairs = new Set<string>()
    for (const activity of this.sessionActivity.values()) {
      uniqueUserChatPairs.add(`${activity.userId}:${activity.chatId}`)
    }

    return {
      checksTotal: this.checksTotal,
      suppressedTotal: this.suppressedTotal,
      allowedTotal: this.allowedTotal,
      allowedUrgentNudgeTotal: this.allowedUrgentNudgeTotal,
      allowedNoRecentDesktopActivityTotal: this.allowedNoRecentDesktopActivityTotal,
      activityRecordedTotal: this.activityRecordedTotal,
      activityIgnoredNonDesktopTotal: this.activityIgnoredNonDesktopTotal,
      activityIgnoredUnknownSessionTypeTotal: this.activityIgnoredUnknownSessionTypeTotal,
      errorsTotal: this.errorsTotal,
      trackedDesktopSessions: this.sessionActivity.size,
      trackedDesktopChatActivities: uniqueUserChatPairs.size,
      lastSuppressedAt: this.lastSuppressedAt,
    }
  }

  resetForTests() {
    this.sessionActivity.clear()
    this.sessionsByUser.clear()
    this.sessionClientTypeCache.clear()
    this.checksTotal = 0
    this.suppressedTotal = 0
    this.allowedTotal = 0
    this.allowedUrgentNudgeTotal = 0
    this.allowedNoRecentDesktopActivityTotal = 0
    this.activityRecordedTotal = 0
    this.activityIgnoredNonDesktopTotal = 0
    this.activityIgnoredUnknownSessionTypeTotal = 0
    this.errorsTotal = 0
    this.lastSuppressedAt = null
  }

  private async getSessionClientType(input: { userId: number; sessionId: number }): Promise<SessionClientType | null> {
    if (this.sessionClientTypeCache.has(input.sessionId)) {
      return this.sessionClientTypeCache.get(input.sessionId) ?? null
    }

    const clientType = await this.resolveSessionClientType(input)
    if (clientType && DESKTOP_CLIENT_TYPES.has(clientType)) {
      this.sessionClientTypeCache.set(input.sessionId, clientType)
    }
    return clientType
  }

  private pruneStale(now: number) {
    const staleCutoff = now - this.activityTtlMs

    for (const [sessionId, activity] of this.sessionActivity.entries()) {
      if (activity.lastActiveAt >= staleCutoff) {
        continue
      }

      this.sessionActivity.delete(sessionId)
      this.sessionClientTypeCache.delete(sessionId)

      const userSessionIds = this.sessionsByUser.get(activity.userId)
      if (!userSessionIds) {
        continue
      }

      userSessionIds.delete(sessionId)
      if (userSessionIds.size === 0) {
        this.sessionsByUser.delete(activity.userId)
      }
    }
  }
}

const defaultSessionClientTypeResolver: SessionClientTypeResolver = async ({ userId, sessionId }) => {
  const row = await db
    .select({ clientType: sessions.clientType })
    .from(sessions)
    .where(and(eq(sessions.id, sessionId), eq(sessions.userId, userId), isNull(sessions.revoked)))
    .limit(1)
    .then((rows) => rows[0])

  return row?.clientType ?? null
}

export const desktopPushSuppressionTracker = new DesktopPushSuppressionTracker()

export const getDesktopPushSuppressionMetrics = (): DesktopPushSuppressionMetrics => {
  return desktopPushSuppressionTracker.getMetrics()
}

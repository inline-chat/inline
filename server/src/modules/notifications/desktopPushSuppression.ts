import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { connectionManager } from "@in/server/ws/connections"

type SessionClientType = "ios" | "macos" | "web" | "api" | "android" | "windows" | "linux" | "cli"

export type DesktopPushSuppressionReason = "active_desktop_chat" | "urgent_nudge" | "no_recent_desktop_activity"
export type DesktopPushSuppressionDecision = { suppress: boolean; reason: DesktopPushSuppressionReason }
export type RecordChatActivityInput = { userId: number; sessionId: number; connectionId?: string; chatId: number; now?: number }
export type ShouldSuppressIOSSendMessagePushInput = { userId: number; chatId: number; isUrgentNudge: boolean; now?: number }

type SessionClientTypeResolver = (input: { userId: number; sessionId: number; connectionId?: string }) => SessionClientType | null | Promise<SessionClientType | null>
export type DesktopActivityStore = {
  record(userId: number, chatId: number): Promise<boolean>
  has(userId: number, chatId: number): Promise<boolean | undefined>
}

type DesktopPushSuppressionTrackerOptions = {
  now?: () => number
  resolveSessionClientType?: SessionClientTypeResolver
  store?: DesktopActivityStore
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

const redisStore: DesktopActivityStore = {
  record: (userId, chatId) => internalMessaging.recordDesktopActivity(userId, chatId),
  has: (userId, chatId) => internalMessaging.hasDesktopActivity(userId, chatId),
}

/** A user/chat key is the only suppression authority. Missing broker data always allows push. */
export class DesktopPushSuppressionTracker {
  private readonly now: () => number
  private readonly resolveSessionClientType: SessionClientTypeResolver
  private readonly store: DesktopActivityStore

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
    this.now = options.now ?? Date.now
    this.resolveSessionClientType = options.resolveSessionClientType ?? defaultSessionClientTypeResolver
    this.store = options.store ?? redisStore
  }

  async recordChatActivity(input: RecordChatActivityInput): Promise<void> {
    // The signal is authenticated, but a client cannot assert that it is macOS.
    // Use the authenticated socket's client type. An absent or unknown socket cannot suppress push.
    try {
      const clientType = await this.resolveSessionClientType({ userId: input.userId, sessionId: input.sessionId, connectionId: input.connectionId })
      if (!clientType) { this.activityIgnoredUnknownSessionTypeTotal++; return }
      if (clientType !== "macos") { this.activityIgnoredNonDesktopTotal++; return }
      if (!await this.store.record(input.userId, input.chatId)) { this.errorsTotal++; return }
      this.activityRecordedTotal++
    } catch { this.errorsTotal++ }
  }

  async shouldSuppressIOSSendMessagePush(input: ShouldSuppressIOSSendMessagePushInput): Promise<DesktopPushSuppressionDecision> {
    this.checksTotal++
    if (input.isUrgentNudge) {
      this.allowedTotal++
      this.allowedUrgentNudgeTotal++
      return { suppress: false, reason: "urgent_nudge" }
    }
    let active: boolean | undefined
    try { active = await this.store.has(input.userId, input.chatId) } catch { this.errorsTotal++ }
    if (active === true) {
      this.suppressedTotal++
      this.lastSuppressedAt = input.now ?? this.now()
      return { suppress: true, reason: "active_desktop_chat" }
    }
    if (active === undefined) this.errorsTotal++
    this.allowedTotal++
    this.allowedNoRecentDesktopActivityTotal++
    return { suppress: false, reason: "no_recent_desktop_activity" }
  }

  getMetrics(): DesktopPushSuppressionMetrics {
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
      // A disposable cluster keyspace is deliberately not enumerated for metrics.
      trackedDesktopSessions: 0,
      trackedDesktopChatActivities: 0,
      lastSuppressedAt: this.lastSuppressedAt,
    }
  }

  resetForTests(): void {
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
}

const defaultSessionClientTypeResolver: SessionClientTypeResolver = ({ userId, sessionId, connectionId }) => {
  if (!connectionId) return null
  const connection = connectionManager.getConnection(connectionId)
  if (connection?.userId !== userId || connection.sessionId !== sessionId) return null
  return connection.clientType === "macos" ? "macos" : null
}

export const desktopPushSuppressionTracker = new DesktopPushSuppressionTracker()
export const getDesktopPushSuppressionMetrics = (): DesktopPushSuppressionMetrics => desktopPushSuppressionTracker.getMetrics()

import * as Sentry from "@sentry/bun"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { LocalCache } from "@in/server/modules/cache/localCache"
import { RealtimeRpcError, retryAfterSecondsFromMs } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"

/**
 * Forgiving send pacing for bots, Telegram flood-wait style: a bot that keeps
 * posting into one chat faster than its budget gets RATE_LIMIT with a
 * retry-after instead of fanning out more database work. The per-bot budget
 * only observes until its summaries show safe numbers; Oct 28's waves would
 * not have tripped either rule, so attribution is the first job here.
 */
export type BotSendPacingMode = "enforce" | "observe" | "off"

export type BotSendPacingConfig = {
  mode: BotSendPacingMode
  /** Messages one bot may post into one chat in a burst, then `perChatPerSecond`. */
  perChatBurst: number
  perChatPerSecond: number
  /** Messages one bot may post across all chats in a burst, then `perBotPerSecond`. */
  perBotBurst: number
  perBotPerSecond: number
  /** The cross-chat rule can stay observe-only while the per-chat rule enforces. */
  perBotMode: "enforce" | "observe"
}

export type BotSendPacingRule = "per_chat" | "per_bot"

export type BotSendPacingDecision =
  | { allowed: true }
  | { allowed: false; rule: BotSendPacingRule; retryAfterMs: number }

type Bucket = { tokens: number; updatedAt: number }

type MinuteStats = {
  sends: number
  rejected: number
  observed: number
  chats: Set<number>
  rules: Set<BotSendPacingRule>
}

const log = new Log("pacing.botSend")
const SUMMARY_INTERVAL_MS = 60_000
const SUMMARY_TOP_BOTS = 5
const SENTRY_INTERVAL_MS = 10 * 60_000
const IDLE_BUCKET_MS = 10 * 60_000
const MAX_TRACKED_BUCKETS = 50_000

const positiveNumber = (value: string | undefined, fallback: number): number => {
  const parsed = value === undefined ? Number.NaN : Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}

export const botSendPacingConfigFromEnv = (env: Record<string, string | undefined> = process.env): BotSendPacingConfig => {
  const mode = env["BOT_SEND_PACING"]
  // Suites share one process pacer; they opt in with an explicit mode.
  const defaultMode: BotSendPacingMode = env["NODE_ENV"] === "test" ? "off" : "enforce"
  return {
    mode: mode === "observe" || mode === "off" || mode === "enforce" ? mode : defaultMode,
    perChatBurst: positiveNumber(env["BOT_SEND_PACING_PER_CHAT_BURST"], 20),
    perChatPerSecond: positiveNumber(env["BOT_SEND_PACING_PER_CHAT_PER_SECOND"], 1),
    perBotBurst: positiveNumber(env["BOT_SEND_PACING_PER_BOT_BURST"], 60),
    perBotPerSecond: positiveNumber(env["BOT_SEND_PACING_PER_BOT_PER_SECOND"], 2),
    perBotMode: env["BOT_SEND_PACING_PER_BOT"] === "enforce" ? "enforce" : "observe",
  }
}

export class BotSendPacer {
  private readonly buckets = new Map<string, Bucket>()
  private minute = new Map<number, MinuteStats>()
  private minuteStartedAt: number
  private readonly sentryReportedAt = new Map<number, number>()

  constructor(
    private readonly config: BotSendPacingConfig,
    private readonly now: () => number = Date.now,
    private readonly report: (botUserId: number, rule: BotSendPacingRule, mode: BotSendPacingMode) => void = reportToSentry,
  ) {
    this.minuteStartedAt = now()
  }

  get enabled(): boolean {
    return this.config.mode !== "off"
  }

  /** Takes one send from both budgets, or neither when either is empty. */
  take(botUserId: number, chatId: number): BotSendPacingDecision {
    if (this.config.mode === "off") return { allowed: true }
    const now = this.now()
    this.rollMinute(now)
    const stats = this.statsFor(botUserId)
    stats.sends += 1
    stats.chats.add(chatId)

    const chatKey = `c:${botUserId}:${chatId}`
    const botKey = `b:${botUserId}`
    const chat = this.refill(chatKey, this.config.perChatBurst, this.config.perChatPerSecond, now)
    const bot = this.refill(botKey, this.config.perBotBurst, this.config.perBotPerSecond, now)
    const chatShort = chat.tokens < 1
    const botShort = bot.tokens < 1
    const shortRule: BotSendPacingRule | undefined = chatShort ? "per_chat" : botShort ? "per_bot" : undefined

    if (shortRule === undefined) {
      chat.tokens -= 1
      bot.tokens -= 1
      return { allowed: true }
    }

    const enforcesBot = this.config.perBotMode === "enforce"
    const retryAfterMs = Math.max(
      chatShort ? ((1 - chat.tokens) / this.config.perChatPerSecond) * 1000 : 0,
      botShort && enforcesBot ? ((1 - bot.tokens) / this.config.perBotPerSecond) * 1000 : 0,
    )
    stats.rules.add(shortRule)
    this.reportOnce(botUserId, shortRule, now)
    if (this.config.mode === "observe" || (!chatShort && !enforcesBot)) {
      // Observe still spends, so the logs show what enforce would have done.
      stats.observed += 1
      chat.tokens = Math.max(chat.tokens - 1, -this.config.perChatBurst)
      bot.tokens = Math.max(bot.tokens - 1, -this.config.perBotBurst)
      return { allowed: true }
    }
    stats.rejected += 1
    return { allowed: false, rule: shortRule, retryAfterMs }
  }

  /** Flushes the current minute's summary; the host also calls this on a timer. */
  flushSummary(now = this.now()): void {
    const entries = Array.from(this.minute.entries())
    this.minute = new Map()
    this.minuteStartedAt = now
    if (entries.length === 0) return

    const throttled = entries.filter(([, stats]) => stats.rejected > 0 || stats.observed > 0)
    for (const [botUserId, stats] of throttled) {
      log.warn("Bot send pacing throttled", {
        botUserId,
        mode: this.config.mode,
        rules: Array.from(stats.rules),
        sends: stats.sends,
        rejected: stats.rejected,
        observed: stats.observed,
        chats: stats.chats.size,
      })
    }
    const top = entries
      .sort(([, a], [, b]) => b.sends - a.sends)
      .slice(0, SUMMARY_TOP_BOTS)
      .map(([botUserId, stats]) => ({ botUserId, sends: stats.sends, chats: stats.chats.size, rejected: stats.rejected }))
    log.info("Bot send pacing summary", { mode: this.config.mode, bots: entries.length, top })
    this.pruneIdleBuckets(now)
  }

  private rollMinute(now: number): void {
    if (now - this.minuteStartedAt >= SUMMARY_INTERVAL_MS) this.flushSummary(now)
  }

  private statsFor(botUserId: number): MinuteStats {
    let stats = this.minute.get(botUserId)
    if (!stats) {
      stats = { sends: 0, rejected: 0, observed: 0, chats: new Set(), rules: new Set() }
      this.minute.set(botUserId, stats)
    }
    return stats
  }

  private refill(key: string, burst: number, perSecond: number, now: number): Bucket {
    let bucket = this.buckets.get(key)
    if (!bucket) {
      bucket = { tokens: burst, updatedAt: now }
      this.buckets.set(key, bucket)
      if (this.buckets.size > MAX_TRACKED_BUCKETS) this.pruneIdleBuckets(now)
      return bucket
    }
    const elapsedSeconds = Math.max(0, now - bucket.updatedAt) / 1000
    bucket.tokens = Math.min(burst, bucket.tokens + elapsedSeconds * perSecond)
    bucket.updatedAt = now
    return bucket
  }

  private pruneIdleBuckets(now: number): void {
    for (const [key, bucket] of this.buckets) {
      if (now - bucket.updatedAt >= IDLE_BUCKET_MS) this.buckets.delete(key)
    }
    // Still over capacity means many active keys; drop the oldest insertions.
    while (this.buckets.size > MAX_TRACKED_BUCKETS) {
      const oldest = this.buckets.keys().next().value
      if (oldest === undefined) break
      this.buckets.delete(oldest)
    }
  }

  private reportOnce(botUserId: number, rule: BotSendPacingRule, now: number): void {
    const last = this.sentryReportedAt.get(botUserId)
    if (last !== undefined && now - last < SENTRY_INTERVAL_MS) return
    this.sentryReportedAt.set(botUserId, now)
    try {
      this.report(botUserId, rule, this.config.mode)
    } catch {
      // Reporting never decides a send.
    }
  }
}

const reportToSentry = (botUserId: number, rule: BotSendPacingRule, mode: BotSendPacingMode): void => {
  Sentry.captureMessage("Bot send pacing throttled", {
    level: "warning",
    tags: { "pacing.rule": rule, "pacing.mode": mode, bot_id: String(botUserId) },
  })
}

const botFlags = new LocalCache<number, boolean>({ ttlMs: 10 * 60_000, negativeTtlMs: 10 * 60_000, maxEntries: 10_000 })

const isBotUser = (userId: number): Promise<boolean> =>
  botFlags.get(userId, async () => {
    const [row] = await db.select({ bot: users.bot }).from(users).where(eq(users.id, userId)).limit(1)
    return row?.bot === true
  })

let pacer: BotSendPacer | undefined
let summaryTimer: ReturnType<typeof setInterval> | undefined

const defaultPacer = (): BotSendPacer => {
  if (!pacer) {
    pacer = new BotSendPacer(botSendPacingConfigFromEnv())
    summaryTimer = setInterval(() => pacer?.flushSummary(), SUMMARY_INTERVAL_MS)
    summaryTimer.unref?.()
  }
  return pacer
}

/**
 * Throws RATE_LIMIT with a retry-after when a bot exceeds its send budget.
 * Human senders return without a budget; the bot flag is cached per user.
 */
export const enforceBotSendPacing = async (input: {
  senderUserId: number
  chatId: number
  isBot?: boolean
}): Promise<void> => {
  const current = defaultPacer()
  // Off costs nothing: no bot lookup, no statement on the send path.
  if (!current.enabled) return
  const isBot = input.isBot ?? await isBotUser(input.senderUserId)
  if (!isBot) return
  const decision = current.take(input.senderUserId, input.chatId)
  if (decision.allowed) return
  throw RealtimeRpcError.RateLimit(retryAfterSecondsFromMs(decision.retryAfterMs))
}

/** Test seam: replaces the process pacer and clears cached bot flags. */
export const resetBotSendPacingForTests = (next?: BotSendPacer): void => {
  if (summaryTimer) clearInterval(summaryTimer)
  summaryTimer = undefined
  pacer = next
  botFlags.clear()
}

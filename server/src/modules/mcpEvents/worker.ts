import { purgeExpiredReactionEvents } from "@in/server/db/models/mcpReactionEvents"
import { isReactionEvent, reactionEventsEnabled } from "./config"
import { OauthModel } from "@in/server/db/models/oauth"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { isTest } from "@in/server/env"
import { IdleBackoff } from "@in/server/utils/idleBackoff"
import { Log } from "@in/server/utils/log"
import { authorizeSelector, validateGrant } from "./authorization"
import { acknowledgeClaim, claimSubscriptions, currentClaim, failClaim, fenceClaim, persistGap, persistPending, purgeExpiredSubscriptions, settleIdle } from "./repository"
import { nextOccurrence } from "./source"
import { callbackTransport, signedHeaders, type CallbackTransport } from "./webhook"
import { McpEventsError, accessDenied, type McpEventSubscription } from "./types"

const log = new Log("mcpEvents.worker")
const maximumAttempts = 12
export const retryDelay = (attempt: number): number => Math.min(15 * 60_000, 1000 * 2 ** Math.min(12, Math.max(0, attempt - 1)))
const requestedRetry = (status: number, value?: string): number | undefined => {
  if ((status !== 429 && status !== 503) || value === undefined) return undefined
  const seconds = Number(value)
  const delay = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(value) - Date.now()
  return Number.isFinite(delay) && delay > 0 ? Math.min(60 * 60_000, delay) : undefined
}

async function deliver(claim: McpEventSubscription, transport: CallbackTransport): Promise<void> {
  let active = claim
  const reauthorize = async () => {
    if (isReactionEvent(active.name) && !reactionEventsEnabled()) throw accessDenied()
    if (!await currentClaim(active)) throw accessDenied()
    const principal = await validateGrant(await OauthModel.getGrant(active.grantId))
    await authorizeSelector(principal, active.name, active.selector)
    // Authority reads can cross a concurrent refresh/unsubscribe; fence again
    // immediately before opening the external connection or committing ACK.
    if (isReactionEvent(active.name) && !reactionEventsEnabled()) throw accessDenied()
    if (!await currentClaim(active)) throw accessDenied()
    return principal
  }
  try {
    const principal = await reauthorize()
    if (!active.pendingEncrypted) {
      const page = await nextOccurrence(principal, active.name, active.selector, active.cursorSeq)
      if ("gapSeq" in page) { await persistGap(active, page.gapSeq); return }
      if (!page.occurrence) { await reauthorize(); await settleIdle(active, page.through); return }
      const pending = await persistPending(active, page.occurrence, page.through)
      if (!pending) return
      active = pending
    }
    if (active.attemptCount >= maximumAttempts) { await fenceClaim(active); return }
    const body = Encryption2.decryptToString(active.pendingEncrypted!)
    const occurrence: unknown = JSON.parse(body)
    if (!occurrence || typeof occurrence !== "object" || !("eventId" in occurrence) || typeof occurrence.eventId !== "string") throw new Error("Invalid persisted MCP event occurrence")
    const secret = Encryption2.decryptToString(active.secretEncrypted)
    const previousSecret = active.previousSecretEncrypted && active.previousSecretUntil && active.previousSecretUntil > new Date()
      ? Encryption2.decryptToString(active.previousSecretEncrypted) : undefined
    const response = await transport({ url: active.callbackUrl, body,
      headers: signedHeaders(active.id, occurrence.eventId, body, secret, previousSecret), beforeConnect: async () => { await reauthorize() } })
    if (response.status >= 200 && response.status < 300) {
      await reauthorize()
      await acknowledgeClaim(active)
      return
    }
    // The delivery profile makes 410/413 terminal for this occurrence only.
    // Settle it after rechecking authority so later updates can still arrive.
    if (response.status === 410 || response.status === 413) {
      await reauthorize()
      await acknowledgeClaim(active)
      return
    }
    await failClaim(active, new Date(Date.now() + (requestedRetry(response.status, response.retryAfter) ?? retryDelay(active.attemptCount + 1))),
      active.attemptCount + 1 >= maximumAttempts)
  } catch (error) {
    if (error instanceof McpEventsError && error.code === -32012) { await fenceClaim(active); return }
    await failClaim(active, new Date(Date.now() + retryDelay(active.attemptCount + 1)), active.attemptCount + 1 >= maximumAttempts)
  }
}

export async function runMcpEventsOnce(limit = 25, transport: CallbackTransport = callbackTransport): Promise<number> {
  const claims = await claimSubscriptions(limit)
  await Promise.all(claims.map((claim) => deliver(claim, transport)))
  return claims.length
}

const workerPollIntervalMs = 1_000

export type McpEventsWorkerOptions = {
  pollIntervalMs?: number
  maximumIdleIntervalMs?: number
  /** Runs once a minute before a poll; purges expired subscriptions and reaction events. */
  cleanup?: () => Promise<void>
  setIntervalFn?: typeof setInterval
  clearIntervalFn?: typeof clearInterval
}

const purgeExpired = async (): Promise<void> => {
  await purgeExpiredSubscriptions()
  await purgeExpiredReactionEvents()
}

export class McpEventsWorker {
  private readonly pollIntervalMs: number
  private readonly backoff: IdleBackoff
  private readonly cleanup: () => Promise<void>
  private readonly setIntervalFn: typeof setInterval
  private readonly clearIntervalFn: typeof clearInterval
  private timer?: ReturnType<typeof setInterval>
  private inFlight?: Promise<void>
  private stopping = false
  private nextCleanupAt = 0
  constructor(private readonly runOnce: () => Promise<number> = runMcpEventsOnce, options: McpEventsWorkerOptions = {}) {
    this.pollIntervalMs = Math.max(100, options.pollIntervalMs ?? workerPollIntervalMs)
    this.backoff = IdleBackoff.forInterval(this.pollIntervalMs, options.maximumIdleIntervalMs)
    this.cleanup = options.cleanup ?? purgeExpired
    this.setIntervalFn = options.setIntervalFn ?? setInterval
    this.clearIntervalFn = options.clearIntervalFn ?? clearInterval
  }
  start(): void {
    if (this.timer) return
    this.stopping = false
    // The timer keeps its base cadence; idle backoff only skips database
    // reads on ticks that come before the next due poll.
    this.timer = this.setIntervalFn(() => { if (!this.inFlight && this.backoff.due()) void this.poll() }, this.pollIntervalMs)
    void this.poll()
  }
  async stop(): Promise<void> {
    this.stopping = true
    if (this.timer) this.clearIntervalFn(this.timer)
    this.timer = undefined
    await this.inFlight
  }
  /** Base intervals between polls; exposed for diagnostics and tests. */
  get idleMultiplier(): number {
    return this.backoff.multiplier
  }
  poll(): Promise<void> {
    if (this.stopping) return Promise.resolve()
    if (this.inFlight) return this.inFlight
    this.inFlight = (async () => {
      if (Date.now() >= this.nextCleanupAt) {
        await this.cleanup()
        this.nextCleanupAt = Date.now() + 60_000
      }
      return this.runOnce()
    })().then((delivered) => { this.backoff.observe(delivered > 0) }, () => {
      log.error("MCP event worker tick failed")
      this.backoff.observe(false)
    }).finally(() => { this.inFlight = undefined })
    return this.inFlight
  }
}

export function startMcpEventsWorker(): McpEventsWorker | null {
  if (isTest) return null
  const worker = new McpEventsWorker()
  worker.start()
  return worker
}

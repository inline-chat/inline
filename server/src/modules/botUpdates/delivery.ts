import { BotUpdatesModel } from "@in/server/db/models/botUpdates"
import { isTest } from "@in/server/env"
import { Log } from "@in/server/utils/log"
import { resolveWebhookUrl } from "./webhookSecurity"
import { request as httpsRequest } from "node:https"

const log = new Log("botUpdates.delivery")
const requestTimeoutMs = 10_000
let interval: ReturnType<typeof setInterval> | undefined
let ticking = false

export const webhookRetryDelayMs = (attempt: number): number => {
  const schedule = [10_000, 30_000, 120_000, 600_000, 1_800_000]
  const base = schedule[Math.max(0, attempt - 1)] ?? Math.min(3_600_000, 1_800_000 * 2 ** Math.min(6, attempt - 5))
  return base + Math.floor(base * Math.random() * 0.2)
}

const retryAfterMs = (status: number, header: string | string[] | undefined): number | undefined => {
  if (status !== 429 && status !== 503) return undefined
  const seconds = Number(Array.isArray(header) ? header[0] : header)
  if (!Number.isFinite(seconds) || seconds < 1) return undefined
  return Math.min(3_600_000, Math.floor(seconds * 1_000))
}

const postPinned = async (input: {
  rawUrl: string
  body: string
  headers: Record<string, string>
}): Promise<{ status: number; retryAfter?: string | string[] }> => {
  const target = await resolveWebhookUrl(input.rawUrl)
  return new Promise((resolve, reject) => {
    const request = httpsRequest(target.url, {
      method: "POST",
      headers: { ...input.headers, "content-length": Buffer.byteLength(input.body).toString() },
      servername: target.url.hostname,
      lookup: ((_hostname: string, _options: unknown, callback: (error: Error | null, address: string, family: number) => void) =>
        callback(null, target.address, target.family)) as any,
    }, (response) => {
      let bytes = 0
      response.on("data", (chunk: Buffer) => {
        bytes += chunk.byteLength
        if (bytes > 4_096) response.destroy()
      })
      response.on("end", () => resolve({ status: response.statusCode ?? 0, retryAfter: response.headers["retry-after"] }))
      response.on("error", reject)
    })
    request.setTimeout(requestTimeoutMs, () => request.destroy(new Error("Webhook request timed out")))
    request.on("error", reject)
    request.end(input.body)
  })
}

async function deliver(claim: Awaited<ReturnType<typeof BotUpdatesModel.claimWebhookDeliveries>>[number]) {
  const url = claim.stream.webhookUrl
  if (!url) return
  try {
    if (!(await BotUpdatesModel.canBotAccessUpdate(claim.stream.botUserId, claim.update))) {
      await BotUpdatesModel.discardWebhookDelivery(claim)
      log.warn("Discarded Bot webhook update after access loss", {
        botUserId: claim.stream.botUserId,
        updateId: claim.update.update_id,
      })
      return
    }
    const body = JSON.stringify(claim.update)
    const headers: Record<string, string> = {
      "content-type": "application/json",
      "user-agent": "InlineBotWebhook/1.0",
      "x-inline-update-id": String(claim.update.update_id),
      "x-inline-attempt": String(claim.attemptCount + 1),
    }
    const secret = BotUpdatesModel.decryptWebhookSecret(claim.stream)
    if (secret) headers["x-inline-bot-api-secret-token"] = secret
    const response = await postPinned({ rawUrl: url, body, headers })
    if (response.status >= 200 && response.status < 300) {
      await BotUpdatesModel.markWebhookDelivered(claim)
      return
    }
    const delay = retryAfterMs(response.status, response.retryAfter) ?? webhookRetryDelayMs(claim.attemptCount + 1)
    await BotUpdatesModel.markWebhookFailed({
      claim,
      error: `HTTP ${response.status}`,
      retryAt: new Date(Date.now() + delay),
    })
  } catch (error) {
    await BotUpdatesModel.markWebhookFailed({
      claim,
      error: error instanceof Error ? error.message : String(error),
      retryAt: new Date(Date.now() + webhookRetryDelayMs(claim.attemptCount + 1)),
    })
  }
}

export async function runBotWebhookDeliveryOnce(limit = 25): Promise<number> {
  await Promise.all([
    BotUpdatesModel.cleanupBotUpdateRows(),
    BotUpdatesModel.cleanupBotMessageRoutes(),
  ])
  const claims = await BotUpdatesModel.claimWebhookDeliveries(limit)
  await Promise.all(claims.map(deliver))
  return claims.length
}

async function tick() {
  if (ticking) return
  ticking = true
  try {
    await runBotWebhookDeliveryOnce()
  } catch (error) {
    log.error("Bot webhook delivery tick failed", { error })
  } finally {
    ticking = false
  }
}

export function startBotWebhookDeliveryWorker(): void {
  if (interval || isTest) return
  void tick()
  interval = setInterval(() => void tick(), 2_500)
}

export function stopBotWebhookDeliveryWorker(): void {
  if (interval) clearInterval(interval)
  interval = undefined
}

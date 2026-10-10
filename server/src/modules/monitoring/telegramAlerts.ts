import { Log } from "@in/server/utils/log"

const log = new Log("monitoring.telegramAlerts")
const DEFAULT_TIMEOUT_MS = 5_000

type TelegramFetch = (url: string, init: RequestInit) => Promise<Pick<Response, "ok" | "json">>

export type TelegramAlertSenderOptions = {
  environment?: Record<string, string | undefined>
  fetch?: TelegramFetch
  timeoutMs?: number
}

/** Independent of Inline and its database. Only Telegram's acknowledgement
 * counts as delivery; credentials and provider error bodies never reach logs.
 */
export const createTelegramAlertSender = (options: TelegramAlertSenderOptions = {}): ((message: string) => Promise<void>) => {
  const environment = options.environment ?? process.env
  const token = environment["TELEGRAM_ALERTS_BOT_TOKEN"] ?? environment["TELEGRAM_TOKEN"]
  const chatId = environment["TELEGRAM_ALERTS_CHAT_ID"]
  const configured = Boolean(token?.trim() && chatId?.trim())
  const fetchAlert = options.fetch ?? fetch
  const timeoutMs = options.timeoutMs !== undefined && Number.isFinite(options.timeoutMs) && options.timeoutMs > 0
    ? Math.min(Math.floor(options.timeoutMs), 30_000)
    : DEFAULT_TIMEOUT_MS

  if (!configured) {
    log.warn("Telegram DB alerts are not configured; set TELEGRAM_ALERTS_BOT_TOKEN (or TELEGRAM_TOKEN) and TELEGRAM_ALERTS_CHAT_ID")
  }

  return async (message) => {
    if (!configured) throw new Error("Telegram DB alerts are not configured.")
    const controller = new AbortController()
    let timedOut = false
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      await Promise.race([
        (async () => {
          const response = await fetchAlert(`https://api.telegram.org/bot${token}/sendMessage`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ chat_id: chatId, text: message }),
            signal: controller.signal,
            redirect: "error",
          })
          if (!response.ok) throw new Error("Telegram HTTP rejection")
          const body: unknown = await response.json()
          if (typeof body !== "object" || body === null || !("ok" in body) || body.ok !== true) {
            throw new Error("Telegram API rejection")
          }
        })(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            timedOut = true
            controller.abort()
            reject(new Error("Telegram deadline exceeded"))
          }, timeoutMs)
        }),
      ])
    } catch {
      // Fetch errors may contain the token-bearing URL; never retain their cause.
      throw new Error(timedOut ? "Telegram alert delivery timed out." : "Telegram alert delivery failed.")
    } finally {
      clearTimeout(timer)
    }
  }
}

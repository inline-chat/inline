import { describe, expect, test, spyOn } from "bun:test"
import { Log } from "@in/server/utils/log"
import { createTelegramAlertSender } from "./telegramAlerts"

const environment = { TELEGRAM_ALERTS_BOT_TOKEN: "synthetic-fixture", TELEGRAM_ALERTS_CHAT_ID: "-100123" }

describe("Telegram health alerts", () => {
  test("sends plain text to Telegram and requires its acknowledgement", async () => {
    const requests: Array<{ url: string; init: RequestInit }> = []
    const send = createTelegramAlertSender({
      environment,
      fetch: async (url, init) => {
        requests.push({ url, init })
        return Response.json({ ok: true })
      },
    })
    await send("DB DOWN")
    expect(requests).toHaveLength(1)
    expect(requests[0]?.url).toBe("https://api.telegram.org/botsynthetic-fixture/sendMessage")
    expect(requests[0]?.init.method).toBe("POST")
    expect(requests[0]?.init.redirect).toBe("error")
    expect(requests[0]?.init.signal).toBeInstanceOf(AbortSignal)
    expect(JSON.parse(String(requests[0]?.init.body))).toEqual({ chat_id: "-100123", text: "DB DOWN" })
  })

  test("accepts the existing TELEGRAM_TOKEN configuration", async () => {
    let requestedUrl = ""
    const send = createTelegramAlertSender({
      environment: { TELEGRAM_TOKEN: "synthetic-legacy", TELEGRAM_ALERTS_CHAT_ID: "123" },
      fetch: async (url) => { requestedUrl = url; return Response.json({ ok: true }) },
    })
    await send("DB RECOVERED")
    expect(requestedUrl).toBe("https://api.telegram.org/botsynthetic-legacy/sendMessage")
  })

  test.each([
    { status: 500, body: { ok: true } },
    { status: 200, body: { ok: false, description: "synthetic-private-provider-error" } },
    { status: 200, body: { ok: "true" } },
    { status: 200, body: null },
  ])("rejects unacknowledged responses (%j)", async ({ status, body }) => {
    const send = createTelegramAlertSender({ environment, fetch: async () => Response.json(body, { status }) })
    await expect(send("DB DOWN")).rejects.toThrow("Telegram alert delivery failed.")
  })

  test("discards malformed JSON and raw fetch errors without preserving a credential-bearing cause", async () => {
    for (const fetchAlert of [
      async () => new Response("malformed-json"),
      async () => { throw new Error("https://api.telegram.org/botsynthetic-private/sendMessage") },
    ]) {
      const send = createTelegramAlertSender({ environment, fetch: fetchAlert })
      let failure: unknown
      try { await send("DB DOWN") } catch (error) { failure = error }
      expect(failure).toBeInstanceOf(Error)
      expect(String(failure)).toBe("Error: Telegram alert delivery failed.")
      expect(failure).not.toHaveProperty("cause")
    }
  })

  test("bounds an unresponsive fetch and aborts its request", async () => {
    let signal: AbortSignal | null | undefined
    const send = createTelegramAlertSender({
      environment, timeoutMs: 10,
      fetch: (_url, init) => { signal = init.signal; return new Promise(() => {}) },
    })
    await expect(send("DB DOWN")).rejects.toThrow("Telegram alert delivery timed out.")
    expect(signal?.aborted).toBe(true)
  })

  test("the deadline also bounds response body parsing", async () => {
    const send = createTelegramAlertSender({
      environment, timeoutMs: 10,
      fetch: async () => ({ ok: true, json: () => new Promise(() => {}) }),
    })
    await expect(send("DB DOWN")).rejects.toThrow("Telegram alert delivery timed out.")
  })

  test("missing configuration warns safely without blocking construction or calling a provider", async () => {
    const warning = spyOn(Log.prototype, "warn").mockImplementation(() => {})
    let requests = 0
    try {
      const send = createTelegramAlertSender({
        environment: { TELEGRAM_ALERTS_BOT_TOKEN: "synthetic-private" },
        fetch: async () => { requests += 1; return Response.json({ ok: true }) },
      })
      expect(warning).toHaveBeenCalledTimes(1)
      expect(String(warning.mock.calls[0]?.[0])).toContain("TELEGRAM_ALERTS_CHAT_ID")
      expect(JSON.stringify(warning.mock.calls)).not.toContain("synthetic-private")
      await expect(send("DB DOWN")).rejects.toThrow("not configured")
      expect(requests).toBe(0)
    } finally { warning.mockRestore() }
  })
})

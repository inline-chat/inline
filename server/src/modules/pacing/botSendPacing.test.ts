import { describe, expect, test } from "bun:test"
import {
  BotSendPacer,
  botSendPacingConfigFromEnv,
  type BotSendPacingConfig,
  type BotSendPacingRule,
} from "./botSendPacing"

const config = (overrides: Partial<BotSendPacingConfig> = {}): BotSendPacingConfig => ({
  mode: "enforce",
  perChatBurst: 3,
  perChatPerSecond: 1,
  perBotBurst: 5,
  perBotPerSecond: 2,
  perBotMode: "enforce",
  ...overrides,
})

const makePacer = (overrides: Partial<BotSendPacingConfig> = {}) => {
  let now = 1_000_000
  const reports: Array<{ botUserId: number; rule: BotSendPacingRule }> = []
  const pacer = new BotSendPacer(config(overrides), () => now, (botUserId, rule) => reports.push({ botUserId, rule }))
  return {
    pacer,
    reports,
    advance: (ms: number) => {
      now += ms
    },
  }
}

describe("BotSendPacer", () => {
  test("allows a per-chat burst, then asks for the time until one token refills", () => {
    const { pacer, reports, advance } = makePacer()
    for (let index = 0; index < 3; index += 1) expect(pacer.take(7, 100)).toEqual({ allowed: true })
    const rejected = pacer.take(7, 100)
    expect(rejected).toEqual({ allowed: false, rule: "per_chat", retryAfterMs: 1000 })
    expect(reports).toEqual([{ botUserId: 7, rule: "per_chat" }])

    advance(1000)
    expect(pacer.take(7, 100)).toEqual({ allowed: true })
  })

  test("caps a bot across chats and does not spend from either budget on rejection", () => {
    const { pacer, advance } = makePacer()
    for (let chatId = 1; chatId <= 5; chatId += 1) expect(pacer.take(7, chatId).allowed).toBe(true)
    const rejected = pacer.take(7, 6)
    expect(rejected).toEqual({ allowed: false, rule: "per_bot", retryAfterMs: 500 })

    advance(500)
    // The rejected send left chat 6's own budget full.
    expect(pacer.take(7, 6)).toEqual({ allowed: true })
  })

  test("an observe-only cross-chat rule records but never rejects", () => {
    const { pacer, reports } = makePacer({ perBotMode: "observe" })
    for (let chatId = 1; chatId <= 8; chatId += 1) expect(pacer.take(7, chatId)).toEqual({ allowed: true })
    expect(reports).toEqual([{ botUserId: 7, rule: "per_bot" }])
    // The per-chat rule still enforces on its own.
    for (let index = 0; index < 3; index += 1) pacer.take(7, 100)
    expect(pacer.take(7, 100)).toMatchObject({ allowed: false, rule: "per_chat" })
  })

  test("keeps bots independent", () => {
    const { pacer } = makePacer()
    for (let index = 0; index < 3; index += 1) pacer.take(7, 100)
    expect(pacer.take(7, 100).allowed).toBe(false)
    expect(pacer.take(8, 100)).toEqual({ allowed: true })
  })

  test("observe mode records the throttle but allows the send", () => {
    const { pacer, reports } = makePacer({ mode: "observe" })
    for (let index = 0; index < 10; index += 1) expect(pacer.take(7, 100)).toEqual({ allowed: true })
    expect(reports).toEqual([{ botUserId: 7, rule: "per_chat" }])
  })

  test("off mode never throttles or reports", () => {
    const { pacer, reports } = makePacer({ mode: "off" })
    for (let index = 0; index < 50; index += 1) expect(pacer.take(7, 100)).toEqual({ allowed: true })
    expect(reports).toEqual([])
  })

  test("reports one throttled bot to Sentry at most once per ten minutes", () => {
    const { pacer, reports, advance } = makePacer()
    for (let index = 0; index < 4; index += 1) pacer.take(7, 100)
    advance(60_000)
    for (let index = 0; index < 4; index += 1) pacer.take(7, 100)
    expect(reports.length).toBe(1)
    advance(10 * 60_000)
    for (let index = 0; index < 4; index += 1) pacer.take(7, 100)
    expect(reports.length).toBe(2)
  })

  test("reads forgiving defaults and accepts tuning from env", () => {
    expect(botSendPacingConfigFromEnv({})).toEqual({
      mode: "enforce", perChatBurst: 20, perChatPerSecond: 1, perBotBurst: 60, perBotPerSecond: 2, perBotMode: "observe",
    })
    expect(botSendPacingConfigFromEnv({ BOT_SEND_PACING_PER_BOT: "enforce" }).perBotMode).toBe("enforce")
    expect(botSendPacingConfigFromEnv({ NODE_ENV: "test" }).mode).toBe("off")
    expect(botSendPacingConfigFromEnv({ NODE_ENV: "test", BOT_SEND_PACING: "enforce" }).mode).toBe("enforce")
    expect(botSendPacingConfigFromEnv({
      BOT_SEND_PACING: "observe",
      BOT_SEND_PACING_PER_CHAT_BURST: "5",
      BOT_SEND_PACING_PER_BOT_PER_SECOND: "0",
    })).toMatchObject({ mode: "observe", perChatBurst: 5, perBotPerSecond: 2 })
  })
})

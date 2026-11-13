import { describe, expect, it, vi } from "vitest"
import { Method } from "@inline-chat/realtime-sdk"
import { createInlineOutputModeResolver } from "./output-mode.js"

const BOT = 777n

function fakeClient(state: { defaultMode?: number; overrides?: Record<string, number>; fail?: boolean }) {
  return {
    invokeRaw: vi.fn(async (method: Method, input: any) => {
      if (state.fail) throw new Error("offline")
      if (method === Method.GET_AGENT_SETTINGS) {
        expect(input.getAgentSettings.botUserId).toBe(0n)
        return { oneofKind: "getAgentSettings", getAgentSettings: { settings: { botUserId: BOT, defaultOutputMode: state.defaultMode ?? 0, revision: 1n } } }
      }
      if (method === Method.GET_AGENT_PARTICIPATIONS) {
        const chatId = String(input.getAgentParticipations.peerId.type.chat.chatId)
        const override = state.overrides?.[chatId]
        return {
          oneofKind: "getAgentParticipations",
          getAgentParticipations: {
            participations: [
              // Another bot's override never applies.
              { botUserId: 9n, outputMode: 2, mode: 0, revision: 0n, date: 0n },
              ...(override !== undefined ? [{ botUserId: BOT, outputMode: override, mode: 0, revision: 0n, date: 0n }] : []),
            ],
          },
        }
      }
      return { oneofKind: undefined }
    }),
  }
}

describe("output mode resolution", () => {
  it("defaults to Detailed, follows the bot default and lets a chat override it", async () => {
    const state: { defaultMode?: number; overrides?: Record<string, number> } = {}
    const client = fakeClient(state)
    let now = 0
    const resolver = createInlineOutputModeResolver({ client: client as any, botUserId: BOT, now: () => now })
    expect(await resolver.resolve(1n)).toBe("detailed")
    state.defaultMode = 2
    state.overrides = { "2": 1 }
    now += 30_000
    expect(await resolver.resolve(1n)).toBe("friendly")
    expect(await resolver.resolve(2n)).toBe("detailed")
  })

  it("peeks only fresh cached modes, without waiting", async () => {
    const state = { defaultMode: 2 }
    const client = fakeClient(state)
    let now = 0
    const resolver = createInlineOutputModeResolver({ client: client as any, botUserId: BOT, now: () => now })
    expect(resolver.peek(1n)).toBeUndefined()
    await resolver.resolve(1n)
    expect(resolver.peek(1n)).toBe("friendly")
    expect(resolver.peek(2n)).toBeUndefined()
    now += 30_000
    expect(resolver.peek(1n)).toBeUndefined()
  })

  it("caches both reads for 30 s and shares a lookup in flight", async () => {
    const state = { defaultMode: 2 }
    const client = fakeClient(state)
    let now = 0
    const resolver = createInlineOutputModeResolver({ client: client as any, botUserId: BOT, now: () => now })
    await Promise.all([resolver.resolve(1n), resolver.resolve(1n)])
    expect(client.invokeRaw).toHaveBeenCalledTimes(2)
    state.defaultMode = 1
    now += 29_000
    expect(await resolver.resolve(1n)).toBe("friendly")
    expect(client.invokeRaw).toHaveBeenCalledTimes(2)
    now += 1_000
    expect(await resolver.resolve(1n)).toBe("detailed")
    expect(client.invokeRaw).toHaveBeenCalledTimes(4)
  })

  it("keeps the last known mode when a read fails, else Detailed", async () => {
    const state = { defaultMode: 2, overrides: { "5": 1 }, fail: true }
    const client = fakeClient(state)
    const onError = vi.fn()
    let now = 0
    const resolver = createInlineOutputModeResolver({ client: client as any, botUserId: BOT, now: () => now, onError })
    expect(await resolver.resolve(1n)).toBe("detailed")
    expect(onError).toHaveBeenCalledWith("getAgentSettings", expect.any(Error))
    state.fail = false
    now += 30_000
    expect(await resolver.resolve(1n)).toBe("friendly")
    expect(await resolver.resolve(5n)).toBe("detailed")
    state.fail = true
    now += 30_000
    expect(await resolver.resolve(1n)).toBe("friendly")
    expect(await resolver.resolve(5n)).toBe("detailed")
  })

  it("does not wait on a stalled lookup", async () => {
    const client = { invokeRaw: vi.fn(() => new Promise(() => {})) }
    const resolver = createInlineOutputModeResolver({ client: client as any, botUserId: BOT, timeoutMs: 20 })
    expect(await resolver.resolve(1n)).toBe("detailed")
  })
})

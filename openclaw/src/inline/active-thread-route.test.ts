import { describe, expect, it, vi } from "vitest"
import {
  adoptInlineActiveThread, beginInlineActiveThreadRoute, getInlineActiveThreadRoute,
  type ActiveInlineThreadRoute,
} from "./active-thread-route.js"

describe("active reply-thread handoff", () => {
  const makeRoute = (overrides: Partial<ActiveInlineThreadRoute> = {}): ActiveInlineThreadRoute => ({
    accountId: "test", sessionKey: "session", sourceChatId: 10n, sourceMessageId: 20n,
    threadReplyDelivered: false, onThreadAdopted: vi.fn(async () => {}), ...overrides,
  })
  const target = { accountId: "test", sessionKey: "session", parentChatId: 10n, parentMessageId: 20n, threadId: 30n }

  it("publishes the child only after one shared transition finishes", async () => {
    let finish!: () => void
    const pending = new Promise<void>((resolve) => { finish = resolve })
    const route = makeRoute({ onThreadAdopted: vi.fn(() => pending) })
    const end = beginInlineActiveThreadRoute(route)
    try {
      const first = adoptInlineActiveThread(target)
      const second = adoptInlineActiveThread(target)
      await Promise.resolve()
      expect(route.threadId).toBeUndefined()
      expect(route.onThreadAdopted).toHaveBeenCalledTimes(1)
      expect(getInlineActiveThreadRoute(target)?.adoption).toBeDefined()
      finish()
      await Promise.all([first, second])
      expect(route.threadId).toBe(30n)
    } finally { end() }
    expect(getInlineActiveThreadRoute(target)).toBeUndefined()
  })

  it("keeps a failed transition failed instead of exposing a half-adopted child", async () => {
    const route = makeRoute({ onThreadAdopted: vi.fn(async () => { throw new Error("drain failed") }) })
    const end = beginInlineActiveThreadRoute(route)
    try {
      await expect(adoptInlineActiveThread(target)).rejects.toThrow("drain failed")
      await expect(adoptInlineActiveThread(target)).rejects.toThrow("drain failed")
      expect(route.threadId).toBeUndefined()
      expect(route.onThreadAdopted).toHaveBeenCalledTimes(1)
    } finally { end() }
  })

  it("matches callback identity without accepting a different turn or account", async () => {
    const route = makeRoute({ sourceMessageSid: "callback:20:400" })
    const end = beginInlineActiveThreadRoute(route)
    const endOther = beginInlineActiveThreadRoute(makeRoute({ sourceMessageId: 21n }))
    try {
      expect(getInlineActiveThreadRoute(target)).toBeUndefined()
      expect(getInlineActiveThreadRoute({ ...target, sourceMessageId: "callback:20:400" })).toBe(route)
      expect(getInlineActiveThreadRoute({ ...target, sourceMessageId: "callback:20:401" })).toBeUndefined()
      await adoptInlineActiveThread({ ...target, accountId: "other" })
      await adoptInlineActiveThread({ ...target, parentChatId: 11n })
      expect(route.onThreadAdopted).not.toHaveBeenCalled()
      await adoptInlineActiveThread(target)
      expect(route.threadId).toBe(30n)
    } finally { end(); endOther() }
  })
})

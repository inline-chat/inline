import { describe, expect, it, spyOn } from "bun:test"
import { DesktopPushSuppressionTracker, type DesktopActivityStore } from "./desktopPushSuppression"
import { connectionManager } from "@in/server/ws/connections"

const fixture = () => {
  let now = 1_000
  let available = true
  const entries = new Map<string, number>()
  const store: DesktopActivityStore = {
    async record(userId, chatId) {
      if (!available) return false
      entries.set(`${userId}:${chatId}`, now + 15_000)
      return true
    },
    async has(userId, chatId) {
      if (!available) return undefined
      return (entries.get(`${userId}:${chatId}`) ?? 0) > now
    },
  }
  const desktop = new DesktopPushSuppressionTracker({
    now: () => now, store, resolveSessionClientType: () => "macos",
  })
  const ios = new DesktopPushSuppressionTracker({
    now: () => now, store, resolveSessionClientType: () => "ios",
  })
  return { desktop, ios, advance: (ms: number) => { now += ms }, disconnect: () => { available = false }, reconnect: () => { available = true } }
}

describe("desktop push suppression", () => {
  it("uses the authenticated local connection and rejects a mismatched session", async () => {
    let records = 0
    const store: DesktopActivityStore = { record: async () => { records++; return true }, has: async () => false }
    const lookup = spyOn(connectionManager, "getConnection").mockImplementation(() => ({
      userId: 7, sessionId: 11, clientType: "macos",
    }) as never)
    try {
      const tracker = new DesktopPushSuppressionTracker({ store })
      await tracker.recordChatActivity({ userId: 7, sessionId: 12, connectionId: "owned", chatId: 22 })
      await tracker.recordChatActivity({ userId: 7, sessionId: 11, connectionId: "owned", chatId: 22 })
      expect(records).toBe(1)
      expect(lookup).toHaveBeenCalledTimes(2)
    } finally { lookup.mockRestore() }
  })

  it("uses one user/chat marker for two desktops and leaves old chat until TTL", async () => {
    const { desktop, advance } = fixture()
    await desktop.recordChatActivity({ userId: 7, sessionId: 11, chatId: 22 })
    await desktop.recordChatActivity({ userId: 7, sessionId: 12, chatId: 22 })
    expect(await desktop.shouldSuppressIOSSendMessagePush({ userId: 7, chatId: 22, isUrgentNudge: false })).toEqual({ suppress: true, reason: "active_desktop_chat" })
    await desktop.recordChatActivity({ userId: 7, sessionId: 11, chatId: 23 })
    expect((await desktop.shouldSuppressIOSSendMessagePush({ userId: 7, chatId: 22, isUrgentNudge: false })).suppress).toBe(true)
    advance(15_001)
    expect((await desktop.shouldSuppressIOSSendMessagePush({ userId: 7, chatId: 22, isUrgentNudge: false })).suppress).toBe(false)
  })

  it("ignores non-macOS activity and bypasses urgent nudges", async () => {
    const { desktop, ios } = fixture()
    await ios.recordChatActivity({ userId: 7, sessionId: 30, chatId: 22 })
    expect((await ios.shouldSuppressIOSSendMessagePush({ userId: 7, chatId: 22, isUrgentNudge: false })).suppress).toBe(false)
    await desktop.recordChatActivity({ userId: 7, sessionId: 31, chatId: 22 })
    expect(await desktop.shouldSuppressIOSSendMessagePush({ userId: 7, chatId: 22, isUrgentNudge: true })).toEqual({ suppress: false, reason: "urgent_nudge" })
  })

  it("sends push when broker is unavailable and never replays a stale activity write", async () => {
    const { desktop, disconnect, reconnect, advance } = fixture()
    disconnect()
    await desktop.recordChatActivity({ userId: 7, sessionId: 11, chatId: 22 })
    expect((await desktop.shouldSuppressIOSSendMessagePush({ userId: 7, chatId: 22, isUrgentNudge: false })).suppress).toBe(false)
    advance(15_001)
    reconnect()
    expect((await desktop.shouldSuppressIOSSendMessagePush({ userId: 7, chatId: 22, isUrgentNudge: false })).suppress).toBe(false)
    expect(desktop.getMetrics().errorsTotal).toBeGreaterThan(0)
  })
})

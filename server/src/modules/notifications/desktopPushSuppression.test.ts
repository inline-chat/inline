import { beforeEach, describe, expect, it } from "bun:test"
import { DesktopPushSuppressionTracker } from "@in/server/modules/notifications/desktopPushSuppression"

describe("desktopPushSuppression", () => {
  let now = 1_000

  beforeEach(() => {
    now = 1_000
  })

  it("suppresses when same chat has fresh desktop activity", async () => {
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => "macos",
    })

    await tracker.recordChatActivity({ userId: 7, sessionId: 11, chatId: 22 })

    const decision = tracker.shouldSuppressIOSSendMessagePush({
      userId: 7,
      chatId: 22,
      isUrgentNudge: false,
    })

    expect(decision).toEqual({ suppress: true, reason: "active_desktop_chat" })

    const metrics = tracker.getMetrics()
    expect(metrics.activityRecordedTotal).toBe(1)
    expect(metrics.suppressedTotal).toBe(1)
    expect(metrics.trackedDesktopSessions).toBe(1)
    expect(metrics.trackedDesktopChatActivities).toBe(1)
  })

  it("does not suppress when activity is stale", async () => {
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => "macos",
    })

    await tracker.recordChatActivity({ userId: 1, sessionId: 1, chatId: 100 })

    now += 59_999

    expect(
      tracker.shouldSuppressIOSSendMessagePush({
        userId: 1,
        chatId: 100,
        isUrgentNudge: false,
      }),
    ).toEqual({ suppress: true, reason: "active_desktop_chat" })

    now += 2

    const decision = tracker.shouldSuppressIOSSendMessagePush({
      userId: 1,
      chatId: 100,
      isUrgentNudge: false,
    })

    expect(decision).toEqual({ suppress: false, reason: "no_recent_desktop_activity" })
  })

  it("does not suppress when activity is for a different chat", async () => {
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => "macos",
    })

    await tracker.recordChatActivity({ userId: 3, sessionId: 4, chatId: 50 })

    const decision = tracker.shouldSuppressIOSSendMessagePush({
      userId: 3,
      chatId: 51,
      isUrgentNudge: false,
    })

    expect(decision).toEqual({ suppress: false, reason: "no_recent_desktop_activity" })
  })

  it("ignores non-desktop sessions and keeps push sending", async () => {
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => "ios",
    })

    await tracker.recordChatActivity({ userId: 9, sessionId: 2, chatId: 44 })

    const decision = tracker.shouldSuppressIOSSendMessagePush({
      userId: 9,
      chatId: 44,
      isUrgentNudge: false,
    })

    expect(decision).toEqual({ suppress: false, reason: "no_recent_desktop_activity" })
    expect(tracker.getMetrics().activityIgnoredNonDesktopTotal).toBe(1)
  })

  it("fails open when session type is unknown", async () => {
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => null,
    })

    await tracker.recordChatActivity({ userId: 5, sessionId: 7, chatId: 88 })

    const decision = tracker.shouldSuppressIOSSendMessagePush({
      userId: 5,
      chatId: 88,
      isUrgentNudge: false,
    })

    expect(decision).toEqual({ suppress: false, reason: "no_recent_desktop_activity" })
    expect(tracker.getMetrics().activityIgnoredUnknownSessionTypeTotal).toBe(1)
  })

  it("never suppresses urgent nudge", async () => {
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => "macos",
    })

    await tracker.recordChatActivity({ userId: 1, sessionId: 99, chatId: 20 })

    const decision = tracker.shouldSuppressIOSSendMessagePush({
      userId: 1,
      chatId: 20,
      isUrgentNudge: true,
    })

    expect(decision).toEqual({ suppress: false, reason: "urgent_nudge" })

    const metrics = tracker.getMetrics()
    expect(metrics.allowedUrgentNudgeTotal).toBe(1)
    expect(metrics.suppressedTotal).toBe(0)
  })

  it("increments error metrics when resolver throws", async () => {
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => {
        throw new Error("resolver failure")
      },
    })

    await tracker.recordChatActivity({ userId: 1, sessionId: 99, chatId: 20 })

    expect(tracker.getMetrics().errorsTotal).toBe(1)
  })

  it("does not cache non-desktop session client type", async () => {
    let resolverCalls = 0
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      resolveSessionClientType: async () => {
        resolverCalls += 1
        return "ios"
      },
    })

    await tracker.recordChatActivity({ userId: 2, sessionId: 10, chatId: 20 })
    await tracker.recordChatActivity({ userId: 2, sessionId: 10, chatId: 20 })

    expect(resolverCalls).toBe(2)
  })

  it("caches desktop session type until activity is pruned", async () => {
    let resolverCalls = 0
    const tracker = new DesktopPushSuppressionTracker({
      now: () => now,
      activityTtlMs: 10,
      resolveSessionClientType: async () => {
        resolverCalls += 1
        return "macos"
      },
    })

    await tracker.recordChatActivity({ userId: 3, sessionId: 11, chatId: 20 })
    await tracker.recordChatActivity({ userId: 3, sessionId: 11, chatId: 20 })
    expect(resolverCalls).toBe(1)

    now += 11
    await tracker.recordChatActivity({ userId: 3, sessionId: 11, chatId: 20 })
    expect(resolverCalls).toBe(2)
  })
})

import { chatId, messageId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { ChatOpenPerformance } from "./ChatOpenPerformance"

const peer = { peerKind: "chat", peerId: chatId(42) } as const

describe("ChatOpenPerformance", () => {
  it("records native-shaped milestones as redacted relative timings", () => {
    let now = 100
    const recordMeasure = vi.fn()
    const performance = new ChatOpenPerformance({
      now: () => now,
      recordMeasure,
    })
    const traceId = performance.begin(peer, messageId(900))
    now = 103
    performance.markCacheReady(traceId)
    now = 108
    performance.markProjectionReady(traceId, {
      source: "around",
      preparedMessageCount: 60,
      promotedMediaCount: 8,
    })
    now = 112
    performance.markFirstLayout(traceId, 60)
    now = 129
    performance.markFirstPaint(traceId)

    expect(performance.get(traceId)).toEqual({
      id: traceId,
      peerKind: "chat",
      hasTargetMessage: true,
      startedAt: 100,
      cacheReadyAt: 103,
      projectionReadyAt: 108,
      firstLayoutAt: 112,
      firstPaintAt: 129,
      source: "around",
      preparedMessageCount: 60,
      promotedMediaCount: 8,
      renderedMessageCount: 60,
      outcome: "painted",
      cacheReadyMs: 3,
      projectionReadyMs: 8,
      firstLayoutMs: 12,
      firstPaintMs: 29,
    })
    expect(performance.get(traceId)).not.toHaveProperty("peerId")
    expect(performance.get(traceId)).not.toHaveProperty("targetMessageId")
    expect(recordMeasure).toHaveBeenNthCalledWith(
      4,
      "inline.chat-open.first-paint",
      29,
    )
  })

  it("keeps milestones idempotent and the trace history bounded", () => {
    let now = 0
    const performance = new ChatOpenPerformance(
      { now: () => now++ },
      2,
    )
    const first = performance.begin(peer)
    performance.markCacheReady(first)
    performance.markCacheReady(first)
    expect(performance.get(first)?.cacheReadyAt).toBe(1)

    const second = performance.begin(peer)
    const third = performance.begin(peer)
    expect(performance.get(first)).toBeUndefined()
    expect(performance.recent().map((trace) => trace.id)).toEqual([
      second,
      third,
    ])
  })

  it("preserves the first failure boundary", () => {
    const performance = new ChatOpenPerformance({ now: () => 1 })
    const traceId = performance.begin(peer)
    performance.markFailed(traceId, "cache")
    performance.markFailed(traceId, "projection")
    expect(performance.get(traceId)).toEqual(
      expect.objectContaining({
        outcome: "failed",
        failurePhase: "cache",
      }),
    )
  })
})

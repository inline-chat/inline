import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("openclaw/plugin-sdk/channel-outbound", () => ({
  createChannelMessageReplyPipeline: () => {
    throw new Error("host pipeline failed")
  },
}))

import { createChannelReplyPipelineCompat } from "./sdk-runtime-compat.js"

describe("createChannelReplyPipelineCompat fallback", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("reports the host error and keeps one keepalive across overlapping reply starts", async () => {
    vi.useFakeTimers()
    const fallbackErrors: unknown[] = []
    let releaseFirstStart: () => void = () => {}
    let startCalls = 0
    const start = vi.fn(() => {
      startCalls += 1
      if (startCalls === 1) {
        return new Promise<void>((resolve) => {
          releaseFirstStart = resolve
        })
      }
      return Promise.resolve()
    })
    const stop = vi.fn(async () => {})

    const pipeline = await createChannelReplyPipelineCompat({
      cfg: {},
      agentId: "main",
      typing: { start, stop, onStartError: () => {}, keepaliveIntervalMs: 1_000, maxDurationMs: 0 },
      onFallback: (err) => fallbackErrors.push(err),
    })
    expect(fallbackErrors).toHaveLength(1)
    expect(String(fallbackErrors[0])).toContain("host pipeline failed")

    const typing = pipeline.typingCallbacks!
    const first = typing.onReplyStart()
    const second = typing.onReplyStart()
    await second
    releaseFirstStart()
    await first

    start.mockClear()
    await vi.advanceTimersByTimeAsync(1_000)
    expect(start).toHaveBeenCalledTimes(1)

    typing.onCleanup?.()
    await vi.advanceTimersByTimeAsync(5_000)
    expect(start).toHaveBeenCalledTimes(1)
    expect(stop).toHaveBeenCalledTimes(1)
  })
})

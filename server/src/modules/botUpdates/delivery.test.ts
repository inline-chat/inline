import { describe, expect, it } from "bun:test"
import {
  BotWebhookDeliveryWorker,
  webhookRetryDelayMs,
} from "./delivery"

describe("bot webhook delivery", () => {
  it("uses bounded increasing retry delays", () => {
    const original = Math.random
    Math.random = () => 0
    try {
      expect(webhookRetryDelayMs(1)).toBe(10_000)
      expect(webhookRetryDelayMs(2)).toBe(30_000)
      expect(webhookRetryDelayMs(9)).toBeLessThanOrEqual(3_600_000)
    } finally {
      Math.random = original
    }
  })

  it("serializes polls and drains active delivery before stopping", async () => {
    let intervalCallback:
      | (() => void)
      | undefined
    let clearCount = 0
    let runs = 0
    let finishRun = (): void => {}
    const activeRun = new Promise<void>(
      (resolve) => {
        finishRun = resolve
      },
    )
    const intervalId = Symbol(
      "interval",
    ) as unknown as ReturnType<
      typeof setInterval
    >
    const worker =
      new BotWebhookDeliveryWorker({
        runOnce: async () => {
          runs += 1
          await activeRun
          return 1
        },
        setIntervalFn: ((
          handler: () => void,
        ) => {
          intervalCallback = handler
          return intervalId
        }) as typeof setInterval,
        clearIntervalFn: ((id) => {
          if (id === intervalId) {
            clearCount += 1
          }
        }) as typeof clearInterval,
      })

    expect(worker.start()).toBe(true)
    const firstPoll = worker.pollOnce()
    const secondPoll = worker.pollOnce()
    expect(firstPoll).toBe(secondPoll)
    expect(runs).toBe(1)

    let stopped = false
    const stopping = worker
      .stop()
      .then(() => {
        stopped = true
      })
    await Promise.resolve()
    expect(stopped).toBe(false)
    expect(clearCount).toBe(1)

    intervalCallback?.()
    expect(runs).toBe(1)
    finishRun()
    await stopping
    expect(stopped).toBe(true)
  })
})

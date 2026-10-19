import { describe, expect, it } from "bun:test"
import {
  BotWebhookDeliveryWorker,
  makeBotWebhookTransport,
  webhookRetryDelayMs,
} from "./delivery"

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

describe("bot webhook delivery", () => {
  it("checks delivery authority after DNS and before opening an HTTPS request", async () => {
    const steps: string[] = []
    const transport = makeBotWebhookTransport({
      resolve: async (rawUrl) => {
        steps.push("dns")
        return { url: new URL(rawUrl), address: "8.8.8.8", family: 4 }
      },
      request: () => {
        steps.push("request")
        throw new Error("synthetic request boundary")
      },
    })
    const input = { rawUrl: "https://receiver.test/webhook", body: "{}", headers: {} }
    expect(await transport({ ...input, beforeConnect: async () => { steps.push("authority"); return false } })).toBeUndefined()
    expect(steps).toEqual(["dns", "authority"])
    steps.length = 0
    await expect(transport({ ...input, beforeConnect: async () => { steps.push("authority"); return true } }))
      .rejects.toThrow("synthetic request boundary")
    expect(steps).toEqual(["dns", "authority", "request"])
  })

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

  it("backs off the delivery queries while idle and resumes on claimed work or an appended update", async () => {
    let tick: (() => void) | undefined
    let runs = 0
    let claimed = 0
    let wakeListener: (() => void) | undefined
    let unsubscribed = 0
    const worker = new BotWebhookDeliveryWorker({
      pollIntervalMs: 2_500,
      maximumIdleIntervalMs: 10_000,
      runOnce: async () => { runs += 1; return claimed },
      onWork: (listener) => { wakeListener = listener; return () => { unsubscribed += 1 } },
      setIntervalFn: ((handler: () => void, _timeout: number) => {
        tick = handler
        return Symbol("interval") as unknown as ReturnType<typeof setInterval>
      }) as typeof setInterval,
      clearIntervalFn: (() => {}) as typeof clearInterval,
    })
    expect(worker.start()).toBe(true)
    await worker.pollOnce()
    expect(runs).toBe(1)
    expect(worker.idleMultiplier).toBe(2)

    const runsPerTick: number[] = []
    for (let index = 0; index < 6; index += 1) {
      tick?.()
      await settle()
      runsPerTick.push(runs)
    }
    // Tick 2 polls with a two-interval gap; the next poll waits four intervals (the cap) until tick 6.
    expect(runsPerTick).toEqual([1, 2, 2, 2, 2, 3])
    expect(worker.idleMultiplier).toBe(4)

    // An in-process append wakes the worker for the next tick.
    wakeListener?.()
    expect(worker.idleMultiplier).toBe(1)
    tick?.()
    await settle()
    expect(runs).toBe(4)

    claimed = 1
    tick?.(); tick?.()
    await settle()
    expect(runs).toBe(5)
    expect(worker.idleMultiplier).toBe(1)
    await worker.stop()
    expect(unsubscribed).toBe(1)
  })
})

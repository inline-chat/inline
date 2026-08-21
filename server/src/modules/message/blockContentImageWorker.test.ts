import { describe, expect, test } from "bun:test"
import {
  BlockContentImageWorker,
  isBlockContentImageWorkerEnabled,
} from "./blockContentImageWorker"

describe("block content image worker lifecycle", () => {
  test("runs by default and supports an explicit emergency opt-out", () => {
    expect(isBlockContentImageWorkerEnabled(undefined)).toBe(true)
    expect(isBlockContentImageWorkerEnabled("")).toBe(true)
    expect(isBlockContentImageWorkerEnabled("1")).toBe(true)
    expect(isBlockContentImageWorkerEnabled("true")).toBe(true)
    expect(isBlockContentImageWorkerEnabled("ON")).toBe(true)
    expect(isBlockContentImageWorkerEnabled("unexpected")).toBe(true)
    expect(isBlockContentImageWorkerEnabled("0")).toBe(false)
    expect(isBlockContentImageWorkerEnabled(" false ")).toBe(false)
    expect(isBlockContentImageWorkerEnabled("OFF")).toBe(false)
  })

  test("does not schedule or run when disabled", async () => {
    let scheduled = false
    let runs = 0
    const worker = new BlockContentImageWorker({
      enabled: false,
      runOnce: async () => ++runs,
      setIntervalFn: ((_handler: () => void, _timeout: number) => {
        scheduled = true
        return Symbol("interval") as unknown as ReturnType<typeof setInterval>
      }) as typeof setInterval,
    })

    expect(worker.start()).toBe(false)
    await worker.stop()
    expect(scheduled).toBe(false)
    expect(runs).toBe(0)
  })

  test("serializes polls and awaits active work during stop", async () => {
    let intervalCallback: (() => void) | undefined
    let clearCount = 0
    let runs = 0
    let finishRun: (() => void) | undefined
    const activeRun = new Promise<void>((resolve) => {
      finishRun = resolve
    })
    const intervalId = Symbol("interval") as unknown as ReturnType<typeof setInterval>
    const worker = new BlockContentImageWorker({
      runOnce: async () => {
        runs += 1
        await activeRun
        return 1
      },
      setIntervalFn: ((handler: () => void, _timeout: number) => {
        intervalCallback = handler
        return intervalId
      }) as typeof setInterval,
      clearIntervalFn: ((id: ReturnType<typeof setInterval>) => {
        if (id === intervalId) clearCount += 1
      }) as typeof clearInterval,
    })

    expect(worker.start()).toBe(true)
    const firstPoll = worker.pollOnce()
    const secondPoll = worker.pollOnce()
    expect(firstPoll).toBe(secondPoll)
    expect(runs).toBe(1)

    let stopped = false
    const stopping = worker.stop().then(() => {
      stopped = true
    })
    await Promise.resolve()
    expect(stopped).toBe(false)
    expect(clearCount).toBe(1)

    intervalCallback?.()
    expect(runs).toBe(1)
    finishRun?.()
    await stopping
    expect(stopped).toBe(true)
    expect(runs).toBe(1)
  })
})

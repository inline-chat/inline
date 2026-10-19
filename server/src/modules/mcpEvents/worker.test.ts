import { describe, expect, test } from "bun:test"
import { McpEventsWorker } from "./worker"

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

const fakeInterval = () => {
  let tick: (() => void) | undefined
  const setIntervalFn = ((handler: () => void) => {
    tick = handler
    return Symbol("interval") as unknown as ReturnType<typeof setInterval>
  }) as typeof setInterval
  return { setIntervalFn, clearIntervalFn: (() => {}) as typeof clearInterval, tick: () => tick?.() }
}

describe("MCP events worker idle backoff", () => {
  test("doubles the ticks between polls while empty and resets once a poll finds work", async () => {
    let delivered = 0
    let runs = 0
    const timers = fakeInterval()
    let cleanups = 0
    const worker = new McpEventsWorker(async () => { runs += 1; return delivered }, {
      pollIntervalMs: 1_000, maximumIdleIntervalMs: 4_000, cleanup: async () => { cleanups += 1 }, ...timers,
    })
    worker.start()
    await worker.poll()
    expect(runs).toBe(1)
    expect(worker.idleMultiplier).toBe(2)

    const runsPerTick: number[] = []
    for (let tick = 0; tick < 8; tick += 1) {
      timers.tick()
      await settle()
      runsPerTick.push(runs)
    }
    // Polls land on tick 2 and then tick 6 once the gap is four intervals (the cap).
    expect(runsPerTick).toEqual([1, 2, 2, 2, 2, 3, 3, 3])
    expect(worker.idleMultiplier).toBe(4)
    expect(cleanups).toBe(1)

    delivered = 3
    timers.tick(); timers.tick()
    await settle()
    expect(runs).toBe(4)
    expect(worker.idleMultiplier).toBe(1)
    timers.tick()
    await settle()
    expect(runs).toBe(5)
    await worker.stop()
  })
})

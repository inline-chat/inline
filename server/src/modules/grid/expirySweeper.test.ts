import { describe, expect, test } from "bun:test"
import { GridExpirySweeper, type GridExpirySweep } from "./expirySweeper"

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

function harness(script: Array<GridExpirySweep | Error | Promise<GridExpirySweep>>) {
  const clock = { now: 1_000_000 }
  let timer: { handler: () => void; at: number } | undefined
  let listener: (() => void) | undefined
  const probes: number[] = []
  const sweeper = new GridExpirySweeper({
    sweep: async () => {
      probes.push(clock.now)
      const next = script.shift() ?? { status: "idle" }
      if (next instanceof Error) throw next
      return await next
    },
    subscribe: (handler) => {
      listener = handler
      return () => {
        listener = undefined
      }
    },
    now: () => clock.now,
    setTimeoutFn: (handler, timeout) => {
      timer = { handler, at: clock.now + timeout }
      return Symbol("timer") as unknown as ReturnType<typeof setTimeout>
    },
    clearTimeoutFn: () => {
      timer = undefined
    },
  })
  return {
    clock,
    probes,
    sweeper,
    /** Committed Grid change, here or hinted from another node. */
    change: () => listener?.(),
    subscribed: () => listener !== undefined,
    /** Gap from now to the armed probe, or null while dormant. */
    gap: () => (sweeper.nextSweepAt === null ? null : sweeper.nextSweepAt - clock.now),
    async fire() {
      if (!timer) throw new Error("No probe is armed")
      const armed = timer
      timer = undefined
      clock.now = armed.at
      armed.handler()
      await settle()
    },
  }
}

describe("grid expiry sweeper scheduling", () => {
  test("an idle instance probes once at start, then makes no queries until a Grid change", async () => {
    const h = harness([{ status: "idle" }])
    h.sweeper.start()
    await settle()
    expect(h.probes).toHaveLength(1)
    expect(h.gap()).toBeNull()

    h.clock.now += 24 * 60 * 60_000
    await settle()
    expect(h.probes).toHaveLength(1)

    h.change()
    h.change()
    expect(h.gap()).toBe(2_000)
    await h.fire()
    expect(h.probes).toHaveLength(2)
    expect(h.gap()).toBeNull()
    await h.sweeper.stop()
  })

  test("sleeps until the earliest deadline and coalesces change hints into one probe", async () => {
    const start = 1_000_000
    const lease = new Date(start + 14 * 60_000)
    const h = harness([
      { status: "idle", nextDueAt: lease },
      { status: "idle", nextDueAt: lease },
      { status: "swept", expiredPresences: 1, retiredTranscriptionSpaces: 0 },
      { status: "idle" },
    ])
    h.sweeper.start()
    await settle()
    expect(h.gap()).toBe(14 * 60_000)

    h.change()
    h.change()
    h.change()
    expect(h.gap()).toBe(2_000)
    await h.fire()
    expect(h.sweeper.nextSweepAt).toBe(lease.getTime())

    await h.fire()
    // Progress re-probes promptly for the next batch or deadline.
    expect(h.gap()).toBe(1_000)
    await h.fire()
    expect(h.gap()).toBeNull()
    expect(h.probes).toEqual([start, start + 2_000, lease.getTime(), lease.getTime() + 1_000])
    await h.sweeper.stop()
  })

  test("a busy lock, a failure or untakeable due work backs off, and a clean probe resets it", async () => {
    const h = harness([
      { status: "busy" },
      new Error("database unavailable"),
      { status: "swept", expiredPresences: 0, retiredTranscriptionSpaces: 0 },
      { status: "idle", nextDueAt: new Date(1_000_000 + 60_000) },
      { status: "busy" },
    ])
    h.sweeper.start()
    await settle()
    const gaps = [h.gap()]
    for (let index = 0; index < 3; index += 1) {
      await h.fire()
      gaps.push(h.gap())
    }
    expect(gaps.slice(0, 3)).toEqual([1_000, 2_000, 4_000])
    await h.fire()
    expect(h.gap()).toBe(1_000)
    await h.sweeper.stop()
  })

  test("a change during a sweep re-probes shortly after instead of going dormant", async () => {
    const pending = Promise.withResolvers<GridExpirySweep>()
    const h = harness([pending.promise])
    h.sweeper.start()
    h.change()
    pending.resolve({ status: "idle" })
    await settle()
    expect(h.gap()).toBe(2_000)
    await h.sweeper.stop()
  })

  test("stop unsubscribes and disarms", async () => {
    const h = harness([{ status: "idle", nextDueAt: new Date(1_000_000 + 60_000) }])
    h.sweeper.start()
    await settle()
    expect(h.gap()).toBe(60_000)
    await h.sweeper.stop()
    expect(h.subscribed()).toBe(false)
    expect(h.gap()).toBeNull()
    h.sweeper.wake()
    expect(h.gap()).toBeNull()
  })
})

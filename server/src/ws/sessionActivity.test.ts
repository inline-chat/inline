import { describe, expect, it } from "bun:test"
import { SessionActivityTracker } from "./sessionActivity"

describe("SessionActivityTracker", () => {
  it("joins repeated shutdown calls and rejects restart until the final write settles", async () => {
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const tracker = new SessionActivityTracker({ write: async () => {
      entered.resolve()
      await release.promise
    } })
    tracker.activate(1)
    const first = tracker.shutdown()
    await entered.promise
    const second = tracker.shutdown()
    expect(second).toBe(first)
    expect(() => tracker.start()).toThrow("before shutdown completes")
    release.resolve()
    await second
    const generation = tracker.start()
    expect(generation).toBe(2)
    await tracker.shutdown()
  })

  it("rejects old-generation callbacks after an intentional restart", async () => {
    const batches: number[][] = []
    const tracker = new SessionActivityTracker({ write: async (ids) => { batches.push([...ids]) } })
    const oldGeneration = tracker.start()
    await tracker.shutdown(oldGeneration)
    const currentGeneration = tracker.start()
    tracker.activate(2, currentGeneration)
    tracker.activate(1, oldGeneration)
    tracker.deactivate(2, oldGeneration)
    await tracker.shutdown(oldGeneration)
    await tracker.flushNow(currentGeneration)
    expect(batches).toEqual([[2]])
    await tracker.shutdown(currentGeneration)
  })

  it("writes 1,000 active sessions in bounded, fair batches from one snapshot", async () => {
    const batches: number[][] = []
    const tracker = new SessionActivityTracker({
      maxSessionsPerWrite: 512,
      maxPendingSessions: 1_000,
      write: async (sessionIds) => { batches.push([...sessionIds]) },
    })

    try {
      for (let sessionId = 1; sessionId <= 1_000; sessionId += 1) tracker.activate(sessionId)
      await tracker.flushNow()

      expect(batches.map((batch) => batch.length)).toEqual([512, 488])
      expect(new Set(batches.flat()).size).toBe(1_000)
    } finally {
      await tracker.shutdown()
    }
  })

  it("moves marks received during a write into the next fair snapshot", async () => {
    const batches: number[][] = []
    const firstWriteStarted = Promise.withResolvers<void>()
    const releaseFirstWrite = Promise.withResolvers<void>()
    let writes = 0
    const tracker = new SessionActivityTracker({
      maxSessionsPerWrite: 2,
      maxPendingSessions: 4,
      write: async (sessionIds) => {
        writes += 1
        batches.push([...sessionIds])
        if (writes === 1) {
          firstWriteStarted.resolve()
          await releaseFirstWrite.promise
        }
      },
    })

    try {
      tracker.activate(1)
      tracker.activate(2)
      tracker.activate(3)
      const firstFlush = tracker.flushNow()
      await firstWriteStarted.promise

      tracker.mark(1)
      tracker.mark(2)
      tracker.mark(3)
      releaseFirstWrite.resolve()
      await firstFlush
      await tracker.flushNow()

      expect(batches).toEqual([[1, 2], [3], [1, 2], [3]])
    } finally {
      releaseFirstWrite.resolve()
      await tracker.shutdown()
    }
  })

  it("drops disconnected pending work, caps retained metadata, and cannot restart after shutdown", async () => {
    const tracker = new SessionActivityTracker({
      maxSessionsPerWrite: 1,
      maxPendingSessions: 2,
      write: async () => {},
    })
    const internals = tracker as unknown as {
      pendingSessions: Map<number, true>
      timer: ReturnType<typeof setInterval> | undefined
    }

    tracker.activate(1)
    tracker.activate(2)
    tracker.activate(3)
    expect([...internals.pendingSessions.keys()]).toEqual([1, 2])

    tracker.deactivate(1)
    tracker.mark(3)
    expect([...internals.pendingSessions.keys()]).toEqual([2, 3])

    await tracker.shutdown()
    tracker.activate(4)
    tracker.mark(2)
    expect(internals.pendingSessions.size).toBe(0)
    expect(internals.timer).toBeUndefined()
  })
})

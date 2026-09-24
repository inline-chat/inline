import { describe, expect, test } from "bun:test"
import { OutboundPublicationDispatcher } from "./outbound"

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((next) => { resolve = next })
  return { promise, resolve }
}

describe("outbound publication dispatcher", () => {
  test("bounds total retained work while coalescing behind an active key", async () => {
    const dispatcher = new OutboundPublicationDispatcher({ ordinaryCapacity: 2, ordinaryActive: 1 })
    const releaseFirst = deferred<void>()
    const runs: string[] = []

    expect(dispatcher.enqueue({ key: "chat:1", run: async () => {
      runs.push("first")
      await releaseFirst.promise
    }, merge: () => {} })).toBe("queued")
    await Promise.resolve()
    expect(dispatcher.enqueue({ key: "chat:1", run: async () => { runs.push("second") }, merge: () => {} })).toBe("queued")
    expect(dispatcher.enqueue({ key: "chat:1", run: async () => { runs.push("third") }, merge: () => {} })).toBe("coalesced")
    expect(dispatcher.enqueue({ key: "chat:2", run: async () => { runs.push("dropped") }, merge: () => {} })).toBe("dropped")
    expect(dispatcher.diagnostics.ordinary.retained).toBe(2)

    releaseFirst.resolve()
    await dispatcher.drain()
    expect(runs).toEqual(["first", "second"])
  })

  test("reserves critical execution while ordinary work is stalled", async () => {
    const dispatcher = new OutboundPublicationDispatcher({ ordinaryActive: 1, criticalActive: 1 })
    const releaseOrdinary = deferred<void>()
    const criticalStarted = deferred<void>()

    dispatcher.enqueue({ key: "ordinary", run: async () => { await releaseOrdinary.promise }, merge: () => {} })
    await Promise.resolve()
    dispatcher.enqueue({ priority: "critical", key: "revocation", run: async () => { criticalStarted.resolve() }, merge: () => {} })

    await criticalStarted.promise
    releaseOrdinary.resolve()
    await dispatcher.drain()
  })

  test("stops new admission and drains the work it already owns", async () => {
    const dispatcher = new OutboundPublicationDispatcher({ ordinaryActive: 1 })
    const release = deferred<void>()
    dispatcher.enqueue({ key: "committed", run: async () => { await release.promise }, merge: () => {} })
    await Promise.resolve()
    dispatcher.stopAdmission()
    expect(dispatcher.enqueue({ key: "new", run: async () => {}, merge: () => {} })).toBe("stopped")

    let drained = false
    const draining = dispatcher.drain().then(() => { drained = true })
    await Promise.resolve()
    expect(drained).toBe(false)
    release.resolve()
    await draining
    expect(dispatcher.diagnostics.ordinary.retained).toBe(0)
  })
})

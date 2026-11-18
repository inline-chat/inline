import { afterEach, describe, expect, it } from "vitest"
import { ProtocolClient } from "../realtime/client/protocol-client"
import { ConnectionManager } from "../realtime/connection/connection-manager"
import { ScriptedTransport } from "./scripted-transport"
import { DEFAULT_START_MS, VirtualClock, useFakeTime, type FakeTime } from "./virtual-clock"

describe("VirtualClock (injected)", () => {
  it("runs due timers in deadline order, ties in scheduling order", async () => {
    const clock = new VirtualClock()
    const fired: string[] = []
    clock.setTimeout(() => fired.push("b@20"), 20)
    clock.setTimeout(() => fired.push("a@10"), 10)
    clock.setTimeout(() => fired.push("c@20"), 20)
    const cancelled = clock.setTimeout(() => fired.push("never"), 15)
    clock.clearTimeout(cancelled)

    await clock.advance(19)
    expect(fired).toEqual(["a@10"])
    expect(clock.now()).toBe(DEFAULT_START_MS + 19)

    await clock.advance(1)
    expect(fired).toEqual(["a@10", "b@20", "c@20"])
  })

  it("lets promise chains started by a timer finish before the next timer", async () => {
    const clock = new VirtualClock()
    const fired: string[] = []
    clock.setTimeout(() => {
      void Promise.resolve()
        .then(() => Promise.resolve())
        .then(() => fired.push("chain done"))
    }, 5)
    clock.setTimeout(() => fired.push("second timer"), 5)
    await clock.runAll()
    expect(fired).toEqual(["chain done", "second timer"])
  })
})

describe("useFakeTime (global timers)", () => {
  let time: FakeTime | undefined
  afterEach(() => {
    time?.dispose()
    time = undefined
  })

  /**
   * The connection manager schedules its backoff with the global
   * `setTimeout`. Under fake time its attempts land at exact virtual times.
   */
  it("makes reconnect backoff deterministic", async () => {
    time = useFakeTime()
    const transport = new ScriptedTransport({ connectPolicy: "refuse" })
    const session = new ProtocolClient({
      transport,
      getConnectionInit: () => ({ token: "token", layer: 2 }),
    })
    const connection = new ConnectionManager({
      session,
      backoffDelayMs: (attempt) => attempt * 1_000,
    })
    const attempts: number[] = []
    const start = time.now()
    const originalStart = transport.start.bind(transport)
    transport.start = async () => {
      attempts.push(time!.now() - start)
      await originalStart()
    }

    await connection.start()
    await time.advance(10_000)
    // Attempt n waits n seconds after the previous refusal.
    expect(attempts).toEqual([0, 1_000, 3_000, 6_000, 10_000])

    transport.connectPolicy = "accept"
    await time.runUntil(() => connection.state === "authenticating", { stepMs: 1_000 })
    expect(time.now() - start).toBe(15_000)
    await connection.stop()
  })
})

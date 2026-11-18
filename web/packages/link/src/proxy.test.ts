import type { Command, CoreEndpoint, CoreMessage, CoreMessageListener, Intent, Patch } from "@inline/core-protocol"
import { CoreProxy, multiplexEndpoint } from "@inline/link"
import { FakeCore, FakeDurable, RecordingUi } from "@inline/link/testing"
import { describe, expect, it } from "vitest"

type ChatId = Extract<Intent, { kind: "sendText" }>["chatId"]
const chat = "5" as ChatId
const windowQuery = { kind: "chatWindow", chatId: chat, anchor: "latest" } as const

const send = (tx: string): Command => ({
  kind: "intent",
  tx,
  intent: { kind: "sendText", chatId: chat, clientKey: tx, text: tx },
})

const flush = () => new Promise<void>((resolve) => setImmediate(resolve))

/** The far side of a route, driven by the test. */
class ScriptedRoute implements CoreEndpoint {
  readonly posted: Command[] = []
  private readonly listeners = new Set<CoreMessageListener>()
  closed = false
  post(command: Command) {
    this.posted.push(command)
  }
  subscribe(listener: CoreMessageListener) {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }
  close() {
    this.closed = true
  }
  emit(message: CoreMessage) {
    for (const listener of Array.from(this.listeners)) listener(message)
  }
  patch(base: number, body: Partial<Patch> = {}) {
    this.emit({
      kind: "patch",
      patch: { base, revision: base + 1, rows: [], lists: [], resources: [], settled: [], ...body },
    })
  }
}

const proxy = () => new CoreProxy({ buildId: "build-1" })

describe("proxy", () => {
  it("withholds a patch whose base is not the last revision, resyncs, and delivers the snapshot", () => {
    const p = proxy()
    const ui = new RecordingUi(p)
    const route = new ScriptedRoute()
    p.attach(route)
    p.post({ kind: "subscribe", sub: 1, query: windowQuery })

    route.patch(0, { lists: [{ sub: 1, op: "replace", keys: [] }] })
    route.patch(1)
    route.patch(3, { settled: [{ tx: "t1", status: "accepted" }] }) // revision 2 was lost
    expect(route.posted.filter((command) => command.kind === "resync")).toHaveLength(1)
    route.patch(4) // still withheld
    expect(ui.messages).toHaveLength(1)

    route.emit({
      kind: "snapshot",
      snapshot: {
        revision: 5,
        rows: [],
        lists: [{ sub: 1, keys: ["message:5:1"] }],
        resources: [],
        settled: [{ tx: "t1", status: "accepted" }],
      },
    })
    route.patch(5, { lists: [{ sub: 1, op: "splice", index: 1, remove: 0, insert: ["message:5:2"] }] })

    expect(ui.errors).toEqual([])
    expect(ui.snapshots).toBe(1)
    expect(ui.list(1)).toEqual(["message:5:1", "message:5:2"])
    // The result inside the withheld patch arrives with the snapshot.
    expect(ui.settledFor("t1")).toEqual(["accepted"])
    expect(p.pendingIntents()).toEqual([])
  })

  it("replays subscriptions, resyncs and re-sends unaccepted intents on a new route", async () => {
    const durable = new FakeDurable()
    const first = multiplexEndpoint(new FakeCore(durable))
    const p = proxy()
    const ui = new RecordingUi(p)
    p.attach(first.open("tab"))
    p.post({ kind: "hello", buildId: "build-1", protocol: 0 })
    p.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    p.post({ kind: "subscribe", sub: 2, query: windowQuery })
    p.post({ kind: "signal", signal: { kind: "online", online: true } })
    p.post(send("t1"))
    await flush()
    expect(ui.settledFor("t1")).toEqual(["accepted"])

    // The core goes away. Commands posted meanwhile wait.
    p.detach()
    void first.close()
    p.post(send("t2"))
    p.post({ kind: "subscribe", sub: 3, query: { kind: "core" } })
    p.post({ kind: "unsubscribe", sub: 3 })
    expect(p.pendingIntents()).toEqual(["t2"])

    const secondCore = new FakeCore(durable)
    p.attach(multiplexEndpoint(secondCore).open("tab"))
    await flush()

    expect(secondCore.received.map((command) => command.kind)).toEqual([
      "hello",
      "signal",
      "subscribe",
      "subscribe",
      "resync",
      "intent",
    ])
    expect(secondCore.commandsOf("intent").map((command) => command.tx)).toEqual(["t2"])
    expect(ui.errors).toEqual([])
    expect(ui.snapshots).toBe(1)
    expect(ui.phase(1)).toBe("ready")
    expect(ui.list(2)).toHaveLength(2)
    expect(ui.settledFor("t2")).toEqual(["accepted"])
    expect(durable.applied).toEqual(["t1", "t2"])
  })

  it("applies an intent once when the old core committed it but its result was lost", async () => {
    const durable = new FakeDurable()
    const firstCore = new FakeCore(durable)
    const p = proxy()
    const ui = new RecordingUi(p)
    p.attach(multiplexEndpoint(firstCore).open("tab"))
    p.post({ kind: "subscribe", sub: 1, query: windowQuery })
    await flush()
    // The core commits, then dies before its result is delivered.
    firstCore.mute()
    p.post(send("t1"))
    await flush()
    firstCore.kill()
    expect(durable.applied).toEqual(["t1"])
    expect(ui.settledFor("t1")).toEqual([])
    p.detach()

    const secondCore = new FakeCore(durable)
    p.attach(multiplexEndpoint(secondCore).open("tab"))
    await flush()

    expect(secondCore.commandsOf("intent")).toHaveLength(1)
    expect(durable.applied).toEqual(["t1"])
    expect(ui.settledFor("t1")).toEqual(["accepted"])
    expect(ui.list(1)).toHaveLength(1)
    expect(p.pendingIntents()).toEqual([])
  })

  it("routes trimWindow only while attached and never replays it", () => {
    const p = proxy()
    const first = new ScriptedRoute()
    p.attach(first)
    p.post({ kind: "subscribe", sub: 1, query: windowQuery })
    const trim: Command = { kind: "trimWindow", sub: 1, keep: { from: "1", to: "9" } as never }
    p.post(trim)
    expect(first.posted.at(-1)).toEqual(trim)
    p.detach()
    p.post(trim)
    const second = new ScriptedRoute()
    p.attach(second)
    expect(second.posted.some((command) => command.kind === "trimWindow")).toBe(false)
  })

  it("reports a core that cannot start on core subscriptions, and clears it when one attaches", () => {
    const p = proxy()
    const ui = new RecordingUi(p)
    p.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    p.post({ kind: "subscribe", sub: 2, query: windowQuery })
    p.reportFailure("Inline could not start in this tab.")
    p.reportFailure("Inline could not start in this tab.")
    expect(ui.phase(1)).toBe("failed")
    expect(ui.resources.get(1)).toMatchObject({ failure: "Inline could not start in this tab." })
    expect(ui.resources.get(2)).toBeUndefined()
    expect(ui.messages).toHaveLength(1)
    // A core subscription made while failed sees the failure at once.
    p.post({ kind: "subscribe", sub: 3, query: { kind: "core" } })
    expect(ui.phase(3)).toBe("failed")

    const route = new ScriptedRoute()
    p.attach(route)
    route.patch(0, {
      resources: [
        { sub: 1, value: { kind: "core", phase: "ready", connection: "connected", storage: "persistent", buildId: "b" } },
      ],
    })
    expect(ui.phase(1)).toBe("ready")
    expect(ui.resources.get(1)).not.toHaveProperty("failure")
    expect(ui.errors).toEqual([])
  })

  it("shows each status of a tx once, and never an older one after a newer one", () => {
    const p = proxy()
    const ui = new RecordingUi(p)
    const route = new ScriptedRoute()
    p.attach(route)
    p.post(send("t1"))
    route.patch(0, { settled: [{ tx: "t1", status: "accepted" }] })
    route.patch(1, { settled: [{ tx: "t1", status: "accepted" }] })
    route.patch(2, { settled: [{ tx: "t1", status: "confirmed" }] })
    route.patch(3, { settled: [{ tx: "t1", status: "accepted" }] })
    expect(ui.settledFor("t1")).toEqual(["accepted", "confirmed"])
    expect(ui.errors).toEqual([])
  })

  it("reports superseded on core subscriptions and then stops", () => {
    const p = proxy()
    const ui = new RecordingUi(p)
    const route = new ScriptedRoute()
    p.attach(route)
    p.post({ kind: "subscribe", sub: 4, query: { kind: "core" } })
    route.patch(0, {
      resources: [
        {
          sub: 4,
          value: { kind: "core", phase: "ready", connection: "connected", storage: "persistent", buildId: "build-1" },
        },
      ],
    })
    p.supersede()
    expect(ui.phase(4)).toBe("superseded")
    expect(ui.resources.get(4)).toMatchObject({ connection: "connected" })
    expect(route.closed).toBe(true)
    p.post(send("t9"))
    expect(route.posted.some((command) => command.kind === "intent")).toBe(false)
    expect(ui.errors).toEqual([])
  })
})

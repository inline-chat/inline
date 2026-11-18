import type { Command, Intent } from "@inline/core-protocol"
import type { PortLike } from "@inline/link"
import { connectCarrier, serveCore } from "@inline/link"
import { FakeCore, FakeDurable, RecordingUi } from "@inline/link/testing"
import { describe, expect, it } from "vitest"

type ChatId = Extract<Intent, { kind: "sendText" }>["chatId"]
const chat = "11" as ChatId

const send = (tx: string, text: string): Command => ({
  kind: "intent",
  tx,
  intent: { kind: "sendText", chatId: chat, clientKey: tx, text },
})

/** Waits for real port deliveries (macrotasks) without timers. */
const until = async (condition: () => boolean, turns = 2_000) => {
  for (let i = 0; i < turns; i++) {
    if (condition()) return
    await new Promise<void>((resolve) => setImmediate(resolve))
  }
  throw new Error("condition not reached")
}

const pair = () => {
  // A real MessageChannel: every message is structured-cloned across it.
  const channel = new MessageChannel()
  return { core: channel.port1 as unknown as PortLike, ui: channel.port2 as unknown as PortLike, channel }
}

describe("worker carrier", () => {
  it("round-trips commands and patches in order across a real port", async () => {
    const ports = pair()
    const durable = new FakeDurable()
    serveCore(ports.core, () => new FakeCore(durable))
    const handle = connectCarrier(ports.ui)
    const endpoint = handle.open("tab-a")
    const ui = new RecordingUi(endpoint)

    endpoint.post({ kind: "hello", buildId: "build-1", protocol: 0 })
    endpoint.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    endpoint.post({ kind: "subscribe", sub: 2, query: { kind: "chatWindow", chatId: chat, anchor: "latest" } })
    const txs = Array.from({ length: 25 }, (_, i) => `tx-${i}`)
    for (const tx of txs) endpoint.post(send(tx, `message ${tx}`))

    await until(() => ui.settled.length === txs.length)

    const core = durable.cores[0]!
    expect(core.received.map((command) => command.kind)).toEqual([
      "hello",
      "subscribe",
      "subscribe",
      ...txs.map(() => "intent"),
    ])
    expect(core.commandsOf("intent").map((command) => command.tx)).toEqual(txs)
    expect(ui.settled.map((result) => result.tx)).toEqual(txs)
    expect(ui.errors).toEqual([])
    expect(ui.messages[0]).toMatchObject({ kind: "hello", buildId: "build-1" })
    expect(ui.phase(1)).toBe("ready")
    expect(ui.list(2)).toHaveLength(txs.length)
    expect(durable.applied).toEqual(txs)

    await handle.shutdown()
    ports.channel.port1.close()
  })

  it("keeps two contexts on one port apart", async () => {
    const ports = pair()
    const durable = new FakeDurable()
    serveCore(ports.core, () => new FakeCore(durable))
    const handle = connectCarrier(ports.ui)
    const a = handle.open("a")
    const b = handle.open("b")
    const uiA = new RecordingUi(a)
    const uiB = new RecordingUi(b)

    a.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chat, anchor: "latest" } })
    b.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    a.post(send("tx-a", "from a"))
    await until(() => uiA.settled.length === 1)
    await until(() => uiB.phase(1) === "ready")

    expect(uiA.list(1)).toHaveLength(1)
    expect(uiB.list(1)).toBeUndefined()
    expect(uiB.settled).toEqual([])
    expect(uiA.errors).toEqual([])
    expect(uiB.errors).toEqual([])

    await handle.shutdown()
  })

  it("shuts down cleanly: contexts and core closed, port closed, later posts ignored", async () => {
    const ports = pair()
    const durable = new FakeDurable()
    const served = serveCore(ports.core, () => new FakeCore(durable))
    const handle = connectCarrier(ports.ui)
    const endpoint = handle.open("a")
    endpoint.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    let exited = false
    handle.onExit(() => {
      exited = true
    })

    await handle.shutdown()
    const core = durable.cores[0]!
    expect(core.closed).toBe(true)
    expect(core.commandsOf("subscribe")).toHaveLength(1)
    expect(core.commandsOf("unsubscribe")).toHaveLength(1)
    endpoint.post({ kind: "resync" })
    await served.close()
    expect(core.received.at(-1)?.kind).toBe("unsubscribe")
    expect(exited).toBe(false)
  })

  it("reports a core that fails to start as an exit", async () => {
    const ports = pair()
    serveCore(ports.core, () => {
      throw new Error("storage unavailable")
    })
    const handle = connectCarrier(ports.ui)
    let reason: string | undefined
    handle.onExit((value) => {
      reason = value
    })
    await until(() => reason !== undefined)
    expect(reason).toBe("storage unavailable")
    ports.channel.port1.close()
  })
})

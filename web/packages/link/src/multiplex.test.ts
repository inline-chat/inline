import type { Command, Intent, MessageRow } from "@inline/core-protocol"
import { multiplexEndpoint } from "@inline/link"
import { FakeCore, FakeDurable, RecordingUi } from "@inline/link/testing"
import { Log } from "@inline/log"
import { describe, expect, it } from "vitest"

type ChatId = Extract<Intent, { kind: "sendText" }>["chatId"]
const chatA = "1" as ChatId
const chatB = "2" as ChatId

const send = (tx: string, chatId: ChatId): Command => ({
  kind: "intent",
  tx,
  intent: { kind: "sendText", chatId, clientKey: tx, text: tx },
})

const flush = () => new Promise<void>((resolve) => setImmediate(resolve))

const setup = () => {
  const durable = new FakeDurable()
  const core = new FakeCore(durable)
  const contexts = multiplexEndpoint(core, { log: new Log("Link", { sink: false }) })
  return { durable, core, contexts }
}

describe("multiplexer", () => {
  it("isolates two contexts that use the same sub IDs, each with its own contiguous revisions", async () => {
    const { core, contexts } = setup()
    const a = contexts.open("a")
    const b = contexts.open("b")
    const uiA = new RecordingUi(a)
    const uiB = new RecordingUi(b)

    a.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chatA, anchor: "latest" } })
    b.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chatB, anchor: "latest" } })
    b.post({ kind: "subscribe", sub: 2, query: { kind: "core" } })
    await flush()
    a.post(send("tx-a1", chatA))
    a.post(send("tx-a2", chatA))
    b.post(send("tx-b1", chatB))
    await flush()

    // The core saw three distinct subs.
    expect(new Set(core.commandsOf("subscribe").map((command) => command.sub)).size).toBe(3)
    expect(uiA.list(1)).toHaveLength(2)
    expect(uiB.list(1)).toHaveLength(1)
    expect(uiA.list(2)).toBeUndefined()
    expect(uiB.phase(2)).toBe("ready")
    expect(uiA.settled.map((result) => result.tx)).toEqual(["tx-a1", "tx-a2"])
    expect(uiB.settled.map((result) => result.tx)).toEqual(["tx-b1"])
    expect(uiA.errors).toEqual([])
    expect(uiB.errors).toEqual([])
    // Each context's revisions count only what it received, from 0.
    const patches = (ui: RecordingUi) =>
      ui.messages.flatMap((message) => (message.kind === "patch" ? [message.patch] : []))
    expect(patches(uiA)[0]?.base).toBe(0)
    expect(patches(uiB)[0]?.base).toBe(0)

    // Unsubscribing a's sub 1 leaves b's sub 1 alone.
    a.post({ kind: "unsubscribe", sub: 1 })
    await flush()
    core.receiveMessage({
      kind: "message",
      id: "2:99",
      chatId: chatB,
      fromId: "8" as MessageRow["fromId"],
      out: false,
      date: 1,
      text: "hi",
      state: "sent",
    })
    await flush()
    expect(uiB.list(1)).toHaveLength(2)
    expect(uiA.list(1)).toHaveLength(2)
  })

  it("routes a resync snapshot to the asking context only, filtered to its subs", async () => {
    const { contexts } = setup()
    const a = contexts.open("a")
    const b = contexts.open("b")
    const uiA = new RecordingUi(a)
    const uiB = new RecordingUi(b)
    a.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    b.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chatB, anchor: "latest" } })
    await flush()

    a.post({ kind: "resync" })
    await flush()
    expect(uiA.snapshots).toBe(1)
    expect(uiB.snapshots).toBe(0)
    const snapshot = uiA.messages.at(-1)
    expect(snapshot?.kind).toBe("snapshot")
    if (snapshot?.kind !== "snapshot") return
    expect(snapshot.snapshot.resources.map((resource) => resource.sub)).toEqual([1])
    expect(snapshot.snapshot.lists).toEqual([])

    // The stream continues contiguously after the snapshot.
    a.post({ kind: "subscribe", sub: 2, query: { kind: "chatWindow", chatId: chatA, anchor: "latest" } })
    await flush()
    expect(uiA.errors).toEqual([])
    expect(uiA.list(2)).toEqual([])
  })

  it("resyncs every context when the core's own stream has a gap", async () => {
    const { core, contexts } = setup()
    const uiA = new RecordingUi(contexts.open("a"))
    const b = contexts.open("b")
    const uiB = new RecordingUi(b)
    b.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chatB, anchor: "latest" } })
    await flush()
    core.skipRevision()
    b.post(send("tx-b1", chatB))
    await flush()
    expect(core.commandsOf("resync")).toHaveLength(1)
    expect(uiB.snapshots).toBe(1)
    expect(uiB.list(1)).toHaveLength(1)
    // The patch is still routed, and the snapshot restates the latest result
    // (the proxy, not the multiplexer, drops the repeat).
    expect(uiB.settledFor("tx-b1")).toEqual(["accepted", "accepted"])
    expect(uiA.snapshots).toBe(1)
  })

  it("gives a late context the rows the core already published", async () => {
    const { contexts } = setup()
    const a = contexts.open("a")
    a.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chatA, anchor: "latest" } })
    a.post(send("tx-1", chatA))
    await flush()
    const b = contexts.open("b")
    const uiB = new RecordingUi(b)
    b.post({ kind: "hello", buildId: "x", protocol: 0 })
    await flush()
    expect(uiB.rows.size).toBe(1)
    expect(uiB.errors).toEqual([])
  })

  it("aggregates visibility: visible while any context is", async () => {
    const { core, contexts } = setup()
    const a = contexts.open("a")
    const b = contexts.open("b")
    const visibility = () =>
      core
        .commandsOf("signal")
        .flatMap((command) => (command.signal.kind === "visibility" ? [command.signal.visible] : []))
    a.post({ kind: "signal", signal: { kind: "visibility", visible: true } })
    b.post({ kind: "signal", signal: { kind: "visibility", visible: false } })
    a.post({ kind: "signal", signal: { kind: "visibility", visible: false } })
    b.post({ kind: "signal", signal: { kind: "visibility", visible: true } })
    b.close()
    expect(visibility()).toEqual([true, false, true, false])
  })

  it("answers hello once from the core and caches it for later contexts", async () => {
    const { core, contexts } = setup()
    const uiA = new RecordingUi(contexts.open("a"))
    const a = contexts.open("a2")
    const uiA2 = new RecordingUi(a)
    a.post({ kind: "hello", buildId: "b", protocol: 0 })
    await flush()
    const c = contexts.open("c")
    const uiC = new RecordingUi(c)
    c.post({ kind: "hello", buildId: "b", protocol: 0 })
    expect(core.commandsOf("hello")).toHaveLength(1)
    expect(uiA2.messages.filter((message) => message.kind === "hello")).toHaveLength(1)
    expect(uiC.messages.filter((message) => message.kind === "hello")).toHaveLength(1)
    expect(uiA.messages).toEqual([])
  })

  it("rewrites trimWindow's sub per context and drops it for an unknown sub", async () => {
    const { core, contexts } = setup()
    const a = contexts.open("a")
    const b = contexts.open("b")
    a.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chatA, anchor: "latest" } })
    b.post({ kind: "subscribe", sub: 1, query: { kind: "chatWindow", chatId: chatB, anchor: "latest" } })
    const keep = { from: "1", to: "5" } as Extract<Command, { kind: "trimWindow" }>["keep"]
    b.post({ kind: "trimWindow", sub: 1, keep })
    b.post({ kind: "trimWindow", sub: 7, keep })
    const bSub = core.commandsOf("subscribe")[1]!.sub
    expect(core.commandsOf("trimWindow")).toEqual([{ kind: "trimWindow", sub: bSub, keep }])
  })

  it("unsubscribes a closed context's subs and closes the core on close", async () => {
    const { core, contexts } = setup()
    const a = contexts.open("a")
    a.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    a.post({ kind: "subscribe", sub: 2, query: { kind: "core" } })
    a.close()
    await flush()
    expect(core.commandsOf("unsubscribe")).toHaveLength(2)
    expect(core.subs.size).toBe(0)
    await contexts.close()
    expect(core.closed).toBe(true)
  })
})

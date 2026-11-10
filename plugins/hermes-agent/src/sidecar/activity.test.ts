import { describe, expect, it } from "vitest"
import type { Doc, ProgressTransport } from "../vendor/agent-activity/index.js"

import { ActivityHub, firstMessageId, parseActivityEvent, randomMessageId, type OutputModeSettings } from "./activity.js"
import type { Target } from "./contract.js"

type Call = { op: "send" | "edit"; target: string; id: bigint; doc: Doc }

function harness(options: { settings?: (target: Target) => Promise<OutputModeSettings>; now?: () => number } = {}) {
  const calls: Call[] = []
  const reads: string[] = []
  const errors: string[] = []
  let next = 500n
  const hub = new ActivityHub({
    transportFor: (target): ProgressTransport => ({
      async send(doc) {
        const id = next++
        calls.push({ op: "send", target: key(target), id, doc })
        return id
      },
      async edit(id, doc) {
        calls.push({ op: "edit", target: key(target), id, doc })
      },
    }),
    readMode: async (target) => {
      reads.push(key(target))
      return options.settings ? options.settings(target) : {}
    },
    onError: (_error, operation) => errors.push(operation),
    ...(options.now ? { now: options.now } : {}),
  })
  return { hub, calls, reads, errors }
}

const key = (target: Target) => ("chatId" in target ? `chat:${target.chatId}` : `user:${target.userId}`)
const chat: Target = { chatId: 10n }

describe("ActivityHub", () => {
  it("draws a Detailed turn with block content and closes it before the answer", async () => {
    const { hub, calls } = harness()
    expect(await hub.apply("t1", chat, { type: "turn.start" }, { at: 1_000 })).toEqual({ mode: "detailed" })
    await hub.apply("t1", chat, {
      type: "item", id: "tool:1", state: "running", body: { kind: "command", command: "npm test" },
    }, { at: 2_000 })
    await hub.apply("t1", chat, {
      type: "item", id: "tool:1", state: "done", durationMs: 4_000,
      body: { kind: "command", command: "npm test", output: "ok", exitCode: 0 },
    }, { at: 6_000 })
    await hub.apply("t1", chat, { type: "turn.end", outcome: "success" }, { at: 10_000 })
    await hub.flush("t1")

    expect(calls[0]?.op).toBe("send")
    expect(calls[0]?.doc.text).toContain("Working")
    expect(calls[0]?.doc.blockContent.blocks.length).toBeGreaterThan(0)
    const last = calls.at(-1)!
    expect(last.op).toBe("edit")
    expect(last.id).toBe(calls[0]!.id)
    expect(last.doc.text).toContain("Worked for 9s")
    expect(last.doc.text).toContain("Ran npm test")
    // The turn is forgotten once its last edit landed; late events are ignored.
    await Promise.resolve()
    expect(hub.size).toBe(0)
    expect(await hub.apply("t1", chat, { type: "commentary", text: "late" })).toEqual({ ignored: true })
  })

  it("keeps no stream in Friendly and ignores its events", async () => {
    const { hub, calls } = harness({ settings: async () => ({ defaultMode: 2 }) })
    expect(await hub.apply("t1", chat, { type: "turn.start" })).toEqual({ mode: "friendly" })
    expect(await hub.apply("t1", chat, { type: "commentary", text: "hello" })).toEqual({ mode: "friendly" })
    await hub.apply("t1", chat, { type: "turn.end", outcome: "success" })
    await hub.flush("t1")
    expect(calls).toEqual([])
  })

  it("prefers the chat override over the bot default and caches per chat", async () => {
    let now = 0
    const { hub, reads } = harness({
      now: () => now,
      settings: async (target) => ("chatId" in target && target.chatId === 11n ? { defaultMode: 2, override: 1 } : { defaultMode: 2 }),
    })
    expect(await hub.apply("a", { chatId: 11n }, { type: "turn.start" })).toEqual({ mode: "detailed" })
    expect(await hub.apply("b", { chatId: 12n }, { type: "turn.start" })).toEqual({ mode: "friendly" })
    expect(await hub.apply("c", { chatId: 11n }, { type: "turn.start" })).toEqual({ mode: "detailed" })
    expect(reads).toEqual(["chat:11", "chat:12"])
    now = 31_000
    await hub.apply("d", { chatId: 11n }, { type: "turn.start" })
    expect(reads).toEqual(["chat:11", "chat:12", "chat:11"])
  })

  it("falls back to the last known mode, else Detailed, when the lookup fails", async () => {
    let now = 0
    let fail = false
    const { hub, errors } = harness({
      now: () => now,
      settings: async () => {
        if (fail) throw new Error("offline")
        return { defaultMode: 2 }
      },
    })
    expect(await hub.apply("a", chat, { type: "turn.start" })).toEqual({ mode: "friendly" })
    fail = true
    now = 60_000
    expect(await hub.apply("b", chat, { type: "turn.start" })).toEqual({ mode: "friendly" })
    expect(await hub.apply("c", { chatId: 99n }, { type: "turn.start" })).toEqual({ mode: "detailed" })
    expect(errors).toEqual(["mode", "mode"])
  })

  it("falls back when the lookup is too slow", async () => {
    const hub = new ActivityHub({
      transportFor: () => ({ send: async () => 1n, edit: async () => {} }),
      readMode: () => new Promise(() => {}),
      modeTimeoutMs: 10,
    })
    expect(await hub.apply("slow", chat, { type: "turn.start" })).toEqual({ mode: "detailed" })
  })

  it("opens a lazy turn without Working until work arrives", async () => {
    const { hub, calls } = harness()
    await hub.apply("t1", chat, { type: "turn.start" }, { lazy: true })
    await hub.apply("t1", chat, { type: "turn.end", outcome: "success" })
    await hub.flush("t1")
    expect(calls).toEqual([])

    await hub.apply("t2", chat, { type: "turn.start" }, { lazy: true })
    await hub.apply("t2", chat, { type: "item", id: "x", state: "running", body: { kind: "read", path: "a.ts" } })
    await hub.flush("t2")
    expect(calls).toHaveLength(1)
  })

  it("ignores events for turns that never started", async () => {
    const { hub, calls } = harness()
    expect(await hub.apply("ghost", chat, { type: "split" })).toEqual({ ignored: true })
    await hub.flush("ghost")
    expect(calls).toEqual([])
  })
})

describe("activity wire helpers", () => {
  it("reads the message id from newMessage and updateMessageId updates", () => {
    expect(firstMessageId({ sendMessage: { updates: [{ update: { oneofKind: "updateMessageId", updateMessageId: { messageId: 7n } } }] } })).toBe(7n)
    expect(firstMessageId({ oneofKind: "sendMessage", sendMessage: { updates: [{ update: { oneofKind: "newMessage", newMessage: { message: { id: 8n } } } }] } })).toBe(8n)
    expect(firstMessageId({ sendMessage: { updates: [] } })).toBeNull()
  })

  it("draws non-zero signed 64-bit random ids", () => {
    for (let index = 0; index < 50; index += 1) {
      const id = randomMessageId()
      expect(id).not.toBe(0n)
      expect(BigInt.asIntN(64, id)).toBe(id)
    }
  })

  it("validates events from the adapter", () => {
    expect(parseActivityEvent({ type: "item", id: "a", state: "done", durationMs: 12, body: { kind: "edit", files: [{ path: "a.ts", change: "added", diff: "+x" }] } }))
      .toEqual({ type: "item", id: "a", state: "done", durationMs: 12, body: { kind: "edit", files: [{ path: "a.ts", change: "added", diff: "+x" }] } })
    expect(parseActivityEvent({ type: "item", id: "p", body: { kind: "plan", steps: [{ text: "one", status: "in_progress" }] } }))
      .toEqual({ type: "item", id: "p", body: { kind: "plan", steps: [{ text: "one", status: "in_progress" }] } })
    expect(parseActivityEvent({ type: "waiting", waiting: true })).toEqual({ type: "waiting", waiting: true })
    expect(parseActivityEvent({ type: "turn.end", outcome: "cancelled" })).toEqual({ type: "turn.end", outcome: "cancelled" })
    expect(() => parseActivityEvent({ type: "turn.end", outcome: "maybe" })).toThrow(/outcome/)
    expect(() => parseActivityEvent({ type: "item", id: "a", body: { kind: "command" } })).toThrow(/command/)
    expect(() => parseActivityEvent({ type: "item", id: "a", state: "sleeping" })).toThrow(/state/)
    expect(() => parseActivityEvent({ type: "nope" })).toThrow(/unknown/)
  })
})

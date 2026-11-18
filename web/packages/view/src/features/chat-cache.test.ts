import { describe, expect, it } from "vitest"
import type { ChatID } from "@inline/ids"
import { ChatCache } from "./chat-cache"
import { ChatModel } from "./chat-model"
import { cid, harness, mid, uid } from "./test-support"

const setup = (capacity = 2) => {
  const h = harness()
  const pinned = new Set<ChatID>()
  const created: ChatID[] = []
  const cache = new ChatCache({
    capacity,
    pinned: () => pinned,
    create: (chatId, anchor) => {
      created.push(chatId)
      return new ChatModel({
        client: h.client,
        chatId,
        userId: uid(1),
        clock: h.time,
        newClientKey: () => "77",
        ...(anchor ? { anchor } : {}),
      })
    },
  })
  const windows = () =>
    h
      .openSubs()
      .filter((query) => query.kind === "chatWindow")
      .map((query) => (query.kind === "chatWindow" ? query.chatId : undefined))
  return { ...h, cache, pinned, created, windows }
}

describe("ChatCache", () => {
  it("reuses a resident chat without subscribing again", () => {
    const s = setup()
    const first = s.cache.open(cid(1))
    first.release()
    const again = s.cache.open(cid(1))
    expect(again.model).toBe(first.model)
    expect(s.created).toEqual([cid(1)])
    expect(s.windows()).toEqual([cid(1)])
  })

  it("evicts the least recently used chat that is neither shown nor leased", () => {
    const s = setup(2)
    s.cache.open(cid(1)).release()
    s.cache.open(cid(2)).release()
    s.cache.open(cid(1)).release() // 1 is now more recent than 2
    s.cache.open(cid(3)).release()
    expect(s.cache.resident.peek()).toEqual([cid(1), cid(3)])
    expect(s.windows()).toEqual([cid(1), cid(3)])
  })

  it("never releases a chat that is open in a pane, and releases it once the pane moves on", () => {
    const s = setup(1)
    s.pinned.add(cid(1))
    const one = s.cache.open(cid(1))
    one.release()
    s.cache.open(cid(2)).release()
    s.cache.open(cid(3)).release()
    // Over capacity, but chat 1 is on screen.
    expect(s.cache.resident.peek()).toEqual([cid(1), cid(3)])
    expect(one.model.disposed).toBe(false)
    s.pinned.delete(cid(1))
    s.cache.evict()
    expect(s.cache.resident.peek()).toEqual([cid(3)])
    expect(one.model.disposed).toBe(true)
  })

  it("keeps a leased chat until the lease ends", () => {
    const s = setup(1)
    const one = s.cache.open(cid(1))
    s.cache.open(cid(2)).release()
    expect(s.cache.resident.peek()).toEqual([cid(1), cid(2)])
    one.release()
    expect(s.cache.resident.peek()).toEqual([cid(2)])
    expect(s.windows()).toEqual([cid(2)])
  })

  it("lets an evicted chat finish a send before it unsubscribes", async () => {
    const s = setup(1)
    const lease = s.cache.open(cid(1))
    const send = lease.model.send("last words", [], undefined)
    lease.release()
    s.cache.open(cid(2)).release()
    expect(s.cache.resident.peek()).toEqual([cid(2)])
    expect(lease.model.disposed).toBe(false)
    expect(s.windows()).toEqual([cid(1), cid(2)])
    s.endpoint.patch({ settled: [{ tx: send.tx, status: "accepted" }] })
    await s.flush()
    expect((await send).status).toBe("accepted")
    expect(lease.model.disposed).toBe(true)
    expect(s.windows()).toEqual([cid(2)])
  })

  it("moves a resident chat's window when opened at a message", () => {
    const s = setup()
    s.cache.open(cid(1)).release()
    s.cache.open(cid(1), { around: mid(40) }).release()
    expect(s.endpoint.commands("ensure").map((c) => c.range)).toEqual([{ around: mid(40) }])
  })

  it("disposes every model when disposed", () => {
    const s = setup()
    const lease = s.cache.open(cid(1))
    s.cache.open(cid(2)).release()
    s.cache.dispose()
    expect(lease.model.disposed).toBe(true)
    expect(s.openSubs()).toEqual([])
    lease.release()
  })
})

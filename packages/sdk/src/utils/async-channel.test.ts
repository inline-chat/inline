import { describe, expect, it } from "vitest"
import { AsyncChannel } from "./async-channel.js"

describe("AsyncChannel", () => {
  it("yields values in order and completes on close", async () => {
    const ch = new AsyncChannel<number>()
    const it = ch[Symbol.asyncIterator]()

    await ch.send(1)
    await ch.send(2)

    expect(await it.next()).toEqual({ value: 1, done: false })
    expect(await it.next()).toEqual({ value: 2, done: false })

    ch.close()
    expect(await it.next()).toEqual({ value: undefined, done: true })
  })

  it("unblocks pending readers on close", async () => {
    const ch = new AsyncChannel<number>()
    const it = ch[Symbol.asyncIterator]()

    const pending = it.next()
    ch.close()

    expect(await pending).toEqual({ value: undefined, done: true })
  })

  it("drops sends after close and close is idempotent", async () => {
    const ch = new AsyncChannel<number>()
    ch.close()
    ch.close()
    await ch.send(1)

    const it = ch[Symbol.asyncIterator]()
    expect(await it.next()).toEqual({ value: undefined, done: true })
  })
})

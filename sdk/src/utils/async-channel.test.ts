import { describe, expect, it } from "vitest"
import {
  AcknowledgedAsyncChannel,
  AsyncChannel,
  AsyncChannelByteOverflowError,
  AsyncChannelOverflowError,
} from "./async-channel.js"

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

  it("fails deterministically when a slow consumer exceeds capacity", async () => {
    const ch = new AsyncChannel<number>(1)
    await ch.send(1)
    await expect(ch.send(2)).rejects.toThrow(AsyncChannelOverflowError)
    ch.close()
  })

  it("bounds queued items by measured bytes and releases the budget on consumption", async () => {
    const ch = new AsyncChannel<string>(4, {
      capacityBytes: 4,
      byteLength: (value) => value.length,
    })
    const iterator = ch[Symbol.asyncIterator]()
    await ch.send("1234")
    await expect(ch.send("5")).rejects.toThrow(AsyncChannelByteOverflowError)
    await expect(iterator.next()).resolves.toEqual({ value: "1234", done: false })
    await expect(ch.send("5")).resolves.toBeUndefined()
    ch.close()
  })

  it("propagates terminal failure to a pending reader", async () => {
    const ch = new AsyncChannel<number>(1)
    const pending = ch[Symbol.asyncIterator]().next()
    const failure = new Error("listener failed")
    ch.fail(failure)
    await expect(pending).rejects.toBe(failure)
  })
})

describe("AcknowledgedAsyncChannel", () => {
  it("acknowledges only after the consumer finishes an item and requests the next", async () => {
    const channel = new AcknowledgedAsyncChannel<number>(2)
    const iterator = channel[Symbol.asyncIterator]()
    const acknowledgement = channel.send(1)

    expect(await iterator.next()).toEqual({ value: 1, done: false })
    let settled = false
    void acknowledgement.then(() => { settled = true })
    await Promise.resolve()
    expect(settled).toBe(false)

    const next = iterator.next()
    await expect(acknowledgement).resolves.toBe(true)
    channel.close()
    await expect(next).resolves.toEqual({ value: undefined, done: true })
  })

  it("marks active and queued deliveries unacknowledged on close", async () => {
    const channel = new AcknowledgedAsyncChannel<number>(2)
    const iterator = channel[Symbol.asyncIterator]()
    const active = channel.send(1)
    const queued = channel.send(2)
    await iterator.next()

    channel.close()

    await expect(active).resolves.toBe(false)
    await expect(queued).resolves.toBe(false)
  })

  it("fails closed when a slow consumer exceeds the finite buffer", () => {
    const channel = new AcknowledgedAsyncChannel<number>(1)
    void channel.send(1)
    expect(() => channel.send(2)).toThrow(AsyncChannelOverflowError)
    channel.close()
  })

  it("keeps an unacknowledged active item inside the byte budget", async () => {
    const channel = new AcknowledgedAsyncChannel<string>(4, {
      capacityBytes: 4,
      byteLength: (value) => value.length,
    })
    const iterator = channel[Symbol.asyncIterator]()
    const first = channel.send("1234")
    await expect(iterator.next()).resolves.toEqual({ value: "1234", done: false })
    expect(() => channel.send("5")).toThrow(AsyncChannelByteOverflowError)

    const next = iterator.next()
    await expect(first).resolves.toBe(true)
    const second = channel.send("5")
    await expect(next).resolves.toEqual({ value: "5", done: false })
    channel.close()
    await expect(second).resolves.toBe(false)
  })

  it("releases active and queued byte accounting when closed", async () => {
    const channel = new AcknowledgedAsyncChannel<string>(4, {
      capacityBytes: 4,
      byteLength: (value) => value.length,
    })
    const iterator = channel[Symbol.asyncIterator]()
    const active = channel.send("12")
    const queued = channel.send("34")
    await iterator.next()
    channel.close()
    await expect(active).resolves.toBe(false)
    await expect(queued).resolves.toBe(false)
    await expect(channel.send("12345")).resolves.toBe(false)
  })
})

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
    void acknowledgement.then(() => {
      settled = true
    })
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

describe("Acknowledged concurrent consumption", () => {
  it("keeps global barriers ordered and counts held receipts against capacity", async () => {
    const channel = new AcknowledgedAsyncChannel<{ key: string | null; id: number }>(4)
    let release!: () => void
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    const processed: number[] = []
    const consuming = channel.consume(
      async (value) => {
        if (value.id === 1) await gate
        processed.push(value.id)
      },
      (value) => value.key,
      2
    )
    const receipts = [
      channel.send({ key: "a", id: 1 }),
      channel.send({ key: null, id: 2 }),
      channel.send({ key: "b", id: 3 }),
      channel.send({ key: "a", id: 4 }),
    ]
    expect(() => channel.send({ key: "c", id: 5 })).toThrow(AsyncChannelOverflowError)
    await Promise.resolve()
    expect(processed).toEqual([])
    release()
    expect(await Promise.all(receipts)).toEqual([true, true, true, true])
    expect(processed.indexOf(1)).toBeLessThan(processed.indexOf(2))
    expect(processed.indexOf(2)).toBeLessThan(processed.indexOf(3))
    expect(processed.indexOf(2)).toBeLessThan(processed.indexOf(4))
    channel.close()
    await consuming
  })

  it("handler failure rejects queued and in-flight receipts without later accidental acknowledgement", async () => {
    const channel = new AcknowledgedAsyncChannel<string>(4)
    let release!: () => void
    const gate = new Promise<void>((resolve) => {
      release = resolve
    })
    const consuming = channel.consume(
      async (key) => {
        if (key === "a") await gate
        else throw new Error("handler rejected")
      },
      (key) => key,
      2
    )
    const failed = expect(consuming).rejects.toThrow("handler rejected")
    const receipts = [channel.send("a"), channel.send("b"), channel.send("a")]
    await failed
    expect(await Promise.all(receipts)).toEqual([false, false, false])
    release()
    await Promise.resolve()
    expect(await channel.send("a")).toBe(false)
  })
})

it("returning a waiting iterator cannot steal work from its replacement", async () => {
  const channel = new AcknowledgedAsyncChannel<number>(4)
  const iterator = channel[Symbol.asyncIterator]()
  const waiting = iterator.next()
  await iterator.return!()
  const received: number[] = []
  const consuming = channel.consume(
    async (value) => {
      received.push(value)
    },
    () => "chat"
  )
  const receipt = channel.send(1)
  await Promise.resolve()
  await Promise.resolve()
  expect(received).toEqual([1])
  await expect(waiting).resolves.toEqual({ done: true, value: undefined })
  await expect(iterator.next()).resolves.toEqual({ done: true, value: undefined })
  await iterator.return!()
  await expect(receipt).resolves.toBe(true)
  await expect(channel.send(2)).resolves.toBe(true)
  expect(received).toEqual([1, 2])
  channel.close()
  await consuming
})

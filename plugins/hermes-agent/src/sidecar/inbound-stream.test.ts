import { PassThrough } from "node:stream"
import { once } from "node:events"
import { describe, expect, it } from "vitest"
import { InboundStream } from "./inbound-stream.js"

const flush = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

function readEvents(consumer: PassThrough): Array<{ seq: number; _inlineDeliveryId: string }> {
  const events: Array<{ seq: number; _inlineDeliveryId: string }> = []
  let buffered = ""
  consumer.on("data", (chunk) => {
    buffered += chunk.toString()
    let newline: number
    while ((newline = buffered.indexOf("\n")) >= 0) {
      events.push(JSON.parse(buffered.slice(0, newline)))
      buffered = buffered.slice(newline + 1)
    }
  })
  return events
}

describe("InboundStream lifecycle", () => {
  it("holds the receipt after socket write until handling is acknowledged", async () => {
    const stream = new InboundStream()
    const consumer = new PassThrough()
    const events = readEvents(consumer)
    stream.attach(consumer)
    let complete = false
    const pending = stream.deliver({ seq: 1, _inlineDeliveryId: "untrusted" }).then(() => { complete = true })
    await flush()
    expect(events).toHaveLength(1)
    expect(events[0]._inlineDeliveryId).not.toBe("untrusted")
    expect(complete).toBe(false)
    stream.acknowledge("unknown")
    await flush()
    expect(complete).toBe(false)
    stream.acknowledge(events[0]._inlineDeliveryId)
    await pending
    // Lost HTTP responses may cause the same acknowledgement to be retried.
    stream.acknowledge(events[0]._inlineDeliveryId)
    expect(complete).toBe(true)
    stream.close()
    consumer.destroy()
  })

  it.each(["close", "error", "replacement"])("replays the same unacknowledged identity after consumer %s", async (cause) => {
    const stream = new InboundStream()
    const old = new PassThrough()
    const original = readEvents(old)
    stream.attach(old)
    let complete = false
    const pending = stream.deliver({ seq: 1 }).then(() => { complete = true })
    await flush()
    expect(complete).toBe(false)
    const replacement = new PassThrough()
    const replay = readEvents(replacement)
    if (cause === "close") {
      const closed = once(old, "close")
      old.destroy()
      await closed
    } else if (cause === "error") {
      old.emit("error", new Error("consumer failed"))
    }
    stream.attach(replacement)
    await flush()
    expect(replay).toEqual(original)
    expect(complete).toBe(false)
    stream.acknowledge(replay[0]._inlineDeliveryId)
    await pending
    // A stale retired consumer must not disconnect the replacement.
    old.emit("error", new Error("retired stream"))
    const next = stream.deliver({ seq: 2 })
    await flush()
    expect(replay.map((event) => event.seq)).toEqual([1, 2])
    expect(replay[1]._inlineDeliveryId).not.toBe(replay[0]._inlineDeliveryId)
    stream.acknowledge(replay[1]._inlineDeliveryId)
    await next
    expect(old.listenerCount("drain")).toBe(0)
    stream.close()
    old.destroy()
    replacement.destroy()
  })

  it("acknowledges unrelated concurrent deliveries independently", async () => {
    const stream = new InboundStream()
    const consumer = new PassThrough()
    const events = readEvents(consumer)
    stream.attach(consumer)
    let firstComplete = false
    const first = stream.deliver({ seq: 1 }).then(() => { firstComplete = true })
    const second = stream.deliver({ seq: 2 })
    await flush()
    expect(events).toHaveLength(2)
    expect(new Set(events.map((event) => event._inlineDeliveryId)).size).toBe(2)
    stream.acknowledge(events[1]._inlineDeliveryId)
    await second
    expect(firstComplete).toBe(false)
    stream.acknowledge(events[0]._inlineDeliveryId)
    await first
    stream.close()
    consumer.destroy()
  })

  it("shutdown rejects pending receipts with absent, writable, or backpressured consumers", async () => {
    for (const mode of ["absent", "writable", "backpressured"]) {
      const stream = new InboundStream()
      const consumer = new PassThrough({ highWaterMark: mode === "backpressured" ? 1 : 16384 })
      if (mode === "writable") readEvents(consumer)
      if (mode !== "absent") stream.attach(consumer)
      const pending = stream.deliver({ seq: 1 })
      const rejected = expect(pending).rejects.toThrow("closed")
      await flush()
      stream.close()
      await rejected
      expect(consumer.listenerCount("drain")).toBe(0)
      consumer.destroy()
    }
  })
})

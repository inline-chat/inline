import { PassThrough } from "node:stream"
import { once } from "node:events"
import { describe, expect, it } from "vitest"
import { InboundStream } from "./inbound-stream.js"

const flush = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

describe("InboundStream lifecycle", () => {
  it.each(["close", "error", "replacement"])("replays pending delivery after old consumer %s", async (cause) => {
    const stream = new InboundStream()
    const old = new PassThrough({ highWaterMark: 1 })
    stream.attach(old)
    let complete = false
    const pending = stream.deliver({ seq: 1 }).then(() => {
      complete = true
    })
    await flush()
    expect(complete).toBe(false)
    const replacement = new PassThrough()
    let output = ""
    const received = new Promise<void>((resolve) =>
      replacement.on("data", (chunk) => {
        output += chunk.toString()
        if (output.endsWith('{"seq":2}\n')) resolve()
      })
    )
    if (cause === "close") {
      const closed = once(old, "close")
      old.destroy()
      await closed
    }
    stream.attach(replacement)
    if (cause === "error") old.emit("error", new Error("retired stream"))
    await pending
    await stream.deliver({ seq: 2 })
    await received
    expect(output).toBe('{"seq":1}\n{"seq":2}\n')
    expect(old.listenerCount("drain")).toBe(0)
    stream.close()
    old.destroy()
    replacement.destroy()
  })

  it("shutdown releases both backpressure and absent-consumer waits without acknowledgement", async () => {
    for (const withConsumer of [false, true]) {
      const stream = new InboundStream()
      const consumer = new PassThrough({ highWaterMark: 1 })
      if (withConsumer) stream.attach(consumer)
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

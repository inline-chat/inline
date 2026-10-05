import { describe, expect, test } from "bun:test"
import { BoundedPcmQueue, pcm16le } from "./pcm.js"

describe("bounded native audio handoff", () => {
  test("PCM serializes signed samples in little endian and respects an offset view", () => {
    const backing = new Int16Array([99, -1, 0x1234, -32768, 99])
    expect([...pcm16le(backing.subarray(1, 4))]).toEqual([255, 255, 52, 18, 0, 128])
  })
  test("producer buffers are copied and a slow consumer has a finite failure bound", async () => {
    const queue = new BoundedPcmQueue(4)
    const producer = new Int16Array([1, 2])
    queue.push(producer)
    producer.fill(9)
    expect([...(await queue.take())!]).toEqual([1, 2])
    queue.push(new Int16Array([3, 4, 5]))
    expect(() => queue.push(new Int16Array([6, 7]))).toThrow("overflow")
    expect(queue.bufferedSamples).toBe(0)
    await expect(queue.take()).rejects.toThrow("overflow")
  })
  test("stop discards queued PCM and wakes an idle reader", async () => {
    const queue = new BoundedPcmQueue(4)
    const waiting = queue.take()
    queue.close()
    expect(await waiting).toBeUndefined()
    expect(() => queue.push(new Int16Array([1]))).toThrow("stopped")
    const queued = new BoundedPcmQueue(4)
    queued.push(new Int16Array([1, 2]))
    queued.close()
    expect(await queued.take()).toBeUndefined()
  })
  test("one consumer receives frames immediately without awaiting provider work", async () => {
    const queue = new BoundedPcmQueue(4)
    const waiting = queue.take()
    queue.push(new Int16Array([4, 5]))
    expect([...(await waiting)!]).toEqual([4, 5])
    expect(queue.bufferedSamples).toBe(0)
  })
})

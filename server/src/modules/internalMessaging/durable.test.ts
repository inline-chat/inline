import { afterEach, describe, expect, spyOn, test } from "bun:test"
import type { BrokerPublication } from "./redis"
import { publishDurableReference } from "./durable"
import { outboundPublications } from "./outbound"
import { internalMessaging } from "./service"

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((next) => { resolve = next })
  return { promise, resolve }
}

describe("durable outbound hints", () => {
  afterEach(async () => {
    await outboundPublications.drain()
    outboundPublications.start()
  })

  test("coalesces the maximum frontier and clears mixed exclusions, including an older arrival", async () => {
    const first = deferred<BrokerPublication>()
    const publications: Parameters<typeof internalMessaging.publish>[0][] = []
    const publish = spyOn(internalMessaging, "publish").mockImplementation(async (input) => {
      publications.push(input)
      if (publications.length === 1) return await first.promise
      return { status: "published", subscribers: 1 }
    })

    try {
      publishDurableReference({
        bucket: { kind: "chat", chatId: 42 }, frontier: 4, senderUserId: 100, excludeSessionId: 10,
      })
      for (let attempt = 0; attempt < 8 && publications.length === 0; attempt += 1) await Promise.resolve()
      expect(publications).toHaveLength(1)

      publishDurableReference({
        bucket: { kind: "chat", chatId: 42 }, frontier: 5, senderUserId: 200, excludeSessionId: 20,
      })
      publishDurableReference({
        bucket: { kind: "chat", chatId: 42 }, frontier: 3, senderUserId: 300, excludeSessionId: 30,
      })
      first.resolve({ status: "published", subscribers: 1 })
      await outboundPublications.drain()

      expect(publications).toHaveLength(2)
      expect(publications[1]).toMatchObject({
        event: { kind: "DurableUpdatesAvailable", frontier: 5 },
      })
      expect(publications[1]?.event).not.toHaveProperty("senderUserId")
      expect(publications[1]?.event).not.toHaveProperty("excludeSessionId")
    } finally {
      first.resolve({ status: "published", subscribers: 1 })
      await outboundPublications.drain()
      publish.mockRestore()
    }
  })
})

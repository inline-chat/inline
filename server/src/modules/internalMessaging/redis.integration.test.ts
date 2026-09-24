import { describe, expect, it } from "bun:test"
import { randomUUID } from "node:crypto"
import { ChatId, SessionId, SpaceId, UserId } from "@in/server/core/schema/identifiers"
import { ConnectionDirectory } from "./directory"
import { InternalMessagingService } from "./service"

const redisUrl = process.env["INLINE_TEST_REDIS_URL"]
const waitFor = async <T>(promise: Promise<T>): Promise<T> => {
  const timer = Promise.withResolvers<never>()
  const timeout = setTimeout(() => timer.reject(new Error("Broker event did not arrive")), 2_000)
  try { return await Promise.race([promise, timer.promise]) }
  finally { clearTimeout(timeout) }
}

describe("two-service disposable broker transport", () => {
  it.skipIf(!redisUrl)("routes typed hints and exact private replies between independent boot IDs", async () => {
    const a = new InternalMessagingService(redisUrl)
    const b = new InternalMessagingService(redisUrl)
    const directoryA = new ConnectionDirectory(a)
    const directoryB = new ConnectionDirectory(b)
    try {
      await Promise.all([a.start(), b.start()])
      expect(a.health).toBe("ready")
      expect(b.health).toBe("ready")

      const received = Promise.withResolvers<number>()
      const unsubscribe = b.on("DurableUpdatesAvailable", ({ event }) => received.resolve(event.frontier))
      expect((await a.publish({ target: { kind: "cluster" }, event: {
        kind: "DurableUpdatesAvailable", bucket: { kind: "chat", chatId: ChatId.make(7) }, frontier: 23,
      } })).status).toBe("published")
      expect(await waitFor(received.promise)).toBe(23)
      unsubscribe()

      const directoryUserId = Number.parseInt(randomUUID().slice(0, 8), 16)
      directoryA.register({ connectionId: "one", userId: directoryUserId, sessionId: 10, clientType: "macos", isBot: false })
      directoryB.register({ connectionId: "two", userId: directoryUserId, sessionId: 10, clientType: "macos", isBot: false })
      await Promise.all([directoryA.rebuild(), directoryB.rebuild()])
      const view = await directoryB.list(directoryUserId)
      expect(view.status).toBe("available")
      if (view.status === "available") expect(view.connections.map((c) => c.connectionId).sort()).toEqual(["one", "two"])

      const target = { kind: "connection" as const, bootId: b.bootId, connectionId: "bot", userId: UserId.make(9001), sessionId: SessionId.make(9002) }
      const origin = { kind: "connection" as const, bootId: a.bootId, connectionId: "actor", userId: UserId.make(8001), sessionId: SessionId.make(8002) }
      const answered = Promise.withResolvers<boolean>()
      const unsubscribePrivate = b.on("PrivateRequest", async (envelope) => {
        if (!b.registerInboundPrivate(envelope)) { answered.resolve(false); return }
        const wrong = await b.replyInboundPrivate({ kind: "botSettings", requestId: envelope.event.requestId,
          actualConnectionId: "wrong", actualSessionId: 9002, botUserId: 9001,
          payload: { kind: "botSettings", response: "e30=" } })
        if (wrong) { answered.resolve(false); return }
        answered.resolve(await b.replyInboundPrivate({ kind: "botSettings", requestId: envelope.event.requestId,
          actualConnectionId: "bot", actualSessionId: 9002, botUserId: 9001,
          payload: { kind: "botSettings", response: "e30=" } }))
      })
      const reply = await a.requestPrivate({ target, origin, requestId: 18446744073709551615n,
        payload: { kind: "botSettings", request: "e30=" }, timeoutMs: 2_000 })
      expect(await waitFor(answered.promise)).toBe(true)
      expect(reply).toEqual({ status: "replied", payload: { kind: "botSettings", response: "e30=" } })
      unsubscribePrivate()

      const receivedSession = Promise.withResolvers<string>()
      const unsubscribeSession = b.on("SessionRealtime", ({ target }) => receivedSession.resolve(target.bootId))
      const directed = await a.publish({
        target: { kind: "session", bootId: b.bootId, userId: UserId.make(9001), sessionId: SessionId.make(9002) },
        event: { kind: "SessionRealtime", payload: { kind: "gridCredentials", roomId: 1,
          spaceId: SpaceId.make(2), generation: 3, mediaMembershipId: randomUUID(), encodedPayload: "e30=" } },
      })
      expect(directed).toEqual({ status: "published", subscribers: 1 })
      expect(await waitFor(receivedSession.promise)).toBe(b.bootId)
      unsubscribeSession()

      const marker = Number.parseInt(randomUUID().slice(0, 8), 16)
      expect(await a.recordDesktopActivity(marker, 17)).toBe(true)
      expect(await b.hasDesktopActivity(marker, 17)).toBe(true)
      expect(await b.hasDesktopActivity(marker, 18)).toBe(false)

      const budgetIdentity = `fixture:${randomUUID()}`
      expect((await a.consumeSharedBudget("http", budgetIdentity, 15_000))?.count).toBe(1)
      expect((await b.consumeSharedBudget("http", budgetIdentity, 15_000))?.count).toBe(2)

      // Both registrations belong to the same account session. Draining A
      // removes only A's socket; B remains the live owner.
      await directoryA.shutdown()
      const afterDrain = await directoryB.list(directoryUserId)
      expect(afterDrain.status).toBe("available")
      if (afterDrain.status === "available") {
        expect(afterDrain.connections.map((connection) => connection.connectionId)).toEqual(["two"])
      }
    } finally {
      await Promise.all([directoryA.shutdown(), directoryB.shutdown()])
      await Promise.all([a.close(), b.close()])
    }
  })
})

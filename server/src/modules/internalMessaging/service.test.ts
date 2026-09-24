import { randomUUID } from "node:crypto"
import { describe, expect, it } from "bun:test"
import { InternalBrokerConfigurationError } from "./redis"
import { encodeEnvelope } from "./schemas"
import {
  InternalMessagingService,
  maxConcurrentInboundEvents,
  maxPendingInboundEvents,
  maxReservedPrivateInboundEvents,
  maxReservedPrivateInboundWorkers,
  maxReservedPriorityInboundEvents,
  maxReservedPriorityInboundWorkers,
} from "./service"

it("rejects service startup with a blank broker URL", async () => {
  const service = new InternalMessagingService("  ")
  try {
    await expect(service.start()).rejects.toBeInstanceOf(InternalBrokerConfigurationError)
    expect(service.health).toBe("unavailable")
  } finally {
    await service.close()
  }
})

type Receive = (frame: string, channel: string) => void

const originBootId = "11111111-1111-4111-8111-111111111111"
const durableFrame = (frontier: number, metadata?: { senderUserId?: number; excludeSessionId?: number }) =>
  encodeEnvelope({
    version: 1,
    eventId: randomUUID(),
    originBootId,
    target: { kind: "cluster" },
    event: { kind: "DurableUpdatesAvailable", bucket: { kind: "chat", chatId: 7 }, frontier, ...metadata },
  } as never)
const spaceDurableFrame = (frontier: number) => encodeEnvelope({
  version: 1,
  eventId: randomUUID(),
  originBootId,
  target: { kind: "cluster" },
  event: { kind: "DurableUpdatesAvailable", bucket: { kind: "space", spaceId: 8 }, frontier },
} as never)
const transientFrame = () => encodeEnvelope({
  version: 1,
  eventId: randomUUID(),
  originBootId,
  target: { kind: "user", userId: 7 },
  event: { kind: "TransientRealtime", payload: { kind: "userPresenceChanged", userId: 7, online: true, lastOnlineMs: null } },
} as never)
const revokedFrame = () => encodeEnvelope({
  version: 1,
  eventId: randomUUID(),
  originBootId,
  target: { kind: "cluster" },
  event: { kind: "SessionRevoked", userId: 7, sessionId: 9 },
} as never)
const privateRequestFrame = (targetBootId: string, requestId = 1n) => encodeEnvelope({
  version: 1,
  eventId: randomUUID(),
  originBootId,
  target: { kind: "connection", bootId: targetBootId, connectionId: "target", userId: 7, sessionId: 9 },
  event: {
    kind: "PrivateRequest",
    correlationId: randomUUID(),
    originBootId,
    originConnection: { kind: "connection", bootId: originBootId, connectionId: "origin", userId: 8, sessionId: 10 },
    requestId,
    deadlineMs: Date.now() + 10_000,
    payload: { kind: "botSettings", request: "test" },
  },
} as never)

const installReadyTransport = async (service: InternalMessagingService) => {
  const receives: Receive[] = []
  const transport = {
    health: "ready" as const,
    start: async (_channels: readonly string[], receive: Receive) => { receives.push(receive) },
    close: async () => {},
    onContinuityLost: () => () => {},
    onReady: () => () => {},
  }
  ;(service as unknown as { transport: typeof transport }).transport = transport
  await service.start()
  const receive = receives.at(-1)
  if (!receive) throw new Error("Expected service transport receiver")
  return { receive, transport }
}

describe("inbound internal messaging ownership", () => {
  it("bounds a 5,000-event burst across handlers and admits revocation/private traffic in reserved capacity", async () => {
    const service = new InternalMessagingService("redis://test.invalid")
    const { receive } = await installReadyTransport(service)
    const release = Promise.withResolvers<void>()
    let active = 0
    let peak = 0
    let handlerStarts = 0
    const revocation = Promise.withResolvers<void>()
    const privateRequest = Promise.withResolvers<void>()
    service.on("TransientRealtime", async () => {
      handlerStarts++
      active++
      peak = Math.max(peak, active)
      try { await release.promise } finally { active-- }
    })
    service.on("TransientRealtime", () => { handlerStarts++ })
    service.on("SessionRevoked", () => revocation.resolve())
    service.on("PrivateRequest", () => privateRequest.resolve())

    for (let index = 0; index < 5_000; index++) receive(transientFrame(), service.key("internal:v1:cluster"))

    expect(peak).toBe(maxConcurrentInboundEvents - maxReservedPriorityInboundWorkers)
    // Each event owns a single scheduled task, so a second callback cannot
    // multiply the number of concurrent handler promises.
    expect(handlerStarts).toBe(peak)
    expect(service.diagnostics.inboundPending).toBeLessThanOrEqual(
      maxPendingInboundEvents - maxReservedPriorityInboundEvents,
    )
    expect(service.diagnostics.droppedInboundEvents).toBeGreaterThan(0)

    receive(revokedFrame(), service.key("internal:v1:cluster"))
    receive(privateRequestFrame(service.bootId), service.key(`internal:v1:boot:${service.bootId}`))
    await Promise.all([revocation.promise, privateRequest.promise])
    release.resolve()
    await service.close()
  })

  it("reserves revocation workers and queue capacity when private traffic is full", async () => {
    const service = new InternalMessagingService("redis://test.invalid")
    const { receive } = await installReadyTransport(service)
    const releasePrivate = Promise.withResolvers<void>()
    const privateWorkersStarted = Promise.withResolvers<void>()
    const revocation = Promise.withResolvers<void>()
    let privateActive = 0
    service.on("PrivateRequest", async () => {
      privateActive++
      if (privateActive === maxReservedPrivateInboundWorkers) privateWorkersStarted.resolve()
      try { await releasePrivate.promise } finally { privateActive-- }
    })
    service.on("SessionRevoked", () => revocation.resolve())

    for (let index = 0; index < maxReservedPrivateInboundWorkers + maxReservedPrivateInboundEvents; index++) {
      receive(privateRequestFrame(service.bootId, BigInt(index + 1)), service.key(`internal:v1:boot:${service.bootId}`))
    }
    await privateWorkersStarted.promise
    expect(service.diagnostics.inboundPrivateActive).toBe(maxReservedPrivateInboundWorkers)

    receive(revokedFrame(), service.key("internal:v1:cluster"))
    await revocation.promise

    releasePrivate.resolve()
    await service.close()
  })

  it("coalesces duplicate revocations for an active authenticated session", async () => {
    const service = new InternalMessagingService("redis://test.invalid")
    const { receive } = await installReadyTransport(service)
    const release = Promise.withResolvers<void>()
    const started = Promise.withResolvers<void>()
    let calls = 0
    service.on("SessionRevoked", async () => {
      calls++
      started.resolve()
      await release.promise
    })

    receive(revokedFrame(), service.key("internal:v1:cluster"))
    await started.promise
    receive(revokedFrame(), service.key("internal:v1:cluster"))
    expect(service.diagnostics.coalescedRevocationEvents).toBe(1)

    release.resolve()
    await service.waitForIncomingWork()
    expect(calls).toBe(1)
    await service.close()
  })

  it("coalesces a pending durable bucket at its highest frontier without retaining mixed exclusions", async () => {
    const service = new InternalMessagingService("redis://test.invalid")
    const { receive } = await installReadyTransport(service)
    const release = Promise.withResolvers<void>()
    const started = Promise.withResolvers<void>()
    const otherBucketStarted = Promise.withResolvers<void>()
    const received: { frontier: number; senderUserId?: number; excludeSessionId?: number }[] = []
    service.on("DurableUpdatesAvailable", async ({ event }) => {
      if (event.bucket.kind === "space") {
        otherBucketStarted.resolve()
        return
      }
      received.push({
        frontier: event.frontier,
        ...(event.senderUserId === undefined ? {} : { senderUserId: event.senderUserId }),
        ...(event.excludeSessionId === undefined ? {} : { excludeSessionId: event.excludeSessionId }),
      })
      if (received.length === 1) {
        started.resolve()
        await release.promise
      }
    })

    receive(durableFrame(3), service.key("internal:v1:cluster"))
    await started.promise
    receive(durableFrame(8, { senderUserId: 41, excludeSessionId: 81 }), service.key("internal:v1:cluster"))
    receive(durableFrame(9, { senderUserId: 42, excludeSessionId: 82 }), service.key("internal:v1:cluster"))
    receive(spaceDurableFrame(4), service.key("internal:v1:cluster"))
    await otherBucketStarted.promise

    release.resolve()
    await service.waitForIncomingWork()
    expect(received).toEqual([
      { frontier: 3 },
      { frontier: 9 },
    ])
    await service.close()
  })

  it("retains matching durable delivery metadata at the highest pending frontier", async () => {
    const service = new InternalMessagingService("redis://test.invalid")
    const { receive } = await installReadyTransport(service)
    const release = Promise.withResolvers<void>()
    const started = Promise.withResolvers<void>()
    const received: { frontier: number; senderUserId?: number; excludeSessionId?: number }[] = []
    service.on("DurableUpdatesAvailable", async ({ event }) => {
      received.push({
        frontier: event.frontier,
        ...(event.senderUserId === undefined ? {} : { senderUserId: event.senderUserId }),
        ...(event.excludeSessionId === undefined ? {} : { excludeSessionId: event.excludeSessionId }),
      })
      if (received.length === 1) {
        started.resolve()
        await release.promise
      }
    })

    receive(durableFrame(3), service.key("internal:v1:cluster"))
    await started.promise
    receive(durableFrame(8, { senderUserId: 41, excludeSessionId: 81 }), service.key("internal:v1:cluster"))
    receive(durableFrame(9, { senderUserId: 41, excludeSessionId: 81 }), service.key("internal:v1:cluster"))

    release.resolve()
    await service.waitForIncomingWork()
    expect(received).toEqual([
      { frontier: 3 },
      { frontier: 9, senderUserId: 41, excludeSessionId: 81 },
    ])
    await service.close()
  })

  it("stops admission, joins started handlers, and rejects an old transport generation after restart", async () => {
    const service = new InternalMessagingService("redis://test.invalid")
    const first = await installReadyTransport(service)
    const release = Promise.withResolvers<void>()
    const started = Promise.withResolvers<void>()
    let calls = 0
    service.on("DurableUpdatesAvailable", async () => {
      calls++
      started.resolve()
      await release.promise
    })

    first.receive(durableFrame(1), service.key("internal:v1:cluster"))
    await started.promise
    // A queued successor is deliberately dropped on shutdown; close joins
    // only work that was already admitted to a handler.
    first.receive(durableFrame(2), service.key("internal:v1:cluster"))
    let closed = false
    const close = service.close().then(() => { closed = true })
    await Promise.resolve()
    expect(closed).toBe(false)
    release.resolve()
    await close
    expect(calls).toBe(1)

    first.receive(durableFrame(3), service.key("internal:v1:cluster"))
    await Promise.resolve()
    expect(calls).toBe(1)

    const second = await installReadyTransport(service)
    first.receive(durableFrame(4), service.key("internal:v1:cluster"))
    second.receive(durableFrame(5), service.key("internal:v1:cluster"))
    await service.waitForIncomingWork()
    expect(calls).toBe(2)
    await service.close()
  })
})

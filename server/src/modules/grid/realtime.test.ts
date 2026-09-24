import { afterEach, expect, spyOn, test } from "bun:test"
import { SpaceId } from "@in/server/core/schema/identifiers"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import type { InternalEnvelope } from "@in/server/modules/internalMessaging/schemas"
import { outboundPublications } from "@in/server/modules/internalMessaging/outbound"
import * as realtime from "@in/server/realtime/message"
import { maxConcurrentGridSpaceDeliveries, notifyGridChanged, subscribeGridChangeHints } from "./realtime"

const spies: { mockRestore(): void }[] = []
afterEach(async () => {
  await outboundPublications.drain()
  outboundPublications.start()
  for (const spy of spies.splice(0)) spy.mockRestore()
})

test("committed Grid changes notify other nodes even without a local recipient", async () => {
  const send = spyOn(realtime, "sendMessageToRealtimeSpace").mockResolvedValue(undefined)
  const publish = spyOn(internalMessaging, "publish").mockResolvedValue({ status: "published", subscribers: 1 })
  spies.push(send, publish)
  await notifyGridChanged({ affectedSpaceIds: new Set([12, 13]), changedRoomId: 25, endedConnections: [] })
  await outboundPublications.drain()
  expect(send).toHaveBeenCalledTimes(2)
  expect(publish.mock.calls.map(([input]) => input)).toEqual([
    { target: { kind: "cluster" }, event: { kind: "GridChanged", spaceId: SpaceId.make(12), roomId: 25 } },
    { target: { kind: "cluster" }, event: { kind: "GridChanged", spaceId: SpaceId.make(13), roomId: 25 } },
  ])
})

test("a failed local delivery cannot prevent the remote notification or fail the mutation", async () => {
  const send = spyOn(realtime, "sendMessageToRealtimeSpace").mockRejectedValue(new Error("Synthetic socket failure"))
  const publish = spyOn(internalMessaging, "publish").mockResolvedValue({ status: "unavailable" })
  spies.push(send, publish)
  await expect(notifyGridChanged({ affectedSpaceIds: new Set([12]), endedConnections: [] })).resolves.toBeUndefined()
  await outboundPublications.drain()
  expect(publish).toHaveBeenCalledTimes(1)
})

test("completes a failed batch before sending the next Grid delivery batch", async () => {
  const releaseHeldDelivery = Promise.withResolvers<void>()
  const started: number[] = []
  const send = spyOn(realtime, "sendMessageToRealtimeSpace").mockImplementation(async (spaceId) => {
    started.push(spaceId)
    if (spaceId === 1) throw new Error("Synthetic socket failure")
    if (spaceId === 2) await releaseHeldDelivery.promise
  })
  const publish = spyOn(internalMessaging, "publish").mockResolvedValue({ status: "published", subscribers: 1 })
  spies.push(send, publish)
  const spaceIds = new Set(Array.from({ length: maxConcurrentGridSpaceDeliveries + 1 }, (_, index) => index + 1))

  const changed = notifyGridChanged({ affectedSpaceIds: spaceIds, endedConnections: [] })
  await Promise.resolve()
  expect(started).toEqual(Array.from({ length: maxConcurrentGridSpaceDeliveries }, (_, index) => index + 1))

  let completed = false
  void changed.then(() => { completed = true })
  await Promise.resolve()
  expect(completed).toBe(false)
  expect(started).not.toContain(maxConcurrentGridSpaceDeliveries + 1)

  releaseHeldDelivery.resolve()
  await changed
  await outboundPublications.drain()
  expect(started).toEqual(Array.from({ length: maxConcurrentGridSpaceDeliveries + 1 }, (_, index) => index + 1))
  expect(publish).toHaveBeenCalledTimes(spaceIds.size)
})

test("bounds local fanout across many affected spaces and completes every delivery", async () => {
  const release = Promise.withResolvers<void>()
  const saturated = Promise.withResolvers<void>()
  let active = 0
  let peak = 0
  let deliveries = 0
  const send = spyOn(realtime, "sendMessageToRealtimeSpace").mockImplementation(async () => {
    deliveries++
    active++
    peak = Math.max(peak, active)
    if (active === maxConcurrentGridSpaceDeliveries) saturated.resolve()
    try { await release.promise } finally { active-- }
  })
  const publish = spyOn(internalMessaging, "publish").mockResolvedValue({ status: "published", subscribers: 1 })
  spies.push(send, publish)
  const spaceIds = new Set(Array.from({ length: maxConcurrentGridSpaceDeliveries * 2 + 3 }, (_, index) => index + 1))

  const changed = notifyGridChanged({ affectedSpaceIds: spaceIds, endedConnections: [] })
  await saturated.promise
  expect(peak).toBe(maxConcurrentGridSpaceDeliveries)
  expect(deliveries).toBe(maxConcurrentGridSpaceDeliveries)

  release.resolve()
  await changed
  await outboundPublications.drain()
  expect(deliveries).toBe(spaceIds.size)
  expect(peak).toBe(maxConcurrentGridSpaceDeliveries)
})

test("received Grid hints use current membership delivery and never republish", async () => {
  let receive: ((envelope: InternalEnvelope) => void | Promise<void>) | undefined
  let removed = false
  const on = spyOn(internalMessaging, "on").mockImplementation((_kind, handler) => {
    receive = handler as typeof receive
    return () => { removed = true }
  })
  const send = spyOn(realtime, "sendMessageToRealtimeSpace").mockResolvedValue(undefined)
  const publish = spyOn(internalMessaging, "publish").mockResolvedValue({ status: "unavailable" })
  spies.push(on, send, publish)
  const unsubscribe = subscribeGridChangeHints()
  expect(on.mock.calls[0]?.[0]).toBe("GridChanged")
  await receive?.({
    version: 1, eventId: crypto.randomUUID(), originBootId: crypto.randomUUID(),
    target: { kind: "cluster" }, event: { kind: "GridChanged", spaceId: SpaceId.make(12), roomId: 25 },
  })
  expect(send).toHaveBeenCalledWith(12, {
    oneofKind: "grid", grid: { event: { oneofKind: "changed", changed: { spaceIds: [12n], roomId: 25n } } },
  })
  expect(publish).not.toHaveBeenCalled()
  unsubscribe()
  expect(removed).toBe(true)
})

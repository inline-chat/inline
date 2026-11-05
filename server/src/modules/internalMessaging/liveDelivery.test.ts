import { describe, expect, it, spyOn } from "bun:test"
import { randomUUID } from "node:crypto"
import { Message, Update, UpdatesPayload } from "@inline-chat/protocol/core"
import { RealtimeDelivery } from "@in/server/protocol/server"
import { InternalMessagingService } from "./service"
import { decodeLiveDelivery, deliveryPartition, LiveRealtimeDelivery, MAX_LIVE_ENVELOPE_BYTES, MAX_LIVE_QUEUE_BYTES, MAX_LIVE_QUEUE_ENTRIES, MAX_LIVE_RECIPIENTS, MAX_LIVE_UPDATE_BYTES } from "./liveDelivery"
import { decodeEnvelope, encodeEnvelope, type InternalEnvelope } from "./schemas"
import { distributedRealtimeConfig } from "./config"
import { liveRequirements } from "./liveAuthorization"
import { ENCRYPTION2_OVERHEAD_BYTES, Encryption2 } from "@in/server/modules/encryption/encryption2"
import { Log } from "@in/server/utils/log"

type Envelope = Extract<InternalEnvelope, { event: { kind: "RealtimeDelivery" } }>
const reaction = (emoji = "👍"): Update[] => [{ update: { oneofKind: "deleteReaction", deleteReaction: { chatId: 9n, userId: 1n, messageId: 2n, emoji } } }]
const message = (text: string): Update[] => [Update.create({ update: { oneofKind: "newMessage", newMessage: { message: Message.create({
  id: 2n, chatId: 9n, fromId: 1n, peerId: { type: { oneofKind: "chat", chat: { chatId: 9n } } }, message: text,
}) } } })]
function messageOfSize(bytes: number): Update[] {
  // Multibyte text stays below the product's 100k UTF-16-unit limit even at
  // the 256 KiB serialized update ceiling. Account for protobuf framing.
  const textBytes = bytes - (UpdatesPayload.toBinary({ updates: message("m".repeat(bytes)) }).byteLength - bytes)
  const updates = message("漢".repeat(Math.floor(textBytes / 3)) + "a".repeat(textBytes % 3))
  expect(UpdatesPayload.toBinary({ updates }).byteLength).toBe(bytes)
  return updates
}
function fixture(enabled = true) {
  const published: Envelope[] = []
  const gate = { wait: Promise.resolve() }
  const service = {
    bootId: randomUUID(), health: "ready", on: () => () => {},
    publish: async (input: Pick<Envelope, "target" | "event">, eventId: string) => {
      await gate.wait
      const envelope = decodeEnvelope(encodeEnvelope({ ...input, eventId, originBootId: service.bootId, version: 1 }))
      if (envelope.event.kind !== "RealtimeDelivery") throw new Error("Unexpected event")
      published.push(envelope as Envelope)
      return { status: "published", subscribers: 2 }
    },
  }
  const live = new LiveRealtimeDelivery(service as unknown as InternalMessagingService, { enabled: () => enabled, receive: async () => {} })
  live.start()
  return { live, service, published, gate }
}

describe("local-first live fanout", () => {
  it("publishes and decodes a valid message update above the generic encryption ceiling", async () => {
    const updates = message("m".repeat(24_576))
    expect(UpdatesPayload.toBinary({ updates }).byteLength).toBeGreaterThan(20_000)
    const { live, published } = fixture()
    live.toUser(1, updates)
    await live.stop()
    expect(published).toHaveLength(1)
    expect(decodeLiveDelivery(published[0]!).updates).toEqual(updates)
    expect(live.diagnostics.dropped).toBe(0)
  })
  it("round-trips the full update ceiling and maximum recipient header through the broker frame", async () => {
    const updates = messageOfSize(MAX_LIVE_UPDATE_BYTES)
    const { live, published } = fixture()
    for (let i = 0; i < MAX_LIVE_RECIPIENTS; i++) live.toUser(2_147_483_647 - i * 16, updates, 2_147_483_647)
    await live.stop()
    expect(published).toHaveLength(1)
    const frame = decodeLiveDelivery(published[0]!)
    expect(frame.updates).toEqual(updates)
    expect(frame.userIds).toHaveLength(MAX_LIVE_RECIPIENTS)
    expect(frame.skipSessionId).toBe(2_147_483_647n)
    // The previous reader already supports this unchanged encrypted format.
    const plaintext = Encryption2.decryptBinary(Buffer.from(published[0]!.event.payload, "base64"))
    expect(plaintext.byteLength).toBeLessThanOrEqual(MAX_LIVE_ENVELOPE_BYTES)
    expect(RealtimeDelivery.fromBinary(plaintext).updates).toEqual(updates)
    expect(live.diagnostics.dropped).toBe(0)
  })
  it("rejects oversized updates on both publication and authenticated receive", async () => {
    const { live, published } = fixture()
    live.toUser(1, reaction())
    await live.drain()
    const oversized = messageOfSize(MAX_LIVE_UPDATE_BYTES + 1)
    live.toUser(1, oversized)
    await live.stop()
    expect(published).toHaveLength(1)
    expect(live.diagnostics.dropped).toBe(1)
    const envelope = published[0]!
    const frame = decodeLiveDelivery(envelope)
    frame.updates = oversized
    const payload = Encryption2.encryptWithLimit(RealtimeDelivery.toBinary(frame), MAX_LIVE_ENVELOPE_BYTES).toString("base64")
    expect(() => decodeLiveDelivery({ ...envelope, event: { ...envelope.event, payload } })).toThrow("updates too large")
    expect(() => decodeLiveDelivery({ ...envelope, event: { ...envelope.event,
      payload: Buffer.alloc(MAX_LIVE_ENVELOPE_BYTES + ENCRYPTION2_OVERHEAD_BYTES + 1).toString("base64"),
    } })).toThrow("envelope too large")
  })
  it("reports publication stage and numeric sizes without leaking failure or update contents", async () => {
    const warning = spyOn(Log.prototype, "warn").mockImplementation(() => {})
    try {
      const { live, service } = fixture()
      service.publish = async () => { throw new Error("private provider failure details") }
      live.toUser(1, message("private message contents"))
      await live.stop()
      expect(warning).toHaveBeenCalledWith(
        "Live realtime publication degraded; durable discovery remains available",
        expect.objectContaining({ reason: "publication_failed", stage: "publish", recipientCount: 1,
          updateBytes: expect.any(Number), envelopeBytes: expect.any(Number), dropped: 1 }),
      )
      expect(JSON.stringify(warning.mock.calls)).not.toContain("private")
    } finally { warning.mockRestore() }
  })
  it("defaults to local-only, permits explicit brokerless coordination, and rejects ambiguous mode settings", () => {
    expect(distributedRealtimeConfig({})).toEqual({ enabled: false, url: undefined })
    expect(distributedRealtimeConfig({ INLINE_REALTIME_DISTRIBUTED: "1" }).enabled).toBe(true)
    expect(distributedRealtimeConfig({ REDIS_URL: " ", VALKEY_URL: "redis://localhost" }).url).toBe("redis://localhost")
    expect(distributedRealtimeConfig({ REDIS_URL: "redis://localhost", INLINE_REALTIME_DISTRIBUTED: "0" })).toEqual({ enabled: false, url: undefined })
    expect(() => distributedRealtimeConfig({ INLINE_REALTIME_DISTRIBUTED: "auto" })).toThrow()
  })
  it("accepts the legacy mode name only when it agrees with the portable setting", () => {
    expect(distributedRealtimeConfig({ REALTIME_DISTRIBUTED: "1" }).enabled).toBe(true)
    expect(distributedRealtimeConfig({ REDIS_URL: "redis://localhost", REALTIME_DISTRIBUTED: "0" })).toEqual({ enabled: false, url: undefined })
    expect(distributedRealtimeConfig({ INLINE_REALTIME_DISTRIBUTED: "1", REALTIME_DISTRIBUTED: "1" }).enabled).toBe(true)
    expect(() => distributedRealtimeConfig({ INLINE_REALTIME_DISTRIBUTED: "0", REALTIME_DISTRIBUTED: "1" })).toThrow("must agree")
    expect(() => distributedRealtimeConfig({ INLINE_REALTIME_DISTRIBUTED: "0", REALTIME_DISTRIBUTED: "invalid" })).toThrow("must be 0 or 1")
  })
  it("orders Space profiles with recipient roster updates and keeps own removal in the user lane", () => {
    const profile: Update[] = [{ update: { oneofKind: "spaceProfile", spaceProfile: { spaceId: 9n, isPro: false } } }]
    const removal: Update[] = [{ update: { oneofKind: "spaceMemberDelete", spaceMemberDelete: { spaceId: 9n, userId: 1n } } }]
    expect(deliveryPartition(profile, 2)).toBe(deliveryPartition(profile, 0, 9))
    expect(deliveryPartition(removal, 2)).toBe(9)
    expect(deliveryPartition(removal, 1)).toBe(1)
  })
  it("does no publication work in local-only mode or while Redis is unavailable", async () => {
    const a = fixture(false)
    a.live.toUser(1, reaction())
    const b = fixture()
    b.service.health = "unavailable"
    b.live.toUser(1, reaction())
    await Promise.all([a.live.stop(), b.live.stop()])
    expect(a.published).toHaveLength(0)
    expect(b.published).toHaveLength(0)
    expect(a.live.diagnostics.queuedBytes).toBe(0)
  })
  it("groups only adjacent identical projections, preserves order and session exclusions, and authenticates recipients", async () => {
    const { live, published } = fixture()
    live.toUser(1, reaction(), 7)
    live.toUser(17, reaction(), 7)
    live.toUser(1, reaction("❤️"), 7)
    live.toUser(33, reaction(), 7)
    await live.stop()
    expect(published).toHaveLength(3)
    const frames = published.map((e) => decodeLiveDelivery(e))
    expect(frames.map((f) => f.userIds)).toEqual([[1n, 17n], [1n], [33n]])
    expect(frames[0]!.skipSessionId).toBe(7n)
    expect(frames[1]!.updates).toEqual(reaction("❤️"))
    expect(published[0]!.event.payload).not.toContain("👍")
    expect(() => decodeLiveDelivery({ ...published[0]!, eventId: randomUUID() })).toThrow()
    expect(() => decodeLiveDelivery(published[0]!, Date.now() + 3_000)).toThrow()
    const altered = { ...frames[0]!, userIds: [4n] }
    const tampered = Buffer.from(published[0]!.event.payload, "base64")
    tampered[tampered.length - 1]! ^= 1
    expect(() => decodeLiveDelivery({ ...published[0]!, event: { kind: "RealtimeDelivery", partition: published[0]!.event.partition, payload: tampered.toString("base64") } })).toThrow()
    expect(RealtimeDelivery.toBinary(altered).length).toBeGreaterThan(0)
  })
  it("bounds memory under a stalled publisher and drains accepted work before stop", async () => {
    const { live, published, gate } = fixture()
    const release = Promise.withResolvers<void>()
    gate.wait = release.promise
    live.toUser(1, reaction())
    await Promise.resolve()
    for (let i = 0; i < 1_000; i++) live.toUser(1, reaction("x".repeat(16_384)))
    expect(live.diagnostics.queuedBytes).toBeLessThanOrEqual(MAX_LIVE_QUEUE_BYTES)
    expect(live.diagnostics.queued).toBeLessThanOrEqual(MAX_LIVE_QUEUE_ENTRIES)
    expect(live.diagnostics.dropped).toBeGreaterThan(0)
    let stopped = false
    const stop = live.stop().then(() => { stopped = true })
    await Promise.resolve()
    expect(stopped).toBe(false)
    release.resolve()
    await stop
    expect(published.length).toBeGreaterThan(0)
    expect(live.diagnostics.queuedBytes).toBe(0)
  })
  it("does not echo events owned by other transports and keeps sender acknowledgement order", async () => {
    const { live, published } = fixture()
    live.toUser(1, [{ update: { oneofKind: "userHasNewUpdates", userHasNewUpdates: { updateSeq: 1 } } }])
    const ack: Update = { update: { oneofKind: "updateMessageId", updateMessageId: { messageId: 1n, randomId: 2n } } }
    live.toUser(1, [ack, ...reaction()])
    await live.stop()
    expect(published).toHaveLength(1)
    expect(decodeLiveDelivery(published[0]!).updates.map((u) => u.update.oneofKind)).toEqual(["updateMessageId", "deleteReaction"])
  })
  it("requires resource access for content but preserves own revocation controls", () => {
    expect([...liveRequirements(reaction(), 1).chats]).toEqual([9])
    expect([...liveRequirements([{ update: { oneofKind: "participantDelete", participantDelete: { chatId: 9n, userId: 1n } } }], 1).chats]).toEqual([])
    expect([...liveRequirements([{ update: { oneofKind: "participantDelete", participantDelete: { chatId: 9n, userId: 1n } } }], 2).chats]).toEqual([9])
    expect(() => liveRequirements([{ update: { oneofKind: "messageAttachment", messageAttachment: { chatId: 9n, messageId: 1n, peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } } } } }], 1)).toThrow()
  })
})

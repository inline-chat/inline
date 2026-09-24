import { describe, expect, it } from "bun:test"
import { randomUUID } from "node:crypto"
import { decodeEnvelope, encodeEnvelope, MAX_INTERNAL_FRAME_BYTES } from "./schemas"
import { SessionId, SpaceId, UserId } from "@in/server/core/schema/identifiers"

const durable = () => ({
  version: 1,
  eventId: randomUUID(),
  originBootId: randomUUID(),
  target: { kind: "cluster" },
  event: { kind: "DurableUpdatesAvailable", bucket: { kind: "chat", chatId: 7 }, frontier: 22 },
})

describe("internal messaging contracts", () => {
  it("round trips a validated durable reference", () => {
    const decoded = decodeEnvelope(JSON.stringify(durable()))
    expect(decodeEnvelope(encodeEnvelope(decoded))).toEqual(decoded)
  })

  it("round trips a Grid change hint without allowing a payload", () => {
    const hint = {
      version: 1 as const,
      eventId: randomUUID(),
      originBootId: randomUUID(),
      target: { kind: "cluster" as const },
      event: {
        kind: "GridChanged" as const,
        spaceId: SpaceId.make(7),
        roomId: 9,
      },
    }
    expect(decodeEnvelope(encodeEnvelope(hint))).toEqual(hint)
    expect(() => decodeEnvelope(JSON.stringify({
      ...hint,
      event: { ...hint.event, payload: "private" },
    }))).toThrow()
  })

  it("rejects excess fields, incompatible targets, invalid IDs and versions", () => {
    expect(() => decodeEnvelope(JSON.stringify({ ...durable(), extra: "ignored?" }))).toThrow()
    expect(() => decodeEnvelope(JSON.stringify({ ...durable(), target: { kind: "user", userId: 1 } }))).toThrow()
    expect(() => decodeEnvelope(JSON.stringify({ ...durable(), event: { ...durable().event, bucket: { kind: "chat", chatId: Number.MAX_SAFE_INTEGER + 1 } } }))).toThrow()
    expect(() => decodeEnvelope(JSON.stringify({ ...durable(), version: 2 }))).toThrow()
  })

  it("rejects large frames and expired private requests before dispatch", () => {
    expect(() => decodeEnvelope(" ".repeat(MAX_INTERNAL_FRAME_BYTES + 1))).toThrow()
    expect(() => decodeEnvelope(JSON.stringify({
      version: 1, eventId: randomUUID(), originBootId: randomUUID(),
      target: { kind: "connection", bootId: randomUUID(), connectionId: "socket", userId: 1, sessionId: 2 },
      event: { kind: "PrivateRequest", correlationId: randomUUID(), originBootId: randomUUID(),
        originConnection: { kind: "connection", bootId: randomUUID(), connectionId: "actor", userId: 2, sessionId: 3 },
        requestId: "18446744073709551615", deadlineMs: Date.now() - 1, payload: { kind: "botSettings", request: "{}" } },
    }))).toThrow()
  })

  it("round trips request IDs beyond JavaScript's safe integer range", () => {
    const originBootId = randomUUID()
    const privateMessage = {
      version: 1 as const, eventId: randomUUID(), originBootId,
      target: { kind: "connection" as const, bootId: randomUUID(), connectionId: "bot", userId: UserId.make(1), sessionId: SessionId.make(2) },
      event: { kind: "PrivateRequest" as const, correlationId: randomUUID(), originBootId,
        originConnection: { kind: "connection" as const, bootId: originBootId, connectionId: "actor", userId: UserId.make(3), sessionId: SessionId.make(4) },
        requestId: 18446744073709551615n, deadlineMs: Date.now() + 10_000,
        payload: { kind: "botSettings" as const, request: "e30=" },
      },
    }
    const decoded = decodeEnvelope(encodeEnvelope(privateMessage))
    expect(decoded.event.kind).toBe("PrivateRequest")
    if (decoded.event.kind === "PrivateRequest") expect(decoded.event.requestId).toBe(privateMessage.event.requestId)
  })

  it("requires an exact boot inbox for session-private credentials", () => {
    const envelope = {
      version: 1 as const, eventId: randomUUID(), originBootId: randomUUID(),
      target: { kind: "session" as const, bootId: randomUUID(), userId: UserId.make(1), sessionId: SessionId.make(2) },
      event: { kind: "SessionRealtime" as const, payload: { kind: "gridCredentials" as const,
        roomId: 3, spaceId: SpaceId.make(4), generation: 5, mediaMembershipId: randomUUID(), encodedPayload: "e30=" } },
    }
    expect(decodeEnvelope(encodeEnvelope(envelope))).toEqual(envelope)
    expect(() => decodeEnvelope(JSON.stringify({ ...envelope, target: { kind: "session", userId: 1, sessionId: 2 } }))).toThrow()
  })
})

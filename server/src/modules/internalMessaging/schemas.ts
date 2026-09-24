import { Schema } from "effect"
import { ChatId, SessionId, SpaceId, UserId } from "@in/server/core/schema/identifiers"
import { WireNonNegativeInteger, WirePositiveInteger } from "@in/server/core/schema/scalars"

const Uuid = Schema.String.check(Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i))
const ConnectionId = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128))
const Deadline = WirePositiveInteger

const ClusterTarget = Schema.Struct({ kind: Schema.Literal("cluster") })
const UserTarget = Schema.Struct({ kind: Schema.Literal("user"), userId: UserId })
const SessionTarget = Schema.Struct({ kind: Schema.Literal("session"), bootId: Uuid, userId: UserId, sessionId: SessionId })
const ConnectionTarget = Schema.Struct({
  kind: Schema.Literal("connection"),
  bootId: Uuid,
  connectionId: ConnectionId,
  userId: UserId,
  sessionId: SessionId,
})

const Bucket = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("chat"), chatId: ChatId }),
  Schema.Struct({ kind: Schema.Literal("space"), spaceId: SpaceId }),
  Schema.Struct({ kind: Schema.Literal("user"), userId: UserId }),
])

const DurableUpdatesAvailable = Schema.Struct({
  kind: Schema.Literal("DurableUpdatesAvailable"),
  bucket: Bucket,
  frontier: WireNonNegativeInteger,
  senderUserId: Schema.optional(UserId),
  excludeSessionId: Schema.optional(SessionId),
})

const TransientPayload = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("botPresenceChanged"), botUserId: UserId, chatId: ChatId, activityId: Uuid }),
  Schema.Struct({ kind: Schema.Literal("userPresenceChanged"), userId: UserId, online: Schema.Boolean, lastOnlineMs: Schema.NullOr(WireNonNegativeInteger) }),
  Schema.Struct({ kind: Schema.Literal("composeChanged"), userId: UserId, chatId: ChatId, action: Schema.Union([Schema.Literal("none"), Schema.Literal("typing"), Schema.Literal("uploadingDocument"), Schema.Literal("uploadingPhoto"), Schema.Literal("uploadingVideo"), Schema.Literal("recordingVoice")]) }),
])

const TransientRealtime = Schema.Struct({ kind: Schema.Literal("TransientRealtime"), payload: TransientPayload })
const SessionRevoked = Schema.Struct({ kind: Schema.Literal("SessionRevoked"), userId: UserId, sessionId: SessionId })
/** A committed Grid room change; receivers re-read and deliver only locally. */
const GridChanged = Schema.Struct({
  kind: Schema.Literal("GridChanged"),
  spaceId: SpaceId,
  roomId: Schema.optional(WirePositiveInteger),
})
const AccessChanged = Schema.Struct({
  kind: Schema.Literal("AccessChanged"),
  resource: Schema.Union([
    Schema.Struct({ kind: Schema.Literal("chat"), chatId: ChatId }),
    Schema.Struct({ kind: Schema.Literal("space"), spaceId: SpaceId }),
  ]),
  affectedUserId: Schema.optional(UserId),
})
const CacheInvalidated = Schema.Struct({
  kind: Schema.Literal("CacheInvalidated"),
  cache: Schema.Union([
    Schema.Struct({ kind: Schema.Literal("userSettings"), userId: UserId }),
    Schema.Struct({ kind: Schema.Literal("userDisplay"), userId: UserId }),
    Schema.Struct({ kind: Schema.Literal("chatMetadata"), chatId: ChatId }),
    Schema.Struct({ kind: Schema.Literal("spaceMetadata"), spaceId: SpaceId }),
    Schema.Struct({ kind: Schema.Literal("spaceRecipients"), spaceId: SpaceId }),
  ]),
})

const PrivateRequestPayload = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("botSettings"), request: Schema.String.check(Schema.isMaxLength(65536)) }),
  Schema.Struct({ kind: Schema.Literal("botFilesystem"), request: Schema.String.check(Schema.isMaxLength(16384)) }),
])
const PrivateReplyPayload = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("botSettings"), response: Schema.String.check(Schema.isMaxLength(393216)) }),
  Schema.Struct({ kind: Schema.Literal("botFilesystem"), response: Schema.String.check(Schema.isMaxLength(393216)) }),
  Schema.Struct({ kind: Schema.Literal("unavailable") }),
])
const PrivateRequest = Schema.Struct({
  kind: Schema.Literal("PrivateRequest"), correlationId: Uuid, originBootId: Uuid,
  originConnection: ConnectionTarget, requestId: Schema.BigIntFromString,
  deadlineMs: Deadline, payload: PrivateRequestPayload,
})
const PrivateReply = Schema.Struct({
  kind: Schema.Literal("PrivateReply"), correlationId: Uuid, originBootId: Uuid,
  replyFromConnectionId: ConnectionId, requestId: Schema.BigIntFromString,
  deadlineMs: Deadline, payload: PrivateReplyPayload,
})
const SessionRealtime = Schema.Struct({
  kind: Schema.Literal("SessionRealtime"),
  payload: Schema.Union([
    Schema.Struct({ kind: Schema.Literal("gridCredentials"), roomId: WirePositiveInteger, spaceId: SpaceId, generation: WireNonNegativeInteger, mediaMembershipId: Uuid, encodedPayload: Schema.String.check(Schema.isMaxLength(32768)) }),
  ]),
})

const Header = { version: Schema.Literal(1), eventId: Uuid, originBootId: Uuid }

/** The union makes invalid event/target pairs unrepresentable at the service boundary. */
export const InternalEnvelope = Schema.Union([
  Schema.Struct({ ...Header, target: ClusterTarget, event: DurableUpdatesAvailable }),
  Schema.Struct({ ...Header, target: UserTarget, event: TransientRealtime }),
  Schema.Struct({ ...Header, target: ClusterTarget, event: SessionRevoked }),
  Schema.Struct({ ...Header, target: ClusterTarget, event: GridChanged }),
  Schema.Struct({ ...Header, target: ClusterTarget, event: AccessChanged }),
  Schema.Struct({ ...Header, target: ClusterTarget, event: CacheInvalidated }),
  Schema.Struct({ ...Header, target: ConnectionTarget, event: PrivateRequest }),
  Schema.Struct({ ...Header, target: ConnectionTarget, event: PrivateReply }),
  Schema.Struct({ ...Header, target: SessionTarget, event: SessionRealtime }),
])

export type InternalEnvelope = typeof InternalEnvelope.Type
export type InternalEvent = InternalEnvelope["event"]

const strict = { onExcessProperty: "error" as const }
export const MAX_INTERNAL_FRAME_BYTES = 512 * 1024

export function decodeEnvelope(frame: string): InternalEnvelope {
  if (Buffer.byteLength(frame, "utf8") > MAX_INTERNAL_FRAME_BYTES) throw new Error("Internal frame exceeds size limit")
  const value: unknown = JSON.parse(frame)
  const envelope = Schema.decodeUnknownSync(InternalEnvelope, strict)(value)
  if ((envelope.event.kind === "PrivateRequest" || envelope.event.kind === "PrivateReply") && envelope.event.deadlineMs <= Date.now()) {
    throw new Error("Expired private message")
  }
  return envelope
}

export function encodeEnvelope(envelope: InternalEnvelope): string {
  const validated = Schema.encodeSync(InternalEnvelope, strict)(envelope)
  const frame = JSON.stringify(validated)
  if (Buffer.byteLength(frame, "utf8") > MAX_INTERNAL_FRAME_BYTES) throw new Error("Internal frame exceeds size limit")
  return frame
}

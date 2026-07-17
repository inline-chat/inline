import { Schema } from "effect"
import { InlineId } from "./scalars"

/** Inline user identity. Decode or construct it at an external boundary. */
export const UserId = InlineId.pipe(Schema.brand("UserId")).annotate({
  identifier: "UserId",
  description: "A positive Inline user identifier",
})

export type UserId = typeof UserId.Type

/** Inline login-session identity. */
export const SessionId = InlineId.pipe(Schema.brand("SessionId")).annotate({
  identifier: "SessionId",
  description: "A positive Inline session identifier",
})

export type SessionId = typeof SessionId.Type

/** Inline chat identity, including private and thread chats. */
export const ChatId = InlineId.pipe(
  Schema.brand("ChatId"),
).annotate({
  identifier: "ChatId",
  description: "A positive Inline chat identifier",
})

export type ChatId = typeof ChatId.Type

/** Inline message identity within its chat. */
export const MessageId = InlineId.pipe(
  Schema.brand("MessageId"),
).annotate({
  identifier: "MessageId",
  description: "A positive Inline message identifier",
})

export type MessageId = typeof MessageId.Type

/** Inline space identity. */
export const SpaceId = InlineId.pipe(
  Schema.brand("SpaceId"),
).annotate({
  identifier: "SpaceId",
  description: "A positive Inline space identifier",
})

export type SpaceId = typeof SpaceId.Type

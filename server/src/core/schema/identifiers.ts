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

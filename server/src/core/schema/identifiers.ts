import {
  Schema,
  SchemaGetter,
} from "effect"
import { InlineId } from "./scalars"

const idString = (
  identifier: string,
  description: string,
) =>
  Schema.String.check(
    Schema.isPattern(/^[1-9][0-9]*$/),
  ).annotate({
    identifier,
    description,
    examples: ["123456789"],
  })

const idStringTransformation = {
  decode: SchemaGetter.transform((value: string) =>
    Number(value),
  ),
  encode: SchemaGetter.transform((value: number) =>
    String(value),
  ),
}

/** Inline user identity. Decode or construct it at an external boundary. */
export const UserId = InlineId.pipe(Schema.brand("UserId")).annotate({
  identifier: "UserId",
  description: "A positive Inline user identifier",
})

export type UserId = typeof UserId.Type

const UserIdString = idString(
  "UserIdString",
  "A positive decimal Inline user identifier",
)

/** Query/path codec that decodes decimal text directly into a UserId. */
export const UserIdFromString = UserIdString.pipe(
  Schema.decodeTo(UserId, idStringTransformation),
).annotate({
  identifier: "UserIdFromString",
})

/** JSON/body codec accepting a user ID as an integer or decimal string. */
export const UserIdInput = Schema.Union([
  UserId,
  UserIdFromString,
]).annotate({
  identifier: "UserIdInput",
  description:
    "An Inline user identifier supplied as an integer or decimal string",
})

/** Inline login-session identity. */
export const SessionId = InlineId.pipe(Schema.brand("SessionId")).annotate({
  identifier: "SessionId",
  description: "A positive Inline session identifier",
})

export type SessionId = typeof SessionId.Type

const SessionIdString = idString(
  "SessionIdString",
  "A positive decimal Inline session identifier",
)

/** Query/path codec that decodes decimal text directly into a SessionId. */
export const SessionIdFromString = SessionIdString.pipe(
  Schema.decodeTo(SessionId, idStringTransformation),
).annotate({
  identifier: "SessionIdFromString",
})

/** JSON/body codec accepting a session ID as an integer or decimal string. */
export const SessionIdInput = Schema.Union([
  SessionId,
  SessionIdFromString,
]).annotate({
  identifier: "SessionIdInput",
  description:
    "An Inline session identifier supplied as an integer or decimal string",
})

/** Inline chat identity, including private and thread chats. */
export const ChatId = InlineId.pipe(
  Schema.brand("ChatId"),
).annotate({
  identifier: "ChatId",
  description: "A positive Inline chat identifier",
})

export type ChatId = typeof ChatId.Type

const ChatIdString = idString(
  "ChatIdString",
  "A positive decimal Inline chat identifier",
)

/** Query/path codec that decodes decimal text directly into a ChatId. */
export const ChatIdFromString = ChatIdString.pipe(
  Schema.decodeTo(ChatId, idStringTransformation),
).annotate({
  identifier: "ChatIdFromString",
})

/** JSON/body codec accepting a chat ID as an integer or decimal string. */
export const ChatIdInput = Schema.Union([
  ChatId,
  ChatIdFromString,
]).annotate({
  identifier: "ChatIdInput",
  description:
    "An Inline chat identifier supplied as an integer or decimal string",
})

/** Inline message identity within its chat. */
export const MessageId = InlineId.pipe(
  Schema.brand("MessageId"),
).annotate({
  identifier: "MessageId",
  description: "A positive Inline message identifier",
})

export type MessageId = typeof MessageId.Type

const MessageIdString = idString(
  "MessageIdString",
  "A positive decimal Inline message identifier",
)

/** Query/path codec that decodes decimal text directly into a MessageId. */
export const MessageIdFromString = MessageIdString.pipe(
  Schema.decodeTo(MessageId, idStringTransformation),
).annotate({
  identifier: "MessageIdFromString",
})

/** JSON/body codec accepting a message ID as an integer or decimal string. */
export const MessageIdInput = Schema.Union([
  MessageId,
  MessageIdFromString,
]).annotate({
  identifier: "MessageIdInput",
  description:
    "An Inline message identifier supplied as an integer or decimal string",
})

/** Inline space identity. */
export const SpaceId = InlineId.pipe(
  Schema.brand("SpaceId"),
).annotate({
  identifier: "SpaceId",
  description: "A positive Inline space identifier",
})

export type SpaceId = typeof SpaceId.Type

const SpaceIdString = idString(
  "SpaceIdString",
  "A positive decimal Inline space identifier",
)

/** Query/path codec that decodes decimal text directly into a SpaceId. */
export const SpaceIdFromString = SpaceIdString.pipe(
  Schema.decodeTo(SpaceId, idStringTransformation),
).annotate({
  identifier: "SpaceIdFromString",
})

/** JSON/body codec accepting a space ID as an integer or decimal string. */
export const SpaceIdInput = Schema.Union([
  SpaceId,
  SpaceIdFromString,
]).annotate({
  identifier: "SpaceIdInput",
  description:
    "An Inline space identifier supplied as an integer or decimal string",
})

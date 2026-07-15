import { Schema } from "effect"
import { PositiveInt32, PositiveInt64 } from "./numbers"

export const UserId = PositiveInt32.pipe(Schema.brand("inline/UserId"))
export type UserId = typeof UserId.Type

export const SessionId = PositiveInt32.pipe(Schema.brand("inline/SessionId"))
export type SessionId = typeof SessionId.Type

export const SpaceId = PositiveInt32.pipe(Schema.brand("inline/SpaceId"))
export type SpaceId = typeof SpaceId.Type

export const ChatId = PositiveInt32.pipe(Schema.brand("inline/ChatId"))
export type ChatId = typeof ChatId.Type

export const MessageId = PositiveInt32.pipe(Schema.brand("inline/MessageId"))
export type MessageId = typeof MessageId.Type

export const FileId = PositiveInt32.pipe(Schema.brand("inline/FileId"))
export type FileId = typeof FileId.Type

export const MessageGlobalId = PositiveInt64.pipe(Schema.brand("inline/MessageGlobalId"))
export type MessageGlobalId = typeof MessageGlobalId.Type

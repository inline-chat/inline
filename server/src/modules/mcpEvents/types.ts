import { Data } from "effect"
import type { McpEventSelector, McpEventSubscription } from "@in/server/db/schema/mcpEvents"
import type { OauthGrant } from "@in/server/db/models/oauth"

export type { McpEventSelector, McpEventSubscription }
export type EventBucket = { kind: "chat" | "space" | "user"; entityId: number }
export type EventPrincipal = { grant: OauthGrant; sessionId: number }
export type EventData = {
  kind: string
  chatId?: string
  spaceId?: string
  messageId?: string
  messageIds?: string[]
  userId?: string
  memberId?: string
  groupId?: string
  interactionId?: string
}
export type EventOccurrence = {
  eventId: string
  name: string
  timestamp: string
  data: EventData
  cursor: string
}
export type SubscribeResult = { id: string; refreshBefore: string; cursor: string; truncated: boolean }

export class McpEventsError extends Data.TaggedError("McpEventsError")<{
  code: number
  message: string
  reason?: string
  data?: Record<string, unknown>
}> {}

export const invalidParams = () => new McpEventsError({ code: -32602, message: "Invalid event parameters" })
export const accessDenied = () => new McpEventsError({ code: -32012, message: "Event access denied" })

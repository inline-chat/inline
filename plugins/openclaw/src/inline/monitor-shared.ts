export const CHANNEL_ID = "inline" as const

export type InlineReplyPayload = {
  isError?: boolean | undefined
  text?: string | undefined
  mediaUrl?: string | undefined
  mediaUrls?: string[] | undefined
  replyToId?: string | undefined
  channelData?: Record<string, unknown> | undefined
  isReasoning?: boolean | undefined
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

export function normalizeOptionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined
}

export function buildChatPeer(chatId: bigint): {
  type: {
    oneofKind: "chat"
    chat: { chatId: bigint }
  }
} {
  return {
    type: {
      oneofKind: "chat",
      chat: { chatId },
    },
  }
}

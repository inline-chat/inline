import type { MessageEntity_MessageEntityMention } from "@inline-chat/protocol/core"

export const mentionMdUrl = (userId: bigint, agentId?: bigint): string => {
  if (agentId !== undefined) {
    return `inline://user?id=${userId.toString()}&agent_id=${agentId.toString()}`
  }
  return `inline://user/${userId.toString()}`
}

export const parseMentionMdUrl = (rawUrl: string): MessageEntity_MessageEntityMention | null => {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }

  if (url.protocol.toLowerCase() !== "inline:" || url.hostname.toLowerCase() !== "user") {
    return null
  }

  const id = url.searchParams.get("id") ?? url.searchParams.get("user_id") ?? url.pathname.replace(/^\/+/, "")
  const userId = positiveInt64(id)
  if (userId === null) {
    return null
  }

  const rawAgentId = url.searchParams.get("agent_id")
  if (rawAgentId === null) {
    return { userId }
  }

  // A malformed Agent target must not silently become a mention of its backing user.
  const agentId = positiveInt64(rawAgentId)
  return agentId === null ? null : { userId, agentId }
}

const positiveInt64 = (value: string | null): bigint | null => {
  if (!value || !/^\d+$/.test(value)) return null
  const id = BigInt(value)
  return id > 0n && id <= 9_223_372_036_854_775_807n ? id : null
}

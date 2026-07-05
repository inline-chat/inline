export type InlineThreadFreshnessMessage = {
  id: bigint
  date?: bigint
  fromId?: bigint
  message?: string
  out?: boolean
  mentioned?: boolean
  entities?: unknown
  media?: unknown
}

export type InlineThreadFreshnessKind = "fresh" | "existing" | "unknown"

export type InlineThreadFreshness<T extends InlineThreadFreshnessMessage = InlineThreadFreshnessMessage> = {
  kind: InlineThreadFreshnessKind
  preJoinMessages: T[]
  priorMentionMessages: T[]
  reason: "history_unavailable" | "no_pre_join_messages" | "has_pre_join_messages"
}

export function resolveInlineThreadFreshness<T extends InlineThreadFreshnessMessage>(params: {
  messages: readonly T[] | null | undefined
  botUserId: bigint
  botUsername?: string | null | undefined
  participantDate?: bigint | null | undefined
}): InlineThreadFreshness<T> {
  if (!params.messages) {
    return {
      kind: "unknown",
      preJoinMessages: [],
      priorMentionMessages: [],
      reason: "history_unavailable",
    }
  }

  const preJoinMessages = params.messages.filter((message) => {
    if (!isPreJoinMessage(message, params.participantDate)) return false
    if (isBotAuthoredMessage(message, params.botUserId)) return false
    return hasVisibleThreadContent(message)
  })
  const priorMentionMessages = preJoinMessages.filter((message) => {
    return messageMentionsBot({
      message,
      botUserId: params.botUserId,
      botUsername: params.botUsername,
    })
  })

  if (preJoinMessages.length === 0) {
    return {
      kind: "fresh",
      preJoinMessages,
      priorMentionMessages,
      reason: "no_pre_join_messages",
    }
  }

  return {
    kind: "existing",
    preJoinMessages,
    priorMentionMessages,
    reason: "has_pre_join_messages",
  }
}

function isPreJoinMessage(
  message: InlineThreadFreshnessMessage,
  participantDate: bigint | null | undefined,
): boolean {
  if (participantDate == null || participantDate <= 0n) return true
  if (message.date == null || message.date <= 0n) return true
  return message.date <= participantDate
}

function isBotAuthoredMessage(message: InlineThreadFreshnessMessage, botUserId: bigint): boolean {
  return message.out === true || message.fromId === botUserId
}

function hasVisibleThreadContent(message: InlineThreadFreshnessMessage): boolean {
  return Boolean(message.message?.trim()) || Boolean(message.media) || Boolean(message.entities)
}

function messageMentionsBot(params: {
  message: InlineThreadFreshnessMessage
  botUserId: bigint
  botUsername?: string | null | undefined
}): boolean {
  if (params.message.mentioned === true) return true
  if (textMentionsUsername(params.message.message, params.botUsername)) return true
  return entitiesMentionBot(params.message.entities, params.botUserId)
}

function textMentionsUsername(
  text: string | undefined,
  botUsername: string | null | undefined,
): boolean {
  const username = botUsername?.trim().replace(/^@/u, "")
  if (!text || !username) return false
  const escaped = username.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  return new RegExp(`(^|\\s)@${escaped}(?=$|[\\s,.:;!?])`, "iu").test(text)
}

function entitiesMentionBot(entities: unknown, botUserId: bigint): boolean {
  const entries = readEntityEntries(entities)
  return entries.some((entry) => entityEntryMentionsBot(entry, botUserId))
}

function readEntityEntries(entities: unknown): unknown[] {
  if (Array.isArray(entities)) return entities
  if (!isRecord(entities)) return []
  return Array.isArray(entities.entities) ? entities.entities : []
}

function entityEntryMentionsBot(entry: unknown, botUserId: bigint): boolean {
  if (!isRecord(entry)) return false
  const entity = isRecord(entry.entity) ? entry.entity : entry
  const oneofKind = readString(entity.oneofKind)
  const mention = isRecord(entity.mention) ? entity.mention : entity
  if (oneofKind && oneofKind !== "mention") return false
  return readBigintLike(mention.userId) === botUserId
}

function readString(value: unknown): string | null {
  return typeof value === "string" ? value : null
}

function readBigintLike(value: unknown): bigint | null {
  if (typeof value === "bigint") return value
  if (typeof value === "number" && Number.isSafeInteger(value)) return BigInt(value)
  if (typeof value !== "string" || !/^\d+$/u.test(value.trim())) return null
  return BigInt(value.trim())
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

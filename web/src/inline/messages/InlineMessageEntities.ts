import {
  MessageEntity_Type,
  type MessageEntities,
} from "@inline-chat/protocol/core"

const MAX_MESSAGE_ENTITIES = 256

const record = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : undefined

const validEntityPayload = (value: unknown) => {
  const payload = record(value)
  if (!payload || typeof payload.oneofKind !== "string") {
    return payload?.oneofKind === undefined
  }
  const nested = record(payload[payload.oneofKind])
  if (!nested) return false
  switch (payload.oneofKind) {
    case "mention":
      return typeof nested.userId === "bigint" && nested.userId > 0n
    case "groupMention":
      return typeof nested.groupId === "bigint" && nested.groupId > 0n
    case "textUrl":
      return typeof nested.url === "string" && nested.url.length <= 8_192
    case "pre":
      return typeof nested.language === "string" && nested.language.length <= 128
    case "thread":
      return typeof nested.chatId === "bigint" && nested.chatId > 0n
    case "threadTitle":
      return (
        typeof nested.spaceId === "bigint" &&
        nested.spaceId > 0n &&
        typeof nested.title === "string" &&
        nested.title.length <= 1_024
      )
    default:
      return false
  }
}

const payloadMatchesType = (
  type: number,
  value: unknown,
) => {
  const oneofKind = record(value)?.oneofKind
  switch (type) {
    case MessageEntity_Type.MENTION:
      return oneofKind === "mention"
    case MessageEntity_Type.GROUP_MENTION:
      return oneofKind === "groupMention"
    case MessageEntity_Type.TEXT_URL:
      return oneofKind === "textUrl"
    case MessageEntity_Type.PRE:
      return oneofKind === "pre"
    case MessageEntity_Type.THREAD:
      return oneofKind === "thread"
    case MessageEntity_Type.THREAD_TITLE:
      return oneofKind === "threadTitle"
    default:
      return oneofKind === undefined
  }
}

const isUtf16Boundary = (text: string, offset: number) => {
  if (offset <= 0 || offset >= text.length) return true
  const before = text.charCodeAt(offset - 1)
  const after = text.charCodeAt(offset)
  return !(
    before >= 0xd800 &&
    before <= 0xdbff &&
    after >= 0xdc00 &&
    after <= 0xdfff
  )
}

/** Validates untrusted renderer entity input at the SharedWorker boundary.
 * Offsets are protocol UTF-16 offsets, matching JavaScript string indices and
 * Inline Apple's NSString/NSRange entity contract. */
export const isInlineMessageEntities = (
  value: unknown,
  text: string,
): value is MessageEntities => {
  if (value === undefined) return true
  const container = record(value)
  if (!container || !Array.isArray(container.entities)) return false
  if (container.entities.length > MAX_MESSAGE_ENTITIES) return false
  return container.entities.every((candidate) => {
    const entity = record(candidate)
    const type = Number(entity?.type)
    const offset = Number(entity?.offset)
    const length = Number(entity?.length)
    if (
      !entity ||
      !Number.isInteger(type) ||
      type < MessageEntity_Type.UNSPECIFIED ||
      type > MessageEntity_Type.GROUP_MENTION ||
      typeof entity.offset !== "bigint" ||
      typeof entity.length !== "bigint" ||
      entity.offset < 0n ||
      entity.length <= 0n ||
      entity.offset + entity.length > BigInt(text.length) ||
      !isUtf16Boundary(text, offset) ||
      !isUtf16Boundary(text, offset + length)
    ) {
      return false
    }
    return (
      payloadMatchesType(type, entity.entity) &&
      validEntityPayload(entity.entity)
    )
  })
}

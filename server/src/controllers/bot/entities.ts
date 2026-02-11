import { InlineError } from "@in/server/types/errors"
import { t } from "elysia"
import { MessageEntities, MessageEntity_Type, type MessageEntity } from "@in/protocol/core"
import type { BotMessageEntityOutput, BotUser } from "@inline-chat/bot-api-types"

const TInt64 = t.Union([t.Number(), t.String()])

export const TBotMessageEntityInput = t.Object({
  // Case-insensitive. Canonical output is lowercase.
  type: t.Union([t.String(), t.Number()]),
  offset: TInt64,
  length: TInt64,

  // TYPE_MENTION
  user_id: t.Optional(TInt64),

  // TYPE_TEXT_URL
  url: t.Optional(t.String()),

  // TYPE_PRE
  language: t.Optional(t.String()),

  // Compatibility: accept `user: { id }` even though the rest of the bot API is snake_case.
  // This is intentionally undocumented and will be normalized to `user_id`.
  user: t.Optional(t.Object({ id: TInt64 })),
})

export const TBotMessageEntitiesInput = t.Array(TBotMessageEntityInput)

export const TBotUserInline = t.Object({
  id: t.Number(),
  is_bot: t.Boolean(),
  username: t.Optional(t.String()),
  first_name: t.Optional(t.String()),
  last_name: t.Optional(t.String()),
})

export const TBotMessageEntityOutput = t.Object({
  type: t.String(), // lowercase
  offset: t.Number(),
  length: t.Number(),
  user: t.Optional(TBotUserInline), // mention only
  url: t.Optional(t.String()), // text_link only
  language: t.Optional(t.String()), // pre only
})

export const TBotMessageEntitiesOutput = t.Array(TBotMessageEntityOutput)

export type BotUserJson = BotUser
type BotEntityJson = BotMessageEntityOutput

const isPlainObject = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

const toInt = (value: unknown, error: InlineError): number => {
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw error
    return Math.trunc(value)
  }
  if (typeof value === "string") {
    if (!value.trim()) throw error
    const n = Number(value)
    if (!Number.isFinite(n)) throw error
    return Math.trunc(n)
  }
  throw error
}

const toBigInt = (value: unknown, error: InlineError): bigint => {
  if (typeof value === "bigint") return value
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw error
    return BigInt(Math.trunc(value))
  }
  if (typeof value === "string") {
    if (!value.trim()) throw error
    try {
      // Accept "123" only; callers should not send floats.
      return BigInt(value)
    } catch {
      throw error
    }
  }
  throw error
}

const normalizeType = (value: unknown): string | number => {
  if (typeof value === "number") return value
  if (typeof value !== "string") throw new InlineError(InlineError.ApiError.BAD_REQUEST)

  const raw = value.trim()
  if (!raw) throw new InlineError(InlineError.ApiError.BAD_REQUEST)

  // Lowercase, strip "type_" prefix, normalize separators.
  let normalized = raw.toLowerCase()
  normalized = normalized.replace(/^type_/, "")
  normalized = normalized.replace(/-/g, "_")

  // Keep API simple: accept a couple of common aliases.
  if (normalized === "textlink") normalized = "text_link"
  if (normalized === "texturl" || normalized === "text_url") normalized = "text_link"

  return normalized
}

const parseEntityType = (value: unknown): MessageEntity_Type => {
  const normalized = normalizeType(value)

  if (typeof normalized === "number") {
    // Best-effort: allow enum numbers.
    return normalized as MessageEntity_Type
  }

  switch (normalized) {
    case "mention":
      return MessageEntity_Type.MENTION
    case "url":
      return MessageEntity_Type.URL
    case "text_link":
      return MessageEntity_Type.TEXT_URL
    case "email":
      return MessageEntity_Type.EMAIL
    case "bold":
      return MessageEntity_Type.BOLD
    case "italic":
      return MessageEntity_Type.ITALIC
    case "username_mention":
      return MessageEntity_Type.USERNAME_MENTION
    case "code":
      return MessageEntity_Type.CODE
    case "pre":
      return MessageEntity_Type.PRE
    case "phone_number":
      return MessageEntity_Type.PHONE_NUMBER
    default:
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const typeToString = (type: MessageEntity_Type): BotMessageEntityOutput["type"] => {
  switch (type) {
    case MessageEntity_Type.MENTION:
      return "mention"
    case MessageEntity_Type.URL:
      return "url"
    case MessageEntity_Type.TEXT_URL:
      return "text_link"
    case MessageEntity_Type.EMAIL:
      return "email"
    case MessageEntity_Type.BOLD:
      return "bold"
    case MessageEntity_Type.ITALIC:
      return "italic"
    case MessageEntity_Type.USERNAME_MENTION:
      return "username_mention"
    case MessageEntity_Type.CODE:
      return "code"
    case MessageEntity_Type.PRE:
      return "pre"
    case MessageEntity_Type.PHONE_NUMBER:
      return "phone_number"
    default:
      return "unknown"
  }
}

export const parseBotEntities = (raw: unknown): MessageEntities | undefined => {
  if (raw === undefined || raw === null) return undefined
  if (!Array.isArray(raw)) throw new InlineError(InlineError.ApiError.BAD_REQUEST)

  const entities: MessageEntity[] = raw.map((item) => {
    if (!isPlainObject(item)) throw new InlineError(InlineError.ApiError.BAD_REQUEST)

    // Enforce snake_case keys for bot API params; allow `user` as a narrow compatibility exception.
    for (const key of Object.keys(item)) {
      if (key === "user") continue
      if (/[A-Z]/.test(key)) throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    const type = parseEntityType(item["type"])
    const offset = toBigInt(item["offset"], new InlineError(InlineError.ApiError.BAD_REQUEST))
    const length = toBigInt(item["length"], new InlineError(InlineError.ApiError.BAD_REQUEST))

    const base: MessageEntity = {
      type,
      offset,
      length,
      entity: { oneofKind: undefined },
    }

    if (type === MessageEntity_Type.MENTION) {
      const userIdRaw =
        item["user_id"] ??
        (isPlainObject(item["user"]) ? (item["user"] as any).id : undefined)
      const userId = toBigInt(userIdRaw, new InlineError(InlineError.ApiError.BAD_REQUEST))
      return {
        ...base,
        entity: { oneofKind: "mention", mention: { userId } },
      }
    }

    if (type === MessageEntity_Type.TEXT_URL) {
      const url = item["url"]
      if (typeof url !== "string" || !url.trim()) throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      return {
        ...base,
        entity: { oneofKind: "textUrl", textUrl: { url: url.trim() } },
      }
    }

    if (type === MessageEntity_Type.PRE) {
      const language = item["language"]
      if (typeof language !== "string" || !language.trim()) throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      return {
        ...base,
        entity: { oneofKind: "pre", pre: { language: language.trim() } },
      }
    }

    // Other types require no extra fields.
    return base
  })

  return { entities }
}

export const encodeBotEntities = (
  entities: MessageEntities | null | undefined,
  options?: { usersById?: Map<number, BotUserJson> },
): BotEntityJson[] | undefined => {
  if (!entities || !entities.entities || entities.entities.length === 0) return undefined

  return entities.entities.map((e) => {
    const out: BotEntityJson = {
      type: typeToString(e.type),
      offset: Number(e.offset),
      length: Number(e.length),
    }

    if (e.entity.oneofKind === "mention") {
      const userId = Number(e.entity.mention.userId)
      out.user = options?.usersById?.get(userId)
    } else if (e.entity.oneofKind === "textUrl") {
      out.url = e.entity.textUrl.url
    } else if (e.entity.oneofKind === "pre") {
      out.language = e.entity.pre.language
    }

    return out
  })
}

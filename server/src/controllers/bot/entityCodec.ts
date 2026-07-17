import type {
  BotMessageEntityOutput,
  BotUser,
} from "@inline-chat/bot-api-types"
import {
  MessageEntities,
  MessageEntity_Type,
  type MessageEntity,
} from "@inline-chat/protocol/core"
import { InlineError } from "@in/server/types/errors"

export type BotUserJson = BotUser
type BotEntityJson = BotMessageEntityOutput

const isPlainObject = (
  value: unknown,
): value is Record<string, unknown> =>
  typeof value === "object" &&
  value !== null &&
  !Array.isArray(value)

const toBigInt = (
  value: unknown,
  error: InlineError,
): bigint => {
  if (typeof value === "bigint") return value
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw error
    return BigInt(Math.trunc(value))
  }
  if (typeof value === "string") {
    if (!value.trim()) throw error
    try {
      return BigInt(value)
    } catch {
      throw error
    }
  }
  throw error
}

const normalizeType = (value: unknown): string | number => {
  if (typeof value === "number") return value
  if (typeof value !== "string") {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const raw = value.trim()
  if (!raw) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  let normalized = raw.toLowerCase()
  normalized = normalized.replace(/^type_/, "")
  normalized = normalized.replace(/-/g, "_")

  // TODO(effect-cutover): remove legacy entity spellings after production
  // telemetry shows no use by Bot clients for 30 days.
  if (normalized === "textlink") normalized = "text_link"
  if (
    normalized === "texturl" ||
    normalized === "text_url"
  ) {
    normalized = "text_link"
  }

  return normalized
}

const parseEntityType = (
  value: unknown,
): MessageEntity_Type => {
  const normalized = normalizeType(value)

  if (typeof normalized === "number") {
    if (
      normalized === MessageEntity_Type.THREAD ||
      normalized === MessageEntity_Type.THREAD_TITLE
    ) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }
    // TODO(effect-cutover): remove numeric entity types after production
    // telemetry shows no use by Bot clients for 30 days. New thread-link types
    // intentionally do not accept enum numbers.
    return normalized as MessageEntity_Type
  }

  const rejectNonCanonicalThreadType = () => {
    if (
      typeof value === "string" &&
      value.trim() !== normalized
    ) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }
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
    case "bot_command":
      return MessageEntity_Type.BOT_COMMAND
    case "thread":
      rejectNonCanonicalThreadType()
      return MessageEntity_Type.THREAD
    case "thread_title":
      rejectNonCanonicalThreadType()
      return MessageEntity_Type.THREAD_TITLE
    default:
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const rejectThreadEntityAliasFields = (
  item: Record<string, unknown>,
): void => {
  if (
    Object.prototype.hasOwnProperty.call(item, "thread_id")
  ) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }
}

const typeToString = (
  type: MessageEntity_Type,
): BotMessageEntityOutput["type"] => {
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
    case MessageEntity_Type.BOT_COMMAND:
      return "bot_command"
    case MessageEntity_Type.THREAD:
      return "thread"
    case MessageEntity_Type.THREAD_TITLE:
      return "thread_title"
    default:
      return "unknown"
  }
}

export const parseBotEntities = (
  raw: unknown,
): MessageEntities | undefined => {
  if (raw === undefined || raw === null) return undefined
  if (!Array.isArray(raw)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const entities: MessageEntity[] = raw.map((item) => {
    if (!isPlainObject(item)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    const type = parseEntityType(item["type"])
    rejectThreadEntityAliasFields(item)

    // TODO(effect-cutover): remove the `user` alias after production telemetry
    // shows no use by Bot clients for 30 days. All other input keys remain
    // snake_case.
    for (const key of Object.keys(item)) {
      if (key === "user") continue
      if (/[A-Z]/.test(key)) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
    }

    const offset = toBigInt(
      item["offset"],
      new InlineError(InlineError.ApiError.BAD_REQUEST),
    )
    const length = toBigInt(
      item["length"],
      new InlineError(InlineError.ApiError.BAD_REQUEST),
    )

    const base: MessageEntity = {
      type,
      offset,
      length,
      entity: { oneofKind: undefined },
    }

    if (type === MessageEntity_Type.MENTION) {
      const user = item["user"]
      const userIdRaw =
        item["user_id"] ??
        (isPlainObject(user) ? user["id"] : undefined)
      const userId = toBigInt(
        userIdRaw,
        new InlineError(InlineError.ApiError.BAD_REQUEST),
      )
      return {
        ...base,
        entity: {
          oneofKind: "mention",
          mention: { userId },
        },
      }
    }

    if (type === MessageEntity_Type.TEXT_URL) {
      const url = item["url"]
      if (typeof url !== "string" || !url.trim()) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      return {
        ...base,
        entity: {
          oneofKind: "textUrl",
          textUrl: { url: url.trim() },
        },
      }
    }

    if (type === MessageEntity_Type.PRE) {
      const language = item["language"]
      if (
        typeof language !== "string" ||
        !language.trim()
      ) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      return {
        ...base,
        entity: {
          oneofKind: "pre",
          pre: { language: language.trim() },
        },
      }
    }

    if (type === MessageEntity_Type.THREAD) {
      const chatId = toBigInt(
        item["chat_id"],
        new InlineError(InlineError.ApiError.BAD_REQUEST),
      )
      if (chatId <= 0n) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      return {
        ...base,
        entity: {
          oneofKind: "thread",
          thread: { chatId },
        },
      }
    }

    if (type === MessageEntity_Type.THREAD_TITLE) {
      const spaceId =
        item["space_id"] === undefined
          ? 0n
          : toBigInt(
              item["space_id"],
              new InlineError(
                InlineError.ApiError.BAD_REQUEST,
              ),
            )
      const title = item["title"]
      if (
        spaceId < 0n ||
        typeof title !== "string" ||
        !title.trim()
      ) {
        throw new InlineError(InlineError.ApiError.BAD_REQUEST)
      }
      return {
        ...base,
        entity: {
          oneofKind: "threadTitle",
          threadTitle: {
            spaceId,
            title: title.trim(),
          },
        },
      }
    }

    return base
  })

  return { entities }
}

export const encodeBotEntities = (
  entities: MessageEntities | null | undefined,
  options?: {
    usersById?: Map<number, BotUserJson>
  },
): BotEntityJson[] | undefined => {
  if (
    !entities ||
    !entities.entities ||
    entities.entities.length === 0
  ) {
    return undefined
  }

  return entities.entities.map((entity) => {
    const out: BotEntityJson = {
      type: typeToString(entity.type),
      offset: Number(entity.offset),
      length: Number(entity.length),
    }

    if (entity.entity.oneofKind === "mention") {
      const userId = Number(entity.entity.mention.userId)
      out.user = options?.usersById?.get(userId)
    } else if (entity.entity.oneofKind === "textUrl") {
      out.url = entity.entity.textUrl.url
    } else if (entity.entity.oneofKind === "pre") {
      out.language = entity.entity.pre.language
    } else if (entity.entity.oneofKind === "thread") {
      out.chat_id = Number(entity.entity.thread.chatId)
    } else if (
      entity.entity.oneofKind === "threadTitle"
    ) {
      if (entity.entity.threadTitle.spaceId > 0n) {
        out.space_id = Number(
          entity.entity.threadTitle.spaceId,
        )
      }
      out.title = entity.entity.threadTitle.title
    }

    return out
  })
}

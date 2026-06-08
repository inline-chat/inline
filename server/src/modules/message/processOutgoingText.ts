import { MessageEntities, MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { lower, userNotDeleted, users } from "@in/server/db/schema"
import { processMessageText } from "@in/server/modules/message/processText"
import { and, inArray } from "drizzle-orm"

type ProcessOutgoingTextInput = {
  text: string
  entities: MessageEntities | undefined
  parseMarkdown?: boolean
}

type ProcessOutgoingTextOutput = {
  text: string
  entities: MessageEntities | undefined
}

type MentionCandidate = {
  offset: number
  length: number
  username: string
}

type BotCommandCandidate = {
  offset: number
  length: number
}

type InlineMentionLink = {
  entity: MessageEntity
  userId?: number
  username?: string
}

type InlineThreadLinkTarget =
  | {
      kind: "chat"
      chatId: number
    }
  | {
      kind: "title"
      spaceId: number
      title: string
    }

const isMentionChar = (char: string): boolean => {
  const code = char.charCodeAt(0)
  return (
    (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code === 95
  )
}

const isBotCommandBoundary = (char: string | undefined): boolean => {
  return char === undefined || /\s/.test(char)
}

const extractBotCommandCandidates = (text: string): BotCommandCandidate[] => {
  const candidates: BotCommandCandidate[] = []

  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "/") {
      continue
    }

    if (!isBotCommandBoundary(text[i - 1])) {
      continue
    }

    let end = i + 1
    while (end < text.length && isMentionChar(text[end]!)) {
      end += 1
    }

    const commandLength = end - i - 1
    if (commandLength < 1 || commandLength > 32) {
      continue
    }

    if (text[end] === "@") {
      const suffixStart = end
      end += 1

      while (end < text.length && isMentionChar(text[end]!)) {
        end += 1
      }

      if (end === suffixStart + 1) {
        end = suffixStart
      }
    }

    candidates.push({
      offset: i,
      length: end - i,
    })

    i = end - 1
  }

  return candidates
}

const extractMentionCandidates = (text: string): MentionCandidate[] => {
  const candidates: MentionCandidate[] = []

  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "@") {
      continue
    }

    if (i > 0 && isMentionChar(text[i - 1]!)) {
      continue
    }

    let end = i + 1
    while (end < text.length && isMentionChar(text[end]!)) {
      end += 1
    }

    const username = text.slice(i + 1, end)
    if (username.length < 2) {
      continue
    }

    candidates.push({
      offset: i,
      length: end - i,
      username,
    })

    i = end - 1
  }

  return candidates
}

const getClientEntityRanges = (
  entities: MessageEntities | undefined,
): Array<{ start: number; end: number }> => {
  if (!entities || entities.entities.length === 0) {
    return []
  }

  return entities.entities
    .filter((entity): entity is MessageEntity => entity !== undefined)
    .map((entity) => {
      const start = Number(entity.offset)
      const end = Number(entity.offset + entity.length)
      return { start, end }
    })
}

const isRangeOverlappingClientEntity = (
  range: { start: number; end: number },
  clientEntityRanges: Array<{ start: number; end: number }>,
): boolean => {
  return clientEntityRanges.some((clientRange) => {
    return range.start < clientRange.end && clientRange.start < range.end
  })
}

const sortEntities = (entities: MessageEntity[]): MessageEntity[] => {
  entities.sort((a, b) => {
    if (a.offset === b.offset) {
      if (a.length === b.length) {
        return 0
      }
      return a.length < b.length ? -1 : 1
    }
    return a.offset < b.offset ? -1 : 1
  })

  return entities
}

const parsePositiveSafeInt = (value: string | null): number | null => {
  if (!value || !/^\d+$/.test(value)) {
    return null
  }

  const id = Number(value)
  if (!Number.isSafeInteger(id) || id <= 0) {
    return null
  }

  return id
}

const normalizeUsername = (value: string | null): string | null => {
  const username = value?.trim().replace(/^@/, "").toLowerCase()
  if (!username || username.length < 2 || !/^[a-z0-9_]+$/.test(username)) {
    return null
  }

  return username
}

const parseInlineUserLink = (rawUrl: string): { userId?: number; username?: string } | null => {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }

  if (url.protocol.toLowerCase() !== "inline:" || url.hostname.toLowerCase() !== "user") {
    return null
  }

  const queryUserId = parsePositiveSafeInt(url.searchParams.get("id") ?? url.searchParams.get("user_id"))
  const pathUserId = parsePositiveSafeInt(url.pathname.replace(/^\/+/, ""))
  const username = normalizeUsername(url.searchParams.get("username"))

  if (queryUserId) {
    return { userId: queryUserId }
  }
  if (pathUserId) {
    return { userId: pathUserId }
  }
  if (username) {
    return { username }
  }

  return null
}

const trimTitle = (value: string | null | undefined): string | null => {
  const title = value?.trim()
  return title ? title : null
}

const parseInlineThreadLink = (rawUrl: string, visibleText: string): InlineThreadLinkTarget | null => {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }

  if (url.protocol.toLowerCase() !== "inline:") {
    return null
  }

  const host = url.hostname.toLowerCase()
  if (host !== "chat" && host !== "thread") {
    return null
  }

  const queryChatId = parsePositiveSafeInt(url.searchParams.get("id") ?? url.searchParams.get("chat_id"))
  const pathChatId = parsePositiveSafeInt(url.pathname.replace(/^\/+/, ""))
  const chatId = queryChatId ?? pathChatId
  if (chatId) {
    return { kind: "chat", chatId }
  }

  if (host !== "thread") {
    return null
  }

  const spaceId = parsePositiveSafeInt(url.searchParams.get("space_id"))
  const title = trimTitle(url.searchParams.get("title")) ?? trimTitle(visibleText)
  if (!spaceId || !title) {
    return null
  }

  return { kind: "title", spaceId, title }
}

const entityText = (text: string, entity: MessageEntity): string => {
  const start = Number(entity.offset)
  const length = Number(entity.length)
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(length) ||
    start < 0 ||
    length <= 0 ||
    start + length > text.length
  ) {
    return ""
  }

  return text.slice(start, start + length)
}

const isEntityWhitespace = (char: string | undefined): boolean => {
  return char !== undefined && /\s/u.test(char)
}

const trimMentionEntity = (text: string, entity: MessageEntity): MessageEntity | null => {
  const start = Number(entity.offset)
  const length = Number(entity.length)
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(length) ||
    start < 0 ||
    length <= 0 ||
    start + length > text.length
  ) {
    return entity
  }

  let nextStart = start
  let nextEnd = start + length
  while (nextStart < nextEnd && isEntityWhitespace(text[nextStart])) {
    nextStart += 1
  }
  while (nextEnd > nextStart && isEntityWhitespace(text[nextEnd - 1])) {
    nextEnd -= 1
  }

  if (nextStart === nextEnd) {
    return null
  }
  if (nextStart === start && nextEnd === start + length) {
    return entity
  }

  return {
    ...entity,
    offset: BigInt(nextStart),
    length: BigInt(nextEnd - nextStart),
  }
}

const normalizeMentionRanges = (text: string, entities: MessageEntities | undefined): MessageEntities | undefined => {
  if (!entities || entities.entities.length === 0) {
    return entities
  }

  let changed = false
  const normalized: MessageEntity[] = []
  for (const entity of entities.entities) {
    if (!entity) {
      changed = true
      continue
    }

    if (entity.type !== MessageEntity_Type.MENTION) {
      normalized.push(entity)
      continue
    }

    const next = trimMentionEntity(text, entity)
    if (!next) {
      changed = true
      continue
    }

    if (next !== entity) {
      changed = true
    }
    normalized.push(next)
  }

  if (!changed) {
    return entities
  }

  return normalized.length > 0 ? { entities: sortEntities(normalized) } : undefined
}

const resolveInlineMentionLinks = async (
  entities: MessageEntities | undefined,
): Promise<MessageEntities | undefined> => {
  if (!entities || entities.entities.length === 0) {
    return entities
  }

  const links: InlineMentionLink[] = []
  for (const entity of entities.entities) {
    if (
      entity?.type !== MessageEntity_Type.TEXT_URL ||
      entity.entity.oneofKind !== "textUrl" ||
      !entity.entity.textUrl.url
    ) {
      continue
    }

    const parsed = parseInlineUserLink(entity.entity.textUrl.url)
    if (!parsed) {
      continue
    }

    links.push({
      entity,
      ...(parsed.userId ? { userId: parsed.userId } : {}),
      ...(parsed.username ? { username: parsed.username } : {}),
    })
  }

  if (links.length === 0) {
    return entities
  }

  const ids = [...new Set(links.map((link) => link.userId).filter((id): id is number => id !== undefined))]
  const usernames = [
    ...new Set(links.map((link) => link.username).filter((username): username is string => username !== undefined)),
  ]

  const usersById = new Map<number, number>()
  const usersByUsername = new Map<string, number>()

  if (ids.length > 0) {
    const rows = await db
      .select({
        id: users.id,
        username: users.username,
      })
      .from(users)
      .where(and(inArray(users.id, ids), userNotDeleted()))

    for (const user of rows) {
      usersById.set(user.id, user.id)
      if (user.username) {
        usersByUsername.set(user.username.toLowerCase(), user.id)
      }
    }
  }

  if (usernames.length > 0) {
    const rows = await db
      .select({
        id: users.id,
        username: users.username,
      })
      .from(users)
      .where(and(inArray(lower(users.username), usernames), userNotDeleted()))

    for (const user of rows) {
      usersById.set(user.id, user.id)
      if (user.username) {
        usersByUsername.set(user.username.toLowerCase(), user.id)
      }
    }
  }

  let changed = false
  const resolvedEntities = entities.entities.map((entity) => {
    const link = links.find((candidate) => candidate.entity === entity)
    if (!link) {
      return entity
    }

    let userId: number | undefined
    if (link.userId) {
      userId = usersById.get(link.userId)
    } else if (link.username) {
      userId = usersByUsername.get(link.username)
    }
    if (!userId) {
      return entity
    }

    changed = true
    return {
      ...entity,
      type: MessageEntity_Type.MENTION,
      entity: {
        oneofKind: "mention" as const,
        mention: {
          userId: BigInt(userId),
        },
      },
    }
  })

  if (!changed) {
    return entities
  }

  return {
    entities: resolvedEntities,
  }
}

const resolveInlineThreadLinks = (
  text: string,
  entities: MessageEntities | undefined,
): MessageEntities | undefined => {
  if (!entities || entities.entities.length === 0) {
    return entities
  }

  let changed = false
  const resolvedEntities = entities.entities.map((entity) => {
    if (
      entity?.type !== MessageEntity_Type.TEXT_URL ||
      entity.entity.oneofKind !== "textUrl" ||
      !entity.entity.textUrl.url
    ) {
      return entity
    }

    const target = parseInlineThreadLink(entity.entity.textUrl.url, entityText(text, entity))
    if (!target) {
      return entity
    }

    changed = true
    if (target.kind === "chat") {
      return {
        ...entity,
        type: MessageEntity_Type.THREAD,
        entity: {
          oneofKind: "thread" as const,
          thread: {
            chatId: BigInt(target.chatId),
          },
        },
      }
    }

    return {
      ...entity,
      type: MessageEntity_Type.THREAD_TITLE,
      entity: {
        oneofKind: "threadTitle" as const,
        threadTitle: {
          spaceId: BigInt(target.spaceId),
          title: target.title,
        },
      },
    }
  })

  if (!changed) {
    return entities
  }

  return {
    entities: resolvedEntities,
  }
}

const parseMissingBotCommandEntities = ({
  text,
  entities,
}: {
  text: string | undefined
  entities: MessageEntities | undefined
}): MessageEntities | undefined => {
  if (!text || !text.includes("/")) {
    return entities
  }

  const commandCandidates = extractBotCommandCandidates(text)
  if (commandCandidates.length === 0) {
    return entities
  }

  const clientEntityRanges = getClientEntityRanges(entities)
  const parsedCommandEntities = commandCandidates
    .filter((candidate) => {
      return !isRangeOverlappingClientEntity(
        { start: candidate.offset, end: candidate.offset + candidate.length },
        clientEntityRanges,
      )
    })
    .map<MessageEntity>((candidate) => ({
      type: MessageEntity_Type.BOT_COMMAND,
      offset: BigInt(candidate.offset),
      length: BigInt(candidate.length),
      entity: { oneofKind: undefined },
    }))

  if (parsedCommandEntities.length === 0) {
    return entities
  }

  const existingEntities = (entities?.entities ?? []).filter((entity): entity is MessageEntity => entity !== undefined)
  return {
    entities: sortEntities([...existingEntities, ...parsedCommandEntities]),
  }
}

const parseMissingMentionEntitiesByUsername = async ({
  text,
  entities,
}: {
  text: string | undefined
  entities: MessageEntities | undefined
}): Promise<MessageEntities | undefined> => {
  if (!text || !text.includes("@")) {
    return entities
  }

  const mentionCandidates = extractMentionCandidates(text)
  if (mentionCandidates.length === 0) {
    return entities
  }

  const clientEntityRanges = getClientEntityRanges(entities)
  const unresolvedMentionCandidates = mentionCandidates.filter((candidate) => {
    return !isRangeOverlappingClientEntity(
      { start: candidate.offset, end: candidate.offset + candidate.length },
      clientEntityRanges,
    )
  })

  if (unresolvedMentionCandidates.length === 0) {
    return entities
  }

  const normalizedUsernames = [...new Set(unresolvedMentionCandidates.map((candidate) => candidate.username.toLowerCase()))]
  if (normalizedUsernames.length === 0) {
    return entities
  }

  const matchedUsers = await db
    .select({
      id: users.id,
      username: users.username,
    })
    .from(users)
    .where(and(inArray(lower(users.username), normalizedUsernames), userNotDeleted()))

  if (matchedUsers.length === 0) {
    return entities
  }

  const userIdByUsername = new Map<string, number>()
  for (const matchedUser of matchedUsers) {
    if (!matchedUser.username) {
      continue
    }
    userIdByUsername.set(matchedUser.username.toLowerCase(), matchedUser.id)
  }

  const parsedMentionEntities: MessageEntity[] = []
  for (const candidate of unresolvedMentionCandidates) {
    const userId = userIdByUsername.get(candidate.username.toLowerCase())
    if (!userId) {
      continue
    }

    parsedMentionEntities.push({
      type: MessageEntity_Type.MENTION,
      offset: BigInt(candidate.offset),
      length: BigInt(candidate.length),
      entity: {
        oneofKind: "mention",
        mention: {
          userId: BigInt(userId),
        },
      },
    })
  }

  if (parsedMentionEntities.length === 0) {
    return entities
  }

  const existingEntities = (entities?.entities ?? []).filter((entity): entity is MessageEntity => entity !== undefined)

  return {
    entities: sortEntities([...existingEntities, ...parsedMentionEntities]),
  }
}

export const processOutgoingText = async (
  input: ProcessOutgoingTextInput,
): Promise<ProcessOutgoingTextOutput> => {
  let text = input.text
  let entities = input.entities

  if (input.parseMarkdown) {
    const processed = processMessageText({ text: input.text, entities: input.entities })
    text = processed.text
    entities = processed.entities
  }

  entities = await resolveInlineMentionLinks(entities)
  entities = normalizeMentionRanges(text, entities)
  entities = resolveInlineThreadLinks(text, entities)
  entities = parseMissingBotCommandEntities({
    text,
    entities,
  })
  entities = await parseMissingMentionEntitiesByUsername({
    text,
    entities,
  })

  return { text, entities }
}

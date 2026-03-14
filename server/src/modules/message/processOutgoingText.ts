import { MessageEntities, MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { lower, users } from "@in/server/db/schema"
import { processMessageText } from "@in/server/modules/message/processText"
import { inArray } from "drizzle-orm"

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

const isMentionChar = (char: string): boolean => {
  const code = char.charCodeAt(0)
  return (
    (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    code === 95
  )
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
    .where(inArray(lower(users.username), normalizedUsernames))

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
  const combinedEntities = [...existingEntities, ...parsedMentionEntities]
  combinedEntities.sort((a, b) => {
    if (a.offset === b.offset) {
      if (a.length === b.length) {
        return 0
      }
      return a.length < b.length ? -1 : 1
    }
    return a.offset < b.offset ? -1 : 1
  })

  return {
    entities: combinedEntities,
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

  entities = await parseMissingMentionEntitiesByUsername({
    text,
    entities,
  })

  return { text, entities }
}

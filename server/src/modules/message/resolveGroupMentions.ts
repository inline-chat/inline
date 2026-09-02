import type { DbChat } from "@in/server/db/schema"
import { resolveMentionedGroupUserIds, validateMentionedGroups } from "@in/server/modules/userGroups"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { parseGroupMentionMdUrl } from "../translation2/entities/groupMention"
import { toRange } from "../translation2/entities/offsets"

type Input = {
  text: string
  entities: MessageEntities | undefined
  chat: DbChat
  currentUserId: number
}

/** Resolve explicit group links only at an authorized send/edit boundary.
 * Translation may decode identity without side effects; generic Markdown or
 * imported history must not start expanding groups or notifying their members. */
export const resolveGroupMentions = async (
  input: Input,
  resolveRecipients: typeof resolveMentionedGroupUserIds = resolveMentionedGroupUserIds,
): Promise<{ entities: MessageEntities | undefined; mentionedUserIds: number[] }> => {
  const normalized = normalizeGroupMentions(input)
  if (normalized.groupIds.length === 0) return { entities: normalized.entities, mentionedUserIds: [] }
  // Existing authority checks space scope, public-space visibility and active
  // membership, and excludes the sender. No converted result escapes on denial.
  const mentionedUserIds = await resolveRecipients({
    chat: input.chat, currentUserId: input.currentUserId, groupIds: normalized.groupIds,
  })
  return { entities: normalized.entities, mentionedUserIds }
}

export const validateGroupMentions = async (
  input: Input,
  validateGroups: typeof validateMentionedGroups = validateMentionedGroups,
): Promise<MessageEntities | undefined> => {
  const normalized = normalizeGroupMentions(input)
  if (normalized.groupIds.length > 0) {
    await validateGroups({
      chat: input.chat, currentUserId: input.currentUserId, groupIds: normalized.groupIds,
    })
  }
  return normalized.entities
}

function normalizeGroupMentions(input: Input): {
  entities: MessageEntities | undefined
  groupIds: number[]
} {
  if (!input.entities?.entities.length) return { entities: input.entities, groupIds: [] }
  const groupIds = new Set<number>()
  let changed = false
  const groupByRange = new Map<string, bigint>()
  const resolved: MessageEntity[] = []
  for (const source of input.entities.entities) {
    if (!source) throw RealtimeRpcError.BadRequest()
    let entity = source
    if (source.type === MessageEntity_Type.TEXT_URL && source.entity.oneofKind === "textUrl") {
      const groupId = parseGroupMentionMdUrl(source.entity.textUrl.url)
      if (groupId !== null) {
        entity = { ...source, type: MessageEntity_Type.GROUP_MENTION,
          entity: { oneofKind: "groupMention", groupMention: { groupId } } }
        changed = true
      }
    }
    if (entity.type !== MessageEntity_Type.GROUP_MENTION) {
      resolved.push(entity)
      continue
    }
    if (entity.entity.oneofKind !== "groupMention" || !toRange(input.text, entity)) {
      throw RealtimeRpcError.BadRequest()
    }
    const id = entity.entity.groupMention.groupId
    // The wire/translation target is Int64, but user_groups.id is PostgreSQL
    // serial (Int32). Reject impossible targets before binding a DB parameter.
    if (id <= 0n || id > 2_147_483_647n) throw RealtimeRpcError.PeerIdInvalid()
    groupIds.add(Number(id))
    const rangeKey = `${entity.offset}:${entity.length}`
    const previous = groupByRange.get(rangeKey)
    if (previous !== undefined) {
      if (previous !== id) throw RealtimeRpcError.BadRequest()
      changed = true
      continue
    }
    groupByRange.set(rangeKey, id)
    resolved.push(entity)
  }
  return {
    entities: changed ? { entities: resolved } : input.entities,
    groupIds: [...groupIds],
  }
}

import { MessageEntities, MessageEntity_Type } from "@inline-chat/protocol/core"

export const getMentionedUserIds = (entities: MessageEntities | undefined): number[] => {
  if (!entities) {
    return []
  }

  const userIds = new Set<number>()

  for (const entity of entities.entities) {
    if (entity?.type !== MessageEntity_Type.MENTION || entity.entity.oneofKind !== "mention") {
      continue
    }

    const userId = Number(entity.entity.mention.userId)
    if (Number.isSafeInteger(userId) && userId > 0) {
      userIds.add(userId)
    }
  }

  return Array.from(userIds)
}

export const getMentionedGroupIds = (entities: MessageEntities | undefined): number[] => {
  if (!entities) {
    return []
  }

  const groupIds = new Set<number>()

  for (const entity of entities.entities) {
    if (entity?.type !== MessageEntity_Type.GROUP_MENTION || entity.entity.oneofKind !== "groupMention") {
      continue
    }

    const groupId = Number(entity.entity.groupMention.groupId)
    if (Number.isSafeInteger(groupId) && groupId > 0) {
      groupIds.add(groupId)
    }
  }

  return Array.from(groupIds)
}

/**
 * Check if a user is mentioned in a message
 *
 * @param entities - The entities of the message
 * @param userId - The user ID to check for
 *
 * @returns True if the user is mentioned, false otherwise
 */
export const isUserMentioned = (
  entities: MessageEntities,
  userId: number,
  resolvedMentionedUserIds?: ReadonlySet<number>,
) => {
  if (resolvedMentionedUserIds?.has(userId)) {
    return true
  }

  return getMentionedUserIds(entities).includes(userId)
}

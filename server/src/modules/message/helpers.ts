import { MessageEntities, MessageEntity_Type } from "@in/protocol/core"

/**
 * Check if a user is mentioned in a message
 *
 * @param entities - The entities of the message
 * @param userId - The user ID to check for
 *
 * @returns True if the user is mentioned, false otherwise
 */
export const isUserMentioned = (entities: MessageEntities, userId: number) => {
  return entities.entities.some(
    (e) =>
      e.type === MessageEntity_Type.MENTION &&
      e.entity.oneofKind === "mention" &&
      e.entity.mention.userId === BigInt(userId),
  )
}

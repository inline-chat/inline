import type { UserID } from "@inline/ids"
import type {
  ChatMessageReaction,
  ChatMessageReactions,
} from "./ChatRowListModel"

export type MessageReactionGroup = {
  emoji: string
  reactions: ChatMessageReaction[]
  weReacted: boolean
  pending: boolean
}

export const resolveMessageReactionGroups = (
  state: ChatMessageReactions | undefined,
  currentUserId: UserID,
): MessageReactionGroup[] => {
  if (!state) return []
  const byEmoji = new Map<string, Map<UserID, ChatMessageReaction>>()
  for (const reaction of state.reactions) {
    let byUser = byEmoji.get(reaction.emoji)
    if (!byUser) {
      byUser = new Map()
      byEmoji.set(reaction.emoji, byUser)
    }
    byUser.set(reaction.userId, reaction)
  }

  const pendingEmojis = new Set<string>()
  for (const intent of state.intents) {
    if (intent.userId !== currentUserId) continue
    pendingEmojis.add(intent.emoji)
    let byUser = byEmoji.get(intent.emoji)
    if (!byUser) {
      byUser = new Map()
      byEmoji.set(intent.emoji, byUser)
    }
    if (intent.action === "add") {
      byUser.set(currentUserId, {
        emoji: intent.emoji,
        userId: currentUserId,
      })
    } else {
      byUser.delete(currentUserId)
    }
  }

  return [...byEmoji.entries()]
    .map(([emoji, byUser]) => ({
      emoji,
      reactions: [...byUser.values()].sort(
        (left, right) => (right.date ?? 0) - (left.date ?? 0),
      ),
      weReacted: byUser.has(currentUserId),
      pending: pendingEmojis.has(emoji),
    }))
    .filter((group) => group.reactions.length > 0)
    .sort((left, right) => {
      if (left.reactions.length !== right.reactions.length) {
        return right.reactions.length - left.reactions.length
      }
      return left.emoji < right.emoji
        ? -1
        : left.emoji > right.emoji
          ? 1
          : 0
    })
}

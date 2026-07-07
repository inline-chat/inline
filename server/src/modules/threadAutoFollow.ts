import type { DbChat } from "@in/server/db/schema"
import { getReplyThreadAnchorSenderId, isReplyThread } from "@in/server/modules/subthreads"

export const FRESH_NORMAL_THREAD_MESSAGE_ID_LIMIT = 15

type ThreadFollowChat = Pick<DbChat, "type">
type ThreadAutoFollowChat = Pick<DbChat, "type" | "parentChatId" | "parentMessageId">

export function canUseThreadFollowMode(chat: ThreadFollowChat): boolean {
  return chat.type === "thread"
}

export function shouldAutoFollowThreadMessage(
  chat: ThreadAutoFollowChat,
  newMessageId: number | null | undefined,
): boolean {
  if (!canUseThreadFollowMode(chat)) {
    return false
  }

  if (isReplyThread(chat)) {
    return true
  }

  return isFreshNormalThreadByNewMessageId(newMessageId)
}

export function isFreshNormalThreadByNewMessageId(newMessageId: number | null | undefined): boolean {
  // Message ids are per-chat, so the newly inserted id is a cheap proxy for thread size.
  // Keep this centralized so we can later swap in a better "fresh thread" signal without changing send flow.
  return (
    typeof newMessageId === "number" &&
    Number.isSafeInteger(newMessageId) &&
    newMessageId > 0 &&
    newMessageId <= FRESH_NORMAL_THREAD_MESSAGE_ID_LIMIT
  )
}

export async function resolveThreadAutoFollowUserIds(input: {
  chat: ThreadAutoFollowChat
  currentUserId: number
  eligibleUserIds: ReadonlySet<number>
  newMessageId: number | null | undefined
}): Promise<number[]> {
  if (!shouldAutoFollowThreadMessage(input.chat, input.newMessageId)) {
    return []
  }

  const followUserIds = new Set<number>([input.currentUserId])

  if (isReplyThread(input.chat)) {
    const anchorSenderId = await getReplyThreadAnchorSenderId(input.chat)
    if (anchorSenderId !== undefined && input.eligibleUserIds.has(anchorSenderId)) {
      followUserIds.add(anchorSenderId)
    }
  }

  return Array.from(followUserIds)
}

import { messageKey, type Db } from "@inline/client/core"
import type { ChatID, MessageID } from "@inline/ids"

export type FullChatProgressiveLease = () => void

export interface FullChatProgressiveService {
  activateChat(chatId: ChatID): FullChatProgressiveLease
  updateVisibleRange(
    chatId: ChatID,
    firstVisibleMessageId: MessageID,
    lastVisibleMessageId: MessageID,
  ): void
}

type ActiveChatsDidChange = (
  activeChatIds: readonly ChatID[],
  releasedChatIds: readonly ChatID[],
) => void
type VisibleRangeDidChange = (
  chatId: ChatID,
  firstVisibleMessageId: MessageID,
  lastVisibleMessageId: MessageID,
) => void

export const FULL_CHAT_RESIDENT_MESSAGE_LIMIT = 500

/**
 * View-lifetime ownership for Inline's progressive chat windows. Each caller
 * receives its own idempotent lease, matching Inline Apple's active-chat
 * tokens instead of coupling cache lifetime to a React render.
 */
export class FullChatProgressiveLeases
  implements FullChatProgressiveService
{
  private readonly leases = new Map<symbol, ChatID>()
  private readonly pendingReleasedChatIds = new Set<ChatID>()
  private releaseScheduled = false

  constructor(
    private readonly activeChatsDidChange: ActiveChatsDidChange,
    private readonly visibleRangeDidChange: VisibleRangeDidChange =
      () => undefined,
  ) {}

  activateChat(chatId: ChatID): FullChatProgressiveLease {
    const token = Symbol(`full-chat-${chatId}`)
    const wasActive =
      this.hasActiveChat(chatId) ||
      this.pendingReleasedChatIds.has(chatId)
    this.pendingReleasedChatIds.delete(chatId)
    this.leases.set(token, chatId)
    if (!wasActive) this.publish([])

    let active = true
    return () => {
      if (!active) return
      active = false
      this.leases.delete(token)
      if (!this.hasActiveChat(chatId)) {
        this.pendingReleasedChatIds.add(chatId)
        this.scheduleRelease()
      }
    }
  }

  updateVisibleRange(
    chatId: ChatID,
    firstVisibleMessageId: MessageID,
    lastVisibleMessageId: MessageID,
  ) {
    if (!this.hasActiveChat(chatId)) return
    this.visibleRangeDidChange(
      chatId,
      firstVisibleMessageId,
      lastVisibleMessageId,
    )
  }

  private hasActiveChat(chatId: ChatID) {
    for (const activeChatId of this.leases.values()) {
      if (activeChatId === chatId) return true
    }
    return false
  }

  private publish(releasedChatIds: readonly ChatID[]) {
    this.activeChatsDidChange(
      Array.from(
        new Set([
          ...this.leases.values(),
          ...this.pendingReleasedChatIds,
        ]),
      ),
      releasedChatIds,
    )
  }

  private scheduleRelease() {
    if (this.releaseScheduled) return
    this.releaseScheduled = true
    queueMicrotask(() => {
      this.releaseScheduled = false
      const releasedChatIds = Array.from(
        this.pendingReleasedChatIds,
      ).filter((chatId) => !this.hasActiveChat(chatId))
      for (const chatId of releasedChatIds) {
        this.pendingReleasedChatIds.delete(chatId)
      }
      if (releasedChatIds.length > 0) {
        this.publish(releasedChatIds)
      }
    })
  }
}

export const createOwnedFullChatProgressive = (
  db: Db,
): FullChatProgressiveService =>
  new FullChatProgressiveLeases(
    (activeChatIds, releasedChatIds) => {
      for (const chatId of activeChatIds) {
        db.activateResidentMessageWindow(chatId)
      }
      for (const chatId of releasedChatIds) {
        db.releaseResidentMessageWindow(chatId)
      }
    },
    (chatId, firstVisibleMessageId, lastVisibleMessageId) => {
      db.compactResidentMessageWindow(
        chatId,
        messageKey(chatId, firstVisibleMessageId),
        messageKey(chatId, lastVisibleMessageId),
        FULL_CHAT_RESIDENT_MESSAGE_LIMIT,
      )
    },
  )

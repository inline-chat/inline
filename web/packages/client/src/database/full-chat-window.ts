import type { ChatID } from "@inline/ids"
import type { MessageKey } from "./models"

export type FullChatWindowSnapshot = {
  chatId: ChatID
  messageKeys: MessageKey[]
  atLatest: boolean
}

type FullChatWindow = {
  messageKeys: Set<MessageKey>
  atLatest: boolean
}

/** Membership for contiguous FullChatProgressive history windows. */
export class FullChatWindowState {
  private readonly windows = new Map<ChatID, FullChatWindow>()

  activate(chatId: ChatID, initialKeys: readonly MessageKey[] = []) {
    if (this.windows.has(chatId)) return false
    this.windows.set(chatId, {
      messageKeys: new Set(initialKeys),
      atLatest: true,
    })
    return true
  }

  release(chatId: ChatID) {
    return this.windows.delete(chatId)
  }

  replace(chatId: ChatID, messageKeys: readonly MessageKey[], atLatest: boolean) {
    const window = this.windows.get(chatId)
    if (!window) return false
    window.messageKeys = new Set(messageKeys)
    window.atLatest = atLatest
    return true
  }

  extend(chatId: ChatID, messageKeys: readonly MessageKey[]) {
    const window = this.windows.get(chatId)
    if (!window) return false
    let changed = false
    for (const key of messageKeys) {
      if (window.messageKeys.has(key)) continue
      window.messageKeys.add(key)
      changed = true
    }
    return changed
  }

  setAtLatest(chatId: ChatID, atLatest: boolean) {
    const window = this.windows.get(chatId)
    if (!window || window.atLatest === atLatest) return false
    window.atLatest = atLatest
    return true
  }

  isActive(chatId: ChatID) {
    return this.windows.has(chatId)
  }

  isAtLatest(chatId: ChatID) {
    return this.windows.get(chatId)?.atLatest === true
  }

  contains(chatId: ChatID, messageKey: MessageKey) {
    const window = this.windows.get(chatId)
    return window?.messageKeys.has(messageKey) === true
  }

  keys(chatId: ChatID) {
    return Array.from(this.windows.get(chatId)?.messageKeys ?? [])
  }

  allKeys() {
    const keys = new Set<MessageKey>()
    for (const window of this.windows.values()) {
      for (const key of window.messageKeys) keys.add(key)
    }
    return keys
  }

  snapshots(): FullChatWindowSnapshot[] {
    return Array.from(this.windows, ([chatId, window]) => ({
      chatId,
      messageKeys: Array.from(window.messageKeys),
      atLatest: window.atLatest,
    }))
  }

  /** Remove overflow from one far edge, retaining one contiguous range. */
  compact(
    chatId: ChatID,
    orderedKeys: readonly MessageKey[],
    firstVisibleKey: MessageKey,
    lastVisibleKey: MessageKey,
    maximumMessages: number,
  ): MessageKey[] {
    const window = this.windows.get(chatId)
    if (!window || orderedKeys.length <= maximumMessages) return []
    const firstVisibleIndex = orderedKeys.indexOf(firstVisibleKey)
    const lastVisibleIndex = orderedKeys.indexOf(lastVisibleKey)
    if (
      firstVisibleIndex < 0 ||
      lastVisibleIndex < firstVisibleIndex ||
      maximumMessages < lastVisibleIndex - firstVisibleIndex + 1
    ) {
      return []
    }

    const overflow = orderedKeys.length - maximumMessages
    const beforeVisible = firstVisibleIndex
    const afterVisible = orderedKeys.length - lastVisibleIndex - 1
    const trimStart =
      beforeVisible >= overflow &&
      (beforeVisible >= afterVisible || afterVisible < overflow)
    const retained = trimStart
      ? orderedKeys.slice(overflow)
      : orderedKeys.slice(0, orderedKeys.length - overflow)
    const retainedSet = new Set(retained)
    const removed = orderedKeys.filter((key) => !retainedSet.has(key))
    window.messageKeys = retainedSet
    if (!trimStart) window.atLatest = false
    return removed
  }
}

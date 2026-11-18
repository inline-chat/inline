/**
 * Which conversations the user is looking at, here and in the account's other
 * tabs.
 *
 * Here: the chats shown in the workspace's panes while the page is visible
 * and focused. The Mac counts the main route and the reply-thread side pane
 * of the key window (`MainWindowOpenCoordinator.isViewingChat`); the web's
 * panes sit side by side on screen, so every pane's current chat counts.
 *
 * Elsewhere: only the leader shows notifications, but the user may be reading
 * the chat in a follower tab while the leader tab is hidden. Each context
 * posts its viewing set on an optional channel (a `BroadcastChannel` per
 * account), and the leader also treats the newest non-empty set it heard as
 * viewed. Only one window has focus at a time, so the newest post wins; a
 * context that loses focus or closes posts an empty set.
 */

import type { ChatID } from "@inline/ids"
import { computed, effect, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import { destinationChatId, type PaneState } from "@inline/view"

/** The `BroadcastChannel` shape (and `ChannelLike` from `@inline/link`). */
export type ViewingChannel = {
  postMessage(message: unknown): void
  addEventListener(type: "message", listener: (event: { readonly data: unknown }) => void): void
  removeEventListener(type: "message", listener: (event: { readonly data: unknown }) => void): void
}

type ViewingMessage = { readonly t: "inline-notify-viewing"; readonly v: 1; readonly from: string; readonly chats: string[] }

const isViewingMessage = (data: unknown): data is ViewingMessage => {
  if (typeof data !== "object" || data === null) return false
  const message = data as Partial<ViewingMessage>
  return (
    message.t === "inline-notify-viewing" &&
    message.v === 1 &&
    typeof message.from === "string" &&
    Array.isArray(message.chats) &&
    message.chats.length <= 16 &&
    message.chats.every((chat) => typeof chat === "string")
  )
}

/** Chats shown in a pane now. A thread destination shows the thread. */
export const chatsInPanes = (panes: readonly PaneState[]): ChatID[] => {
  const chats: ChatID[] = []
  for (const pane of panes) {
    const entry = pane.entries[pane.index]
    const chatId = entry ? destinationChatId(entry.destination) : undefined
    if (chatId !== undefined && !chats.includes(chatId)) chats.push(chatId)
  }
  return chats
}

export type ViewingTrackerOptions = {
  readonly panes: ReadSignal<readonly PaneState[]>
  readonly visible: ReadSignal<boolean>
  readonly focused: ReadSignal<boolean>
  readonly channel?: ViewingChannel
  /** This context's ID on the channel. */
  readonly contextId: string
}

export type ViewingTracker = {
  /** Chats this context shows in a visible, focused page. */
  readonly local: ReadSignal<readonly ChatID[]>
  /** Whether the user is looking at the chat here or, as last heard, in another context. */
  isViewing(chatId: ChatID): boolean
  dispose: Dispose
}

const sameList = (a: readonly ChatID[], b: readonly ChatID[]) =>
  a.length === b.length && a.every((chat, index) => chat === b[index])

export const createViewingTracker = (options: ViewingTrackerOptions): ViewingTracker => {
  const { channel, contextId } = options
  const local = computed(
    () => (options.visible.get() && options.focused.get() ? chatsInPanes(options.panes.get()) : []),
    { equals: sameList },
  )
  const remote = signal<{ readonly from: string; readonly chats: readonly ChatID[] } | undefined>(undefined)

  const onMessage = (event: { readonly data: unknown }) => {
    const data = event.data
    if (!isViewingMessage(data) || data.from === contextId) return
    const current = remote.peek()
    if (data.chats.length > 0) remote.set({ from: data.from, chats: data.chats as ChatID[] })
    else if (current?.from === data.from) remote.set(undefined)
  }
  channel?.addEventListener("message", onMessage)

  const post = (chats: readonly ChatID[]) => {
    try {
      channel?.postMessage({ t: "inline-notify-viewing", v: 1, from: contextId, chats: [...chats] } satisfies ViewingMessage)
    } catch {
      // A closed channel: nothing to tell.
    }
  }
  const stop = effect(() => {
    const chats = local.get()
    untracked(() => {
      // Focus here means no other window has it: forget what another said.
      if (chats.length > 0) remote.set(undefined)
      post(chats)
    })
  })

  let disposed = false
  return {
    local,
    isViewing(chatId) {
      return local.peek().includes(chatId) || (remote.peek()?.chats.includes(chatId) ?? false)
    },
    dispose() {
      if (disposed) return
      disposed = true
      stop()
      post([])
      channel?.removeEventListener("message", onMessage)
    },
  }
}

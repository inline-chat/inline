/**
 * Incoming compose activity, for the chat header and the sidebar.
 *
 * `ChatTypingModel` subscribes to one chat's `composeActions` and gives the
 * header its status line. `ComposeActivityIndex` subscribes once to every
 * chat's activity and gives each sidebar row its own computed, so a typing
 * change in one chat renders one row.
 *
 * Expiry is the core's (6 s after the last refresh, a stop, a new message
 * from that person, or a dropped connection; `COMPOSE_ACTION_RULE`); these
 * models only present what the core says is current.
 */

import type { ChatRow, ComposeActivity, ComposeResource, UserRow } from "@inline/core-protocol"
import type { ChatID, UserID } from "@inline/ids"
import { computed, type ReadSignal, type StoreClient, type SubscriptionHandle } from "@inline/reactive"
import { composeStatus, sameStatus, type ComposeStatus } from "./presentation"

const noActivities: readonly ComposeActivity[] = Object.freeze([])

const activitiesOf = (handle: SubscriptionHandle): ReadSignal<readonly ComposeActivity[]> =>
  computed(() => {
    const resource = handle.resource.get()
    return resource?.kind === "compose" ? (resource as ComposeResource).activities : noActivities
  })

const userReader = (client: StoreClient) => (userId: UserID): UserRow | undefined => client.store.row("user", userId).get()

/** Whether a chat is a direct message, from its row in the store (the sidebar and the chat window carry it). */
export const isDirectChat = (client: StoreClient, chatId: ChatID): ReadSignal<boolean> =>
  computed(() => (client.store.row("chat", chatId).get() as ChatRow | undefined)?.peerUserId !== undefined)

export type ChatTypingModel = {
  /** The header's status line (rule 15: below the connection state, above bot status and local time). */
  readonly status: ReadSignal<ComposeStatus | undefined>
  /** Someone is typing (not another activity). */
  readonly typing: ReadSignal<boolean>
  dispose(): void
}

export const createChatTyping = (options: {
  readonly client: StoreClient
  readonly chatId: ChatID
  /** Default: from the chat's row in the store. */
  readonly isDirect?: ReadSignal<boolean>
}): ChatTypingModel => {
  const { client, chatId } = options
  const handle = client.subscribe({ kind: "composeActions", chatId })
  const activities = activitiesOf(handle)
  const isDirect = options.isDirect ?? isDirectChat(client, chatId)
  const user = userReader(client)
  const status = computed(() => composeStatus({ activities: activities.get(), isDirect: isDirect.get(), user, length: "full" }), {
    equals: sameStatus,
  })
  return {
    status,
    typing: computed(() => status.get()?.kind === "typing"),
    dispose: () => handle.unsubscribe(),
  }
}

/** What a sidebar row shows for its chat. */
export type RowActivity = {
  /** Someone is typing in it. */
  readonly typing: boolean
  /** The short status line, when someone is doing anything. */
  readonly status: ComposeStatus | undefined
}

const idle: RowActivity = Object.freeze({ typing: false, status: undefined })

export type ComposeActivityIndex = {
  /** One cached computed per chat; keeps its identity while the chat's line does not change. */
  forChat(chatId: ChatID): ReadSignal<RowActivity>
  dispose(): void
}

/** One subscription to every chat's compose activity, split per chat for sidebar rows. */
export const createComposeActivityIndex = (options: { readonly client: StoreClient }): ComposeActivityIndex => {
  const { client } = options
  const handle = client.subscribe({ kind: "composeActions" })
  const all = activitiesOf(handle)
  const byChat = computed(() => {
    const map = new Map<ChatID, ComposeActivity[]>()
    for (const entry of all.get()) {
      const list = map.get(entry.chatId)
      if (list) list.push(entry)
      else map.set(entry.chatId, [entry])
    }
    return map as ReadonlyMap<ChatID, readonly ComposeActivity[]>
  })
  const user = userReader(client)
  const cache = new Map<ChatID, ReadSignal<RowActivity>>()
  return {
    forChat: (chatId) => {
      let cached = cache.get(chatId)
      if (!cached) {
        const isDirect = isDirectChat(client, chatId)
        const activities = computed(() => byChat.get().get(chatId) ?? noActivities, {
          equals: (a, b) => a.length === b.length && a.every((entry, index) => {
            const other = b[index]
            return other !== undefined && other.userId === entry.userId && other.action === entry.action
          }),
        })
        cached = computed(
          () => {
            const status = composeStatus({ activities: activities.get(), isDirect: isDirect.get(), user, length: "short" })
            return status ? { typing: status.kind === "typing", status } : idle
          },
          { equals: (a, b) => a.typing === b.typing && sameStatus(a.status, b.status) },
        )
        cache.set(chatId, cached)
      }
      return cached
    },
    dispose: () => {
      handle.unsubscribe()
      cache.clear()
    },
  }
}

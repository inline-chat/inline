/**
 * The sidebar's model: the `sidebar` query for one mode, as an ordered list
 * of item keys and a computed per item, so a change to one chat re-renders
 * one row and a change in order re-renders no row.
 *
 * The core orders the list (feature-map rules 6 and 7); this model never
 * reorders it. The `sidebar` query carries, with each dialog, every row its
 * item reads (chat, peer, last message and its sender, draft, space, parent
 * chat), so every item has its preview from the first result.
 */

import {
  receivedMessageRowId,
  rowKey,
  type ChatRow,
  type CoreEndpoint,
  type DialogRow,
  type DraftRow,
  type MessageRow,
  type QueryDescriptor,
  type Revision,
  type RowKey,
  type SubId,
  type UserRow,
} from "@inline/core-protocol"
import type { ChatID, DialogID, SpaceID, UserID } from "@inline/ids"
import { previewText, userShortName } from "@inline/chat-ui"
import {
  batch,
  computed,
  effect,
  plainEqual,
  sameKeys,
  signal,
  untracked,
  type ReadSignal,
  type StoreClient,
  type SubscriptionHandle,
} from "@inline/reactive"
import type { OpenIntent, Workspace } from "../workspace/workspace"
import { chatAvatar, chatTitle, destinationChatId, peerUserIdOf, type AvatarInput } from "./helpers"

export type SidebarMode = Extract<QueryDescriptor, { kind: "sidebar" }>["mode"]

export type SidebarPreview =
  /** Rule: a draft takes precedence over the last message ("Draft: …"). */
  | { readonly kind: "draft"; readonly text: string }
  | {
      readonly kind: "message"
      readonly text: string
      readonly outgoing: boolean
      /**
       * For a thread: the sender's short name, which the row shows before
       * the text ("Ada: see you"), as the Mac does. Absent in direct
       * messages, and when the sender's row is not on the device.
       */
      readonly sender?: string
    }
  | { readonly kind: "none" }

export type SidebarItem = {
  /** The dialog's row key; stable for the item's life. */
  readonly key: RowKey
  readonly dialogId: DialogID
  readonly chatId: ChatID
  readonly peerUserId?: UserID
  readonly spaceId?: SpaceID
  readonly title: string
  readonly emoji?: string
  readonly avatar: AvatarInput
  readonly preview: SidebarPreview
  /** Seconds since the epoch of the last activity, for the row's time label. */
  readonly date?: number
  readonly unreadCount: number
  readonly unreadMark: boolean
  /** `unreadCount > 0 || unreadMark`. */
  readonly hasUnread: boolean
  /** The chat's unread is accent-styled and counted in the badge (rule 9): a DM or a followed thread. */
  readonly prominent: boolean
  readonly pinned: boolean
  readonly selected: boolean
  // The fields below are always set by `SidebarModel`; they are optional
  // only so items built by hand (labs, view tests) stay valid.
  /** The dialog is open in the sidebar (`DialogRow.open`). */
  readonly open?: boolean
  readonly archived?: boolean
  /**
   * Shown in the inbox only because its chat is selected (rule 7): not open
   * and not pinned. The row shows it as temporary and its menu offers
   * "Close from Sidebar" and "Keep in Sidebar". Always false outside `inbox`.
   */
  readonly temporary?: boolean
  /** Unseen mentions of the viewer (the `@` badge); 0 when none or unknown. */
  readonly unreadMentionCount?: number
  /** Unseen reactions to the viewer's messages (the heart badge); 0 when none or unknown. */
  readonly unreadReactionCount?: number
  /** A thread's follow choice; absent is the default (relevance). */
  readonly followMode?: DialogRow["followMode"]
  /** The chat's own notification setting; absent follows the account's. */
  readonly notificationMode?: DialogRow["notificationMode"]
}

/**
 * Whether a chat's unread is prominent (feature-map rule 9, Mac
 * `Dialog.prominentUnreadSQL`): a direct message (`peerUserId`, which is
 * also what the Mac's `chat.type = private` means), or a followed thread.
 */
export type ProminenceInput = { readonly dialog: DialogRow; readonly chat: ChatRow | undefined }

/** Hooks for what the rows cannot say. */
export type SidebarHooks = {
  /** Also treat a chat as followed (`DialogRow.followMode` is read without it). */
  readonly isFollowing?: (input: ProminenceInput) => boolean
}

export const isProminentUnread = (input: ProminenceInput, hooks: SidebarHooks = {}): boolean =>
  peerUserIdOf(input.dialog, input.chat) !== undefined ||
  input.dialog.followMode === "following" ||
  hooks.isFollowing?.(input) === true

const previewLength = 120

/** The prominent unread items, in list order, with their indices in `items`. */
export type ProminentUnread = { readonly keys: readonly RowKey[]; readonly indices: readonly number[] }

const noProminentUnread: ProminentUnread = { keys: [], indices: [] }

const sameProminentUnread = (a: ProminentUnread, b: ProminentUnread): boolean =>
  sameKeys(a.keys, b.keys) && sameKeys(a.indices, b.indices)

export type SidebarModelOptions = {
  readonly client: StoreClient
  readonly workspace: Workspace
  readonly mode?: SidebarMode
  readonly spaceId?: SpaceID
  readonly hooks?: SidebarHooks
  /** Item computeds kept for keys no longer listed before the cache is pruned. Default 64. */
  readonly itemCacheSlack?: number
  /**
   * How the model subscribes. Default `client.subscribe`. The session passes
   * one that hands out subscriptions restored from the boot snapshot first.
   */
  readonly subscribe?: (query: QueryDescriptor) => SubscriptionHandle
  /**
   * The core endpoint, to know when the core answered a mode's list (an
   * answer can be an empty list, which the store cannot tell from no answer).
   * The session passes it. Without it `ready` is true once the list is
   * non-empty or restored from the boot snapshot, and `setMode` does not
   * hold the previous list (an empty answer could never release it).
   */
  readonly core?: Pick<CoreEndpoint, "subscribe">
}

export class SidebarModel {
  readonly mode: ReadSignal<SidebarMode>
  /**
   * Ordered item keys (dialog row keys), in the core's order. After
   * `setMode`, the previous mode's list until the core answers the new one.
   */
  readonly items: ReadSignal<readonly RowKey[]>
  /**
   * True when `items` is the current mode's list as the core answered it (or
   * as the boot snapshot restored it). False on first load until the core
   * answers, and after `setMode` while the previous list is held. A view shows
   * an empty state only when ready; while not ready it shows the list it has,
   * busy, or a static placeholder.
   */
  readonly ready: ReadSignal<boolean>
  /** The chat shown in the focused pane, if any. */
  readonly selectedChatId: ReadSignal<ChatID | undefined>
  /**
   * The items with prominent unread (rule 9), in list order, and their
   * indices in `items`. Does not depend on the selection: selecting a chat
   * recomputes nothing here. The badge and "unread below" read it.
   */
  readonly prominentUnread: ReadSignal<ProminentUnread>
  /** `prominentUnread`'s keys. */
  readonly prominentUnreadKeys: ReadSignal<readonly RowKey[]>
  /** Count of chats with prominent unread: the app badge and tab title (rule 9). */
  readonly prominentUnreadCount: ReadSignal<number>
  readonly canSelectAdjacent: ReadSignal<boolean>
  /** Dialog rows by chat, for models that need a chat's dialog (unread count, read marker). */
  readonly dialogByChat: ReadSignal<ReadonlyMap<ChatID, RowKey>>

  readonly #client: StoreClient
  readonly #workspace: Workspace
  readonly #hooks: SidebarHooks
  readonly #spaceId: SpaceID | undefined
  readonly #mode = signal<SidebarMode>("inbox")
  readonly #handle
  /** The list on screen while the current mode's subscription is unanswered. */
  readonly #previous = signal<SubscriptionHandle | undefined>(undefined)
  /** The revision of the first core message that carried each sub's list. */
  readonly #answered = signal<ReadonlyMap<SubId, Revision>>(new Map())
  readonly #hasCore: boolean
  readonly #itemCache = new Map<RowKey, ReadSignal<SidebarItem | undefined>>()
  readonly #unreadCache = new Map<RowKey, ReadSignal<boolean>>()
  readonly #slack: number
  readonly #subscribeQuery: (query: QueryDescriptor) => SubscriptionHandle
  readonly #disposers: (() => void)[] = []
  #disposed = false

  constructor(options: SidebarModelOptions) {
    this.#client = options.client
    this.#workspace = options.workspace
    this.#hooks = options.hooks ?? {}
    this.#spaceId = options.spaceId
    this.#slack = options.itemCacheSlack ?? 64
    this.#subscribeQuery = options.subscribe ?? ((query) => options.client.subscribe(query))
    this.#hasCore = options.core !== undefined
    if (options.core) {
      this.#disposers.push(
        options.core.subscribe((message) => {
          if (message.kind === "patch") this.#noteAnswers(message.patch.revision, message.patch.lists)
          else if (message.kind === "snapshot") this.#noteAnswers(message.snapshot.revision, message.snapshot.lists)
        }),
      )
    }
    this.#mode.set(options.mode ?? "inbox")
    this.mode = { get: () => this.#mode.get(), peek: () => this.#mode.peek() }
    this.#handle = signal<SubscriptionHandle>(this.#subscribe(this.#mode.peek()))
    this.ready = computed(() => this.#isAnswered(this.#handle.get()))
    this.items = computed(
      () => {
        const current = this.#handle.get()
        const previous = this.#previous.get()
        if (previous && !this.#isAnswered(current)) return previous.list.get()
        return current.list.get()
      },
      { equals: sameKeys },
    )
    this.selectedChatId = computed(() => destinationChatId(this.#workspace.focusedDestination.get()))
    this.canSelectAdjacent = computed(() => this.items.get().length > 0)
    this.prominentUnread = computed(
      () => {
        const keys: RowKey[] = []
        const indices: number[] = []
        this.items.get().forEach((key, index) => {
          if (this.#prominentUnreadOf(key).get()) {
            keys.push(key)
            indices.push(index)
          }
        })
        return keys.length === 0 ? noProminentUnread : { keys, indices }
      },
      { equals: sameProminentUnread },
    )
    this.prominentUnreadKeys = computed(() => this.prominentUnread.get().keys)
    this.prominentUnreadCount = computed(() => this.prominentUnread.get().keys.length)
    this.dialogByChat = computed(
      () => {
        const map = new Map<ChatID, RowKey>()
        for (const key of this.items.get()) {
          const dialog = this.#client.store.rowByKey(key).get() as DialogRow | undefined
          if (dialog) map.set(dialog.chatId, key)
        }
        return map
      },
      // A dialog's unread count changing re-runs this, but changes nothing that depends on it.
      { equals: sameEntries },
    )
    // Once the current mode is answered, the held list is released.
    this.#disposers.push(
      effect(() => {
        const previous = this.#previous.get()
        if (!previous || !this.#isAnswered(this.#handle.get())) return
        untracked(() => {
          this.#previous.set(undefined)
          previous.unsubscribe()
        })
      }),
    )
  }

  /**
   * The derived item of one key. One computed per key, cached, so every
   * caller observes the same node. It keeps its identity when nothing it
   * shows changed.
   */
  item(key: RowKey): ReadSignal<SidebarItem | undefined> {
    let item = this.#itemCache.get(key)
    if (!item) {
      this.#pruneItems()
      item = this.#createItem(key)
      this.#itemCache.set(key, item)
    }
    return item
  }

  /** The dialog row of a chat, when the chat is in this sidebar's list. */
  dialogFor(chatId: ChatID): ReadSignal<DialogRow | undefined> {
    return computed(() => {
      const key = this.dialogByChat.get().get(chatId)
      return key ? (this.#client.store.rowByKey(key).get() as DialogRow | undefined) : undefined
    })
  }

  /** The current mode's subscription (what the boot snapshot exports). */
  get subscription(): SubscriptionHandle {
    return this.#handle.peek()
  }

  /** Open an item's chat. */
  open(key: RowKey, intent: OpenIntent = "here"): void {
    const dialog = this.#client.store.peekRow(key) as DialogRow | undefined
    if (!dialog) return
    this.#workspace.open({ kind: "chat", chatId: dialog.chatId }, { intent })
  }

  /**
   * Select the previous (-1) or next (1) chat in the sidebar's order (the
   * navigation commands). With nothing selected, next opens the first chat
   * and previous the last. Stops at the ends, as the Mac app does.
   */
  selectAdjacent(direction: -1 | 1): boolean {
    const keys = this.items.peek()
    if (keys.length === 0) return false
    const selected = this.selectedChatId.peek()
    const index = selected === undefined ? -1 : keys.findIndex((key) => this.#chatIdOf(key) === selected)
    let next: number
    if (index === -1) next = direction === 1 ? 0 : keys.length - 1
    else next = index + direction
    if (next < 0 || next >= keys.length) return false
    const key = keys[next]
    if (key === undefined) return false
    const chatId = this.#chatIdOf(key)
    if (chatId === undefined) return false
    this.#workspace.open({ kind: "chat", chatId })
    return true
  }

  /**
   * Switch the list's mode. `mode` changes at once; `items` keeps the list on
   * screen until the core answers the new mode's subscription (`ready` is
   * false meanwhile), so the view never flashes empty.
   */
  setMode(mode: SidebarMode): void {
    if (this.#disposed || mode === this.#mode.peek()) return
    const current = this.#handle.peek()
    const previous = this.#previous.peek()
    batch(() => {
      this.#mode.set(mode)
      if (!this.#hasCore) {
        // Without the core the model cannot tell an empty answer from none, so it does not hold.
        this.#handle.set(this.#subscribe(mode))
        current.unsubscribe()
        return
      }
      if (previous && modeOf(previous) === mode) {
        // Back to the list still on screen: take it up again.
        this.#previous.set(undefined)
        this.#handle.set(previous)
        current.unsubscribe()
        return
      }
      const next = this.#subscribe(mode)
      if (this.#isAnsweredNow(current)) {
        // Hold what is on screen until the new list is answered.
        previous?.unsubscribe()
        this.#previous.set(current)
      } else {
        // Nothing of the current mode is on screen: keep holding the older list, if any.
        current.unsubscribe()
      }
      this.#handle.set(next)
    })
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    for (const dispose of this.#disposers.splice(0).reverse()) dispose()
    this.#previous.peek()?.unsubscribe()
    this.#handle.peek().unsubscribe()
    this.#itemCache.clear()
    this.#unreadCache.clear()
  }

  #subscribe(mode: SidebarMode): SubscriptionHandle {
    return this.#subscribeQuery({ kind: "sidebar", mode, ...(this.#spaceId ? { spaceId: this.#spaceId } : {}) })
  }

  /** Tracked: whether the core answered this subscription's list and the store applied it. */
  #isAnswered(handle: SubscriptionHandle): boolean {
    const store = this.#client.store
    if (store.provisionalSubs.get().has(handle.sub)) return true
    if (!this.#hasCore) return handle.list.get().length > 0
    const revision = this.#answered.get().get(handle.sub)
    return revision !== undefined && store.revision.get() >= revision
  }

  #isAnsweredNow(handle: SubscriptionHandle): boolean {
    return untracked(() => this.#isAnswered(handle))
  }

  #noteAnswers(revision: Revision, lists: readonly { sub: SubId }[]): void {
    let next: Map<SubId, Revision> | undefined
    for (const { sub } of lists) {
      if ((next ?? this.#answered.peek()).has(sub)) continue
      next ??= new Map(this.#answered.peek())
      next.set(sub, revision)
    }
    if (next) this.#answered.set(next)
  }

  #chatIdOf(key: RowKey): ChatID | undefined {
    return (this.#client.store.peekRow(key) as DialogRow | undefined)?.chatId
  }

  #pruneItems() {
    const keys = this.items.peek()
    if (this.#itemCache.size <= keys.length + this.#slack && this.#unreadCache.size <= keys.length + this.#slack) return
    const live = new Set(keys)
    for (const key of this.#itemCache.keys()) if (!live.has(key)) this.#itemCache.delete(key)
    for (const key of this.#unreadCache.keys()) if (!live.has(key)) this.#unreadCache.delete(key)
  }

  /** Whether one item has prominent unread: its dialog and chat only, never the selection. */
  #prominentUnreadOf(key: RowKey): ReadSignal<boolean> {
    let flag = this.#unreadCache.get(key)
    if (!flag) {
      this.#pruneItems()
      const store = this.#client.store
      const dialogRow = store.rowByKey(key) as ReadSignal<DialogRow | undefined>
      flag = computed(() => {
        const dialog = dialogRow.get()
        if (!dialog || !(dialog.unreadCount > 0 || dialog.unreadMark)) return false
        return isProminentUnread({ dialog, chat: store.row("chat", dialog.chatId).get() }, this.#hooks)
      })
      this.#unreadCache.set(key, flag)
    }
    return flag
  }

  #createItem(key: RowKey): ReadSignal<SidebarItem | undefined> {
    const store = this.#client.store
    const dialogRow = store.rowByKey(key) as ReadSignal<DialogRow | undefined>
    // Selecting a chat re-runs this small computed for every item, and the
    // item's own computed only for the two whose flag changed.
    const selected = computed(() => {
      const dialog = dialogRow.get()
      return dialog !== undefined && this.selectedChatId.get() === dialog.chatId
    })
    return computed(
      () => {
        const dialog = dialogRow.get()
        if (!dialog) return undefined
        const chatId = dialog.chatId
        const chat = store.row("chat", chatId).get()
        const peerUserId = peerUserIdOf(dialog, chat)
        const peer: UserRow | undefined = peerUserId !== undefined ? store.row("user", peerUserId).get() : undefined
        const draft = store.row("draft", chatId).get()
        const lastRowId =
          chat?.lastMessageRowId ?? (chat?.lastMessageId ? receivedMessageRowId(chatId, chat.lastMessageId) : undefined)
        const last = lastRowId !== undefined ? store.row("message", lastRowId).get() : undefined
        // Threads name the sender before the text (Mac `HomeChatListItemSnapshot.preview`).
        const sender = last && peerUserId === undefined ? store.row("user", last.fromId).get() : undefined
        const hasUnread = dialog.unreadCount > 0 || dialog.unreadMark
        const spaceId = dialog.spaceId ?? chat?.spaceId
        return {
          key,
          dialogId: dialog.id,
          chatId,
          ...(peerUserId !== undefined ? { peerUserId } : {}),
          ...(spaceId !== undefined ? { spaceId } : {}),
          title: chatTitle(chat, peer, peerUserId),
          ...(chat?.emoji ? { emoji: chat.emoji } : {}),
          avatar: chatAvatar(chatId, chat, peer, peerUserId),
          preview: sidebarPreview(draft, last, sender ? { sender: userShortName(sender) } : {}),
          ...(chat?.lastActivityDate !== undefined ? { date: chat.lastActivityDate } : {}),
          unreadCount: dialog.unreadCount,
          unreadMark: dialog.unreadMark,
          hasUnread,
          prominent: isProminentUnread({ dialog, chat }, this.#hooks),
          pinned: dialog.pinned,
          selected: selected.get(),
          open: dialog.open,
          archived: dialog.archived,
          temporary: this.#mode.get() === "inbox" && !dialog.open && !dialog.pinned,
          unreadMentionCount: dialog.unreadMentionsCount ?? 0,
          unreadReactionCount: dialog.unreadReactionsCount ?? 0,
          ...(dialog.followMode ? { followMode: dialog.followMode } : {}),
          ...(dialog.notificationMode ? { notificationMode: dialog.notificationMode } : {}),
        }
      },
      { equals: plainEqual },
    )
  }
}

const sameEntries = <K, V>(a: ReadonlyMap<K, V>, b: ReadonlyMap<K, V>): boolean => {
  if (a === b) return true
  if (a.size !== b.size) return false
  for (const [key, value] of a) if (b.get(key) !== value) return false
  return true
}

const modeOf = (handle: SubscriptionHandle): SidebarMode | undefined =>
  handle.query.kind === "sidebar" ? handle.query.mode : undefined

/**
 * What a message preview says when it has no text of its own, by the Mac
 * rules (`HomeChatListItemSnapshot.preview`, `Message.stringRepresentationPlain`):
 * a document by its name; else the text (a service message's text is its
 * fallback); else the media's name; else "Message".
 */
export const messagePreviewSource = (message: MessageRow): string => {
  const media = message.media
  if (media?.kind === "document") {
    const name = previewText(media.document.fileName ?? "", { maxGraphemes: previewLength })
    return `\u{1F4C4} ${name || "Document"}`
  }
  if (message.text.trim().length > 0) return message.text
  switch (media?.kind) {
    case "photo":
      return media.sticker ? "Sticker" : "Photo"
    case "video":
      return media.sticker ? "Sticker" : "Video"
    case "voice":
      return "Voice message"
    case "nudge":
      return "Nudge"
    case undefined:
      return "Message"
  }
}

/**
 * The row's second line. A non-empty draft wins ("Draft: …" in the view);
 * else the last message, when its row is in the store, with `sender` for a
 * thread.
 */
export const sidebarPreview = (
  draft: DraftRow | undefined,
  last: MessageRow | undefined,
  options: { readonly sender?: string } = {},
): SidebarPreview => {
  const draftText = draft ? previewText(draft.text, { maxGraphemes: previewLength }) : ""
  if (draftText.length > 0) return { kind: "draft", text: draftText }
  if (!last) return { kind: "none" }
  const text = previewText(messagePreviewSource(last), { maxGraphemes: previewLength, fallback: "Message" })
  const sender = options.sender?.trim()
  return { kind: "message", text, outgoing: last.out, ...(sender ? { sender } : {}) }
}

/** The badge count for a list of items: chats with prominent unread (rule 9). */
export const prominentUnreadCount = (items: readonly (SidebarItem | undefined)[]): number =>
  items.reduce((count, item) => (item?.hasUnread && item.prominent ? count + 1 : count), 0)

/** The key a dialog row has in the store. */
export const dialogKey = (id: DialogID): RowKey => rowKey("dialog", id)

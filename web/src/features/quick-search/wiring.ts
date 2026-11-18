/**
 * Quick Search for a signed-in account: builds the `QuickSearchModel` over an
 * `AccountSession` and turns what the model's `activate` returns into
 * navigation or a command run. Framework-free and DOM-free; the palette view
 * (`QuickSearchPalette`) renders the model this returns.
 *
 * - Local results come from the session's rows: the dialogs of the sidebar
 *   (the visible list, plus `all` and `archived` lists this subscribes for
 *   the session's life so archived and closed chats are found too), their
 *   chats, peers and spaces, through `createRowLocalSource`.
 * - Commands are the session's registry.
 * - Usage (frecency and per-query picks) is kept per account in the injected
 *   storage under `quickSearchUsageStorageKey(userId)`. Every change of the
 *   visible chat is recorded as a switch, as the Mac app does.
 * - Message and server search are injected (`messages`, `remote`); without
 *   them those sections never appear. TODO(contract): the core has no
 *   message search query and no server user search yet.
 */

import { rowKey, type ChatRow, type DialogRow, type RowKey, type SpaceRow, type UserRow } from "@inline/core-protocol"
import type { ChatID, SpaceID, UserID } from "@inline/ids"
import { computed, effect, untracked, type Clock, type Dispose, type ReadSignal, type SubscriptionHandle } from "@inline/reactive"
import { detectPlatform, type Command, type CommandRegistry, type Destination, type OpenIntent, type Platform, type ScopeId } from "@inline/view"
import { destinationChatId, type AccountSession } from "@inline/view/features"
import {
  QuickSearchModel,
  UsageStore,
  chatUsageKey,
  createRowLocalSource,
  memoryUsagePersistence,
  storageUsagePersistence,
  userUsageKey,
  type QuickSearchContext,
  type QuickSearchItem,
  type QuickSearchLocalSource,
  type QuickSearchMessageSource,
  type QuickSearchOutcome,
  type QuickSearchRemoteSource,
  type QuickSearchRows,
} from "@inline/view/quick-search"

/** Where an account's Quick Search usage is kept. Erase it with the account's other data on sign-out. */
export const quickSearchUsageStorageKey = (userId: UserID): string => `inline:quick-search-usage:${userId}`

type StorageLike = Pick<Storage, "getItem" | "setItem">

/** The keyboard dispatcher's layer API (`KeyboardDispatcher.pushLayer`). */
export type KeyboardLayers = {
  pushLayer(scope: ScopeId, options?: { modal?: boolean }): () => void
}

export type QuickSearchWiringOptions = {
  /** Timers for the model's debounces and the usage store's save. */
  readonly clock: Pick<Clock, "setTimeout" | "clearTimeout">
  /** Wall clock in milliseconds. Default `Date.now`. */
  readonly now?: () => number
  /** Where usage is kept (`localStorage`). Without it, usage lives in memory. */
  readonly storage?: StorageLike
  /** For shortcut labels and the platform modifier. Default: detected from `navigator`. */
  readonly platform?: Platform
  /**
   * The app's keyboard dispatcher. While the palette is open a modal
   * `dialog` layer is pushed, so global shortcuts do not fire under it.
   */
  readonly keyboard?: KeyboardLayers
  /** Local message search (the core's full-text query). TODO(contract): not in the core yet. */
  readonly messages?: QuickSearchMessageSource
  /** Server people: `createCoreRemoteSource({ client: session.client })` (core-sources.ts). */
  readonly remote?: QuickSearchRemoteSource
  /** Extra words a command is found by. */
  readonly commandKeywords?: (command: Command) => readonly string[]
  /** Subscribe the `all` and `archived` sidebar lists so they are searchable. Default true. */
  readonly includeAllChats?: boolean
  /** Timing overrides (tests, labs). */
  readonly timing?: { readonly messageDebounceMs?: number; readonly remoteDelayMs?: number }
  /**
   * Open the direct chat with a person who has none yet. Default: the
   * person's page (`{ kind: "user" }`). TODO(contract): no intent creates a
   * direct chat.
   */
  readonly openUser?: (userId: UserID, intent: OpenIntent) => void
  /** Select a space. Default: the space's members page. */
  readonly openSpace?: (spaceId: SpaceID) => void
  /**
   * Start a thread titled `title` in a space. Default: the new-thread
   * destination for the space (the title is dropped: TODO(contract), the
   * destination has no title).
   */
  readonly createThread?: (spaceId: SpaceID, title: string) => void
  /** Called after every performed outcome (labs and diagnostics). */
  readonly onPerform?: (outcome: QuickSearchOutcome) => void
}

export interface QuickSearchWiring {
  readonly model: QuickSearchModel
  readonly usage: UsageStore
  readonly platform: Platform
  /** The session's command registry (titles and shortcuts of command rows). */
  readonly commands: CommandRegistry
  /** The local candidates, for tests and labs. */
  readonly local: QuickSearchLocalSource
  /** The space results are scoped to (from the focused pane). */
  readonly context: ReadSignal<QuickSearchContext>
  readonly isOpen: ReadSignal<boolean>
  /** Open with an empty query. Already open: nothing changes. */
  open(): void
  close(): void
  toggle(): void
  /**
   * Activate an item (default: the active one) and perform the outcome. The
   * model closes first; the palette restores focus synchronously on close,
   * so the outcome runs with focus back where it was. Returns the outcome.
   */
  activate(item?: QuickSearchItem, intent?: OpenIntent): QuickSearchOutcome
  /** Perform an outcome. Returns false for `none` or a command that did not run. */
  perform(outcome: QuickSearchOutcome): boolean
  /** A photo URL for a person, from the rows in memory. */
  photoUrl(userId: UserID): string | undefined
  /** Forget all usage (sign-out). */
  clearUsage(): void
  dispose(): void
}

const isDialog = (row: unknown): row is DialogRow => (row as DialogRow | undefined)?.kind === "dialog"

/**
 * The rows Quick Search reads, from an account session: dialogs in sidebar
 * order with `all` then the visible list then `archived`, each chat once.
 * Lookups read through the store, so a candidate rebuilds when its row does.
 */
export const sessionQuickSearchRows = (
  session: Pick<AccountSession, "client" | "userId">,
  lists: readonly ReadSignal<readonly RowKey[]>[],
): ReadSignal<QuickSearchRows> => {
  const store = session.client.store
  const chat = (id: ChatID) => store.rowByKey(rowKey("chat", id)).get() as ChatRow | undefined
  const user = (id: UserID) => store.rowByKey(rowKey("user", id)).get() as UserRow | undefined
  const space = (id: SpaceID) => store.rowByKey(rowKey("space", id)).get() as SpaceRow | undefined
  return computed(() => {
    const seenKeys = new Set<RowKey>()
    const seenChats = new Set<ChatID>()
    const dialogs: DialogRow[] = []
    for (const list of lists) {
      for (const key of list.get()) {
        if (seenKeys.has(key)) continue
        seenKeys.add(key)
        const row = store.rowByKey(key).get()
        if (!isDialog(row) || seenChats.has(row.chatId)) continue
        seenChats.add(row.chatId)
        dialogs.push(row)
      }
    }
    // TODO(contract): no query lists spaces; the spaces of listed chats stand in.
    const spaces: SpaceRow[] = []
    const seenSpaces = new Set<SpaceID>()
    for (const dialog of dialogs) {
      const spaceId = dialog.spaceId ?? chat(dialog.chatId)?.spaceId
      if (spaceId === undefined || seenSpaces.has(spaceId)) continue
      seenSpaces.add(spaceId)
      const row = space(spaceId)
      if (row) spaces.push(row)
    }
    // TODO(contract): no query lists known people (members, contacts) without a direct chat.
    return { dialogs, chat, user, space, spaces, users: [], selfId: session.userId }
  })
}

/** The chat a destination shows, and the space it belongs to. */
const spaceOfDestination = (
  destination: Destination,
  chatSpace: (chatId: ChatID) => SpaceID | undefined,
): SpaceID | undefined => {
  switch (destination.kind) {
    case "space":
    case "newThread":
      return destination.spaceId
    default: {
      const chatId = destinationChatId(destination)
      return chatId !== undefined ? chatSpace(chatId) : undefined
    }
  }
}

/**
 * Wire Quick Search to a session. Call once per session (the shell does,
 * next to its other session wiring) and `dispose()` with the session.
 *
 * The session's `app.quickSearch` command calls the view hook
 * `openQuickSearch`; the shell implements that hook with `wiring.open()`.
 */
export const wireQuickSearch = (session: AccountSession, options: QuickSearchWiringOptions): QuickSearchWiring => {
  const disposers: Dispose[] = []
  const store = session.client.store
  const now = options.now ?? Date.now
  const platform = options.platform ?? detectPlatform({ ...(typeof navigator !== "undefined" ? { navigator } : {}), desktop: false })

  // Lists: the visible sidebar always; `all` and `archived` for the session's life.
  const handles: SubscriptionHandle[] = []
  if (options.includeAllChats ?? true) {
    handles.push(session.client.subscribe({ kind: "sidebar", mode: "all" }))
    handles.push(session.client.subscribe({ kind: "sidebar", mode: "archived" }))
  }
  const [allHandle, archivedHandle] = handles
  const lists = [
    ...(allHandle ? [allHandle.list] : []),
    session.sidebar.items,
    ...(archivedHandle ? [archivedHandle.list] : []),
  ]
  const rows = sessionQuickSearchRows(session, lists)
  const local = createRowLocalSource(rows)

  const chatRow = (chatId: ChatID) => store.rowByKey(rowKey("chat", chatId)).get() as ChatRow | undefined
  const context = computed<QuickSearchContext>(
    () => {
      const spaceId = spaceOfDestination(session.workspace.focusedDestination.get(), (chatId) => chatRow(chatId)?.spaceId)
      return spaceId !== undefined ? { spaceId } : {}
    },
    { equals: (a, b) => a.spaceId === b.spaceId },
  )

  const usage = new UsageStore({
    persistence: options.storage
      ? storageUsagePersistence(options.storage, quickSearchUsageStorageKey(session.userId))
      : memoryUsagePersistence(),
    now,
    clock: options.clock,
  })

  const model = new QuickSearchModel({
    clock: options.clock,
    now,
    local,
    commands: session.registry,
    usage,
    context,
    ...(options.messages ? { messages: options.messages } : {}),
    ...(options.remote ? { remote: options.remote } : {}),
    ...(options.commandKeywords ? { commandKeywords: options.commandKeywords } : {}),
    ...(options.timing ? { timing: options.timing } : {}),
  })

  // Every change of the visible chat counts as a switch (Mac `Nav3`), except
  // the chat restored at start, which the user did not pick now.
  let previousChat: ChatID | undefined
  let first = true
  disposers.push(
    effect(() => {
      const chatId = session.sidebar.selectedChatId.get()
      untracked(() => {
        if (first) {
          first = false
          previousChat = chatId
          return
        }
        if (chatId === undefined || chatId === previousChat) {
          previousChat = chatId
          return
        }
        previousChat = chatId
        const chat = store.peekRow(rowKey("chat", chatId)) as ChatRow | undefined
        usage.recordSwitch(chat?.peerUserId !== undefined ? userUsageKey(chat.peerUserId) : chatUsageKey(chatId))
      })
    }),
  )

  // A modal keyboard layer while open: global shortcuts stay quiet under the palette.
  if (options.keyboard) {
    const keyboard = options.keyboard
    disposers.push(
      effect(() => {
        if (!model.isOpen.get()) return
        return untracked(() => keyboard.pushLayer("dialog", { modal: true }))
      }),
    )
  }

  const workspace = session.workspace

  const directChatWith = (userId: UserID): ChatID | undefined =>
    local.chats.peek().find((candidate) => candidate.peerUserId === userId)?.chatId

  const perform = (outcome: QuickSearchOutcome): boolean => {
    let done = true
    switch (outcome.kind) {
      case "open":
        workspace.open(outcome.destination, { intent: outcome.intent })
        break
      case "openUser": {
        const chatId = directChatWith(outcome.userId)
        if (chatId !== undefined) workspace.open({ kind: "chat", chatId }, { intent: outcome.intent })
        else if (options.openUser) options.openUser(outcome.userId, outcome.intent)
        else workspace.open({ kind: "user", userId: outcome.userId }, { intent: outcome.intent })
        break
      }
      case "openSpace":
        if (options.openSpace) options.openSpace(outcome.spaceId)
        else workspace.open({ kind: "space", spaceId: outcome.spaceId, page: "members" })
        break
      case "runCommand":
        done = session.registry.run(outcome.commandId, { source: "palette" })
        break
      case "createThread":
        if (options.createThread) options.createThread(outcome.spaceId, outcome.title)
        else workspace.open({ kind: "newThread", spaceId: outcome.spaceId })
        break
      case "none":
        done = false
        break
    }
    options.onPerform?.(outcome)
    return done
  }

  let disposed = false
  return {
    model,
    usage,
    platform,
    commands: session.registry,
    local,
    context,
    isOpen: model.isOpen,
    open: () => {
      if (disposed || model.isOpen.peek()) return
      model.open()
    },
    close: () => model.close(),
    toggle: () => {
      if (model.isOpen.peek()) model.close()
      else if (!disposed) model.open()
    },
    activate: (item, intent = "here") => {
      const outcome = model.activate(item, intent)
      perform(outcome)
      return outcome
    },
    perform,
    photoUrl: (userId) => (store.peekRow(rowKey("user", userId)) as UserRow | undefined)?.photoUrl,
    clearUsage: () => usage.clear(),
    dispose: () => {
      if (disposed) return
      disposed = true
      model.dispose()
      for (const dispose of disposers.splice(0).reverse()) dispose()
      for (const handle of handles) handle.unsubscribe()
      usage.dispose()
    },
  }
}

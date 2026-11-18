/**
 * Everything that exists while a user is signed in: the connection to the
 * account's core, its status, the signed-in user, the workspace restored for
 * this account, the commands, the sidebar and the resident chats.
 *
 * Created by the app model on sign-in and disposed on sign-out. The core
 * connection is injected (`web/src/core/connect.ts` in the app, a scripted
 * endpoint in tests), so this file never touches a worker or the DOM.
 */

import {
  receivedMessageRowId,
  rowKey,
  type CoreEndpoint,
  type CoreResource,
  type DialogRow,
  type QueryDescriptor,
  type Row,
  type RowKey,
  type SyncStall,
  type UserRow,
  type WindowAnchor,
} from "@inline/core-protocol"
import type { ChatID, UserID } from "@inline/ids"
import {
  computed,
  effect,
  plainEqual,
  untracked,
  type ClientSnapshotData,
  type Clock,
  type ReadSignal,
  type StoreClient,
  type SubscriptionHandle,
} from "@inline/reactive"
import { registerNavigationCommands, type FocusRegion } from "../commands/navigation"
import type { Platform } from "../commands/platform"
import { CommandRegistry } from "../commands/registry"
import type { HistoryBinding } from "../workspace/history-binding"
import { createWorkspaceStore, restoreWorkspace, type StorageLike, type WorkspaceStore } from "../workspace/persistence"
import type { ExternalOpener, Workspace } from "../workspace/workspace"
import { ChatCache, defaultResidentChats, type ChatLease } from "./chat-cache"
import { ChatModel } from "./chat-model"
import {
  createConnectionDisplay,
  sessionHealthSignal,
  sessionStatusSignal,
  type ConnectionDisplay,
  type DisplayedConnection,
  type SessionHealth,
  type SessionStatus,
} from "./connection-status"
import { destinationChatId } from "./helpers"
import { actionHandle, IntentTracker, type ActionHandle } from "./intent-outcome"
import { SessionActions, type ActionHooks } from "./session-actions"
import { SidebarModel, type SidebarHooks, type SidebarMode } from "./sidebar-model"

/**
 * What a connector returns: the shape of `AccountConnection` in
 * `web/src/core/connect.ts` (its `core` is a `LinkedCore`, which is a
 * `CoreEndpoint`).
 */
export type AccountConnection = {
  readonly core: CoreEndpoint
  readonly client: StoreClient
  /**
   * State to show before the core answers: the boot snapshot, as
   * `exportProvisional` produced it. The session restores it into `client`
   * before any model subscribes, and the models take the restored
   * subscriptions over, so they read it in the same task.
   */
  readonly provisional?: ClientSnapshotData
  /** Stops forwarding signals, releases the store and leaves the account's election. */
  close(): void
}

export type AccountConnector = (userId: UserID) => AccountConnection

/** Callbacks into the view layer for commands whose effect is visual. Default no-ops. */
export type SessionViewHooks = {
  readonly focusRegion: (region: FocusRegion) => void
  readonly openQuickSearch: () => void
  readonly toggleSidebar: () => void
  readonly openSettings?: () => void
}

export type AccountSessionOptions = {
  readonly userId: UserID
  readonly token: string
  readonly connect: AccountConnector
  /** Sent in `hello`. Without it no `hello` is posted (tests). */
  readonly buildId?: string
  /** Protocol version for `hello`. */
  readonly protocol?: number
  readonly clock: Clock
  /** Wall clock in milliseconds since the epoch. Default `Date.now`. */
  readonly now?: () => number
  readonly random?: () => number
  readonly newClientKey?: () => string
  /** Where the workspace is kept (`localStorage`). Without it the workspace is not persisted. */
  readonly storage?: StorageLike
  /** The command registry to register into. Default: a registry of the session's own. */
  readonly registry?: CommandRegistry
  readonly opener?: ExternalOpener
  readonly sidebarMode?: SidebarMode
  readonly sidebarHooks?: SidebarHooks
  readonly residentChats?: number
  /** For shortcut hints in action menus. `AppModel` passes its own. */
  readonly platform?: Platform
  /**
   * How long `end` keeps the connection open for the core to report the
   * replica erased. Default `SIGN_OUT_WAIT_MS`.
   */
  readonly signOutWaitMs?: number
}

/**
 * How long `end` waits for the core's `signedOut`. The core tells the server
 * (at most 3 s) and erases the replica; past this the session closes anyway.
 * The link then still gives the worker its own, longer sign-out bound
 * (`SIGN_OUT_SHUTDOWN_TIMEOUT_MS` in `@inline/link`) before terminating it,
 * and the boot sweep removes anything an interrupted erase left behind.
 */
export const SIGN_OUT_WAIT_MS = 10_000

/**
 * How an `end` finished, as far as this context can tell:
 *
 * - `erased`: the core reported `signedOut` (`erased: "complete"`) after the
 *   sign-out, or had already reported it (a revocation, or another context's
 *   sign-out), which it does only after erasing.
 * - `eraseFailed`: the same with `erased: "failed"`; the core keeps its erase
 *   marker, and the next start of that account or the boot sweep finishes it.
 * - `timedOut`: no answer within `signOutWaitMs`; the connection closed anyway.
 * - `notRunning`: this context never saw a running session on the core
 *   (no core resource yet, superseded, or never past `signedOut`); nothing to
 *   wait for here.
 * - `interrupted`: the session was disposed while waiting.
 */
export type SignOutOutcome = "erased" | "eraseFailed" | "timedOut" | "notRunning" | "interrupted"

/** What `exportProvisional` exports besides the signed-in user and the visible sidebar. */
export type ProvisionalExportOptions = {
  /** Also export this chat's window, when the chat is resident. */
  readonly chatId?: ChatID
  /** The part of each list to keep (the first screen of the sidebar, the rows around the reading place). */
  readonly select?: (query: QueryDescriptor, keys: readonly RowKey[]) => readonly RowKey[]
}

/**
 * The rows a row needs to be drawn that are not in a list, for the boot
 * snapshot: a dialog its chat, peer and draft; a chat its peer and last
 * message; a message its sender, and its chat and draft (the header and
 * composer of the chat the window belongs to).
 */
export const relatedRowKeys = (row: Row): RowKey[] => {
  switch (row.kind) {
    case "dialog":
      return [
        rowKey("chat", row.chatId),
        ...(row.peerUserId ? [rowKey("user", row.peerUserId)] : []),
        rowKey("draft", row.chatId),
      ]
    case "chat":
      return [
        ...(row.peerUserId ? [rowKey("user", row.peerUserId)] : []),
        ...(row.lastMessageId ? [rowKey("message", receivedMessageRowId(row.id, row.lastMessageId))] : []),
        ...(row.lastMessageRowId ? [rowKey("message", row.lastMessageRowId)] : []),
      ]
    case "message":
      return [rowKey("user", row.fromId), rowKey("chat", row.chatId), rowKey("draft", row.chatId)]
    default:
      return []
  }
}

/** Whether a subscription restored from the boot snapshot can stand in for one a model asks for. */
const adopts = (restored: QueryDescriptor, wanted: QueryDescriptor): boolean => {
  if (wanted.kind === "chatWindow") {
    // The restored window was anchored where the reader was. A model asked to
    // open at a message (a link) wants that message instead.
    return restored.kind === "chatWindow" && restored.chatId === wanted.chatId && typeof wanted.anchor !== "object"
  }
  return plainEqual(restored, wanted)
}

const erasedOutcome = (resource: CoreResource): SignOutOutcome =>
  resource.erased === "failed" ? "eraseFailed" : "erased"

/** Workspace storage key for an account. */
export const workspaceStorageKey = (userId: UserID): string => `inline:workspace:${userId}`

const noop = () => {}

export class AccountSession {
  readonly userId: UserID
  readonly client: StoreClient
  readonly core: CoreEndpoint
  /** The core's phase, connection and storage, as the core reports them. */
  readonly coreResource: ReadSignal<CoreResource | undefined>
  /** The connection state worth showing now (rule 15). */
  readonly connection: ReadSignal<DisplayedConnection | undefined>
  readonly status: ReadSignal<SessionStatus>
  /**
   * Why the app may be behind the server: offline, connecting, updating,
   * stalled sync (with whether `retrySync` may help), or the session refused.
   * For an indicator beside `status`, which keeps its own values.
   */
  readonly health: ReadSignal<SessionHealth>
  /** Sync scopes that stopped retrying (`CoreResource.stalledSync`); empty when none. */
  readonly stalledSync: ReadSignal<readonly SyncStall[]>
  /** True once the core reports the session revoked. The app model signs out on it. */
  readonly revoked: ReadSignal<boolean>
  readonly me: ReadSignal<UserRow | undefined>
  readonly workspace: Workspace
  readonly registry: CommandRegistry
  readonly sidebar: SidebarModel
  /** Prominent unread chats across every non-archived chat, for the badge (rule 9). */
  readonly badgeCount: ReadSignal<number>
  readonly chats: ChatCache
  /** True when the session started from a boot snapshot (`AccountConnection.provisional`). */
  readonly restoredFromSnapshot: boolean
  /** Follows actions to their final result; shared by the chat models. */
  readonly intents: IntentTracker
  /** Message commands, message row actions and sidebar row actions. */
  readonly actions: SessionActions

  readonly #options: AccountSessionOptions
  readonly #connection: AccountConnection
  readonly #coreSub: SubscriptionHandle
  readonly #meSub: SubscriptionHandle
  readonly #display: ConnectionDisplay
  readonly #workspaceStore: WorkspaceStore | undefined
  readonly #badgeSidebar: SidebarModel
  /** A chat's dialog row through `ChatRow.dialogId`, one computed per chat. */
  readonly #dialogs = new Map<ChatID, ReadSignal<DialogRow | undefined>>()
  readonly #disposers: (() => void)[] = []
  /** Subscriptions restored from the boot snapshot that no model has taken yet. */
  readonly #restored: SubscriptionHandle[]
  #history: HistoryBinding | undefined
  #view: SessionViewHooks = { focusRegion: noop, openQuickSearch: noop, toggleSidebar: noop }
  #disposed = false
  /** The core reported a session past `signedOut` at least once. */
  #sawSession = false
  #ending: Promise<SignOutOutcome> | undefined
  #outcome: SignOutOutcome | undefined
  /** Stops a pending `end` wait and closes the connection. */
  #finishEnding: ((outcome: SignOutOutcome) => void) | undefined

  constructor(options: AccountSessionOptions) {
    this.#options = options
    this.userId = options.userId
    this.#connection = options.connect(options.userId)
    this.core = this.#connection.core
    this.client = this.#connection.client
    // Before any subscription, so no result or dialog row is missed.
    this.intents = new IntentTracker({ core: this.core, store: this.client.store })

    if (options.buildId !== undefined) {
      this.core.post({ kind: "hello", buildId: options.buildId, protocol: options.protocol ?? 0 })
    }
    this.core.post({ kind: "session", action: "start", session: { userId: options.userId, token: options.token } })

    // After the session start (the core answers a subscription made before it
    // with nothing), before any model subscribes.
    const provisional = this.#connection.provisional
    this.#restored = provisional ? this.client.restore(provisional) : []
    this.restoredFromSnapshot = this.#restored.length > 0
    const subscribe = (query: QueryDescriptor) => this.#subscribe(query)

    this.#coreSub = subscribe({ kind: "core" })
    const coreResource = this.#coreSub.resource
    this.coreResource = computed(() => {
      const value = coreResource.get()
      return value?.kind === "core" ? value : undefined
    })
    this.#display = createConnectionDisplay({
      connection: computed(() => this.coreResource.get()?.connection),
      clock: options.clock,
    })
    this.connection = this.#display.displayed
    this.status = sessionStatusSignal(this.coreResource, this.#display)
    this.health = sessionHealthSignal(this.coreResource, this.#display)
    const noStalls: readonly SyncStall[] = []
    this.stalledSync = computed(() => this.coreResource.get()?.stalledSync ?? noStalls, { equals: plainEqual })
    this.revoked = computed(() => this.coreResource.get()?.connection === "sessionRevoked")
    this.#disposers.push(
      effect(() => {
        const phase = this.coreResource.get()?.phase
        if (phase !== undefined && phase !== "signedOut" && phase !== "superseded") this.#sawSession = true
      }),
    )

    this.#meSub = subscribe({ kind: "me" })
    const meKeys = this.#meSub.list
    this.me = computed(() => {
      const key = meKeys.get()[0]
      return key ? (this.client.store.rowByKey(key).get() as UserRow | undefined) : undefined
    })

    this.#workspaceStore = options.storage
      ? createWorkspaceStore(options.storage, workspaceStorageKey(options.userId))
      : undefined
    this.workspace = restoreWorkspace(this.#workspaceStore?.load(), options.opener ? { opener: options.opener } : {})

    this.sidebar = new SidebarModel({
      client: this.client,
      workspace: this.workspace,
      mode: options.sidebarMode ?? "inbox",
      subscribe,
      core: this.core,
      ...(options.sidebarHooks ? { hooks: options.sidebarHooks } : {}),
    })
    // The badge counts every non-archived chat, not only what the visible
    // mode lists, so it has its own `all` list. Rows are shared in the store;
    // the cost is one list of keys.
    this.#badgeSidebar = new SidebarModel({
      client: this.client,
      workspace: this.workspace,
      mode: "all",
      subscribe,
      core: this.core,
      ...(options.sidebarHooks ? { hooks: options.sidebarHooks } : {}),
    })
    this.badgeCount = this.#badgeSidebar.prominentUnreadCount

    this.chats = new ChatCache({
      capacity: options.residentChats ?? defaultResidentChats,
      pinned: () => this.#chatsInPanes(),
      create: (chatId, anchor) => this.#createChat(chatId, anchor),
    })

    this.registry = options.registry ?? new CommandRegistry()
    this.actions = new SessionActions({
      client: this.client,
      viewerId: options.userId,
      chat: (chatId) => {
        const model = this.chats.peek(chatId)
        return model && !model.disposed ? model : undefined
      },
      intents: this.intents,
      ...(options.platform ? { platform: options.platform } : {}),
    })
    this.#disposers.push(this.actions.register(this.registry))
    // Read at run time: the app binds history after the session exists.
    const currentHistory = () => this.#history
    this.#disposers.push(
      registerNavigationCommands(this.registry, {
        workspace: this.workspace,
        get history() {
          return currentHistory()
        },
        selectAdjacentChat: (direction) => {
          this.sidebar.selectAdjacent(direction)
        },
        canSelectAdjacentChat: this.sidebar.canSelectAdjacent,
        focusRegion: (region) => this.#view.focusRegion(region),
        openQuickSearch: () => this.#view.openQuickSearch(),
        toggleSidebar: () => this.#view.toggleSidebar(),
        openSettings: () => {
          if (this.#view.openSettings) this.#view.openSettings()
          else this.workspace.open({ kind: "settings" })
        },
      }),
    )

    // A restored chat window waits for its chat's pane (the shell mounts after
    // this); everything else restored is taken above or not needed. What is
    // still unclaimed when the core is ready is released.
    this.#releaseRestored((handle) => handle.query.kind !== "chatWindow")
    if (this.#restored.length > 0) {
      this.#disposers.push(
        effect(() => {
          if (this.coreResource.get()?.phase === "ready") untracked(() => this.#releaseRestored(() => true))
        }),
      )
    }

    this.#disposers.push(
      this.workspace.subscribe(() => {
        this.#workspaceStore?.save(this.workspace)
        this.chats.evict()
      }),
    )
  }

  /** Open a chat's model for a pane. Release the lease when the pane stops showing it. */
  openChat(chatId: ChatID, anchor?: WindowAnchor): ChatLease {
    return this.chats.open(chatId, anchor)
  }

  /**
   * A chat's dialog row (unread count, read marker, modes): the chat row's
   * `dialogId` (set on every chat row the core publishes) to the dialog row,
   * as the store holds them. Undefined while either is not on this context
   * (a chat whose rows no query here carries yet, an account with no dialog
   * for it). One cached computed per chat; it follows both rows.
   */
  dialogFor(chatId: ChatID): ReadSignal<DialogRow | undefined> {
    let dialog = this.#dialogs.get(chatId)
    if (!dialog) {
      const store = this.client.store
      dialog = computed(() => {
        const dialogId = store.row("chat", chatId).get()?.dialogId
        return dialogId === undefined ? undefined : store.row("dialog", dialogId).get()
      })
      this.#dialogs.set(chatId, dialog)
    }
    return dialog
  }

  /** Retry every stalled sync scope now (`health` kind `syncStalled`). */
  retrySync(): ActionHandle {
    return actionHandle(this.client.intent({ kind: "retrySync" }), "retry syncing", {
      store: this.client.store,
      tracker: this.intents,
    })
  }

  /** Connect what only views can do for message and sidebar actions. Returns a function that disconnects them. */
  attachActions(hooks: ActionHooks): () => void {
    return this.actions.attach(hooks)
  }

  /** The history binding, once the app created it for the workspace. Back and Forward use it. */
  setHistory(history: HistoryBinding | undefined): void {
    this.#history = history
  }

  /** Connect the view callbacks. Returns a function that disconnects them. */
  attachView(hooks: SessionViewHooks): () => void {
    this.#view = hooks
    return () => {
      if (this.#view === hooks) this.#view = { focusRegion: noop, openQuickSearch: noop, toggleSidebar: noop }
    }
  }

  /**
   * The state to paint the next start from (the boot snapshot): the
   * signed-in user, the visible sidebar list and, with `chatId`, that chat's
   * window, each with the rows it needs (`relatedRowKeys`). Rows only the
   * overlay predicts are not exported. Undefined once disposed.
   */
  exportProvisional(options: ProvisionalExportOptions = {}): ClientSnapshotData | undefined {
    if (this.#disposed) return undefined
    const handles = [this.#meSub, this.sidebar.subscription]
    const chat = options.chatId !== undefined ? this.chats.peek(options.chatId) : undefined
    if (chat && !chat.disposed) handles.push(chat.windowSubscription)
    const queries = new Map(handles.map((handle) => [handle.sub, handle.query]))
    const select = options.select
    return this.client.exportSubscriptions(handles, {
      expand: relatedRowKeys,
      ...(select
        ? {
            select: (sub: number, keys: readonly RowKey[]) => {
              const query = queries.get(sub)
              return query ? select(query, keys) : keys
            },
          }
        : {}),
    })
  }

  /** Save what is kept across reloads now (the app calls it on `pagehide`). */
  flush(): void {
    if (!this.#disposed) this.#workspaceStore?.save(this.workspace)
  }

  /**
   * End the account in this context: ask the core to sign out (it stops
   * realtime and erases the replica; a repeat is harmless) and dispose.
   * With `erase`, the workspace kept for this account is cleared too.
   *
   * The models are released at once (`disposed` is true on return). When the
   * core was seen running a session, the connection and the `core`
   * subscription stay open until the core reports `signedOut` (after its erase), or
   * `signOutWaitMs` passes, so closing never cuts the erase short. Resolves
   * with how it ended (`signOutOutcome`). Repeated calls return the same
   * promise.
   */
  end(options: { erase?: boolean } = {}): Promise<SignOutOutcome> {
    if (this.#ending) return this.#ending
    if (this.#disposed) return Promise.resolve("interrupted")
    const before = this.coreResource.peek()
    this.core.post({ kind: "session", action: "signOut" })
    if (options.erase) this.#workspaceStore?.clear()
    const settled = this.#settledBeforeWait(before)
    if (settled) {
      this.#outcome = settled
      this.dispose({ save: !options.erase })
      this.#ending = Promise.resolve(settled)
      return this.#ending
    }

    this.#release({ save: !options.erase })
    const clock = this.#options.clock
    this.#ending = new Promise<SignOutOutcome>((resolve) => {
      let stop: (() => void) | undefined
      let finished = false
      const finish = (outcome: SignOutOutcome) => {
        if (finished) return
        finished = true
        this.#finishEnding = undefined
        clock.clearTimeout(timer)
        stop?.()
        this.#outcome = outcome
        this.#close()
        resolve(outcome)
      }
      const timer = clock.setTimeout(() => finish("timedOut"), this.#options.signOutWaitMs ?? SIGN_OUT_WAIT_MS)
      this.#finishEnding = finish
      stop = effect(() => {
        const resource = this.coreResource.get()
        // Only a report after the sign-out was posted counts.
        if (!resource || resource === before) return
        if (resource.phase === "signedOut") untracked(() => finish(erasedOutcome(resource)))
      })
      if (finished) stop()
    })
    return this.#ending
  }

  /** How the last `end` finished; undefined until it has. */
  get signOutOutcome(): SignOutOutcome | undefined {
    return this.#outcome
  }

  /** The outcome when there is nothing to wait for, from the core state when `end` was called. */
  #settledBeforeWait(before: CoreResource | undefined): SignOutOutcome | undefined {
    if (!before || before.phase === "superseded") return "notRunning"
    if (before.phase !== "signedOut" || before.signingOut) return undefined
    // The core reports `signedOut` after a session only once the erase is
    // over (a revocation, or another context's sign-out finished first).
    if (before.erased || before.connection === "sessionRevoked" || this.#sawSession) return erasedOutcome(before)
    return "notRunning"
  }

  /** Unsubscribe everything and close the connection. Idempotent; ends a pending `end` wait at once. */
  dispose(options: { save?: boolean } = {}): void {
    if (this.#disposed) {
      this.#finishEnding?.("interrupted")
      return
    }
    this.#release(options)
    this.#close()
  }

  /** Releases the models and every subscription except the `core` one. */
  #release(options: { save?: boolean }): void {
    if (this.#disposed) return
    if (options.save !== false) this.#workspaceStore?.save(this.workspace)
    this.#disposed = true
    for (const dispose of this.#disposers.splice(0).reverse()) dispose()
    this.#releaseRestored(() => true)
    this.chats.dispose()
    this.actions.dispose()
    this.#badgeSidebar.dispose()
    this.sidebar.dispose()
    this.#display.dispose()
    this.#meSub.unsubscribe()
    this.intents.dispose()
    this.#dialogs.clear()
  }

  #close(): void {
    this.#coreSub.unsubscribe()
    this.#connection.close()
  }

  get disposed(): boolean {
    return this.#disposed
  }

  /** A restored subscription that can stand in for `query`, else a new one. */
  #subscribe(query: QueryDescriptor): SubscriptionHandle {
    const index = this.#restored.findIndex((handle) => adopts(handle.query, query))
    const restored = index >= 0 ? this.#restored.splice(index, 1)[0] : undefined
    return restored ?? this.client.subscribe(query)
  }

  #releaseRestored(which: (handle: SubscriptionHandle) => boolean): void {
    for (let i = this.#restored.length - 1; i >= 0; i--) {
      const handle = this.#restored[i]
      if (handle && which(handle)) {
        this.#restored.splice(i, 1)
        handle.unsubscribe()
      }
    }
  }

  #createChat(chatId: ChatID, anchor: WindowAnchor | undefined): ChatModel {
    const options = this.#options
    return new ChatModel({
      client: this.client,
      subscribe: (query) => this.#subscribe(query),
      chatId,
      userId: this.userId,
      clock: options.clock,
      ...(anchor ? { anchor } : {}),
      ...(options.now ? { now: options.now } : {}),
      ...(options.random ? { random: options.random } : {}),
      ...(options.newClientKey ? { newClientKey: options.newClientKey } : {}),
      dialog: this.dialogFor(chatId),
      intents: this.intents,
      post: (command) => {
        if (!this.#disposed) this.core.post(command)
      },
    })
  }

  #chatsInPanes(): ReadonlySet<ChatID> {
    const chats = new Set<ChatID>()
    for (const pane of this.workspace.panes.peek()) {
      const entry = pane.entries[pane.index]
      const chatId = entry ? destinationChatId(entry.destination) : undefined
      if (chatId !== undefined) chats.add(chatId)
    }
    return chats
  }
}

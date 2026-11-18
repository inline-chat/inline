/**
 * The chat pane's model: which chat a pane shows, and the wiring between its
 * `ChatModel` (from the session's resident cache) and the timeline
 * controller (`@inline/timeline`). Framework-free; `ChatPane.tsx` creates
 * one per pane with `useModel` and calls `show(destination)` as the pane's
 * destination changes.
 *
 * - Showing another chat reuses the pane: the old chat's controller saves
 *   its reading place (`leave`) and is disposed, its lease is released (the
 *   cache keeps it resident), and the new chat's model comes from the cache.
 *   A resident chat already has its rows, so the controller is opened with
 *   them in the same task and the next frame paints them.
 * - Showing a message in the chat already shown jumps to it.
 * - Rows become timeline items through `timelineItems`, with the unread
 *   line fixed for the visit; read state and paging go back to the model.
 * - Incoming rows reach the timeline in the same task as the store change:
 *   the store client applies a patch batch at the start of a frame, the
 *   chat model's signals change inside that batch, the effect below runs
 *   when the batch ends and calls `setItems`, the controller publishes
 *   `rendered` synchronously, and the view commits in the microtask React
 *   queues. Nothing here waits for another frame, a timer or a microtask.
 *   `onStage` marks each hand-off (`ChatPaneStage`).
 */

import { rowKeyOf, type MessageRow, type RowKey, type WindowAnchor } from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { computed, effect, scope, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import {
  createTimelineController,
  timelineItems,
  type Clock as TimelineClock,
  type FrameSource,
  type OpenTarget,
  type SavedPlace,
  type TimelineController,
  type TimelineItem,
  type TimelineWindow,
} from "@inline/timeline"
import { emptyDestination, sameDestination, type Destination, type PaneId, type Workspace } from "@inline/view"
import {
  chatSubtitle,
  type AccountSession,
  type ChatHeader,
  type ChatLease,
  type ChatModel,
  type ChatSubtitle,
  type ChatWindowState,
  type ComposerSendOutcome,
  type ComposerSendRequest,
  type DisplayedConnection,
} from "@inline/view/features"
import type { ComposeStatus } from "../typing/presentation"
import { createChatTyping, type ChatTypingModel } from "../typing/typing-model"

/** The pane destinations that show a chat, reduced to what the pane needs. */
export type ChatPaneTarget = {
  readonly chatId: ChatID
  /** Open centered on this message (a link, a search hit). */
  readonly messageId?: MessageID
  readonly destination: Destination
}

export const chatPaneTarget = (destination: Destination): ChatPaneTarget | undefined => {
  switch (destination.kind) {
    case "chat":
      return { chatId: destination.chatId, destination }
    case "message":
      return { chatId: destination.chatId, messageId: destination.messageId, destination }
    case "thread":
      return { chatId: destination.threadId, destination }
    default:
      return undefined
  }
}

/** A pane's current destination as a signal (empty once the pane is gone). */
export const paneDestination = (workspace: Pick<Workspace, "panes">, paneId: PaneId): ReadSignal<Destination> =>
  computed(
    () => {
      const pane = workspace.panes.get().find((candidate) => candidate.id === paneId)
      return pane?.entries[pane.index]?.destination ?? emptyDestination
    },
    { equals: sameDestination },
  )

/** What the pane needs from the session. `AccountSession` fits. */
export type ChatPaneSession = Pick<AccountSession, "openChat" | "userId" | "connection" | "client"> & {
  readonly workspace: Pick<Workspace, "viewState">
}

/**
 * Hand-offs of rows from the store to the screen, for performance marks
 * (`inline.timeline.<stage>`): `rows` the pane read the chat model's rows
 * after a store change; `setItems` the controller has the items and has
 * published what to render; `commit` the view has committed them (a
 * microtask after `setItems`, queued after the view framework's own).
 */
export type ChatPaneStage = "rows" | "setItems" | "commit"

/** How an open chat got its first rows, for the performance lab (`__inlineApp.openChat.source`). */
export type OpenChatSource = "memory" | "sqlite" | "network"

/** Optional observers: boot marks and unsaved-work tracking. */
export type ChatPaneHooks = {
  /** A stage of rows reaching the screen after the chat was opened (incoming, sent, edited rows). */
  readonly onStage?: (stage: ChatPaneStage, chatId: ChatID) => void
  /** The first rows of a chat are rendered (after a switch, or at boot). */
  readonly onRowsShown?: () => void
  /** A switch to another chat started. */
  readonly onSwitch?: () => void
  /** A send started; resolves when it settles. */
  readonly trackSend?: (work: Promise<unknown>) => void
  /** The pane shows another chat (undefined: none, or the pane closed). */
  readonly onChat?: (chat: OpenChat | undefined) => void
}

export type ChatPaneOptions = {
  readonly session: ChatPaneSession
  /** IANA time zone for day separators. */
  readonly timeZone: string
  readonly clock: TimelineClock
  readonly frames: FrameSource
  readonly hooks?: ChatPaneHooks
}

/** What is kept per chat in the workspace's view-state bag. */
type ChatViewState = { readonly place?: SavedPlace }

const isSavedPlace = (value: unknown): value is SavedPlace =>
  typeof value === "object" &&
  value !== null &&
  typeof (value as SavedPlace).messageId === "string" &&
  typeof (value as SavedPlace).offset === "number"

const sameSubtitle = (a: ChatSubtitle, b: ChatSubtitle): boolean => {
  if (a.kind !== b.kind) return false
  if (a.kind === "connection") return a.state === (b as typeof a).state
  if (a.kind === "typing") return a.text === (b as typeof a).text
  return true
}

const toTimelineWindow = (window: ChatWindowState): TimelineWindow => ({
  hasOlder: window.hasOlder,
  hasNewer: window.hasNewer,
  atLatest: window.atLatest,
  loading: window.loading,
  ...(window.certifiedThrough !== undefined ? { contiguousThrough: window.certifiedThrough } : {}),
})

/** One chat shown in a pane: its model lease, its timeline controller and the composer's inputs. */
export class OpenChat {
  readonly chatId: ChatID
  readonly model: ChatModel
  readonly timeline: TimelineController
  readonly header: ReadSignal<ChatHeader>
  /**
   * The header's subtitle, rule 15's order: the connection state, then
   * typing and other compose activity (`activity`), then bot status for a
   * direct message with a bot.
   */
  readonly subtitle: ReadSignal<ChatSubtitle>
  /** Who is typing, uploading or recording here (`createChatTyping`); its kind picks the line's dots. */
  readonly activity: ReadSignal<ComposeStatus | undefined>
  /** The core's window as the timeline sees it (for the timeline view's edges and empty state). */
  readonly timelineWindow: ReadSignal<TimelineWindow>
  /** True once the controller was opened with the core's first window. */
  readonly opened: ReadSignal<boolean>
  /**
   * Where the first rows came from: `memory` when the window was ready in the
   * task that opened the chat (resident, or restored from the boot snapshot),
   * `sqlite` when the core's first answer had rows (or the chat is empty),
   * `network` when it answered with none while still loading. Undefined until
   * the controller opens.
   */
  readonly source: ReadSignal<OpenChatSource | undefined>
  #target: ChatPaneTarget
  readonly #lease: ChatLease
  readonly #typing: ChatTypingModel
  readonly #options: ChatPaneOptions
  readonly #opened = signal(false)
  readonly #source = signal<OpenChatSource | undefined>(undefined)
  readonly #stop: Dispose
  #disposed = false

  constructor(target: ChatPaneTarget, options: ChatPaneOptions) {
    this.#target = target
    this.#options = options
    this.chatId = target.chatId
    const anchor: WindowAnchor | undefined = target.messageId ? { around: target.messageId } : undefined
    this.#lease = options.session.openChat(target.chatId, anchor)
    const model = this.#lease.model
    this.model = model
    this.header = model.header
    this.opened = { get: () => this.#opened.get(), peek: () => this.#opened.peek() }
    this.source = { get: () => this.#source.get(), peek: () => this.#source.peek() }
    const connection: ReadSignal<DisplayedConnection | undefined> = options.session.connection
    const isDirect = computed(() => model.header.get().isDirect)
    this.#typing = createChatTyping({ client: options.session.client, chatId: target.chatId, isDirect })
    this.activity = this.#typing.status
    this.subtitle = computed(
      () => {
        const header = model.header.get()
        const typing = this.#typing.status.get()?.text
        return chatSubtitle({
          connection: connection.get(),
          ...(typing ? { typing } : {}),
          isDirect: header.isDirect,
          peerIsBot: header.peerIsBot,
        })
      },
      { equals: sameSubtitle },
    )

    this.timelineWindow = computed(() => toTimelineWindow(model.window.get()), {
      equals: (a, b) =>
        a.hasOlder === b.hasOlder &&
        a.hasNewer === b.hasNewer &&
        a.atLatest === b.atLatest &&
        a.loading === b.loading &&
        a.contiguousThrough === b.contiguousThrough,
    })

    const viewerId = options.session.userId
    this.timeline = createTimelineController({
      viewerId,
      clock: options.clock,
      frames: options.frames,
      request: (range) => model.request(range),
      markRead: (decision) => model.markRead(decision.maxId),
      savePlace: (place) => this.#savePlace(place),
    })

    const onStage = options.hooks?.onStage
    const chatId = target.chatId
    let constructing = true
    this.#stop = scope(() => {
      let previous: readonly TimelineItem[] | undefined
      let lineAbove: MessageID | undefined
      let rowsShown = false
      effect(() => {
        const keys = model.rowKeys.get()
        const rows: MessageRow[] = []
        for (const key of keys) {
          const row = model.row(key).get()
          if (row) rows.push(row)
        }
        const window = model.window.get()
        untracked(() => {
          const boundary = window.unreadBoundary
          const result = timelineItems(
            {
              rows,
              viewerId,
              timeZone: options.timeZone,
              ...(boundary
                ? { unread: { boundary, reachesHistoryStart: !window.hasOlder, ...(lineAbove ? { lineAbove } : {}) } }
                : {}),
            },
            previous,
          )
          previous = result.items
          lineAbove = result.unreadLineAbove
          if (!this.#opened.peek()) {
            if (!window.ready) return
            this.timeline.open({ target: this.#openTarget(window), items: result.items, window: toTimelineWindow(window) })
            this.#source.set(
              constructing ? "memory" : rows.length > 0 || window.loading === "none" ? "sqlite" : "network",
            )
            this.#opened.set(true)
          } else {
            onStage?.("rows", chatId)
            this.timeline.setItems(result.items, toTimelineWindow(window))
            if (onStage) {
              onStage("setItems", chatId)
              queueMicrotask(() => onStage("commit", chatId))
            }
          }
          if (!rowsShown && result.items.length > 0) {
            rowsShown = true
            options.hooks?.onRowsShown?.()
          }
        })
      })
      effect(() => {
        const readState = model.readState.get()
        if (readState) untracked(() => this.timeline.setReadState(readState))
      })
      // The timeline trimmed its rendered range (idle, far from the reader): the core may
      // release the rows outside it, so a long visit does not keep every page in memory.
      let renderedCount = 0
      effect(() => {
        const { start, end } = this.timeline.range.get()
        const count = end - start
        const shrank = count < renderedCount
        renderedCount = count
        if (!shrank || !this.#opened.peek()) return
        untracked(() => {
          const kept: RowKey[] = []
          for (const item of this.timeline.rendered.peek()) if (item.kind === "message") kept.push(rowKeyOf(item.row))
          model.trimToRows(kept)
        })
      })
      // An unread line still loading falls back to latest when the connection drops.
      effect(() => {
        if (connection.get() === "waitingForNetwork") untracked(() => this.timeline.connectionLost())
      })
    })
    constructing = false
  }

  get target(): ChatPaneTarget {
    return this.#target
  }

  get disposed(): boolean {
    return this.#disposed
  }

  /** The same chat at another destination (a message link): jump there. */
  retarget(target: ChatPaneTarget): void {
    const previous = this.#target
    this.#target = target
    if (target.messageId && target.messageId !== previous.messageId) {
      this.timeline.jumpToMessage(target.messageId, { highlight: true })
    }
  }

  /** The composer's `send`. The timeline follows the sent message; the send is tracked until it settles. */
  send = (request: ComposerSendRequest): Promise<ComposerSendOutcome> => {
    const work = this.model.sendFromComposer(request)
    this.#options.hooks?.trackSend?.(work)
    if (request.kind === "send") this.timeline.userSent()
    return work
  }

  /** The composer's `saveDraft`. */
  saveDraft = (text: string, entities: ComposerSendRequest["entities"] | undefined, revision: number): void => {
    this.model.saveDraft(text, entities, revision)
  }

  /** The draft to start the composer from, read synchronously (a resident chat has it). */
  initialDraft(): { text: string; entities?: ComposerSendRequest["entities"]; revision: number } | undefined {
    const draft = this.model.draft.peek()
    if (!draft) return undefined
    return { text: draft.text, ...(draft.entities ? { entities: draft.entities } : {}), revision: draft.revision }
  }

  /** Leave: save the reading place, stop feeding the controller, release the lease. */
  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.timeline.leave()
    this.#stop()
    this.#typing.dispose()
    this.timeline.dispose()
    this.#lease.release()
  }

  #openTarget(window: ChatWindowState): OpenTarget {
    if (this.#target.messageId) return { kind: "message", messageId: this.#target.messageId, highlight: true }
    const stored = this.#options.session.workspace.viewState.get<ChatViewState>(this.#target.destination)
    if (stored && isSavedPlace(stored.place)) return { kind: "place", place: stored.place }
    const unread = this.model.readState.peek()?.unreadCount ?? 0
    if (window.unreadBoundary && unread > 0) return { kind: "unread", boundary: window.unreadBoundary }
    return { kind: "latest" }
  }

  #savePlace(place: SavedPlace | null): void {
    const viewState = this.#options.session.workspace.viewState
    const destination: Destination = { kind: "chat", chatId: this.chatId }
    viewState.set(destination, place ? ({ place } satisfies ChatViewState) : undefined)
  }
}

/**
 * One per pane. `current` is the chat on screen; `show` swaps it. The pane
 * view renders `current` and nothing else, so the swap is one signal write.
 */
export class ChatPaneModel {
  readonly current: ReadSignal<OpenChat | undefined>
  readonly #options: ChatPaneOptions
  readonly #current = signal<OpenChat | undefined>(undefined)
  #stopFollowing: Dispose | undefined
  #disposed = false

  constructor(options: ChatPaneOptions) {
    this.#options = options
    this.current = { get: () => this.#current.get(), peek: () => this.#current.peek() }
  }

  /** Show a destination. A destination without a chat clears the pane. */
  show(destination: Destination): void {
    if (this.#disposed) return
    const target = chatPaneTarget(destination)
    const current = this.#current.peek()
    if (current && target && current.chatId === target.chatId) {
      current.retarget(target)
      return
    }
    if (!current && !target) return
    if (current) this.#options.hooks?.onSwitch?.()
    // Open the new chat before releasing the old one, so a chat shown in
    // both (another pane) never drops out of the cache in between.
    const next = target ? new OpenChat(target, this.#options) : undefined
    this.#current.set(next)
    current?.dispose()
    this.#options.hooks?.onChat?.(next)
  }

  /**
   * Show whatever `destination` holds, now and on every change (the pane's
   * entry in the workspace). Replaces an earlier `follow`.
   */
  follow(destination: ReadSignal<Destination>): void {
    this.#stopFollowing?.()
    this.#stopFollowing = effect(() => {
      const next = destination.get()
      untracked(() => this.show(next))
    })
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    this.#stopFollowing?.()
    this.#stopFollowing = undefined
    const current = this.#current.peek()
    this.#current.set(undefined)
    current?.dispose()
    if (current) this.#options.hooks?.onChat?.(undefined)
  }
}

/** The structural part of the composer controller that `followDraft` drives. */
export type DraftFollower = {
  readonly doc: ReadSignal<{ readonly text: string; readonly revision: number }>
  setDraft(draft: { text: string; entities?: ComposerSendRequest["entities"]; revision: number }): void
}

/**
 * A chat opened cold has no draft row until the core answers. When it
 * arrives, put it in the composer, unless the user already typed.
 * Call inside an owner (`useModel`'s scope); returns the disposer.
 */
export const followDraft = (chat: OpenChat, composer: DraftFollower): Dispose =>
  effect(() => {
    const draft = chat.model.draft.get()
    if (!draft) return
    untracked(() => {
      const doc = composer.doc.peek()
      if (doc.text.length > 0 || doc.revision >= draft.revision) return
      composer.setDraft({ text: draft.text, ...(draft.entities ? { entities: draft.entities } : {}), revision: draft.revision })
    })
  })

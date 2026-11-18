/**
 * The signed-in window's own state: the split between the sidebar and the
 * pane area (sizes and collapse persisted per account), the toasts, the
 * window-level status surface, and the focus targets the commands move
 * between. Framework-free; the shell view creates one per session with
 * `useModel` and hands it DOM elements through ref callbacks.
 *
 * It implements the session's view hooks (focus sidebar, focus composer,
 * toggle sidebar, quick search) and the runtime's shell hooks (type to
 * focus, restore focus after a removed element lost it).
 *
 * Per session it also owns: the find commands (Mod+F, Mod+G, Mod+Shift+G)
 * acting on the focused pane's `ChatFind`; the media layer (made from the
 * content chunk on first use, disposed with the session); the attachments
 * loader (`SessionAttachments`); and the media viewer (`MediaViewerHost`).
 */

import { computed, signal, type Dispose, type ReadSignal } from "@inline/reactive"
import { SplitViewController, ToastQueue, type SplitViewState } from "@inline/ui"
import type { FocusRegion, PaneId } from "@inline/view"
import type { AccountSession } from "@inline/view/features"
import { SessionAttachments, type AttachmentsChunkSource } from "../features/chat/chat-attachments"
import type { ChatFind } from "../features/chat/chat-find"
import { MediaViewerHost, type MediaViewerChunkSource, type ViewerKeyboard } from "../features/chat/media-viewer-host"
import { MessageActions, messageRowRect, type MessageLayersFactory } from "../features/chat/message-actions"
import { registerFindCommands } from "../features/find/commands"
import { chatSelectionText } from "../features/find/selection"
import type { ComposerModel } from "../features/composer/model"
import { listenTypeAnywhere } from "../features/composer/type-anywhere"
import type { QuickSearchWiring } from "../features/quick-search/wiring"
import { SidebarHandle } from "../features/sidebar/handle"
import type { SidebarTypingSource } from "../features/sidebar/activity"
import type { EmojiEngine } from "../features/emoji"
import { createComposeActivityIndex, type ComposeActivityIndex } from "../features/typing/typing-model"
import { SessionEmoji, type EmojiModules } from "./emoji-session"
import { focusWithoutScroll } from "./focus"
import { layoutStorageKey, type AppRuntime } from "./runtime"
import { statusSurface, type StatusSurface } from "./status"

export const SIDEBAR_PANE = "sidebar"
/** The toasts' distance from the message list's inline-end and block-end edges (the kit's advice for that container). */
export const TOAST_OFFSET = { inline: 12, block: 12 } as const
export const MAIN_PANE = "main"

/** Mac `Theme.swift`: sidebar 240 by default, 180 to 340. */
export const sidebarPaneSpec = {
  id: SIDEBAR_PANE,
  size: 240,
  minSize: 180,
  maxSize: 340,
  collapsible: true,
  label: "Resize sidebar",
} as const

const layoutVersion = 1

type StoredLayout = { v: typeof layoutVersion; split: SplitViewState }

const readLayout = (raw: string | null | undefined): Partial<SplitViewState> | undefined => {
  if (!raw) return undefined
  try {
    const value = JSON.parse(raw) as Partial<StoredLayout> | null
    if (!value || value.v !== layoutVersion || typeof value.split !== "object" || value.split === null) return undefined
    const sizes = typeof value.split.sizes === "object" && value.split.sizes !== null ? value.split.sizes : {}
    const collapsed = Array.isArray(value.split.collapsed)
      ? value.split.collapsed.filter((id): id is string => typeof id === "string")
      : []
    return { sizes, collapsed }
  } catch {
    return undefined
  }
}

export type ShellModelOptions = {
  readonly runtime: Pick<AppRuntime, "attachShell" | "storage">
  readonly session: AccountSession
  /** Schedules work for the next frame (after a collapsed sidebar is shown again). */
  readonly nextFrame?: (fn: () => void) => void
  readonly toasts?: ToastQueue
  /**
   * Quick Search for the session: loads its code and returns the wiring
   * function (`wireQuickSearch` bound to the options). It is not in the
   * initial bundle: `loadQuickSearch()` runs after the first paint, or on
   * the first Mod+K. Without it the command says it is not available.
   */
  readonly quickSearch?: () => Promise<(session: AccountSession) => QuickSearchWiring>
  /** The document, for type anywhere to focus the composer. Omitted in tests. */
  readonly document?: Document
  /** Write text to the clipboard (Copy Text, Copy Message Link). */
  readonly copyText?: (text: string) => Promise<boolean> | void
  /** This page's origin, for message links. Default the app's. */
  readonly origin?: string
  /** The attachments model's chunk. Without it, composers take text only. */
  readonly attachmentsChunk?: AttachmentsChunkSource
  /** The attachment strip's view (`attachmentStripChunk.load`), started with the model on the first file. */
  readonly attachmentStrip?: () => unknown
  /** The media viewer's chunk. Without it, photos do not open. */
  readonly mediaViewerChunk?: MediaViewerChunkSource
  /**
   * The reaction picker's and the confirmation alert's controllers (the
   * layers chunk's `kitLayers`), made on first need or when warmed. Without
   * it, neither opens (tests that do not exercise them).
   */
  readonly messageLayers?: MessageLayersFactory
  /** The app's keyboard, for the viewer's modal layer. */
  readonly keyboard?: ViewerKeyboard
  /** The emoji modules (`view-chunks.ts`). Without them, the reaction picker is the quick row and the composer has no `:` list. */
  readonly emoji?: EmojiModules
}

/** A pane's find, while that pane shows a chat. */
type PaneFind = { readonly find: ChatFind; readonly timeline: () => Element | null }

/** What a focusable region registers: a function that focuses it and says whether it did. */
export type FocusTarget = () => boolean

/** The composer as the shell sees it (`ComposerModel` fits). */
export type ShellComposer = Pick<ComposerModel, "focus" | "focused"> & {
  /** For text put in the composer without sending (a bot's compose button, a prompt suggestion). */
  readonly composer?: Pick<ComposerModel["composer"], "insertText">
}

export class ShellModel {
  readonly session: AccountSession
  readonly split: SplitViewController
  readonly toasts: ToastQueue
  readonly sidebarCollapsed: ReadSignal<boolean>
  /** The window-level surface for the session's status. */
  readonly surface: ReadSignal<StatusSurface>
  /** Quick Search, wired to this session once its code has loaded; the shell mounts its palette. */
  readonly quickSearch: ReadSignal<QuickSearchWiring | undefined>
  /** For "focus sidebar": the sidebar view binds it. */
  readonly sidebarHandle = new SidebarHandle()
  /** Message actions for the session: the hooks, the row actions, the reaction picker and delete confirmation. */
  readonly messageActions: MessageActions
  /** True once the sidebar can say "no chats" rather than "loading" (`SidebarModel.ready`). */
  readonly sidebarReady: ReadSignal<boolean>
  /** The focused pane's find in chat, while it shows a chat: what Mod+F, Mod+G and Mod+Shift+G act on. */
  readonly findTarget: ReadSignal<ChatFind | undefined>
  /** Attachments for the session's composers (the model loads on the first file). */
  readonly attachments: SessionAttachments | undefined
  /** The media viewer (its chunk loads on the first photo opened). */
  readonly mediaViewer: MediaViewerHost | undefined
  /** Emoji for this account: the reaction picker, the composer's `:` list and button, recents (loaded after the first paint). */
  readonly emoji: SessionEmoji | undefined
  /** The emoji table once loaded (reaction chips' names, `MessageRowContext.emojiEngine`); undefined before. */
  readonly emojiEngine: ReadSignal<EmojiEngine | undefined>
  /** Who is composing in each chat, for the sidebar's rows: one `composeActions` subscription for the session. */
  readonly composeActivity: ComposeActivityIndex
  /** `SidebarView`'s `typingFor`: the row's chat's activity. */
  readonly typingFor: SidebarTypingSource

  readonly #options: ShellModelOptions
  readonly #composers = new Map<PaneId, ShellComposer>()
  readonly #timelines = new Map<PaneId, FocusTarget>()
  readonly #detach: (() => void)[] = []
  readonly #quickSearch = signal<QuickSearchWiring | undefined>(undefined)
  readonly #finds = signal<ReadonlyMap<PaneId, PaneFind>>(new Map())
  #media: { dispose(): void } | undefined
  #quickSearchLoad: Promise<QuickSearchWiring | undefined> | undefined
  #sidebar: HTMLElement | null = null
  #disposed = false

  constructor(options: ShellModelOptions) {
    this.#options = options
    this.session = options.session
    const storage = options.runtime.storage
    const key = layoutStorageKey(options.session.userId)
    let stored: string | null = null
    try {
      stored = storage?.getItem(key) ?? null
    } catch {
      stored = null
    }
    const initial = readLayout(stored)
    this.split = new SplitViewController({
      panes: [sidebarPaneSpec, { id: MAIN_PANE, flex: true, minSize: 320 }],
      ...(initial ? { initial } : {}),
      onChange: (state) => {
        try {
          storage?.setItem(key, JSON.stringify({ v: layoutVersion, split: state } satisfies StoredLayout))
        } catch {
          // Losing a layout is better than failing a resize.
        }
      },
    })
    this.sidebarCollapsed = this.split.isCollapsed(SIDEBAR_PANE)
    // In the corner of the message list above the composer (each chat pane attaches `toasts.container`).
    this.toasts = options.toasts ?? new ToastQueue({ label: "Notifications", offset: TOAST_OFFSET })
    this.quickSearch = { get: () => this.#quickSearch.get(), peek: () => this.#quickSearch.peek() }
    this.surface = computed(() => statusSurface(this.session.status.get(), this.session.coreResource.get()))
    this.sidebarReady = this.session.sidebar.ready
    this.emoji = options.emoji
      ? new SessionEmoji({ userId: options.session.userId, storage: options.runtime.storage, modules: options.emoji })
      : undefined
    this.emojiEngine = computed(() => this.emoji?.services.get()?.loader.engine.get())
    this.composeActivity = createComposeActivityIndex({ client: options.session.client })
    this.typingFor = (item) => this.composeActivity.forChat(item.chatId)
    const doc = options.document
    this.messageActions = new MessageActions({
      session: this.session,
      copyText: (text) => options.copyText?.(text),
      toast: (input) => void this.toasts.show({ duration: 4000, ...input }),
      ...(options.origin !== undefined ? { origin: options.origin } : {}),
      ...(options.messageLayers ? { layers: options.messageLayers } : {}),
      // The emoji picker's code and data start loading with the first Add Reaction (if not warmed yet).
      onOpenPicker: () => void this.emoji?.use().catch(() => undefined),
      ...(doc
        ? {
            isTextSelected: () => {
              const selection = doc.getSelection()
              return !!selection && !selection.isCollapsed && selection.toString().length > 0
            },
            rowRect: (rowId: Parameters<typeof messageRowRect>[1]) => messageRowRect(doc, rowId),
          }
        : {}),
    })

    this.findTarget = computed(() => this.#finds.get().get(this.session.workspace.focusedPaneId.get())?.find)
    this.attachments = options.attachmentsChunk
      ? new SessionAttachments({
          chunk: options.attachmentsChunk,
          client: options.session.client,
          userId: options.session.userId,
          ...(options.attachmentStrip ? { loadStripView: options.attachmentStrip } : {}),
        })
      : undefined
    this.mediaViewer = options.mediaViewerChunk ? new MediaViewerHost(options.mediaViewerChunk, options.keyboard) : undefined

    this.#detach.push(
      this.messageActions.attach(),
      registerFindCommands(options.session.registry, {
        target: this.findTarget,
        // Seed from a selection inside the focused pane's message list only (never the composer's).
        readSelection: () => {
          const pane = this.#finds.peek().get(this.session.workspace.focusedPaneId.peek())
          return doc && pane ? chatSelectionText(doc, pane.timeline()) : undefined
        },
      }),
      options.session.attachView({
        focusRegion: (region) => this.focusRegion(region),
        openQuickSearch: () => this.openQuickSearch(),
        toggleSidebar: () => this.toggleSidebar(),
      }),
      ...(options.document
        ? [listenTypeAnywhere(options.document, () => (this.activeComposer() as ComposerModel | undefined) ?? null)]
        : []),
      options.runtime.attachShell({
        focusRegion: (region) => this.focusRegion(region),
        typeToFocus: () => {
          this.focusComposer()
        },
        restoreFocus: () => this.restoreFocus(),
      }),
    )
  }

  /** Ref callback for the sidebar column. */
  readonly sidebarElement = (element: HTMLElement): (() => void) => {
    this.#sidebar = element
    return () => {
      if (this.#sidebar === element) this.#sidebar = null
    }
  }

  /** A pane's composer registers itself while mounted. */
  registerComposer(paneId: PaneId, composer: ShellComposer): () => void {
    this.#composers.set(paneId, composer)
    return () => {
      if (this.#composers.get(paneId) === composer) this.#composers.delete(paneId)
    }
  }

  /** Put text in a pane's composer at the caret, without sending, and focus it. False without one. */
  composeInPane(paneId: PaneId, text: string): boolean {
    const composer = this.#composers.get(paneId)
    if (!composer?.composer) return false
    composer.composer.insertText(text)
    composer.focus()
    return true
  }

  /** The focused pane's composer, if it has one. */
  activeComposer(): ShellComposer | undefined {
    return this.#composers.get(this.session.workspace.focusedPaneId.peek())
  }

  /** A pane's find in chat, while the pane shows that chat. */
  registerFind(paneId: PaneId, find: ChatFind, timeline: () => Element | null): Dispose {
    const entry: PaneFind = { find, timeline }
    this.#finds.set(new Map(this.#finds.peek()).set(paneId, entry))
    return () => {
      if (this.#finds.peek().get(paneId) !== entry) return
      const next = new Map(this.#finds.peek())
      next.delete(paneId)
      this.#finds.set(next)
    }
  }

  /**
   * The session's media layer, made on first use (the content chunk passes
   * its factory) and disposed with the session: one set of subscriptions
   * and object URLs shared by every pane.
   */
  mediaSources<T extends { dispose(): void }>(create: () => T): T {
    if (!this.#media) this.#media = create()
    return this.#media as T
  }

  /** A pane's message list registers how to focus it while mounted. */
  registerTimeline(paneId: PaneId, focus: FocusTarget): () => void {
    this.#timelines.set(paneId, focus)
    return () => {
      if (this.#timelines.get(paneId) === focus) this.#timelines.delete(paneId)
    }
  }

  focusRegion(region: FocusRegion): void {
    if (region === "sidebar") this.focusSidebar()
    else this.focusComposer()
  }

  /** Focus the focused pane's composer. False when that pane has none. */
  focusComposer(): boolean {
    return this.activeComposer()?.focus() ?? false
  }

  /** Focus the sidebar's selected row (or the list), showing the sidebar first if it is collapsed. */
  focusSidebar(): boolean {
    if (this.sidebarCollapsed.peek()) {
      this.split.setCollapsed(SIDEBAR_PANE, false)
      const nextFrame = this.#options.nextFrame ?? ((fn: () => void) => void Promise.resolve().then(fn))
      nextFrame(() => this.#focusSidebarNow())
      return true
    }
    return this.#focusSidebarNow()
  }

  toggleSidebar(): void {
    const willCollapse = !this.sidebarCollapsed.peek()
    const sidebar = this.#sidebar
    const hadFocus = !!sidebar && !!sidebar.ownerDocument.activeElement && sidebar.contains(sidebar.ownerDocument.activeElement)
    this.split.toggleCollapsed(SIDEBAR_PANE)
    // Focus must not stay in a hidden sidebar.
    if (willCollapse && hadFocus && !this.focusComposer()) this.#timelines.get(this.session.workspace.focusedPaneId.peek())?.()
  }

  /**
   * Load and wire Quick Search (once; again after a failure). Resolves to the
   * wiring, or undefined without a loader, after a failure or once disposed.
   */
  loadQuickSearch(): Promise<QuickSearchWiring | undefined> {
    const load = this.#options.quickSearch
    if (!load || this.#disposed) return Promise.resolve(undefined)
    this.#quickSearchLoad ??= load().then(
      (wire) => {
        if (this.#disposed) return undefined
        const wiring = this.#quickSearch.peek() ?? wire(this.session)
        this.#quickSearch.set(wiring)
        return wiring
      },
      () => {
        this.#quickSearchLoad = undefined
        return undefined
      },
    )
    return this.#quickSearchLoad
  }

  /**
   * Open Quick Search. Before its code has loaded (the first Mod+K within
   * moments of start), it loads, the palette mounts, and it opens on the
   * next frame; without a loader, or when loading fails, a toast says so
   * instead of doing nothing.
   */
  openQuickSearch(): void {
    const wiring = this.#quickSearch.peek()
    if (wiring) {
      wiring.open()
      return
    }
    if (!this.#options.quickSearch) {
      this.toasts.show({ id: "quick-search", title: "Quick search isn't available yet", tone: "neutral", duration: 3000 })
      return
    }
    void this.loadQuickSearch().then((loaded) => {
      if (this.#disposed) return
      if (!loaded) {
        this.toasts.show({ id: "quick-search", title: "Quick search couldn't load", tone: "neutral", duration: 3000 })
        return
      }
      // The palette mounts in the commit this load caused; open once it is there.
      const nextFrame = this.#options.nextFrame ?? ((fn: () => void) => void Promise.resolve().then(fn))
      nextFrame(() => {
        if (!this.#disposed) loaded.open()
      })
    })
  }

  /** Focus fell to the page after its element went away: composer, else message list, else sidebar. */
  restoreFocus(): void {
    if (this.focusComposer()) return
    const paneId = this.session.workspace.focusedPaneId.peek()
    if (this.#timelines.get(paneId)?.()) return
    if (!this.sidebarCollapsed.peek()) this.#focusSidebarNow()
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    for (const detach of this.#detach.splice(0)) detach()
    this.#quickSearch.peek()?.dispose()
    this.#quickSearch.set(undefined)
    this.messageActions.dispose()
    this.emoji?.dispose()
    this.composeActivity.dispose()
    this.mediaViewer?.dispose()
    this.attachments?.dispose()
    this.#media?.dispose()
    this.#media = undefined
    this.#finds.set(new Map())
    this.toasts.dispose()
    this.#composers.clear()
    this.#timelines.clear()
  }

  #focusSidebarNow(): boolean {
    if (this.sidebarHandle.focus()) return true
    const sidebar = this.#sidebar
    if (!sidebar) return false
    const target =
      sidebar.querySelector<HTMLElement>('[aria-selected="true"]') ??
      sidebar.querySelector<HTMLElement>("[data-sidebar-list]") ??
      sidebar
    return focusWithoutScroll(target)
  }
}

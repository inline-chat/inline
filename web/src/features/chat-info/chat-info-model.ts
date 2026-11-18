/**
 * The chat info pane's model (the `chatInfo` destination): header, tabs,
 * the participants list with its keyboard controller, and the chat's
 * settings bound to the dialog intents.
 *
 * Mac reference: `InlineMac/Views/ChatInfo/ChatInfo.swift`. The Mac shows the
 * notification picker and the chat ID in a card above segmented tabs
 * (Participants for threads, then Media, Files, Voice and Links). Here the
 * tabs are the same, in that order, with Settings last (the Mac's card).
 * Each media tab is its own `ChatMediaModel` over `chatMedia`, made when it
 * is first shown. Adding and removing participants is `member-actions.ts`
 * and the picker `add-people.ts`.
 *
 * Settings write durable intents (`setDialogNotifications`,
 * `setDialogFollow`, `setDialogPinned`, `setDialogArchived`, `markUnread`)
 * with the dialog row predicted in the store's overlay, so the control moves
 * in the same frame and moves back if the core refuses. Each control has a
 * state saying plainly what happened: waiting to sync while offline, refused
 * (with the reason), or not confirmed (uncertain).
 *
 * Framework-free; the view (`ChatInfoPane.tsx`) renders it.
 */

import type { ChatRow, DialogRow, Intent, MediaContent, MessageRowId, RowKey, UserRow } from "@inline/core-protocol"
import type { ChatID, UserID } from "@inline/ids"
import {
  browserClock,
  computed,
  effect,
  plainEqual,
  scope,
  signal,
  untracked,
  type Clock,
  type ReadSignal,
  type StoreClient,
} from "@inline/reactive"
import {
  ContextMenuController,
  DialogController,
  ListboxController,
  TabsController,
  ToggleController,
  type MenuEntry,
  type Part,
} from "@inline/ui"
import type { ChatInfoTab } from "@inline/view"
import { actionHandle, chatAvatar, chatTitle, type ActionNotice, type AvatarInput, type IntentTracker } from "@inline/view/features"
import type { MediaSources, OpenMediaInput } from "../content"
import type { MediaVisibility } from "../media/visibility"
import { createAddPeople, type AddPeopleModel } from "./add-people"
import { createChatMediaModel, type ChatMediaModel, type ChatMediaTabId } from "./chat-media-model"
import { createMediaGrid, type MediaGrid } from "./media-grid"
import { createMemberActions, type MemberActions, type MemberActionsOptions } from "./member-actions"
import { createParticipantsModel, type ParticipantsModel } from "./participants-model"

/** The pane's own tabs. All but `settings` are destination tabs. */
export type ChatInfoPaneTab = "participants" | ChatMediaTabId | "settings"

/** What the media tabs need from the app (the session's media layer and the content views' handlers). */
export type ChatInfoMediaOptions = {
  /** The session's media sources (`createCoreMediaSources`): thumbnails, held per cell. */
  readonly sources: MediaSources & { createVisibility?(): MediaVisibility<object> }
  /** A photo or video was opened (the app's media viewer). */
  readonly onOpenMedia?: (input: OpenMediaInput) => void
  /** A file row's download (the content views' `onDownload`). */
  readonly onDownload?: (input: { readonly rowId: MessageRowId; readonly media: MediaContent }) => void
  /** A link row (the content views' link handler); default: nothing (the row is a plain link). */
  readonly onOpenLink?: (url: string) => void
}

export type NotificationChoice = "default" | "all" | "mentions" | "none"

/** The Mac's `DialogNotificationSettingSelection`, in its order and words. */
export const NOTIFICATION_CHOICES: readonly { readonly value: NotificationChoice; readonly label: string }[] = [
  { value: "default", label: "Default" },
  { value: "all", label: "All" },
  { value: "mentions", label: "Mentions" },
  { value: "none", label: "None" },
]

export type ChatInfoHeader = {
  readonly title: string
  /** "Direct message", "Bot", "Private thread", "Public thread", "Subthread", "Reply thread". */
  readonly kindLabel: string
  /** "8 participants", "3 participants, 1 group", "120 members"; absent until the list is complete. */
  readonly countText?: string
  readonly avatar: AvatarInput
  readonly chatIdText: string
}

export type ChatSettings = {
  /** The dialog row is known; without it the controls are disabled. */
  readonly available: boolean
  readonly isThread: boolean
  readonly notifications: NotificationChoice
  readonly following: boolean
  readonly pinned: boolean
  readonly archived: boolean
  readonly unread: boolean
}

export type ControlId = "notifications" | "follow" | "pin" | "archive" | "unread"

/**
 * - `idle`: nothing to say.
 * - `pending`: sent to the core, not yet committed.
 * - `waiting`: committed on this device while offline; it syncs on reconnect.
 * - `failed`: refused (offline for an action that needs a connection, storage full, the server said no).
 * - `uncertain`: the connection dropped before the server answered.
 */
export type ControlState =
  | { readonly kind: "idle" }
  | { readonly kind: "pending" }
  | { readonly kind: "waiting"; readonly text: string }
  | { readonly kind: "failed"; readonly notice: ActionNotice }
  | { readonly kind: "uncertain"; readonly notice: ActionNotice }

export const WAITING_TEXT = "Saved on this device. Inline will sync it when you're back online."

export type CopyState = "idle" | "copied" | "failed"

export type ChatInfoModelOptions = {
  readonly client: StoreClient
  readonly chatId: ChatID
  readonly viewerId: UserID
  /** The chat's dialog row (`session.dialogFor(chatId)`). */
  readonly dialog: ReadSignal<DialogRow | undefined>
  /** The session's tracker (`session.intents`), for final outcomes. */
  readonly intents?: IntentTracker
  /** The device is offline (`session.health` is `offline`). */
  readonly offline?: ReadSignal<boolean>
  /** The destination's tab; a tab the chat does not have opens the first one. */
  readonly tab?: ChatInfoTab
  /** The pane's tab changed: the destination tab, or undefined for settings (no destination tab). */
  readonly onTabChange?: (tab: ChatInfoTab | undefined) => void
  /** Open a person's profile (`{ kind: "user", userId }` destination). */
  readonly onOpenProfile: (userId: UserID) => void
  /** Write text to the clipboard. Without it, the copy control is hidden. */
  readonly copyText?: (text: string) => Promise<void> | void
  readonly clock?: Clock
  /** Share a participants model (with the chat's mention suggestions). Default: the model creates and owns one. */
  readonly participants?: ParticipantsModel
  /** The media tabs' services. Without it the media tabs list rows with no thumbnails and open nothing. */
  readonly media?: ChatInfoMediaOptions
  /** Outcomes of adding and removing participants, for the app's toasts (they also show under the list). */
  readonly onNotice?: MemberActionsOptions["onNotice"]
}

export type ChatInfoModel = {
  readonly chatId: ChatID
  readonly participants: ParticipantsModel
  readonly header: ReadSignal<ChatInfoHeader>
  readonly tabs: ReadSignal<readonly { readonly id: ChatInfoPaneTab; readonly label: string }[]>
  readonly tabsController: TabsController
  /** Keyboard navigation of the participants list; Enter or a click opens the profile. */
  readonly list: ListboxController
  /** Add and remove participants; `members.ids` is the list the pane shows. */
  readonly members: MemberActions
  readonly addPeople: AddPeopleModel
  /** The participants list's context menu: Remove where the viewer may. Rows carry `data-participant={key}`. */
  readonly participantMenu: ContextMenuController
  /** A row's actions (the context menu's items). */
  participantActions(key: RowKey): readonly MenuEntry[]
  /** A media tab's model, made on first use and kept while the pane is open. */
  mediaTab(tab: ChatMediaTabId): ChatMediaModel
  /** The photos and videos grid's keyboard navigation (the Media tab). */
  readonly mediaGrid: MediaGrid
  /**
   * Hand the media grid's element here: thumbnails subscribe only for cells
   * near the viewport (the media layer's visibility, on the grid's nearest
   * scrolling ancestor). A no-op without `media.sources.createVisibility`.
   */
  readonly mediaVisibility: Part
  /** The confirmation for a removal (`members.question`); opens and closes with it. */
  readonly removeDialog: DialogController
  readonly media: ChatInfoMediaOptions | undefined
  readonly settings: ReadSignal<ChatSettings>
  control(id: ControlId): ReadSignal<ControlState>
  readonly followSwitch: ToggleController
  readonly pinSwitch: ToggleController
  readonly archiveSwitch: ToggleController
  setNotifications(choice: NotificationChoice): void
  setFollowing(following: boolean): void
  setPinned(pinned: boolean): void
  setArchived(archived: boolean): void
  markUnread(): void
  /** Forget a control's message (the user dismissed it). */
  dismiss(id: ControlId): void
  readonly canCopy: boolean
  readonly copyState: ReadSignal<CopyState>
  copyChatId(): void
  /** Open the participant's profile; groups have none. */
  openParticipant(key: string): void
  dispose(): void
}

const COPIED_MS = 2_000

const kindLabel = (chat: ChatRow | undefined, peer: UserRow | undefined): string => {
  if (!chat) return "Chat"
  if (chat.peerUserId !== undefined) return peer?.bot ? "Bot" : "Direct message"
  if (chat.parentMessageId !== undefined) return "Reply thread"
  if (chat.parentChatId !== undefined) return "Subthread"
  return chat.isPublic ? "Public thread" : "Private thread"
}

const plural = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`

export const createChatInfoModel = (options: ChatInfoModelOptions): ChatInfoModel => {
  const { client, chatId, viewerId, dialog } = options
  const store = client.store
  const clock = options.clock ?? browserClock()
  const ownsParticipants = options.participants === undefined
  const participants = options.participants ?? createParticipantsModel({ client, chatId, viewerId, clock })
  const offline = options.offline ?? signal(false)

  const chat = participants.chat
  const peer = computed(() => {
    const id = chat.get()?.peerUserId
    return id === undefined ? undefined : store.row("user", id).get()
  })
  const isThread = computed(() => chat.get()?.peerUserId === undefined)

  // Keep the peer's user row in the store while the pane is open.
  let peerSub: { id: UserID; unsubscribe(): void } | undefined

  const header = computed<ChatInfoHeader>(
    () => {
      const row = chat.get()
      const user = peer.get()
      const counts = participants.counts.get()
      const source = participants.source.get()
      let countText: string | undefined
      if (row && row.peerUserId === undefined && participants.complete.get()) {
        countText =
          source.kind === "space"
            ? plural(counts.people, "member", "members")
            : counts.groups > 0
              ? `${plural(counts.people, "participant", "participants")}, ${plural(counts.groups, "group", "groups")}`
              : plural(counts.people, "participant", "participants")
      }
      return {
        title: chatTitle(row, user, row?.peerUserId),
        kindLabel: kindLabel(row, user),
        ...(countText ? { countText } : {}),
        avatar: chatAvatar(chatId, row, user, row?.peerUserId),
        chatIdText: chatId,
      }
    },
    { equals: plainEqual },
  )

  const mediaTabs = [
    { id: "media", label: "Media" },
    { id: "files", label: "Files" },
    { id: "voice", label: "Voice" },
    { id: "links", label: "Links" },
  ] as const
  const tabs = computed<readonly { readonly id: ChatInfoPaneTab; readonly label: string }[]>(
    () => [
      ...(isThread.get() ? [{ id: "participants" as const, label: "Participants" }] : []),
      ...mediaTabs,
      { id: "settings" as const, label: "Settings" },
    ],
    { equals: plainEqual },
  )
  const initialTab: ChatInfoPaneTab =
    options.tab && tabs.peek().some((entry) => entry.id === options.tab) ? options.tab : (tabs.peek()[0]?.id ?? "settings")
  const tabsController = new TabsController({
    tabs: () => tabs.get(),
    selected: initialTab,
    label: "Chat info",
    onChange: (id) => options.onTabChange?.(id === "settings" ? undefined : (id as ChatInfoTab)),
  })

  const members = createMemberActions({
    client,
    chatId,
    viewerId,
    participants,
    clock,
    ...(options.intents ? { intents: options.intents } : {}),
    ...(options.onNotice ? { onNotice: options.onNotice } : {}),
  })
  const addPeople = createAddPeople({
    client,
    spaceId: participants.spaceId,
    excluded: members.excluded,
    onAdd: (userIds) => members.add(userIds),
  })
  /** The row a secondary click or Shift+F10 was on. */
  let menuRow: RowKey | undefined
  const participantMenu = new ContextMenuController({
    label: "Participant",
    shouldOpen: (event) => {
      const target = event.target as Element | null
      const row = target?.closest?.("[data-participant]")?.getAttribute("data-participant") as RowKey | undefined
      menuRow = row ?? undefined
      return row !== undefined && members.canRemove(row)
    },
    items: () => (menuRow === undefined ? [] : participantActions(menuRow)),
  })
  /** The Mac's row actions (`ChatInfoParticipantRow`, `ChatInfoGroupAccessRow`): Remove where the viewer may. */
  const participantActions = (row: RowKey): readonly MenuEntry[] => {
    if (!members.canRemove(row)) return []
    const item = participants.member(row).peek()
    return [
      {
        type: "item",
        id: "remove",
        label: item?.kind === "group" ? "Remove Group Access" : "Remove Participant",
        destructive: true,
        onSelect: () => members.requestRemove(row),
      },
    ]
  }

  const mediaModels = new Map<ChatMediaTabId, ChatMediaModel>()
  const mediaModelsMade = signal(0)
  const mediaTab = (tab: ChatMediaTabId): ChatMediaModel => {
    let model = mediaModels.get(tab)
    if (!model) {
      model = untracked(() => createChatMediaModel({ client, chatId, tab }))
      if (!disposed) {
        mediaModels.set(tab, model)
        mediaModelsMade.set(mediaModelsMade.peek() + 1)
      }
    }
    return model
  }
  const mediaGrid = createMediaGrid({
    count: computed(() => {
      mediaModelsMade.get()
      return mediaModels.get("media")?.ids.get().length ?? 0
    }),
    onOpen: (index) => openMediaAt(index),
    onNearEnd: () => void mediaModels.get("media")?.loadMore(),
  })
  const visibility = options.media?.sources.createVisibility?.()
  const mediaVisibility: Part = {
    attach: (element) => {
      if (!visibility) return () => {}
      const view = element.ownerDocument.defaultView
      // The nearest ancestor that scrolls: the observers' root.
      let scroller: Element = element
      for (let node: Element | null = element.parentElement; node; node = node.parentElement) {
        const overflow = view?.getComputedStyle(node).overflowY
        if (overflow === "auto" || overflow === "scroll") {
          scroller = node
          break
        }
      }
      return visibility.attach(scroller)
    },
  }
  const removeDialog = new DialogController({
    role: "alertdialog",
    label: "Remove participant",
    onClose: () => members.cancelRemove(),
  })

  const openMediaAt = (index: number) => {
    const model = mediaModels.get("media")
    const key = model?.ids.peek()[index]
    const item = key ? model?.item(key).peek() : undefined
    if (!item || item.kind !== "media") return
    options.media?.onOpenMedia?.({
      rowId: item.rowId,
      key: item.photo ? `photo:${item.photo.id}` : `video:${item.video?.id ?? ""}`,
      kind: item.video ? "video" : "photo",
      photo: item.video ? undefined : item.photo,
      video: item.video,
    })
  }

  const list = new ListboxController({
    items: () => members.ids.get().map((key) => ({ id: key, label: participants.member(key).get()?.name ?? "" })),
    selectionMode: "none",
    clickRunsAction: true,
    label: "Participants",
    onAction: (key) => openParticipant(key),
  })

  const settings = computed<ChatSettings>(
    () => {
      const row = dialog.get()
      return {
        available: row !== undefined,
        isThread: isThread.get(),
        notifications: row?.notificationMode ?? "default",
        following: row?.followMode === "following",
        pinned: row?.pinned ?? false,
        archived: row?.archived ?? false,
        unread: row !== undefined && (row.unreadMark || row.unreadCount > 0),
      }
    },
    { equals: plainEqual },
  )

  // --- Controls and their outcomes
  const idle: ControlState = { kind: "idle" }
  const states = new Map<ControlId, ReturnType<typeof signal<ControlState>>>()
  const generations = new Map<ControlId, number>()
  const stateOf = (id: ControlId) => {
    let state = states.get(id)
    if (!state) {
      state = signal<ControlState>(idle, { equals: plainEqual })
      states.set(id, state)
    }
    return state
  }
  let disposed = false

  const run = (id: ControlId, what: string, intent: Intent, predicted: Partial<DialogRow> | ((row: DialogRow) => DialogRow)) => {
    const row = dialog.peek()
    const optimistic = row ? [{ row: typeof predicted === "function" ? predicted(row) : { ...row, ...predicted } }] : []
    const generation = (generations.get(id) ?? 0) + 1
    generations.set(id, generation)
    const state = stateOf(id)
    const current = () => !disposed && generations.get(id) === generation
    state.set({ kind: "pending" })
    const handle = actionHandle(client.intent(intent, optimistic), what, {
      store,
      ...(options.intents ? { tracker: options.intents } : {}),
    })
    void handle.then((first) => {
      if (!current()) return
      if (first.status === "rejected") state.set({ kind: "failed", notice: first.notice })
      else if (first.status === "uncertain") state.set({ kind: "uncertain", notice: first.notice })
      else if (offline.peek()) state.set({ kind: "waiting", text: WAITING_TEXT })
    })
    void handle.outcome.then((outcome) => {
      if (!current()) return
      if (outcome.status === "confirmed") state.set(idle)
      else if (outcome.status === "rejected") state.set({ kind: "failed", notice: outcome.notice })
      else state.set({ kind: "uncertain", notice: outcome.notice })
    })
  }

  const setNotifications = (choice: NotificationChoice) => {
    if (!dialog.peek() || settings.peek().notifications === choice) return
    run("notifications", "change notifications", { kind: "setDialogNotifications", chatId, mode: choice }, (row) => {
      const { notificationMode: _, ...rest } = row
      return choice === "default" ? rest : { ...rest, notificationMode: choice }
    })
  }
  const setFollowing = (following: boolean) => {
    if (!dialog.peek() || settings.peek().following === following) return
    const mode = following ? "following" : "unfollowed"
    run("follow", following ? "follow the thread" : "unfollow the thread", { kind: "setDialogFollow", chatId, mode }, { followMode: mode })
  }
  const setPinned = (pinned: boolean) => {
    if (!dialog.peek() || settings.peek().pinned === pinned) return
    run("pin", pinned ? "pin the chat" : "unpin the chat", { kind: "setDialogPinned", chatId, pinned }, { pinned })
  }
  const setArchived = (archived: boolean) => {
    if (!dialog.peek() || settings.peek().archived === archived) return
    run("archive", archived ? "archive the chat" : "unarchive the chat", { kind: "setDialogArchived", chatId, archived }, { archived })
  }
  const markUnread = () => {
    if (!dialog.peek() || settings.peek().unread) return
    run("unread", "mark the chat as unread", { kind: "markUnread", chatId }, { unreadMark: true })
  }

  // Switches mirror the dialog row; a user toggle runs the intent.
  let syncing = false
  const toggle = (apply: (on: boolean) => void) =>
    new ToggleController({
      kind: "switch",
      onChange: (on) => {
        if (!syncing) apply(on)
      },
    })
  const followSwitch = toggle(setFollowing)
  const pinSwitch = toggle(setPinned)
  const archiveSwitch = toggle(setArchived)

  const copyState = signal<CopyState>("idle")
  let copyTimer: unknown

  const openParticipant = (key: string) => {
    const item = participants.member(key as never).peek()
    if (item?.kind === "user") options.onOpenProfile(item.userId)
  }

  const stopScope = scope(() => {
    effect(() => {
      const value = settings.get()
      untracked(() => {
        syncing = true
        try {
          followSwitch.setPressed(value.following)
          pinSwitch.setPressed(value.pinned)
          archiveSwitch.setPressed(value.archived)
          for (const control of [followSwitch, pinSwitch, archiveSwitch]) control.setDisabled(!value.available)
        } finally {
          syncing = false
        }
      })
    })
    // A tab that disappears (a chat that turned out to be a direct message) gives way to the first one.
    effect(() => {
      const available = tabs.get()
      const selected = tabsController.selectedId.get()
      if (!available.some((tab) => tab.id === selected)) {
        const first = available[0]
        if (first) untracked(() => tabsController.select(first.id))
      }
    })
    effect(() => {
      const asked = members.question.get() !== null
      untracked(() => {
        if (asked) removeDialog.open()
        else if (removeDialog.isOpen.peek()) removeDialog.close()
      })
    })
    effect(() => {
      const id = chat.get()?.peerUserId
      untracked(() => {
        if (peerSub?.id === id) return
        peerSub?.unsubscribe()
        peerSub = id === undefined ? undefined : { id, unsubscribe: client.subscribe({ kind: "user", userId: id }).unsubscribe }
      })
    })
  })

  return {
    chatId,
    participants,
    header,
    tabs,
    tabsController,
    list,
    settings,
    members,
    addPeople,
    participantMenu,
    participantActions,
    mediaTab,
    mediaGrid,
    mediaVisibility,
    removeDialog,
    media: options.media,
    control: (id) => stateOf(id),
    followSwitch,
    pinSwitch,
    archiveSwitch,
    setNotifications,
    setFollowing,
    setPinned,
    setArchived,
    markUnread,
    dismiss: (id) => {
      generations.set(id, (generations.get(id) ?? 0) + 1)
      stateOf(id).set(idle)
    },
    canCopy: options.copyText !== undefined,
    copyState,
    copyChatId: () => {
      const copy = options.copyText
      if (!copy) return
      if (copyTimer !== undefined) clock.clearTimeout(copyTimer)
      const settle = (state: CopyState) => {
        if (disposed) return
        copyState.set(state)
        copyTimer = clock.setTimeout(() => {
          copyTimer = undefined
          copyState.set("idle")
        }, COPIED_MS)
      }
      try {
        Promise.resolve(copy(chatId)).then(
          () => settle("copied"),
          () => settle("failed"),
        )
      } catch {
        settle("failed")
      }
    },
    openParticipant,
    dispose: () => {
      disposed = true
      stopScope()
      peerSub?.unsubscribe()
      if (copyTimer !== undefined) clock.clearTimeout(copyTimer)
      members.dispose()
      addPeople.dispose()
      visibility?.dispose()
      for (const model of mediaModels.values()) model.dispose()
      mediaModels.clear()
      if (ownsParticipants) participants.dispose()
    },
  }
}

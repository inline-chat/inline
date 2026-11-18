/**
 * Shows a notification for each new incoming message, by feature-map rule 12
 * (Mac `MacNotifications`).
 *
 * - Source: the core's `newMessages` query, subscribed for the controller's
 *   life. The core lists only messages that arrived live or by a catch-up
 *   page, first inserted, incoming, not silent, unread and at most 120 s old
 *   (`NEW_MESSAGES_RULE`), each with its chat, dialog and sender rows, so a
 *   chat that is not open anywhere notifies too. The list is append-only and
 *   bounded; entries are handled once, by key and by tag, so a list replayed
 *   after a resync does not notify twice.
 * - Decision: `messageNotificationFacts` (view) into `decideMessageNotification`
 *   (platform), with the dialog's `notificationMode`, the row's `mentioned` and
 *   `silent`, and the policy's own freshness limit as a second guard. Only the
 *   leader context shows, so two tabs never show the same message; every
 *   context still marks entries as handled so a new leader starts current.
 * - Presentation: tag `messageNotificationTag(chatId, messageId)`, group
 *   `chatNotificationGroup(chatId)` (the Mac identifiers), title and body from
 *   `notificationContent`.
 * - Click: the platform focuses the window; this opens the chat at the message.
 * - Read: when the chat's read frontier reaches a shown message, its
 *   notification closes (Mac `NotificationSyncOps`: `messageId <= readUpTo`).
 *   An entry leaving the feed does not close anything.
 * - Edit: the Mac schedules only for new messages and never touches a shown
 *   notification on edit; an edit changes a row, not the feed, so nothing here.
 */

import {
  rowKey,
  receivedMessageRowId,
  type ChatRow,
  type DialogRow,
  type MessageRow,
  type RowKey,
  type SpaceRow,
  type UserRow,
} from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import {
  chatNotificationGroup,
  decideMessageNotification,
  messageNotificationTag,
  type Capability,
  type ChatNotificationMode,
  type GlobalNotificationMode,
  type NotificationData,
  type NotificationDecision,
  type Notifications,
} from "@inline/platform"
import { effect, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import type { PaneState, Workspace } from "@inline/view"
import { chatTitle, compareMessageIds, messageNotificationFacts, type AccountSession } from "@inline/view/features"
import { isCallTranscript, isNudge, isUrgentNudge, notificationContent } from "./content"
import { createViewingTracker, type ViewingChannel, type ViewingTracker } from "./viewing"

/** Link roles (`LinkRole` from `@inline/link`; `AppRuntime.role` in `web/src/app`). */
export type CoreRole = "connecting" | "leader" | "follower" | "handoff" | "superseded" | "closed"

/**
 * What the controller reads from the session. `AccountSession` fits.
 * `dialogFor` is the session's chat-to-dialog lookup (`ChatRow.dialogId`),
 * the same as `dialogRowOf` below.
 */
export type NotificationSession = Pick<AccountSession, "userId" | "client" | "chats" | "dialogFor"> & {
  readonly workspace: Pick<Workspace, "open"> & { readonly panes: ReadSignal<readonly PaneState[]> }
}

/**
 * Overrides for the notification settings. The chat's mode comes from its
 * dialog row (`notificationMode`, absent: follow the account). TODO(contract):
 * the account mode and the sound setting are not on the protocol; until they
 * are, the Mac defaults apply (mode `all`, sound on).
 */
export type NotificationSettings = {
  readonly globalMode?: () => GlobalNotificationMode
  /** Overrides the dialog's `notificationMode`. */
  readonly chatMode?: (chatId: ChatID) => ChatNotificationMode
  readonly soundEnabled?: () => boolean
}

/** What a sound player (Phase 3) gets for each notification shown with sound. */
export type NotificationSoundEvent = {
  readonly chatId: ChatID
  readonly messageId: MessageID
  readonly urgent: boolean
}

export type NotificationControllerOptions = {
  readonly session: NotificationSession
  readonly notifications: Capability<Notifications>
  readonly lifecycle: { readonly visible: ReadSignal<boolean>; readonly focused: ReadSignal<boolean> }
  /**
   * This context's link role. Only `leader` shows; `undefined` (a connector
   * without an election, such as an in-process core) counts as the only
   * context. Omitted: this context is the only one.
   */
  readonly role?: ReadSignal<CoreRole | undefined>
  /** Wall clock, milliseconds since the epoch (`systemClock()` from `@inline/platform`). */
  readonly clock: { now(): number }
  /** Shares which chats each context is viewing (a `BroadcastChannel` per account). */
  readonly channel?: ViewingChannel
  readonly contextId?: string
  readonly settings?: NotificationSettings
  /** Hook for notification sounds (Phase 3). Called after a notification with sound is shown. */
  readonly onSound?: (event: NotificationSoundEvent) => void
}

export type NotificationController = {
  /** Tags this controller showed that are still open as far as it knows. */
  openTags(): string[]
  /** The rule 12 decision for one message, as the controller would make it now. For diagnostics. */
  decide(message: MessageRow): NotificationDecision
  readonly viewing: ViewingTracker
  dispose: Dispose
}

/** What a message notification carries; plain strings so it can cross the preload bridge. */
export type MessageNotificationData = {
  readonly kind: "message"
  readonly chatId: string
  readonly messageId: string
  /** The recipient, as the Mac's `recipientUserId`: a click never acts for another account. */
  readonly userId: string
}

const isMessageData = (data: NotificationData): data is MessageNotificationData =>
  data.kind === "message" &&
  typeof data.chatId === "string" &&
  typeof data.messageId === "string" &&
  typeof data.userId === "string"

/** Tags remembered as handled; far above the feed's 50 entries. */
const CONSIDERED_LIMIT = 1000

const higher = (a: MessageID | undefined, b: MessageID | undefined): MessageID | undefined => {
  if (a === undefined) return b
  if (b === undefined) return a
  return compareMessageIds(a, b) >= 0 ? a : b
}

const randomContextId = () => Math.random().toString(36).slice(2, 12)

type OpenNotification = { readonly chatId: ChatID; readonly messageId: MessageID }

export const createNotificationController = (options: NotificationControllerOptions): NotificationController => {
  const { session, clock, settings } = options
  const store = session.client.store
  const me: UserID = session.userId
  const considered = new Set<string>()
  const open = new Map<string, OpenNotification>()
  const openChats = signal<readonly ChatID[]>([])
  const disposers: Dispose[] = []

  const feed = session.client.subscribe({ kind: "newMessages" })
  disposers.push(() => feed.unsubscribe())

  const viewing = createViewingTracker({
    panes: session.workspace.panes,
    visible: options.lifecycle.visible,
    focused: options.lifecycle.focused,
    contextId: options.contextId ?? randomContextId(),
    ...(options.channel ? { channel: options.channel } : {}),
  })

  const isLeader = () => {
    if (!options.role) return true
    const role = options.role.peek()
    return role === undefined || role === "leader"
  }

  const peek = <R>(kind: "user" | "chat" | "space" | "message", id: string) =>
    store.peekRow(rowKey(kind, id)) as R | undefined

  /**
   * The chat's dialog row: `rowKey("dialog", chat.dialogId)` from the chat
   * row (the feed and the sidebar ship it with each dialog). A chat row
   * without `dialogId` has none (`session.dialogFor` reads the same field).
   * Tracked when called tracked.
   */
  const dialogRowOf = (chatId: ChatID): DialogRow | undefined => {
    const dialogId = store.row("chat", chatId).get()?.dialogId
    if (dialogId === undefined) return session.dialogFor(chatId).get()
    return store.rowByKey(rowKey("dialog", dialogId)).get() as DialogRow | undefined
  }

  const dialogOf = (chatId: ChatID): DialogRow | undefined => untracked(() => dialogRowOf(chatId))

  /** The highest read frontier known for a chat. Tracked when called tracked. */
  const readMaxOf = (chatId: ChatID): MessageID | undefined => {
    const fromDialog = dialogRowOf(chatId)?.readMaxId
    const fromModel = session.chats.resident.get().includes(chatId)
      ? session.chats.peek(chatId)?.readState.get()?.readMaxId
      : undefined
    return higher(fromDialog, fromModel)
  }

  const publishOpenChats = () => {
    const chats: ChatID[] = []
    for (const entry of open.values()) if (!chats.includes(entry.chatId)) chats.push(entry.chatId)
    openChats.set(chats)
  }

  const forget = (tag: string) => {
    if (open.delete(tag)) publishOpenChats()
  }

  const authorOf = (chatId: ChatID | undefined, messageId: MessageID | undefined): UserID | undefined =>
    chatId && messageId ? peek<MessageRow>("message", receivedMessageRowId(chatId, messageId))?.fromId : undefined

  const decide = (message: MessageRow): NotificationDecision => {
    const chatId = message.chatId
    const chat = peek<ChatRow>("chat", chatId)
    const dialog = dialogOf(chatId)
    const readMax = untracked(() => readMaxOf(chatId))
    // A reply to me, or a message in a reply thread anchored on my message.
    const replyAuthor = authorOf(chatId, message.replyToMessageId)
    const anchorAuthor = authorOf(chat?.parentChatId, chat?.parentMessageId)
    const repliedToAuthor = replyAuthor === me || anchorAuthor === me ? me : (replyAuthor ?? anchorAuthor)
    const chatMode = settings?.chatMode?.(chatId) ?? dialog?.notificationMode ?? "global"
    // `messageNotificationFacts` does not read `mentioned`, `silent` or the
    // dialog's mode yet; they are applied around it here.
    const facts = messageNotificationFacts({
      message,
      me,
      newlyInserted: true,
      chat,
      dialog,
      viewingConversation: viewing.isViewing(chatId),
      nowMs: clock.now(),
      chatMode,
      ...(settings?.globalMode ? { globalMode: settings.globalMode() } : {}),
      ...(settings?.soundEnabled ? { soundEnabled: settings.soundEnabled() } : {}),
      ...(repliedToAuthor !== undefined ? { repliedToAuthor } : {}),
    })
    return decideMessageNotification({
      ...facts,
      mentionsMe: facts.mentionsMe || message.mentioned === true,
      silentSend: message.silent === true,
      // Unread when it arrived (the core checked); still unread now?
      unread: message.messageId === undefined || readMax === undefined || compareMessageIds(message.messageId, readMax) > 0,
      // TODO(contract): `countsAsUnread` is not on `MessageRow`; it defaults to counting.
      nudge: isNudge(message),
      urgentNudge: isUrgentNudge(message),
      callTranscript: isCallTranscript(message),
    })
  }

  const remember = (tag: string) => {
    considered.add(tag)
    if (considered.size > CONSIDERED_LIMIT) {
      const oldest = considered.values().next().value
      if (oldest !== undefined) considered.delete(oldest)
    }
  }

  const consider = (message: MessageRow) => {
    const messageId = message.messageId
    if (messageId === undefined) return
    const chatId = message.chatId
    const tag = messageNotificationTag(chatId, messageId)
    if (considered.has(tag)) return
    remember(tag)
    const notifications = options.notifications
    if (!notifications.available || !isLeader()) return
    const decision = decide(message)
    if (!decision.notify) return

    const chat = peek<ChatRow>("chat", chatId)
    const dialog = dialogOf(chatId)
    const content = notificationContent({
      message,
      sender: peek<UserRow>("user", message.fromId),
      chat,
      space: chat?.spaceId ? peek<SpaceRow>("space", chat.spaceId) : undefined,
      isDirect: (dialog?.peerUserId ?? chat?.peerUserId) !== undefined,
      chatTitle: chatTitle(chat, undefined),
    })
    const data: MessageNotificationData = { kind: "message", chatId, messageId, userId: me }
    const shown = notifications.show({
      tag,
      title: content.title,
      body: content.body,
      group: chatNotificationGroup(chatId),
      silent: decision.silent,
      urgent: decision.urgent,
      data,
    })
    if (!shown) return
    open.set(tag, { chatId, messageId })
    publishOpenChats()
    if (!decision.silent) options.onSound?.({ chatId, messageId, urgent: decision.urgent })
  }

  // The feed: each key once. A key whose row has not arrived yet is retried on the next change.
  let handled = new Set<RowKey>()
  disposers.push(
    effect(() => {
      const keys = feed.list.get()
      untracked(() => {
        const next = new Set<RowKey>()
        for (const key of keys) {
          if (handled.has(key)) {
            next.add(key)
            continue
          }
          const row = store.peekRow(key)
          if (row?.kind !== "message") continue
          next.add(key)
          consider(row)
        }
        handled = next
      })
    }),
  )

  // Close notifications the user has read (here or on another device).
  disposers.push(
    effect(() => {
      for (const chatId of openChats.get()) {
        const readMax = readMaxOf(chatId)
        if (readMax === undefined) continue
        untracked(() => {
          for (const [tag, entry] of Array.from(open)) {
            if (entry.chatId !== chatId || compareMessageIds(entry.messageId, readMax) > 0) continue
            if (options.notifications.available) options.notifications.close(tag)
            forget(tag)
          }
        })
      }
    }),
  )

  if (options.notifications.available) {
    disposers.push(
      options.notifications.onClick(({ tag, data }) => {
        if (!isMessageData(data) || data.userId !== me) return
        forget(tag)
        session.workspace.open({ kind: "message", chatId: data.chatId as ChatID, messageId: data.messageId as MessageID })
      }),
    )
  }

  let disposed = false
  return {
    openTags: () => [...open.keys()],
    decide,
    viewing,
    dispose() {
      if (disposed) return
      disposed = true
      for (const dispose of disposers.splice(0).reverse()) dispose()
      viewing.dispose()
      // Signing out: nothing of this account stays on screen.
      if (options.notifications.available) for (const tag of open.keys()) options.notifications.close(tag)
      open.clear()
    },
  }
}

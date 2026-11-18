/**
 * Whether a new message notifies: feature-map rule 12, ported from the Mac
 * client so both apps agree.
 *
 * Sources: `MacNotifications.shouldScheduleMessageNotification` and
 * `isFreshMessage`, `MessageNotificationPresentation.foregroundOptions`
 * (`apple/InlineKit/Sources/InlineKit/MacNotifications/MacNotifications.swift`,
 * `.../Notifications/MessageNotificationTarget.swift`), the mode resolution in
 * `DialogNotificationPreference.swift` and `NotificationSettingsCompat.swift`.
 *
 * Pure: no clock, no DOM. The caller gathers the facts.
 */

/** The account-wide mode (`NotificationMode` on the Mac). */
export type GlobalNotificationMode =
  | "all"
  | "mentions"
  /** Legacy name for `mentions`. */
  | "importantOnly"
  /** Mentions only: DMs and replies do not count. */
  | "onlyMentions"
  | "none"

/** A chat's own setting; `global` follows the account mode. */
export type ChatNotificationMode = "global" | "all" | "mentions" | "none"

export type EffectiveNotificationMode = "all" | "mentions" | "onlyMentions" | "none"

/** Maximum age of a message that may still notify (Mac `maximumMessageAge`). */
export const MAX_NOTIFICATION_AGE_MS = 2 * 60 * 1000

export interface MessageNotificationFacts {
  /** Sent by the current user. */
  readonly outgoing: boolean
  /** First insertion of this message in the store; false for edits and re-delivery. */
  readonly newlyInserted: boolean
  /** Above the dialog's read and collapsed frontiers after the update committed. */
  readonly unread: boolean
  /** The server's `countsAsUnread`; absent means true. */
  readonly countsAsUnread?: boolean
  /** The sender chose silent send. */
  readonly silentSend?: boolean
  /** A call transcript service message, which never notifies. */
  readonly callTranscript?: boolean
  /** Message date in seconds since the epoch, as on `MessageRow.date`. */
  readonly dateSeconds: number
  /** Now, in milliseconds since the epoch. */
  readonly nowMs: number
  /** The user is looking at this conversation (see `isViewingConversation`). */
  readonly viewingConversation: boolean
  readonly chatMode: ChatNotificationMode
  readonly globalMode: GlobalNotificationMode
  readonly directMessage: boolean
  /** The message mentions the current user. */
  readonly mentionsMe: boolean
  /**
   * Replies to the current user's message, or is in a reply thread anchored on
   * one. Counts in `mentions` mode, not in `onlyMentions`.
   */
  readonly repliesToMe?: boolean
  readonly nudge?: boolean
  /** A nudge whose text is exactly the siren emoji. Bypasses mode and viewing. */
  readonly urgentNudge?: boolean
  /** The user's sound setting; urgent nudges always sound. Defaults to true. */
  readonly soundEnabled?: boolean
}

export type NotificationSkipReason =
  | "outgoing"
  | "not-new"
  | "read"
  | "does-not-count-as-unread"
  | "call-transcript"
  | "silent-send"
  | "stale"
  | "viewing"
  | "mode"

export type NotificationDecision =
  | { readonly notify: true; readonly urgent: boolean; readonly silent: boolean }
  | { readonly notify: false; readonly reason: NotificationSkipReason }

const skip = (reason: NotificationSkipReason): NotificationDecision => ({ notify: false, reason })

/** `NotificationSettingsCompat` + `resolveEffectiveMode`. */
export const resolveNotificationMode = (
  chatMode: ChatNotificationMode,
  globalMode: GlobalNotificationMode,
): EffectiveNotificationMode => {
  if (chatMode !== "global") return chatMode
  return globalMode === "importantOnly" ? "mentions" : globalMode
}

/** Mac `isFreshMessage`: a positive date at most two minutes old. A future date counts as fresh. */
export const isFreshMessage = (dateSeconds: number, nowMs: number): boolean =>
  Number.isFinite(dateSeconds) && dateSeconds > 0 && nowMs - dateSeconds * 1000 <= MAX_NOTIFICATION_AGE_MS

export const decideMessageNotification = (facts: MessageNotificationFacts): NotificationDecision => {
  if (facts.outgoing) return skip("outgoing")
  if (!facts.newlyInserted) return skip("not-new")
  if (!facts.unread) return skip("read")
  if (facts.countsAsUnread === false) return skip("does-not-count-as-unread")
  if (facts.callTranscript) return skip("call-transcript")
  if (facts.silentSend) return skip("silent-send")
  if (!isFreshMessage(facts.dateSeconds, facts.nowMs)) return skip("stale")

  if (facts.urgentNudge) return { notify: true, urgent: true, silent: false }

  if (facts.viewingConversation) return skip("viewing")

  const nudge = facts.nudge === true
  const addressed = facts.mentionsMe || facts.repliesToMe === true
  const mode = resolveNotificationMode(facts.chatMode, facts.globalMode)
  let passes: boolean
  switch (mode) {
    case "all":
      passes = true
      break
    case "none":
      passes = false
      break
    case "mentions":
      passes = facts.directMessage || addressed || nudge
      break
    case "onlyMentions":
      passes = facts.mentionsMe || nudge
      break
  }
  if (!passes) return skip("mode")
  return { notify: true, urgent: false, silent: facts.soundEnabled === false }
}

/**
 * Mac `isViewingChat`: the app is active, the window is focused, and it shows
 * this conversation. On the web: the tab is visible and focused and its route
 * is this chat.
 */
export const isViewingConversation = (input: {
  readonly visible: boolean
  readonly focused: boolean
  readonly openChatId: string | null
  readonly chatId: string
}): boolean => input.visible && input.focused && input.openChatId === input.chatId

/** Stable per-message tag, the same string the Mac client uses as request identifier. */
export const messageNotificationTag = (chatId: string, messageId: string): string =>
  `chat_${chatId}_message_${messageId}`

/** Per-conversation group key, as the Mac thread identifier. */
export const chatNotificationGroup = (chatId: string): string => `chat_${chatId}`

/**
 * Pure rules and strings for the composer view: the send key hint, error
 * wording, and the two keyboard decisions that sit outside the editor
 * (type anywhere to focus, Escape in an empty composer). Framework-free and
 * DOM-free, so each rule is tested in Node.
 */

import type { Platform, SendKey } from "@inline/composer"
import type { IntentRejection } from "@inline/core-protocol"

/** The hint shown in an empty composer: which keys send. Mirrors `keys.ts` in the composer package. */
export const sendHint = (sendKey: SendKey, platform: Platform): string => {
  if (platform === "mac") return sendKey === "enter" ? "↩ to send, ⇧↩ for a new line" : "⌘↩ to send"
  return sendKey === "enter" ? "Enter to send, Shift+Enter for a new line" : "Ctrl+Enter to send"
}

/** The shortcut for `aria-keyshortcuts` on the send button. */
export const sendShortcut = (sendKey: SendKey, platform: Platform): string =>
  sendKey === "enter" ? "Enter" : platform === "mac" ? "Meta+Enter" : "Control+Enter"

/**
 * Words for a rejected send. The reason is the caller's `SendOutcome.reason`,
 * normally the core's `IntentRejection` passed through; `failed` is what the
 * controller reports when `send` threw, so the outcome is unknown. The text
 * always says the message is still there, because the composer keeps it.
 */
export const sendErrorText = (reason: IntentRejection | "failed" | "uncertain" | (string & {})): string => {
  switch (reason) {
    case "storageFull":
    case "storage-full":
      return "Not enough storage on this device to send. Free up space, then try again. Your message is still here."
    case "unavailable":
      return "Inline isn't ready to send yet. Your message is still here; try again in a moment."
    case "notSignedIn":
      return "You're signed out. Sign in again to send; your message is still here."
    case "invalid":
    case "unsupported":
      return "This message can't be sent as it is. It is still here to change."
    case "failed":
    case "uncertain":
      return "Couldn't confirm the message was saved for sending. It is still here; try again."
    default:
      return "Couldn't send. Your message is still here; try again."
  }
}

export type KeyFacts = {
  key: string
  ctrlKey: boolean
  metaKey: boolean
  altKey: boolean
  isComposing?: boolean
  defaultPrevented?: boolean
}

/** A key that types one character (letters in any script, digits, punctuation, space excluded). */
export const isTypingKey = (key: string): boolean => {
  if (key === " " || key.length === 0) return false
  // One grapheme-ish: a single code point, or a short sequence the platform sends as one key.
  const points = [...key]
  return points.length === 1 && !/\p{C}/u.test(key)
}

/**
 * Type anywhere to focus: a plain character key pressed while focus is not in
 * an editable field moves focus to the composer before the browser handles
 * the key, so the character lands there. Modifier shortcuts, navigation keys,
 * Space (which scrolls the timeline) and keys during a composition never do.
 */
export const shouldFocusForKey = (event: KeyFacts, context: { targetIsEditable: boolean; composerFocused: boolean }): boolean => {
  if (context.targetIsEditable || context.composerFocused) return false
  if (event.defaultPrevented || event.isComposing) return false
  // AltGr arrives as Ctrl+Alt on Windows and types characters (@ on German layouts).
  const altGr = event.ctrlKey && event.altKey && !event.metaKey
  if (!altGr && (event.ctrlKey || event.metaKey)) return false
  // Option on a Mac types a different character (é, ü, –). Alt that still reports a
  // plain letter or digit is a menu or app shortcut elsewhere.
  if (event.altKey && !altGr && /^[a-z0-9]$/i.test(event.key)) return false
  return isTypingKey(event.key)
}

/**
 * Escape in an empty composer hands focus back to the message list. Only when
 * nothing else took the key first (the binding takes it to dismiss an
 * autocomplete, cancel an edit, or clear a reply) and no modifier is held.
 */
export const escapeLeavesComposer = (event: KeyFacts & { shiftKey: boolean }, context: { empty: boolean }): boolean =>
  event.key === "Escape" &&
  context.empty &&
  !event.defaultPrevented &&
  !event.isComposing &&
  !event.ctrlKey &&
  !event.metaKey &&
  !event.altKey &&
  !event.shiftKey

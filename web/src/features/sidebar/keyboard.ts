/**
 * Keys and modifiers of the sidebar list, as pure functions of the event's
 * fields so they are tested without a DOM.
 */

import type { OpenIntent, OS } from "@inline/view"

export type Modifiers = {
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly altKey?: boolean
  readonly shiftKey?: boolean
}

export type KeyInput = Modifiers & { readonly key: string; readonly isComposing?: boolean }

/** The platform's command modifier: Cmd on Mac, Ctrl elsewhere. */
export const hasCommand = (event: Modifiers, os: OS): boolean => (os === "mac" ? !!event.metaKey : !!event.ctrlKey)

/**
 * How a click or Enter with modifiers opens a chat. The default map:
 *
 * | Modifiers | Intent | Why |
 * | --- | --- | --- |
 * | none | `here` | |
 * | command | `newTab` | Cmd-click opens a new tab on the Mac (rule 13) and in browsers |
 * | Option / Alt | `otherPane` | Option-click opens the side pane on the Mac (rule 13) |
 * | command + Option / Alt | `newPane` | |
 *
 * Shift is left alone: it is range selection once multi-select lands.
 * A caller can replace the map (`SidebarView`'s `openIntent` prop).
 */
export const openIntentFor = (event: Modifiers, os: OS): OpenIntent => {
  const command = hasCommand(event, os)
  if (command && event.altKey) return "newPane"
  if (command) return "newTab"
  if (event.altKey) return "otherPane"
  return "here"
}

export type OpenIntentMap = (event: Modifiers, os: OS) => OpenIntent

/** The intent of a pointer activation: the middle button opens a new tab, as for links. */
export const pointerOpenIntent = (
  event: Modifiers & { readonly button: number },
  os: OS,
  map: OpenIntentMap = openIntentFor,
): OpenIntent | undefined => {
  if (event.button === 1) return "newTab"
  if (event.button !== 0) return undefined
  return map(event, os)
}

export type MoveTarget = "previous" | "next" | "first" | "last" | "pageUp" | "pageDown"

export type ListKeyAction =
  | { readonly kind: "move"; readonly to: MoveTarget }
  | { readonly kind: "open"; readonly intent: OpenIntent }
  | { readonly kind: "type"; readonly char: string }

const moves: Record<string, MoveTarget> = {
  ArrowUp: "previous",
  ArrowDown: "next",
  Home: "first",
  End: "last",
  PageUp: "pageUp",
  PageDown: "pageDown",
}

/** One user-perceived character (a letter, a digit, an emoji), not a named key like "Tab". */
const isCharacter = (key: string): boolean => {
  if (key.length === 0) return false
  if (key.length === 1) return true
  // Named keys are ASCII words ("Enter", "ArrowUp"); a character key with
  // more than one code unit is a surrogate pair or a cluster.
  return !/^[A-Za-z][A-Za-z0-9]+$/.test(key) && [...key].length <= 2
}

/**
 * The list action for a key, or undefined to leave the key alone (so global
 * shortcuts such as Alt+Up for the previous chat and Cmd+K still work).
 */
export const listKeyAction = (
  event: KeyInput,
  context: { readonly os: OS; readonly typeaheadActive: boolean; readonly openIntent?: OpenIntentMap },
): ListKeyAction | undefined => {
  if (event.isComposing) return undefined
  const plain = !event.metaKey && !event.ctrlKey && !event.altKey
  const move = moves[event.key]
  if (move) return plain && !event.shiftKey ? { kind: "move", to: move } : undefined
  const map = context.openIntent ?? openIntentFor
  if (event.key === "Enter") return event.shiftKey ? undefined : { kind: "open", intent: map(event, context.os) }
  if (event.key === " ") {
    if (context.typeaheadActive && plain) return { kind: "type", char: " " }
    return event.shiftKey ? undefined : { kind: "open", intent: map(event, context.os) }
  }
  if (plain && isCharacter(event.key)) return { kind: "type", char: event.key }
  return undefined
}

/** The index a move lands on, clamped to the list (no wrapping, as on the Mac). */
export const moveIndex = (to: MoveTarget, current: number, count: number, pageSize: number): number => {
  if (count <= 0) return -1
  const page = Math.max(1, pageSize)
  const last = count - 1
  switch (to) {
    case "first":
      return 0
    case "last":
      return last
    case "previous":
      return current < 0 ? last : Math.max(0, current - 1)
    case "next":
      return current < 0 ? 0 : Math.min(last, current + 1)
    case "pageUp":
      return current < 0 ? 0 : Math.max(0, current - page)
    case "pageDown":
      return current < 0 ? 0 : Math.min(last, current + page)
  }
}

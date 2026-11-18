import type { MarkType } from "./model"

/**
 * Keyboard routing as a pure function of the key and the composer's state,
 * so every rule is testable in Node. The DOM binding turns a `KeyboardEvent`
 * into a `KeyInput`, asks the controller, and prevents the default only when
 * a command was chosen and handled.
 */

export type Platform = "mac" | "other"

/** Which key sends. Shift+Enter is always a new line; Mod+Enter always sends. */
export type SendKey = "enter" | "modEnter"

export type KeyInput = {
  key: string
  shiftKey: boolean
  altKey: boolean
  ctrlKey: boolean
  metaKey: boolean
  /** `KeyboardEvent.isComposing`; also true for keyCode 229 in the binding. */
  isComposing?: boolean
}

export type AutocompleteKey = "previous" | "next" | "accept" | "dismiss"

export type KeyCommand =
  | { kind: "send" }
  | { kind: "newline" }
  | { kind: "editLast" }
  | { kind: "undo" }
  | { kind: "redo" }
  | { kind: "toggleMark"; mark: MarkType }
  | { kind: "link" }
  | { kind: "escape" }
  | { kind: "autocomplete"; key: AutocompleteKey }

export type KeyContext = {
  platform: Platform
  sendKey: SendKey
  /** An autocomplete trigger is active. */
  autocomplete: boolean
  /** The document has no text at all. */
  empty: boolean
}

/** Format shortcuts, after the Mac client's Format menu. Strikethrough has no Mac shortcut; Mod+Shift+X follows Slack and Notion. */
const formatKeys: Readonly<Record<string, { shift: boolean; mark: MarkType }>> = {
  b: { shift: false, mark: "bold" },
  i: { shift: false, mark: "italic" },
  u: { shift: false, mark: "underline" },
  c: { shift: true, mark: "code" },
  x: { shift: true, mark: "strikethrough" },
}

export const keyCommand = (input: KeyInput, context: KeyContext): KeyCommand | null => {
  // Never interfere with a composition in progress.
  if (input.isComposing) return null
  const mod = context.platform === "mac" ? input.metaKey : input.ctrlKey
  const otherMod = context.platform === "mac" ? input.ctrlKey : input.metaKey
  const key = input.key.length === 1 ? input.key.toLowerCase() : input.key
  const plain = !mod && !otherMod && !input.altKey && !input.shiftKey

  if (context.autocomplete && !mod && !otherMod && !input.altKey) {
    if (key === "ArrowUp" && !input.shiftKey) return { kind: "autocomplete", key: "previous" }
    if (key === "ArrowDown" && !input.shiftKey) return { kind: "autocomplete", key: "next" }
    if ((key === "Enter" || key === "Tab") && !input.shiftKey) return { kind: "autocomplete", key: "accept" }
    if (key === "Escape") return { kind: "autocomplete", key: "dismiss" }
  }

  if (key === "Enter") {
    if (otherMod) return null
    if (mod) return { kind: "send" }
    if (input.shiftKey || input.altKey) return { kind: "newline" }
    return context.sendKey === "enter" ? { kind: "send" } : { kind: "newline" }
  }

  if (key === "ArrowUp" && plain && context.empty) return { kind: "editLast" }
  if (key === "Escape" && plain) return { kind: "escape" }

  if (mod && !otherMod && !input.altKey) {
    if (key === "z") return input.shiftKey ? { kind: "redo" } : { kind: "undo" }
    if (key === "y" && !input.shiftKey && context.platform === "other") return { kind: "redo" }
    if (key === "k" && !input.shiftKey) return { kind: "link" }
    const format = formatKeys[key]
    if (format && format.shift === input.shiftKey) return { kind: "toggleMark", mark: format.mark }
  }
  return null
}

/** Mod+Shift+V: the next paste should match style (plain text only). */
export const isPastePlainKey = (input: KeyInput, platform: Platform): boolean => {
  const mod = platform === "mac" ? input.metaKey : input.ctrlKey
  return mod && input.shiftKey && input.key.toLowerCase() === "v"
}

export const detectPlatform = (): Platform => {
  const nav = (globalThis as { navigator?: { platform?: string; userAgentData?: { platform?: string } } }).navigator
  const name = nav?.userAgentData?.platform ?? nav?.platform ?? ""
  return /mac|iphone|ipad|ipod/i.test(name) ? "mac" : "other"
}

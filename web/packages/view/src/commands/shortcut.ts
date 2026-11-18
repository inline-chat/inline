/**
 * Shortcut parsing, matching and display.
 *
 * Shortcuts are written as text: `Mod+K`, `Alt+ArrowUp`, `Ctrl+Shift+C`.
 * `Mod` is Cmd on Mac and Ctrl elsewhere; `Ctrl` is always the Control key,
 * so `Ctrl+K` on Mac is Control-K as in the Mac app.
 *
 * Keys are matched layout-aware where that is safe: a letter is matched by
 * the character it types (so Dvorak users press the key labelled K), falling
 * back to the physical key when a modifier turns the character into
 * something else (Option on Mac) or the layout is not Latin. Digits and
 * punctuation are matched by physical key, so `Shift+1` is not `!`.
 */

import type { OS } from "./platform"

/** A shortcut as written, before `Mod` is resolved for a platform. */
export type ParsedShortcut = {
  readonly key: string
  readonly mod: boolean
  readonly ctrl: boolean
  readonly meta: boolean
  readonly alt: boolean
  readonly shift: boolean
}

/** A concrete key combination on one OS. */
export type KeyCombo = {
  readonly key: string
  readonly ctrl: boolean
  readonly meta: boolean
  readonly alt: boolean
  readonly shift: boolean
}

export class ShortcutParseError extends Error {
  constructor(text: string, reason: string) {
    super(`Invalid shortcut "${text}": ${reason}`)
    this.name = "ShortcutParseError"
  }
}

const namedKeys = new Set([
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Escape",
  "Enter",
  "Tab",
  "Space",
  "Backspace",
  "Delete",
  "Insert",
  "Home",
  "End",
  "PageUp",
  "PageDown",
])

const keyAliases: Record<string, string> = {
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
  esc: "Escape",
  return: "Enter",
  del: "Delete",
  comma: ",",
  period: ".",
  slash: "/",
  backslash: "\\",
  bracketleft: "[",
  bracketright: "]",
  semicolon: ";",
  quote: "'",
  backquote: "`",
  minus: "-",
  equal: "=",
}

const punctuation = new Set([",", ".", "/", "\\", "[", "]", ";", "'", "`", "-", "="])

const namedByLower = new Map([...namedKeys].map((name) => [name.toLowerCase(), name]))

const isFunctionKey = (key: string): boolean => /^F([1-9]|1\d|2[0-4])$/.test(key)

/** The canonical name of a key in a shortcut, or `undefined` if it is not one. */
const canonicalKey = (raw: string): string | undefined => {
  if (raw.length === 1) {
    const lower = raw.toLowerCase()
    if (/^[a-z0-9]$/.test(lower) || punctuation.has(lower)) return lower
    return undefined
  }
  const lower = raw.toLowerCase()
  const named = namedByLower.get(lower) ?? keyAliases[lower]
  if (named) return named
  const fn = raw.toUpperCase()
  return isFunctionKey(fn) ? fn : undefined
}

/** Parse a shortcut. Throws `ShortcutParseError`: shortcuts are code, so a bad one is a bug. */
export const parseShortcut = (text: string): ParsedShortcut => {
  const parts = text.split("+").map((part) => part.trim())
  if (parts.length === 0 || parts.some((part) => part.length === 0)) {
    throw new ShortcutParseError(text, "empty part")
  }
  const keyPart = parts[parts.length - 1] as string
  const result = { mod: false, ctrl: false, meta: false, alt: false, shift: false }
  for (const part of parts.slice(0, -1)) {
    let flag: keyof typeof result
    switch (part.toLowerCase()) {
      case "mod":
        flag = "mod"
        break
      case "ctrl":
      case "control":
        flag = "ctrl"
        break
      case "cmd":
      case "command":
      case "meta":
      case "super":
      case "win":
        flag = "meta"
        break
      case "alt":
      case "option":
      case "opt":
        flag = "alt"
        break
      case "shift":
        flag = "shift"
        break
      default:
        throw new ShortcutParseError(text, `unknown modifier "${part}"`)
    }
    if (result[flag]) throw new ShortcutParseError(text, `repeated modifier "${part}"`)
    result[flag] = true
  }
  const key = canonicalKey(keyPart)
  if (!key) throw new ShortcutParseError(text, `unknown key "${keyPart}"`)
  return { key, ...result }
}

/** Resolve `Mod` for an OS. */
export const resolveShortcut = (shortcut: ParsedShortcut, os: OS): KeyCombo => ({
  key: shortcut.key,
  ctrl: shortcut.ctrl || (shortcut.mod && os !== "mac"),
  meta: shortcut.meta || (shortcut.mod && os === "mac"),
  alt: shortcut.alt,
  shift: shortcut.shift,
})

export const parseCombo = (text: string, os: OS): KeyCombo => resolveShortcut(parseShortcut(text), os)

/** A canonical string for a combo, used as a lookup key: `Ctrl+Alt+Shift+Meta+k`. */
export const comboId = (combo: KeyCombo): string =>
  `${combo.ctrl ? "Ctrl+" : ""}${combo.alt ? "Alt+" : ""}${combo.shift ? "Shift+" : ""}${combo.meta ? "Meta+" : ""}${combo.key}`

export const sameCombo = (a: KeyCombo, b: KeyCombo): boolean => comboId(a) === comboId(b)

/** Whether a key types a character when pressed without Ctrl or Cmd. */
export const isPrintableKey = (key: string): boolean => key.length === 1 || key === "Space"

// MARK: - Events

/** The parts of a `KeyboardEvent` the matcher reads. */
export type KeyEventLike = {
  readonly key: string
  readonly code?: string
  readonly ctrlKey: boolean
  readonly metaKey: boolean
  readonly altKey: boolean
  readonly shiftKey: boolean
  readonly repeat?: boolean
  readonly isComposing?: boolean
  /** Legacy; 229 means an IME is handling the key. */
  readonly keyCode?: number
  readonly target?: unknown
  readonly defaultPrevented?: boolean
  getModifierState?(key: string): boolean
  preventDefault?(): void
  stopPropagation?(): void
}

const codeToKey: Record<string, string> = {
  Comma: ",",
  Period: ".",
  Slash: "/",
  Backslash: "\\",
  BracketLeft: "[",
  BracketRight: "]",
  Semicolon: ";",
  Quote: "'",
  Backquote: "`",
  Minus: "-",
  Equal: "=",
  Space: "Space",
}

const legacyKeyNames: Record<string, string> = {
  Up: "ArrowUp",
  Down: "ArrowDown",
  Left: "ArrowLeft",
  Right: "ArrowRight",
  Esc: "Escape",
  Del: "Delete",
  Spacebar: "Space",
}

const modifierKeys = new Set(["Shift", "Control", "Alt", "AltGraph", "Meta", "OS", "Super", "Hyper", "CapsLock", "Fn"])

/** The canonical key of an event, or `undefined` for modifier-only and unknown keys. */
export const eventKey = (event: KeyEventLike): string | undefined => {
  const key = event.key
  const code = event.code ?? ""
  if (modifierKeys.has(key)) return undefined
  if (key === " " || code === "Space") return "Space"
  const legacy = legacyKeyNames[key]
  if (legacy) return legacy
  if (namedKeys.has(key) || isFunctionKey(key)) return key
  if (key.length === 1 && /^[a-z]$/i.test(key)) return key.toLowerCase()
  const letter = /^Key([A-Z])$/.exec(code)
  if (letter?.[1]) return letter[1].toLowerCase()
  const digit = /^Digit(\d)$/.exec(code)
  if (digit?.[1]) return digit[1]
  const punct = codeToKey[code]
  if (punct) return punct
  if (key.length === 1) return /^\d$/.test(key) ? key : key.toLowerCase()
  return undefined
}

/** The combo an event represents, or `undefined` if it is only a modifier. */
export const eventCombo = (event: KeyEventLike): KeyCombo | undefined => {
  const key = eventKey(event)
  if (!key) return undefined
  return { key, ctrl: event.ctrlKey, meta: event.metaKey, alt: event.altKey, shift: event.shiftKey }
}

/** True while an input method is composing; no shortcut may fire then. */
export const isComposingEvent = (event: KeyEventLike): boolean =>
  event.isComposing === true || event.key === "Process" || event.keyCode === 229

// MARK: - Display

const macSymbols: Record<string, string> = {
  ArrowUp: "↑",
  ArrowDown: "↓",
  ArrowLeft: "←",
  ArrowRight: "→",
  Escape: "⎋",
  Enter: "↩",
  Tab: "⇥",
  Space: "Space",
  Backspace: "⌫",
  Delete: "⌦",
  Home: "↖",
  End: "↘",
  PageUp: "⇞",
  PageDown: "⇟",
}

const otherNames: Record<string, string> = {
  ArrowUp: "Up",
  ArrowDown: "Down",
  ArrowLeft: "Left",
  ArrowRight: "Right",
  Escape: "Esc",
  PageUp: "Page Up",
  PageDown: "Page Down",
}

/** How a combo is shown in menus and the shortcut reference: `⌥↑` on Mac, `Alt+Up` elsewhere. */
export const formatCombo = (combo: KeyCombo, os: OS): string => {
  const keyLabel = (names: Record<string, string>) => names[combo.key] ?? (combo.key.length === 1 ? combo.key.toUpperCase() : combo.key)
  if (os === "mac") {
    return `${combo.ctrl ? "⌃" : ""}${combo.alt ? "⌥" : ""}${combo.shift ? "⇧" : ""}${combo.meta ? "⌘" : ""}${keyLabel(macSymbols)}`
  }
  const parts: string[] = []
  if (combo.ctrl) parts.push("Ctrl")
  if (combo.meta) parts.push(os === "windows" ? "Win" : "Super")
  if (combo.alt) parts.push("Alt")
  if (combo.shift) parts.push("Shift")
  parts.push(keyLabel(otherNames))
  return parts.join("+")
}

/** Electron accelerator syntax, for the native menu. */
export const toAccelerator = (combo: KeyCombo): string => {
  const parts: string[] = []
  if (combo.ctrl) parts.push("Ctrl")
  if (combo.meta) parts.push("Cmd")
  if (combo.alt) parts.push("Alt")
  if (combo.shift) parts.push("Shift")
  const names: Record<string, string> = {
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
    Escape: "Esc",
    Enter: "Return",
  }
  parts.push(names[combo.key] ?? (combo.key.length === 1 ? combo.key.toUpperCase() : combo.key))
  return parts.join("+")
}

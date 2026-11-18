/**
 * Shortcuts for assistive technology: the `aria-keyshortcuts` value
 * (WAI-ARIA 1.2) of a key combination. Modifiers are `Control`, `Alt`,
 * `Shift` and `Meta`; the key is a `KeyboardEvent.key` value, letters
 * upper case, the space bar `Space`. Several shortcuts are separated by a
 * space.
 *
 * Visible hints ("⌘E", "Ctrl+Shift+E") are drawn `aria-hidden`; the element
 * that the shortcut acts on carries this value instead. Matching keys is the
 * command registry's job (`@inline/view`), not the kit's.
 */

/** Structurally the registry's `KeyCombo`. */
export type ShortcutCombo = {
  readonly key: string
  readonly ctrl?: boolean
  readonly meta?: boolean
  readonly alt?: boolean
  readonly shift?: boolean
}

const keyName = (key: string): string => {
  if (key === " " || key === "Space") return "Space"
  return key.length === 1 ? key.toUpperCase() : key
}

/** `aria-keyshortcuts` for one combination: `{ key: "e", meta: true }` gives "Meta+E". */
export const ariaKeyShortcuts = (combo: ShortcutCombo): string => {
  const parts: string[] = []
  if (combo.ctrl) parts.push("Control")
  if (combo.alt) parts.push("Alt")
  if (combo.shift) parts.push("Shift")
  if (combo.meta) parts.push("Meta")
  parts.push(keyName(combo.key))
  return parts.join("+")
}

// The registry's display forms (`formatCombo` in `@inline/view`), read back.
const macModifiers: Record<string, keyof Omit<ShortcutCombo, "key">> = { "⌃": "ctrl", "⌥": "alt", "⇧": "shift", "⌘": "meta" }
const macKeys: Record<string, string> = {
  "↑": "ArrowUp",
  "↓": "ArrowDown",
  "←": "ArrowLeft",
  "→": "ArrowRight",
  "⎋": "Escape",
  "↩": "Enter",
  "⇥": "Tab",
  "⌫": "Backspace",
  "⌦": "Delete",
  "↖": "Home",
  "↘": "End",
  "⇞": "PageUp",
  "⇟": "PageDown",
}
const otherModifiers: Record<string, keyof Omit<ShortcutCombo, "key">> = {
  ctrl: "ctrl",
  control: "ctrl",
  alt: "alt",
  option: "alt",
  shift: "shift",
  win: "meta",
  super: "meta",
  meta: "meta",
  cmd: "meta",
}
const otherKeys: Record<string, string> = {
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
  esc: "Escape",
  "page up": "PageUp",
  "page down": "PageDown",
}

const parseMacHint = (hint: string): ShortcutCombo | undefined => {
  const combo: { key: string; ctrl?: boolean; meta?: boolean; alt?: boolean; shift?: boolean } = { key: "" }
  let index = 0
  const chars = Array.from(hint)
  while (index < chars.length) {
    const modifier = macModifiers[chars[index] ?? ""]
    if (!modifier) break
    combo[modifier] = true
    index++
  }
  const rest = chars.slice(index).join("")
  if (rest.length === 0) return undefined
  combo.key = macKeys[rest] ?? rest
  return combo
}

const parseOtherHint = (hint: string): ShortcutCombo | undefined => {
  const parts = hint.split("+")
  // "Ctrl++" names the plus key.
  if (hint.endsWith("++")) parts.splice(parts.length - 2, 2, "+")
  const combo: { key: string; ctrl?: boolean; meta?: boolean; alt?: boolean; shift?: boolean } = { key: "" }
  for (const [index, part] of parts.entries()) {
    const word = part.trim()
    if (index === parts.length - 1) {
      if (word.length === 0) return undefined
      combo.key = otherKeys[word.toLowerCase()] ?? word
      continue
    }
    const modifier = otherModifiers[word.toLowerCase()]
    if (!modifier) return undefined
    combo[modifier] = true
  }
  return combo
}

/**
 * `aria-keyshortcuts` from a displayed hint, as the registry formats them
 * ("⌘E", "⇧⌘⌫", "Ctrl+Shift+E", "Alt+Up", "R"); undefined when it does not
 * read as one. A fallback for callers that only have the hint: prefer
 * `ariaKeyShortcuts(combo)` from the command's combo.
 */
export const ariaKeyShortcutsFromHint = (hint: string): string | undefined => {
  const text = hint.trim()
  if (text.length === 0) return undefined
  const first = Array.from(text)[0] ?? ""
  const combo = macModifiers[first] || macKeys[text] ? parseMacHint(text) : parseOtherHint(text)
  return combo ? ariaKeyShortcuts(combo) : undefined
}

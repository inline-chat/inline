import { atomsIntersecting } from "./entities"
import type { DocState, Range } from "./types"

/**
 * Autocomplete triggers, detected from the document alone. The rules follow
 * the Mac client (`apple/InlineKit/Sources/InlineKit/RichTextHelpers/`:
 * `MentionDetector`, `EmojiAutocompleteDetector`, `SlashCommandDetector`).
 *
 * Each trigger reports the query typed so far (from the trigger character to
 * the caret) and the range to replace when an item is accepted (from the
 * trigger character to the end of the word, which may extend past the caret).
 */
export type TriggerKind = "mention" | "emoji" | "command"

export type Trigger = {
  kind: TriggerKind
  /** Text between the trigger character and the caret. */
  query: string
  /** The range an accepted item replaces, trigger character included. */
  range: Range
}

const isBreak = (code: number) => code === 32 || code === 10 || code === 9 || code === 13

/** `@` at the start or after whitespace, then no whitespace up to the caret. */
export const detectMention = (text: string, caret: number): Trigger | null => {
  if (caret < 0 || caret > text.length) return null
  let at = -1
  for (let i = caret - 1; i >= 0; i--) {
    const code = text.charCodeAt(i)
    if (code === 64) {
      at = i
      break
    }
    if (isBreak(code)) break
  }
  if (at < 0) return null
  if (at > 0 && !isBreak(text.charCodeAt(at - 1))) return null
  let end = caret
  while (end < text.length && !isBreak(text.charCodeAt(end))) end++
  return { kind: "mention", query: text.slice(at + 1, caret), range: { from: at, to: end } }
}

/** Letters, digits, `_`, `+`, `-` (ASCII), as in the Mac detector. */
const isEmojiQueryChar = (code: number) =>
  code === 43 ||
  code === 45 ||
  code === 95 ||
  (code >= 48 && code <= 57) ||
  (code >= 65 && code <= 90) ||
  (code >= 97 && code <= 122)

const letterOrDigit = /[\p{L}\p{N}_]/u

/** The whole code point that ends at `offset`. */
const charBefore = (text: string, offset: number): string => {
  const low = text.charCodeAt(offset - 1)
  if (offset >= 2 && low >= 0xdc00 && low <= 0xdfff) {
    const high = text.charCodeAt(offset - 2)
    if (high >= 0xd800 && high <= 0xdbff) return text.slice(offset - 2, offset)
  }
  return text.slice(offset - 1, offset)
}

/**
 * `:` followed by at least one query character up to the caret, where the
 * colon does not follow a letter, digit or underscore (so `10:30` and
 * `http://` do not trigger).
 */
export const detectEmoji = (text: string, caret: number): Trigger | null => {
  if (caret <= 0 || caret > text.length) return null
  for (let i = caret - 1; i >= 0; i--) {
    const code = text.charCodeAt(i)
    if (code === 58) {
      if (i + 1 >= caret) return null
      if (i > 0 && letterOrDigit.test(charBefore(text, i))) return null
      let end = caret
      while (end < text.length && isEmojiQueryChar(text.charCodeAt(end))) end++
      return { kind: "emoji", query: text.slice(i + 1, caret), range: { from: i, to: end } }
    }
    if (isBreak(code) || !isEmojiQueryChar(code)) return null
  }
  return null
}

/**
 * `/` with only whitespace before it in the whole message and nothing but
 * whitespace after the command word: a command is the entire message, as in
 * the Mac client.
 */
export const detectCommand = (text: string, caret: number): Trigger | null => {
  if (caret < 0 || caret > text.length) return null
  let slash = -1
  for (let i = caret - 1; i >= 0; i--) {
    const code = text.charCodeAt(i)
    if (code === 47) {
      slash = i
      break
    }
    if (isBreak(code)) break
  }
  if (slash < 0) return null
  if (text.slice(0, slash).trim() !== "") return null
  let end = caret
  while (end < text.length && !isBreak(text.charCodeAt(end))) end++
  if (text.slice(end).trim() !== "") return null
  return { kind: "command", query: text.slice(slash + 1, caret), range: { from: slash, to: end } }
}

/**
 * The trigger at a collapsed caret, if any. Command first (it is the most
 * specific), then mention, then emoji. A trigger whose range touches an atom
 * is ignored, so the `@` in an existing mention chip never re-triggers.
 */
export const detectTrigger = (state: DocState): Trigger | null => {
  const { anchor, focus } = state.selection
  if (anchor !== focus) return null
  const detectors = [detectCommand, detectMention, detectEmoji]
  for (const detect of detectors) {
    const trigger = detect(state.text, focus)
    if (!trigger) continue
    if (atomsIntersecting(state.entities, trigger.range.from, Math.max(trigger.range.to, trigger.range.from + 1)).length > 0) {
      continue
    }
    return trigger
  }
  return null
}

export const sameTrigger = (a: Trigger | null, b: Trigger | null): boolean =>
  a === b ||
  (a !== null &&
    b !== null &&
    a.kind === b.kind &&
    a.query === b.query &&
    a.range.from === b.range.from &&
    a.range.to === b.range.to)

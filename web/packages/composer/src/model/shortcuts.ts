import { isCollapsed, replace } from "./doc"
import { atomsIntersecting, normalizeEntities } from "./entities"
import { lineStartOf } from "./segment"
import type { DocState } from "./types"

/**
 * Markdown-style shortcuts, kept minimal: only `**bold**`, after
 * `apple/InlineKit/Sources/InlineKit/RichTextHelpers/BoldTextDetector.swift`.
 *
 * Differences from the Mac detector, on purpose:
 * - it runs when the closing `**` has just been typed, on the text before
 *   the caret on the current line, not over the whole message, so pasted or
 *   restored text is never rewritten;
 * - the content may not start or end with whitespace (`2 ** 3 ** 4` stays
 *   as typed), as in Markdown.
 */
const pattern = /\*\*([^*\n]+?)\*\*$/

/**
 * If the caret is right after `**content**`, remove the markers and make
 * the content bold. Returns `state` unchanged otherwise. The caller records
 * the result as its own history step, so one undo brings the markers back.
 */
export const applyBoldShortcut = (state: DocState): DocState => {
  if (!isCollapsed(state.selection)) return state
  const caret = state.selection.focus
  if (caret < 5 || state.text.charCodeAt(caret - 1) !== 42) return state
  const lineStart = lineStartOf(state.text, caret)
  const before = state.text.slice(lineStart, caret)
  const match = pattern.exec(before)
  if (!match) return state
  const content = match[1]!
  if (/^\s|\s$/u.test(content)) return state
  const start = lineStart + match.index
  const end = caret
  if (atomsIntersecting(state.entities, start, start + 2).length > 0) return state
  if (atomsIntersecting(state.entities, end - 2, end).length > 0) return state

  // Remove the closing markers, then the opening ones, then add the mark.
  const withoutClose = replace(state, { from: end - 2, to: end }, { text: "" })
  const withoutOpen = replace(withoutClose, { from: start, to: start + 2 }, { text: "" })
  const contentEnd = end - 4
  const entities = normalizeEntities(withoutOpen.text, [
    ...withoutOpen.entities,
    { type: "bold", offset: start, length: content.length },
  ])
  return {
    ...withoutOpen,
    entities,
    selection: { anchor: contentEnd, focus: contentEnd },
    pendingMarks: null,
    revision: state.revision + 1,
  }
}

/**
 * The page's text selection as a find seed. Framework-free; touches the DOM
 * only when called, and duck-typed so it runs in tests without one.
 */

type NodeLike = { readonly parentElement?: ElementLike | null } | null | undefined
type ElementLike = {
  contains(node: unknown): boolean
  closest?(selector: string): unknown
}
type SelectionLike = {
  readonly isCollapsed: boolean
  readonly rangeCount: number
  readonly anchorNode: unknown
  readonly focusNode: unknown
  toString(): string
}
type DocumentLike = { getSelection(): SelectionLike | null }

const editable = "input, textarea, [contenteditable]:not([contenteditable='false'])"

const insideEditable = (node: unknown): boolean => {
  const element = (node as { closest?: unknown } | null)?.closest
    ? (node as ElementLike)
    : (node as NodeLike)?.parentElement
  return typeof element?.closest === "function" && element.closest(editable) !== null
}

/**
 * The selected text when the whole selection lies inside `root` (the chat's
 * message list) and not in an editable field (the composer has its own
 * selection, and Mod+F there should not seed with a draft). Undefined
 * otherwise. Pass the result to `open({ seed })`; the model keeps the first
 * line, trimmed and capped (`selectionSeed`).
 */
export const chatSelectionText = (doc: DocumentLike | undefined, root: ElementLike | null | undefined): string | undefined => {
  if (!doc || !root) return undefined
  const selection = doc.getSelection()
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return undefined
  if (!root.contains(selection.anchorNode) || !root.contains(selection.focusNode)) return undefined
  if (insideEditable(selection.anchorNode) || insideEditable(selection.focusNode)) return undefined
  const text = selection.toString()
  return text.trim().length > 0 ? text : undefined
}

import { effect, untracked } from "@inline/reactive"
import type { ComposerController } from "../controller"
import { isPastePlainKey, type KeyInput } from "../keys"
import {
  atomsIntersecting,
  deleteBackward,
  deleteForward,
  deleteRange,
  deletionRange,
  docLines,
  insertText,
  selectionRange,
  type DeleteUnit,
  type DocState,
  type Line,
  type Range,
} from "../model"
import { INTERNAL_MIME, type ClipboardContent } from "../internal"
import { fillLine, isLineElement, lineMatchesDom, renderLine, type ComposerClassNames } from "./render"
import { domPointToOffset, readDomText, readSelection, writeSelection } from "./selection"

/**
 * The DOM binding: imperative code handed one element, which becomes the
 * editable surface for a controller. Framework-free; a view calls it from a
 * ref callback (or `useElement`) and calls the returned function on unmount.
 *
 * Two input paths (see README):
 * - structural edits (Enter, deleting across an atom or a line, formatting,
 *   paste, drop, undo and redo) are taken in `beforeinput` or `keydown`,
 *   applied to the model, and the affected lines re-rendered;
 * - plain typing and IME composition are left to the browser and read back
 *   from the DOM on `input` and by a mutation observer. Nothing is rendered
 *   and no key is handled while a composition is in progress.
 */

export type AttachOptions = {
  classNames?: ComposerClassNames
  /** `spellcheck` on the surface. Follows the user's setting; default true. */
  spellcheck?: boolean
  /** Accessible name. */
  label?: string
  /** Shown by the view's CSS through `attr(data-placeholder)` while `data-empty` is set. */
  placeholder?: string
  /** Save the draft when the page hides (`visibilitychange`, `pagehide`). Default true. */
  flushOnHide?: boolean
}

const deleteUnits: Readonly<Record<string, [direction: "backward" | "forward", unit: DeleteUnit]>> = {
  deleteContentBackward: ["backward", "grapheme"],
  deleteContentForward: ["forward", "grapheme"],
  deleteWordBackward: ["backward", "word"],
  deleteWordForward: ["forward", "word"],
  deleteSoftLineBackward: ["backward", "line"],
  deleteHardLineBackward: ["backward", "line"],
  deleteSoftLineForward: ["forward", "line"],
  deleteHardLineForward: ["forward", "line"],
}

const formatInputs: Readonly<Record<string, "bold" | "italic" | "underline" | "strikethrough">> = {
  formatBold: "bold",
  formatItalic: "italic",
  formatUnderline: "underline",
  formatStrikeThrough: "strikethrough",
}

const ignoredInputs: ReadonlySet<string> = new Set([
  "formatSuperscript",
  "formatSubscript",
  "formatJustifyFull",
  "formatJustifyCenter",
  "formatJustifyRight",
  "formatJustifyLeft",
  "formatIndent",
  "formatOutdent",
  "formatRemove",
  "formatSetBlockTextDirection",
  "formatSetInlineTextDirection",
  "formatBackColor",
  "formatFontColor",
  "formatFontName",
  "insertOrderedList",
  "insertUnorderedList",
  "insertHorizontalRule",
  "insertLink",
])

/** A change the browser can make itself: inside one line, touching no atom. */
const browserCanEdit = (doc: DocState, range: Range): boolean =>
  !doc.text.slice(range.from, range.to).includes("\n") &&
  atomsIntersecting(doc.entities, range.from, range.to).length === 0 &&
  !touchesAtomEdge(doc, range)

/** A collapsed deletion right next to an atom would remove part of a chip in some engines. */
const touchesAtomEdge = (doc: DocState, range: Range): boolean =>
  range.from === range.to &&
  doc.entities.some((e) => e.type === "mention" || e.type === "groupMention" || e.type === "thread"
    ? e.offset === range.from || e.offset + e.length === range.from
    : false)

export const attachComposer = (
  root: HTMLElement,
  controller: ComposerController,
  options: AttachOptions = {},
): (() => void) => {
  const doc = root.ownerDocument
  const view = doc.defaultView
  const classNames = options.classNames ?? {}
  let composing = false
  let renderDeferred = false
  let plainNextPaste = false
  let dragSource: Range | null = null
  let detached = false
  /** The content last rendered, so a selection change does not reconcile the DOM. */
  let rendered: DocState | null = null

  root.setAttribute("contenteditable", "true")
  root.setAttribute("role", "textbox")
  root.setAttribute("aria-multiline", "true")
  root.setAttribute("spellcheck", options.spellcheck === false ? "false" : "true")
  root.setAttribute("enterkeyhint", "send")
  if (options.label) root.setAttribute("aria-label", options.label)
  if (options.placeholder) root.setAttribute("data-placeholder", options.placeholder)
  while (root.firstChild) root.removeChild(root.firstChild)

  const isFocused = () => {
    const active = doc.activeElement
    return active === root || (active !== null && root.contains(active))
  }

  // -------------------------------------------------------------------------
  // Rendering

  const lineElements = (): HTMLElement[] => {
    const out: HTMLElement[] = []
    for (let child = root.firstChild; child; child = child.nextSibling) {
      if (isLineElement(child)) out.push(child)
    }
    return out
  }

  /** Bring the DOM in line with the model, touching only lines that differ. Returns whether anything changed. */
  const reconcile = (lines: Line[]): boolean => {
    let changed = false
    // Anything that is not one of our lines (browser-made text, br, blocks) goes.
    for (let child = root.firstChild; child; ) {
      const next = child.nextSibling
      if (!isLineElement(child)) {
        root.removeChild(child)
        changed = true
      }
      child = next
    }
    const current = lineElements()
    const min = Math.min(current.length, lines.length)
    let prefix = 0
    while (prefix < min && lineMatchesDom(current[prefix]!, lines[prefix]!)) prefix++
    let suffix = 0
    while (
      suffix < min - prefix &&
      lineMatchesDom(current[current.length - 1 - suffix]!, lines[lines.length - 1 - suffix]!)
    ) {
      suffix++
    }
    const oldMiddle = current.slice(prefix, current.length - suffix)
    const newMiddle = lines.slice(prefix, lines.length - suffix)
    const anchor = current[current.length - suffix] ?? null
    // Reuse elements in place where counts line up, so a line keeps its node.
    for (let i = 0; i < newMiddle.length; i++) {
      const line = newMiddle[i]!
      const existing = oldMiddle[i]
      if (existing) {
        if (!lineMatchesDom(existing, line)) {
          fillLine(existing, line, classNames)
          changed = true
        }
      } else {
        root.insertBefore(renderLine(doc, line, classNames), anchor)
        changed = true
      }
    }
    for (let i = newMiddle.length; i < oldMiddle.length; i++) {
      root.removeChild(oldMiddle[i]!)
      changed = true
    }
    return changed
  }

  const render = (state: DocState) => {
    if (composing) {
      renderDeferred = true
      return
    }
    renderDeferred = false
    const fromDom = controller.lastChangeFromDom()
    if (rendered && rendered.text === state.text && rendered.entities === state.entities) {
      // A selection change: the content on screen is already this content.
      if (!fromDom && isFocused()) writeSelection(root, state.selection)
      return
    }
    rendered = state
    const changed = reconcile(docLines(state))
    if (state.text.length === 0) root.setAttribute("data-empty", "")
    else root.removeAttribute("data-empty")
    // Our own mutations are not input.
    observer.takeRecords()
    if ((changed || !fromDom) && isFocused()) writeSelection(root, state.selection)
  }

  // -------------------------------------------------------------------------
  // Reading back what the browser did

  const syncSelection = () => {
    const selection = readSelection(root)
    if (selection) controller.setSelection(selection)
  }

  const readBack = () => {
    observer.takeRecords()
    if (composing || detached) return
    const text = readDomText(root)
    const selection = readSelection(root) ?? controller.doc.peek().selection
    const state = controller.doc.peek()
    if (text === state.text) {
      controller.setSelection(selection)
      // Same text, different structure (a browser-made <b>, a split node): fix it.
      if (reconcile(docLines(state))) {
        observer.takeRecords()
        if (isFocused()) writeSelection(root, controller.doc.peek().selection)
      }
      return
    }
    controller.applyDomText(text, selection)
  }

  const observer = new (view?.MutationObserver ?? MutationObserver)(() => {
    if (!composing) readBack()
  })

  // -------------------------------------------------------------------------
  // Events

  const onBeforeInput = (event: InputEvent) => {
    if (composing || event.isComposing) return
    const type = event.inputType
    const state = () => controller.doc.peek()
    syncSelection()

    if (type === "insertParagraph" || type === "insertLineBreak") {
      event.preventDefault()
      controller.insertLineBreak()
      return
    }
    if (type === "insertText" || type === "insertReplacementText" || type === "insertFromYank") {
      const data = event.data ?? event.dataTransfer?.getData("text/plain") ?? ""
      const range = targetRange(event) ?? selectionRange(state().selection)
      const needsModel =
        data.includes("\n") ||
        state().pendingMarks !== null ||
        !browserCanEdit(state(), range) ||
        (range.from !== range.to && atomsIntersecting(state().entities, range.from, range.to).length > 0)
      if (!needsModel) return
      event.preventDefault()
      const selected = selectionRange(state().selection)
      const atSelection = selected.from === range.from && selected.to === range.to
      controller.apply((s) => (atSelection ? insertText(s, data) : insertText(s, data, range)), "typing")
      return
    }
    if (type === "insertFromPaste" || type === "insertFromPasteAsQuotation" || type === "insertFromDrop") {
      // Handled by the paste and drop listeners; never let the browser insert HTML.
      event.preventDefault()
      return
    }
    if (type === "deleteByCut") {
      event.preventDefault()
      controller.deleteSelection()
      return
    }
    if (type === "deleteByDrag") {
      event.preventDefault()
      return
    }
    const deletion = deleteUnits[type]
    if (deletion || type === "deleteContent") {
      const [direction, unit] = deletion ?? ["backward", "grapheme"]
      const range = targetRange(event) ?? deletionRange(state(), direction, unit)
      if (browserCanEdit(state(), range) && range.from !== range.to) return
      event.preventDefault()
      controller.apply(
        (s) =>
          range.from !== range.to
            ? deleteRange(s, range)
            : direction === "backward"
              ? deleteBackward(s, unit)
              : deleteForward(s, unit),
        "deleting",
      )
      return
    }
    if (type === "historyUndo") {
      event.preventDefault()
      controller.undo()
      return
    }
    if (type === "historyRedo") {
      event.preventDefault()
      controller.redo()
      return
    }
    const format = formatInputs[type]
    if (format) {
      event.preventDefault()
      controller.toggleMark(format)
      return
    }
    if (ignoredInputs.has(type)) event.preventDefault()
  }

  /** The range the browser says it will change, mapped to the model. */
  const targetRange = (event: InputEvent): Range | null => {
    const ranges = typeof event.getTargetRanges === "function" ? event.getTargetRanges() : []
    const first = ranges[0]
    if (!first) return null
    const from = domPointToOffset(root, first.startContainer, first.startOffset)
    const to = domPointToOffset(root, first.endContainer, first.endOffset)
    if (from === null || to === null) return null
    return { from: Math.min(from, to), to: Math.max(from, to) }
  }

  const onInput = () => {
    if (!composing) readBack()
  }

  const onCompositionStart = () => {
    composing = true
  }

  const onCompositionEnd = () => {
    composing = false
    readBack()
    if (renderDeferred) render(controller.doc.peek())
  }

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.isComposing || event.keyCode === 229 || composing) return
    const input: KeyInput = {
      key: event.key,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
      ctrlKey: event.ctrlKey,
      metaKey: event.metaKey,
    }
    if (isPastePlainKey(input, controller.platform)) {
      plainNextPaste = true
      return
    }
    syncSelection()
    if (controller.handleKeyDown(input)) event.preventDefault()
  }

  const onSelectionChange = () => {
    if (composing || detached) return
    if (readSelection(root) === null) return
    // Read text first: an engine may report the caret move before the input.
    readBack()
  }

  const clipboardContent = (data: DataTransfer): ClipboardContent => {
    const content: ClipboardContent = {}
    const html = data.getData("text/html")
    const text = data.getData("text/plain")
    const internal = data.getData(INTERNAL_MIME)
    if (html) content.html = html
    if (text) content.text = text
    if (internal) content.internal = internal
    return content
  }

  const filesOf = (data: DataTransfer): File[] => Array.from(data.files ?? [])

  const onPaste = (event: ClipboardEvent) => {
    const data = event.clipboardData
    event.preventDefault()
    const plain = plainNextPaste
    plainNextPaste = false
    if (!data) return
    syncSelection()
    const content = clipboardContent(data)
    const files = filesOf(data)
    // An image copied from a web page arrives as a file plus an HTML fragment
    // (`<img src=…>`) and no plain text: the file is what the user copied. A
    // spreadsheet or document selection arrives as plain text plus HTML plus a
    // picture of the selection: there the text is what the user copied.
    if (files.length > 0 && !content.text && !content.internal) {
      controller.pasteFiles(files)
      return
    }
    if (!content.text && !content.html && !content.internal) return
    controller.paste(content, { plain })
  }

  const writeClipboard = (event: ClipboardEvent): boolean => {
    syncSelection()
    const state = controller.doc.peek()
    if (state.selection.anchor === state.selection.focus || !event.clipboardData) return false
    const content = controller.selectedContent()
    event.preventDefault()
    event.clipboardData.setData("text/plain", content.text)
    event.clipboardData.setData(INTERNAL_MIME, controller.clipboardPayload(content))
    return true
  }

  const onCopy = (event: ClipboardEvent) => {
    writeClipboard(event)
  }

  const onCut = (event: ClipboardEvent) => {
    if (writeClipboard(event)) controller.deleteSelection()
  }

  const onDragStart = (event: DragEvent) => {
    syncSelection()
    const state = controller.doc.peek()
    dragSource = state.selection.anchor === state.selection.focus ? null : selectionRange(state.selection)
    if (dragSource && event.dataTransfer) {
      const content = controller.selectedContent()
      event.dataTransfer.setData("text/plain", content.text)
      event.dataTransfer.setData(INTERNAL_MIME, controller.clipboardPayload(content))
    }
  }

  const onDragEnd = () => {
    dragSource = null
  }

  const dropOffset = (event: DragEvent): number | null => {
    const d = doc as Document & {
      caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null
      caretRangeFromPoint?: (x: number, y: number) => globalThis.Range | null
    }
    const position = d.caretPositionFromPoint?.(event.clientX, event.clientY)
    if (position) return domPointToOffset(root, position.offsetNode, position.offset)
    const range = d.caretRangeFromPoint?.(event.clientX, event.clientY)
    if (range) return domPointToOffset(root, range.startContainer, range.startOffset)
    return null
  }

  const onDrop = (event: DragEvent) => {
    const data = event.dataTransfer
    event.preventDefault()
    const source = dragSource
    dragSource = null
    if (!data) return
    const files = filesOf(data)
    const content = clipboardContent(data)
    if (files.length > 0 && !content.text && !content.html) {
      controller.pasteFiles(files)
      return
    }
    const at = dropOffset(event) ?? selectionRange(controller.doc.peek().selection).from
    controller.drop(content, at, source ?? undefined)
    root.focus({ preventScroll: true })
  }

  const onVisibilityChange = () => {
    if (doc.visibilityState === "hidden") controller.flushDraft()
  }
  const onPageHide = () => controller.flushDraft()

  root.addEventListener("beforeinput", onBeforeInput)
  root.addEventListener("input", onInput)
  root.addEventListener("compositionstart", onCompositionStart)
  root.addEventListener("compositionend", onCompositionEnd)
  root.addEventListener("keydown", onKeyDown)
  root.addEventListener("paste", onPaste)
  root.addEventListener("copy", onCopy)
  root.addEventListener("cut", onCut)
  root.addEventListener("dragstart", onDragStart)
  root.addEventListener("dragend", onDragEnd)
  root.addEventListener("drop", onDrop)
  doc.addEventListener("selectionchange", onSelectionChange)
  if (options.flushOnHide !== false) {
    doc.addEventListener("visibilitychange", onVisibilityChange)
    view?.addEventListener("pagehide", onPageHide)
  }

  const stopRendering = effect(() => {
    const state = controller.doc.get()
    untracked(() => render(state))
  })
  observer.observe(root, { childList: true, characterData: true, subtree: true })

  return () => {
    if (detached) return
    detached = true
    stopRendering()
    observer.disconnect()
    root.removeEventListener("beforeinput", onBeforeInput)
    root.removeEventListener("input", onInput)
    root.removeEventListener("compositionstart", onCompositionStart)
    root.removeEventListener("compositionend", onCompositionEnd)
    root.removeEventListener("keydown", onKeyDown)
    root.removeEventListener("paste", onPaste)
    root.removeEventListener("copy", onCopy)
    root.removeEventListener("cut", onCut)
    root.removeEventListener("dragstart", onDragStart)
    root.removeEventListener("dragend", onDragEnd)
    root.removeEventListener("drop", onDrop)
    doc.removeEventListener("selectionchange", onSelectionChange)
    doc.removeEventListener("visibilitychange", onVisibilityChange)
    view?.removeEventListener("pagehide", onPageHide)
  }
}

/** Focus the surface without scrolling the page (check WebKit; see README). */
export const focusComposer = (root: HTMLElement) => root.focus({ preventScroll: true })

import type { Selection } from "../model"
import { ATOM_ATTR, isLineElement } from "./render"

/**
 * Reading the editable surface back as text, and mapping between DOM points
 * and model offsets. One walk does both, so the text and the offsets always
 * agree, including for DOM the browser made rather than us:
 *
 * - each top-level block (our line `div`s, or a block the browser inserted)
 *   is a line; lines are joined with `\n`;
 * - loose text and inline elements directly in the root form a line too;
 * - `br` ends a line inside the root and is otherwise ignored (we only use
 *   it as a filler);
 * - an atom counts as its text, and a point inside it snaps to its start
 *   (offset 0) or its end (anything else).
 */

const blockNames: ReadonlySet<string> = new Set(["div", "p", "li", "pre", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"])

const isBlock = (node: Node): boolean =>
  node.nodeType === 1 && (isLineElement(node) || blockNames.has((node as Element).localName))

const isAtom = (node: Node): node is Element => node.nodeType === 1 && (node as Element).hasAttribute(ATOM_ATTR)

type Target = { node: Node; offset: number }

class Reader {
  text = ""
  found: number | null = null

  constructor(private readonly target: Target | null) {}

  private hit(position: number) {
    if (this.found === null) this.found = position
  }

  /** Inline content of a line: text, marked spans, atoms, nested blocks as line breaks. */
  inline(node: Node, lineStart: number) {
    const target = this.target
    if (node.nodeType === 3) {
      const data = (node as Text).data
      if (target && target.node === node) this.hit(this.text.length + Math.min(Math.max(target.offset, 0), data.length))
      this.text += data
      return
    }
    if (node.nodeType !== 1) return
    const el = node as Element
    if (el.localName === "br") {
      if (target && target.node === el) this.hit(this.text.length)
      return
    }
    if (isAtom(el)) {
      const start = this.text.length
      const label = el.textContent ?? ""
      if (target && (target.node === el || el.contains(target.node))) {
        const atStart = target.offset === 0 && (target.node === el || isFirstTextOf(el, target.node))
        this.hit(atStart ? start : start + label.length)
      }
      this.text += label
      return
    }
    if (isBlock(el) && this.text.length > lineStart) this.text += "\n"
    this.children(el, (child) => this.inline(child, lineStart))
  }

  private children(el: Node, visit: (child: Node) => void) {
    const target = this.target
    let index = 0
    for (let child = el.firstChild; child; child = child.nextSibling, index++) {
      if (target && target.node === el && target.offset === index) this.hit(this.text.length)
      visit(child)
    }
    if (target && target.node === el && target.offset >= index) this.hit(this.text.length)
  }

  root(root: Element) {
    const target = this.target
    const atRoot = (index: number) => target !== null && target.node === root && target.offset === index
    let lines = 0
    let loose = false
    const startLine = () => {
      if (lines > 0) this.text += "\n"
      lines++
    }
    let index = 0
    for (let child = root.firstChild; child; child = child.nextSibling, index++) {
      if (isBlock(child)) {
        loose = false
        startLine()
        if (atRoot(index)) this.hit(this.text.length)
        const lineStart = this.text.length
        this.children(child, (c) => this.inline(c, lineStart))
        continue
      }
      if (child.nodeType === 1 && (child as Element).localName === "br") {
        if (atRoot(index)) this.hit(this.text.length)
        if (target && target.node === child) this.hit(this.text.length)
        if (loose) {
          loose = false
          continue
        }
        // A lone br in an empty root, or one trailing after the last block
        // (Firefox adds these), is not a line.
        const last = child.nextSibling === null
        if (root.childNodes.length === 1 || (last && child.previousSibling && isBlock(child.previousSibling))) continue
        startLine()
        continue
      }
      if (!loose) {
        startLine()
        loose = true
      }
      if (atRoot(index)) this.hit(this.text.length)
      this.inline(child, this.text.length)
    }
    if (target && target.node === root && target.offset >= index) this.hit(this.text.length)
  }
}

const isFirstTextOf = (atom: Element, node: Node): boolean => {
  let first: Node | null = atom.firstChild
  while (first && first.nodeType !== 3) first = first.firstChild
  return first === node
}

/** The text the surface shows, as the model would hold it. */
export const readDomText = (root: Element): string => {
  const reader = new Reader(null)
  reader.root(root)
  return reader.text
}

/** The model offset of a DOM point inside `root`, or `null` if it is outside. */
export const domPointToOffset = (root: Element, node: Node, offset: number): number | null => {
  if (node !== root && !root.contains(node)) return null
  const reader = new Reader({ node, offset })
  reader.root(root)
  return reader.found
}

export type DomPoint = { node: Node; offset: number }

/**
 * The DOM point for a model offset, for a surface rendered by `render.ts`.
 * At a boundary between two runs it prefers, in order: the start of plain
 * text, the end of the previous text run, and a position between elements.
 * That keeps the browser typing into the node whose formatting the model
 * would give the new text.
 */
export const offsetToDomPoint = (root: Element, offset: number): DomPoint => {
  let remaining = Math.max(0, offset)
  let lastLine: Element | null = null
  for (let line = root.firstElementChild; line; line = line.nextElementSibling) {
    if (!isLineElement(line)) continue
    lastLine = line
    const length = lineLength(line)
    if (remaining <= length) return pointInLine(line, remaining)
    remaining -= length + 1
  }
  if (lastLine) return pointInLine(lastLine, lineLength(lastLine))
  return { node: root, offset: 0 }
}

const runLength = (node: Node): number =>
  node.nodeType === 3 ? (node as Text).data.length : node.nodeType === 1 && (node as Element).localName !== "br" ? (node.textContent ?? "").length : 0

const lineLength = (line: Element): number => {
  let length = 0
  for (let child = line.firstChild; child; child = child.nextSibling) length += runLength(child)
  return length
}

const textOf = (node: Node): Text | null => {
  if (node.nodeType === 3) return node as Text
  if (node.nodeType === 1 && !isAtom(node) && (node as Element).localName !== "br") {
    const first = node.firstChild
    if (first && first.nodeType === 3) return first as Text
  }
  return null
}

const isPlainText = (node: Node | null): boolean => !!node && node.nodeType === 3

const pointInLine = (line: Element, offset: number): DomPoint => {
  const children: Node[] = []
  for (let child = line.firstChild; child; child = child.nextSibling) {
    if (child.nodeType === 1 && (child as Element).localName === "br") continue
    children.push(child)
  }
  if (children.length === 0) return { node: line, offset: 0 }
  let position = 0
  for (let i = 0; i < children.length; i++) {
    const child = children[i]!
    const length = runLength(child)
    const end = position + length
    if (offset < end || (offset === end && i === children.length - 1)) {
      if (offset === position && i > 0) return boundary(line, children[i - 1]!, child)
      if (offset === position) {
        const text = textOf(child)
        return text ? { node: text, offset: 0 } : { node: line, offset: indexIn(line, child) }
      }
      if (offset === end) {
        const text = textOf(child)
        return text ? { node: text, offset: text.data.length } : { node: line, offset: indexIn(line, child) + 1 }
      }
      const text = textOf(child)
      // Inside an atom cannot happen for a normalized selection; use its end.
      return text ? { node: text, offset: offset - position } : { node: line, offset: indexIn(line, child) + 1 }
    }
    position = end
  }
  const last = children[children.length - 1]!
  return { node: line, offset: indexIn(line, last) + 1 }
}

const boundary = (line: Element, before: Node, after: Node): DomPoint => {
  if (isPlainText(after)) return { node: after, offset: 0 }
  const beforeText = textOf(before)
  if (beforeText) return { node: beforeText, offset: beforeText.data.length }
  const afterText = textOf(after)
  if (afterText) return { node: afterText, offset: 0 }
  return { node: line, offset: indexIn(line, after) }
}

const indexIn = (parent: Node, child: Node): number => {
  let index = 0
  for (let node = parent.firstChild; node && node !== child; node = node.nextSibling) index++
  return index
}

/** The DOM selection mapped to the model, or `null` if it is not inside `root`. */
export const readSelection = (root: Element): Selection | null => {
  const selection = root.ownerDocument.getSelection()
  if (!selection || !selection.anchorNode || !selection.focusNode) return null
  const anchor = domPointToOffset(root, selection.anchorNode, selection.anchorOffset)
  const focus = domPointToOffset(root, selection.focusNode, selection.focusOffset)
  if (anchor === null || focus === null) return null
  return { anchor, focus }
}

/** Put the DOM selection at a model selection. */
export const writeSelection = (root: Element, selection: Selection) => {
  const domSelection = root.ownerDocument.getSelection()
  if (!domSelection) return
  const anchor = offsetToDomPoint(root, selection.anchor)
  const focus = selection.anchor === selection.focus ? anchor : offsetToDomPoint(root, selection.focus)
  if (
    domSelection.anchorNode === anchor.node &&
    domSelection.anchorOffset === anchor.offset &&
    domSelection.focusNode === focus.node &&
    domSelection.focusOffset === focus.offset
  ) {
    return
  }
  if (typeof domSelection.setBaseAndExtent === "function") {
    domSelection.setBaseAndExtent(anchor.node, anchor.offset, focus.node, focus.offset)
    return
  }
  const range = root.ownerDocument.createRange()
  range.setStart(anchor.node, anchor.offset)
  range.collapse(true)
  domSelection.removeAllRanges()
  domSelection.addRange(range)
  if (focus !== anchor) domSelection.extend(focus.node, focus.offset)
}

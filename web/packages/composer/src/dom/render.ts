import { markKey, type Line, type MarkType, type Run } from "../model"

/**
 * Rendering the model to the editable surface. Text goes into the DOM as
 * text nodes only (`createTextNode`, `textContent`); no HTML string is ever
 * parsed. Structure, per line:
 *
 *     <div data-line dir="auto">
 *       text node                          plain text
 *       <span data-marks="bold italic">    marked text, one text node inside
 *       <span data-atom contenteditable="false" data-len="3">   an atom chip
 *       <br data-filler>                   only on an empty line, or after a
 *                                          trailing atom so the caret can sit there
 *     </div>
 *
 * Styling comes from class names the view passes in (StyleX output), keyed
 * by mark type, atom type, `line` and `atom`.
 */

export type ComposerClassNames = Partial<Record<MarkType | "mention" | "groupMention" | "thread" | "line" | "atom" | "link", string>>

export const LINE_ATTR = "data-line"
export const ATOM_ATTR = "data-atom"
export const MARKS_ATTR = "data-marks"
export const FILLER_ATTR = "data-filler"

const marksValue = (run: Extract<Run, { kind: "text" }>) => run.marks.map(markKey).join(" ")

const atomKey = (run: Extract<Run, { kind: "atom" }>) =>
  `${run.entity.type}:${run.entity.userId ?? run.entity.chatId ?? run.entity.groupId ?? ""}`

const addClasses = (el: Element, names: (string | undefined)[]) => {
  for (const name of names) {
    if (!name) continue
    for (const part of name.split(/\s+/)) if (part) el.classList.add(part)
  }
}

export const renderRun = (doc: Document, run: Run, classNames: ComposerClassNames): Node => {
  if (run.kind === "atom") {
    const span = doc.createElement("span")
    span.setAttribute(ATOM_ATTR, atomKey(run))
    span.setAttribute("contenteditable", "false")
    span.setAttribute("data-len", String(run.text.length))
    addClasses(span, [classNames.atom, classNames[run.entity.type as "mention" | "groupMention" | "thread"]])
    span.textContent = run.text
    return span
  }
  if (run.marks.length === 0) return doc.createTextNode(run.text)
  const span = doc.createElement("span")
  span.setAttribute(MARKS_ATTR, marksValue(run))
  addClasses(span, run.marks.map((m) => classNames[m.type]))
  if (run.marks.some((m) => m.type === "textUrl")) addClasses(span, [classNames.link])
  span.appendChild(doc.createTextNode(run.text))
  return span
}

const needsFiller = (line: Line) => {
  const last = line.runs[line.runs.length - 1]
  return !last || last.kind === "atom"
}

export const fillLine = (el: HTMLElement, line: Line, classNames: ComposerClassNames) => {
  const doc = el.ownerDocument
  while (el.firstChild) el.removeChild(el.firstChild)
  for (const run of line.runs) el.appendChild(renderRun(doc, run, classNames))
  if (needsFiller(line)) {
    const br = doc.createElement("br")
    br.setAttribute(FILLER_ATTR, "")
    el.appendChild(br)
  }
}

export const renderLine = (doc: Document, line: Line, classNames: ComposerClassNames): HTMLElement => {
  const el = doc.createElement("div")
  el.setAttribute(LINE_ATTR, "")
  el.setAttribute("dir", "auto")
  addClasses(el, [classNames.line])
  fillLine(el, line, classNames)
  return el
}

export const isLineElement = (node: Node | null | undefined): node is HTMLElement =>
  !!node && node.nodeType === 1 && (node as Element).hasAttribute(LINE_ATTR)

/**
 * Whether a line element shows exactly what the model would render. The
 * browser edits text inside our nodes when the user types; as long as the
 * structure and text still match the model, the line is left untouched.
 */
export const lineMatchesDom = (el: Element, line: Line): boolean => {
  if (!isLineElement(el)) return false
  const nodes: Node[] = []
  for (let child = el.firstChild; child; child = child.nextSibling) {
    if (child.nodeType === 1 && (child as Element).localName === "br") continue
    nodes.push(child)
  }
  if (nodes.length !== line.runs.length) return false
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i]!
    const run = line.runs[i]!
    if (run.kind === "atom") {
      if (node.nodeType !== 1) return false
      const span = node as Element
      if (span.getAttribute(ATOM_ATTR) !== atomKey(run) || span.textContent !== run.text) return false
      continue
    }
    if (run.marks.length === 0) {
      if (node.nodeType !== 3 || (node as Text).data !== run.text) return false
      continue
    }
    if (node.nodeType !== 1) return false
    const span = node as Element
    if (span.localName !== "span" || span.getAttribute(MARKS_ATTR) !== marksValue(run)) return false
    const only = span.firstChild
    if (!only || only !== span.lastChild || only.nodeType !== 3 || (only as Text).data !== run.text) return false
  }
  return true
}

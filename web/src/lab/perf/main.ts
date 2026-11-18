/**
 * Perf lab page: boots the app in demo mode in a same-origin frame, runs the
 * journeys against it and shows the table. Plain DOM, no view framework, no
 * HTML strings. `globalThis.__perfLab` is the state as plain data (a getter,
 * fresh on every read) and `globalThis.__perfLabControl` drives it. See
 * README.md in this folder.
 *
 * Query: `?scale=small|medium|large` (default medium), `seed`, `storage`,
 * `cpu=4` (declare DevTools CPU throttling), `run=all`.
 */

import "./lab.css"
import type { ResultRow } from "./budgets"
import { parseLabParams } from "./environment"
import { JOURNEYS, type JourneyName } from "./journeys"
import { createPerfLab, type PerfLabControl, type PerfLabSnapshot } from "./lab"
import { formatValue, gradeLabel, rowNotes } from "./markdown"

const byId = <T extends HTMLElement>(id: string): T => {
  const element = document.getElementById(id)
  if (!element) throw new Error(`#${id} is missing from lab-perf.html`)
  return element as T
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, className?: string): HTMLElementTagNameMap[K] => {
  const element = document.createElement(tag)
  if (text !== undefined) element.textContent = text
  if (className) element.className = className
  return element
}

const params = parseLabParams(location.search)
const iframe = byId<HTMLIFrameElement>("app")
const status = byId<HTMLParagraphElement>("status")
const warnings = byId<HTMLUListElement>("warnings")
const environment = byId<HTMLParagraphElement>("environment")
const tbody = byId<HTMLTableElement>("results").tBodies[0] as HTMLTableSectionElement
const markdownBox = byId<HTMLTextAreaElement>("markdown")

// Whether the app frame is on screen: an off-screen frame may get no frames.
let frameVisible: boolean | undefined
new IntersectionObserver(
  (entries) => {
    const last = entries[entries.length - 1]
    if (last) frameVisible = last.intersectionRatio >= 0.5
  },
  { threshold: [0, 0.5, 1] },
).observe(iframe)

const renderRow = (row: ResultRow): HTMLTableRowElement => {
  const tr = el("tr")
  if (row.grade === "info") tr.dataset.info = ""
  const moment = el("td", row.moment)
  const measure = el("td", row.measure || "–")
  if (row.method) measure.append(el("span", row.method, "perf-small"))
  const notes = el("td", rowNotes(row) || "")
  tr.append(
    moment,
    measure,
    el("td", row.input),
    el("td", String(row.n), "perf-number"),
    el("td", formatValue(row.median, row.unit), "perf-number"),
    el("td", formatValue(row.worst, row.unit), "perf-number"),
    el("td", row.budget || "–"),
    el("td", gradeLabel(row.grade), `grade-${row.grade}`),
    notes,
  )
  return tr
}

const render = (snapshot: PerfLabSnapshot) => {
  status.textContent = snapshot.message
  status.dataset.state = snapshot.status
  warnings.replaceChildren(...snapshot.warnings.map((warning) => el("li", warning)))
  warnings.hidden = snapshot.warnings.length === 0
  environment.textContent = snapshot.environment ? snapshot.environment.line : ""
  tbody.replaceChildren(...snapshot.rows.map(renderRow))
  if (!markdownBox.hidden) markdownBox.value = snapshot.markdown
}

const lab = createPerfLab({ iframe, params, frameVisible: () => frameVisible, onChange: render })

Object.defineProperty(globalThis, "__perfLab", { configurable: true, get: () => lab.snapshot() })
;(globalThis as { __perfLabControl?: PerfLabControl }).__perfLabControl = lab.control

// ---------------------------------------------------------------------------
// Controls

const LABELS: Record<JourneyName, string> = {
  warmStart: "Warm start",
  switchSqlite: "Switch (SQLite)",
  switchMemory: "Switch (memory)",
  send: "Send",
  typing: "Typing",
  incoming: "Incoming",
  streaming: "Streaming",
  scrollPaging: "Scroll and paging",
  sidebar: "Sidebar",
  initialJs: "Initial JS",
  leaderHandoff: "Leader handoff",
  memory: "Memory",
}

const controls = byId<HTMLDivElement>("controls")
const button = (label: string, run: () => unknown, primary = false) => {
  const b = el("button", label)
  b.type = "button"
  if (primary) b.className = "perf-primary"
  b.addEventListener("click", () => void run())
  return b
}

const copyMarkdown = async () => {
  const text = lab.control.markdown()
  try {
    await navigator.clipboard.writeText(text)
    status.textContent = "Copied the table as Markdown."
  } catch {
    // No clipboard permission: show it to copy by hand.
    markdownBox.hidden = false
    markdownBox.value = text
    markdownBox.select()
    status.textContent = "Clipboard unavailable: the Markdown is in the box below, selected."
  }
}

controls.append(
  button("Run all", () => lab.control.runAll(), true),
  ...JOURNEYS.map((name) => button(LABELS[name], () => lab.control[name]())),
  button("Copy as Markdown", copyMarkdown),
  button("Reload app", () => lab.control.load()),
)

render(lab.snapshot())

// Load the app now, so a first run does not include its first boot; run everything when asked.
void (params.autorun ? lab.control.runAll() : lab.control.load()).catch((error: unknown) => {
  status.textContent = error instanceof Error ? error.message : String(error)
  status.dataset.state = "error"
})

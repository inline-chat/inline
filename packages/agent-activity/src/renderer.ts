import { DocBuilder, type DiffChangeName, type Doc } from "./doc.js"
import { progressFits } from "./limits.js"
import type { ActivityKindName, StatusName } from "./protocol.js"
import {
  MAX_ROW_DIFF_CHARS,
  baseName,
  elapsedText,
  firstLine,
  head,
  redactSecrets,
  relativePath,
  tail,
} from "./text.js"

export type FileChange = {
  path: string
  change?: DiffChangeName
  /** Unified diff lines, or a new file's content. */
  diff?: string
  additions?: number
  deletions?: number
}

export type PlanStep = { text: string; status: "pending" | "in_progress" | "completed" }

/** What one item of work is, in harness-neutral terms. */
export type ItemBody =
  | { kind: "command"; command: string; output?: string; exitCode?: number }
  | { kind: "read"; path: string }
  | { kind: "search"; query?: string; path?: string }
  | { kind: "list"; path?: string }
  | { kind: "edit"; files: FileChange[] }
  | { kind: "web"; query?: string; url?: string }
  | { kind: "tool"; name: string; title?: string; input?: string; output?: string; error?: string }
  | { kind: "agent"; title?: string; meta?: string }
  | { kind: "plan"; steps: PlanStep[]; explanation?: string }
  | { kind: "reasoning"; summary: string }
  | { kind: "note"; text: string }
  | { kind: "compaction" }

export type ItemState = "running" | "waiting" | "done" | "failed" | "cancelled"
export type TurnOutcome = "success" | "failure" | "cancelled"

export type ActivityEvent =
  /** A turn began: Detailed shows "Working" from here, even for a turn that only answers. */
  | { type: "turn.start" }
  /**
   * Starts or updates an item, matched by `id`. A body merges into the
   * previous one of the same kind, so an end event can carry only the
   * output. `parent` nests the item under an `agent` item.
   */
  | { type: "item"; id: string; parent?: string; body?: ItemBody; state?: ItemState; durationMs?: number }
  /** Text the agent wrote between tool calls. */
  | { type: "commentary"; text: string }
  /** An approval or question is waiting on a person (or no longer is). */
  | { type: "waiting"; id?: string; waiting: boolean }
  /** A person's new message arrived mid-turn: the current message ends and later work starts a new one. */
  | { type: "split" }
  | { type: "turn.end"; outcome: TurnOutcome }

export type RenderOp =
  /** Create, or edit, progress message `slot`. `urgent` skips edit coalescing. */
  | { type: "progress"; slot: number; doc: Doc; urgent: boolean }
  /** The last edit of progress message `slot`. */
  | { type: "end"; slot: number; doc: Doc }

type Row = {
  id: string
  parent?: string
  body?: ItemBody
  state: ItemState
  startedAt: number
  durationMs?: number
}

type Slot = { id: number; startedAt: number; rows: Row[] }

export type RendererOptions = {
  /** The work's folder: paths under it show relative, as the harnesses show them. */
  folder?: string
}

const busy = (row: Row) => row.state === "running" || row.state === "waiting"
const status = (state: ItemState): StatusName => state
const exploring = (body: ItemBody | undefined): boolean =>
  body?.kind === "read" || body?.kind === "search" || body?.kind === "list"

/**
 * Turns harness-neutral activity events into progress-message operations,
 * as the Inline CLI bridge draws Codex and Claude Code work: one "Working"
 * message per stretch of work, with a row per item, that closes to "Worked
 * for 1m 4s" before the answer. Pure: callers pass the time and perform the
 * operations (see ProgressPresenter).
 */
export class ProgressRenderer {
  private nextSlot = 1
  private slot: Slot | undefined
  private now = 0
  private notes = 0

  constructor(private readonly options: RendererOptions = {}) {}

  /** Whether a progress message is open. */
  get isOpen(): boolean {
    return this.slot !== undefined
  }

  apply(event: ActivityEvent, at: number = Date.now()): RenderOp[] {
    this.now = at
    const ops: RenderOp[] = []
    switch (event.type) {
      case "turn.start":
        this.openSlot()
        this.pushProgress(ops, true)
        break
      case "item":
        this.item(event)
        this.pushProgress(ops, event.state === "waiting" || event.state === "failed")
        break
      case "commentary": {
        const text = event.text.trim()
        if (!text) break
        this.openSlot()
        this.notes += 1
        this.slot!.rows.push({ id: `note:${this.notes}`, body: { kind: "note", text }, state: "done", startedAt: at })
        this.pushProgress(ops, false)
        break
      }
      case "waiting":
        if (!this.slot) break
        this.markWaiting(event.id, event.waiting)
        this.pushProgress(ops, true)
        break
      case "split":
        this.split(ops)
        break
      case "turn.end":
        this.endTurn(event.outcome, ops)
        break
    }
    return ops
  }

  private openSlot(): void {
    if (!this.slot) this.slot = { id: this.nextSlot++, startedAt: this.now, rows: [] }
  }

  private item(event: Extract<ActivityEvent, { type: "item" }>): void {
    this.openSlot()
    const slot = this.slot!
    let row = slot.rows.find((candidate) => candidate.id === event.id)
    if (!row) {
      row = { id: event.id, state: "running", startedAt: this.now }
      if (event.parent !== undefined) row.parent = event.parent
      slot.rows.push(row)
    }
    if (event.body) row.body = mergeBody(row.body, event.body)
    if (event.state) {
      const ending = !busy({ ...row, state: event.state }) && busy(row)
      row.state = event.state
      if (event.durationMs !== undefined) row.durationMs = event.durationMs
      else if (ending && row.durationMs === undefined) row.durationMs = this.now - row.startedAt
    } else if (event.durationMs !== undefined) {
      row.durationMs = event.durationMs
    }
  }

  private markWaiting(id: string | undefined, waiting: boolean): void {
    const rows = this.slot?.rows ?? []
    const target = id !== undefined
      ? rows.find((row) => row.id === id)
      : [...rows].reverse().find((row) => (waiting ? row.state === "running" : row.state === "waiting"))
    if (!target) return
    if (waiting && target.state === "running") target.state = "waiting"
    else if (!waiting && target.state === "waiting") target.state = "running"
  }

  private split(ops: RenderOp[]): void {
    const slot = this.slot
    if (!slot) return
    const carried = slot.rows.filter(busy)
    const kept = { ...slot, rows: slot.rows.filter((row) => !busy(row)) }
    ops.push({ type: "end", slot: slot.id, doc: this.endedDoc(kept, `Worked for ${elapsedText(this.now - slot.startedAt)}`) })
    this.slot = undefined
    if (carried.length > 0) {
      this.openSlot()
      this.slot!.rows.push(...carried)
      this.pushProgress(ops, true)
    }
  }

  private endTurn(outcome: TurnOutcome, ops: RenderOp[]): void {
    const slot = this.slot
    if (!slot) return
    for (const row of slot.rows) {
      if (!busy(row)) continue
      row.state = outcome === "success" ? "done" : "cancelled"
      row.durationMs ??= this.now - row.startedAt
    }
    const verb = outcome === "cancelled" ? "Stopped after" : outcome === "failure" ? "Failed after" : "Worked for"
    const failed = unresolvedFailures(slot.rows)
    const summary = `${verb} ${elapsedText(this.now - slot.startedAt)}${failed > 0 ? ` · ${failed} failed` : ""}`
    ops.push({ type: "end", slot: slot.id, doc: this.endedDoc(slot, summary) })
    this.slot = undefined
  }

  /** Emits the open message; near a server limit, ends it with the finished rows that fit and continues in a new one. */
  private pushProgress(ops: RenderOp[], urgent: boolean): void {
    if (!this.slot) return
    let doc = this.progressDoc(this.slot)
    if (!progressFits(doc) && this.splitForSize(ops)) doc = this.progressDoc(this.slot)
    ops.push({ type: "progress", slot: this.slot.id, doc, urgent })
  }

  private splitForSize(ops: RenderOp[]): boolean {
    const slot = this.slot!
    const summary = `Worked for ${elapsedText(this.now - slot.startedAt)} · continued below`
    const tops = slot.rows.filter((row) => topLevel(row, slot.rows))
    let finished = 0
    while (finished < tops.length && !busy(tops[finished]!)) finished += 1
    const fits = (count: number) => progressFits(this.endedDoc(subset(slot, tops.slice(0, count)), summary))
    let low = 0
    let high = finished
    while (low < high) {
      const middle = Math.ceil((low + high) / 2)
      if (fits(middle)) low = middle
      else high = middle - 1
    }
    if (low === 0) return false
    const kept = subset(slot, tops.slice(0, low))
    ops.push({ type: "end", slot: slot.id, doc: this.endedDoc(kept, summary) })
    this.slot = {
      id: this.nextSlot++,
      startedAt: this.now,
      rows: slot.rows.filter((row) => !kept.rows.includes(row)),
    }
    return true
  }

  private progressDoc(slot: Slot): Doc {
    const builder = new DocBuilder()
    builder.progress(
      "Working",
      true,
      { startedAtSeconds: slot.startedAt / 1000, text: elapsedText(this.now - slot.startedAt) },
      (inner) => this.writeSlot(inner, slot),
    )
    return builder.finish()
  }

  /** Closed under its summary; a quiet footer line when nothing but the answer happened. */
  private endedDoc(slot: Slot, summary: string): Doc {
    const builder = new DocBuilder()
    const rows = new DocBuilder()
    this.writeSlot(rows, slot)
    if (rows.isEmpty()) builder.footer(summary)
    else builder.progress(summary, false, undefined, (inner) => this.writeSlot(inner, slot))
    return builder.finish()
  }

  /** Top-level rows in phases and runs: a reasoning summary heads the work after it, and runs of reads, finished commands and edits fold. */
  private writeSlot(builder: DocBuilder, slot: Slot): void {
    const rows = slot.rows.filter((row) => topLevel(row, slot.rows) && shows(row))
    let start = 0
    while (start < rows.length) {
      let end = start + 1
      while (end < rows.length && !startsPhase(rows[end]!)) end += 1
      const first = rows[start]!
      if (startsPhase(first) && end > start + 1) this.writePhase(builder, slot, first, rows.slice(start + 1, end))
      else if (startsPhase(first)) this.writeRow(builder, slot, first)
      else this.writeRuns(builder, slot, rows.slice(start, end))
      start = end
    }
  }

  private writePhase(builder: DocBuilder, slot: Slot, headRow: Row, rows: Row[]): void {
    const text = headRow.body?.kind === "reasoning" ? headRow.body.summary : ""
    const title = firstLine(text, 80)
    const running = [headRow, ...rows].some(busy)
    builder.disclosure(title, { activity: "reasoning", status: running ? "running" : "done" }, (inner) => {
      if (text.trim() !== title) inner.paragraph(tail(text))
      this.writeRuns(inner, slot, rows)
    })
  }

  private writeRuns(builder: DocBuilder, slot: Slot, rows: Row[]): void {
    let index = 0
    while (index < rows.length) {
      const fold = foldOf(rows[index]!)
      let end = index + 1
      if (fold !== "none") while (end < rows.length && foldOf(rows[end]!) === fold) end += 1
      const run = rows.slice(index, end)
      if (fold === "explore") this.writeExplore(builder, run)
      else if (fold === "command" && run.length > 1) this.writeCommands(builder, slot, run)
      else if (fold === "edit" && run.length > 1) this.writeEdits(builder, slot, run)
      else for (const row of run) this.writeRow(builder, slot, row)
      index = end
    }
  }

  /** Codex's "Explored" row: consecutive reads merge into one "Read a, b". */
  private writeExplore(builder: DocBuilder, run: Row[]): void {
    const running = run.some(busy)
    const failed = run.filter((row) => row.state === "failed").length
    const lines: string[] = []
    let reads: string[] = []
    const flush = () => {
      if (reads.length > 0) lines.push(`Read ${reads.join(", ")}`)
      reads = []
    }
    for (const row of run) {
      const body = row.body
      const suffix = row.state === "failed" ? " (failed)" : ""
      if (body?.kind === "read") {
        if (row.state === "failed") {
          flush()
          lines.push(`Read ${this.path(body.path)}${suffix}`)
        } else {
          const name = baseName(body.path)
          if (!reads.includes(name)) reads.push(name)
        }
      } else if (body?.kind === "search") {
        flush()
        const query = body.query ? redactSecrets(firstLine(body.query, 80)) : undefined
        const where = body.path ? this.path(body.path) : undefined
        lines.push(`${query && where ? `Search ${query} in ${where}` : query ? `Search ${query}` : where ? `Search in ${where}` : "Search"}${suffix}`)
      } else if (body?.kind === "list") {
        flush()
        lines.push(`List ${body.path ? this.path(body.path) : "."}${suffix}`)
      }
    }
    flush()
    builder.disclosure(
      running ? "Exploring" : "Explored",
      { activity: "explore", status: running ? "running" : "done", ...(failed > 0 ? { meta: `${failed} failed` } : {}) },
      (inner) => {
        for (const line of lines) inner.paragraph(line)
      },
    )
  }

  private writeCommands(builder: DocBuilder, slot: Slot, run: Row[]): void {
    const total = run.reduce((sum, row) => sum + (row.durationMs ?? 0), 0)
    builder.disclosure(
      `Ran ${run.length} commands`,
      { activity: "command", status: "done", ...(total > 0 ? { meta: elapsedText(Math.max(total, 1000)) } : {}) },
      (inner) => {
        for (const row of run) this.writeRow(inner, slot, row)
      },
    )
  }

  private writeEdits(builder: DocBuilder, slot: Slot, run: Row[]): void {
    const files = run.flatMap((row) => (row.body?.kind === "edit" ? row.body.files : []))
    const { added, removed } = files.reduce((sum, file) => {
      const counts = lineCounts(file)
      return { added: sum.added + counts.added, removed: sum.removed + counts.removed }
    }, { added: 0, removed: 0 })
    const count = new Set(files.map((file) => file.path)).size
    const meta = countsMeta(added, removed)
    builder.disclosure(
      count === 1 ? "Edited 1 file" : `Edited ${count} files`,
      { activity: "edit", status: "done", ...(meta ? { meta } : {}) },
      (inner) => {
        for (const row of run) this.writeRow(inner, slot, row)
      },
    )
  }

  private writeRow(builder: DocBuilder, slot: Slot, row: Row): void {
    const body = row.body
    if (body?.kind === "note") {
      builder.paragraph(body.text)
      return
    }
    const { title, meta, activity } = this.rowTitle(row)
    const children = body?.kind === "agent"
      ? slot.rows.filter((candidate) => candidate.parent === row.id && shows(candidate))
      : []
    builder.disclosure(title, { activity, status: status(row.state), ...(meta ? { meta } : {}) }, (inner) => {
      this.rowDetail(inner, row)
      if (children.length > 0) this.writeRuns(inner, slot, children)
    })
  }

  private rowTitle(row: Row): { title: string; meta?: string; activity: ActivityKindName } {
    const body = row.body
    const running = busy(row)
    const time = !running && row.durationMs !== undefined ? elapsedText(Math.max(row.durationMs, 1000)) : undefined
    switch (body?.kind) {
      case "command": {
        const code = body.exitCode !== undefined && body.exitCode !== 0 ? `exit ${body.exitCode}` : undefined
        const meta = [code, time].filter(Boolean).join(" · ") || undefined
        const command = firstLine(redactSecrets(body.command), 80)
        return { title: `${running ? "Running" : "Ran"} ${command}`.trim(), ...(meta ? { meta } : {}), activity: "command" }
      }
      case "read":
        return { title: `Read ${this.path(body.path)}`, activity: "read" }
      case "search":
        return { title: body.query ? `Search ${redactSecrets(firstLine(body.query, 80))}` : "Search", activity: "search" }
      case "list":
        return { title: `List ${body.path ? this.path(body.path) : "."}`, activity: "explore" }
      case "edit": {
        const [only, ...rest] = body.files
        const verb = (change?: DiffChangeName) =>
          change === "added" ? "Added" : change === "deleted" ? "Deleted" : change === "renamed" ? "Renamed" : "Edited"
        const title = only && rest.length === 0
          ? `${verb(only.change)} ${this.path(only.path)}`
          : `Edited ${body.files.length} files`
        const { added, removed } = body.files.reduce((sum, file) => {
          const counts = lineCounts(file)
          return { added: sum.added + counts.added, removed: sum.removed + counts.removed }
        }, { added: 0, removed: 0 })
        const meta = countsMeta(added, removed)
        const deletes = body.files.length > 0 && body.files.every((file) => file.change === "deleted")
        return { title, ...(meta ? { meta } : {}), activity: deletes ? "delete" : "edit" }
      }
      case "web":
        if (body.query) return { title: `Searched the web for ${redactSecrets(firstLine(body.query, 80))}`, activity: "web" }
        return { title: body.url ? `Read ${redactSecrets(shortUrl(body.url))}` : "Browsed the web", activity: "web" }
      case "tool": {
        const title = firstLine(redactSecrets(body.title || body.name), 90)
        return { title, ...(time ? { meta: time } : {}), activity: "tool" }
      }
      case "agent": {
        const title = body.title ? `Sub-agent: ${firstLine(redactSecrets(body.title), 70)}` : "Sub-agent"
        return { title, ...(body.meta ? { meta: body.meta } : time ? { meta: time } : {}), activity: "agent" }
      }
      case "plan":
        return { title: "Updated plan", activity: "unspecified" }
      case "reasoning":
        return { title: firstLine(body.summary, 80) || "Thinking", activity: "reasoning" }
      case "compaction":
        return { title: running ? "Compacting the conversation" : "Compacted the conversation", activity: "tool" }
      default:
        return { title: "Working", activity: "unspecified" }
    }
  }

  /** The expanded view: output, diffs, plans and tool payloads, bounded. */
  private rowDetail(builder: DocBuilder, row: Row): void {
    const body = row.body
    switch (body?.kind) {
      case "command":
        builder.code(`$ ${head(redactSecrets(body.command))}`, "sh")
        if (body.output) builder.code(tail(redactSecrets(body.output)))
        if (body.exitCode !== undefined && body.exitCode !== 0) builder.paragraph(`Exit code ${body.exitCode}`)
        break
      case "edit": {
        let shown = 0
        for (const file of body.files) {
          const diff = file.diff && shown < MAX_ROW_DIFF_CHARS ? tail(file.diff) : undefined
          shown += diff?.length ?? 0
          const counts = {
            ...(file.additions !== undefined ? { additions: file.additions } : {}),
            ...(file.deletions !== undefined ? { deletions: file.deletions } : {}),
          }
          builder.diff(this.path(file.path), file.change ?? "modified", diff, counts)
        }
        break
      }
      case "tool":
        if (body.input) builder.code(tail(redactSecrets(body.input)))
        if (body.output) builder.code(tail(redactSecrets(body.output)))
        if (body.error) builder.paragraph(redactSecrets(firstLine(body.error, 500)))
        break
      case "plan":
        if (body.explanation) builder.paragraph(body.explanation)
        builder.steps(body.steps.map((step) => ({
          text: step.text,
          status: step.status === "completed" ? "done" : step.status === "in_progress" ? "running" : "none",
        })))
        break
      case "reasoning": {
        const title = firstLine(body.summary, 80)
        if (body.summary.trim() !== title) builder.paragraph(tail(body.summary))
        break
      }
      default:
        break
    }
  }

  private path(path: string): string {
    return relativePath(path, this.options.folder)
  }
}

function mergeBody(previous: ItemBody | undefined, next: ItemBody): ItemBody {
  if (!previous || previous.kind !== next.kind) return next
  const merged: Record<string, unknown> = { ...previous }
  for (const [key, value] of Object.entries(next)) if (value !== undefined) merged[key] = value
  return merged as ItemBody
}

function topLevel(row: Row, rows: readonly Row[]): boolean {
  return row.parent === undefined || !rows.some((candidate) => candidate.id === row.parent && candidate.body?.kind === "agent")
}

/** Reasoning with no summary has nothing to show. */
function shows(row: Row): boolean {
  if (!row.body) return busy(row)
  return !(row.body.kind === "reasoning" && row.body.summary.trim() === "")
}

function startsPhase(row: Row): boolean {
  return row.body?.kind === "reasoning" && row.body.summary.trim() !== ""
}

type Fold = "explore" | "command" | "edit" | "none"

function foldOf(row: Row): Fold {
  if (exploring(row.body)) return "explore"
  if (row.body?.kind === "command" && row.state === "done" && (row.body.exitCode ?? 0) === 0) return "command"
  if (row.body?.kind === "edit" && row.state === "done") return "edit"
  return "none"
}

/** Failed commands and tools that no later run of the same one fixed. */
function unresolvedFailures(rows: readonly Row[]): number {
  const keyed = rows.flatMap((row) => {
    const body = row.body
    if (body?.kind === "command") {
      const failed = row.state === "failed" || (body.exitCode !== undefined && body.exitCode !== 0)
      return [{ key: `command:${body.command}`, failed }]
    }
    if (body?.kind === "tool") return [{ key: `tool:${body.name}:${body.title ?? ""}`, failed: row.state === "failed" }]
    return []
  })
  return keyed.filter((entry, index) => entry.failed && !keyed.slice(index + 1).some((later) => later.key === entry.key && !later.failed)).length
}

function subset(slot: Slot, tops: readonly Row[]): Slot {
  const keep = new Set<Row>(tops)
  const parents = tops.filter((row) => row.body?.kind === "agent").map((row) => row.id)
  while (parents.length > 0) {
    const parent = parents.pop()!
    for (const row of slot.rows) {
      if (!keep.has(row) && row.parent === parent) {
        keep.add(row)
        if (row.body?.kind === "agent") parents.push(row.id)
      }
    }
  }
  return { ...slot, rows: slot.rows.filter((row) => keep.has(row)) }
}

/** Lines added and removed, as Codex counts a change. */
function lineCounts(file: FileChange): { added: number; removed: number } {
  if (file.additions !== undefined || file.deletions !== undefined) {
    return { added: file.additions ?? 0, removed: file.deletions ?? 0 }
  }
  if (!file.diff) return { added: 0, removed: 0 }
  const lines = file.diff.split("\n")
  const hunks = lines.some((line) => line.startsWith("@@"))
  if (file.change === "added" && !hunks) return { added: lines.length, removed: 0 }
  if (file.change === "deleted" && !hunks) return { added: 0, removed: lines.length }
  let added = 0
  let removed = 0
  for (const line of lines) {
    if (line.startsWith("+++") || line.startsWith("---")) continue
    if (line.startsWith("+")) added += 1
    else if (line.startsWith("-")) removed += 1
  }
  return { added, removed }
}

function countsMeta(added: number, removed: number): string | undefined {
  return added + removed > 0 ? `+${added} −${removed}` : undefined
}

function shortUrl(url: string): string {
  try {
    const parsed = new URL(url)
    const path = parsed.pathname === "/" ? "" : parsed.pathname
    return firstLine(`${parsed.host}${path}`, 80)
  } catch {
    return firstLine(url, 80)
  }
}

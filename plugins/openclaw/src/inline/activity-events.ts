import type { ActivityEvent, FileChange, ItemBody, ItemState, PlanStep, TurnOutcome } from "../vendor/agent-activity/index.js"

/** Only explicit host lifecycle metadata can identify a cancelled turn. */
export function activityLifecycleOutcome(data: Record<string, unknown>): TurnOutcome | undefined {
  if (data.phase !== "end" && data.phase !== "error") return undefined
  if (data.aborted === true) return data.stopReason === "timeout" ? "failure" : "cancelled"
  return data.phase === "error" ? "failure" : "success"
}

/** Readable titles for tools without a richer row; never derived from arguments or output. */
const TOOL_TITLES: Record<string, string> = {
  execute_code: "Running code", code_execution: "Running code",
  read: "Reading a file", read_file: "Reading a file", write: "Writing a file", write_file: "Writing a file",
  edit: "Editing a file", apply_patch: "Editing files", web_search: "Searching the web",
  web_fetch: "Reading a web page", browser: "Using the browser", image: "Inspecting an image",
  view_image: "Inspecting an image", memory_search: "Searching memory", memory_get: "Reading memory",
  skills_search: "Searching skills", skills_read: "Reading a skill", process: "Checking a command",
}

const COMMAND_TOOLS = new Set(["exec", "bash", "shell", "terminal"])
const SEARCH_TOOLS = new Set(["grep", "rg", "search", "glob", "find"])
const LIST_TOOLS = new Set(["ls", "list", "list_dir", "list_files"])
const AGENT_TOOLS = new Set(["sessions_spawn", "subagent", "spawn_agent", "agent", "task"])
const HIDDEN_COMMAND = "a command"
const MAX_OUTPUT_BUFFER = 8_000

export type OpenClawActivityOptions = {
  /** `streaming.progress.commandText: "status"`: rows say "a command" and show no command text or output. */
  hideCommandText?: boolean | undefined
}

export type OpenClawToolStart = {
  itemId?: string | undefined
  toolCallId?: string | undefined
  name?: string | undefined
  phase?: string | undefined
  args?: Record<string, unknown> | undefined
}

export type OpenClawItemEvent = {
  itemId?: string | undefined
  toolCallId?: string | undefined
  kind?: string | undefined
  title?: string | undefined
  name?: string | undefined
  phase?: string | undefined
  status?: string | undefined
  summary?: string | undefined
  progressText?: string | undefined
  meta?: string | undefined
  approvalId?: string | undefined
  hideFromChannelProgress?: boolean | undefined
  suppressChannelProgress?: boolean | undefined
}

export type OpenClawCommandOutput = {
  itemId?: string | undefined
  toolCallId?: string | undefined
  phase?: string | undefined
  name?: string | undefined
  output?: string | undefined
  status?: string | undefined
  exitCode?: number | null | undefined
  durationMs?: number | undefined
}

export type OpenClawPatchSummary = {
  itemId?: string | undefined
  toolCallId?: string | undefined
  phase?: string | undefined
  added?: string[] | undefined
  modified?: string[] | undefined
  deleted?: string[] | undefined
}

export type OpenClawPlanUpdate = {
  phase?: string | undefined
  explanation?: string | undefined
  steps?: ReadonlyArray<{ step?: string; status?: string } | string> | undefined
}

export type OpenClawApprovalEvent = {
  phase?: string | undefined
  itemId?: string | undefined
  toolCallId?: string | undefined
}

type RowInfo = { name?: string; commandText?: string; output: string; busy: boolean }

/**
 * Turns one turn's OpenClaw reply callbacks into renderer events: one row per
 * tool call, keyed by its tool call ID so the start, item, output and patch
 * callbacks for a call land on the same row. Titles come from tool names and
 * the agent's explicit descriptions, never from command output.
 */
// The Claude Code runtime reaches OpenClaw tools over MCP, so they arrive as
// `mcp__openclaw__exec`; title and correlate them as `exec`.
const OPENCLAW_MCP_TOOL_PREFIX = /^mcp__openclaw__/

function openClawToolName(name: string | undefined): string | undefined {
  return name?.trim().replace(OPENCLAW_MCP_TOOL_PREFIX, "") || undefined
}

export class OpenClawActivityMapper {
  private readonly rows = new Map<string, RowInfo>()
  private readonly aliases = new Map<string, string>()
  private readonly hidden = new Set<string>()
  private generated = 0
  private compactions = 0

  constructor(private readonly options: OpenClawActivityOptions = {}) {}

  toolStart(payload: OpenClawToolStart): ActivityEvent[] {
    const name = openClawToolName(payload.name)
    if (!name) return []
    const id = this.rowId(payload.toolCallId, payload.itemId, name)
    if (this.hidden.has(id)) return []
    this.row(id, name)
    return [{ type: "item", id, body: this.toolBody(id, name, payload.args ?? {}), state: "running" }]
  }

  item(payload: OpenClawItemEvent): ActivityEvent[] {
    payload = { ...payload, name: openClawToolName(payload.name) }
    if (payload.kind === "preamble") {
      const text = payload.progressText?.trim()
      return text ? [{ type: "commentary", text }] : []
    }
    const id = this.rowId(payload.toolCallId, payload.itemId, payload.name, payload.phase === "end")
    if (payload.hideFromChannelProgress || payload.suppressChannelProgress) {
      this.hidden.add(id)
      return []
    }
    if (this.hidden.has(id)) return []
    const known = this.rows.has(id)
    const row = this.row(id, payload.name)
    const state = itemState(payload.phase, payload.status, payload.approvalId)
    row.busy = state === "running" || state === "waiting"
    if (known) return [{ type: "item", id, state }]
    return [{ type: "item", id, body: this.itemBody(payload, row), state }]
  }

  commandOutput(payload: OpenClawCommandOutput): ActivityEvent[] {
    payload = { ...payload, name: openClawToolName(payload.name) }
    const id = this.rowId(payload.toolCallId, payload.itemId, payload.name, payload.phase === "end")
    if (this.hidden.has(id)) return []
    const row = this.row(id, payload.name)
    const hide = this.options.hideCommandText === true
    if (payload.phase !== "end") {
      if (!hide && payload.output) row.output = (row.output + payload.output).slice(-MAX_OUTPUT_BUFFER)
      return row.output && !hide ? [{ type: "item", id, body: { kind: "command", command: this.commandOf(id), output: row.output } }] : []
    }
    const output = hide ? undefined : (payload.output ?? row.output) || undefined
    const exitCode = typeof payload.exitCode === "number" ? payload.exitCode : undefined
    const failed = payload.status === "failed" || payload.status === "error" || (exitCode !== undefined && exitCode !== 0)
    row.busy = false
    return [{
      type: "item",
      id,
      body: {
        kind: "command",
        command: this.commandOf(id),
        ...(output !== undefined ? { output: output.slice(-MAX_OUTPUT_BUFFER) } : {}),
        ...(exitCode !== undefined ? { exitCode } : {}),
      },
      state: failed ? "failed" : "done",
      ...(typeof payload.durationMs === "number" && Number.isFinite(payload.durationMs) ? { durationMs: payload.durationMs } : {}),
    }]
  }

  patchSummary(payload: OpenClawPatchSummary): ActivityEvent[] {
    const files: FileChange[] = [
      ...(payload.added ?? []).map((path): FileChange => ({ path, change: "added" })),
      ...(payload.modified ?? []).map((path): FileChange => ({ path, change: "modified" })),
      ...(payload.deleted ?? []).map((path): FileChange => ({ path, change: "deleted" })),
    ].filter((file) => file.path.trim() !== "")
    if (files.length === 0) return []
    const id = this.rowId(payload.toolCallId, payload.itemId, "apply_patch", payload.phase === "end")
    if (this.hidden.has(id)) return []
    const row = this.row(id, "apply_patch")
    const ending = payload.phase === "end"
    if (ending) row.busy = false
    return [{ type: "item", id, body: { kind: "edit", files }, ...(ending ? { state: "done" as const } : {}) }]
  }

  plan(payload: OpenClawPlanUpdate): ActivityEvent[] {
    if (payload.phase !== undefined && payload.phase !== "update") return []
    const steps = (payload.steps ?? []).flatMap((step): PlanStep[] => {
      const text = (typeof step === "string" ? step : step.step ?? "").trim()
      if (!text) return []
      const status = typeof step === "string" ? "pending" : step.status
      return [{ text, status: status === "completed" ? "completed" : status === "in_progress" ? "in_progress" : "pending" }]
    })
    const explanation = payload.explanation?.trim()
    if (steps.length === 0 && !explanation) return []
    // Later updates edit the plan row in place; after a reply it starts anew below.
    return [{
      type: "item",
      id: "plan",
      body: { kind: "plan", steps, ...(explanation ? { explanation } : {}) },
      state: "done",
    }]
  }

  approval(payload: OpenClawApprovalEvent): ActivityEvent[] {
    const key = payload.toolCallId ?? payload.itemId
    const id = key !== undefined ? this.aliases.get(key) ?? key : undefined
    const known = id !== undefined && this.rows.has(id)
    const waiting = payload.phase === "requested"
    return [{ type: "waiting", ...(known ? { id } : {}), waiting }]
  }

  compactionStart(): ActivityEvent[] {
    this.compactions += 1
    return [{ type: "item", id: `compaction:${this.compactions}`, body: { kind: "compaction" }, state: "running" }]
  }

  compactionEnd(payload?: { completed?: boolean }): ActivityEvent[] {
    if (this.compactions === 0) this.compactions = 1
    return [{
      type: "item",
      id: `compaction:${this.compactions}`,
      body: { kind: "compaction" },
      state: payload?.completed === false ? "failed" : "done",
    }]
  }

  private rowId(toolCallId: string | undefined, itemId: string | undefined, name: string | undefined, ending = false): string {
    if (toolCallId) {
      if (itemId) this.aliases.set(itemId, toolCallId)
      return toolCallId
    }
    if (itemId) return this.aliases.get(itemId) ?? itemId
    // Hosts without IDs: an end event closes the latest open row of the same tool.
    if (ending && name) {
      const open = [...this.rows.entries()].reverse().find(([, row]) => row.busy && row.name === name)
      if (open) return open[0]
    }
    this.generated += 1
    return `item:${this.generated}`
  }

  private row(id: string, name: string | undefined): RowInfo {
    let row = this.rows.get(id)
    if (!row) {
      row = { output: "", busy: true, ...(name ? { name } : {}) }
      this.rows.set(id, row)
    } else if (name && !row.name) {
      row.name = name
    }
    return row
  }

  private commandOf(id: string): string {
    return this.rows.get(id)?.commandText ?? HIDDEN_COMMAND
  }

  private toolBody(id: string, name: string, args: Record<string, unknown>): ItemBody {
    const tool = name.toLowerCase()
    const text = (...keys: string[]) => {
      for (const key of keys) {
        const value = args[key]
        if (typeof value === "string" && value.trim()) return value.trim()
      }
      return undefined
    }
    const description = text("description", "title")
    if (COMMAND_TOOLS.has(tool)) {
      const command = this.options.hideCommandText ? undefined : text("command", "cmd", "script")
      const row = this.rows.get(id)
      if (row && command) row.commandText = command
      return { kind: "command", command: command ?? HIDDEN_COMMAND }
    }
    if (tool === "read" || tool === "read_file") {
      const path = text("path", "file_path", "filePath", "file")
      if (path) return { kind: "read", path }
    }
    if (tool === "write" || tool === "write_file" || tool === "edit") {
      const path = text("path", "file_path", "filePath", "file")
      if (path) return { kind: "edit", files: [{ path, change: "modified" }] }
    }
    if (SEARCH_TOOLS.has(tool)) {
      const query = text("pattern", "query", "glob")
      const path = text("path", "dir", "directory")
      return { kind: "search", ...(query ? { query } : {}), ...(path ? { path } : {}) }
    }
    if (LIST_TOOLS.has(tool)) {
      const path = text("path", "dir", "directory")
      return { kind: "list", ...(path ? { path } : {}) }
    }
    if (tool === "web_search") {
      const query = text("query", "q")
      if (query) return { kind: "web", query }
    }
    if (tool === "web_fetch" || tool === "browser") {
      const url = text("url")
      if (url) return { kind: "web", url }
    }
    if (AGENT_TOOLS.has(tool)) {
      const title = text("label", "taskName", "description", "task")
      return { kind: "agent", ...(title ? { title } : {}) }
    }
    return { kind: "tool", name, title: description ?? toolTitle(name) }
  }

  /** Bodies for items the host reported without a tool start. */
  private itemBody(payload: OpenClawItemEvent, row: RowInfo): ItemBody {
    const name = payload.name?.trim() || row.name
    if (payload.kind === "command" || (name && COMMAND_TOOLS.has(name.toLowerCase()))) {
      return { kind: "command", command: HIDDEN_COMMAND }
    }
    if (payload.toolCallId || (name && payload.kind === "tool")) {
      return { kind: "tool", name: name ?? "tool", title: name ? toolTitle(name) : "Using a tool" }
    }
    // Items that are not tool calls carry harness-authored titles ("Checking inputs").
    const title = firstLine(payload.title) ?? firstLine(payload.summary) ?? (name ? toolTitle(name) : "Working")
    return { kind: "tool", name: name ?? payload.kind ?? "item", title }
  }
}

function itemState(phase: string | undefined, status: string | undefined, approvalId: string | undefined): ItemState {
  const normalized = status?.trim().toLowerCase()
  if (normalized === "blocked") return approvalId ? "waiting" : phase === "end" ? "failed" : "waiting"
  if (phase !== "end") return "running"
  if (normalized === "failed" || normalized === "error" || normalized === "failure") return "failed"
  if (normalized === "skipped" || normalized === "cancelled" || normalized === "canceled" || normalized === "aborted") return "cancelled"
  return "done"
}

export function toolTitle(name: string): string {
  const known = TOOL_TITLES[name.toLowerCase()]
  if (known) return known
  if (COMMAND_TOOLS.has(name.toLowerCase())) return "Running a script"
  const words = name.replace(/^mcp__/, "").replace(/__/g, " ").replace(/[_-]+/g, " ").trim()
  return words ? `${words[0]!.toUpperCase()}${words.slice(1)}` : "Using a tool"
}

function firstLine(text: string | undefined): string | undefined {
  const line = text?.split("\n").find((candidate) => candidate.trim() !== "")?.trim()
  return line ? line.slice(0, 120) : undefined
}

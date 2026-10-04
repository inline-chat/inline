export type ActivityLine = string | {
  text: string
  id?: string
  status?: string
  detail?: string
  label?: string
  toolName?: string
  kind?: string
  activityTitle?: string
}
export type ActivityOutcome = "success" | "failure" | "cancelled"

export const ACTIVITY_MESSAGE_MAX_CHARS = 3700
const ACTIVITY_PREVIEW_MAX_CHARS = 1200

function truncatePreview(value: string, limit: number): string {
  if (value.length <= limit) return value
  let end = Math.max(0, limit - 1)
  // Keep surrogate pairs intact when a preview contains emoji.
  if (end > 0 && /[\uD800-\uDBFF]/.test(value[end - 1]!)) end -= 1
  return `${value.slice(0, end)}…`
}

/** Only explicit host lifecycle metadata can identify a cancelled turn. */
export function activityLifecycleOutcome(data: Record<string, unknown>): ActivityOutcome | undefined {
  if (data.phase !== "end" && data.phase !== "error") return undefined
  if (data.aborted === true) return data.stopReason === "timeout" ? "failure" : "cancelled"
  return data.phase === "error" ? "failure" : "success"
}

const TOOL_TITLES: Record<string, string> = {
  exec: "Running a script", bash: "Running a script", shell: "Running a script", terminal: "Running a script", execute_code: "Running code",
  read: "Reading a file", read_file: "Reading a file", write: "Writing a file", write_file: "Writing a file",
  edit: "Editing a file", apply_patch: "Editing files", web_search: "Searching the web",
  web_fetch: "Reading a web page", browser: "Using the browser", image: "Inspecting an image",
}

export function activityTitle(line: ActivityLine | undefined): string {
  if (!line) return "Working"
  // Strings are adapter-authored statuses, not tool output. Structured tool
  // events never derive intent from commands or arbitrary log content.
  if (typeof line === "string") return line.replace(/\s+/g, " ").trim().slice(0, 100) || "Working"
  if (line.kind === "approval") return "Waiting for approval"
  const explicit = line.activityTitle?.replace(/\s+/g, " ").trim()
  if (explicit) return explicit.slice(0, 100)
  if (line.toolName) return TOOL_TITLES[line.toolName.toLowerCase()] || "Using a tool"
  if (line.kind === "patch") return "Updating files"
  if (line.kind === "plan") return "Planning the next steps"
  if (line.kind === "command-output") return "Running a script"
  return "Working"
}

export function activityAttention(lines: ReadonlyArray<ActivityLine>): { failed: boolean; stopped: boolean } {
  let failed = false, stopped = false
  for (const line of lines) {
    const status = typeof line === "string" ? "" : line.status?.trim().toLowerCase() || ""
    failed ||= /^(error|failed|failure|blocked|exit -?[1-9]\d*)$/.test(status)
    stopped ||= /^(interrupted|cancelled|canceled|aborted|stopped)$/.test(status)
  }
  return { failed, stopped }
}

/** Preserve presentation metadata when the host merges a completion into a tool row. */
export function preserveActivityTitles(previous: ReadonlyArray<ActivityLine>, next: ActivityLine[]): void {
  if (previous.length !== next.length) return
  for (let index = 0; index < next.length; index++) {
    const before = previous[index], after = next[index]
    // The host has already correlated this replacement by its stable ID/key.
    if (before && after && before !== after && typeof before !== "string" && typeof after !== "string" && before.activityTitle && !after.activityTitle) {
      after.activityTitle = before.activityTitle
    }
  }
}

export function formatQuietTimeline(
  lines: ReadonlyArray<ActivityLine>, working: boolean, elapsedSeconds?: number,
  outcome: ActivityOutcome = "success", recordedToolFailure = false,
  maxLineChars = ACTIVITY_PREVIEW_MAX_CHARS,
): string {
  const previewLimit = Math.max(1, Math.min(ACTIVITY_PREVIEW_MAX_CHARS, Math.floor(maxLineChars) || ACTIVITY_PREVIEW_MAX_CHARS))
  const text = lines.map((line) => {
    if (typeof line === "string") return line
    const status = line.status && !line.text.includes(line.status) ? `: ${line.status}` : ""
    const detail = line.detail && !line.text.includes(line.detail) ? ` — ${line.detail}` : ""
    return `${line.text}${status}${detail}`
  }).filter(Boolean)
  const escape = (value: string) => value.replace(/[\\`*_{}[\]<>#!|]/g, "\\$&")
  const attention = activityAttention(lines)
  const terminal = outcome === "cancelled" ? "Stopped after"
    : outcome === "failure" ? "Failed after" : "Worked for"
  const summary = working ? activityTitle(lines.at(-1))
    : `${elapsedSeconds === undefined ? terminal.split(" ")[0] : `${terminal} ${formatWorkDuration(elapsedSeconds)}`}${terminal === "Worked for" && (attention.failed || recordedToolFailure) ? " · tool error recorded" : ""}`
  // Cap the source before escaping so previews cannot split an escape sequence.
  // Escaping can at most double this budget; one step still fits in a row.
  const body = text.length ? text.map((line) => `- ${escape(truncatePreview(line, previewLimit))}`).join("\n") : "No tool preview supplied."
  return `<details>\n<summary${working ? ' kind="progress"' : ""} activity="agent">${escape(summary)}</summary>\n\n${body}\n\n</details>`
}

export function formatWorkDuration(seconds: number): string {
  const total = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0
  if (total < 1) return "less than 1s"
  const hours = Math.floor(total / 3600), minutes = Math.floor((total % 3600) / 60), remainder = total % 60
  return [hours ? `${hours}h` : "", minutes ? `${minutes}m` : "", remainder ? `${remainder}s` : ""].filter(Boolean).join(" ")
}

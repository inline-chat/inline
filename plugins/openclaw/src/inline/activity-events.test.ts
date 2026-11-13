import { describe, expect, it } from "vitest"
import { OpenClawActivityMapper, activityLifecycleOutcome, toolTitle } from "./activity-events.js"

describe("OpenClaw activity events", () => {
  it("keeps a tool call's start, item, output and end on one command row", () => {
    const mapper = new OpenClawActivityMapper()
    expect(mapper.toolStart({ toolCallId: "exec-1", name: "exec", args: { command: "pytest -q", description: "Running tests" } })).toEqual([
      { type: "item", id: "exec-1", body: { kind: "command", command: "pytest -q" }, state: "running" },
    ])
    expect(mapper.item({ itemId: "command:exec-1", toolCallId: "exec-1", kind: "command", name: "exec", title: "command pytest -q", phase: "start", status: "running" }))
      .toEqual([{ type: "item", id: "exec-1", state: "running" }])
    expect(mapper.commandOutput({ itemId: "command:exec-1", toolCallId: "exec-1", phase: "delta", output: "1 passed\n" }))
      .toEqual([{ type: "item", id: "exec-1", body: { kind: "command", command: "pytest -q", output: "1 passed\n" } }])
    expect(mapper.commandOutput({ itemId: "command:exec-1", phase: "end", exitCode: 1, durationMs: 4_200 })).toEqual([{
      type: "item",
      id: "exec-1",
      body: { kind: "command", command: "pytest -q", output: "1 passed\n", exitCode: 1 },
      state: "failed",
      durationMs: 4_200,
    }])
    expect(mapper.item({ itemId: "tool:exec-1", toolCallId: "exec-1", kind: "tool", name: "exec", phase: "end", status: "failed" }))
      .toEqual([{ type: "item", id: "exec-1", state: "failed" }])
  })

  it("treats OpenClaw tools reached over MCP as the tool itself", () => {
    const mapper = new OpenClawActivityMapper()
    expect(mapper.toolStart({ toolCallId: "exec-1", name: "mcp__openclaw__exec", args: { command: "date" } })).toEqual([
      { type: "item", id: "exec-1", body: { kind: "command", command: "date" }, state: "running" },
    ])
    expect(mapper.item({ itemId: "tool:exec-1", toolCallId: "exec-1", kind: "tool", name: "mcp__openclaw__exec", phase: "end", status: "completed" }))
      .toEqual([{ type: "item", id: "exec-1", state: "done" }])
  })

  it("picks the richest body per tool and readable titles otherwise", () => {
    const mapper = new OpenClawActivityMapper()
    const body = (name: string, args: Record<string, unknown>, id = name) => {
      const [event] = mapper.toolStart({ toolCallId: id, name, args })
      return event?.type === "item" ? event.body : undefined
    }
    expect(body("read", { path: "/repo/src/a.ts" })).toEqual({ kind: "read", path: "/repo/src/a.ts" })
    expect(body("write", { path: "notes.md", content: "secret" })).toEqual({ kind: "edit", files: [{ path: "notes.md", change: "modified" }] })
    expect(body("apply_patch", { input: "*** Begin Patch" })).toEqual({ kind: "tool", name: "apply_patch", title: "Editing files" })
    expect(body("web_search", { query: "inline chat" })).toEqual({ kind: "web", query: "inline chat" })
    expect(body("web_fetch", { url: "https://inline.chat/docs" })).toEqual({ kind: "web", url: "https://inline.chat/docs" })
    expect(body("browser", { action: "snapshot" })).toEqual({ kind: "tool", name: "browser", title: "Using the browser" })
    expect(body("sessions_spawn", { label: "Review the PR", task: "long prompt" })).toEqual({ kind: "agent", title: "Review the PR" })
    expect(body("memory_search", { query: "private" })).toEqual({ kind: "tool", name: "memory_search", title: "Searching memory" })
    expect(body("custom_lookup", { token: "x" })).toEqual({ kind: "tool", name: "custom_lookup", title: "Custom lookup" })
    expect(body("custom_lookup", { description: "Checking the order" }, "c2")).toEqual({ kind: "tool", name: "custom_lookup", title: "Checking the order" })
    expect(toolTitle("mcp__linear__list_issues")).toBe("Linear list issues")
  })

  it("turns a patch summary into an edit row with file changes", () => {
    const mapper = new OpenClawActivityMapper()
    mapper.toolStart({ toolCallId: "p1", name: "apply_patch", args: {} })
    expect(mapper.patchSummary({ toolCallId: "p1", phase: "end", added: ["a.ts"], modified: ["b.ts"], deleted: ["c.ts"] })).toEqual([{
      type: "item",
      id: "p1",
      body: { kind: "edit", files: [{ path: "a.ts", change: "added" }, { path: "b.ts", change: "modified" }, { path: "c.ts", change: "deleted" }] },
      state: "done",
    }])
  })

  it("hides command text and output when the channel shows status only", () => {
    const mapper = new OpenClawActivityMapper({ hideCommandText: true })
    expect(mapper.toolStart({ toolCallId: "e", name: "bash", args: { command: "curl -H 'Authorization: Bearer abc'" } }))
      .toEqual([{ type: "item", id: "e", body: { kind: "command", command: "a command" }, state: "running" }])
    expect(mapper.commandOutput({ toolCallId: "e", phase: "delta", output: "secret" })).toEqual([])
    expect(mapper.commandOutput({ toolCallId: "e", phase: "end", output: "secret", exitCode: 0 }))
      .toEqual([{ type: "item", id: "e", body: { kind: "command", command: "a command", exitCode: 0 }, state: "done" }])
  })

  it("skips items the host keeps out of channel progress", () => {
    const mapper = new OpenClawActivityMapper()
    expect(mapper.item({ itemId: "tool:h", toolCallId: "h", kind: "tool", name: "secret_tool", phase: "start", hideFromChannelProgress: true })).toEqual([])
    expect(mapper.item({ itemId: "tool:h", toolCallId: "h", kind: "tool", name: "secret_tool", phase: "end", status: "completed" })).toEqual([])
    expect(mapper.commandOutput({ toolCallId: "h", phase: "end", output: "x" })).toEqual([])
    expect(mapper.item({ itemId: "s", kind: "tool", name: "quiet", phase: "start", suppressChannelProgress: true })).toEqual([])
  })

  it("maps statuses, plans, approvals, compaction and preambles", () => {
    const mapper = new OpenClawActivityMapper()
    mapper.toolStart({ toolCallId: "t", name: "exec", args: { command: "rm -rf build" } })
    expect(mapper.approval({ phase: "requested", toolCallId: "t" })).toEqual([{ type: "waiting", id: "t", waiting: true }])
    expect(mapper.approval({ phase: "resolved", toolCallId: "t" })).toEqual([{ type: "waiting", id: "t", waiting: false }])
    expect(mapper.approval({ phase: "requested" })).toEqual([{ type: "waiting", waiting: true }])
    expect(mapper.item({ itemId: "tool:t", toolCallId: "t", phase: "end", status: "skipped" })).toEqual([{ type: "item", id: "t", state: "cancelled" }])
    expect(mapper.item({ itemId: "a1", kind: "analysis", title: "Checking inputs\nmore", phase: "start", status: "running" }))
      .toEqual([{ type: "item", id: "a1", body: { kind: "tool", name: "analysis", title: "Checking inputs" }, state: "running" }])
    expect(mapper.plan({ phase: "update", explanation: "First things first", steps: [{ step: "Read", status: "completed" }, { step: "Write", status: "in_progress" }, "Ship"] })).toEqual([{
      type: "item",
      id: "plan",
      body: { kind: "plan", explanation: "First things first", steps: [{ text: "Read", status: "completed" }, { text: "Write", status: "in_progress" }, { text: "Ship", status: "pending" }] },
      state: "done",
    }])
    expect(mapper.plan({ phase: "start" })).toEqual([])
    expect(mapper.compactionStart()).toEqual([{ type: "item", id: "compaction:1", body: { kind: "compaction" }, state: "running" }])
    expect(mapper.compactionEnd({ completed: true })).toEqual([{ type: "item", id: "compaction:1", body: { kind: "compaction" }, state: "done" }])
    expect(mapper.item({ kind: "preamble", progressText: " Looking at the logs. " })).toEqual([{ type: "commentary", text: "Looking at the logs." }])
  })

  it("closes an ID-less end on the latest open row of the same tool", () => {
    const mapper = new OpenClawActivityMapper()
    const [start] = mapper.toolStart({ name: "exec", args: { command: "ls" } })
    const id = start?.type === "item" ? start.id : undefined
    expect(mapper.item({ kind: "command", name: "exec", phase: "end", status: "done" })).toEqual([{ type: "item", id, state: "done" }])
  })

  it("uses explicit terminal lifecycle metadata for cancellation and timeout", () => {
    expect(activityLifecycleOutcome({ phase: "end", aborted: true, stopReason: "aborted" })).toBe("cancelled")
    expect(activityLifecycleOutcome({ phase: "error", aborted: true, stopReason: "timeout" })).toBe("failure")
    expect(activityLifecycleOutcome({ phase: "finishing", aborted: true })).toBeUndefined()
    expect(activityLifecycleOutcome({ phase: "end" })).toBe("success")
    expect(activityLifecycleOutcome({ phase: "error" })).toBe("failure")
  })
})

import {
  ProgressStream,
  resolveOutputMode,
  type ActivityEvent,
  type FileChange,
  type ItemBody,
  type ItemState,
  type OutputMode,
  type PlanStep,
  type ProgressTransport,
  type TurnOutcome,
} from "../vendor/agent-activity/index.js"

import { SidecarError, asOptionalRecord, type Target } from "./contract.js"

/** The bot's default output mode and this chat's override, as `AgentOutputMode` numbers. */
export type OutputModeSettings = { defaultMode?: number | undefined; override?: number | undefined }

export type ActivityHubOptions = {
  transportFor(target: Target): ProgressTransport
  /** Reads the chat's output mode settings; may throw, and the hub falls back. */
  readMode(target: Target): Promise<OutputModeSettings>
  now?: () => number
  /** How long one chat's resolved mode is reused. */
  modeCacheMs?: number
  /** A lookup slower than this falls back, so a slow server never holds up the turn. */
  modeTimeoutMs?: number
  onError?: (error: unknown, operation: "mode" | "send" | "edit") => void
  maxTurns?: number
}

type TurnState = {
  target: Target
  ready: Promise<OutputMode>
  mode?: OutputMode
  stream?: ProgressStream
  ended: boolean
  touchedAt: number
}

const MODE_CACHE_MS = 30_000
const MODE_TIMEOUT_MS = 3_000
const MAX_TURNS = 256

/**
 * Detailed progress for the Hermes adapter, one stream per agent turn. The
 * Python adapter posts turn events here in order; Friendly turns keep no
 * stream and their events are dropped.
 */
export class ActivityHub {
  private readonly turns = new Map<string, TurnState>()
  private readonly modes = new Map<string, { mode: OutputMode; at: number }>()
  private readonly now: () => number
  private readonly modeCacheMs: number
  private readonly modeTimeoutMs: number
  private readonly maxTurns: number

  constructor(private readonly options: ActivityHubOptions) {
    this.now = options.now ?? Date.now
    this.modeCacheMs = options.modeCacheMs ?? MODE_CACHE_MS
    this.modeTimeoutMs = options.modeTimeoutMs ?? MODE_TIMEOUT_MS
    this.maxTurns = options.maxTurns ?? MAX_TURNS
  }

  /**
   * Applies one event to a turn. `turn.start` opens the turn and resolves its
   * mode; with `lazy` it opens without showing "Working" until work arrives.
   * Events for turns that never started, or already ended, are ignored.
   */
  async apply(
    turnId: string,
    target: Target,
    event: ActivityEvent,
    options: { at?: number; lazy?: boolean } = {},
  ): Promise<{ mode?: OutputMode; ignored?: true }> {
    let state = this.turns.get(turnId)
    if (event.type === "turn.start") {
      if (!state) state = this.open(turnId, target)
      const mode = await state.ready
      if (mode === "detailed" && !options.lazy && !state.ended) state.stream?.apply(event, options.at)
      return { mode }
    }
    if (!state || state.ended) return { ignored: true }
    const mode = await state.ready
    state.touchedAt = this.now()
    if (mode !== "detailed" || !state.stream) return { mode }
    state.stream.apply(event, options.at)
    if (event.type === "turn.end") this.end(turnId, state)
    return { mode }
  }

  /** Resolves once every send and edit queued for the turn has reached the server. */
  async flush(turnId: string): Promise<void> {
    const state = this.turns.get(turnId)
    if (!state) return
    await state.ready
    await state.stream?.flush()
  }

  /** Open turns, for diagnostics and tests. */
  get size(): number {
    return this.turns.size
  }

  private open(turnId: string, target: Target): TurnState {
    this.prune()
    const state: TurnState = { target, ended: false, touchedAt: this.now(), ready: Promise.resolve("detailed") }
    state.ready = this.modeFor(target).then((mode) => {
      state.mode = mode
      if (mode === "detailed") {
        state.stream = new ProgressStream(this.options.transportFor(target), {
          onError: (error, op) => this.options.onError?.(error, op),
        })
      }
      return mode
    })
    this.turns.set(turnId, state)
    return state
  }

  private end(turnId: string, state: TurnState): void {
    state.ended = true
    const done = () => {
      if (this.turns.get(turnId) === state) this.turns.delete(turnId)
    }
    void (state.stream?.flush() ?? Promise.resolve()).then(done, done)
  }

  /** Drops the least recently used turns past the cap; one whose turn end was lost stays bounded. */
  private prune(): void {
    if (this.turns.size < this.maxTurns) return
    const byAge = [...this.turns.entries()].sort((left, right) => left[1].touchedAt - right[1].touchedAt)
    for (const [id] of byAge.slice(0, this.turns.size - this.maxTurns + 1)) this.turns.delete(id)
  }

  private async modeFor(target: Target): Promise<OutputMode> {
    const key = targetKey(target)
    const cached = this.modes.get(key)
    if (cached && this.now() - cached.at < this.modeCacheMs) return cached.mode
    try {
      let timer: ReturnType<typeof setTimeout> | undefined
      const settings = await Promise.race([
        this.options.readMode(target),
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error("output mode lookup timed out")), this.modeTimeoutMs)
        }),
      ]).finally(() => clearTimeout(timer))
      const mode = resolveOutputMode(settings.defaultMode, settings.override)
      this.modes.set(key, { mode, at: this.now() })
      if (this.modes.size > 1_024) this.modes.delete(this.modes.keys().next().value!)
      return mode
    } catch (error) {
      this.options.onError?.(error, "mode")
      // The last known mode for this chat, else Detailed (unspecified means Detailed).
      return cached?.mode ?? "detailed"
    }
  }
}

export function targetKey(target: Target): string {
  return "chatId" in target ? `chat:${target.chatId.toString()}` : `user:${target.userId.toString()}`
}

/** A non-zero signed 64-bit random ID, as `sendMessage` requires. */
export function randomMessageId(): bigint {
  const bytes = new Uint8Array(8)
  globalThis.crypto.getRandomValues(bytes)
  const value = new DataView(bytes.buffer).getBigInt64(0, true)
  return value === 0n ? 1n : value
}

/** The new message's ID from a raw `sendMessage` result (`newMessage` or `updateMessageId` updates). */
export function firstMessageId(result: unknown): bigint | null {
  const record = asOptionalRecord(result)
  const send = asOptionalRecord(record?.sendMessage) ?? record
  const updates = Array.isArray(send?.updates) ? send.updates : []
  for (const raw of updates) {
    const update = asOptionalRecord(asOptionalRecord(raw)?.update)
    if (update?.oneofKind === "newMessage") {
      const id = asOptionalRecord(asOptionalRecord(update.newMessage)?.message)?.id
      if (id != null) return BigInt(String(id))
    }
    if (update?.oneofKind === "updateMessageId") {
      const id = asOptionalRecord(update.updateMessageId)?.messageId
      if (id != null) return BigInt(String(id))
    }
  }
  return null
}

const ITEM_STATES = new Set<ItemState>(["running", "waiting", "done", "failed", "cancelled"])
const OUTCOMES = new Set<TurnOutcome>(["success", "failure", "cancelled"])
const PLAN_STATUSES = new Set<PlanStep["status"]>(["pending", "in_progress", "completed"])
const CHANGES = new Set<NonNullable<FileChange["change"]>>(["added", "deleted", "modified", "renamed"])

/** Validates an activity event from the Python adapter, which sends plain JSON. */
export function parseActivityEvent(value: unknown): ActivityEvent {
  const record = asOptionalRecord(value)
  if (!record) throw new SidecarError("event must be an object", "bad_format")
  switch (record.type) {
    case "turn.start":
      return { type: "turn.start" }
    case "split":
      return { type: "split" }
    case "turn.end": {
      const outcome = record.outcome
      if (typeof outcome !== "string" || !OUTCOMES.has(outcome as TurnOutcome)) {
        throw new SidecarError("turn.end requires outcome success, failure or cancelled", "bad_format")
      }
      return { type: "turn.end", outcome: outcome as TurnOutcome }
    }
    case "commentary":
      return { type: "commentary", text: requiredString(record, "text") }
    case "waiting": {
      if (typeof record.waiting !== "boolean") throw new SidecarError("waiting requires a boolean", "bad_format")
      const id = optionalString(record, "id")
      return { type: "waiting", waiting: record.waiting, ...(id !== undefined ? { id } : {}) }
    }
    case "item": {
      const id = requiredString(record, "id")
      const parent = optionalString(record, "parent")
      const state = record.state
      if (state !== undefined && (typeof state !== "string" || !ITEM_STATES.has(state as ItemState))) {
        throw new SidecarError("item state is not valid", "bad_format")
      }
      const durationMs = optionalNumber(record, "durationMs")
      const body = record.body === undefined ? undefined : parseBody(record.body)
      return {
        type: "item",
        id,
        ...(parent !== undefined ? { parent } : {}),
        ...(body ? { body } : {}),
        ...(state !== undefined ? { state: state as ItemState } : {}),
        ...(durationMs !== undefined ? { durationMs } : {}),
      }
    }
    default:
      throw new SidecarError("unknown activity event type", "bad_format")
  }
}

function parseBody(value: unknown): ItemBody {
  const body = asOptionalRecord(value)
  if (!body) throw new SidecarError("item body must be an object", "bad_format")
  const strings = <K extends string>(...keys: K[]) => {
    const out: Partial<Record<K, string>> = {}
    for (const key of keys) {
      const text = optionalString(body, key)
      if (text !== undefined) out[key] = text
    }
    return out
  }
  switch (body.kind) {
    case "command": {
      const exitCode = optionalNumber(body, "exitCode")
      return {
        kind: "command",
        command: requiredString(body, "command"),
        ...strings("output"),
        ...(exitCode !== undefined ? { exitCode: Math.trunc(exitCode) } : {}),
      }
    }
    case "read":
      return { kind: "read", path: requiredString(body, "path") }
    case "search":
      return { kind: "search", ...strings("query", "path") }
    case "list":
      return { kind: "list", ...strings("path") }
    case "edit": {
      const files = Array.isArray(body.files) ? body.files : []
      return { kind: "edit", files: files.map(parseFileChange) }
    }
    case "web":
      return { kind: "web", ...strings("query", "url") }
    case "tool":
      return { kind: "tool", name: requiredString(body, "name"), ...strings("title", "input", "output", "error") }
    case "agent":
      return { kind: "agent", ...strings("title", "meta") }
    case "plan": {
      const steps = Array.isArray(body.steps) ? body.steps : []
      return {
        kind: "plan",
        steps: steps.map((raw) => {
          const step = asOptionalRecord(raw)
          const status = step?.status
          if (!step || typeof status !== "string" || !PLAN_STATUSES.has(status as PlanStep["status"])) {
            throw new SidecarError("plan step is not valid", "bad_format")
          }
          return { text: requiredString(step, "text"), status: status as PlanStep["status"] }
        }),
        ...strings("explanation"),
      }
    }
    case "reasoning":
      return { kind: "reasoning", summary: requiredString(body, "summary") }
    case "note":
      return { kind: "note", text: requiredString(body, "text") }
    case "compaction":
      return { kind: "compaction" }
    default:
      throw new SidecarError("unknown item body kind", "bad_format")
  }
}

function parseFileChange(value: unknown): FileChange {
  const file = asOptionalRecord(value)
  if (!file) throw new SidecarError("edit file must be an object", "bad_format")
  const change = file.change
  if (change !== undefined && (typeof change !== "string" || !CHANGES.has(change as NonNullable<FileChange["change"]>))) {
    throw new SidecarError("edit file change is not valid", "bad_format")
  }
  const diff = optionalString(file, "diff")
  const additions = optionalNumber(file, "additions")
  const deletions = optionalNumber(file, "deletions")
  return {
    path: requiredString(file, "path"),
    ...(change !== undefined ? { change: change as NonNullable<FileChange["change"]> } : {}),
    ...(diff !== undefined ? { diff } : {}),
    ...(additions !== undefined ? { additions: Math.trunc(additions) } : {}),
    ...(deletions !== undefined ? { deletions: Math.trunc(deletions) } : {}),
  }
}

function requiredString(record: Record<string, unknown>, key: string): string {
  const value = record[key]
  if (typeof value !== "string") throw new SidecarError(`${key} must be a string`, "bad_format")
  return value
}

function optionalString(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== "string") throw new SidecarError(`${key} must be a string`, "bad_format")
  return value
}

function optionalNumber(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== "number" || !Number.isFinite(value)) throw new SidecarError(`${key} must be a number`, "bad_format")
  return value
}

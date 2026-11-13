import { createHash, randomUUID } from "node:crypto"
import { mkdir, open, readFile, rename, rm } from "node:fs/promises"
import path from "node:path"

type Encoded = null | boolean | number | string | { type: "bigint" | "bytes"; value: string }
  | { type: "array"; value: Encoded[] } | { type: "object"; value: Record<string, Encoded> }

function encode(value: unknown): Encoded {
  if (value == null) return null
  if (typeof value === "string" || typeof value === "boolean") return value
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "bigint") return { type: "bigint", value: String(value) }
  if (value instanceof Uint8Array) return { type: "bytes", value: Buffer.from(value).toString("base64") }
  if (Array.isArray(value)) return { type: "array", value: value.map(encode) }
  if (typeof value === "object") return { type: "object", value: Object.fromEntries(
    Object.entries(value).filter(([, child]) => child !== undefined).map(([key, child]) => [key, encode(child)]),
  ) }
  throw new Error("Unsupported Inline inbox value")
}

function decode(value: Encoded): unknown {
  if (value == null || typeof value !== "object") return value
  switch (value.type) {
    case "bigint": return BigInt(value.value)
    case "bytes": return new Uint8Array(Buffer.from(value.value, "base64"))
    case "array": return value.value.map(decode)
    case "object": return Object.fromEntries(Object.entries(value.value).map(([key, child]) => [key, decode(child)]))
  }
}

type StoredRecord = {
  id: string
  state: "pending" | "dispatching" | "completed"
  acceptedAt?: number
  updatedAt: number
  payload?: Encoded
  recoveryNotified?: boolean
}

const MAX_INBOX_BYTES = 8 * 1024 * 1024
const MAX_INPUT_BYTES = 1024 * 1024

export class InlineInboxCapacityError extends Error {}

function encodeInput(value: unknown): Encoded {
  const encoded = encode(value)
  if (Buffer.byteLength(JSON.stringify(encoded)) > MAX_INPUT_BYTES) throw new Error("Inline input exceeds the durable inbox byte limit")
  return encoded
}

export type InlineInboxEntry<T> = { id: string; state: StoredRecord["state"]; payload: T }

/** Custody of input before the SDK cursor advances. Dispatching is deliberately
 * never replayed: old hosts have no durable, idempotent turn-admission API. */
export class InlineInboundInbox<T> {
  private records = new Map<string, StoredRecord>()
  private writes: Promise<unknown> = Promise.resolve()
  private closed = false
  private clock = 0

  private constructor(private readonly file: string, private readonly identity: string) {}

  static async open<T>(stateDir: string, identity: { baseUrl: string; accountId: string; botUserId: bigint }): Promise<InlineInboundInbox<T>> {
    const endpoint = new URL(identity.baseUrl).href.replace(/\/+$/, "")
    const key = JSON.stringify([endpoint, identity.accountId, String(identity.botUserId)])
    const file = path.join(stateDir, "channels", "inline", "inbox", `${createHash("sha256").update(key).digest("hex")}.json`)
    const inbox = new InlineInboundInbox<T>(file, key)
    let source: string
    try { source = await readFile(file, "utf8") } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return inbox
      throw error
    }
    let stored: { version: number; identity: string; records: StoredRecord[] }
    try { stored = JSON.parse(source) as typeof stored } catch { throw new Error("Invalid Inline inbound inbox") }
    if (!stored || stored.version !== 1 || stored.identity !== key || !Array.isArray(stored.records) || stored.records.some((record) =>
      typeof record.id !== "string" || !["pending", "dispatching", "completed"].includes(record.state) ||
      !Number.isSafeInteger(record.updatedAt) ||
      (record.acceptedAt !== undefined && !Number.isSafeInteger(record.acceptedAt)) ||
      (record.state !== "completed" && record.payload === undefined))) throw new Error("Invalid Inline inbound inbox")
    inbox.records = new Map(stored.records.map((record) => [record.id, record]))
    inbox.clock = Math.max(0, ...stored.records.map((record) => record.updatedAt))
    return inbox
  }

  entries(): InlineInboxEntry<T>[] {
    return Array.from(this.records.values()).flatMap((record) => record.state === "completed" || record.payload === undefined
      ? [] : [{ id: record.id, state: record.state, payload: decode(record.payload) as T }])
  }

  state(id: string): StoredRecord["state"] | undefined { return this.records.get(id)?.state }

  entry(id: string): InlineInboxEntry<T> | undefined {
    const record = this.records.get(id)
    if (!record || record.state === "completed" || record.payload === undefined) return undefined
    return { id, state: record.state, payload: decode(record.payload) as T }
  }

  pendingBefore(ids: readonly string[]): InlineInboxEntry<T>[] {
    const boundary = Math.max(0, ...ids.map((id) => this.records.get(id)?.updatedAt ?? 0))
    return this.entries().filter((entry) => {
      const record = this.records.get(entry.id)!
      return entry.state === "pending" && (record.acceptedAt ?? record.updatedAt) < boundary
    })
  }

  async cancelPendingBefore(ids: readonly string[], shouldCancel: (payload: T) => boolean): Promise<string[]> {
    return this.mutate(() => {
      if (ids.some((id) => this.records.get(id)?.state !== "pending")) return []
      // Select and retire inside the same write transaction. A turn that has
      // already crossed beginDispatch must keep its uncertain outcome.
      const cancelled = this.pendingBefore(ids).filter((entry) => shouldCancel(entry.payload)).map((entry) => entry.id)
      for (const id of cancelled) this.records.set(id, { id, state: "completed", updatedAt: this.timestamp() })
      this.pruneCompleted()
      return cancelled
    })
  }

  private timestamp(): number { return this.clock = Math.max(Date.now(), this.clock + 1) }

  async close(): Promise<void> {
    this.closed = true
    await this.writes
  }

  async accept(id: string, payload: T): Promise<boolean> {
    return this.mutate(() => {
      if (this.records.has(id)) return false
      if (Array.from(this.records.values()).filter((record) => record.state !== "completed").length >= 1_000) {
        throw new InlineInboxCapacityError("Inline inbound inbox is full; input remains unacknowledged")
      }
      const acceptedAt = this.timestamp()
      this.records.set(id, { id, state: "pending", acceptedAt, updatedAt: acceptedAt, payload: encodeInput(payload) })
      return true
    })
  }

  async updatePending(id: string, payload: T): Promise<void> {
    await this.mutate(() => {
      const record = this.records.get(id)
      if (record?.state === "pending") this.records.set(id, { ...record, acceptedAt: record.acceptedAt ?? record.updatedAt,
        payload: encodeInput(payload), updatedAt: this.timestamp() })
    })
  }

  async beginDispatch(ids: readonly string[], recovery?: (payload: T) => T): Promise<boolean> {
    return this.mutate(() => {
      if (ids.some((id) => this.records.get(id)?.state !== "pending")) return false
      for (const id of ids) {
        const record = this.records.get(id)!
        this.records.set(id, { ...record, state: "dispatching", updatedAt: this.timestamp(),
          ...(recovery && record.payload !== undefined ? { payload: encodeInput(recovery(decode(record.payload) as T)) } : {}),
        })
      }
      return true
    })
  }

  async complete(ids: readonly string[]): Promise<void> {
    await this.mutate(() => {
      for (const id of ids) if (this.records.has(id)) this.records.set(id, { id, state: "completed", updatedAt: this.timestamp() })
      // Completed records retain identity only, covering replay before the SDK's
      // own cursor checkpoint without retaining old message bodies indefinitely.
      this.pruneCompleted()
    })
  }

  needsRecoveryNotice(id: string): boolean {
    const record = this.records.get(id)
    return record?.state === "dispatching" && !record.recoveryNotified
  }

  async markRecoveryNotified(ids: string | readonly string[]): Promise<void> {
    await this.mutate(() => {
      for (const id of typeof ids === "string" ? [ids] : ids) {
        if (this.records.get(id)?.state === "dispatching") {
          // Custody has passed to the owner through a confirmed Inline notice,
          // not a claim that the host finished the possibly queued request.
          this.records.set(id, { id, state: "completed", updatedAt: this.timestamp(), recoveryNotified: true })
        }
      }
      this.pruneCompleted()
    })
  }

  private pruneCompleted(): void {
    const completed = Array.from(this.records.values()).filter((record) => record.state === "completed")
    completed.sort((a, b) => a.updatedAt - b.updatedAt)
    for (const record of completed.slice(0, Math.max(0, completed.length - 5_000))) this.records.delete(record.id)
  }

  private async mutate<R>(change: () => R): Promise<R> {
    const operation = this.writes.then(async () => {
      if (this.closed) throw new Error("Inline inbound inbox is closed")
      const before = new Map(this.records)
      try {
        const result = change()
        if (before.size === this.records.size && Array.from(this.records).every(([id, record]) => before.get(id) === record)) return result
        await this.persist()
        return result
      } catch (error) {
        this.records = before
        throw error
      }
    })
    this.writes = operation.catch(() => {})
    return operation
  }

  private async persist(): Promise<void> {
    const contents = JSON.stringify({ version: 1, identity: this.identity, records: Array.from(this.records.values()) })
    if (Buffer.byteLength(contents) > MAX_INBOX_BYTES) throw new InlineInboxCapacityError("Inline inbound inbox byte limit reached; input remains unacknowledged")
    const directory = path.dirname(this.file)
    await mkdir(directory, { recursive: true, mode: 0o700 })
    const temporary = `${this.file}.${randomUUID()}.tmp`
    try {
      const file = await open(temporary, "wx", 0o600)
      try {
        await file.writeFile(contents)
        await file.sync()
      } finally { await file.close() }
      await rename(temporary, this.file)
      const parent = await open(directory, "r")
      try { await parent.sync() } finally { await parent.close() }
    } finally { await rm(temporary, { force: true }) }
  }
}

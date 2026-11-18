import type { ModelMessage } from "./server-model"

/**
 * A chat's messages for the demo server model: seeded messages 1 through
 * `count` are produced on demand by `at`, everything else (new, edited,
 * deleted) is stored. It is a `Map`, so `ServerModel` uses it unchanged:
 *
 * - `get`, `has`, `set` and `delete` touch one message. A seeded message read
 *   through `get` is kept, so an edit to the object it returned sticks.
 * - Iterating, `size` and `forEach` materialize every seeded message first
 *   (once; the chat then behaves as a plain map).
 * - `peek`, `latest`, `idsBefore` and `idsAfter` answer without
 *   materializing; the demo model uses them for its hot paths.
 * - `absent(id)` names seeded IDs that never exist (deleted before the
 *   journal's retention): they are skipped everywhere, as server holes are.
 */
export class DemoLazyMessages extends Map<bigint, ModelMessage> {
  private complete = false
  private readonly deleted = new Set<bigint>()
  /** Stored IDs above the seeded range, ascending; rebuilt after a change. */
  private extras: bigint[] | null = null

  constructor(
    readonly count: number,
    private readonly at: (id: bigint) => ModelMessage,
    private readonly absent: (id: bigint) => boolean = () => false,
  ) {
    super()
  }

  get materialized() {
    return this.complete
  }

  /** IDs deleted from the seeded range. */
  deletedSeeded(): bigint[] {
    return Array.from(this.deleted)
  }

  /** Messages held in memory (new, edited or read once), without materializing. */
  stored(): ModelMessage[] {
    return Array.from(super.values())
  }

  private seeded(id: bigint) {
    return id >= 1n && id <= BigInt(this.count) && !this.deleted.has(id) && !this.absent(id)
  }

  override get(id: bigint): ModelMessage | undefined {
    const stored = super.get(id)
    if (stored || this.complete || !this.seeded(id)) return stored
    const message = this.at(id)
    super.set(id, message)
    return message
  }

  /** The message without keeping a seeded one in memory. */
  peek(id: bigint): ModelMessage | undefined {
    const stored = super.get(id)
    if (stored || this.complete || !this.seeded(id)) return stored
    return this.at(id)
  }

  override has(id: bigint): boolean {
    return super.has(id) || (!this.complete && this.seeded(id))
  }

  override set(id: bigint, message: ModelMessage): this {
    if (!super.has(id) && id > BigInt(this.count)) this.extras = null
    this.deleted.delete(id)
    return super.set(id, message)
  }

  override delete(id: bigint): boolean {
    const existed = this.has(id)
    if (!this.complete && id >= 1n && id <= BigInt(this.count)) this.deleted.add(id)
    if (super.delete(id) && id > BigInt(this.count)) this.extras = null
    return existed
  }

  override clear(): void {
    this.complete = true
    this.extras = null
    super.clear()
  }

  /** The newest message, without materializing. */
  latest(): ModelMessage | undefined {
    const [id] = this.idsBefore(undefined, 1)
    return id == null ? undefined : this.peek(id)
  }

  /** Up to `limit` IDs below `before` (or the newest), newest first. */
  idsBefore(before: bigint | undefined, limit: number): bigint[] {
    const result: bigint[] = []
    if (limit <= 0) return result
    if (this.complete) {
      const ids = Array.from(super.keys())
        .filter((id) => before == null || id < before)
        .sort((left, right) => (left > right ? -1 : left < right ? 1 : 0))
      return ids.slice(0, limit)
    }
    const extras = this.extraIds()
    let extra = extras.length - 1
    while (extra >= 0 && before != null && extras[extra]! >= before) extra -= 1
    const count = BigInt(this.count)
    let seeded = before == null ? count : before - 1n < count ? before - 1n : count
    while (result.length < limit) {
      while (seeded >= 1n && (this.deleted.has(seeded) || this.absent(seeded))) seeded -= 1n
      const nextExtra = extra >= 0 ? extras[extra]! : undefined
      const nextSeeded = seeded >= 1n ? seeded : undefined
      if (nextExtra == null && nextSeeded == null) break
      if (nextSeeded == null || (nextExtra != null && nextExtra > nextSeeded)) {
        result.push(nextExtra!)
        extra -= 1
      } else {
        result.push(nextSeeded)
        seeded -= 1n
      }
    }
    return result
  }

  /** Up to `limit` IDs above `after`, oldest first. */
  idsAfter(after: bigint, limit: number): bigint[] {
    const result: bigint[] = []
    if (limit <= 0) return result
    if (this.complete) {
      const ids = Array.from(super.keys())
        .filter((id) => id > after)
        .sort((left, right) => (left < right ? -1 : left > right ? 1 : 0))
      return ids.slice(0, limit)
    }
    const extras = this.extraIds()
    let extra = 0
    while (extra < extras.length && extras[extra]! <= after) extra += 1
    const count = BigInt(this.count)
    let seeded = after + 1n < 1n ? 1n : after + 1n
    while (result.length < limit) {
      while (seeded <= count && (this.deleted.has(seeded) || this.absent(seeded))) seeded += 1n
      const nextExtra = extra < extras.length ? extras[extra]! : undefined
      const nextSeeded = seeded <= count ? seeded : undefined
      if (nextExtra == null && nextSeeded == null) break
      if (nextSeeded == null || (nextExtra != null && nextExtra < nextSeeded)) {
        result.push(nextExtra!)
        extra += 1
      } else {
        result.push(nextSeeded)
        seeded += 1n
      }
    }
    return result
  }

  /** Produce every seeded message; afterwards this is a plain map. */
  materialize() {
    if (this.complete) return
    for (let id = 1n; id <= BigInt(this.count); id += 1n) {
      if (!super.has(id) && !this.deleted.has(id) && !this.absent(id)) super.set(id, this.at(id))
    }
    this.complete = true
    this.extras = null
  }

  override get size(): number {
    this.materialize()
    return super.size
  }

  override keys(): MapIterator<bigint> {
    this.materialize()
    return super.keys()
  }

  override values(): MapIterator<ModelMessage> {
    this.materialize()
    return super.values()
  }

  override entries(): MapIterator<[bigint, ModelMessage]> {
    this.materialize()
    return super.entries()
  }

  override [Symbol.iterator](): MapIterator<[bigint, ModelMessage]> {
    return this.entries()
  }

  override forEach(
    callback: (value: ModelMessage, key: bigint, map: Map<bigint, ModelMessage>) => void,
    thisArg?: unknown,
  ): void {
    this.materialize()
    super.forEach(callback, thisArg)
  }

  private extraIds(): bigint[] {
    if (!this.extras) {
      const count = BigInt(this.count)
      this.extras = Array.from(super.keys())
        .filter((id) => id > count)
        .sort((left, right) => (left < right ? -1 : left > right ? 1 : 0))
    }
    return this.extras
  }
}

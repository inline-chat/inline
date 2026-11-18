import type { ChatID } from "@inline/ids"
import { DbObjectKind, type DbModel } from "./models"

const inRange = (
  range: Extract<DbReadStamp, { type: "clear-range" }>,
  id: string,
) => {
  if (range.keep.has(id)) return false
  let value: bigint
  try {
    value = BigInt(id)
  } catch {
    return false
  }
  return range.from <= value && value <= range.to
}

/** Stable key for one object across kinds, shared by undo, stamps and reads. */
export const dbObjectKey = (
  kind: DbObjectKind,
  id: DbModel["id"],
): string => `${kind}\0${String(id)}`

/**
 * One write's effect on a key, as a read in flight must see it.
 * `value: null` means the key was removed, or its value is unknown because a
 * write was rolled back: either way the stored row must not be admitted.
 */
export type DbReadStamp =
  | {
      type: "write"
      kind: DbObjectKind
      id: DbModel["id"]
      value: DbModel | null
    }
  | { type: "clear-chat"; chatId: ChatID }
  | {
      type: "clear-range"
      chatId: ChatID
      from: bigint
      to: bigint
      keep: ReadonlySet<string>
    }

/**
 * Invariant 13. A disk read that began before a write was accepted must not
 * overwrite that write's result in memory.
 *
 * A read registers one admission when it starts. The admission is seeded
 * with every accepted write that has not committed yet (the read may see the
 * disk before or after them), and every write accepted while the read is in
 * flight stamps it. When the read admits rows, it does so in one synchronous
 * step through `reconcile`: a stamped key takes the stamped value (or is
 * dropped if it was removed), a message of a cleared chat is dropped, and
 * only an unstamped row is taken from disk.
 */
export class DbReadAdmission {
  private readonly changed = new Map<string, DbModel | null>()
  private readonly clearedChats = new Set<ChatID>()
  private readonly clearedRanges: Array<
    Extract<DbReadStamp, { type: "clear-range" }>
  > = []

  stamp(stamp: DbReadStamp) {
    if (stamp.type === "write") {
      this.changed.set(dbObjectKey(stamp.kind, stamp.id), stamp.value)
      return
    }
    const prefix = `${DbObjectKind.Message}\0${stamp.chatId}:`
    if (stamp.type === "clear-chat") {
      this.clearedChats.add(stamp.chatId)
      for (const key of this.changed.keys()) {
        if (key.startsWith(prefix)) this.changed.set(key, null)
      }
      return
    }
    this.clearedRanges.push(stamp)
    for (const key of this.changed.keys()) {
      if (!key.startsWith(prefix)) continue
      const id = key.slice(prefix.length)
      if (inRange(stamp, id)) this.changed.set(key, null)
    }
  }

  /** True when a write touched this key after (or pending at) the read's start. */
  touched(kind: DbObjectKind, id: DbModel["id"]) {
    return this.changed.has(dbObjectKey(kind, id))
  }

  /**
   * The value to admit for a stored row that is not resident, or `undefined`
   * when the row must not be admitted.
   */
  reconcile<O extends DbModel>(
    kind: DbObjectKind,
    stored: O,
  ): O | undefined {
    const key = dbObjectKey(kind, stored.id)
    if (this.changed.has(key)) {
      return (this.changed.get(key) ?? undefined) as O | undefined
    }
    if (kind === DbObjectKind.Message && "chatId" in stored) {
      const chatId = stored.chatId as ChatID
      if (this.clearedChats.has(chatId)) return undefined
      const id = String((stored as { messageId?: unknown }).messageId)
      if (
        this.clearedRanges.some(
          (range) => range.chatId === chatId && inRange(range, id),
        )
      ) {
        return undefined
      }
    }
    return stored
  }
}

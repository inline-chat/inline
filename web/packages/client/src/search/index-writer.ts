import type { Database, PreparedStatement, SqlValue } from "@sqlite.org/sqlite-wasm"
import { decodeInlineModel } from "../database/model-codec"
import { DbObjectKind, type Message } from "../database/models"
import { indexText, textHash } from "./normalize"

/**
 * Keeps the FTS5 index (`message_search`, replica schema version 5) in step
 * with message rows. The SQLite store calls `put` for every message it
 * writes, inside the same transaction, so a message and its index entry
 * commit or roll back together (invariants 1 and 6). Removing a message row
 * removes its entry through SQL triggers (`message` → `message_search_doc`
 * → `message_search`), whatever deleted the row.
 *
 * Index rowids order the index newest first: `date * 1024 + (messageId mod
 * 1024)`, the next free slot on the rare collision. FTS5 walks rowids in
 * order, so "newest first" with a limit stops after the page instead of
 * sorting every match. It is the Mac's order (date, then message ID), except
 * that within one second message IDs compare modulo 1024. Doclists store
 * rowid deltas as varints, so the multiplier is kept small: 2^31 made the
 * index 27% larger than 2^10 (measured in README.md).
 */

const DATE_SHIFT = 1_024n
const MESSAGE_ID_MASK = 1_023n
const MAX_DATE = 0xffff_ffff
/** Collisions are probed this far; past it the message is not indexed. */
const MAX_PROBE = 4_096

export const chatToken = (chatId: string | bigint) => `c${String(chatId)}`

const toBigInt = (value: SqlValue | undefined): bigint | undefined => {
  if (typeof value === "bigint") return value
  if (typeof value === "number" && Number.isInteger(value)) return BigInt(value)
  return undefined
}

const messageSeconds = (date: number | undefined): number => {
  if (typeof date !== "number" || !Number.isFinite(date)) return 0
  return Math.min(MAX_DATE, Math.max(0, Math.floor(date)))
}

/** A server-assigned message ID; temporary (local) IDs are zero or negative. */
const serverMessageId = (id: unknown): bigint | undefined => {
  try {
    const value = BigInt(String(id))
    return value > 0n ? value : undefined
  } catch {
    return undefined
  }
}

export const searchRowid = (date: number | undefined, id: bigint): bigint =>
  BigInt(messageSeconds(date)) * DATE_SHIFT + (id & MESSAGE_ID_MASK)

/** The indexed body and its hash (which covers the date, since the rowid does). */
export const searchEntryOf = (
  message: Pick<Message, "message" | "date">,
): { body: string; hash: number } | undefined => {
  const body = indexText(message.message)
  if (body.length === 0) return undefined
  return { body, hash: textHash(`${messageSeconds(message.date)}\u0000${body}`) }
}

export type IndexPutResult = "indexed" | "unchanged" | "removed" | "skipped"

/**
 * One transaction's index writes. Statements are prepared on first use and
 * finalized by `finalize`, so a transaction without messages pays nothing.
 */
export class MessageSearchIndexWriter {
  private statements = new Map<string, PreparedStatement>()

  constructor(private readonly db: Database) {}

  private statement(sql: string): PreparedStatement {
    let statement = this.statements.get(sql)
    if (!statement) {
      statement = this.db.prepare(sql)
      this.statements.set(sql, statement)
    }
    return statement
  }

  private run(sql: string, bind: (SqlValue | bigint)[]) {
    const statement = this.statement(sql)
    try {
      statement.bind(bind as SqlValue[]).stepReset()
    } finally {
      statement.clearBindings()
    }
  }

  private first(sql: string, bind: (SqlValue | bigint)[]): SqlValue[] | undefined {
    const statement = this.statement(sql)
    try {
      statement.bind(bind as SqlValue[])
      return statement.step() ? (statement.get([]) as SqlValue[]) : undefined
    } finally {
      statement.reset()
      statement.clearBindings()
    }
  }

  /** Bring one message's entry in line with the row just written. */
  put(message: Message): IndexPutResult {
    const id = serverMessageId(message.messageId)
    if (id === undefined) return "skipped"
    let chat: bigint
    try {
      chat = BigInt(String(message.chatId))
    } catch {
      return "skipped"
    }
    const entry = searchEntryOf(message)
    const existing = this.first(
      "SELECT rowid, hash FROM message_search_doc WHERE chat_id = ? AND message_id = ?",
      [chat, id],
    )
    const existingRowid = existing ? toBigInt(existing[0]) : undefined
    if (!entry) {
      if (existingRowid === undefined) return "skipped"
      this.run("DELETE FROM message_search_doc WHERE rowid = ?", [existingRowid])
      return "removed"
    }
    if (existing && Number(existing[1]) === entry.hash) return "unchanged"
    if (existingRowid !== undefined) {
      this.run("DELETE FROM message_search_doc WHERE rowid = ?", [existingRowid])
    }
    const base = searchRowid(message.date, id)
    let rowid: bigint | undefined
    for (let probe = 0n; probe < BigInt(MAX_PROBE); probe++) {
      const candidate = base + probe
      if (!this.first("SELECT 1 FROM message_search_doc WHERE rowid = ?", [candidate])) {
        rowid = candidate
        break
      }
    }
    if (rowid === undefined) return "skipped"
    this.run("INSERT INTO message_search(rowid, body, chat) VALUES (?, ?, ?)", [
      rowid,
      entry.body,
      chatToken(chat),
    ])
    this.run(
      "INSERT INTO message_search_doc(rowid, chat_id, message_id, hash) VALUES (?, ?, ?, ?)",
      [rowid, chat, id, entry.hash],
    )
    return "indexed"
  }

  finalize() {
    for (const statement of this.statements.values()) statement.finalize()
    this.statements.clear()
  }
}

/** Where a backfill stands: the last message key it indexed. */
export type BackfillCursor = readonly [chatId: bigint, messageId: bigint]

export type BackfillBatchResult = {
  /** Message rows read. */
  readonly read: number
  /** The last key read; undefined when nothing was left. */
  readonly last: BackfillCursor | undefined
  readonly done: boolean
}

/**
 * Index up to `limit` stored messages after `after`, in primary-key order.
 * Runs inside the caller's transaction. Rows that do not decode are skipped
 * (they are not searchable, and the backfill must not stall on them).
 */
export const indexStoredMessages = (
  db: Database,
  writer: MessageSearchIndexWriter,
  after: BackfillCursor | undefined,
  limit: number,
): BackfillBatchResult => {
  const rows = db.exec({
    sql: after
      ? `SELECT chat_id, message_id, payload FROM message
         WHERE (chat_id, message_id) > (?, ?)
         ORDER BY chat_id, message_id LIMIT ?`
      : `SELECT chat_id, message_id, payload FROM message
         ORDER BY chat_id, message_id LIMIT ?`,
    bind: (after ? [after[0], after[1], limit] : [limit]) as SqlValue[],
    rowMode: "array",
    returnValue: "resultRows",
  }) as SqlValue[][]
  let last: BackfillCursor | undefined
  for (const row of rows) {
    const chat = toBigInt(row[0])
    const id = toBigInt(row[1])
    if (chat === undefined || id === undefined) continue
    last = [chat, id]
    const payload = row[2]
    if (!(payload instanceof Uint8Array)) continue
    let model: ReturnType<typeof decodeInlineModel>
    try {
      model = decodeInlineModel(payload)
    } catch {
      continue
    }
    if (model.kind !== DbObjectKind.Message) continue
    writer.put(model)
  }
  return { read: rows.length, last, done: rows.length < limit }
}

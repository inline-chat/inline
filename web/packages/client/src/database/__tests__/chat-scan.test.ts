import { chatId as makeChatId, messageId as makeMessageId, userId as makeUserId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { chatMediaMatches } from "../../queries/chat-media"
import { SEED_ACCOUNT_SCALES, writeSeedAccountToStore } from "../../testing/seed-account"
import { Db } from "../index"
import { DbObjectKind, messageKey, type Message } from "../models"
import { createSqliteMemoryPersistenceStore } from "../sqlite/openers"

/**
 * `Db.scanChatMessages`: a chat's stored messages that pass a filter, newest
 * first, read from disk by the `message` primary key (the `chatMedia` list's
 * local first frame).
 */

const chat = makeChatId(10)
const other = makeChatId(11)

const message = (chatId: typeof chat, id: number, photo: boolean): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId, makeMessageId(id)),
  messageId: makeMessageId(id),
  chatId,
  fromId: makeUserId(2),
  message: `m${id}`,
  date: 1_000 + id,
  ...(photo
    ? { media: { media: { oneofKind: "photo", photo: { photo: { id: BigInt(id), date: 1n, sizes: [] } } } } as never }
    : {}),
})

const photos = (value: Message) => chatMediaMatches(value, "photos")

const seeded = async () => {
  const store = createSqliteMemoryPersistenceStore()
  await store.open()
  const objects: Message[] = []
  // Every third message of chat 10 is a photo; chat 11 is all photos.
  for (let id = 1; id <= 30; id += 1) objects.push(message(chat, id, id % 3 === 0))
  for (let id = 1; id <= 5; id += 1) objects.push(message(other, id, true))
  // A send not yet confirmed: never listed.
  objects.push({ ...message(chat, -5, true) })
  await store.write(objects.map((object) => ({ type: "put", object })))
  const db = new Db({ autoHydrate: false, persistenceStore: store })
  return { db, store }
}

const ids = (messages: readonly Message[]) => messages.map((value) => Number(value.messageId))

describe("Db.scanChatMessages", () => {
  it("lists one chat's matches newest first, pages with the cursor, and says when it is done", async () => {
    const { db } = await seeded()
    const first = await db.scanChatMessages(chat, photos, { limit: 4, maxScanned: 1_000 })
    expect(ids(first!.matches)).toEqual([30, 27, 24, 21])
    expect(first!.exhausted).toBe(false)
    expect(first!.lowest).toBe("21")

    const rest = await db.scanChatMessages(chat, photos, { limit: 100, maxScanned: 1_000, beforeMessageId: first!.lowest! })
    expect(ids(rest!.matches)).toEqual([18, 15, 12, 9, 6, 3])
    expect(rest!.exhausted).toBe(true)
    // The rows found are resident now.
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(chat, makeMessageId(3))))).toBeDefined()
  })

  it("stops at the scan budget and continues from where it stopped", async () => {
    const { db } = await seeded()
    const capped = await db.scanChatMessages(chat, photos, { limit: 100, maxScanned: 5 })
    expect(capped!.scanned).toBe(5)
    expect(ids(capped!.matches)).toEqual([30, 27])
    expect(capped!.exhausted).toBe(false)
    expect(capped!.lowest).toBe("26")
    const next = await db.scanChatMessages(chat, photos, { limit: 100, maxScanned: 5, beforeMessageId: capped!.lowest! })
    expect(ids(next!.matches)).toEqual([24, 21])
  })

  it("a write accepted during the read wins (invariant 13)", async () => {
    const { db } = await seeded()
    const read = db.scanChatMessages(chat, photos, { limit: 100, maxScanned: 1_000 })
    // Message 30 loses its photo and 27 is deleted while the read is in flight.
    const thirty = message(chat, 30, false)
    db.insert(thirty)
    db.delete(db.ref(DbObjectKind.Message, messageKey(chat, makeMessageId(27))))
    const result = await read
    expect(ids(result!.matches)).toEqual([24, 21, 18, 15, 12, 9, 6, 3])
  })

  it("a store that cannot scan answers undefined", async () => {
    const db = new Db({ autoHydrate: false })
    expect(await db.scanChatMessages(chat, photos, { limit: 10, maxScanned: 10 })).toBeUndefined()
  })
})

/**
 * The cost on a chat with 100,000 messages (5% photos, as the seeded
 * account has). Opt in: `INLINE_CHAT_SCAN_TIMING=1 bunx vitest run
 * src/database/__tests__/chat-scan.test.ts`.
 */
const timing = process.env.INLINE_CHAT_SCAN_TIMING === "1"
const report = (line: string) => process.stderr.write(`[chat scan timing] ${line}\n`)

describe.skipIf(!timing)("chat scan timing", () => {
  it("100,000 messages in one chat", { timeout: 600_000 }, async () => {
    const store = createSqliteMemoryPersistenceStore()
    await store.open()
    const summary = await writeSeedAccountToStore(store, {
      seed: 7,
      chats: 1,
      messages: 100_000,
      threadShare: 0,
    })
    void SEED_ACCOUNT_SCALES
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    const raw = await store.database()
    const chatIdRow = raw.exec({
      sql: "SELECT chat_id, count(*) FROM message GROUP BY chat_id ORDER BY count(*) DESC LIMIT 1",
      returnValue: "resultRows",
    })[0]!
    const target = makeChatId(String(chatIdRow[0]))
    report(`seeded ${summary.messages} messages; chat ${target} holds ${String(chatIdRow[1])}`)
    const plan = raw.exec({
      sql: "EXPLAIN QUERY PLAN SELECT payload FROM message WHERE chat_id = ? AND message_id > 0 AND message_id < ? ORDER BY message_id DESC LIMIT ?",
      bind: [BigInt(target), 1n << 60n, 256],
      returnValue: "resultRows",
    })
    report(`plan: ${plan.map((row) => String(row[3])).join(" | ")}`)

    const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)] ?? 0
    const measure = async (label: string, match: (value: Message) => boolean, limit: number, maxScanned: number) => {
      const samples: number[] = []
      let last: Awaited<ReturnType<Db["scanChatMessages"]>>
      for (let run = 0; run < 7; run += 1) {
        // A fresh Db each run, so nothing is resident.
        const fresh = new Db({ autoHydrate: false, persistenceStore: store })
        const started = performance.now()
        last = await fresh.scanChatMessages(target, match, { limit, maxScanned })
        samples.push(performance.now() - started)
      }
      report(
        `${label}: median ${median(samples).toFixed(1)} ms, max ${Math.max(...samples).toFixed(1)} ms; ` +
          `${last!.matches.length} matches, ${last!.scanned} rows read, exhausted ${last!.exhausted}`,
      )
    }
    await measure("photos, first 50 (5% density)", (value) => chatMediaMatches(value, "photos"), 50, 2_000)
    await measure("photos, first 50, no budget", (value) => chatMediaMatches(value, "photos"), 50, 100_000)
    await measure("files (none in the seed), budget 2,000", (value) => chatMediaMatches(value, "files"), 50, 2_000)
    await measure("files (none), whole chat", (value) => chatMediaMatches(value, "files"), 50, 100_000)
    void db
  })
})

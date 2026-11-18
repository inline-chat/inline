import type { Database, SqlValue } from "@sqlite.org/sqlite-wasm"
import { chatId as makeChatId, spaceId as makeSpaceId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { SEED_ACCOUNT_SCALES, writeSeedAccountToStore } from "../../testing/seed-account"
import { MessageSearch } from "../engine"
import { indexText } from "../normalize"

/**
 * The 300,000-message measurement (`search/README.md`, "Measurements").
 * Opt in: `INLINE_SEARCH_TIMING=1 bunx vitest run src/search/__tests__/timing.test.ts`.
 * `INLINE_SEARCH_TIMING_MESSAGES` changes the size.
 */
const enabled = process.env.INLINE_SEARCH_TIMING === "1"
const messages = Number(process.env.INLINE_SEARCH_TIMING_MESSAGES ?? SEED_ACCOUNT_SCALES.large.messages)
const chats = Math.max(20, Math.round((messages / SEED_ACCOUNT_SCALES.large.messages) * SEED_ACCOUNT_SCALES.large.chats))

const report = (line: string) => process.stderr.write(`[search timing] ${line}\n`)

const value = (db: Database, sql: string, bind?: SqlValue[]) =>
  Number((db.exec({ sql, ...(bind ? { bind } : {}), rowMode: "array", returnValue: "resultRows" }) as SqlValue[][])[0]?.[0] ?? 0)

/** Bytes in used pages (free pages left by a drop do not count). */
const bytes = (db: Database) =>
  (value(db, "PRAGMA page_count") - value(db, "PRAGMA freelist_count")) * value(db, "PRAGMA page_size")

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)] ?? 0
}

const time = async (runs: number, fn: () => Promise<unknown>) => {
  await fn()
  const samples: number[] = []
  for (let k = 0; k < runs; k++) {
    const started = performance.now()
    await fn()
    samples.push(performance.now() - started)
  }
  return { median: median(samples), max: Math.max(...samples) }
}

describe.skipIf(!enabled)("search timing on a seeded account", () => {
  it(`${messages} messages: index size, query latency, backfill throughput`, { timeout: 1_800_000 }, async () => {
    const store = createSqliteMemoryPersistenceStore()
    await store.open()
    let started = performance.now()
    const summary = await writeSeedAccountToStore(store, { seed: 7, chats, messages })
    const seedMs = performance.now() - started
    report(`seeded ${summary.messages} messages in ${summary.chats} chats in ${(seedMs / 1000).toFixed(1)} s (store writes with live indexing)`)

    const db = new Db({ autoHydrate: false, persistenceStore: store })
    const search = new MessageSearch({ db, store, pause: async () => {} })
    const facts = await store.readSearchIndex((raw) => ({
      total: bytes(raw),
      docs: value(raw, "SELECT count(*) FROM message_search_doc"),
      biggestChat: String(raw.exec({ sql: "SELECT chat_id FROM message GROUP BY chat_id ORDER BY count(*) DESC LIMIT 1", returnValue: "resultRows" })[0]?.[0]),
      biggestChatSize: value(raw, "SELECT count(*) FROM message GROUP BY chat_id ORDER BY count(*) DESC LIMIT 1"),
      space: String(raw.exec({ sql: "SELECT space_id FROM chat WHERE space_id IS NOT NULL GROUP BY space_id ORDER BY count(*) DESC LIMIT 1", returnValue: "resultRows" })[0]?.[0]),
    }))
    const breakdown = await store.readSearchIndex((raw) => {
      try {
        return (raw.exec({
          sql: "SELECT name, sum(pgsize) FROM dbstat WHERE name LIKE 'message%' GROUP BY name ORDER BY 2 DESC",
          rowMode: "array",
          returnValue: "resultRows",
        }) as SqlValue[][]).map(([name, size]) => `${String(name)} ${(Number(size) / 1e6).toFixed(1)} MB`)
      } catch {
        return ["dbstat not available"]
      }
    })
    report(`tables: ${breakdown.join(", ")}`)
    report(`replica ${(facts.total / 1e6).toFixed(1)} MB, ${facts.docs} indexed messages; biggest chat ${facts.biggestChat} with ${facts.biggestChatSize}`)

    const queries: Array<[string, () => Promise<unknown>]> = [
      ["deploy (common word)", () => search.search({ query: "deploy" })],
      ["rev (3-letter prefix)", () => search.search({ query: "rev" })],
      ["re (2-letter prefix)", () => search.search({ query: "re" })],
      ["deploy t (one-letter last word)", () => search.search({ query: "deploy t" })],
      ["release notes (two words)", () => search.search({ query: "release notes" })],
      ['"ship the" (phrase)', () => search.search({ query: '"review the"' })],
      ["migrat latenc (two rare-ish prefixes)", () => search.search({ query: "migrat latenc" })],
      ["确认 (CJK)", () => search.search({ query: "确认" })],
      ["مرحبا (Arabic)", () => search.search({ query: "مرحبا" })],
      ["cafe (folded accent)", () => search.search({ query: "cafe" })],
      ["zqxw (no match)", () => search.search({ query: "zqxw" })],
      ["deploy in one space", () => search.search({ query: "deploy", spaceId: makeSpaceId(facts.space) })],
      ["deploy, relevance", () => search.search({ query: "deploy", sort: "relevance" })],
      ["find in biggest chat: the (100)", () => search.findInChat({ chatId: makeChatId(facts.biggestChat), query: "the" })],
      ["count in biggest chat: the", () => search.count({ query: "the", chatId: makeChatId(facts.biggestChat) })],
      ["count everywhere: deploy (capped)", () => search.count({ query: "deploy" })],
    ]
    const timings: Record<string, number> = {}
    for (const [name, run] of queries) {
      const { median: ms, max } = await time(15, run)
      timings[name] = ms
      report(`${name}: median ${ms.toFixed(2)} ms, max ${max.toFixed(2)} ms`)
    }
    expect(timings["deploy (common word)"]).toBeLessThan(20)

    // The live index after incremental writes, then fully merged.
    const optimizeStarted = performance.now()
    await store.writeSearchIndex((raw) => raw.exec("INSERT INTO message_search(message_search) VALUES ('optimize')"))
    const optimizeMs = performance.now() - optimizeStarted
    const optimized = await store.readSearchIndex(bytes)
    report(`'optimize' took ${optimizeMs.toFixed(0)} ms and saved ${((facts.total - optimized) / 1e6).toFixed(1)} MB`)
    facts.total = optimized

    // Index size: drop the index, vacuum, compare.
    await store.writeSearchIndex((raw) => {
      raw.exec("INSERT INTO message_search(message_search) VALUES ('delete-all')")
      raw.exec("DROP TRIGGER message_search_doc_ad")
      raw.exec("DELETE FROM message_search_doc")
    })
    await store.readSearchIndex((raw) => raw.exec("VACUUM"))
    const withoutIndex = await store.readSearchIndex(bytes)
    const indexBytes = facts.total - withoutIndex
    report(`index (optimized) ${(indexBytes / 1e6).toFixed(1)} MB in all, ${((indexBytes / facts.docs) * 100_000 / 1e6).toFixed(1)} MB per 100,000 indexed messages; replica without it ${(withoutIndex / 1e6).toFixed(1)} MB`)

    // Alternative configurations, filled with the same folded bodies.
    const bodies = await store.readSearchIndex((raw) => {
      const out: string[] = []
      const rows = raw.exec({ sql: "SELECT payload FROM message", rowMode: "array", returnValue: "resultRows" }) as SqlValue[][]
      return { rows, out }
    })
    const { decodeInlineModel } = await import("../../database/model-codec")
    const folded = bodies.rows.map((row) => indexText((decodeInlineModel(row[0] as Uint8Array) as { message?: string }).message))
    const variants: Array<[string, string]> = [
      ["no prefix index", "prefix = ''"],
      ["prefix 2 3 (chosen)", "prefix = '2 3'"],
      ["prefix 2 3 4 (Mac)", "prefix = '2 3 4'"],
      ["prefix 1 2 3", "prefix = '1 2 3'"],
    ]
    for (const [name, option] of variants) {
      const size = await store.writeSearchIndex((raw) => {
        const before = bytes(raw)
        raw.exec(`CREATE VIRTUAL TABLE variant USING fts5(body, chat, content = '', contentless_delete = 1,
          tokenize = "unicode61 remove_diacritics 0 categories 'L* N* M* P* S* C*'"${option === "prefix = ''" ? "" : `, ${option}`})`)
        const insert = raw.prepare("INSERT INTO variant(rowid, body, chat) VALUES (?, ?, 'c1')")
        folded.forEach((body, index) => {
          if (body.length === 0) return
          insert.bind([index + 1, body]).stepReset()
        })
        insert.finalize()
        raw.exec("INSERT INTO variant(variant) VALUES ('optimize')")
        const after = bytes(raw)
        raw.exec("DROP TABLE variant")
        return after - before
      })
      report(`${name}: ${((size / facts.docs) * 100_000 / 1e6).toFixed(1)} MB per 100,000 messages (FTS tables only)`)
    }
    const trigram = await store.writeSearchIndex((raw) => {
      const before = bytes(raw)
      raw.exec("CREATE VIRTUAL TABLE variant USING fts5(body, content = '', contentless_delete = 1, tokenize = 'trigram')")
      const insert = raw.prepare("INSERT INTO variant(rowid, body) VALUES (?, ?)")
      folded.forEach((body, index) => {
        if (body.length > 0) insert.bind([index + 1, body]).stepReset()
      })
      insert.finalize()
      raw.exec("INSERT INTO variant(variant) VALUES ('optimize')")
      const after = bytes(raw)
      raw.exec("DROP TABLE variant")
      return after - before
    })
    report(`trigram over the folded text: ${((trigram / facts.docs) * 100_000 / 1e6).toFixed(1)} MB per 100,000 messages`)
    await store.readSearchIndex((raw) => raw.exec("VACUUM"))

    // Backfill throughput: rebuild everything through the real backfill.
    await store.writeSearchIndex((raw) => {
      raw.exec(`CREATE TRIGGER message_search_doc_ad AFTER DELETE ON message_search_doc BEGIN
        DELETE FROM message_search WHERE rowid = old.id; END`)
      raw.exec(`UPDATE inline_replica_metadata SET value = '{"version":1,"state":"building"}' WHERE key = 'message_search'`)
    })
    const batchTimes: number[] = []
    let last = performance.now()
    const backfill = new MessageSearch({
      db,
      store,
      backfillBatchSize: 250,
      pause: async () => {
        const now = performance.now()
        batchTimes.push(now - last)
        last = performance.now()
      },
    })
    started = performance.now()
    last = started
    await backfill.start()
    const backfillMs = performance.now() - started
    report(
      `backfill of ${facts.docs} messages in ${(backfillMs / 1000).toFixed(1)} s, ${batchTimes.length + 1} batches of 250: median ${median(batchTimes).toFixed(1)} ms, max ${Math.max(...batchTimes).toFixed(1)} ms per batch`,
    )
    expect(backfill.status()).toEqual({ state: "ready" })
    await backfill.stop()
    await search.stop()
    await store.close()
  })
})

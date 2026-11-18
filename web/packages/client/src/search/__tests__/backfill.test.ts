import type { Database } from "@sqlite.org/sqlite-wasm"
import { chatId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { encodeInlineModel } from "../../database/model-codec"
import {
  INLINE_SQLITE_SCHEMA_VERSION,
  migrateInlineSqlite,
} from "../../database/sqlite/schema"
import { SQLitePersistenceStore } from "../../database/sqlite/SQLitePersistenceStore"
import { MessageSearch, type MessageSearchIndexStatus } from "../engine"
import { indexDisagreements, message, sharedDatabase } from "./fixture"

const tables = (db: Database) =>
  db
    .exec({ sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'trigger') ORDER BY name", returnValue: "resultRows" })
    .map((row) => String(row[0]))

const insertRawMessages = (db: Database, chat: number, count: number, text = (id: number) => `stored note ${id}`) => {
  for (let id = 1; id <= count; id++) {
    db.exec({
      sql: "INSERT INTO message(chat_id, message_id, date_order, payload) VALUES (?, ?, ?, ?)",
      bind: [BigInt(chat), BigInt(id), id, encodeInlineModel(message(chat, id, text(id)))],
    })
  }
}

type Gate = { wait: () => Promise<void>; open: () => void; waiting: () => number }
const gate = (): Gate => {
  let resolvers: Array<() => void> = []
  let opened = false
  return {
    wait: () => (opened ? Promise.resolve() : new Promise<void>((resolve) => resolvers.push(resolve))),
    open: () => {
      opened = true
      for (const resolve of resolvers) resolve()
      resolvers = []
    },
    waiting: () => resolvers.length,
  }
}

const flush = async () => {
  for (let k = 0; k < 20; k++) await Promise.resolve()
}

describe("upgrade to schema version 5", () => {
  for (let earlier = 0; earlier < INLINE_SQLITE_SCHEMA_VERSION; earlier++) {
    it(`from schema version ${earlier}: adds the index, then indexes stored messages in the background`, async () => {
      const { database, dispose } = await sharedDatabase()
      expect(migrateInlineSqlite(database, earlier)).toBe(earlier)
      expect(tables(database)).not.toContain("message_search")
      if (earlier >= 1) {
        insertRawMessages(database, 10, 25)
        // Not indexable: a temporary ID and an empty text.
        database.exec({
          sql: "INSERT INTO message(chat_id, message_id, date_order, payload) VALUES (?, ?, ?, ?)",
          bind: [10n, -5n, 0, encodeInlineModel(message(10, -5, "stored temporary"))],
        })
        database.exec({
          sql: "INSERT INTO message(chat_id, message_id, date_order, payload) VALUES (?, ?, ?, ?)",
          bind: [10n, 99n, 0, encodeInlineModel(message(10, 99, ""))],
        })
      }
      const store = new SQLitePersistenceStore(async () => database)
      await store.open()
      expect(tables(database)).toEqual(
        expect.arrayContaining([
          "message_search",
          "message_search_doc",
          "message_search_doc_ad",
          "message_search_message_ad",
        ]),
      )
      const db = new Db({ autoHydrate: false, persistenceStore: store })
      const search = new MessageSearch({ db, store, backfillBatchSize: 4, pause: async () => {} })
      const before = await search.search({ query: "stored" })
      expect(before.hits).toEqual([])
      expect(before.indexComplete).toBe(earlier === 0)
      await search.start()
      expect(search.status()).toEqual({ state: "ready" })
      const after = await search.search({ query: "stored", limit: 100 })
      expect(after.indexComplete).toBe(true)
      expect(after.hits.length).toBe(earlier >= 1 ? 25 : 0)
      expect(await store.readSearchIndex(indexDisagreements)).toEqual([])
      await search.stop()
      dispose()
    })
  }
})

describe("backfill", () => {
  it("resumes after a restart from the progress stored in the replica", async () => {
    const { database, dispose } = await sharedDatabase()
    migrateInlineSqlite(database, 4)
    insertRawMessages(database, 10, 30)
    insertRawMessages(database, 11, 30)
    const statuses: MessageSearchIndexStatus[] = []
    const firstStore = new SQLitePersistenceStore(async () => database)
    await firstStore.open()
    const firstGate = gate()
    const first = new MessageSearch({
      db: new Db({ autoHydrate: false, persistenceStore: firstStore }),
      store: firstStore,
      backfillBatchSize: 10,
      pause: () => firstGate.wait(),
    })
    first.subscribe((status) => statuses.push(status))
    const running = first.start()
    // Let three batches commit, then "close the tab".
    for (let k = 0; k < 3; k++) {
      while (firstGate.waiting() === 0) await flush()
      if (k < 2) {
        const waiting = firstGate
        // Release just this pause.
        waiting.open()
        Object.assign(firstGate, gate())
      }
    }
    const stopped = first.stop()
    firstGate.open()
    await running
    await stopped
    expect(statuses.filter((status) => status.state === "building").length).toBeGreaterThanOrEqual(3)
    const partial = await firstStore.readSearchIndex((db) => Number(db.selectValue("SELECT count(*) FROM message_search_doc")))
    expect(partial).toBe(30)

    // A new process continues where the first stopped: nothing is read twice.
    const secondStore = new SQLitePersistenceStore(async () => database)
    const second = new MessageSearch({
      db: new Db({ autoHydrate: false, persistenceStore: secondStore }),
      store: secondStore,
      backfillBatchSize: 10,
      pause: async () => {},
    })
    const progress: MessageSearchIndexStatus[] = []
    second.subscribe((status) => progress.push(status))
    await second.start()
    expect(progress[0]).toEqual({ state: "building", indexed: 30, total: 60 })
    expect(progress.at(-1)).toEqual({ state: "ready" })
    expect(progress.flatMap((status) => (status.state === "building" ? [status.indexed] : []))).toEqual([30, 40, 50, 60])
    expect(await secondStore.readSearchIndex(indexDisagreements)).toEqual([])
    await second.stop()
    dispose()
  })

  it("never blocks a read: rows load and partial search answers while a batch is held open", async () => {
    const { database, dispose } = await sharedDatabase()
    migrateInlineSqlite(database, 4)
    insertRawMessages(database, 10, 40)
    let holdBackfill: Gate | undefined
    const store = new SQLitePersistenceStore(async () => database, {
      onWriteCheckpoint: async ({ phase, operationCount }) => {
        // operationCount 0: a search-index transaction (the backfill).
        if (phase === "after-begin" && operationCount === 0 && holdBackfill) await holdBackfill.wait()
      },
    })
    await store.open()
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    const betweenBatches = gate()
    const search = new MessageSearch({ db, store, backfillBatchSize: 10, pause: () => betweenBatches.wait() })
    const running = search.start()
    while (betweenBatches.waiting() === 0) await flush()

    // Between batches: a search answers with what is indexed and says it is partial.
    const partial = await search.search({ query: "stored", limit: 100 })
    expect(partial.indexComplete).toBe(false)
    expect(partial.hits.length).toBe(10)
    expect(search.status()).toMatchObject({ state: "building", indexed: 10, total: 40 })

    // A batch held inside its transaction does not hold a local read.
    holdBackfill = gate()
    betweenBatches.open()
    while (holdBackfill.waiting() === 0) await flush()
    const rows = await db.hydrateMessageWindow(chatId(10), { limit: 20 })
    expect(rows).toBeGreaterThan(0)
    expect(holdBackfill.waiting()).toBe(1)
    holdBackfill.open()
    await running
    expect((await search.count({ query: "stored" })).count).toBe(40)
    await search.stop()
    dispose()
  })

  it("rebuilds when the folding rules change (an older normalizer version)", async () => {
    const { database, dispose } = await sharedDatabase()
    const store = new SQLitePersistenceStore(async () => database)
    await store.open()
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    db.insert(message(10, 1, "versioned text"))
    await db.flushPersistence()
    database.exec(
      `UPDATE inline_replica_metadata SET value = '{"version":0,"state":"ready"}' WHERE key = 'message_search'`,
    )
    const search = new MessageSearch({ db, store, pause: async () => {} })
    expect((await search.search({ query: "versioned" })).indexComplete).toBe(false)
    await search.start()
    expect(search.status()).toEqual({ state: "ready" })
    expect((await search.search({ query: "versioned" })).hits.length).toBe(1)
    await search.stop()
    dispose()
  })

  it("gives up after a bounded number of failed batches, in a visible state", async () => {
    const { database, dispose } = await sharedDatabase()
    migrateInlineSqlite(database, 4)
    insertRawMessages(database, 10, 5)
    let attempts = 0
    const store = new SQLitePersistenceStore(async () => database, {
      onWriteCheckpoint: ({ phase, operationCount }) => {
        if (phase === "before-commit" && operationCount === 0) {
          attempts += 1
          throw new Error("quota exceeded")
        }
      },
    })
    await store.open()
    const search = new MessageSearch({
      db: new Db({ autoHydrate: false, persistenceStore: store }),
      store,
      pause: async () => {},
    })
    await search.start()
    expect(attempts).toBe(3)
    expect(search.status()).toEqual({ state: "failed", message: "quota exceeded" })
    expect(await store.readSearchIndex((db) => Number(db.selectValue("SELECT count(*) FROM message_search_doc")))).toBe(0)
    await search.stop()
    dispose()
  })
})

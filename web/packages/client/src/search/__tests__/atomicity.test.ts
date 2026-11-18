import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { encodeInlineModel } from "../../database/model-codec"
import { DbObjectKind, messageKey } from "../../database/models"
import { migrateInlineSqlite } from "../../database/sqlite/schema"
import {
  SQLitePersistenceStore,
  type InlineSqliteWriteCheckpoint,
} from "../../database/sqlite/SQLitePersistenceStore"
import { MessageSearch } from "../engine"
import { indexDisagreements, message, sharedDatabase } from "./fixture"

const PHASES: InlineSqliteWriteCheckpoint["phase"][] = ["after-begin", "before-commit", "after-commit"]

class Crash extends Error {}

/** A store on the shared database that crashes once at `phase` when `armed` says so. */
const processOn = (
  database: Awaited<ReturnType<typeof sharedDatabase>>["database"],
  rule?: { phase: InlineSqliteWriteCheckpoint["phase"]; armed: () => boolean },
) => {
  let fired = false
  const store = new SQLitePersistenceStore(async () => database, {
    onWriteCheckpoint: ({ phase }) => {
      if (fired && rule) throw new Crash("dead process")
      if (rule && !fired && phase === rule.phase && rule.armed()) {
        fired = true
        throw new Crash(`crash at ${phase}`)
      }
    },
  })
  return { store, fired: () => fired }
}

describe("invariants 1 and 6: a message and its index entry commit together", () => {
  for (const phase of PHASES) {
    it(`a crash at ${phase} leaves messages and index in agreement`, async () => {
      const { database, dispose } = await sharedDatabase()
      // A committed baseline.
      {
        const { store } = processOn(database)
        const db = new Db({ autoHydrate: false, persistenceStore: store })
        db.insert({ kind: DbObjectKind.Chat, id: chatId(10) })
        for (let id = 1; id <= 5; id++) db.insert(message(10, id, `baseline ${id}`))
        await db.flushPersistence()
      }
      // The crashing process: one write that adds, edits and deletes.
      let armed = false
      const crashing = processOn(database, { phase, armed: () => armed })
      const db = new Db({ autoHydrate: false, persistenceStore: crashing.store })
      armed = true
      await db
        .commit(() => {
          db.insert(message(10, 6, "fresh crash text"))
          db.update(message(10, 1, "edited crash text"))
          db.delete(db.ref(DbObjectKind.Message, messageKey(chatId(10), messageId(2))))
        })
        .catch(() => undefined)
      expect(crashing.fired()).toBe(true)

      // The next process sees one consistent state.
      const { store } = processOn(database)
      await store.open()
      expect(await store.readSearchIndex(indexDisagreements)).toEqual([])
      const restarted = new Db({ autoHydrate: false, persistenceStore: store })
      const search = new MessageSearch({ db: restarted, store, pause: async () => {} })
      const crashText = (await search.search({ query: "crash text" })).hits.map((hit) => hit.text)
      const baseline = (await search.search({ query: "baseline" })).hits.map((hit) => hit.text)
      if (phase === "after-commit") {
        expect(crashText).toEqual(["fresh crash text", "edited crash text"])
        expect(baseline).toEqual(["baseline 5", "baseline 4", "baseline 3"])
      } else {
        expect(crashText).toEqual([])
        expect(baseline).toEqual(["baseline 5", "baseline 4", "baseline 3", "baseline 2", "baseline 1"])
      }
      await search.stop()
      dispose()
    })

    it(`a backfill batch crashing at ${phase} keeps its progress and entries together, and resumes`, async () => {
      const { database, dispose } = await sharedDatabase()
      migrateInlineSqlite(database, 4)
      for (let id = 1; id <= 40; id++) {
        database.exec({
          sql: "INSERT INTO message(chat_id, message_id, date_order, payload) VALUES (?, ?, ?, ?)",
          bind: [10n, BigInt(id), id, encodeInlineModel(message(10, id, `stored ${id}`))],
        })
      }
      let batches = 0
      const crashing = processOn(database, { phase, armed: () => ++batches === 3 })
      await crashing.store.open()
      const db = new Db({ autoHydrate: false, persistenceStore: crashing.store })
      const first = new MessageSearch({ db, store: crashing.store, backfillBatchSize: 7, pause: async () => {} })
      await first.start()
      expect(crashing.fired()).toBe(true)
      // Whole batches only: two committed, the third only if it crashed after COMMIT.
      const indexed = await crashing.store.readSearchIndex(
        (db) => Number(db.selectValue("SELECT count(*) FROM message_search_doc")),
      )
      expect(indexed).toBe(phase === "after-commit" ? 21 : 14)

      const { store } = processOn(database)
      const second = new MessageSearch({
        db: new Db({ autoHydrate: false, persistenceStore: store }),
        store,
        backfillBatchSize: 7,
        pause: async () => {},
      })
      expect((await second.search({ query: "stored" })).indexComplete).toBe(false)
      await second.start()
      expect(second.status()).toEqual({ state: "ready" })
      expect(await store.readSearchIndex(indexDisagreements)).toEqual([])
      expect((await second.count({ query: "stored" })).count).toBe(40)
      await first.stop()
      await second.stop()
      dispose()
    })
  }
})

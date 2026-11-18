import initializeSqlite, { type Database } from "@sqlite.org/sqlite-wasm"
import { userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { encodeInlineModel } from "../model-codec"
import { DbObjectKind } from "../models"
import {
  INLINE_SQLITE_SCHEMA_VERSION,
  InlineSqliteMigrationError,
  isInlineSqliteSchemaTooNew,
  migrateInlineSqlite,
} from "./schema"
import { SQLitePersistenceStore } from "./SQLitePersistenceStore"

const VERSION_4_TABLES = [
  "space_member",
  "chat_participant",
  "chat_participant_group",
  "user_group",
  "dialog_folder",
  "user_settings",
]

const rawDatabase = async () => {
  const sqlite3 = await initializeSqlite()
  return new sqlite3.oo1.DB(":memory:", "c")
}

const tables = (db: Database) =>
  db
    .exec({
      sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      rowMode: "object",
      returnValue: "resultRows",
    })
    .map((row) => String(row.name))

/** A store over one existing database that survives the store closing it. */
const storeOver = (db: Database) => {
  const close = db.close.bind(db)
  db.close = (() => db) as Database["close"]
  return {
    store: new SQLitePersistenceStore(async () => db),
    dispose: () => close(),
  }
}

describe("invariant 9: a replica from a newer schema is never opened or written", () => {
  it("invariant 9: stops on a newer schema before writing anything, with a typed outdated error", async () => {
    const db = await rawDatabase()
    migrateInlineSqlite(db)
    db.exec({
      sql: `INSERT INTO inline_schema_migration(version, name, applied_at)
        VALUES (?, ?, ?)`,
      bind: [INLINE_SQLITE_SCHEMA_VERSION + 1, "future_schema", 1],
    })
    const before = tables(db)
    const { store, dispose } = storeOver(db)

    const opened = store.open()
    await expect(opened).rejects.toBeInstanceOf(InlineSqliteMigrationError)
    const error = await opened.catch((reason: unknown) => reason)
    expect(isInlineSqliteSchemaTooNew(error)).toBe(true)
    expect(error).toMatchObject({
      storedVersion: INLINE_SQLITE_SCHEMA_VERSION + 1,
      supportedVersion: INLINE_SQLITE_SCHEMA_VERSION,
    })
    // The message the host matches on today is unchanged.
    expect((error as Error).message).toMatch(/newer than supported/)

    // The store never becomes the writer.
    await expect(
      store.write([
        {
          type: "put",
          object: { kind: DbObjectKind.User, id: userId(7) },
        },
      ]),
    ).rejects.toThrow(/newer than supported/)
    expect(tables(db)).toEqual(before)
    expect(
      db.exec({
        sql: "SELECT COUNT(*) AS count FROM user",
        rowMode: "object",
        returnValue: "resultRows",
      })[0]?.count,
    ).toBe(0)
    dispose()
  })

  for (
    let earlier = 0;
    earlier < INLINE_SQLITE_SCHEMA_VERSION;
    earlier += 1
  ) {
    it(`invariants 5 and 9: upgrades a replica at schema version ${earlier}, keeps its rows, and starts with no certified history`, async () => {
      const db = await rawDatabase()
      expect(migrateInlineSqlite(db, earlier)).toBe(earlier)
      const { store, dispose } = storeOver(db)
      if (earlier >= 1) {
        // Version 1 created the model tables: keep a row through the
        // upgrade, written with raw SQL so nothing migrates it first.
        db.exec({
          sql: "INSERT INTO user(id, payload) VALUES (?, ?)",
          bind: [
            7n,
            encodeInlineModel({
              kind: DbObjectKind.User,
              id: userId(7),
              firstName: "Kept",
            }),
          ],
        })
      }
      if (earlier < 3) {
        expect(tables(db)).not.toContain("message_history_coverage")
      }
      if (earlier < 4) {
        for (const table of VERSION_4_TABLES) expect(tables(db)).not.toContain(table)
      }

      await store.open()
      expect(migrateInlineSqlite(db)).toBe(INLINE_SQLITE_SCHEMA_VERSION)
      expect(tables(db)).toEqual(
        expect.arrayContaining([
          "inline_replica_metadata",
          "message_history_coverage",
          ...VERSION_4_TABLES,
        ]),
      )
      // The membership and settings models start empty.
      for (const kind of [
        DbObjectKind.SpaceMember,
        DbObjectKind.ChatParticipant,
        DbObjectKind.ChatParticipantGroup,
        DbObjectKind.UserGroup,
        DbObjectKind.DialogFolder,
        DbObjectKind.UserSettings,
      ]) {
        expect(await store.collection(kind).getAll()).toEqual([])
      }
      if (earlier >= 1) {
        expect(
          await store.collection(DbObjectKind.User).get(userId(7)),
        ).toMatchObject({ firstName: "Kept" })
      }
      // No coverage row: every chat's history starts as a hole.
      expect(await store.collection(DbObjectKind.HistoryCoverage).getAll()).toEqual([])
      dispose()
    })
  }
})

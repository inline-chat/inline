import initializeSqlite, { type Database } from "@sqlite.org/sqlite-wasm"
import { Update, UserGroup } from "@inline-chat/protocol/core"
import { inlineId, spaceId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { encodeInlineModel } from "../../database/model-codec"
import { DbObjectKind, spaceMemberKey, type DbModel } from "../../database/models"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { migrateInlineSqlite } from "../../database/sqlite/schema"

/** The schema version that added `deferred_update.update_type`. */
const DEFERRED_UPDATE_TYPE_VERSION = 4
import { SQLitePersistenceStore } from "../../database/sqlite/SQLitePersistenceStore"
import { DbQueryPlanType } from "../../database/types"
import { getDialogId } from "../transactions/mappers"
import { bindAccountUser } from "../updates/account-context"
import {
  deferredUpdateRecord,
  deferredUserGroupRecord,
} from "../updates/apply-updates"
import { replayProjectedDeferredUpdates } from "../updates/deferred-replay"
import {
  chatPeer,
  createSyncEngine,
  JournalClient,
  SELF,
  SPACE,
  seedAccount,
  THREAD,
  update,
} from "./update-coverage-fixtures"

const memberAdd = (seq: number) =>
  update(seq, {
    oneofKind: "spaceMemberAdd",
    spaceMemberAdd: {
      member: { id: 100n, spaceId: 5n, userId: 3n, date: 1_000n, canAccessPublicChats: true },
    },
  })

const notificationNone = (seq: number) =>
  update(seq, {
    oneofKind: "dialogNotificationSettings",
    dialogNotificationSettings: {
      peerId: chatPeer(10n),
      notificationSettings: { mode: 3 },
    },
  })

const group = UserGroup.create({
  id: 30n,
  spaceId: 5n,
  name: "Design",
  memberCount: 1,
  userIds: [1n],
  currentUserIsMember: true,
  date: 900n,
})

const unknownKind = update(7, { oneofKind: "agentSettings", agentSettings: {} })

describe("deferred replay keeps what it cannot project (invariant 7)", () => {
  it("retains malformed payloads, still-raw updates and kinds without a model", async () => {
    const store = createSqliteMemoryPersistenceStore()
    const older = new Db({ autoHydrate: false, persistenceStore: store })
    seedAccount(older)
    const malformed = { ...deferredUpdateRecord(memberAdd(3)), payload: new Uint8Array([0xff, 0x01]) }
    // A spaceMemberAdd without its member: the projection keeps it raw.
    const incomplete = deferredUpdateRecord(
      update(4, { oneofKind: "spaceMemberAdd", spaceMemberAdd: {} }),
    )
    older.batch(() => {
      older.replace(malformed)
      older.replace(incomplete)
      older.replace(deferredUpdateRecord(unknownKind))
      older.replace(deferredUserGroupRecord(group))
      older.replace(deferredUpdateRecord(memberAdd(5)))
    })
    await older.flushPersistence()

    const db = new Db({ persistenceStore: store })
    await db.ready
    bindAccountUser(db, () => SELF)
    db.delete(db.ref(DbObjectKind.UserGroup, inlineId(30)))
    expect(await replayProjectedDeferredUpdates(db)).toEqual({ applied: 2, retained: 2 })
    await db.flushPersistence()

    expect(db.get(db.ref(DbObjectKind.UserGroup, inlineId(30)))?.name).toBe("Design")
    expect(
      db.get(db.ref(DbObjectKind.SpaceMember, spaceMemberKey(SPACE, userId(3))))?.memberId,
    ).toBe("100")
    const left = (await store.collection(DbObjectKind.DeferredUpdate).getAll())
      .map((row) => row.id)
      .sort()
    expect(left).toEqual(
      [malformed.id, incomplete.id, deferredUpdateRecord(unknownKind).id].sort(),
    )
  })
})

const rawDatabase = async () => {
  const sqlite3 = await initializeSqlite()
  return new sqlite3.oo1.DB(":memory:", "c")
}

/** A store over one existing database that survives the store closing it. */
const storeOver = (db: Database) => {
  const close = db.close.bind(db)
  db.close = (() => db) as Database["close"]
  return {
    store: new SQLitePersistenceStore(async () => db),
    dispose: () => close(),
  }
}

const insertModel = (db: Database, table: string, columns: string, values: unknown[], model: DbModel) => {
  db.exec({
    sql: `INSERT INTO ${table}(${columns}, payload) VALUES (${values.map(() => "?").join(", ")}, ?)`,
    bind: [...values, encodeInlineModel(model)] as never,
  })
}

describe("upgrade: raw rows written by an older schema replay into the new models", () => {
  // Raw rows without `update_type` exist only in replicas written before
  // version 4 added the column; a version-4 build always writes it. Every
  // later migration still runs on these upgrades.
  for (let earlier = 1; earlier < DEFERRED_UPDATE_TYPE_VERSION; earlier += 1) {
    it(`from schema version ${earlier}: backfills the kind of each raw row and replays it on the first connection`, async () => {
      const raw = await rawDatabase()
      expect(migrateInlineSqlite(raw, earlier)).toBe(earlier)
      const dialogId = getDialogId({ peerThreadId: THREAD })
      insertModel(raw, "space", "id, date", [5n, 100], {
        kind: DbObjectKind.Space, id: SPACE, name: "Space", creator: false, date: 100,
      })
      insertModel(raw, "chat", "id, space_id", [10n, 5n], {
        kind: DbObjectKind.Chat, id: THREAD, title: "Thread", spaceId: SPACE,
      })
      insertModel(raw, "dialog", "id, chat_id", [BigInt(dialogId), 10n], {
        kind: DbObjectKind.Dialog, id: dialogId, chatId: THREAD, peerThreadId: THREAD,
      })
      const rows = [
        deferredUpdateRecord(memberAdd(1)),
        deferredUpdateRecord(notificationNone(2)),
        deferredUpdateRecord(unknownKind),
        deferredUserGroupRecord(group),
      ]
      for (const row of rows) {
        insertModel(
          raw,
          "deferred_update",
          "id, bucket_id, target_key, seq, date",
          [row.id, row.bucketId, null, row.seq ?? null, row.date ?? null],
          row,
        )
      }
      const { store, dispose } = storeOver(raw)
      await store.open()
      // The migration read each row's kind from its payload.
      expect(
        raw.exec({
          sql: "SELECT update_type FROM deferred_update ORDER BY update_type",
          rowMode: "array",
          returnValue: "resultRows",
        }).map((row) => row[0]),
      ).toEqual(["agentSettings", "dialogNotificationSettings", "sidecarUserGroup", "spaceMemberAdd"])

      const db = new Db({ persistenceStore: store })
      await db.ready
      bindAccountUser(db, () => SELF)
      const engine = createSyncEngine(db, new JournalClient())
      await engine.connectionOpened()
      await engine.idle()
      await engine.stop()
      await db.flushPersistence()

      expect(
        db.get(db.ref(DbObjectKind.SpaceMember, spaceMemberKey(spaceId(5), userId(3)))),
      ).toMatchObject({ memberId: "100", canAccessPublicChats: true })
      expect(db.get(db.ref(DbObjectKind.Dialog, dialogId))?.notificationMode).toBe("none")
      expect(db.get(db.ref(DbObjectKind.UserGroup, inlineId(30)))?.name).toBe("Design")
      // Only the kind with no model is still raw.
      expect(
        (await store.collection(DbObjectKind.DeferredUpdate).getAll()).map((row) => row.updateType),
      ).toEqual(["agentSettings"])
      expect(
        db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.SpaceMember),
      ).toHaveLength(1)
      dispose()
    })
  }
})

describe("deferred record identity", () => {
  it("stores a raw update losslessly with its kind", () => {
    const record = deferredUpdateRecord(unknownKind)
    expect(record).toMatchObject({ bucketId: "unbucketed", seq: 7, updateType: "agentSettings" })
    expect(Update.fromBinary(record.payload)).toEqual(unknownKind)
  })
})

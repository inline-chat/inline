import { IDBDatabase, IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { Update } from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import { Db } from "../../database"
import { DbObjectKind, messageKey } from "../../database/models"
import { DbSyncStorage } from "../sync/db-sync-storage"
import {
  upsertChat,
  upsertDialog,
  upsertMessage,
} from "../transactions/mappers"
import { updateBucketKey } from "../sync/update-bucket-key"
import { applyUpdates } from "../updates"

const target = chatId(801)
const keep = chatId(802)
const metadata = [DbObjectKind.Chat, DbObjectKind.Dialog] as const
const removal = Update.create({
  seq: 1,
  date: 100n,
  update: {
    oneofKind: "userRemovedFromChat",
    userRemovedFromChat: { chatId: 801n },
  },
})

const seed = async (db: Db) => {
  await db.commit(() => {
    for (const id of [target, keep]) {
      db.insert({ kind: DbObjectKind.Chat, id, title: `chat ${id}` })
      db.insert({
        kind: DbObjectKind.Dialog,
        id: dialogId(-BigInt(id)),
        chatId: id,
        peerThreadId: id,
      })
      db.insert({
        kind: DbObjectKind.Message,
        id: messageKey(id, messageId(1)),
        messageId: messageId(1),
        chatId: id,
        fromId: userId(7),
        message: "private history",
      })
    }
  })
}

describe("effective chat access removal", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("infers the server's user bucket for both effective access events", () => {
    expect(updateBucketKey(removal)).toEqual({ kind: "user" })
    expect(
      updateBucketKey(
        Update.create({
          update: {
            oneofKind: "userAddedToChat",
            userAddedToChat: { chatId: 801n },
          },
        }),
      ),
    ).toEqual({ kind: "user" })
  })

  it.each(["realtime", "syncCatchup"] as const)(
    "commits %s removal and cursor together, including unloaded history on reopen",
    async (source) => {
      vi.stubGlobal("indexedDB", new IDBFactory())
      vi.stubGlobal("IDBKeyRange", IDBKeyRange)
      const namespace = `access-removal-${crypto.randomUUID()}`
      const seedDb = new Db({ autoHydrate: false, storageNamespace: namespace })
      await seed(seedDb)
      await seedDb.closePersistence()
      const db = new Db({ autoHydrate: false, storageNamespace: namespace })
      await db.hydrateKinds([...metadata])
      const storage = new DbSyncStorage(db)
      await storage.initialize()
      const transactions = vi.spyOn(IDBDatabase.prototype, "transaction")

      expect(
        await storage.commitBucketState(
          { kind: "user" },
          { seq: 1, date: 100 },
          () => {
            applyUpdates(db, [removal], source)
          },
        ),
      ).toBe(true)
      expect(
        transactions.mock.calls.filter(([, mode]) => mode === "readwrite"),
      ).toHaveLength(1)
      expect(db.get(db.ref(DbObjectKind.Chat, target))).toBeUndefined()
      expect(
        db.get(db.ref(DbObjectKind.Dialog, dialogId(-801))),
      ).toBeUndefined()
      await db.closePersistence()

      const reopened = new Db({
        autoHydrate: false,
        storageNamespace: namespace,
      })
      await reopened.hydrateKinds([
        ...metadata,
        DbObjectKind.Message,
        DbObjectKind.SyncBucketState,
      ])
      expect(
        reopened.get(reopened.ref(DbObjectKind.Chat, target)),
      ).toBeUndefined()
      expect(
        reopened.get(reopened.ref(DbObjectKind.Dialog, dialogId(-801))),
      ).toBeUndefined()
      expect(
        reopened.get(
          reopened.ref(DbObjectKind.Message, messageKey(target, messageId(1))),
        ),
      ).toBeUndefined()
      expect(
        reopened.get(
          reopened.ref(DbObjectKind.Message, messageKey(keep, messageId(1))),
        )?.message,
      ).toBe("private history")
      expect(
        reopened.get(reopened.ref(DbObjectKind.SyncBucketState, "user"))?.seq,
      ).toBe(1)
      await reopened.closePersistence()
    },
  )

  it("rolls removal and cursor back if their IndexedDB transaction aborts", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const db = new Db({
      autoHydrate: false,
      storageNamespace: `access-abort-${crypto.randomUUID()}`,
    })
    await seed(db)
    const storage = new DbSyncStorage(db)
    await storage.initialize()
    expect(
      await storage.commitBucketState(
        { kind: "user" },
        { seq: 1, date: 100 },
        () => {
          applyUpdates(db, [removal])
          db.insert({
            kind: DbObjectKind.User,
            id: userId(8),
            firstName: (() => {}) as unknown as string,
          })
        },
      ),
    ).toBe(false)
    expect(db.get(db.ref(DbObjectKind.Chat, target))?.title).toBe("chat 801")
    expect(
      db.get(db.ref(DbObjectKind.Message, messageKey(target, messageId(1))))
        ?.message,
    ).toBe("private history")
    expect(await storage.getBucketState({ kind: "user" })).toEqual({
      seq: 0,
      date: 0,
    })
    await db.closePersistence()
  })

  it("invalidates inherited descendants while preserving drafts and allowing fresh authorized child snapshots", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `access-descendants-${crypto.randomUUID()}`
    const db = new Db({ autoHydrate: false, storageNamespace: namespace })
    await seed(db)
    const child = chatId(803)
    const grandchild = chatId(804)
    await db.commit(() => {
      for (const [id, parent] of [
        [child, target],
        [grandchild, child],
      ] as const) {
        db.insert({
          kind: DbObjectKind.Chat,
          id,
          title: "Inherited",
          parentChatId: parent,
        })
        db.insert({
          kind: DbObjectKind.Dialog,
          id: dialogId(-BigInt(id)),
          chatId: id,
          peerThreadId: id,
        })
        db.insert({
          kind: DbObjectKind.Message,
          id: messageKey(id, messageId(1)),
          messageId: messageId(1),
          chatId: id,
          fromId: userId(7),
          message: "Inherited private history",
        })
      }
      db.insert({
        kind: DbObjectKind.MessageDraft,
        id: `chat:${child}`,
        peerKind: "chat",
        peerThreadId: child,
        text: "unsent local draft",
        revision: 1,
        updatedAt: 100,
      })
      applyUpdates(db, [removal])
    })
    for (const id of [target, child, grandchild]) {
      expect(db.get(db.ref(DbObjectKind.Chat, id))).toBeUndefined()
      expect(
        db.get(db.ref(DbObjectKind.Dialog, dialogId(-BigInt(id)))),
      ).toBeUndefined()
      expect(
        db.get(db.ref(DbObjectKind.Message, messageKey(id, messageId(1)))),
      ).toBeUndefined()
    }
    expect(db.get(db.ref(DbObjectKind.Chat, keep))).toBeDefined()
    expect(
      db.get(db.ref(DbObjectKind.MessageDraft, `chat:${child}`))?.text,
    ).toBe("unsent local draft")

    // A fresh GET_CHAT accepted by the server may retain an independent child
    // grant even though its parent's cached inherited projection was removed.
    await db.commit(() => {
      upsertChat(db, {
        id: BigInt(child),
        parentChatId: BigInt(target),
        title: "Direct child grant",
      })
      upsertDialog(db, {
        chatId: BigInt(child),
        peer: { type: { oneofKind: "chat", chat: { chatId: BigInt(child) } } },
      })
      upsertMessage(db, {
        id: 2n,
        chatId: BigInt(child),
        fromId: 7n,
        out: false,
        message: "Fresh authorized history",
        date: 100n,
      })
    })
    await db.closePersistence()
    const reopened = new Db({ autoHydrate: false, storageNamespace: namespace })
    await reopened.hydrateKinds([
      ...metadata,
      DbObjectKind.Message,
      DbObjectKind.MessageDraft,
    ])
    expect(reopened.get(reopened.ref(DbObjectKind.Chat, child))?.title).toBe(
      "Direct child grant",
    )
    expect(
      reopened.get(reopened.ref(DbObjectKind.Chat, target)),
    ).toBeUndefined()
    expect(
      reopened.get(reopened.ref(DbObjectKind.Chat, grandchild)),
    ).toBeUndefined()
    expect(
      reopened.get(
        reopened.ref(DbObjectKind.Message, messageKey(child, messageId(1))),
      ),
    ).toBeUndefined()
    expect(
      reopened.get(
        reopened.ref(DbObjectKind.Message, messageKey(child, messageId(2))),
      )?.message,
    ).toBe("Fresh authorized history")
    expect(
      reopened.get(reopened.ref(DbObjectKind.MessageDraft, `chat:${child}`))
        ?.text,
    ).toBe("unsent local draft")
    await reopened.closePersistence()
  })
})

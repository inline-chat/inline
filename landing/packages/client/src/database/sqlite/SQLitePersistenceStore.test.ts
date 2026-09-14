import {
  chatId,
  dialogId,
  messageId,
  userId,
} from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { Db } from "../index"
import {
  DbObjectKind,
  messageDraftKey,
  messageKey,
  type DeferredUpdate,
  type Message,
  type PendingTransaction,
} from "../models"
import { DbQueryPlanType } from "../types"
import { createSqliteMemoryPersistenceStore } from "./openers"
import type { SQLitePersistenceStore } from "./SQLitePersistenceStore"
import {
  INLINE_SQLITE_SCHEMA_VERSION,
  InlineSqliteMigrationError,
  migrateInlineSqlite,
} from "./schema"

describe("SQLitePersistenceStore", () => {
  let store: SQLitePersistenceStore | undefined

  afterEach(async () => {
    await store?.close()
  })

  it("persists exact Inline models and bounded message windows", async () => {
    store = createSqliteMemoryPersistenceStore()
    const targetChatId = chatId("9223372036854775806")
    const db = new Db({
      autoHydrate: false,
      persistenceStore: store,
    })
    db.batch(() => {
      db.insert({
        kind: DbObjectKind.User,
        id: userId("9223372036854775805"),
        firstName: "Dena",
      })
      db.insert({
        kind: DbObjectKind.Chat,
        id: targetChatId,
        title: "Foundation",
        date: 1_000,
        lastMsgId: messageId(120),
      })
      db.insert({
        kind: DbObjectKind.Dialog,
        id: dialogId(-1),
        chatId: targetChatId,
        open: true,
        order: "a",
      })
      for (let index = 1; index <= 120; index += 1) {
        const id = messageId(index)
        db.insert({
          kind: DbObjectKind.Message,
          id: messageKey(targetChatId, id),
          chatId: targetChatId,
          messageId: id,
          fromId: userId("9223372036854775805"),
          date: 1_000 + Math.floor(index / 3),
          message: `Message ${index}`,
          randomId: BigInt(index),
        })
      }
    })
    await db.flushPersistence()

    const restarted = new Db({
      autoHydrate: false,
      persistenceStore: store,
    })
    await restarted.hydrateKinds([
      DbObjectKind.User,
      DbObjectKind.Chat,
      DbObjectKind.Dialog,
    ])
    await expect(
      restarted.hydrateMessageWindow(targetChatId, { limit: 50 }),
    ).resolves.toBe(50)
    const latest = restarted.queryCollection<
      DbObjectKind.Message,
      Message,
      DbQueryPlanType.Objects
    >(DbQueryPlanType.Objects, DbObjectKind.Message)
    expect(latest.map((message) => message.messageId)).toEqual(
      Array.from({ length: 50 }, (_, index) =>
        messageId(index + 71),
      ),
    )
    expect(latest.at(-1)?.randomId).toBe(120n)

    const persistedMessages = store.collection(
      DbObjectKind.Message,
    )
    await expect(
      persistedMessages.getMessageWindowByChatId?.(
        targetChatId,
        4,
        { date: 1_020, messageId: messageId(60) },
      ),
    ).resolves.toMatchObject(
      [56, 57, 58, 59].map((id) => ({
        chatId: targetChatId,
        messageId: messageId(id),
      })),
    )
    await expect(
      persistedMessages.getMessageWindowByChatId?.(
        targetChatId,
        4,
        undefined,
        { date: 1_020, messageId: messageId(60) },
      ),
    ).resolves.toMatchObject(
      [61, 62, 63, 64].map((id) => ({
        chatId: targetChatId,
        messageId: messageId(id),
      })),
    )

    await expect(
      restarted.loadLocalWindowAroundMessage(targetChatId, {
        messageId: messageId(60),
        beforeLimit: 5,
        afterLimit: 4,
      }),
    ).resolves.toBe(true)
    const around = restarted.queryCollection<
      DbObjectKind.Message,
      Message,
      DbQueryPlanType.Objects
    >(DbQueryPlanType.Objects, DbObjectKind.Message)
    expect(around.map((message) => message.messageId)).toEqual(
      Array.from({ length: 10 }, (_, index) => messageId(index + 55)),
    )
  })

  it("queries deferred updates by target without loading the log", async () => {
    store = createSqliteMemoryPersistenceStore()
    const matching: DeferredUpdate = {
      kind: DbObjectKind.DeferredUpdate,
      id: "matching",
      bucketId: "chat:10",
      targetKey: messageKey(chatId(10), messageId(1)),
      payloadType: "Update",
      updateType: "messageAttachment",
      payload: new Uint8Array([1, 2, 3]),
      seq: 2,
      date: 20,
    }
    const unrelated: DeferredUpdate = {
      ...matching,
      id: "unrelated",
      targetKey: messageKey(chatId(20), messageId(1)),
    }
    await store.write([
      { type: "put", object: matching },
      { type: "put", object: unrelated },
    ])

    await expect(
      store
        .collection(DbObjectKind.DeferredUpdate)
        .getDeferredUpdatesByTargetKeys?.([matching.targetKey!]),
    ).resolves.toEqual([matching])
  })

  it("rolls back the whole transaction when one model cannot encode", async () => {
    store = createSqliteMemoryPersistenceStore()
    const invalid: PendingTransaction = {
      kind: DbObjectKind.PendingTransaction,
      id: "invalid",
      type: "send_message",
      context: { unencodable: () => undefined },
      createdAt: 1,
      status: "pending",
    }

    await expect(
      store.write([
        {
          type: "put",
          object: {
            kind: DbObjectKind.User,
            id: userId(7),
            firstName: "Must roll back",
          },
        },
        { type: "put", object: invalid },
      ]),
    ).rejects.toThrow("Could not encode Inline")

    await expect(
      store.collection(DbObjectKind.User).get(userId(7)),
    ).resolves.toBeUndefined()
  })

  it("rolls back earlier statements when a later SQLite constraint fails", async () => {
    store = createSqliteMemoryPersistenceStore()

    await expect(
      store.write([
        {
          type: "put",
          object: {
            kind: DbObjectKind.User,
            id: userId(8),
            firstName: "Must roll back",
          },
        },
        {
          type: "put",
          object: {
            kind: DbObjectKind.MessageDraft,
            id: messageDraftKey({
              peerKind: "user",
              peerUserId: userId(8),
            }),
            peerKind: "user",
            text: "Invalid peer columns",
            revision: 1,
            updatedAt: 1,
          },
        },
      ]),
    ).rejects.toBeDefined()

    await expect(
      store.collection(DbObjectKind.User).get(userId(8)),
    ).resolves.toBeUndefined()
  })

  it("exposes ordered crash checkpoints around the commit boundary", async () => {
    const checkpoints: string[] = []
    store = createSqliteMemoryPersistenceStore({
      onWriteCheckpoint: (checkpoint) => {
        checkpoints.push(checkpoint.phase)
        expect(checkpoint.operationCount).toBe(1)
      },
    })

    await store.write([
      {
        type: "put",
        object: {
          kind: DbObjectKind.User,
          id: userId(10),
          firstName: "Checkpoint",
        },
      },
    ])

    expect(checkpoints).toEqual([
      "after-begin",
      "before-commit",
      "after-commit",
    ])
  })

  it("rolls back a checkpoint failure before commit", async () => {
    store = createSqliteMemoryPersistenceStore({
      onWriteCheckpoint: (checkpoint) => {
        if (checkpoint.phase === "before-commit") {
          throw new Error("simulated pre-commit termination")
        }
      },
    })

    await expect(
      store.write([
        {
          type: "put",
          object: {
            kind: DbObjectKind.User,
            id: userId(11),
            firstName: "Not committed",
          },
        },
      ]),
    ).rejects.toThrow("simulated pre-commit termination")
    await expect(
      store.collection(DbObjectKind.User).get(userId(11)),
    ).resolves.toBeUndefined()
  })

  it("never rolls back a durable commit when acknowledgement fails", async () => {
    store = createSqliteMemoryPersistenceStore({
      onWriteCheckpoint: (checkpoint) => {
        if (checkpoint.phase === "after-commit") {
          throw new Error("simulated lost commit acknowledgement")
        }
      },
    })

    await expect(
      store.write([
        {
          type: "put",
          object: {
            kind: DbObjectKind.User,
            id: userId(12),
            firstName: "Already committed",
          },
        },
      ]),
    ).rejects.toThrow("simulated lost commit acknowledgement")
    await expect(
      store.collection(DbObjectKind.User).get(userId(12)),
    ).resolves.toMatchObject({ firstName: "Already committed" })
  })

  it("deletes persisted history for only the requested chat", async () => {
    store = createSqliteMemoryPersistenceStore()
    const messages = [chatId(10), chatId(20)].map((targetChatId) => ({
      kind: DbObjectKind.Message,
      id: messageKey(targetChatId, messageId(1)),
      chatId: targetChatId,
      messageId: messageId(1),
      fromId: userId(7),
      message: "Persisted",
    }) satisfies Message)
    await store.write(
      messages.map((object) => ({ type: "put" as const, object })),
    )
    await store.write([
      { type: "deleteMessagesByChat", chatId: chatId(10) },
    ])

    await expect(
      store.collection(DbObjectKind.Message).get(messages[0]!.id),
    ).resolves.toBeUndefined()
    await expect(
      store.collection(DbObjectKind.Message).get(messages[1]!.id),
    ).resolves.toEqual(messages[1])
  })

  it("reopens through an existing collection facade after close", async () => {
    store = createSqliteMemoryPersistenceStore()
    const users = store.collection(DbObjectKind.User)
    await users.put({
      kind: DbObjectKind.User,
      id: userId(9),
      firstName: "Before close",
    })
    await store.close()

    // The in-memory SQLite opener creates a fresh database on reopen. The
    // important invariant is that the existing collection facade remains
    // usable and reaches the reopened owner rather than a closed handle.
    await expect(users.get(userId(9))).resolves.toBeUndefined()
    await users.put({
      kind: DbObjectKind.User,
      id: userId(9),
      firstName: "After reopen",
    })
    await expect(users.get(userId(9))).resolves.toMatchObject({
      firstName: "After reopen",
    })
  })

  it("runs forward migrations idempotently and refuses a newer schema", async () => {
    store = createSqliteMemoryPersistenceStore()
    const database = await store.database()
    expect(migrateInlineSqlite(database)).toBe(
      INLINE_SQLITE_SCHEMA_VERSION,
    )
    database.exec({
      sql: `INSERT INTO inline_schema_migration(version, name, applied_at)
        VALUES (?, ?, ?)`,
      bind: [
        INLINE_SQLITE_SCHEMA_VERSION + 1,
        "future_schema",
        Date.now(),
      ],
    })
    expect(() => migrateInlineSqlite(database)).toThrow(
      InlineSqliteMigrationError,
    )
  })
})

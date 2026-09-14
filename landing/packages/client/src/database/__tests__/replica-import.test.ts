import {
  IDBFactory,
  IDBKeyRange,
} from "fake-indexeddb"
import {
  chatId,
  dialogId,
  messageId,
  spaceId,
  userId,
} from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  DbObjectKind,
  messageDraftKey,
  messageKey,
  type DbModel,
} from "../models"
import {
  assertInlineLegacyFallbackAllowed,
  importIndexedDbReplicaIntoSqlite,
  INLINE_INDEXED_DB_IMPORT_MARKER,
  INLINE_REPLICA_IMPORT_KINDS,
  INLINE_SQLITE_AUTHORITY_MARKER,
  InlinePersistenceReplicaPromotedError,
} from "../replica-import"
import { createSqliteMemoryPersistenceStore } from "../sqlite/openers"
import { createIndexedDbPersistenceStore } from "../storage"

const targetChatId = chatId("9223372036854775806")
const targetUserId = userId("9223372036854775805")

const fixtureModels = (): DbModel[] => [
  {
    kind: DbObjectKind.User,
    id: targetUserId,
    firstName: "Dena",
  },
  {
    kind: DbObjectKind.Space,
    id: spaceId(2),
    name: "Inline",
    creator: true,
    date: 100,
  },
  {
    kind: DbObjectKind.Chat,
    id: targetChatId,
    title: "Foundation",
    spaceId: spaceId(2),
    lastMsgId: messageId(5),
    date: 105,
  },
  {
    kind: DbObjectKind.Dialog,
    id: dialogId(-1),
    chatId: targetChatId,
    spaceId: spaceId(2),
    open: true,
    order: "a",
  },
  ...Array.from({ length: 5 }, (_, index) => {
    const id = messageId(index + 1)
    return {
      kind: DbObjectKind.Message,
      id: messageKey(targetChatId, id),
      chatId: targetChatId,
      messageId: id,
      fromId: targetUserId,
      date: 100 + index,
      message: `Imported ${index + 1}`,
      randomId: BigInt(index + 1),
    } as const
  }),
  {
    kind: DbObjectKind.DeferredUpdate,
    id: "deferred-1",
    bucketId: `chat:${targetChatId}`,
    targetKey: messageKey(targetChatId, messageId(1)),
    payloadType: "Update",
    updateType: "messageAttachment",
    payload: new Uint8Array([1, 2, 3]),
    seq: 3,
    date: 103,
  },
  {
    kind: DbObjectKind.PendingTransaction,
    id: "outbox-1",
    type: "send_message",
    replayPolicy: "idempotent",
    context: {
      chatId: targetChatId,
      randomId: 9223372036854775807n,
    },
    createdAt: 1_700_000_000_000,
    status: "pending",
  },
  {
    kind: DbObjectKind.ReservedChatID,
    id: chatId("9223372036854775804"),
    chatId: chatId("9223372036854775804"),
    expiresAt: 1_700_000_100,
    createdAt: 1_700_000_000_000,
  },
  {
    kind: DbObjectKind.MessageDraft,
    id: messageDraftKey({
      peerKind: "chat",
      peerThreadId: targetChatId,
    }),
    peerKind: "chat",
    peerThreadId: targetChatId,
    text: "Survives cutover",
    revision: 2,
    updatedAt: 1_700_000_000_000,
  },
  {
    kind: DbObjectKind.SyncBucketState,
    id: `chat:${targetChatId}`,
    seq: 7,
    date: 107,
  },
  {
    kind: DbObjectKind.SyncGlobalState,
    id: 0,
    lastSyncDate: 107,
  },
]

const installIndexedDb = () => {
  vi.stubGlobal("indexedDB", new IDBFactory())
  vi.stubGlobal("IDBKeyRange", IDBKeyRange)
}

describe("IndexedDB to SQLite replica import", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it("keeps the import-kind manifest exhaustive and cursors last", () => {
    expect(new Set(INLINE_REPLICA_IMPORT_KINDS)).toEqual(
      new Set(Object.values(DbObjectKind)),
    )
    expect(INLINE_REPLICA_IMPORT_KINDS.slice(-2)).toEqual([
      DbObjectKind.SyncBucketState,
      DbObjectKind.SyncGlobalState,
    ])
  })

  it("streams every replica model in bounded pages and marks completion", async () => {
    installIndexedDb()
    const source = createIndexedDbPersistenceStore(
      `replica-import-${crypto.randomUUID()}`,
    )
    if (!source) throw new Error("IndexedDB unavailable")
    const models = fixtureModels()
    await source.write(
      models.map((object) => ({ type: "put" as const, object })),
    )
    const scan = vi.spyOn(source, "scan")
    const target = createSqliteMemoryPersistenceStore()
    const progress = vi.fn()

    const result = await importIndexedDbReplicaIntoSqlite({
      source,
      target,
      batchSize: 2,
      onProgress: progress,
    })

    expect(result.status).toBe("imported")
    expect(result.importedTotal).toBe(models.length)
    expect(
      scan.mock.calls.every(([, , limit]) => limit === 2),
    ).toBe(true)
    expect(
      scan.mock.calls.filter(
        ([kind]) => kind === DbObjectKind.Message,
      ),
    ).toHaveLength(3)
    expect(progress).toHaveBeenLastCalledWith({
      kind: DbObjectKind.SyncGlobalState,
      importedForKind: 1,
      importedTotal: models.length,
    })

    for (const model of models) {
      await expect(
        target.collection(model.kind).get(model.id as never),
      ).resolves.toEqual(model)
    }
    await expect(
      target.getReplicaMetadata(INLINE_INDEXED_DB_IMPORT_MARKER),
    ).resolves.toBe("complete")
    await expect(
      source.getReplicaMetadata?.(INLINE_SQLITE_AUTHORITY_MARKER),
    ).resolves.toBe("complete")
    await expect(
      assertInlineLegacyFallbackAllowed(source),
    ).rejects.toBeInstanceOf(InlinePersistenceReplicaPromotedError)

    // Import is non-destructive. A completed target reopens only to repair the
    // authority fence; it never rescans legacy rows.
    await expect(
      source.collection(DbObjectKind.User).get(targetUserId),
    ).resolves.toEqual(models[0])
    const sourceOpen = vi.spyOn(source, "open")
    scan.mockClear()
    await expect(
      importIndexedDbReplicaIntoSqlite({ source, target, batchSize: 2 }),
    ).resolves.toMatchObject({
      status: "already-imported",
      importedTotal: 0,
    })
    expect(sourceOpen).toHaveBeenCalledOnce()
    expect(scan).not.toHaveBeenCalled()
    await source.close()
    await target.close()
  })

  it("leaves no marker on interruption and safely reapplies batches", async () => {
    installIndexedDb()
    const source = createIndexedDbPersistenceStore(
      `replica-resume-${crypto.randomUUID()}`,
    )
    if (!source) throw new Error("IndexedDB unavailable")
    const models = fixtureModels()
    await source.write(
      models.map((object) => ({ type: "put" as const, object })),
    )
    const target = createSqliteMemoryPersistenceStore()
    const originalWrite = target.write.bind(target)
    let writes = 0
    vi.spyOn(target, "write").mockImplementation(async (operations) => {
      writes += 1
      if (writes === 4) throw new Error("simulated worker termination")
      await originalWrite(operations)
    })

    await expect(
      importIndexedDbReplicaIntoSqlite({ source, target, batchSize: 2 }),
    ).rejects.toThrow("Inline IndexedDB replica import failed")
    await expect(
      target.getReplicaMetadata(INLINE_INDEXED_DB_IMPORT_MARKER),
    ).resolves.toBeUndefined()
    await expect(
      source.getReplicaMetadata?.(INLINE_SQLITE_AUTHORITY_MARKER),
    ).resolves.toBeUndefined()

    vi.mocked(target.write).mockImplementation(originalWrite)
    await expect(
      importIndexedDbReplicaIntoSqlite({ source, target, batchSize: 2 }),
    ).resolves.toMatchObject({
      status: "imported",
      importedTotal: models.length,
    })
    for (const model of models) {
      await expect(
        target.collection(model.kind).get(model.id as never),
      ).resolves.toEqual(model)
    }
    await expect(
      source.getReplicaMetadata?.(INLINE_SQLITE_AUTHORITY_MARKER),
    ).resolves.toBe("complete")

    await source.close()
    await target.close()
  })

  it("fences IndexedDB before committing SQLite completion", async () => {
    installIndexedDb()
    const source = createIndexedDbPersistenceStore(
      `replica-fence-${crypto.randomUUID()}`,
    )
    if (!source) throw new Error("IndexedDB unavailable")
    await source.write(
      fixtureModels().map((object) => ({ type: "put" as const, object })),
    )
    const target = createSqliteMemoryPersistenceStore()
    const setTargetMetadata = target.setReplicaMetadata.bind(target)
    vi.spyOn(target, "setReplicaMetadata").mockRejectedValueOnce(
      new Error("simulated completion-marker failure"),
    )

    await expect(
      importIndexedDbReplicaIntoSqlite({ source, target, batchSize: 2 }),
    ).rejects.toThrow("Inline IndexedDB replica import failed")
    await expect(
      source.getReplicaMetadata?.(INLINE_SQLITE_AUTHORITY_MARKER),
    ).resolves.toBe("complete")
    await expect(
      target.getReplicaMetadata(INLINE_INDEXED_DB_IMPORT_MARKER),
    ).resolves.toBeUndefined()
    await expect(
      assertInlineLegacyFallbackAllowed(source),
    ).rejects.toBeInstanceOf(InlinePersistenceReplicaPromotedError)

    vi.mocked(target.setReplicaMetadata).mockImplementation(
      setTargetMetadata,
    )
    await expect(
      importIndexedDbReplicaIntoSqlite({ source, target, batchSize: 2 }),
    ).resolves.toMatchObject({ status: "imported" })
    await expect(
      target.getReplicaMetadata(INLINE_INDEXED_DB_IMPORT_MARKER),
    ).resolves.toBe("complete")

    await source.close()
    await target.close()
  })
})

import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { Db } from "../index"
import {
  DbObjectKind,
  messageKey,
  type DbModel,
  type DbModels,
} from "../models"
import type {
  InlinePersistenceCollection,
  InlinePersistenceOperation,
  InlinePersistenceStore,
} from "../persistence"
import { DbQueryPlanType } from "../types"

const createMemoryPersistenceStore = () => {
  let rows = new Map<DbObjectKind, Map<number | string, DbModel>>()
  const collections = new Map<
    DbObjectKind,
    InlinePersistenceCollection<any>
  >()

  const rowsFor = (kind: DbObjectKind) => {
    let kindRows = rows.get(kind)
    if (!kindRows) {
      kindRows = new Map()
      rows.set(kind, kindRows)
    }
    return kindRows
  }

  const collection = <K extends DbObjectKind>(kind: K) => {
    let existing = collections.get(kind)
    if (!existing) {
      existing = {
        init: async () => {},
        get: async (id) =>
          rowsFor(kind).get(id) as DbModels[K] | undefined,
        getMany: async (ids) =>
          ids.flatMap((id) => {
            const object = rowsFor(kind).get(id)
            return object ? [object as DbModels[K]] : []
          }),
        getAll: vi.fn(async () =>
          Array.from(rowsFor(kind).values()) as DbModels[K][],
        ),
        getMessageWindowByChatId: vi.fn(
          async (targetChatId, limit) => {
            if (kind !== DbObjectKind.Message) return []
            return Array.from(rowsFor(kind).values())
              .filter(
                (object) =>
                  object.kind === DbObjectKind.Message &&
                  object.chatId === targetChatId,
              )
              .slice(-limit) as DbModels[K][]
          },
        ),
        put: async (object) => {
          rowsFor(kind).set(object.id, object)
        },
        delete: async (id) => {
          rowsFor(kind).delete(id)
        },
      } satisfies InlinePersistenceCollection<DbModels[K]>
      collections.set(kind, existing)
    }
    return existing as unknown as InlinePersistenceCollection<
      DbModels[K]
    >
  }

  const apply = (
    target: Map<DbObjectKind, Map<number | string, DbModel>>,
    operation: InlinePersistenceOperation,
  ) => {
    const targetRows = new Map(target.get(
      operation.type === "put"
        ? operation.object.kind
        : operation.type === "delete"
          ? operation.kind
          : DbObjectKind.Message,
    ))
    const kind =
      operation.type === "put"
        ? operation.object.kind
        : operation.type === "delete"
          ? operation.kind
          : DbObjectKind.Message

    switch (operation.type) {
      case "put":
        targetRows.set(operation.object.id, operation.object)
        break
      case "delete":
        targetRows.delete(operation.id)
        break
      case "deleteMessagesByChat":
        for (const [id, object] of targetRows) {
          if (
            object.kind === DbObjectKind.Message &&
            object.chatId === operation.chatId
          ) {
            targetRows.delete(id)
          }
        }
        break
    }
    target.set(kind, targetRows)
  }

  const write = vi.fn(
    async (operations: readonly InlinePersistenceOperation[]) => {
      const next = new Map(
        Array.from(rows, ([kind, kindRows]) => [
          kind,
          new Map(kindRows),
        ]),
      )
      for (const operation of operations) apply(next, operation)
      rows = next
    },
  )
  const store: InlinePersistenceStore = {
    open: async () => {},
    collection,
    write,
    close: async () => {},
  }
  return { collection, store, write }
}

describe("Inline persistence store boundary", () => {
  it("commits cross-kind changes once and hydrates them after restart", async () => {
    const persistence = createMemoryPersistenceStore()
    const writer = new Db({
      autoHydrate: false,
      persistenceStore: persistence.store,
    })

    writer.batch(() => {
      writer.insert({
        kind: DbObjectKind.User,
        id: userId(7),
        firstName: "Dena",
      })
      writer.insert({
        kind: DbObjectKind.Chat,
        id: chatId(10),
        title: "Foundation",
      })
    })
    await writer.flushPersistence()

    expect(persistence.write).toHaveBeenCalledTimes(1)
    expect(persistence.write.mock.calls[0]?.[0]).toHaveLength(2)

    const restarted = new Db({
      autoHydrate: false,
      persistenceStore: persistence.store,
    })
    await restarted.hydrateKinds([
      DbObjectKind.User,
      DbObjectKind.Chat,
    ])

    expect(
      restarted.get(
        restarted.ref(DbObjectKind.User, userId(7)),
      )?.firstName,
    ).toBe("Dena")
    expect(
      restarted.get(
        restarted.ref(DbObjectKind.Chat, chatId(10)),
      )?.title,
    ).toBe("Foundation")
  })

  it("hydrates only the requested message window through the adapter index", async () => {
    const persistence = createMemoryPersistenceStore()
    const targetChatId = chatId(10)
    await persistence.store.write(
      Array.from({ length: 500 }, (_, index) => {
        const id = messageId(index + 1)
        return {
          type: "put" as const,
          object: {
            kind: DbObjectKind.Message,
            id: messageKey(targetChatId, id),
            chatId: targetChatId,
            messageId: id,
            fromId: userId(7),
            message: `Message ${index + 1}`,
          },
        }
      }),
    )
    persistence.write.mockClear()

    const db = new Db({
      autoHydrate: false,
      persistenceStore: persistence.store,
    })
    await expect(
      db.hydrateMessageWindow(targetChatId, { limit: 50 }),
    ).resolves.toBe(50)

    const messages = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
    )
    const messageCollection = persistence.collection(
      DbObjectKind.Message,
    )
    expect(messages).toHaveLength(50)
    expect(messageCollection.getAll).not.toHaveBeenCalled()
    expect(
      messageCollection.getMessageWindowByChatId,
    ).toHaveBeenCalledWith(
      targetChatId,
      50,
      undefined,
      undefined,
    )
  })

  it("lets an explicit null adapter create a renderer-only projection", async () => {
    const open = vi.fn(() => {
      throw new Error("IndexedDB must not be consulted")
    })
    vi.stubGlobal("indexedDB", { open })
    try {
      const db = new Db({
        autoHydrate: false,
        persistenceStore: null,
      })
      db.insert({
        kind: DbObjectKind.User,
        id: userId(7),
        firstName: "Dena",
      })
      await db.flushPersistence()
      expect(open).not.toHaveBeenCalled()
    } finally {
      vi.unstubAllGlobals()
    }
  })
})

import {
  IDBFactory,
  IDBKeyRange,
  IDBObjectStore,
} from "fake-indexeddb"
import { Update } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  Db,
  DatabaseCommitError,
  DbObjectKind,
  DbQueryPlanType,
  messageKey,
} from "../../index"
import {
  applyUpdates,
  DeferredMessageUpdateOwner,
} from "../updates"
import { upsertMessage } from "../transactions/mappers"

const installIndexedDb = () => {
  vi.stubGlobal("indexedDB", new IDBFactory())
  vi.stubGlobal("IDBKeyRange", IDBKeyRange)
}

const targetChatId = chatId(801)
const targetMessageId = messageId(41)
const targetKey = messageKey(targetChatId, targetMessageId)

const messageModel = () => ({
  kind: DbObjectKind.Message as const,
  id: targetKey,
  messageId: targetMessageId,
  chatId: targetChatId,
  fromId: userId(7),
  message: "Foundation",
  date: 1_000,
})

const reactionUpdate = ({
  seq,
  emoji = "🔥",
  user = 7n,
  deleted = false,
  target = 41n,
}: {
  seq: number
  emoji?: string
  user?: bigint
  deleted?: boolean
  target?: bigint
}) =>
  Update.create({
    seq,
    date: BigInt(1_000 + seq),
    update: deleted
      ? {
          oneofKind: "deleteReaction",
          deleteReaction: {
            emoji,
            userId: user,
            messageId: target,
            chatId: 801n,
          },
        }
      : {
          oneofKind: "updateReaction",
          updateReaction: {
            reaction: {
              emoji,
              userId: user,
              messageId: target,
              chatId: 801n,
              date: BigInt(1_000 + seq),
            },
          },
        },
  })

const attachment = (title: string) => ({
  id: 70n,
  attachment: {
    oneofKind: "externalTask" as const,
    externalTask: {
      id: 700n,
      taskId: "ENG-41",
      application: "linear",
      title,
      status: 3,
      assignedUserId: 7n,
      url: "https://linear.app/issue/ENG-41",
      number: "ENG-41",
      date: 1_000n,
    },
  },
})

const attachmentUpdate = (
  seq: number,
  value:
    | ReturnType<typeof attachment>
    | { id: bigint; attachment: { oneofKind: undefined } },
) =>
  Update.create({
    seq,
    date: BigInt(1_000 + seq),
    update: {
      oneofKind: "messageAttachment",
      messageAttachment: {
        chatId: 801n,
        messageId: 41n,
        attachment: value,
      },
    },
  })

describe("deferred update persistence", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("survives reload without entering the normal resident working set", async () => {
    installIndexedDb()
    const namespace = `deferred-${crypto.randomUUID()}`
    const update = Update.create({
      seq: 9,
      date: 1_009n,
      update: {
        oneofKind: "updateReaction",
        updateReaction: {
          reaction: {
            emoji: "🔥",
            userId: 7n,
            messageId: 41n,
            chatId: 801n,
            date: 1_009n,
          },
        },
      },
    })
    const first = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })

    applyUpdates(first, [update], "syncCatchup")
    await first.flushPersistence()

    const reloaded = new Db({
      storageNamespace: namespace,
    })
    await reloaded.ready
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toEqual([])

    await reloaded.hydrateKinds([
      DbObjectKind.DeferredUpdate,
    ])
    const deferred = reloaded.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.DeferredUpdate,
    )
    expect(deferred).toHaveLength(1)
    expect(
      Update.fromBinary(deferred[0]!.payload),
    ).toEqual(update)
  })

  it("selectively replays ordered reactions when a persisted message window materializes", async () => {
    installIndexedDb()
    const namespace = `deferred-window-${crypto.randomUUID()}`
    const first = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    first.storeNonResidentObject(messageModel())
    applyUpdates(first, [
      reactionUpdate({ seq: 9 }),
      reactionUpdate({ seq: 10, deleted: true }),
      reactionUpdate({ seq: 11, target: 99n }),
    ])
    await first.flushPersistence()

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    new DeferredMessageUpdateOwner(reloaded)
    await reloaded.hydrateMessageWindow(targetChatId, {
      limit: 50,
    })

    expect(
      reloaded.get(
        reloaded.ref(DbObjectKind.Message, targetKey),
      )?.reactions,
    ).toBeUndefined()
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toEqual([])

    const unrelatedKey = messageKey(
      targetChatId,
      messageId(99),
    )
    await reloaded.hydrateDeferredUpdatesForMessageKeys([
      unrelatedKey,
    ])
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toHaveLength(1)
  })

  it("selectively replays ordered attachment updates into a cold message", async () => {
    installIndexedDb()
    const namespace = `deferred-attachment-${crypto.randomUUID()}`
    const first = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    first.storeNonResidentObject(messageModel())
    applyUpdates(first, [
      attachmentUpdate(9, attachment("First title")),
      attachmentUpdate(10, attachment("Latest title")),
    ])
    await first.flushPersistence()

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    new DeferredMessageUpdateOwner(reloaded)
    await reloaded.hydrateMessageWindow(targetChatId, {
      limit: 50,
    })

    expect(
      reloaded.get(reloaded.ref(DbObjectKind.Message, targetKey))
        ?.attachments?.attachments,
    ).toMatchObject([
      {
        id: 70n,
        attachment: {
          oneofKind: "externalTask",
          externalTask: { title: "Latest title" },
        },
      },
    ])
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toEqual([])

    await reloaded.flushPersistence()
    const afterRestart = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await afterRestart.hydrateMessageWindow(targetChatId, {
      limit: 50,
    })
    expect(
      afterRestart.get(afterRestart.ref(DbObjectKind.Message, targetKey))
        ?.attachments?.attachments[0]?.attachment.oneofKind,
    ).toBe("externalTask")
  })

  it("replays a cold attachment deletion without leaving an empty wrapper", async () => {
    installIndexedDb()
    const namespace = `deferred-attachment-delete-${crypto.randomUUID()}`
    const first = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    first.storeNonResidentObject({
      ...messageModel(),
      attachments: { attachments: [attachment("Delete me")] },
    })
    applyUpdates(first, [
      attachmentUpdate(9, {
        id: 70n,
        attachment: { oneofKind: undefined },
      }),
    ])
    await first.flushPersistence()

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    new DeferredMessageUpdateOwner(reloaded)
    await reloaded.hydrateMessageWindow(targetChatId, {
      limit: 50,
    })

    expect(
      reloaded.get(reloaded.ref(DbObjectKind.Message, targetKey))?.attachments,
    ).toBeUndefined()
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toEqual([])
  })

  it("replays a deferred add over a fresh protocol snapshot inside its commit", async () => {
    installIndexedDb()
    const namespace = `deferred-snapshot-${crypto.randomUUID()}`
    const first = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    applyUpdates(first, [reactionUpdate({ seq: 9 })])
    await first.flushPersistence()

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await reloaded.hydrateDeferredUpdatesForMessageKeys([
      targetKey,
    ])
    await reloaded.commit(() => {
      upsertMessage(reloaded, {
        id: 41n,
        chatId: 801n,
        fromId: 7n,
        message: "Fresh snapshot",
        date: 1_020n,
        out: false,
      })
    })

    expect(
      reloaded.get(
        reloaded.ref(DbObjectKind.Message, targetKey),
      )?.reactions?.reactions,
    ).toMatchObject([{ emoji: "🔥", userId: 7n }])
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toEqual([])

    const afterRestart = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await afterRestart.hydrateDeferredUpdatesForMessageKeys([
      targetKey,
    ])
    expect(
      afterRestart.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toEqual([])
  })

  it("retains malformed targeted payloads without blocking message hydration", async () => {
    installIndexedDb()
    const namespace = `deferred-malformed-${crypto.randomUUID()}`
    const first = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    first.storeNonResidentObject(messageModel())
    first.insert({
      kind: DbObjectKind.DeferredUpdate,
      id: "malformed",
      bucketId: "chat:801",
      seq: 9,
      payloadType: "Update",
      updateType: "updateReaction",
      targetKey,
      payload: new Uint8Array([255]),
    })
    await first.flushPersistence()

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    new DeferredMessageUpdateOwner(reloaded)
    await expect(
      reloaded.hydrateMessageWindow(targetChatId, {
        limit: 50,
      }),
    ).resolves.toBe(1)
    expect(
      reloaded.get(
        reloaded.ref(DbObjectKind.Message, targetKey),
      )?.message,
    ).toBe("Foundation")
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toHaveLength(1)
  })

  it("rolls back snapshot replay and deferred consumption when the IndexedDB transaction aborts", async () => {
    installIndexedDb()
    const namespace = `deferred-atomic-${crypto.randomUUID()}`
    const first = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    applyUpdates(first, [reactionUpdate({ seq: 9 })])
    await first.flushPersistence()

    const reloaded = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await reloaded.hydrateDeferredUpdatesForMessageKeys([
      targetKey,
    ])
    const deleteSpy = vi
      .spyOn(IDBObjectStore.prototype, "delete")
      .mockImplementationOnce(() => {
        throw new Error("forced deferred delete failure")
      })

    await expect(
      reloaded.commit(() => {
        upsertMessage(reloaded, {
          id: 41n,
          chatId: 801n,
          fromId: 7n,
          message: "Must roll back",
          date: 1_020n,
          out: false,
        })
      }),
    ).rejects.toBeInstanceOf(DatabaseCommitError)
    expect(
      reloaded.get(
        reloaded.ref(DbObjectKind.Message, targetKey),
      ),
    ).toBeUndefined()
    expect(
      reloaded.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toHaveLength(1)
    deleteSpy.mockRestore()

    const afterRestart = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await afterRestart.hydrateDeferredUpdatesForMessageKeys([
      targetKey,
    ])
    expect(
      afterRestart.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toHaveLength(1)
  })
})

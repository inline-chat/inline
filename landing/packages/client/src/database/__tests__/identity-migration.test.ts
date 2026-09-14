import {
  IDBFactory,
  IDBKeyRange,
} from "fake-indexeddb"
import {
  afterEach,
  describe,
  expect,
  it,
  vi,
} from "vitest"
import { Update } from "@inline-chat/protocol/core"
import {
  chatId,
  dialogId,
  inlineIdOrderKey,
  messageId,
  userId,
} from "@inline/ids"
import { DbObjectKind, messageKey } from "../models"
import {
  IndexedDbIdentityMigrationError,
  createDatabaseStorage,
  migrateStoredIdentity,
} from "../storage"

describe("IndexedDB identity migration", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("keeps adjacent int64 identities distinct beyond Number.MAX_SAFE_INTEGER", () => {
    const lower = migrateStoredIdentity({
      kind: DbObjectKind.Chat,
      id: 9_007_199_254_740_992n,
      createdBy: 9_007_199_254_740_994n,
    })
    const upper = migrateStoredIdentity({
      kind: DbObjectKind.Chat,
      id: "9007199254740993",
      createdBy: "9007199254740995",
    })

    expect(lower).toMatchObject({
      id: chatId("9007199254740992"),
      createdBy: userId("9007199254740994"),
    })
    expect(upper).toMatchObject({
      id: chatId("9007199254740993"),
      createdBy: userId("9007199254740995"),
    })
    expect(lower.id).not.toBe(upper.id)
  })

  it("migrates chat-scoped message identity and replay context atomically", () => {
    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.Message,
        id: 7,
        chatId: 10,
        fromId: 1,
      }),
    ).toMatchObject({
      id: messageKey(chatId(10), messageId(7)),
      messageId: messageId(7),
      chatId: chatId(10),
      fromId: userId(1),
    })

    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.PendingTransaction,
        id: "transaction-1",
        type: "send_message",
        context: {
          chatId: 10,
          replyToMsgId: 5,
          temporaryMessageId: -1,
        },
      }),
    ).toMatchObject({
      context: {
        chatId: chatId(10),
        replyToMsgId: messageId(5),
        temporaryMessageId: messageId(-1),
      },
    })

    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.PendingTransaction,
        id: "transaction-unpin",
        type: "pin_message",
        context: {
          messageId: "9007199254740993",
          unpin: true,
          previousPinnedMessageIds: [1, "9007199254740995"],
          optimisticPinnedMessageIds: [1],
        },
      }),
    ).toMatchObject({
      context: {
        messageId: messageId("9007199254740993"),
        previousPinnedMessageIds: [
          messageId(1),
          messageId("9007199254740995"),
        ],
        optimisticPinnedMessageIds: [messageId(1)],
      },
    })
  })

  it("preserves native signed dialog identity", () => {
    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.Dialog,
        id: -801,
        chatId: 801,
        peerThreadId: 801,
      }),
    ).toMatchObject({
      id: dialogId(-801),
      chatId: chatId(801),
      peerThreadId: chatId(801),
    })
  })

  it("preserves an exact owner-only reserved chat identity", () => {
    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.ReservedChatID,
        id: "9007199254740993",
        chatId: 9_007_199_254_740_993n,
        expiresAt: 1_800_000_000,
        createdAt: 1_700_000_000_000,
      }),
    ).toMatchObject({
      id: chatId("9007199254740993"),
      chatId: chatId("9007199254740993"),
    })
  })

  it("derives a draft identity from its exact Inline peer", () => {
    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.MessageDraft,
        id: "stale-draft-key",
        peerKind: "user",
        peerUserId: "9007199254740993",
        peerThreadId: 44,
        text: "draft",
        revision: 1,
        updatedAt: 1,
      }),
    ).toMatchObject({
      id: "user:9007199254740993",
      peerKind: "user",
      peerUserId: userId("9007199254740993"),
      peerThreadId: undefined,
    })
  })

  it("aborts instead of blessing a number that JavaScript already rounded", () => {
    expect(() =>
      migrateStoredIdentity({
        kind: DbObjectKind.Chat,
        id: Number.MAX_SAFE_INTEGER + 1,
      }),
    ).toThrow(IndexedDbIdentityMigrationError)
  })

  it("backfills selective message targets for pre-v6 deferred rows", () => {
    const update = Update.create({
      seq: 9,
      update: {
        oneofKind: "updateReaction",
        updateReaction: {
          reaction: {
            chatId: 801n,
            messageId: 41n,
            userId: 7n,
            emoji: "🔥",
            date: 1_009n,
          },
        },
      },
    })

    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.DeferredUpdate,
        id: "legacy-reaction",
        bucketId: "chat:801",
        seq: 9,
        payloadType: "Update",
        updateType: "updateReaction",
        payload: Update.toBinary(update),
      }),
    ).toMatchObject({ targetKey: messageKey(chatId(801), messageId(41)) })

    const attachment = Update.create({
      seq: 10,
      update: {
        oneofKind: "messageAttachment",
        messageAttachment: {
          chatId: 801n,
          messageId: 42n,
          attachment: {
            id: 12n,
            attachment: { oneofKind: undefined },
          },
        },
      },
    })
    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.DeferredUpdate,
        id: "legacy-attachment",
        bucketId: "chat:801",
        seq: 10,
        payloadType: "Update",
        updateType: "messageAttachment",
        payload: Update.toBinary(attachment),
      }),
    ).toMatchObject({
      targetKey: messageKey(chatId(801), messageId(42)),
    })

    expect(
      migrateStoredIdentity({
        kind: DbObjectKind.DeferredUpdate,
        id: "legacy-malformed",
        bucketId: "chat:801",
        payloadType: "Update",
        updateType: "updateReaction",
        payload: new Uint8Array([255]),
      }),
    ).toMatchObject({ targetKey: undefined })
  })

  it("forwards the v4 message-ID index to the date and ID window index", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `v4-window-${crypto.randomUUID()}`
    const databaseName = `inline-client-db:${namespace}`

    const legacyDatabase = await new Promise<IDBDatabase>(
      (resolve, reject) => {
        const request = indexedDB.open(databaseName, 4)
        request.onupgradeneeded = () => {
          const store = request.result.createObjectStore(
            "objects",
            {
              keyPath: ["kind", "id"],
            },
          )
          store.createIndex("kind", "kind", {
            unique: false,
          })
          store.createIndex(
            "message-chat-id",
            ["kind", "chatId", "_messageIdOrder"],
            { unique: false },
          )
          for (const [rawMessageId, date] of [
            [900, 10],
            [1, 20],
          ] as const) {
            const exactMessageId = messageId(rawMessageId)
            store.put({
              kind: DbObjectKind.Message,
              id: messageKey(chatId(10), exactMessageId),
              messageId: exactMessageId,
              chatId: chatId(10),
              fromId: userId(7),
              date,
              _messageIdOrder:
                inlineIdOrderKey(exactMessageId),
            })
          }
        }
        request.onsuccess = () => resolve(request.result)
        request.onerror = () => reject(request.error)
      },
    )
    legacyDatabase.onversionchange = () => legacyDatabase.close()

    const storage = createDatabaseStorage(namespace)
    if (!storage) {
      throw new Error("IndexedDB storage unavailable")
    }
    const messages = storage.collection(
      DbObjectKind.Message,
    )
    await messages.init()

    await expect(
      messages.getMessageWindowByChatId?.(
        chatId(10),
        1,
      ),
    ).resolves.toEqual([
      expect.objectContaining({
        messageId: messageId(1),
        date: 20,
      }),
    ])
  })

  it("adds v7 replica metadata without rerunning the v6 identity rewrite", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `v6-metadata-${crypto.randomUUID()}`
    const databaseName = `inline-client-db:${namespace}`
    const legacyDatabase = await new Promise<IDBDatabase>(
      (resolve, reject) => {
        const request = indexedDB.open(databaseName, 6)
        request.onupgradeneeded = () => {
          const store = request.result.createObjectStore(
            "objects",
            { keyPath: ["kind", "id"] },
          )
          // This deliberately cannot pass the old identity rewrite. A v6→v7
          // metadata-only upgrade must leave it untouched.
          store.put({
            kind: DbObjectKind.User,
            id: Number.MAX_SAFE_INTEGER + 1,
            firstName: "Legacy sentinel",
          })
        }
        request.onsuccess = () => resolve(request.result)
        request.onerror = () => reject(request.error)
      },
    )
    legacyDatabase.close()

    const storage = createDatabaseStorage(namespace)
    if (!storage?.setReplicaMetadata || !storage.getReplicaMetadata) {
      throw new Error("IndexedDB replica metadata unavailable")
    }
    await storage.open()
    expect(() =>
      legacyDatabase.transaction("objects", "readonly"),
    ).toThrow()
    await storage.setReplicaMetadata("cutover", "ready")
    await expect(storage.getReplicaMetadata("cutover")).resolves.toBe(
      "ready",
    )
    await expect(
      new Promise<IDBDatabase>((resolve, reject) => {
        const oldWriter = indexedDB.open(databaseName, 6)
        oldWriter.onsuccess = () => resolve(oldWriter.result)
        oldWriter.onerror = () => reject(oldWriter.error)
      }),
    ).rejects.toMatchObject({ name: "VersionError" })
    await storage.close()
  })
})

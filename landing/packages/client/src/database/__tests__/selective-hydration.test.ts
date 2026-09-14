import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import {
  afterEach,
  describe,
  expect,
  it,
  vi,
} from "vitest"
import {
  chatId,
  compareInlineIds,
  messageId,
  userId,
  type ChatID,
} from "@inline/ids"
import { Db } from "../index"
import {
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type Message,
  type MessageKey,
} from "../models"
import {
  compareMessageWindowCursors,
  messageWindowCursor,
  type MessageWindowCursor,
} from "../message-window"
import { DbQueryPlanType } from "../types"
import type { CollectionStorage } from "../storage"

const message = (
  id: number,
  rawChatId: number,
  date = id,
): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(chatId(rawChatId), messageId(id)),
  messageId: messageId(id),
  chatId: chatId(rawChatId),
  fromId: userId(7),
  message: `message ${id}`,
  date,
})

describe("selective message hydration", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("hydrates only the requested chat window and can prepend an older window", async () => {
    const allMessages = [
      ...Array.from({ length: 100 }, (_, index) => message(index + 1, 10)),
      ...Array.from({ length: 40 }, (_, index) => message(index + 1_000, 20)),
    ]

    const getMessageWindowByChatId = vi.fn(async (
      requestedChatId: ChatID,
      limit: number,
      before?: MessageWindowCursor,
    ) =>
      allMessages
        .filter(
          (item) =>
            item.chatId === requestedChatId &&
            (before == null ||
              compareMessageWindowCursors(
                messageWindowCursor(item),
                before,
              ) < 0),
        )
        .sort((left, right) =>
          compareMessageWindowCursors(
            messageWindowCursor(right),
            messageWindowCursor(left),
          ),
        )
        .slice(0, limit)
        .reverse(),
    )

    const storage: CollectionStorage<Message> = {
      init: vi.fn(async () => {}),
      get: vi.fn(async () => undefined),
      getAll: vi.fn(async () => {
        throw new Error("message windows must not scan the whole collection")
      }),
      getMessageWindowByChatId,
      put: vi.fn(async () => {}),
      delete: vi.fn(async () => {}),
    }

    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.Message]: storage,
      },
    })

    await expect(
      db.hydrateMessageWindow(chatId(10), { limit: 50 }),
    ).resolves.toBe(50)

    let hydrated = db.queryCollection<Message["kind"], Message, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
    )
    expect(hydrated.map((item) => item.messageId)).toEqual(
      Array.from({ length: 50 }, (_, index) => messageId(index + 51)),
    )
    expect(storage.getAll).not.toHaveBeenCalled()

    await expect(
      db.hydrateMessageWindow(chatId(10), {
        limit: 25,
        before: {
          date: 51,
          messageId: messageId(51),
        },
      }),
    ).resolves.toBe(25)

    hydrated = db.queryCollection<Message["kind"], Message, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
    )
    expect(
      hydrated
        .map((item) => item.messageId)
        .sort(compareInlineIds),
    ).toEqual(
      Array.from({ length: 75 }, (_, index) => messageId(index + 26)),
    )
    expect(getMessageWindowByChatId).toHaveBeenNthCalledWith(
      1,
      chatId(10),
      50,
      undefined,
      undefined,
    )
    expect(getMessageWindowByChatId).toHaveBeenNthCalledWith(
      2,
      chatId(10),
      25,
      {
        date: 51,
        messageId: messageId(51),
      },
      undefined,
    )
  })

  it("releases an inactive chat window without deleting durable history", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `message-release-${crypto.randomUUID()}`
    const db = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    db.batch(() => {
      db.insert({
        kind: DbObjectKind.Chat,
        id: chatId(10),
        lastMsgId: messageId(5),
      })
      for (let id = 1; id <= 5; id += 1) {
        db.insert(message(id, 10))
      }
      db.insert({
        ...message(4, 10),
        id: messageKey(chatId(10), messageId(-1)),
        messageId: messageId(-1),
        status: MessageSendingStatus.Failed,
      })
      db.insert(message(50, 20))
    })
    await db.flushPersistence()

    expect(db.releaseResidentMessageWindow(chatId(10))).toBe(4)
    expect(
      db
        .queryCollection<
          Message["kind"],
          Message,
          DbQueryPlanType.Objects
        >(DbQueryPlanType.Objects, DbObjectKind.Message)
        .map((item) => item.messageId)
        .sort(compareInlineIds),
    ).toEqual([messageId(-1), messageId(5), messageId(50)])

    await expect(
      db.hydrateMessageWindow(chatId(10), {
        limit: 10,
        before: messageWindowCursor(message(5, 10)),
      }),
    ).resolves.toBe(5)
    expect(
      db
        .queryCollection<
          Message["kind"],
          Message,
          DbQueryPlanType.Objects
        >(DbQueryPlanType.Objects, DbObjectKind.Message)
        .filter((item) => item.chatId === chatId(10))
        .map((item) => item.messageId)
        .sort(compareInlineIds),
    ).toEqual([
      messageId(-1),
      messageId(1),
      messageId(2),
      messageId(3),
      messageId(4),
      messageId(5),
    ])
  })

  it("defers inactive-window release while a reaction intent is transient", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    db.batch(() => {
      db.insert({
        kind: DbObjectKind.Chat,
        id: chatId(10),
        lastMsgId: messageId(2),
      })
      db.insert({
        ...message(1, 10),
        reactionIntents: [
          {
            id: "reaction-1",
            emoji: "👍",
            userId: userId(7),
            action: "add",
          },
        ],
      })
      db.insert(message(2, 10))
    })

    expect(db.releaseResidentMessageWindow(chatId(10))).toBe(0)
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
      ),
    ).toHaveLength(2)
  })

  it("uses date and message ID as the IndexedDB keyset", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `message-window-${crypto.randomUUID()}`
    const writer = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    const messages = [
      message(900, 10, 10),
      message(1, 10, 20),
      message(2, 10, 20),
      message(3, 10, 30),
    ]
    writer.batch(() => {
      for (const item of messages) writer.insert(item)
    })
    await writer.flushPersistence()

    const reader = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await expect(
      reader.hydrateMessageWindow(chatId(10), { limit: 2 }),
    ).resolves.toBe(2)
    await expect(
      reader.hydrateMessageWindow(chatId(10), {
        limit: 2,
        before: {
          date: 20,
          messageId: messageId(2),
        },
      }),
    ).resolves.toBe(2)

    expect(
      reader
        .queryCollection<
          Message["kind"],
          Message,
          DbQueryPlanType.Objects
        >(
          DbQueryPlanType.Objects,
          DbObjectKind.Message,
        )
        .sort((left, right) =>
          compareMessageWindowCursors(
            messageWindowCursor(left),
            messageWindowCursor(right),
          ),
        )
        .map((item) => item.messageId),
    ).toEqual([
      messageId(900),
      messageId(1),
      messageId(2),
      messageId(3),
    ])
  })

  it("hydrates a bounded newer window in ascending order", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `message-newer-${crypto.randomUUID()}`
    const writer = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    writer.batch(() => {
      for (let id = 1; id <= 10; id += 1) {
        writer.insert(message(id, 10, id))
      }
    })
    await writer.flushPersistence()

    const reader = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    reader.replace({
      kind: DbObjectKind.Chat,
      id: chatId(10),
      lastMsgId: messageId(10),
      date: 10,
    })
    reader.activateResidentMessageWindow(chatId(10))
    reader.fullChatWindows.setAtLatest(chatId(10), false)
    await expect(
      reader.hydrateMessageWindow(chatId(10), {
        limit: 3,
        after: messageWindowCursor(message(4, 10, 4)),
      }),
    ).resolves.toBe(3)
    expect(
      reader
        .queryCollection<
          Message["kind"],
          Message,
          DbQueryPlanType.Objects
        >(DbQueryPlanType.Objects, DbObjectKind.Message)
        .map((item) => item.messageId),
    ).toEqual([messageId(5), messageId(6), messageId(7)])
    expect(reader.fullChatWindows.isAtLatest(chatId(10))).toBe(
      false,
    )

    await expect(
      reader.hydrateMessageWindow(chatId(10), {
        limit: 3,
        after: messageWindowCursor(message(7, 10, 7)),
      }),
    ).resolves.toBe(3)
    expect(reader.fullChatWindows.isAtLatest(chatId(10))).toBe(
      true,
    )
  })

  it("replaces one resident chat window with a bounded indexed window around a message", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `message-around-${crypto.randomUUID()}`
    const writer = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    const chatMessages = [
      message(900, 10, 10),
      message(1, 10, 20),
      message(2, 10, 20),
      message(3, 10, 20),
      message(4, 10, 30),
      message(5, 10, 40),
    ]
    writer.batch(() => {
      for (const item of chatMessages) writer.insert(item)
      writer.insert(message(50, 20, 50))
    })
    await writer.flushPersistence()

    const reader = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await reader.hydrateMessageWindow(chatId(10), { limit: 2 })
    await reader.hydrateMessageWindow(chatId(20), { limit: 1 })
    const residentBatches: Array<{
      changes: Array<{ id: MessageKey; object?: Message }>
    }> = []
    const unsubscribe = reader.subscribeToResidentChanges((batch) => {
      residentBatches.push(batch as typeof residentBatches[number])
    })

    await expect(
      reader.loadLocalWindowAroundMessage(chatId(10), {
        messageId: messageId(2),
        beforeLimit: 1,
        afterLimit: 2,
      }),
    ).resolves.toBe(true)

    const residentMessages = reader.queryCollection<
      Message["kind"],
      Message,
      DbQueryPlanType.Objects
    >(DbQueryPlanType.Objects, DbObjectKind.Message)
    expect(
      residentMessages
        .filter((item) => item.chatId === chatId(10))
        .sort((left, right) =>
          compareMessageWindowCursors(
            messageWindowCursor(left),
            messageWindowCursor(right),
          ),
        )
        .map((item) => item.messageId),
    ).toEqual([
      messageId(1),
      messageId(2),
      messageId(3),
      messageId(4),
    ])
    expect(
      residentMessages.some(
        (item) =>
          item.chatId === chatId(20) &&
          item.messageId === messageId(50),
      ),
    ).toBe(true)
    const residentChanges = residentBatches.flatMap(
      (batch) => batch.changes,
    )
    const removed = residentChanges.find(
      (change) =>
        change.id === messageKey(chatId(10), messageId(5)),
    )
    expect(removed).toBeDefined()
    expect(removed).not.toHaveProperty("object")
    expect(residentChanges).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: messageKey(chatId(10), messageId(1)),
          object: expect.objectContaining({
            messageId: messageId(1),
          }),
        }),
      ]),
    )

    await expect(
      reader.loadLocalWindowAroundMessage(chatId(10), {
        messageId: messageId(404),
        beforeLimit: 1,
        afterLimit: 1,
      }),
    ).resolves.toBe(false)
    expect(
      reader
        .queryCollection<
          Message["kind"],
          Message,
          DbQueryPlanType.Objects
        >(DbQueryPlanType.Objects, DbObjectKind.Message)
        .filter((item) => item.chatId === chatId(10)),
    ).toHaveLength(4)
    unsubscribe()
  })

  it("hydrates only object ids supplied by navigation hints", async () => {
    const getMany = vi.fn(async (ids: MessageKey[]) =>
      ids.map((id) => message(Number(id.split(":")[1]), 10)),
    )
    const storage: CollectionStorage<Message> = {
      init: vi.fn(async () => {}),
      get: vi.fn(async () => undefined),
      getMany,
      getAll: vi.fn(async () => {
        throw new Error("navigation hints must not scan the whole collection")
      }),
      put: vi.fn(async () => {}),
      delete: vi.fn(async () => {}),
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.Message]: storage,
      },
    })

    await expect(
      db.hydrateObjects(DbObjectKind.Message, [
        messageKey(chatId(10), messageId(91)),
        messageKey(chatId(10), messageId(95)),
        messageKey(chatId(10), messageId(95)),
        messageKey(chatId(10), messageId(99)),
      ]),
    ).resolves.toBe(3)

    expect(getMany).toHaveBeenCalledWith([
      messageKey(chatId(10), messageId(91)),
      messageKey(chatId(10), messageId(95)),
      messageKey(chatId(10), messageId(99)),
    ])
    expect(storage.getAll).not.toHaveBeenCalled()
    expect(
      db.get(
        db.ref(
          DbObjectKind.Message,
          messageKey(chatId(10), messageId(95)),
        ),
      )?.message,
    ).toBe("message 95")
  })
})

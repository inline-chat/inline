import {
  Update,
  type Message as ProtocolMessage,
} from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { AuthStore } from "../../auth"
import { Db } from "../../database"
import {
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  type Message,
} from "../../database/models"
import type { CollectionStorage } from "../../database/storage"
import {
  getChatHistory,
  GetChatHistoryMode,
  sendMessage,
} from "../transactions"
import { upsertMessage } from "../transactions/mappers"
import { RealtimeClient } from "../realtime"
import { MockTransport } from "../transport/mock-transport"
import { applyUpdates } from "../updates"

const targetChatId = chatId(10)

const protocolMessage = (
  id: number,
  date = id,
): ProtocolMessage => ({
  id: BigInt(id),
  fromId: 8n,
  chatId: 10n,
  out: false,
  message: `Message ${id}`,
  date: BigInt(date),
})

const dbMessage = (
  id: number,
  status?: MessageSendingStatus,
): Message => ({
  kind: DbObjectKind.Message,
  id: messageKey(targetChatId, messageId(id)),
  chatId: targetChatId,
  messageId: messageId(id),
  fromId: userId(7),
  date: id,
  message: `Message ${id}`,
  status,
})

const applyHistory = (
  db: Db,
  mode: GetChatHistoryMode,
  messages: ProtocolMessage[],
) => {
  const transaction = getChatHistory({ mode })
  transaction.beforeExecute?.(db)
  const result = {
    oneofKind: "getChatHistory" as const,
    getChatHistory: { messages },
  }
  transaction.apply(result, db)
  transaction.afterCommit?.(result, db)
}

describe("direct message-window ownership", () => {
  it("replaces latest history while retaining local sends", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const old = dbMessage(20)
    const pending = dbMessage(
      9_001,
      MessageSendingStatus.Sending,
    )
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: messageId(100),
      date: 100,
    })
    db.insert(old)
    db.insert(pending)
    db.activateResidentMessageWindow(targetChatId)
    db.replaceResidentMessageWindow(
      targetChatId,
      [old.id],
      false,
    )

    applyHistory(
      db,
      GetChatHistoryMode.HISTORY_MODE_LATEST,
      [protocolMessage(99), protocolMessage(100)],
    )

    expect(
      db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, messageId(100)),
      ),
    ).toBe(true)
    expect(db.isMessageInHistoryWindow(targetChatId, pending.id)).toBe(
      true,
    )
    expect(db.isMessageInHistoryWindow(targetChatId, old.id)).toBe(
      false,
    )
    expect(db.fullChatWindows.isAtLatest(targetChatId)).toBe(true)
  })

  it("extends pagination and reaches latest only when the chat tail arrives", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const middle = dbMessage(50)
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: messageId(100),
      date: 100,
    })
    db.insert(middle)
    db.activateResidentMessageWindow(targetChatId)
    db.replaceResidentMessageWindow(
      targetChatId,
      [middle.id],
      false,
    )

    applyHistory(
      db,
      GetChatHistoryMode.HISTORY_MODE_NEWER,
      [protocolMessage(75)],
    )
    expect(db.fullChatWindows.isAtLatest(targetChatId)).toBe(false)
    expect(
      db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, messageId(75)),
      ),
    ).toBe(true)

    applyHistory(
      db,
      GetChatHistoryMode.HISTORY_MODE_NEWER,
      [protocolMessage(100)],
    )
    expect(db.fullChatWindows.isAtLatest(targetChatId)).toBe(true)
  })

  it("shows live tail messages only while the active window is at latest", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: messageId(10),
      date: 10,
    })
    db.activateResidentMessageWindow(targetChatId)

    upsertMessage(db, protocolMessage(11))
    const firstLiveKey = messageKey(targetChatId, messageId(11))
    expect(
      db.isMessageInHistoryWindow(targetChatId, firstLiveKey),
    ).toBe(true)

    db.replaceResidentMessageWindow(
      targetChatId,
      [firstLiveKey],
      false,
    )
    upsertMessage(db, protocolMessage(12))
    expect(
      db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, messageId(12)),
      ),
    ).toBe(false)
  })

  it("promotes an accepted send from old history without waiting for cache hydration", async () => {
    const auth = new AuthStore({ persistence: "memory" })
    const db = new Db({ autoHydrate: false, persistence: false })
    const old = dbMessage(4)
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: messageId(10),
      date: 10,
    })
    db.insert(old)
    db.activateResidentMessageWindow(targetChatId)
    db.replaceResidentMessageWindow(
      targetChatId,
      [old.id],
      false,
    )
    const client = new RealtimeClient({
      auth,
      db,
      transport: new MockTransport(),
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(7) })
    const temporaryMessageId = messageId(9_002)

    await client.mutateAccepted(
      sendMessage({
        chatId: targetChatId,
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 10n },
          },
        },
        text: "From old history",
        randomId: 92n,
        temporaryMessageId,
        temporarySendDate: 1_001,
      }),
    )

    expect(
      db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, temporaryMessageId),
      ),
    ).toBe(true)
    expect(db.isMessageInHistoryWindow(targetChatId, old.id)).toBe(
      false,
    )
    await client.stop()
  })

  it("keeps an acknowledged local send in the active window when its ID changes", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const temporary = {
      ...dbMessage(9_004, MessageSendingStatus.Sending),
      randomId: 94n,
    }
    const serverMessageId = messageId(104)
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: temporary.messageId,
      date: temporary.date,
    })
    db.insert(temporary)
    db.activateResidentMessageWindow(targetChatId)

    applyUpdates(db, [
      Update.create({
        update: {
          oneofKind: "updateMessageId",
          updateMessageId: {
            messageId: BigInt(serverMessageId),
            randomId: 94n,
          },
        },
      }),
    ])

    const serverKey = messageKey(targetChatId, serverMessageId)
    expect(db.get(db.ref(DbObjectKind.Message, serverKey))).toBeDefined()
    expect(
      db.isMessageInHistoryWindow(targetChatId, serverKey),
    ).toBe(true)
    expect(
      db.isMessageInHistoryWindow(targetChatId, temporary.id),
    ).toBe(false)
  })

  it("does not reuse history intent versions after a chat is reopened", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const current = dbMessage(50)
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: current.messageId,
      date: current.date,
    })
    db.insert(current)
    db.activateResidentMessageWindow(targetChatId)
    const stale = getChatHistory({
      mode: GetChatHistoryMode.HISTORY_MODE_LATEST,
    })
    stale.beforeExecute?.(db)

    db.releaseResidentMessageWindow(targetChatId)
    db.activateResidentMessageWindow(targetChatId)
    db.replaceResidentMessageWindow(
      targetChatId,
      [current.id],
      true,
    )
    const staleResult = {
      oneofKind: "getChatHistory" as const,
      getChatHistory: { messages: [protocolMessage(40)] },
    }
    stale.apply(staleResult, db)
    stale.afterCommit?.(staleResult, db)

    expect(
      db.isMessageInHistoryWindow(targetChatId, current.id),
    ).toBe(true)
    expect(
      db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, messageId(40)),
      ),
    ).toBe(false)
  })

  it("lets a newer send-to-latest intent cancel an older around read", async () => {
    let finishAround!: (messages: Message[]) => void
    const around = new Promise<Message[]>((resolve) => {
      finishAround = resolve
    })
    const storage: CollectionStorage<Message> = {
      init: async () => {},
      get: async () => undefined,
      getAll: async () => [],
      put: async () => {},
      delete: async () => {},
      getMessageWindowByChatId: async () => [],
      getMessageWindowAroundMessageId: async () => await around,
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: { [DbObjectKind.Message]: storage },
    })
    const old = dbMessage(4)
    const pending = dbMessage(
      9_003,
      MessageSendingStatus.Sending,
    )
    db.insert({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: messageId(10),
      date: 10,
    })
    db.insert(pending)
    db.activateResidentMessageWindow(targetChatId)

    const olderIntent = db.loadLocalWindowAroundMessage(targetChatId, {
      messageId: old.messageId,
      beforeLimit: 2,
      afterLimit: 2,
    })
    await db.promoteResidentMessageWindowToLatest(targetChatId)
    finishAround([old])

    await expect(olderIntent).resolves.toBe(false)
    expect(db.isMessageInHistoryWindow(targetChatId, pending.id)).toBe(
      true,
    )
    expect(db.isMessageInHistoryWindow(targetChatId, old.id)).toBe(
      false,
    )
  })

  it("rejects invalid local window requests at the data boundary", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    await expect(
      db.hydrateMessageWindow(targetChatId, { limit: 201 }),
    ).rejects.toThrow("Invalid Inline message window")
    await expect(
      db.loadLocalWindowAroundMessage(targetChatId, {
        messageId: messageId(1),
        beforeLimit: 100,
        afterLimit: 100,
      }),
    ).rejects.toThrow("Invalid Inline around-message window")
  })
})

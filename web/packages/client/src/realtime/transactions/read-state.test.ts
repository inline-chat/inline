import { Method, Update, type InputPeer } from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { decodePendingTransaction } from "./transaction-registry"
import { markAsUnread } from "./mark-as-unread"
import { readMessages } from "./read-messages"

const peerId: InputPeer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 801n },
  },
}

const makeDb = () => {
  const db = new Db({ autoHydrate: false, persistence: false })
  db.insert({
    kind: DbObjectKind.Chat,
    id: chatId(801),
    lastMsgId: messageId(30),
  })
  db.insert({
    kind: DbObjectKind.Dialog,
    id: dialogId(-801),
    chatId: chatId(801),
    peerThreadId: chatId(801),
    readMaxId: messageId(10),
    unreadCount: 4,
    unreadMark: true,
  })
  return db
}

describe("Inline read-state transactions", () => {
  it("encodes an exact read boundary and declares durable retry safety", () => {
    const transaction = readMessages({
      peerId,
      maxId: messageId("9007199254740993"),
    })

    expect(transaction.method).toBe(Method.READ_MESSAGES)
    expect(transaction.kind).toEqual({
      kind: "mutation",
      config: {
        retryAfterTransportLoss: true,
        retryAfterAck: true,
      },
    })
    expect(transaction.persistence).toEqual({
      type: "read_messages",
      replayPolicy: "idempotent",
    })
    expect(transaction.input(transaction.context)).toEqual({
      oneofKind: "readMessages",
      readMessages: {
        peerId,
        maxId: 9007199254740993n,
      },
    })
  })

  it("advances the resident boundary without falsely clearing newer unread messages", () => {
    const db = makeDb()
    readMessages({ peerId, maxId: messageId(20) }).optimistic(db)

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      readMaxId: messageId(20),
      unreadCount: 4,
      unreadMark: false,
    })

    readMessages({ peerId, maxId: messageId(30) }).optimistic(db)
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      readMaxId: messageId(30),
      unreadCount: 0,
      unreadMark: false,
    })
  })

  it("never moves a read boundary backwards", () => {
    const db = makeDb()
    readMessages({ peerId, maxId: messageId(5) }).optimistic(db)

    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.readMaxId,
    ).toBe(messageId(10))
  })

  it("makes mark-unread optimistic and durable", () => {
    const db = makeDb()
    db.replace({
      ...db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))!,
      unreadMark: false,
    })
    const transaction = markAsUnread({ peerId })
    transaction.optimistic(db)

    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.unreadMark,
    ).toBe(true)
    expect(transaction.persistence).toEqual({
      type: "mark_as_unread",
      replayPolicy: "idempotent",
    })
  })

  it("restores both durable read intents from the outbox allowlist", () => {
    const base = {
      kind: DbObjectKind.PendingTransaction as const,
      id: "tx",
      replayPolicy: "idempotent" as const,
      createdAt: 1,
      status: "pending" as const,
    }

    expect(
      decodePendingTransaction({
        ...base,
        type: "read_messages",
        context: { peerId, maxId: messageId(30) },
      }),
    ).toBeDefined()
    expect(
      decodePendingTransaction({
        ...base,
        type: "mark_as_unread",
        context: { peerId },
      }),
    ).toBeDefined()
  })

  it("applies the authoritative server read state", () => {
    const db = makeDb()
    const transaction = readMessages({ peerId, maxId: messageId(30) })
    transaction.apply(
      {
        oneofKind: "readMessages",
        readMessages: {
          updates: [
            Update.create({
              update: {
                oneofKind: "updateReadMaxId",
                updateReadMaxId: {
                  peerId: {
                    type: {
                      oneofKind: "chat",
                      chat: { chatId: 801n },
                    },
                  },
                  readMaxId: 30n,
                  unreadCount: 0,
                },
              },
            }),
          ],
        },
      },
      db,
    )

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      readMaxId: messageId(30),
      unreadCount: 0,
      unreadMark: false,
    })
  })
})

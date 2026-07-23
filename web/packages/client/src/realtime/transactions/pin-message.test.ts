import {
  Method,
  Update,
  type InputPeer,
  type Peer,
} from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { decodePendingTransaction } from "./transaction-registry"
import { pinMessage } from "./pin-message"

const peerId: InputPeer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 801n },
  },
}

const peer: Peer = {
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
    pinnedMessageIds: [messageId(30), messageId(20)],
  })
  return db
}

describe("PinMessageTransaction", () => {
  it("makes exact Unpin optimistic, durable, and replay-safe", () => {
    const db = makeDb()
    const transaction = pinMessage({
      peerId,
      messageId: messageId(30),
      unpin: true,
    })

    expect(transaction.method).toBe(Method.PIN_MESSAGE)
    expect(transaction.kind).toEqual({
      kind: "mutation",
      config: {
        retryAfterTransportLoss: true,
        retryAfterAck: true,
      },
    })
    expect(transaction.persistence).toEqual({
      type: "pin_message",
      replayPolicy: "idempotent",
    })
    expect(transaction.input(transaction.context)).toEqual({
      oneofKind: "pinMessage",
      pinMessage: {
        peerId,
        messageId: 30n,
        unpin: true,
      },
    })

    transaction.prepare(db)
    transaction.optimistic(db)
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(801)))?.pinnedMessageIds,
    ).toEqual([messageId(20)])

    const restored = decodePendingTransaction({
      kind: DbObjectKind.PendingTransaction,
      id: "unpin",
      type: "pin_message",
      replayPolicy: "idempotent",
      context: transaction.context,
      createdAt: 1,
      status: "pending",
    })
    expect(restored).toBeDefined()
    expect(restored?.context).toEqual(transaction.context)
  })

  it("keeps Pin non-durable because replay can reorder newer pins", () => {
    const db = makeDb()
    const transaction = pinMessage({
      peerId,
      messageId: messageId(10),
      unpin: false,
    })

    expect(transaction.persistence).toBeUndefined()
    expect(transaction.kind).toEqual({ kind: "mutation", config: {} })
    transaction.optimistic(db)
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(801)))?.pinnedMessageIds,
    ).toEqual([messageId(10), messageId(30), messageId(20)])
    expect(
      decodePendingTransaction({
        kind: DbObjectKind.PendingTransaction,
        id: "unsafe-pin",
        type: "pin_message",
        replayPolicy: "idempotent",
        context: transaction.context,
        createdAt: 1,
        status: "pending",
      }),
    ).toBeUndefined()
  })

  it("applies the authoritative pinned update", () => {
    const db = makeDb()
    const transaction = pinMessage({
      peerId,
      messageId: messageId(30),
      unpin: true,
    })

    transaction.apply(
      {
        oneofKind: "pinMessage",
        pinMessage: {
          updates: [
            Update.create({
              update: {
                oneofKind: "pinnedMessages",
                pinnedMessages: {
                  peerId: peer,
                  messageIds: [20n],
                },
              },
            }),
          ],
        },
      },
      db,
    )

    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(801)))?.pinnedMessageIds,
    ).toEqual([messageId(20)])
  })

  it("rolls back only while its own optimistic value is current", () => {
    const db = makeDb()
    const transaction = pinMessage({
      peerId,
      messageId: messageId(30),
      unpin: true,
    })
    transaction.prepare(db)
    transaction.optimistic(db)
    transaction.failed(new Error("rejected"), db)
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(801)))?.pinnedMessageIds,
    ).toEqual([messageId(30), messageId(20)])

    transaction.optimistic(db)
    const chat = db.get(db.ref(DbObjectKind.Chat, chatId(801)))!
    db.replace({ ...chat, pinnedMessageIds: [messageId(40)] })
    transaction.failed(new Error("late rejection"), db)
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(801)))?.pinnedMessageIds,
    ).toEqual([messageId(40)])
  })
})

import { Chat, Dialog, Method } from "@inline-chat/protocol/core"
import { chatId, dialogId, spaceId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { AuthStore } from "../../auth"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { createChat } from "./create-chat"
import { decodePendingTransaction } from "./transaction-registry"

describe("CreateChatTransaction", () => {
  it("encodes Inline's untitled private-thread input without inventing a title", () => {
    const transaction = createChat({
      title: "  \n ",
      spaceId: spaceId("9007199254740993"),
      isPublic: false,
      participants: [{ userId: 9007199254740995n }],
    })

    expect(transaction.method).toBe(Method.CREATE_CHAT)
    expect(transaction.kind).toEqual({
      kind: "mutation",
      config: {},
    })
    expect(transaction.persistence).toBeUndefined()
    expect(transaction.input(transaction.context)).toEqual({
      oneofKind: "createChat",
      createChat: {
        title: undefined,
        spaceId: 9007199254740993n,
        description: undefined,
        emoji: undefined,
        isPublic: false,
        participants: [{ userId: 9007199254740995n }],
      },
    })
  })

  it("requires the authoritative chat and dialog before committing either", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const transaction = createChat({ isPublic: false })

    expect(() =>
      transaction.apply(
        {
          oneofKind: "createChat",
          createChat: {
            chat: Chat.create({ id: 801n, title: "Thread" }),
          },
        },
        db,
      ),
    ).toThrow("invalid")
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(801))),
    ).toBeUndefined()

    expect(() =>
      transaction.apply(
        {
          oneofKind: "createChat",
          createChat: {
            chat: Chat.create({ id: 801n, title: "Thread" }),
            dialog: Dialog.create({ chatId: 802n }),
          },
        },
        db,
      ),
    ).toThrow("invalid")
  })

  it("maps the server chat and dialog with exact Inline IDs", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const transaction = createChat({ isPublic: false })

    transaction.apply(
      {
        oneofKind: "createChat",
        createChat: {
          chat: Chat.create({
            id: 801n,
            title: "",
            untitled: true,
            createdBy: 31n,
          }),
          dialog: Dialog.create({
            chatId: 801n,
            peer: {
              type: {
                oneofKind: "chat",
                chat: { chatId: 801n },
              },
            },
            open: false,
          }),
        },
      },
      db,
    )

    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(801))),
    ).toMatchObject({
      id: chatId(801),
      untitled: true,
      createdBy: userId(31),
    })
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801))),
    ).toMatchObject({
      chatId: chatId(801),
      peerThreadId: chatId(801),
      open: false,
    })
  })

  it("atomically claims a reserved ID and creates Inline's optimistic models", () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const auth = new AuthStore()
    void auth.login({ token: "token", userId: userId(31) })
    const reservedChatId = chatId(901)
    db.insert({
      kind: DbObjectKind.ReservedChatID,
      id: reservedChatId,
      chatId: reservedChatId,
      expiresAt: Math.floor(Date.now() / 1_000) + 60,
      createdAt: Date.now(),
    })
    const transaction = createChat({
      title: "  ",
      spaceId: spaceId(71),
      isPublic: false,
      participants: [{ userId: 31n }],
      reservedChatId,
    })

    db.batch(() => {
      transaction.prepare?.(db)
      transaction.optimistic?.(db, auth)
    })

    expect(transaction.persistence).toEqual({
      type: "create_chat",
      replayPolicy: "idempotent",
    })
    expect(transaction.kind).toEqual({
      kind: "mutation",
      config: {
        retryAfterTransportLoss: true,
        retryAfterAck: true,
      },
    })
    expect(transaction.context.reservationClaimed).toBe(true)
    expect(
      db.get(db.ref(DbObjectKind.ReservedChatID, reservedChatId)),
    ).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Chat, reservedChatId))).toMatchObject({
      id: reservedChatId,
      spaceId: spaceId(71),
      createdBy: userId(31),
      untitled: true,
      createState: "pending",
    })
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-901))),
    ).toMatchObject({
      chatId: reservedChatId,
      peerThreadId: reservedChatId,
      open: false,
    })
    expect(transaction.satisfiedBlockersOnSuccess).toEqual([
      { type: "chatCreated", chatId: reservedChatId },
    ])
    expect(transaction.input(transaction.context)).toMatchObject({
      oneofKind: "createChat",
      createChat: { reservedChatId: 901n },
    })
  })

  it("refuses unclaimed persisted creates and marks an accepted create failed", () => {
    const reservedChatId = chatId(902)
    expect(
      decodePendingTransaction({
        kind: DbObjectKind.PendingTransaction,
        id: "unsafe-create",
        type: "create_chat",
        replayPolicy: "idempotent",
        context: { isPublic: false, reservedChatId },
        createdAt: 1,
        status: "pending",
      }),
    ).toBeUndefined()

    const db = new Db({ autoHydrate: false, persistence: false })
    db.insert({
      kind: DbObjectKind.Chat,
      id: reservedChatId,
      createState: "pending",
    })
    const restored = decodePendingTransaction({
      kind: DbObjectKind.PendingTransaction,
      id: "accepted-create",
      type: "create_chat",
      replayPolicy: "idempotent",
      context: {
        isPublic: false,
        reservedChatId,
        reservationClaimed: true,
      },
      createdAt: 2,
      status: "pending",
    })
    expect(restored).toBeDefined()
    restored?.failed?.({ kind: "rpc-error" }, db, new AuthStore())
    expect(db.get(db.ref(DbObjectKind.Chat, reservedChatId))?.createState).toBe(
      "failed",
    )
  })
})

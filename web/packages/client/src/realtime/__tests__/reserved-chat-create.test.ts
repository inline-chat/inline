import {
  Chat,
  Dialog,
  Method,
  RpcError_Code,
  ServerProtocolMessage,
  type ClientMessage,
} from "@inline-chat/protocol/core"
import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { chatId, dialogId, userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AuthStore } from "../../auth"
import { DatabaseCommitError, Db } from "../../database"
import {
  DbObjectKind,
  type PendingTransaction,
} from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { RealtimeClient } from "../realtime"
import { createChat, updateDialogOpen } from "../transactions"
import { MockTransport } from "../transport/mock-transport"

const waitFor = async (predicate: () => boolean, timeoutMs = 500) => {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  throw new Error("Timed out waiting for condition")
}

const connectAndOpen = async (transport: MockTransport) => {
  await transport.connect()
  await transport.emitMessage(
    ServerProtocolMessage.create({
      id: 1n,
      body: { oneofKind: "connectionOpen", connectionOpen: {} },
    }),
  )
}

const rpcCalls = (transport: MockTransport, method: Method) =>
  transport.sent.filter(
    (message): message is ClientMessage & {
      body: Extract<ClientMessage["body"], { oneofKind: "rpcCall" }>
    } =>
      message.body.oneofKind === "rpcCall" &&
      message.body.rpcCall.method === method,
  )

const reservation = (id = chatId(901)) => ({
  kind: DbObjectKind.ReservedChatID as const,
  id,
  chatId: id,
  expiresAt: Math.floor(Date.now() / 1_000) + 300,
  createdAt: Date.now(),
})

const createResult = (reqMsgId: bigint, id = 901n) =>
  ServerProtocolMessage.create({
    id: 90n,
    body: {
      oneofKind: "rpcResult",
      rpcResult: {
        reqMsgId,
        result: {
          oneofKind: "createChat",
          createChat: {
            chat: Chat.create({
              id,
              untitled: true,
              createdBy: 31n,
            }),
            dialog: Dialog.create({
              chatId: id,
              peer: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: id },
                },
              },
              open: false,
            }),
          },
        },
      },
    },
  })

const openResult = (reqMsgId: bigint, id = 901n) =>
  ServerProtocolMessage.create({
    id: 91n,
    body: {
      oneofKind: "rpcResult",
      rpcResult: {
        reqMsgId,
        result: {
          oneofKind: "updateDialogOpen",
          updateDialogOpen: {
            chat: Chat.create({ id, untitled: true }),
            dialog: Dialog.create({
              chatId: id,
              peer: {
                type: {
                  oneofKind: "chat",
                  chat: { chatId: id },
                },
              },
              open: true,
            }),
          },
        },
      },
    },
  })

const pending = (db: Db) =>
  db.queryCollection<
    DbObjectKind.PendingTransaction,
    PendingTransaction,
    DbQueryPlanType.Objects
  >(
    DbQueryPlanType.Objects,
    DbObjectKind.PendingTransaction,
    () => true,
  )

class FailNextCommitDb extends Db {
  failNextCommit = false

  override commit(recipe: () => void): Promise<void> {
    if (this.failNextCommit) {
      this.failNextCommit = false
      return Promise.reject(
        new DatabaseCommitError(
          new Error("temporary IndexedDB write failure"),
        ),
      )
    }
    return super.commit(recipe)
  }
}

describe("reserved chat create and chatCreated blocker", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("sends create before Inbox open and releases the blocker only after apply", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    db.insert(reservation())
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(31) })
    await connectAndOpen(transport)

    const createdChatId = await client.createThread({
      title: "",
      isPublic: false,
      participants: [userId(31)],
    })
    await client.mutateAccepted(
      updateDialogOpen({
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 901n },
          },
        },
        open: true,
        requiresChatCreated: true,
      }),
    )

    expect(createdChatId).toBe(chatId(901))
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(901)))).toMatchObject({
      createState: "pending",
    })
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-901)))).toMatchObject({
      open: true,
    })
    expect(
      db.get(db.ref(DbObjectKind.ReservedChatID, chatId(901))),
    ).toBeUndefined()
    await waitFor(() => rpcCalls(transport, Method.CREATE_CHAT).length === 1)
    expect(rpcCalls(transport, Method.UPDATE_DIALOG_OPEN)).toHaveLength(0)

    const createCall = rpcCalls(transport, Method.CREATE_CHAT)[0]!
    await transport.emitMessage(createResult(createCall.id))
    await waitFor(
      () => rpcCalls(transport, Method.UPDATE_DIALOG_OPEN).length === 1,
    )
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(901)))?.createState,
    ).toBeUndefined()

    const openCall = rpcCalls(
      transport,
      Method.UPDATE_DIALOG_OPEN,
    )[0]!
    await transport.emitMessage(openResult(openCall.id))
    await waitFor(() => pending(db).length === 0)
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-901)))?.open).toBe(
      true,
    )
    await client.stop()
  })

  it("uses native server-first direct create when the warm pool is empty", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(31) })
    await connectAndOpen(transport)

    const createPromise = client.createThread({
      title: "",
      isPublic: false,
      participants: [userId(31)],
    })
    await waitFor(() => rpcCalls(transport, Method.CREATE_CHAT).length === 1)
    const createCall = rpcCalls(transport, Method.CREATE_CHAT)[0]!
    const input = createCall.body.rpcCall.input
    expect(input?.oneofKind).toBe("createChat")
    if (input?.oneofKind !== "createChat") {
      throw new Error("Missing direct createChat input")
    }
    expect("reservedChatId" in input.createChat).toBe(false)
    await transport.emitMessage(createResult(createCall.id, 950n))
    await expect(createPromise).resolves.toBe(chatId(950))
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(950)))).toBeDefined()
    await client.stop()
  })

  it("restores create-before-open ordering after an owner crash", async () => {
    vi.stubGlobal("indexedDB", new IDBFactory())
    vi.stubGlobal("IDBKeyRange", IDBKeyRange)
    const namespace = `reserved-restart-${crypto.randomUUID()}`
    const firstAuth = new AuthStore()
    await firstAuth.login({ token: "token", userId: userId(31) })
    const firstDb = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await firstDb.commit(() => firstDb.insert(reservation()))
    const firstClient = new RealtimeClient({
      auth: firstAuth,
      db: firstDb,
      transport: new MockTransport(),
      sync: false,
    })
    await firstClient.mutateAccepted(
      createChat({
        isPublic: false,
        participants: [{ userId: 31n }],
        reservedChatId: chatId(901),
      }),
    )
    await firstClient.mutateAccepted(
      updateDialogOpen({
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 901n },
          },
        },
        open: true,
        requiresChatCreated: true,
      }),
    )
    await firstDb.flushPersistence()

    const secondAuth = new AuthStore()
    await secondAuth.login({ token: "token", userId: userId(31) })
    const secondDb = new Db({
      autoHydrate: false,
      storageNamespace: namespace,
    })
    await secondDb.hydrateKinds([
      DbObjectKind.Chat,
      DbObjectKind.Dialog,
    ])
    const transport = new MockTransport()
    const secondClient = new RealtimeClient({
      auth: secondAuth,
      db: secondDb,
      transport,
      sync: false,
    })
    await secondClient.start()
    await connectAndOpen(transport)

    await waitFor(() => rpcCalls(transport, Method.CREATE_CHAT).length === 1)
    expect(rpcCalls(transport, Method.UPDATE_DIALOG_OPEN)).toHaveLength(0)
    expect(
      secondDb.get(
        secondDb.ref(DbObjectKind.ReservedChatID, chatId(901)),
      ),
    ).toBeUndefined()

    await transport.emitMessage(
      createResult(rpcCalls(transport, Method.CREATE_CHAT)[0]!.id),
    )
    await waitFor(
      () => rpcCalls(transport, Method.UPDATE_DIALOG_OPEN).length === 1,
    )
    await transport.emitMessage(
      openResult(
        rpcCalls(transport, Method.UPDATE_DIALOG_OPEN)[0]!.id,
      ),
    )
    await waitFor(() => pending(secondDb).length === 0)
    await secondClient.stop()
  })

  it("retries only local result persistence before releasing the open blocker", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new FailNextCommitDb({
      autoHydrate: false,
      persistence: false,
    })
    db.insert(reservation())
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(31) })
    await connectAndOpen(transport)
    await client.mutateAccepted(
      createChat({
        isPublic: false,
        reservedChatId: chatId(901),
      }),
    )
    await client.mutateAccepted(
      updateDialogOpen({
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 901n },
          },
        },
        open: true,
        requiresChatCreated: true,
      }),
    )
    await waitFor(() => rpcCalls(transport, Method.CREATE_CHAT).length === 1)

    db.failNextCommit = true
    await transport.emitMessage(
      createResult(rpcCalls(transport, Method.CREATE_CHAT)[0]!.id),
    )
    expect(rpcCalls(transport, Method.UPDATE_DIALOG_OPEN)).toHaveLength(0)
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(901)))?.createState).toBe(
      "pending",
    )

    await waitFor(
      () => rpcCalls(transport, Method.UPDATE_DIALOG_OPEN).length === 1,
    )
    expect(rpcCalls(transport, Method.CREATE_CHAT)).toHaveLength(1)
    expect(
      db.get(db.ref(DbObjectKind.Chat, chatId(901)))?.createState,
    ).toBeUndefined()
    await transport.emitMessage(
      openResult(
        rpcCalls(transport, Method.UPDATE_DIALOG_OPEN)[0]!.id,
      ),
    )
    await waitFor(() => pending(db).length === 0)
    await client.stop()
  })

  it("fails a dependent Inbox open when reserved creation fails", async () => {
    const transport = new MockTransport()
    const auth = new AuthStore()
    const db = new Db({ autoHydrate: false, persistence: false })
    db.insert(reservation())
    const client = new RealtimeClient({
      auth,
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(31) })
    await connectAndOpen(transport)
    await client.mutateAccepted(
      createChat({
        isPublic: false,
        reservedChatId: chatId(901),
      }),
    )
    await client.mutateAccepted(
      updateDialogOpen({
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 901n },
          },
        },
        open: true,
        requiresChatCreated: true,
      }),
    )
    await waitFor(() => rpcCalls(transport, Method.CREATE_CHAT).length === 1)
    const createCall = rpcCalls(transport, Method.CREATE_CHAT)[0]!
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 92n,
        body: {
          oneofKind: "rpcError",
          rpcError: {
            reqMsgId: createCall.id,
            code: 400,
            errorCode: RpcError_Code.BAD_REQUEST,
            message: "CREATE_FAILED",
          },
        },
      }),
    )
    await waitFor(
      () => pending(db).filter((value) => value.status === "failed").length === 2,
    )
    expect(rpcCalls(transport, Method.UPDATE_DIALOG_OPEN)).toHaveLength(0)
    expect(db.get(db.ref(DbObjectKind.Chat, chatId(901)))?.createState).toBe(
      "failed",
    )
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-901)))?.open).toBe(
      false,
    )
    await client.stop()
  })
})

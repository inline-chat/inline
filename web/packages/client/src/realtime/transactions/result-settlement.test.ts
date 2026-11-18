import {
  Method,
  ServerProtocolMessage,
  Update,
  type ClientMessage,
} from "@inline-chat/protocol/core"
import { chatId, userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AuthStore } from "../../auth"
import { Db } from "../../database"
import { DbObjectKind, type PendingTransaction } from "../../database/models"
import type { InlinePersistenceStore } from "../../database/persistence"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { DbQueryPlanType } from "../../database/types"
import {
  MAX_RESULT_SETTLEMENT_ATTEMPTS,
  RealtimeClient,
} from "../realtime"
import { MockTransport } from "../transport/mock-transport"
import { sendMessage } from "./send-message"
import { TransactionFailure } from "./transaction-errors"

/** The real SQLite store, with a switch that makes every write fail. */
const createBrokenDiskStore = () => {
  const inner = createSqliteMemoryPersistenceStore()
  const state = { failing: false, failedWrites: 0 }
  const store: InlinePersistenceStore = {
    open: () => inner.open(),
    close: () => inner.close(),
    collection: (kind) => inner.collection(kind),
    async write(operations) {
      if (state.failing) {
        state.failedWrites += 1
        throw new DOMException("disk full", "QuotaExceededError")
      }
      await inner.write(operations)
    },
  }
  return { store, state }
}

const isSend = (message: ClientMessage) =>
  message.body.oneofKind === "rpcCall" &&
  message.body.rpcCall.method === Method.SEND_MESSAGE

/** Yield to the event loop a bounded number of turns until `ready`. */
const until = async (ready: () => boolean) => {
  for (let turn = 0; turn < 500; turn += 1) {
    if (ready()) return
    await new Promise<void>((resolve) => setImmediate(resolve))
  }
  throw new Error("condition never became true")
}

describe("intent settlement after a failed local commit", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("stops retrying after the cap and settles the intent as uncertain, not failed", async () => {
    const { store, state } = createBrokenDiskStore()
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    const transport = new MockTransport()
    const client = new RealtimeClient({
      auth: new AuthStore(),
      db,
      transport,
      sync: false,
    })
    await client.startSession({ token: "token", userId: userId(7) })

    const result = client.execute(
      sendMessage({
        chatId: chatId(10),
        peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
        text: "Server has it, disk does not",
      }),
    )
    const settled = result.then(
      () => undefined,
      (error: unknown) => error,
    )
    await transport.connect()
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 1n,
        body: { oneofKind: "connectionOpen", connectionOpen: {} },
      }),
    )
    await until(() => transport.sent.some(isSend))
    const request = transport.sent.find(isSend)!
    if (
      request.body.oneofKind !== "rpcCall" ||
      request.body.rpcCall.input.oneofKind !== "sendMessage"
    ) {
      throw new Error("missing sendMessage request")
    }

    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    state.failing = true
    await transport.emitMessage(
      ServerProtocolMessage.create({
        id: 2n,
        body: {
          oneofKind: "rpcResult",
          rpcResult: {
            reqMsgId: request.id,
            result: {
              oneofKind: "sendMessage",
              sendMessage: {
                addedUserIds: [],
                unaddedUserIds: [],
                updates: [
                  Update.create({
                    update: {
                      oneofKind: "updateMessageId",
                      updateMessageId: {
                        messageId: 900n,
                        randomId:
                          request.body.rpcCall.input.sendMessage.randomId ??
                          0n,
                      },
                    },
                  }),
                ],
              },
            },
          },
        },
      }),
    )
    await until(() => state.failedWrites === 1)

    // 50 ms doubling to a 5 s ceiling: well under a minute in all.
    for (let step = 0; step < 60; step += 1) {
      await vi.advanceTimersByTimeAsync(1_000)
    }

    const error = await settled
    expect(error).toBeInstanceOf(TransactionFailure)
    expect((error as TransactionFailure).kind).toBe("ambiguous-result")
    expect(state.failedWrites).toBe(1 + MAX_RESULT_SETTLEMENT_ATTEMPTS)

    // Nothing retries any more.
    await vi.advanceTimersByTimeAsync(10 * 60_000)
    expect(state.failedWrites).toBe(1 + MAX_RESULT_SETTLEMENT_ATTEMPTS)

    // The durable intent is untouched, so a restart can reconcile it.
    const [pending] = db.queryCollection<
      DbObjectKind.PendingTransaction,
      PendingTransaction,
      DbQueryPlanType.Objects
    >(DbQueryPlanType.Objects, DbObjectKind.PendingTransaction)
    expect(pending?.status).toBe("pending")

    vi.useRealTimers()
    state.failing = false
    await client.stop()
  })
})

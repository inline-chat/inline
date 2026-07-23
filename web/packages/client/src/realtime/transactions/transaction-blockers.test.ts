import { Method, type RpcCall } from "@inline-chat/protocol/core"
import { chatId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import type { Db } from "../../database"
import {
  Query,
  chatCreatedBlocker,
  type Transaction,
} from "./transaction"
import { Transactions } from "./transactions"

const transaction = (
  name: string,
  blockers = [] as ReturnType<typeof chatCreatedBlocker>[],
): Transaction<{ name: string }> => ({
  method: Method.GET_ME,
  kind: Query(),
  context: { name },
  blockers,
  input: () =>
    ({ oneofKind: "getMe", getMe: {} }) as RpcCall["input"],
  apply: (_result, _db: Db) => undefined,
})

describe("Transaction blockers", () => {
  it("skips blocked work without stalling unrelated queued transactions", () => {
    const queue = new Transactions()
    const blocker = chatCreatedBlocker(chatId(901))
    queue.enqueue(transaction("open", [blocker]), { id: "open" })
    queue.enqueue(transaction("unrelated"), { id: "other" })

    expect(queue.dequeue(() => "blocked")).toMatchObject({
      state: "ready",
      wrapper: { id: "other" },
    })
    expect(queue.dequeue(() => "blocked")).toBeNull()

    queue.satisfy([blocker])
    expect(queue.dequeue(() => "blocked")).toMatchObject({
      state: "ready",
      wrapper: { id: "open" },
    })
  })

  it("returns a dependency failure without moving the transaction in flight", () => {
    const queue = new Transactions()
    queue.enqueue(
      transaction("open", [chatCreatedBlocker(chatId(902))]),
      { id: "open" },
    )

    expect(queue.dequeue(() => "failed")).toMatchObject({
      state: "failed",
      wrapper: { id: "open" },
    })
    expect(queue.dequeue(() => "satisfied")).toBeNull()
  })
})

import { describe, expect, test } from "bun:test"
import { BotChatSettingsProblem_Code, type BotChatSettingsResponse } from "@inline-chat/protocol/core"
import { BotChatSettingsBroker } from "./broker"

const documentResponse = (revision: string): BotChatSettingsResponse => ({
  result: {
    oneofKind: "document",
    document: { version: 1, revision, sections: [] },
  },
})

const scope = (botUserId: number, actorUserId = 7, chatId = 9) => ({ botUserId, actorUserId, chatId })

describe("BotChatSettingsBroker", () => {
  test("the first answer wins and late answers are rejected", async () => {
    let nextId = 1n
    const broker = new BotChatSettingsBroker({ generateId: () => nextId++ })
    const pending = broker.create(scope(42))
    expect(broker.answer(pending.requestId, 99, documentResponse("wrong-bot"))).toBe(false)
    expect(broker.answer(pending.requestId, 42, documentResponse("one"))).toBe(true)
    expect(broker.answer(pending.requestId, 42, documentResponse("two"))).toBe(false)
    expect((await pending.response).result).toMatchObject({
      oneofKind: "document",
      document: { revision: "one" },
    })
  })

  test("times out as unreachable and clears the correlation", async () => {
    const broker = new BotChatSettingsBroker({ answerTimeoutMs: 1, generateId: () => 1n })
    const pending = broker.create(scope(42))
    expect((await pending.response).result).toMatchObject({
      oneofKind: "problem",
      problem: { code: BotChatSettingsProblem_Code.UNREACHABLE },
    })
    expect(broker.pendingCount).toBe(0)
  })

  test("shutdown resolves every waiter", async () => {
    let nextId = 1n
    const broker = new BotChatSettingsBroker({ generateId: () => nextId++ })
    const first = broker.create(scope(1))
    const second = broker.create(scope(2))
    broker.shutdown()
    expect((await first.response).result.oneofKind).toBe("problem")
    expect((await second.response).result.oneofKind).toBe("problem")
    expect(broker.pendingCount).toBe(0)
  })

  test("bounds one actor, bot, and chat without evicting unrelated requests", async () => {
    let nextId = 1n
    const broker = new BotChatSettingsBroker({
      maxPendingRequests: 10,
      maxPendingRequestsPerKey: 2,
      generateId: () => nextId++,
    })
    const unrelated = broker.create(scope(2, 8, 10))
    const first = broker.create(scope(1))
    const second = broker.create(scope(1))
    const third = broker.create(scope(1))

    expect((await first.response).result).toMatchObject({
      oneofKind: "problem",
      problem: { code: BotChatSettingsProblem_Code.UNREACHABLE },
    })
    expect(broker.pendingCount).toBe(3)
    expect(broker.answer(unrelated.requestId, 2, documentResponse("unrelated"))).toBe(true)
    expect(broker.answer(second.requestId, 1, documentResponse("second"))).toBe(true)
    expect(broker.answer(third.requestId, 1, documentResponse("third"))).toBe(true)
  })
})

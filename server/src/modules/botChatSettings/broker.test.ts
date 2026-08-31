import { describe, expect, test } from "bun:test"
import { BotChatSettingsProblem_Code, type BotChatSettingsResponse } from "@inline-chat/protocol/core"
import { BotChatSettingsBroker } from "./broker"

const documentResponse = (revision: string): BotChatSettingsResponse => ({
  result: {
    oneofKind: "document",
    document: { version: 1, revision, sections: [] },
  },
})

const scope = (
  botUserId: number,
  actorUserId = 7,
  chatId = 9,
  operation: "request" | "mutation" = "request",
) => ({ botUserId, actorUserId, chatId, operation })

describe("BotChatSettingsBroker", () => {
  test("the first answer wins and late answers are rejected", async () => {
    let nextId = 1n
    const broker = new BotChatSettingsBroker({ generateId: () => nextId++ })
    const pending = broker.create(scope(42))
    expect(broker.answer(pending.requestId, 99, documentResponse("wrong-bot"))).toBe("wrong_bot")
    expect(broker.answer(pending.requestId, 42, documentResponse("one"))).toBe("answered")
    expect(broker.answer(pending.requestId, 42, documentResponse("two"))).toBe("missing")
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
    expect(broker.answer(unrelated.requestId, 2, documentResponse("unrelated"))).toBe("answered")
    expect(broker.answer(second.requestId, 1, documentResponse("second"))).toBe("answered")
    expect(broker.answer(third.requestId, 1, documentResponse("third"))).toBe("answered")
  })

  test("emits privacy-safe dispatch and terminal diagnostics", async () => {
    let now = 100
    const diagnostics: Array<Record<string, unknown>> = []
    const broker = new BotChatSettingsBroker({
      generateId: () => 1n,
      now: () => now,
      onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
    })
    const pending = broker.create(scope(42, 7, 9, "mutation"))

    expect(broker.markDispatched(pending.requestId, 2)).toBe(true)
    now = 1_600
    expect(broker.answer(pending.requestId, 42, documentResponse("done"))).toBe("answered")
    await pending.response

    expect(diagnostics).toEqual([
      {
        phase: "dispatched",
        operation: "mutation",
        pendingCount: 1,
        recipientCount: 2,
      },
      {
        phase: "resolved",
        operation: "mutation",
        pendingCount: 0,
        elapsedMs: 1_500,
        outcome: "document",
        reason: "answer",
        recipientCount: 2,
      },
    ])
  })

  test("classifies a dispatch failure and clears its waiter", async () => {
    const diagnostics: Array<Record<string, unknown>> = []
    const broker = new BotChatSettingsBroker({
      generateId: () => 1n,
      onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
    })
    const pending = broker.create(scope(42))

    expect(broker.resolveSystem(
      pending.requestId,
      {
        result: {
          oneofKind: "problem",
          problem: { code: BotChatSettingsProblem_Code.UNREACHABLE, message: "Bot unreachable" },
        },
      },
      "dispatch_failure",
    )).toBe(true)
    await pending.response

    expect(broker.pendingCount).toBe(0)
    expect(diagnostics.at(-1)).toMatchObject({
      phase: "resolved",
      operation: "request",
      reason: "dispatch_failure",
      outcome: `problem:${BotChatSettingsProblem_Code.UNREACHABLE}`,
    })
  })
})

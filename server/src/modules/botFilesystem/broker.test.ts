import { describe, expect, test } from "bun:test"
import { BotFilesystemBroker } from "./broker"
import type { BotFilesystemResponse } from "@inline-chat/protocol/core"
const reply: BotFilesystemResponse = { result: { oneofKind: "workspaceId", workspaceId: "workspace-1" } }

describe("private filesystem broker", () => {
  test("only the exact bot can answer; answers are consumed once", async () => {
    const broker = new BotFilesystemBroker()
    const pending = broker.create(7, "connection-a")!
    expect(broker.answer(pending.id, 8, "connection-a", reply)).toBe(false)
    expect(broker.answer(pending.id, 7, "connection-b", reply)).toBe(false)
    expect(broker.answer(pending.id, 7, "connection-a", reply)).toBe(true)
    expect(broker.answer(pending.id, 7, "connection-a", reply)).toBe(false)
    expect(await pending.response).toEqual(reply)
  })
  test("per-bot capacity is bounded and shutdown resolves all requests", async () => {
    const broker = new BotFilesystemBroker()
    const pending = Array.from({ length: 8 }, () => broker.create(7, "connection-a")!)
    expect(broker.create(7, "connection-a")).toBeUndefined()
    broker.shutdown()
    for (const request of pending) expect((await request.response).result.oneofKind).toBe("problem")
  })
  test("offline hosts time out", async () => {
    const broker = new BotFilesystemBroker(1)
    expect((await broker.create(7, "connection-a")!.response).result.oneofKind).toBe("problem")
  })
})

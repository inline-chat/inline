import {
  GetUpdatesResult_ResultType,
  Method,
  SyncSkippedSequence_Reason,
} from "@inline-chat/protocol/core"
import { afterEach, describe, expect, it } from "vitest"
import { messageId } from "@inline/ids"
import { CoreHarness } from "./core-harness"
import { ServerModel, chatInputPeer } from "./server-model"

/**
 * The server model answers sync the way the server does, and a real core
 * runs against it. These tests double as its documentation.
 */

const getUpdates = (
  model: ServerModel,
  bucket: "user" | bigint,
  startSeq: number,
  options: { seqEnd?: number; limit?: number } = {},
) => {
  const outcome = model.handleRpc(0, Method.GET_UPDATES, {
    oneofKind: "getUpdates",
    getUpdates: {
      bucket: {
        type:
          bucket === "user"
            ? { oneofKind: "user", user: {} }
            : { oneofKind: "chat", chat: { peerId: chatInputPeer(bucket) } },
      },
      startSeq: BigInt(startSeq),
      seqEnd: BigInt(options.seqEnd ?? 0),
      limit: options.limit ?? 0,
      totalLimit: 0,
    },
  })
  if (!("result" in outcome) || outcome.result.oneofKind !== "getUpdates") {
    throw new Error("expected a getUpdates result")
  }
  return outcome.result.getUpdates
}

describe("server model", () => {
  it("pages a chat bucket 100 records at a time and accounts for every sequence", () => {
    let now = 1_000
    const model = new ServerModel({ now: () => now })
    model.addChat({ id: 10n, participants: [2n] })
    for (let index = 0; index < 150; index += 1) {
      now += 1
      model.postMessage({ chatId: 10n, fromId: 2n, text: `m${index}` })
    }
    model.deleteMessages(10n, [3n])

    const first = getUpdates(model, 10n, 0)
    expect(first.updates).toHaveLength(100)
    expect(first.seq).toBe(100n)
    expect(first.final).toBe(false)
    // A deleted message replays as chatSkipPts, as the server's replay does.
    expect(first.updates[2]?.update.oneofKind).toBe("chatSkipPts")
    // Non-empty chat pages carry the chat and the dialog's current unread count.
    expect(first.sidecars?.dialogs[0]?.unreadCount).toBe(149)

    const second = getUpdates(model, 10n, 100)
    expect(second.seq).toBe(151n)
    expect(second.final).toBe(true)
  })

  it("answers TOO_LONG past the replay limit and across a pruned journal", () => {
    const model = new ServerModel({ now: () => 1_000, replayLimit: 20 })
    model.addChat({ id: 10n, participants: [2n] })
    for (let index = 0; index < 30; index += 1) {
      model.postMessage({ chatId: 10n, fromId: 2n, text: `m${index}` })
    }
    expect(getUpdates(model, 10n, 0).resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(getUpdates(model, 10n, 0, { seqEnd: 20 }).resultType).toBe(
      GetUpdatesResult_ResultType.SLICE,
    )

    model.pruneJournal("chat:10", 15)
    const pruned = getUpdates(model, 10n, 12)
    expect(pruned.resultType).toBe(GetUpdatesResult_ResultType.TOO_LONG)
    expect(pruned.seq).toBe(30n)
  })

  it("lists records without a projection as skipped sequences", () => {
    const model = new ServerModel({ now: () => 1_000 })
    model.addChat({ id: 10n, participants: [2n] })
    model.postMessage({ chatId: 10n, fromId: 2n, text: "hello" })
    model.addIrrelevantRecord("user")
    model.readOnOtherDevice(10n, 1n)

    const page = getUpdates(model, "user", 0)
    expect(page.seq).toBe(2n)
    expect(page.skippedSequences).toEqual([
      { seq: 1n, reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET },
    ])
    expect(page.updates[0]?.update.oneofKind).toBe("updateReadMaxId")
  })

  it("assigns a sent message one ID per random ID", () => {
    const model = new ServerModel({ now: () => 1_000 })
    model.addChat({ id: 10n })
    const send = () =>
      model.handleRpc(0, Method.SEND_MESSAGE, {
        oneofKind: "sendMessage",
        sendMessage: { peerId: chatInputPeer(10n), randomId: 77n, message: "once" },
      })
    const first = send()
    const retry = send()
    expect(model.chatState(10n).messages).toHaveLength(1)
    if (!("result" in first) || !("result" in retry)) throw new Error("expected results")
    if (first.result.oneofKind !== "sendMessage" || retry.result.oneofKind !== "sendMessage") {
      throw new Error("expected sendMessage results")
    }
    expect(first.result.sendMessage.updates.map((update) => update.update.oneofKind)).toEqual([
      "updateMessageId",
      "newMessage",
    ])
    // The server answers a retry with the receipt only.
    expect(retry.result.sendMessage.updates.map((update) => update.update.oneofKind)).toEqual([
      "updateMessageId",
    ])
  })
})

describe("a real core against the server model", () => {
  let harness: CoreHarness | undefined
  afterEach(async () => {
    await harness?.dispose()
    harness = undefined
  })

  it("receives a live message, then catches up a gap after a reconnect", async () => {
    harness = CoreHarness.create()
    const { model } = harness
    model.addUser(2n, "Ada")
    model.addChat({ id: 10n, participants: [2n] })
    model.postMessage({ chatId: 10n, fromId: 2n, text: "before boot" })

    await harness.boot()
    await harness.seedReplicaFromModel()
    await harness.runUntil(() => harness!.connected())

    model.postMessage({ chatId: 10n, fromId: 2n, text: "live" })
    await harness.settle()

    // Lose the connection; two messages are posted while the client is away.
    await harness.process.transport.disconnect("test")
    model.postMessage({ chatId: 10n, fromId: 2n, text: "missed 1" })
    model.postMessage({ chatId: 10n, fromId: 2n, text: "missed 2" })
    await harness.heal()

    const replica = await harness.snapshot()
    const texts = replica.messages
      .filter((message) => message.chatId === "10")
      .sort((left, right) => Number(left.messageId) - Number(right.messageId))
      .map((message) => message.message)
    expect(texts).toEqual(["before boot", "live", "missed 1", "missed 2"])
    expect(replica.dialogs[0]?.unreadCount).toBe(model.unreadCount(10n))
    expect(model.chatState(10n).lastMsgId).toBe(4n)
    expect(replica.chats[0]?.lastMsgId).toBe(messageId(4))
  })
})

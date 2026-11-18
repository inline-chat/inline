import { Method, Update } from "@inline-chat/protocol/core"
import { chatId, messageId, userId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { AuthStore } from "../auth"
import { Db } from "../database"
import { DbObjectKind, messageKey, type Message } from "../database/models"
import { DbQueryPlanType } from "../database/types"
import { Log } from "@inline/log"
import { RealtimeClient } from "../realtime/realtime"
import { sendMessage } from "../realtime/transactions/send-message"
import { ScriptedTransport } from "./scripted-transport"
import { chatInputPeer, chatPeer } from "./server-model"
import { useFakeTime, type FakeTime } from "./virtual-clock"

/**
 * Driving the real client by hand, one frame at a time. Use this level when
 * a test needs exact control of what the server says and when; use the
 * server model (`server-model.test.ts`) when it only needs a correct server.
 */

const quiet = new Log("Test", { sink: false })

const incoming = (seq: number, id: bigint, text: string) =>
  Update.create({
    seq,
    date: 1_767_225_600n + BigInt(seq),
    update: {
      oneofKind: "newMessage",
      newMessage: {
        message: { id, fromId: 2n, chatId: 10n, peerId: chatPeer(10n), message: text, out: false, date: 1_767_225_600n },
      },
    },
  })

describe("scripted transport", () => {
  let time: FakeTime | undefined
  afterEach(() => {
    time?.dispose()
    time = undefined
  })

  it("opens a session, answers sync and a send, and survives duplicates and reordering", async () => {
    time = useFakeTime()
    const transport = new ScriptedTransport() // manual: the test accepts
    const db = new Db({ autoHydrate: false })
    const client = new RealtimeClient({
      auth: new AuthStore(),
      db,
      transport,
      logger: quiet,
      connection: { backoffDelayMs: () => 1_000 },
    })
    db.insert({ kind: DbObjectKind.Chat, id: chatId(10), title: "Ten" })
    db.insert({
      kind: DbObjectKind.SyncBucketState,
      id: "chat:chat:10",
      seq: 0,
      date: 0,
    })

    void client.startSession({ token: "token", userId: userId(1) })
    await time.settle()
    expect(transport.state).toBe("connecting")

    // Accept the socket, wait for connectionInit, send connectionOpen.
    await transport.open()
    expect(transport.sent[0]?.body.oneofKind).toBe("connectionInit")
    await time.settle()

    // Sync starts: the user bucket and discovery. Answer both as caught up.
    await transport.answerGetUpdates(transport.requireRpc(Method.GET_UPDATES), { seq: 0n })
    await transport.answerGetUpdatesState(transport.requireRpc(Method.GET_UPDATES_STATE), {
      date: 1_767_225_600n,
    })
    await time.settle()

    // A send: inspect the decoded request, acknowledge it, answer it twice.
    const sent = client.execute(
      sendMessage({ chatId: chatId(10), peerId: chatInputPeer(10n), text: "hi" }),
    )
    await time.settle()
    const call = transport.requireRpc(Method.SEND_MESSAGE)
    expect(call.input.oneofKind === "sendMessage" && call.input.sendMessage.message).toBe("hi")
    await transport.ack(call)
    await transport.answerSendMessage(call, { messageId: 7n, seq: 1, fromId: 1n })
    await transport.answerSendMessage(call, { messageId: 7n, seq: 1, fromId: 1n })
    await sent
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(chatId(10), messageId(7))))?.message).toBe("hi")

    // Two pushes, held and released in reverse order, the first duplicated.
    transport.hold()
    await transport.pushUpdates([incoming(1, 8n, "one")])
    await transport.pushUpdates([incoming(2, 9n, "two")])
    expect(transport.held()).toHaveLength(2)
    await transport.release([1, 0, 0])
    await time.settle()

    // Sequence 2 arrived first: a gap. The bucket is fenced and fetched from
    // its cursor; nothing in it is applied until the page arrives.
    const page = transport.requireRpc(Method.GET_UPDATES)
    expect(page.input.oneofKind === "getUpdates" && page.input.getUpdates.startSeq).toBe(0n)
    await transport.answerGetUpdates(page, {
      updates: [incoming(1, 8n, "one"), incoming(2, 9n, "two")],
      seq: 2n,
    })
    await time.settle()

    const rows = db
      .queryCollection<DbObjectKind.Message, Message, DbQueryPlanType.Objects>(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
      )
      .map((row) => row.messageId)
      .sort()
    expect(rows).toEqual(["7", "8", "9"])
    await client.stop()
  })

  it("refuses connections and reports them to the client's backoff", async () => {
    time = useFakeTime()
    const transport = new ScriptedTransport({ connectPolicy: "refuse" })
    const client = new RealtimeClient({
      auth: new AuthStore(),
      db: new Db({ autoHydrate: false }),
      transport,
      sync: false,
      logger: quiet,
      connection: { backoffDelayMs: () => 2_000 },
    })
    void client.startSession({ token: "token", userId: userId(1) })
    await time.settle()
    await time.advance(5_000)
    expect(transport.connectionAttempts).toBe(3)

    transport.connectPolicy = "manual"
    await time.advance(2_000)
    await transport.open()
    await time.runUntil(() => client.connectionState === "connected")
    expect(transport.connectionAttempts).toBe(4)
    await client.stop()
  })
})

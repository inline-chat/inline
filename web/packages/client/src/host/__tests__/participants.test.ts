import { Method } from "@inline-chat/protocol/core"
import { rowKey, memberRowId, type MemberRow } from "@inline/core-protocol"
import { chatId as makeChatId, userId as makeUserId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import type { OutgoingFrame } from "../../testing/server-model"
import { ModelHost, self } from "./model-host"

/**
 * `addChatParticipants` and `removeChatParticipant` against the real host:
 * durable (the member rows change in the accepting commit), idempotent by
 * transaction ID, retried after a lost acknowledgement, and sent by the next
 * core after a crash between the commit and the server's answer.
 */

const chat = makeChatId(10)
const ada = makeUserId(2)
const bea = makeUserId(3)
const cy = makeUserId(4)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const boot = async (options: { online?: boolean } = {}) => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addUser(3n, "Bea")
  mh.model.addUser(4n, "Cy")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  await mh.seedDisk()
  await mh.start(options)
  mh.ui.subscribeTo(2, { kind: "chatParticipants", chatId: chat })
  // People Bea and Cy are on the device (a DM, a space): their user rows exist.
  mh.ui.subscribeTo(3, { kind: "user", userId: bea })
  mh.ui.subscribeTo(4, { kind: "user", userId: cy })
  if (options.online !== false) {
    await mh.until(() => participants(mh).includes(ada), "roster fetched")
  }
  return mh
}

const participants = (mh: ModelHost) =>
  mh.ui
    .rows(2)
    .filter((row): row is MemberRow => row.kind === "member")
    .map((row) => row.userId)
    .sort()

/** No sends run in these tests: every outbox row is a host record. */
const hostRecords = (mh: ModelHost) => mh.disk.count("pending_transaction")

const rpcCount = (mh: ModelHost, method: Method) => mh.model.rpcLog.filter((entry) => entry.method === method).length

const isResult = (kind: string) => (frame: OutgoingFrame) =>
  frame.kind === "result" &&
  frame.message.body.oneofKind === "rpcResult" &&
  frame.message.body.rpcResult.result.oneofKind === kind

describe("addChatParticipants", () => {
  it("shows the new members in the accepting commit, then confirms once the server added them", async () => {
    const mh = await boot()
    mh.transport.hold()
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea, cy] })
    await mh.until(() => mh.ui.result("add")?.status === "accepted", "accepted")
    // Durable before anything is sent: the rows and one record per person.
    expect(participants(mh)).toEqual([self, ada, bea, cy].sort())
    expect(mh.ui.list(2)).toContain(rowKey("member", memberRowId({ chatId: chat }, bea)))
    expect(await hostRecords(mh)).toBe(2)
    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("add")).status).toBe("confirmed")
    expect(mh.model.chats.get(10n)!.participants).toEqual([1n, 2n, 3n, 4n])
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
    expect(participants(mh)).toEqual([self, ada, bea, cy].sort())
  })

  it("is idempotent by transaction ID: a re-posted tx is answered, not applied again", async () => {
    const mh = await boot()
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea] })
    expect((await mh.final("add")).status).toBe("confirmed")
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea] })
    await mh.synced()
    expect(mh.results("add")).toEqual(["accepted", "confirmed", "confirmed"])
    expect(rpcCount(mh, Method.ADD_CHAT_PARTICIPANT)).toBe(1)
  })

  it("acknowledgement lost: retried after reconnect, confirmed, added once", async () => {
    const mh = await boot()
    let armed = true
    mh.endpoint.interceptor = (frame) => {
      if (armed && isResult("addChatParticipant")(frame)) {
        armed = false
        return "drop-and-disconnect"
      }
      return "deliver"
    }
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea] })
    expect((await mh.final("add")).status).toBe("confirmed")
    expect(rpcCount(mh, Method.ADD_CHAT_PARTICIPANT)).toBe(2)
    expect(mh.model.chats.get(10n)!.participants).toEqual([1n, 2n, 3n])
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
  })

  it("crash after the commit, before the answer: the next core sends it, added once", async () => {
    const mh = await boot()
    let armed = true
    // The server applies the add; its answer dies with the process.
    mh.endpoint.interceptor = (frame) => {
      if (armed && isResult("addChatParticipant")(frame)) {
        armed = false
        return "drop"
      }
      return "deliver"
    }
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea] })
    await mh.until(() => !armed, "applied on the server, answer lost")
    expect(mh.model.chats.get(10n)!.participants).toEqual([1n, 2n, 3n])
    await mh.stop()
    expect(await hostRecords(mh)).toBe(1)
    await mh.start()
    mh.ui.subscribeTo(2, { kind: "chatParticipants", chatId: chat })
    await mh.until(() => rpcCount(mh, Method.ADD_CHAT_PARTICIPANT) === 2, "resent by the next core")
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
    expect(mh.model.chats.get(10n)!.participants).toEqual([1n, 2n, 3n])
    expect(participants(mh)).toEqual([self, ada, bea].sort())
  })

  it("offline: accepted and shown, sent after a restart", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [cy] })
    await mh.until(() => mh.ui.result("add")?.status === "accepted", "accepted")
    expect(participants(mh)).toContain(cy)
    await mh.stop()
    await mh.start()
    mh.ui.subscribeTo(2, { kind: "chatParticipants", chatId: chat })
    await mh.until(() => mh.model.chats.get(10n)!.participants.includes(4n), "sent by the next core")
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
  })

  it("a tx re-posted to the next core follows the committed records instead of adding again", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea] })
    await mh.until(() => mh.ui.result("add")?.status === "accepted", "accepted")
    await mh.stop()
    // A handoff: the next core starts, and the UI's link re-posts the intent.
    await mh.start({ online: false })
    mh.ui.subscribeTo(2, { kind: "chatParticipants", chatId: chat })
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea] })
    await mh.until(() => mh.ui.result("add")?.status === "accepted", "accepted again")
    expect(await hostRecords(mh)).toBe(1)
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    expect((await mh.final("add")).status).toBe("confirmed")
    expect(rpcCount(mh, Method.ADD_CHAT_PARTICIPANT)).toBe(1)
    expect(mh.model.chats.get(10n)!.participants).toEqual([1n, 2n, 3n])
  })

  it("refuses malformed input before committing anything", async () => {
    const mh = await boot()
    mh.intent("none", { kind: "addChatParticipants", chatId: chat, userIds: [] })
    mh.intent("bad", { kind: "addChatParticipants", chatId: chat, userIds: ["x" as never] })
    mh.intent("both", { kind: "removeChatParticipant", chatId: chat, userId: bea, groupId: "5" })
    for (const tx of ["none", "bad", "both"]) {
      expect(await mh.final(tx)).toMatchObject({ status: "rejected", reason: "invalid" })
    }
    expect(await hostRecords(mh)).toBe(0)
  })
})

describe("removeChatParticipant", () => {
  it("removes the row in the accepting commit and confirms", async () => {
    const mh = await boot()
    mh.transport.hold()
    mh.intent("remove", { kind: "removeChatParticipant", chatId: chat, userId: ada })
    await mh.until(() => mh.ui.result("remove")?.status === "accepted", "accepted")
    expect(participants(mh)).not.toContain(ada)
    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("remove")).status).toBe("confirmed")
    expect(mh.model.chats.get(10n)!.participants).toEqual([1n])
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
  })

  it("a refusal does not guess: the roster is fetched again and shows the server's list", async () => {
    const mh = await boot()
    const fetches = rpcCount(mh, Method.GET_CHAT_PARTICIPANTS)
    // Bea is not a participant on the server; the device thinks she is.
    mh.intent("add", { kind: "addChatParticipants", chatId: chat, userIds: [bea] })
    expect((await mh.final("add")).status).toBe("confirmed")
    mh.model.chats.get(10n)!.participants = [1n, 2n]
    mh.intent("remove", { kind: "removeChatParticipant", chatId: chat, userId: bea })
    expect(await mh.final("remove")).toMatchObject({ status: "rejected", reason: "server" })
    await mh.until(() => rpcCount(mh, Method.GET_CHAT_PARTICIPANTS) > fetches, "refetched")
    await mh.until(() => participants(mh).join() === [self, ada].join(), "server's list")
    await mh.synced()
    expect(await hostRecords(mh)).toBe(0)
  })
})

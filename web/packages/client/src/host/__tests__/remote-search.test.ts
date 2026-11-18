import { Method } from "@inline-chat/protocol/core"
import type { Patch, RemoteSearchResource } from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { ModelHost } from "./model-host"

/**
 * Server search against the real host: `searchServerMessages` (hits with
 * ranges, paging, the exact count) and `searchUsers`, as request and answer;
 * offline and malformed requests fail at once; a replaced request never
 * delivers; nothing is written to the replica.
 */

const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada Lovelace")
  mh.model.addUser(3n, "Adam")
  mh.model.addUser(4n, "Bea")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "Deploy the app" })
  mh.model.postMessage({ chatId: 10n, fromId: 1n, text: "lunch?" })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "deploy notes are up" })
  await mh.seedDisk()
  await mh.start()
  return mh
}

const answer = (mh: ModelHost, sub: number) => {
  const value = mh.ui.state.resources.get(sub)
  return value?.kind === "remoteSearch" ? (value as RemoteSearchResource) : undefined
}
const done = (mh: ModelHost, sub: number) => answer(mh, sub)?.status === "done" || answer(mh, sub)?.status === "failed"
const result = (mh: ModelHost, sub: number) => {
  const value = answer(mh, sub)
  return value?.status === "done" ? value.result : undefined
}

describe("searchServerMessages", () => {
  it("answers hits newest first with ranges on their text, then pages by offset", async () => {
    const mh = await boot()
    const rowsBefore = await mh.disk.count("message")
    mh.ui.subscribeTo(5, { kind: "searchServerMessages", request: { chatId: chat, query: "deploy", limit: 1 } })
    await mh.until(() => done(mh, 5), "answer")
    expect(result(mh, 5)).toEqual({
      kind: "messages",
      chatId: chat,
      hits: [{ messageId: "3", fromId: "2", date: expect.any(Number), out: false, text: "deploy notes are up", ranges: [[0, 6]] }],
      nextOffsetId: "3",
    })
    mh.ui.subscribeTo(5, {
      kind: "searchServerMessages",
      request: { chatId: chat, query: "deploy", limit: 1, offsetId: "3" as never },
    })
    await mh.until(() => (result(mh, 5) as { hits?: { messageId: string }[] })?.hits?.[0]?.messageId === "1", "page 2")
    mh.ui.subscribeTo(5, { kind: "searchServerMessages", request: { chatId: chat, query: "deploy", countOnly: true } })
    await mh.until(() => result(mh, 5)?.kind === "count", "count")
    expect(result(mh, 5)).toEqual({ kind: "count", chatId: chat, count: 2 })
    await mh.synced()
    expect(await mh.disk.count("message")).toBe(rowsBefore)
  })

  it("a replaced request never delivers its answer", async () => {
    const mh = await boot()
    mh.transport.hold()
    mh.ui.subscribeTo(5, { kind: "searchServerMessages", request: { chatId: chat, query: "lunch" } })
    mh.ui.subscribeTo(5, { kind: "searchServerMessages", request: { chatId: chat, query: "deploy" } })
    const seen = mh.ui.patches.length
    await mh.settleUntil(mh.transport.release())
    await mh.until(() => done(mh, 5), "answer")
    const delivered = mh.ui.patches
      .slice(seen)
      .flatMap((patch: Patch) => patch.resources)
      .filter((change) => change.sub === 5 && change.value.kind === "remoteSearch" && change.value.status === "done")
    expect(delivered).toHaveLength(1)
    expect((result(mh, 5) as { hits: { text: string }[] }).hits.map((hit) => hit.text)).toEqual([
      "deploy notes are up",
      "Deploy the app",
    ])
  })

  it("fails at once offline or malformed, without a request", async () => {
    const mh = await boot()
    const calls = () => mh.model.rpcLog.filter((entry) => entry.method === Method.SEARCH_MESSAGES).length
    mh.ui.subscribeTo(5, { kind: "searchServerMessages", request: { chatId: chat, query: "a" } })
    mh.ui.subscribeTo(6, { kind: "searchServerMessages", request: { chatId: "x" as never, query: "deploy" } })
    await mh.until(() => done(mh, 5) && done(mh, 6), "answers")
    expect(answer(mh, 5)).toEqual({ kind: "remoteSearch", status: "failed", reason: "invalid" })
    expect(answer(mh, 6)).toEqual({ kind: "remoteSearch", status: "failed", reason: "invalid" })
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.ui.subscribeTo(7, { kind: "searchServerMessages", request: { chatId: chat, query: "deploy" } })
    await mh.until(() => done(mh, 7), "answer")
    expect(answer(mh, 7)).toEqual({ kind: "remoteSearch", status: "failed", reason: "offline" })
    expect(calls()).toBe(0)
  })
})

describe("searchUsers", () => {
  it("answers people as user row values, not stored, without the account", async () => {
    const mh = await boot()
    const usersBefore = await mh.disk.count("user")
    mh.ui.subscribeTo(5, { kind: "searchUsers", request: { query: "@ada" } })
    await mh.until(() => done(mh, 5), "answer")
    expect(result(mh, 5)).toEqual({
      kind: "users",
      users: [
        { kind: "user", id: "2", firstName: "Ada Lovelace" },
        { kind: "user", id: "3", firstName: "Adam" },
      ],
    })
    expect(mh.ui.list(5)).toEqual([])
    await mh.synced()
    expect(await mh.disk.count("user")).toBe(usersBefore)
  })
})

import {
  NEW_MESSAGES_RULE,
  rowKey,
  type MessageRow,
} from "@inline/core-protocol"
import { chatId as makeChatId, dialogId, userId as makeUserId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { ModelHost } from "./model-host"

/**
 * The `newMessages` feed: incoming messages that arrived live after the
 * subscription started (NEW_MESSAGES_RULE). A live push and a fresh catch-up
 * page count; history paging, an old catch-up and our own messages do not.
 */

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const design = makeChatId(10)
const FEED = 5

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.addChat({ id: 20n, title: "Random", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "before" })
  mh.model.postMessage({ chatId: 20n, fromId: 2n, text: "before too" })
  mh.model.setReadMaxId(10n, 1n)
  mh.model.setReadMaxId(20n, 1n)
  await mh.seedDisk()
  await mh.start()
  mh.ui.subscribeTo(FEED, { kind: "newMessages" })
  await mh.until(() => mh.ui.state.lists.has(FEED), "feed subscribed")
  await mh.synced()
  return mh
}

const feed = (mh: ModelHost) => (mh.ui.rows(FEED) as MessageRow[]).map((row) => row.text)

describe("newMessages", () => {
  it("lists a live incoming message with the rows a notification needs", async () => {
    const mh = await boot()
    expect(feed(mh)).toEqual([])
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "ping" })
    await mh.until(() => feed(mh).length === 1, "live arrival")
    const [message] = mh.ui.rows(FEED) as MessageRow[]
    expect(message).toMatchObject({ text: "ping", chatId: design, messageId: "2", out: false })
    expect(mh.ui.state.rows.get(rowKey("chat", design))).toMatchObject({ title: "Design" })
    expect(mh.ui.state.rows.get(rowKey("dialog", dialogId(10)))).toMatchObject({ chatId: design })
    expect(mh.ui.state.rows.get(rowKey("user", makeUserId(2)))).toMatchObject({ firstName: "Ada" })

    // Append-only: the next one is added after it.
    mh.model.postMessage({ chatId: 20n, fromId: 2n, text: "pong" })
    await mh.until(() => feed(mh).length === 2, "second arrival")
    expect(feed(mh)).toEqual(["ping", "pong"])
  })

  it("leaves out the account's own messages and edits", async () => {
    const mh = await boot()
    mh.model.postMessage({ chatId: 10n, fromId: mh.model.selfUserId, text: "from my phone" })
    mh.model.editMessage(10n, 1n, "before, edited")
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "marker" })
    await mh.until(() => feed(mh).length === 1, "marker")
    await mh.synced()
    expect(feed(mh)).toEqual(["marker"])
  })

  it("does not list messages loaded by history paging, however recent", async () => {
    const mh = await boot()
    // On the server but never pushed: only a history page brings them.
    const date = BigInt(mh.time.nowSeconds())
    for (const id of [5n, 6n, 7n]) {
      mh.model.importMessage({ id, chatId: 20n, fromId: 2n, text: `paged ${id}`, date, reactions: [] })
    }
    mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: makeChatId(20), anchor: "latest" })
    await mh.until(
      () => (mh.ui.rows(2) as MessageRow[]).some((row) => row.text === "paged 7"),
      "history page",
    )
    await mh.synced()
    expect(feed(mh)).toEqual([])
  })

  it("catch-up after a reconnect lists what is still fresh and leaves out older messages", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "while away, long ago" })
    await mh.time.advance((NEW_MESSAGES_RULE.maxAgeSeconds + 60) * 1_000)
    mh.model.postMessage({ chatId: 20n, fromId: 2n, text: "while away, just now" })
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    await mh.until(() => mh.ui.core(1)?.connection === "connected", "online")
    await mh.synced()
    await mh.until(() => feed(mh).length === 1, "fresh catch-up")
    expect(feed(mh)).toEqual(["while away, just now"])
    // The older one did arrive by the same catch-up; it is only too old.
    mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: design, anchor: "latest" })
    await mh.until(
      () => (mh.ui.rows(2) as MessageRow[]).some((row) => row.text === "while away, long ago"),
      "older message in the replica",
    )
  })

  it("lists only what arrived after the subscription started", async () => {
    const mh = await boot()
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "early" })
    await mh.until(() => feed(mh).length === 1, "early")
    mh.ui.subscribeTo(6, { kind: "newMessages" })
    await mh.until(() => mh.ui.state.lists.has(6), "late subscriber")
    expect(mh.ui.list(6)).toEqual([])
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "late" })
    await mh.until(() => mh.ui.list(6).length === 1, "late arrival")
    expect(feed(mh)).toEqual(["early", "late"])
  })

  it("is bounded and releases rows as they age out", async () => {
    const mh = await boot()
    for (let index = 0; index < NEW_MESSAGES_RULE.limit + 5; index++) {
      mh.model.postMessage({ chatId: 10n, fromId: 2n, text: `burst ${index}` })
    }
    await mh.until(() => feed(mh).at(-1) === `burst ${NEW_MESSAGES_RULE.limit + 4}`, "burst")
    expect(feed(mh)).toHaveLength(NEW_MESSAGES_RULE.limit)
    expect(feed(mh)[0]).toBe("burst 5")

    await mh.time.advance(NEW_MESSAGES_RULE.retainSeconds * 1_000 + 1_000)
    await mh.until(() => feed(mh).length === 0, "aged out")
    // Rows no subscription holds are removed from the context.
    expect(mh.ui.state.rows.get(rowKey("message", `${design}:3`))).toBeUndefined()
  })
})

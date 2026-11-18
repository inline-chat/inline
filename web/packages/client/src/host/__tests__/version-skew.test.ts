import { rowKey, type ChatRow, type DialogRow, type Intent, type QueryDescriptor } from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { ModelHost } from "./model-host"

/**
 * Version skew between a UI and a core of different builds (link makes the
 * newest build lead, but a follower can talk to an older leader until it
 * learns that): what this pass added degrades as designed.
 *
 * - A core that does not know an intent kind (an older core given
 *   `addChatParticipants`) answers `rejected` with `unsupported` and changes
 *   nothing; the UI keeps its state and says so.
 * - A core that does not know a query kind (an older core given `chatMedia`)
 *   keeps that subscription empty and answers the others.
 * - A core given a known intent with fields it does not know (an older core
 *   given `sendText.draftRevision`) runs the intent without them: the draft
 *   stays, as before this pass.
 * - An older UI ignores fields it does not know on rows (`ChatRow.dialogId`,
 *   `MessageRow.tx`); `core-protocol`'s reducer test covers that side.
 */

const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "hello" })
  await mh.seedDisk()
  await mh.start()
  mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
  await mh.until(() => mh.ui.list(2).length === 1, "window")
  return mh
}

describe("version skew", () => {
  it("an intent kind the core does not know is refused as unsupported and changes nothing", async () => {
    const mh = await boot()
    const outbox = await mh.disk.count("pending_transaction")
    mh.intent("future", { kind: "inviteToFuture", chatId: chat } as unknown as Intent)
    expect(await mh.final("future")).toEqual({ tx: "future", status: "rejected", reason: "unsupported" })
    expect(await mh.disk.count("pending_transaction")).toBe(outbox)
    // The core keeps working.
    mh.intent("draft", { kind: "saveDraft", chatId: chat, text: "still here", revision: 1 })
    expect((await mh.final("draft")).status).toBe("confirmed")
  })

  it("a query kind the core does not know stays empty; the others answer; ensure on it is ignored", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(5, { kind: "chatGallery", chatId: chat } as unknown as QueryDescriptor)
    mh.ui.subscribeTo(6, { kind: "chat", chatId: chat })
    mh.ui.post({ kind: "ensure", sub: 5, range: "older" })
    await mh.until(() => mh.ui.list(6).length === 1, "chat")
    await mh.synced()
    expect(mh.ui.list(5)).toEqual([])
    expect(mh.ui.state.resources.get(5)).toBeUndefined()
  })

  it("a known intent with fields the core does not read runs without them", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(3, { kind: "draft", chatId: chat })
    mh.intent("draft", { kind: "saveDraft", chatId: chat, text: "kept", revision: 2 })
    await mh.final("draft")
    // Without `draftRevision` (an older UI, or an older core ignoring it) the draft stays.
    mh.intent("send", { kind: "sendText", chatId: chat, clientKey: "4242", text: "hi", futureOption: true } as Intent)
    expect((await mh.final("send")).status).toBe("confirmed")
    expect(mh.ui.rows(3)).toMatchObject([{ kind: "draft", text: "kept" }])
  })
})

describe("chat to dialog", () => {
  it("every chat row names its dialog, and the chat query carries the dialog row", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(6, { kind: "chat", chatId: chat })
    await mh.until(() => mh.ui.list(6).length === 1, "chat")
    const row = mh.ui.rows(6)[0] as ChatRow
    expect(row.dialogId).toBeDefined()
    const dialog = mh.ui.state.rows.get(rowKey("dialog", row.dialogId!)) as DialogRow | undefined
    expect(dialog).toMatchObject({ kind: "dialog", chatId: chat })
    // The sidebar's dialog row is the same row.
    mh.ui.subscribeTo(7, { kind: "sidebar", mode: "all" })
    await mh.until(() => mh.ui.list(7).length === 1, "sidebar")
    expect(mh.ui.list(7)).toEqual([rowKey("dialog", row.dialogId!)])
    // The dialog changes (a new incoming message): the chat subscription follows it.
    mh.ui.post({ kind: "unsubscribe", sub: 7 })
    const unread = (mh.ui.state.rows.get(rowKey("dialog", row.dialogId!)) as DialogRow).unreadCount
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "again" })
    await mh.until(
      () => (mh.ui.state.rows.get(rowKey("dialog", row.dialogId!)) as DialogRow | undefined)?.unreadCount === unread + 1,
      "dialog follows",
    )
  })
})

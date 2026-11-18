import { DialogFollowMode } from "@inline-chat/protocol/core"
import {
  newClientKey,
  rowKey,
  sentMessageRowId,
  type ChatRow,
  type DialogRow,
  type MessageRow,
  type Patch,
  type RowKey,
} from "@inline/core-protocol"
import { chatId as makeChatId, dialogId, spaceId as makeSpaceId, userId as makeUserId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { DbObjectKind, messageDraftKey } from "../../database/models"
import { ModelHost } from "./model-host"

/**
 * The sidebar query carries what a row view shows (the Mac
 * `ChatListItemSnapshot`), and stays diff-minimal: one chat's change sends
 * that chat's rows and no list change unless the order moved.
 */

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const design = makeChatId(10)
const random = makeChatId(20)
const quiet = makeChatId(30)

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  const model = mh.model
  model.addUser(2n, "Ada")
  model.addUser(3n, "Lin")
  model.addSpace(5n, "Studio")
  model.addChat({ id: 30n, title: "Quiet", participants: [2n] })
  model.postMessage({ chatId: 30n, fromId: 2n, text: "old news" })
  await mh.time.advance(60_000)
  model.addChat({ id: 20n, title: "Random", participants: [3n] })
  model.postMessage({ chatId: 20n, fromId: 3n, text: "lunch?" })
  await mh.time.advance(60_000)
  model.addChat({ id: 10n, title: "Design", spaceId: 5n, participants: [2n] })
  model.postMessage({ chatId: 10n, fromId: 2n, text: "first" })
  model.postMessage({ chatId: 10n, fromId: 2n, text: "latest design" })
  await mh.seedDisk(
    [
      { kind: DbObjectKind.Space, id: makeSpaceId(5), name: "Studio", creator: false, date: 1 },
      {
        kind: DbObjectKind.MessageDraft,
        id: messageDraftKey({ peerKind: "chat", peerThreadId: random }),
        peerKind: "chat",
        peerThreadId: random,
        text: "half a thought",
        revision: 3,
        updatedAt: 1,
      },
    ],
    (db) => {
      const dialog = db.get(db.ref(DbObjectKind.Dialog, dialogId(10)))!
      db.replace({
        ...dialog,
        followMode: DialogFollowMode.FOLLOWING,
        notificationMode: "mentions",
        unreadMentionsCount: 2,
        unreadReactionsCount: 0,
      })
    },
  )
  await mh.start()
  mh.ui.subscribeTo(2, { kind: "sidebar", mode: "all" })
  await mh.until(() => mh.ui.list(2).length === 3, "sidebar")
  await mh.synced()
  return mh
}

const row = <T>(mh: ModelHost, key: RowKey) => mh.ui.state.rows.get(key) as T | undefined
const chatRowOf = (mh: ModelHost, id: string) => row<ChatRow>(mh, rowKey("chat", id))
const lastMessage = (mh: ModelHost, id: string) => {
  const last = chatRowOf(mh, id)?.lastMessageRowId
  return last ? row<MessageRow>(mh, rowKey("message", last)) : undefined
}
const order = (mh: ModelHost) => (mh.ui.rows(2) as DialogRow[]).map((dialog) => dialog.chatId)

const patchesSince = (mh: ModelHost, start: number): Patch[] => mh.ui.patches.slice(start)
const upserted = (patches: Patch[]) =>
  patches.flatMap((patch) =>
    patch.rows.flatMap((change) => (change.op === "upsert" ? [`${change.row.kind}:${change.row.id}`] : [])),
  )
const removed = (patches: Patch[]) =>
  patches.flatMap((patch) =>
    patch.rows.flatMap((change) => (change.op === "remove" ? [`${change.kind}:${change.id}`] : [])),
  )

describe("sidebar rows", () => {
  it("carries each row's last message and sender, draft, space and dialog state from the first result", async () => {
    const mh = await boot()
    expect(order(mh)).toEqual([design, random, quiet])
    // The first patch that lists the sidebar already has the previews (read
    // from disk before the core became ready), not a later fill-in.
    const first = mh.ui.patches.find((patch) => patch.lists.some((list) => list.sub === 2))!
    expect(upserted([first])).toEqual(
      expect.arrayContaining([`message:${design}:2`, `message:${random}:1`, `message:${quiet}:1`]),
    )

    expect(lastMessage(mh, design)).toMatchObject({ text: "latest design", fromId: "2" })
    expect(lastMessage(mh, random)).toMatchObject({ text: "lunch?" })
    expect(lastMessage(mh, quiet)).toMatchObject({ text: "old news" })
    expect(row(mh, rowKey("user", makeUserId(3)))).toMatchObject({ firstName: "Lin" })
    expect(row(mh, rowKey("draft", random))).toMatchObject({ text: "half a thought", revision: 3 })
    expect(row(mh, rowKey("space", makeSpaceId(5)))).toMatchObject({ name: "Studio" })
    expect(row(mh, rowKey("dialog", dialogId(10)))).toMatchObject({
      followMode: "following",
      notificationMode: "mentions",
      unreadMentionsCount: 2,
      unreadReactionsCount: 0,
    })
    // Only the last message of each chat, not its history.
    expect(row(mh, rowKey("message", `${design}:1`))).toBeUndefined()
  })

  it("a new last message sends that chat's rows and no list change while the order holds", async () => {
    const mh = await boot()
    const start = mh.ui.patches.length
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "newer design" })
    await mh.until(() => lastMessage(mh, design)?.text === "newer design", "new preview")
    await mh.synced()
    const patches = patchesSince(mh, start)
    expect(patches.flatMap((patch) => patch.lists)).toEqual([])
    expect(new Set(upserted(patches))).toEqual(
      new Set([`message:${design}:3`, `chat:${design}`, `dialog:${dialogId(10)}`]),
    )
    // The previous last message is released.
    expect(removed(patches)).toEqual([`message:${design}:2`])
  })

  it("moves a row with one list change when its new message changes the order", async () => {
    const mh = await boot()
    await mh.time.advance(60_000)
    const start = mh.ui.patches.length
    mh.model.postMessage({ chatId: 30n, fromId: 2n, text: "back again" })
    await mh.until(() => order(mh)[0] === quiet, "reordered")
    await mh.synced()
    const lists = patchesSince(mh, start).flatMap((patch) => patch.lists)
    // One list change (the smallest single change `diffList` finds).
    expect(lists).toHaveLength(1)
    expect(order(mh)).toEqual([quiet, design, random])
    expect(lastMessage(mh, quiet)?.text).toBe("back again")
  })

  it("an edit of a last message sends only that message row", async () => {
    const mh = await boot()
    const start = mh.ui.patches.length
    mh.model.editMessage(20n, 1n, "lunch at 1?")
    await mh.until(() => lastMessage(mh, random)?.text === "lunch at 1?", "edited preview")
    await mh.synced()
    const patches = patchesSince(mh, start)
    expect(upserted(patches)).toEqual([`message:${random}:1`])
    expect(patches.flatMap((patch) => patch.lists)).toEqual([])
  })

  it("names a message sent here by its client key, before and after the server assigns its ID", async () => {
    const mh = await boot()
    const clientKey = newClientKey()
    const sentId = sentMessageRowId(random, clientKey)
    mh.transport.hold()
    mh.intent("s1", { kind: "sendText", chatId: random, clientKey, text: "on my way" })
    await mh.until(() => chatRowOf(mh, random)?.lastMessageRowId === sentId, "local preview")
    expect(lastMessage(mh, random)).toMatchObject({ text: "on my way", state: "sending", out: true })
    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("s1")).status).toBe("confirmed")
    await mh.synced()
    expect(chatRowOf(mh, random)?.lastMessageRowId).toBe(sentId)
    expect(lastMessage(mh, random)).toMatchObject({ state: "sent", messageId: "2" })
  })

  it("updates the draft row when a draft is saved", async () => {
    const mh = await boot()
    mh.intent("d1", { kind: "saveDraft", chatId: quiet, text: "reply later", revision: 1 })
    await mh.final("d1")
    await mh.until(() => row(mh, rowKey("draft", quiet)) != null, "draft row")
    expect(row(mh, rowKey("draft", quiet))).toMatchObject({ text: "reply later" })
  })
})

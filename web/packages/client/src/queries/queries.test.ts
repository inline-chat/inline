import {
  applyPatch,
  createProtocolState,
  rowKey,
  type CoreMessage,
  type CoreResource,
  type Patch,
} from "@inline/core-protocol"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId, spaceId, userId, type ChatID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../database"
import { DbObjectKind, messageKey, MessageSendingStatus, type Dialog, type Message } from "../database/models"
import type { QueryAccount, QueryEnv } from "./compute"
import { QueryContext } from "./context"
import { diffList, plainEqual } from "./diff"
import { entitiesFromProtocol, entitiesToProtocol, messageRow } from "./rows"
import { sortSidebar, type SidebarEntry } from "./sidebar"
import { isValidQuery } from "./validate"
import { CommittedView } from "./view"

const dialog = (id: number, extra: Partial<Dialog> = {}): Dialog => ({
  kind: DbObjectKind.Dialog,
  id: dialogId(id),
  chatId: chatId(Math.abs(id)),
  ...extra,
})

const entry = (id: number, extra: Partial<Dialog> = {}, activity = 0): SidebarEntry => ({
  dialog: dialog(id, extra),
  chat: undefined,
  activity,
})

const order = (entries: SidebarEntry[]) => entries.map((item) => Number(item.dialog.id))

describe("sidebar order (Mac rules)", () => {
  it("puts pinned first by pinnedOrder, then inbox by order, ties by dialog ID descending", () => {
    const entries = [
      entry(1, { open: true, order: "b" }),
      entry(2, { open: true, order: "a" }),
      entry(3, { open: true }),
      entry(4, { open: true }),
      entry(5, { pinned: true, pinnedOrder: "z" }),
      entry(6, { pinned: true, pinnedOrder: "m" }),
      entry(7, { pinned: true }),
      entry(8, { open: false }),
    ]
    expect(order(sortSidebar(entries, "inbox", undefined))).toEqual([6, 5, 7, 2, 1, 4, 3])
  })

  it("orders all and archived by activity, and filters by mode, space and hidden", () => {
    const entries = [
      entry(1, { open: true }, 10),
      entry(2, {}, 30),
      entry(3, { archived: true }, 50),
      entry(4, { chatListHidden: true }, 99),
      entry(5, {}, 30),
      entry(6, { pinned: true }, 1),
      entry(7, { spaceId: spaceId(9) }, 40),
    ]
    expect(order(sortSidebar(entries, "all", undefined))).toEqual([6, 7, 5, 2, 1])
    expect(order(sortSidebar(entries, "archived", undefined))).toEqual([3])
    expect(order(sortSidebar(entries, "all", spaceId(9)))).toEqual([7])
  })
})

describe("list diff", () => {
  it("emits one splice over the changed span, or nothing", () => {
    const keys = ["a", "b", "c", "d"].map((id) => rowKey("dialog", id))
    expect(diffList(1, keys, keys)).toBeNull()
    expect(diffList(1, undefined, keys)).toEqual({ sub: 1, op: "replace", keys })
    const moved = [keys[2]!, keys[0]!, keys[1]!, keys[3]!]
    expect(diffList(1, keys, moved)).toEqual({
      sub: 1,
      op: "splice",
      index: 0,
      remove: 3,
      insert: [keys[2], keys[0], keys[1]],
    })
    const reversed = keys.slice().reverse()
    expect(diffList(1, keys, reversed)).toEqual({ sub: 1, op: "replace", keys: reversed })
    const appended = [...keys, rowKey("dialog", "e")]
    expect(diffList(1, keys, appended)).toEqual({
      sub: 1,
      op: "splice",
      index: 4,
      remove: 0,
      insert: [rowKey("dialog", "e")],
    })
    const removed = [keys[0]!, keys[3]!]
    const change = diffList(1, keys, removed)
    expect(change).toEqual({ sub: 1, op: "splice", index: 1, remove: 2, insert: [] })
  })

  it("compares plain data structurally", () => {
    expect(plainEqual({ a: [1, { b: 2 }] }, { a: [1, { b: 2 }] })).toBe(true)
    expect(plainEqual({ a: 1 }, { a: 1, b: undefined })).toBe(false)
    expect(plainEqual([1], { 0: 1 })).toBe(false)
  })
})

describe("rows", () => {
  it("maps entities both ways", () => {
    const protocol = {
      entities: [
        {
          type: MessageEntity_Type.MENTION,
          offset: 0n,
          length: 3n,
          entity: { oneofKind: "mention" as const, mention: { userId: 8n } },
        },
        {
          type: MessageEntity_Type.TEXT_URL,
          offset: 4n,
          length: 2n,
          entity: { oneofKind: "textUrl" as const, textUrl: { url: "https://inline.chat" } },
        },
      ],
    }
    const rows = entitiesFromProtocol(protocol)
    expect(rows).toEqual([
      { type: "mention", offset: 0, length: 3, userId: "8" },
      { type: "textUrl", offset: 4, length: 2, url: "https://inline.chat" },
    ])
    expect(entitiesToProtocol(rows)).toEqual(protocol)
  })

  it("carries the detail of group, thread-title, bot, agent and math entities", () => {
    const rows = [
      { type: "mention" as const, offset: 0, length: 1, userId: userId(8), agentId: "3" },
      { type: "groupMention" as const, offset: 1, length: 1, groupId: "4" },
      { type: "threadTitle" as const, offset: 2, length: 1, spaceId: spaceId(5), title: "Plan" },
      { type: "botCommand" as const, offset: 3, length: 1, botUserId: userId(6) },
      { type: "math" as const, offset: 4, length: 1, display: true },
    ]
    expect(entitiesFromProtocol(entitiesToProtocol(rows))).toEqual(rows)
  })

  it("keys a local send by its client key and hides its temporary ID", () => {
    const message: Message = {
      kind: DbObjectKind.Message,
      id: messageKey(chatId(5), messageId(-12)),
      messageId: messageId(-12),
      randomId: 99n,
      chatId: chatId(5),
      fromId: userId(7),
      message: "hi",
      out: true,
      date: 3,
      status: MessageSendingStatus.Sending,
    }
    expect(messageRow(message, "99", userId(7))).toEqual({
      kind: "message",
      id: "5:r99",
      chatId: "5",
      clientKey: "99",
      fromId: "7",
      out: true,
      date: 3,
      text: "hi",
      state: "sending",
    })
  })
})

describe("query validation", () => {
  it("accepts well-formed descriptors and refuses the rest", () => {
    expect(isValidQuery({ kind: "chatWindow", chatId: "5", anchor: { around: "3" } })).toBe(true)
    expect(isValidQuery({ kind: "chatWindow", chatId: "05", anchor: "latest" })).toBe(false)
    expect(isValidQuery({ kind: "sidebar", mode: "everything" })).toBe(false)
    expect(isValidQuery({ kind: "user", userId: 5 })).toBe(false)
    expect(isValidQuery(null)).toBe(false)
  })
})

describe("QueryContext", () => {
  const core: CoreResource = {
    kind: "core",
    phase: "ready",
    connection: "connected",
    storage: "memory",
    buildId: "b",
  }

  const setup = () => {
    const db = new Db({ autoHydrate: false })
    const view = new CommittedView()
    const collected: Parameters<QueryContext["publish"]>[1][number][] = []
    db.subscribeToResidentChanges((batch) => {
      view.apply(batch)
      collected.push(...batch.changes)
    })
    const account: QueryAccount = {
      view,
      userId: userId(7),
      windowKeys: () => [],
      windowAtLatest: () => true,
      clientKeyFor: (message) => message.randomId?.toString(),
      windowState: () => ({ loading: "none", hasOlder: false }),
      draftFor: () => ({ key: "chat:1", draft: undefined }),
    }
    const env: QueryEnv = { core, account }
    const messages: CoreMessage[] = []
    const context = new QueryContext((message) => messages.push(message))
    /** Changes committed since the last call. */
    const changes = () => collected.splice(0)
    return { db, env, messages, context, changes }
  }

  const addDialog = (db: Db, id: ChatID, title: string, date: number) => {
    db.insert({ kind: DbObjectKind.Chat, id, title, date })
    db.insert({ kind: DbObjectKind.Dialog, id: dialogId(id), chatId: id, open: true })
  }

  it("opens with a snapshot, then patches only what changed with contiguous revisions", () => {
    const { db, env, messages, context, changes } = setup()
    addDialog(db, chatId(1), "One", 10)
    addDialog(db, chatId(2), "Two", 20)
    context.subscribe(1, { kind: "sidebar", mode: "all" }, {}, true)
    context.subscribe(2, { kind: "user", userId: userId(9) }, {}, true)
    context.publish(env, [], false)
    expect(messages).toHaveLength(1)
    expect(messages[0]?.kind).toBe("snapshot")

    changes()
    db.update({ kind: DbObjectKind.Chat, id: chatId(1), title: "One!", date: 30 })
    context.publish(env, changes(), false)
    const patch = (messages[1] as { patch: Patch }).patch
    expect(patch.base).toBe(1)
    expect(patch.revision).toBe(2)
    // The chat row changed and the order flipped; the dialogs did not change.
    expect(patch.rows).toEqual([
      { op: "upsert", row: { kind: "chat", id: "1", title: "One!", lastActivityDate: 30, dialogId: "1" } },
    ])
    expect(patch.lists).toEqual([
      { sub: 1, op: "replace", keys: [rowKey("dialog", "1"), rowKey("dialog", "2")] },
    ])

    // A change no subscription depends on emits nothing.
    db.insert({ kind: DbObjectKind.User, id: userId(3), firstName: "X" })
    context.publish(env, changes(), false)
    expect(messages).toHaveLength(2)

    // Unsubscribing releases rows no other subscription holds.
    context.unsubscribe(1)
    context.publish(env, [], false)
    const release = (messages[2] as { patch: Patch }).patch
    expect(release.base).toBe(2)
    expect(release.rows.map((change) => change.op)).toEqual(["remove", "remove", "remove", "remove"])
  })

  it("leaves a subscription out until it is ready, and settles intents in the next patch", () => {
    const { db, env, messages, context } = setup()
    addDialog(db, chatId(1), "One", 10)
    context.publish(env, [], false) // opening snapshot
    context.subscribe(1, { kind: "chat", chatId: chatId(1) }, {}, false)
    context.settle({ tx: "t", status: "accepted" })
    context.publish(env, [], false)
    const first = (messages[1] as { patch: Patch }).patch
    expect(first.rows).toEqual([])
    expect(first.settled).toEqual([{ tx: "t", status: "accepted" }])

    context.setReady(1, true)
    context.publish(env, [], false)
    const state = createProtocolState()
    state.revision = 1
    expect(applyPatch(state, first)).toBe("applied")
    expect(applyPatch(state, (messages[2] as { patch: Patch }).patch)).toBe("applied")
    expect(state.lists.get(1)).toEqual([rowKey("chat", "1")])
  })
})

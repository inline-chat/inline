import { chatId, dialogId, messageId, spaceId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { DbObjectKind, MessageSendingStatus, messageKey } from "../../database/models"
import type { InlinePersistenceOperation, InlinePersistenceStore } from "../../database/persistence"
import { Db } from "../../database"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { applyUpdates } from "../../realtime/updates"
import { purgeSpace } from "../../realtime/updates/membership"
import { MessageSearch, type MessageSearchStore } from "../engine"
import {
  clearHistoryUpdate,
  deleteChatUpdate,
  deleteMessagesUpdate,
  disagreements,
  editMessageUpdate,
  message,
  newMessageUpdate,
  openSearchDb,
} from "./fixture"

type Opened = Awaited<ReturnType<typeof openSearchDb>>
let opened: Opened[] = []
const open = async (...args: Parameters<typeof openSearchDb>) => {
  const context = await openSearchDb(...args)
  opened.push(context)
  return context
}

afterEach(async () => {
  for (const context of opened) await context.close()
  opened = []
})

describe("the index follows every message write path (invariants 1 and 6)", () => {
  it("indexes new messages, re-indexes edits and drops deletes from sync updates", async () => {
    const context = await open()
    context.insertChat(10)
    applyUpdates(context.db, [
      newMessageUpdate(10n, 1n, "the release is ready"),
      newMessageUpdate(10n, 2n, "review the migration"),
    ])
    await context.db.flushPersistence()
    expect(await context.texts("release")).toEqual(["the release is ready"])

    applyUpdates(context.db, [editMessageUpdate(10n, 1n, "the launch is ready")])
    await context.db.flushPersistence()
    expect(await context.texts("release")).toEqual([])
    expect(await context.texts("launch")).toEqual(["the launch is ready"])

    applyUpdates(context.db, [deleteMessagesUpdate(10n, [2n])])
    await context.db.flushPersistence()
    expect(await context.texts("migration")).toEqual([])
    expect(await disagreements(context.store)).toEqual([])
  })

  it("removes a chat's entries in bulk on clear history and on an access-loss purge", async () => {
    const context = await open()
    context.insertChat(10)
    context.insertChat(11, { spaceId: spaceId(5) })
    context.insertChat(12)
    context.db.insert({ kind: DbObjectKind.Space, id: spaceId(5), name: "S", creator: false, date: 1 })
    for (let id = 1n; id <= 30n; id++) {
      applyUpdates(context.db, [
        newMessageUpdate(10n, id, `alpha ${id}`),
        newMessageUpdate(11n, id, `alpha space ${id}`),
        newMessageUpdate(12n, id, `alpha deleted ${id}`),
      ])
    }
    await context.db.flushPersistence()
    expect((await context.search.count({ query: "alpha" })).count).toBe(90)

    applyUpdates(context.db, [clearHistoryUpdate(10n)])
    applyUpdates(context.db, [deleteChatUpdate(12n)])
    await context.db.flushPersistence()
    expect((await context.search.count({ query: "alpha" })).count).toBe(30)

    purgeSpace(context.db, spaceId(5))
    await context.db.flushPersistence()
    expect((await context.search.count({ query: "alpha" })).count).toBe(0)
    expect(await disagreements(context.store)).toEqual([])
  })

  it("drops rows a certified history page proves gone, and indexes the page's rows", async () => {
    const context = await open()
    context.insertChat(10)
    for (let id = 1; id <= 20; id++) context.db.insert(message(10, id, `cached ${id}`))
    await context.db.flushPersistence()
    // The server says 1 to 20 now hold only 18, 19 and 20.
    await context.db.commit(() => {
      context.db.insert(message(10, 18, "page eighteen"))
      context.db.insert(message(10, 19, "page nineteen"))
      context.db.insert(message(10, 20, "page twenty"))
      context.db.admitHistoryPage(chatId(10), [[1n, 20n]], [messageId(18), messageId(19), messageId(20)])
    })
    expect(await context.texts("cached")).toEqual([])
    expect(await context.texts("page")).toEqual(["page twenty", "page nineteen", "page eighteen"])
    expect(await disagreements(context.store)).toEqual([])
  })

  it("never indexes an optimistic send: a rejected one leaves no ghost, a confirmed one is found under its server ID", async () => {
    const context = await open()
    context.insertChat(10)
    const temp = message(10, -1_700_000_000_001n, "optimistic hello", {
      status: MessageSendingStatus.Sending,
      randomId: 77n,
      out: true,
    })
    context.db.insert(temp)
    const rejected = message(10, -1_700_000_000_002n, "rejected hello", {
      status: MessageSendingStatus.Sending,
      out: true,
    })
    context.db.insert(rejected)
    await context.db.flushPersistence()
    expect(await context.texts("hello")).toEqual([])

    // Rejected: the row stays as failed, the index never had it.
    context.db.update({ ...rejected, status: MessageSendingStatus.Failed })
    // Confirmed: the server ID replaces the temporary row in one write.
    applyUpdates(context.db, [
      {
        update: { oneofKind: "updateMessageId", updateMessageId: { messageId: 500n, randomId: 77n } },
      } as never,
    ])
    await context.db.flushPersistence()
    const page = await context.search.search({ query: "hello" })
    expect(page.hits.map((hit) => [hit.messageId, hit.text])).toEqual([["500", "optimistic hello"]])

    // A cancelled send is deleted: still nothing.
    context.db.delete(context.db.ref(DbObjectKind.Message, rejected.id))
    await context.db.flushPersistence()
    expect(await disagreements(context.store)).toEqual([])
  })

  it("removes entries whatever deletes the row, such as a future eviction in raw SQL", async () => {
    const context = await open()
    context.insertChat(10)
    for (let id = 1; id <= 10; id++) context.db.insert(message(10, id, `evictable ${id}`))
    await context.db.flushPersistence()
    await context.store.writeSearchIndex((db) => db.exec("DELETE FROM message WHERE message_id <= 5"))
    expect((await context.search.count({ query: "evictable" })).count).toBe(5)
    expect(await disagreements(context.store)).toEqual([])
  })

  it("does not rewrite an entry when a message is written again with the same text", async () => {
    const context = await open()
    context.insertChat(10)
    const row = message(10, 1, "stable text")
    context.db.insert(row)
    await context.db.flushPersistence()
    const before = await context.store.readSearchIndex((db) => db.exec({ sql: "SELECT id FROM message_search_doc", returnValue: "resultRows" }))
    context.db.update({ ...row, mentioned: true })
    await context.db.flushPersistence()
    const after = await context.store.readSearchIndex((db) => db.exec({ sql: "SELECT id FROM message_search_doc", returnValue: "resultRows" }))
    expect(after).toEqual(before)
    // An edit to empty text removes the entry.
    context.db.update({ ...row, message: "" })
    await context.db.flushPersistence()
    expect(await context.texts("stable")).toEqual([])
    expect(await disagreements(context.store)).toEqual([])
  })
})

describe("what is findable", () => {
  const corpus: Array<[number, string]> = [
    [1, "Café naïve résumé"],
    [2, "می‌خواهم فردا بروم"],
    [3, "كتاب يك دانشجو"],
    [4, "مَرْحَبًا بِكُمْ"],
    [5, "東京タワーに行きました"],
    [6, "我们明天发布新版本"],
    [7, "ship it 👍🏽 🚀"],
    [8, "Deploy שלום release مرحبا today"],
    [9, "회의를 시작합니다"],
    [10, "build 2024 ۱۴۰۳"],
  ]

  const scripted = async () => {
    const context = await open()
    context.insertChat(10)
    for (const [id, text] of corpus) context.db.insert(message(10, id, text))
    await context.db.flushPersistence()
    return context
  }

  it.each([
    ["cafe", 1, ["Café"]],
    ["RESUME", 1, ["résumé"]],
    ["میخواهم", 2, ["می‌خواهم"]],
    ["می‌خواهم", 2, ["می‌خواهم"]],
    ["کتاب یک", 3, ["كتاب", "يك"]],
    ["مرحبا بکم", 4, ["مَرْحَبًا", "بِكُمْ"]],
    ["タワー", 5, ["タワー"]],
    ["京タ", 5, ["京タ"]],
    ["行き", 5, ["行き"]],
    ["发布", 6, ["发布"]],
    ["新版", 6, ["新版"]],
    ["it 👍", 7, ["it", "👍🏽"]],
    ["ship 🚀", 7, ["ship", "🚀"]],
    ["\"שלום release\"", 8, ["שלום release"]],
    ["مرحبا today", 8, ["مرحبا", "today"]],
    ["의를", 9, ["의를"]],
    ["1403", 10, ["۱۴۰۳"]],
  ])("finds %j in message %i and highlights the match", async (query, id, expected) => {
    const context = await scripted()
    const page = await context.search.search({ query })
    expect(page.hits.map((hit) => Number(hit.messageId))).toContain(id)
    const hit = page.hits.find((candidate) => Number(candidate.messageId) === id)!
    expect(hit.ranges.map(([start, end]) => hit.text.slice(start, end))).toEqual(expected)
    expect(hit.snippetRanges.map(([start, end]) => hit.snippet.slice(start, end))).toEqual(expected)
  })

  it("does not find a word from its middle in spaced scripts, nor a phrase out of order", async () => {
    const context = await scripted()
    expect(await context.texts("ploy")).toEqual([])
    expect(await context.texts('"release Deploy"')).toEqual([])
  })

  it("never throws on hostile query strings and leaves the index usable", async () => {
    const context = await scripted()
    const hostile = [
      '"', '""', '"unclosed phrase', 'NEAR(ship it)', "ship*", "*", "**ship", "-ship", "ship:it", "body:ship",
      "chat:c10", "^ship", "(ship OR it)", "AND", "OR NOT", "ship AND", "\u0000ship", "\uD800ship\uDC00",
      "x".repeat(100_000), "'; DROP TABLE message; --", "{body chat}: ship", '"ship" "it', "++", "🚀🚀🚀",
      "NEAR", "ship NEAR/2 it", "ship + it", "c10", "\\ship", "ship'", "`ship`", "ship‌it",
    ]
    for (const query of hostile) {
      await expect(context.search.search({ query }), query).resolves.toBeDefined()
      await expect(context.search.findInChat({ chatId: chatId(10), query }), query).resolves.toBeDefined()
      await expect(context.search.count({ query }), query).resolves.toBeDefined()
      await expect(context.search.search({ query, sort: "relevance" }), query).resolves.toBeDefined()
    }
    expect(await context.texts("ship")).toEqual(["ship it 👍🏽 🚀"])
    // The chat column is not searchable as text.
    expect(await context.texts("c10")).toEqual([])
  })
})

describe("queries", () => {
  it("orders newest first by date then message ID (the Mac's Quick Search), across chats", async () => {
    const context = await open()
    context.insertChat(10)
    context.insertChat(11)
    context.db.insert(message(10, 5, "same second", { date: 2_000 }))
    context.db.insert(message(11, 9, "same second", { date: 2_000 }))
    context.db.insert(message(11, 3, "same second later", { date: 2_001 }))
    context.db.insert(message(10, 1, "same second earlier", { date: 1_999 }))
    await context.db.flushPersistence()
    const page = await context.search.search({ query: "same second" })
    expect(page.hits.map((hit) => `${hit.chatId}:${hit.messageId}`)).toEqual(["11:3", "11:9", "10:5", "10:1"])
    expect(page.indexComplete).toBe(true)
  })

  it("gives colliding index positions (same second, same message ID modulo 1024) their own slots", async () => {
    const context = await open()
    for (const chat of [10, 11, 12]) context.insertChat(chat)
    context.db.insert(message(10, 5, "collide", { date: 3_000 }))
    context.db.insert(message(11, 1_029, "collide", { date: 3_000 }))
    context.db.insert(message(12, 2_053, "collide", { date: 3_000 }))
    await context.db.flushPersistence()
    expect((await context.search.search({ query: "collide" })).hits.length).toBe(3)
    // Deleting one frees its slot without touching the others.
    context.db.delete(context.db.ref(DbObjectKind.Message, messageKey(chatId(11), messageId(1_029))))
    await context.db.flushPersistence()
    const left = await context.search.search({ query: "collide" })
    expect(left.hits.map((hit) => `${hit.chatId}:${hit.messageId}`).sort()).toEqual(["10:5", "12:2053"])
    expect(await disagreements(context.store)).toEqual([])
  })

  it("pages with a cursor that stays stable while new messages arrive", async () => {
    const context = await open()
    context.insertChat(10)
    for (let id = 1; id <= 50; id++) context.db.insert(message(10, id, `page item ${id}`))
    await context.db.flushPersistence()
    const seen: string[] = []
    let page = await context.search.search({ query: "item", limit: 10 })
    seen.push(...page.hits.map((hit) => String(hit.messageId)))
    let round = 0
    while (page.nextCursor) {
      // New messages arrive between pages, newer than everything shown.
      context.db.insert(message(10, 1_000 + round, `new item ${round}`))
      await context.db.flushPersistence()
      round += 1
      page = await context.search.search({ query: "item", limit: 10, cursor: page.nextCursor })
      seen.push(...page.hits.map((hit) => String(hit.messageId)))
    }
    expect(seen).toEqual(Array.from({ length: 50 }, (_, index) => String(50 - index)))
  })

  it("filters by space (the dialog's, else the chat's) and leaves out archived dialogs on request", async () => {
    const context = await open()
    context.insertChat(10, { spaceId: spaceId(5) })
    context.insertChat(11, { spaceId: spaceId(6) })
    context.insertChat(12)
    context.db.insert({ kind: DbObjectKind.Dialog, id: dialogId(-12), chatId: chatId(12), spaceId: spaceId(5), archived: true })
    context.db.insert(message(10, 1, "spaced out"))
    context.db.insert(message(11, 1, "spaced elsewhere"))
    context.db.insert(message(12, 1, "spaced archived"))
    await context.db.flushPersistence()
    const inSpace = await context.search.search({ query: "spaced", spaceId: spaceId(5) })
    expect(inSpace.hits.map((hit) => hit.text)).toEqual(["spaced archived", "spaced out"])
    const unarchived = await context.search.search({ query: "spaced", spaceId: spaceId(5), includeArchived: false })
    expect(unarchived.hits.map((hit) => hit.text)).toEqual(["spaced out"])
  })

  it("ranks by bm25 within the newest matches when asked for relevance", async () => {
    const context = await open()
    context.insertChat(10)
    context.db.insert(message(10, 1, "deploy deploy deploy"))
    context.db.insert(message(10, 2, "we should deploy the long and winding service after lunch today"))
    context.db.insert(message(10, 3, "nothing here"))
    await context.db.flushPersistence()
    const page = await context.search.search({ query: "deploy", sort: "relevance", limit: 1 })
    expect(page.hits.map((hit) => Number(hit.messageId))).toEqual([1])
    const next = await context.search.search({ query: "deploy", sort: "relevance", limit: 1, cursor: page.nextCursor! })
    expect(next.hits.map((hit) => Number(hit.messageId))).toEqual([2])
    expect(next.nextCursor).toBeUndefined()
  })

  it("caps the work per query and continues from where it stopped", async () => {
    const context = await open({ maxScannedRows: 7 })
    context.insertChat(10, { spaceId: spaceId(5) })
    context.insertChat(11, { spaceId: spaceId(6) })
    context.db.insert(message(10, 1, "needle old"))
    for (let id = 1; id <= 20; id++) context.db.insert(message(11, id, `needle other ${id}`, { date: 1_800_000_000 + id }))
    await context.db.flushPersistence()
    let page = await context.search.search({ query: "needle", spaceId: spaceId(5) })
    expect(page.truncated).toBe(true)
    expect(page.hits).toEqual([])
    const found: string[] = []
    let guard = 0
    while (page.nextCursor && guard++ < 10) {
      page = await context.search.search({ query: "needle", spaceId: spaceId(5), cursor: page.nextCursor })
      found.push(...page.hits.map((hit) => hit.text))
    }
    expect(found).toEqual(["needle old"])
  })

  it("stops on the time budget too", async () => {
    let clock = 0
    const context = await open({ now: () => (clock += 100), maxQueryMs: 50 })
    context.insertChat(10)
    for (let id = 1; id <= 300; id++) context.db.insert(message(10, id, `timed ${id}`))
    await context.db.flushPersistence()
    const page = await context.search.search({ query: "timed", spaceId: spaceId(99) })
    expect(page.truncated).toBe(true)
    expect(page.nextCursor).toBeDefined()
  })

  it("rejects on abort and never answers an aborted query", async () => {
    const context = await open()
    context.insertChat(10)
    context.db.insert(message(10, 1, "abort me"))
    await context.db.flushPersistence()
    const aborted = new AbortController()
    aborted.abort()
    await expect(context.search.search({ query: "abort" }, aborted.signal)).rejects.toBeDefined()
    const late = new AbortController()
    const pending = context.search.search({ query: "abort" }, late.signal)
    late.abort()
    await expect(pending).rejects.toBeDefined()
  })

  it("rejects cursors it did not produce", async () => {
    const context = await open()
    await expect(context.search.search({ query: "anything", cursor: "bogus" })).rejects.toBeInstanceOf(RangeError)
  })
})

describe("find in chat", () => {
  it("pages one chat newest first, steps older and newer by cursor, and counts", async () => {
    const context = await open()
    context.insertChat(10)
    context.insertChat(11)
    for (let id = 1; id <= 250; id++) context.db.insert(message(10, id, `match ${id}`))
    for (let id = 1; id <= 30; id++) context.db.insert(message(11, id, `match elsewhere ${id}`))
    await context.db.flushPersistence()

    const first = await context.search.findInChat({ chatId: chatId(10), query: "match" })
    expect(first.hits.length).toBe(100)
    expect(Number(first.hits[0]!.messageId)).toBe(250)
    expect(first.hasOlder).toBe(true)
    expect(first.hasNewer).toBe(false)
    const second = await context.search.findInChat({ chatId: chatId(10), query: "match", cursor: first.olderCursor! })
    expect(Number(second.hits[0]!.messageId)).toBe(150)
    const third = await context.search.findInChat({ chatId: chatId(10), query: "match", cursor: second.olderCursor! })
    expect(third.hits.map((hit) => Number(hit.messageId))).toEqual(Array.from({ length: 50 }, (_, index) => 50 - index))
    expect(third.hasOlder).toBe(false)
    expect(third.hasNewer).toBe(true)

    const back = await context.search.findInChat({
      chatId: chatId(10),
      query: "match",
      cursor: third.newerCursor!,
      direction: "newer",
    })
    expect(back.hits.map((hit) => hit.messageId)).toEqual(second.hits.map((hit) => hit.messageId))
    expect(back.hasNewer).toBe(true)
    expect(back.hasOlder).toBe(true)

    // Step from one hit to its neighbours.
    const hit = second.hits[10]!
    const older = await context.search.findInChat({ chatId: chatId(10), query: "match", cursor: hit.cursor, limit: 1 })
    const newer = await context.search.findInChat({ chatId: chatId(10), query: "match", cursor: hit.cursor, limit: 1, direction: "newer" })
    expect(Number(older.hits[0]!.messageId)).toBe(Number(hit.messageId) - 1)
    expect(Number(newer.hits[0]!.messageId)).toBe(Number(hit.messageId) + 1)

    expect(await context.search.count({ query: "match", chatId: chatId(10) })).toEqual({ count: 250, capped: false, indexComplete: true })
    expect((await context.search.count({ query: "match" })).count).toBe(280)
  })
})

/** The real SQLite store, with writes a test can hold before they reach SQLite. */
const heldStore = () => {
  const inner = createSqliteMemoryPersistenceStore()
  let gate: Promise<void> | null = null
  let release = () => {}
  const store: InlinePersistenceStore & MessageSearchStore = {
    open: () => inner.open(),
    close: () => inner.close(),
    collection: (kind) => inner.collection(kind),
    async write(operations: readonly InlinePersistenceOperation[]) {
      if (gate) await gate
      await inner.write(operations)
    },
    readSearchIndex: (read) => inner.readSearchIndex(read),
    writeSearchIndex: (write) => inner.writeSearchIndex(write),
  }
  return {
    store,
    inner,
    hold() {
      gate = new Promise((resolve) => {
        release = () => {
          gate = null
          resolve()
        }
      })
    },
    release: () => release(),
  }
}

describe("invariant 13: a search read never overrides a write accepted before it returns", () => {
  it("drops a hit deleted in memory and re-highlights one edited in memory before the commit", async () => {
    const held = heldStore()
    await held.store.open()
    const db = new Db({ autoHydrate: false, persistenceStore: held.store })
    const search = new MessageSearch({ db, store: held.store, pause: async () => {} })
    db.insert({ kind: DbObjectKind.Chat, id: chatId(10) })
    db.insert(message(10, 1, "keep the plan"))
    db.insert(message(10, 2, "drop the plan"))
    db.insert(message(10, 3, "edit the plan"))
    await db.flushPersistence()

    held.hold()
    db.delete(db.ref(DbObjectKind.Message, messageKey(chatId(10), messageId(2))))
    db.update({ ...message(10, 3, "edited: the new plan") })
    const page = await search.search({ query: "plan" })
    expect(page.hits.map((hit) => hit.text)).toEqual(["edited: the new plan", "keep the plan"])
    const edited = page.hits[0]!
    expect(edited.ranges.map(([start, end]) => edited.text.slice(start, end))).toEqual(["plan"])

    held.release()
    await db.flushPersistence()
    await search.stop()
    await held.store.close()
  })
})

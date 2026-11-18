import type { ChatRow, DialogRow, SpaceRow, UserRow } from "@inline/core-protocol"
import { chatId, dialogId, messageId, spaceId, userId, type ChatID, type SpaceID, type UserID } from "@inline/ids"
import { manualTime, signal } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { createRowLocalSource, isMessageSearchable, messageSnippet, type QuickSearchRows } from "./sources"
import { fakeMessageSource, fakeRemoteSource } from "./testing"

const user = (id: number, firstName?: string, lastName?: string, username?: string): UserRow => ({
  kind: "user",
  id: userId(id),
  ...(firstName ? { firstName } : {}),
  ...(lastName ? { lastName } : {}),
  ...(username ? { username } : {}),
})
const chat = (id: number, fields: Partial<ChatRow> = {}): ChatRow => ({ kind: "chat", id: chatId(id), ...fields })
const dialog = (id: number, fields: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: dialogId(id),
  chatId: chatId(id),
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...fields,
})

const rowsOf = (input: { chats: ChatRow[]; dialogs: DialogRow[]; users: UserRow[]; spaces?: SpaceRow[]; selfId?: UserID }): QuickSearchRows => {
  const chats = new Map<ChatID, ChatRow>(input.chats.map((c) => [c.id, c]))
  const users = new Map<UserID, UserRow>(input.users.map((u) => [u.id, u]))
  const spaces = new Map<SpaceID, SpaceRow>((input.spaces ?? []).map((s) => [s.id, s]))
  return {
    dialogs: input.dialogs,
    chat: (id) => chats.get(id),
    user: (id) => users.get(id),
    space: (id) => spaces.get(id),
    users: input.users,
    spaces: input.spaces ?? [],
    ...(input.selfId ? { selfId: input.selfId } : {}),
  }
}

describe("createRowLocalSource", () => {
  const design: SpaceRow = { kind: "space", id: spaceId(9), name: "Design" }
  const base = {
    chats: [chat(1, { peerUserId: userId(10) }), chat(2, { title: " Launch plan ", spaceId: design.id }), chat(3), chat(4, { title: "Sub", parentChatId: chatId(2) })],
    dialogs: [dialog(1, { peerUserId: userId(10), unreadCount: 2 }), dialog(2, { pinned: true, spaceId: design.id }), dialog(3), dialog(4)],
    users: [user(10, "Ada", "Lovelace", "ada"), user(11, "Grace", "Hopper"), user(12, "Me")],
    spaces: [design],
    selfId: userId(12),
  }

  it("builds chat candidates with Mac titles, keys and subtitles", () => {
    const source = createRowLocalSource(signal(rowsOf(base)))
    const chats = source.chats.peek()
    expect(chats.map((c) => [c.key, c.title, c.subtitle])).toEqual([
      ["user:10", "Ada Lovelace", "@ada"],
      ["chat:2", "Launch plan", "Design"],
      ["chat:3", "New thread", undefined],
      ["chat:4", "Sub", "Launch plan"],
    ])
    expect(chats[0]).toMatchObject({ unread: true, peerUserId: userId(10) })
    expect(chats[1]).toMatchObject({ pinned: true, spaceId: design.id })
  })

  it("lists known people without a direct chat, never the signed-in user", () => {
    const source = createRowLocalSource(signal(rowsOf(base)))
    expect(source.users.peek().map((u) => u.key)).toEqual(["user:11"])
    expect(source.spaces.peek().map((s) => s.title)).toEqual(["Design"])
  })

  it("reuses a candidate while its rows keep their identity", () => {
    const rows = signal(rowsOf(base))
    const source = createRowLocalSource(rows)
    const before = source.chats.peek()
    const renamed = { ...base, chats: base.chats.map((c) => (c.id === chatId(3) ? chat(3, { title: "Renamed" }) : c)) }
    rows.set(rowsOf(renamed))
    const after = source.chats.peek()
    expect(after[0]).toBe(before[0])
    expect(after[1]).toBe(before[1])
    expect(after[2]).not.toBe(before[2])
    expect(after[2]?.title).toBe("Renamed")
  })
})

describe("message search helpers", () => {
  it("needs two letters or digits (Mac rule)", () => {
    expect(isMessageSearchable("a")).toBe(false)
    expect(isMessageSearchable(" a! ")).toBe(false)
    expect(isMessageSearchable("ab")).toBe(true)
    expect(isMessageSearchable("سل")).toBe(true)
  })

  it("cuts a snippet around the first hit and points at it", () => {
    const text = `${"x".repeat(100)} Déploy the release ${"y".repeat(100)}`
    const { snippet, ranges } = messageSnippet(text, "deploy", 10)
    expect(snippet.startsWith("...")).toBe(true)
    expect(snippet.endsWith("...")).toBe(true)
    const [range] = ranges
    expect(range && snippet.slice(range[0], range[1])).toBe("Déploy")
    expect(messageSnippet("short text", "zz").snippet).toBe("short text")
  })
})

describe("fake sources", () => {
  it("search with prefix semantics, newest first, after their latency, and honor abort", async () => {
    const time = manualTime()
    const source = fakeMessageSource({
      clock: time,
      latencyMs: 30,
      messages: [
        { chatId: chatId(1), messageId: messageId(1), chatTitle: "A", text: "release notes", date: 1 },
        { chatId: chatId(1), messageId: messageId(2), chatTitle: "A", text: "the release went out", date: 2 },
        { chatId: chatId(2), messageId: messageId(3), chatTitle: "B", text: "unrelated", date: 3 },
      ],
    })
    const controller = new AbortController()
    const pending = source.search({ query: "rel", limit: 20, includeArchived: true, sort: "newest" }, controller.signal)
    time.advance(30)
    expect((await pending).map((hit) => hit.messageId)).toEqual([messageId(2), messageId(1)])

    const aborted = new AbortController()
    const late = source.search({ query: "rel", limit: 20, includeArchived: true, sort: "newest" }, aborted.signal)
    aborted.abort()
    await expect(late).rejects.toMatchObject({ name: "AbortError" })
    expect(time.pendingTimers()).toBe(0)
  })

  it("returns remote users the query matches", async () => {
    const remote = fakeRemoteSource({ users: [user(1, "Zed", "Shaw", "zed"), user(2, "Amy")] })
    const result = await remote.search({ query: "ze", limit: 20 }, new AbortController().signal)
    expect(result.users.map((u) => u.id)).toEqual([userId(1)])
  })
})

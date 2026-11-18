import type { ChatRow, DialogRow, SpaceRow, UserRow } from "@inline/core-protocol"
import { chatId, dialogId, messageId, spaceId, userId, type ChatID, type SpaceID, type UserID } from "@inline/ids"
import { manualTime, signal, type ManualTime } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { CommandRegistry } from "../commands/registry"
import { QuickSearchModel, type QuickSearchContext, type QuickSearchItem, type QuickSearchOptions } from "./model"
import { createRowLocalSource, type MessageHit, type QuickSearchMessageSource, type QuickSearchRows } from "./sources"
import { scriptedMessageSource, scriptedRemoteSource } from "./testing"
import { UsageStore, memoryUsagePersistence } from "./usage"

const T0 = Date.UTC(2026, 10, 17)

const flush = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

const user = (id: number, firstName: string, lastName?: string, username?: string): UserRow => ({
  kind: "user",
  id: userId(id),
  firstName,
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

const design: SpaceRow = { kind: "space", id: spaceId(9), name: "Design Team" }

const fixture = () => {
  const users = [user(10, "Ada", "Lovelace", "ada"), user(11, "Grace", "Hopper", "grace"), user(12, "Alan", "Turing", "alan")]
  const chats = [
    chat(1, { peerUserId: userId(10), lastActivityDate: 100 }),
    chat(2, { title: "Design review", spaceId: design.id, lastActivityDate: 50 }),
    chat(3, { title: "Product Meeting", lastActivityDate: 70 }),
    chat(4, { title: "Launch", lastActivityDate: 10 }),
    chat(5, { title: "Hiring" }),
    chat(6, { title: "Infra" }),
    chat(7, { title: "Random" }),
    chat(8, { title: "Ops weekly" }),
    chat(9, { title: "Ops daily", spaceId: design.id }),
  ]
  const dialogs = [
    dialog(1, { peerUserId: userId(10) }),
    dialog(2, { spaceId: design.id }),
    dialog(3),
    dialog(4),
    dialog(5),
    dialog(6),
    dialog(7),
    dialog(8),
    dialog(9, { spaceId: design.id }),
  ]
  const chatMap = new Map<ChatID, ChatRow>(chats.map((c) => [c.id, c]))
  const userMap = new Map<UserID, UserRow>(users.map((u) => [u.id, u]))
  const rows: QuickSearchRows = {
    dialogs,
    chat: (id) => chatMap.get(id),
    user: (id) => userMap.get(id),
    space: (id: SpaceID) => (id === design.id ? design : undefined),
    users,
    spaces: [design],
  }
  return { rows: signal(rows) }
}

type Harness = {
  model: QuickSearchModel
  time: ManualTime
  usage: UsageStore
  registry: CommandRegistry
  context: ReturnType<typeof signal<QuickSearchContext>>
  messages: ReturnType<typeof scriptedMessageSource>
  remote: ReturnType<typeof scriptedRemoteSource>
}

const setup = (overrides: Partial<QuickSearchOptions> = {}): Harness => {
  const time = manualTime()
  const wall = () => T0 + time.now()
  const usage = new UsageStore({ persistence: memoryUsagePersistence(), now: wall })
  const registry = new CommandRegistry()
  registry.register({ id: "app.quickSearch", title: "Quick Search", category: "app", run: () => {} })
  registry.register({ id: "app.settings", title: "Settings", category: "app", run: () => {} })
  registry.register({ id: "chat.markRead", title: "Mark as Read", category: "chat", run: () => {} })
  registry.register({ id: "hidden", title: "Hidden", category: "app", inPalette: false, run: () => {} })
  registry.register({ id: "off", title: "Disabled thing", category: "app", enabled: signal(false), run: () => {} })
  const context = signal<QuickSearchContext>({})
  const messages = scriptedMessageSource()
  const remote = scriptedRemoteSource()
  const model = new QuickSearchModel({
    clock: time,
    now: wall,
    local: createRowLocalSource(fixture().rows),
    commands: registry,
    messages: messages.source,
    remote: remote.source,
    usage,
    context,
    ...overrides,
  })
  return { model, time, usage, registry, context, messages, remote }
}

const ids = (items: readonly QuickSearchItem[]) => items.map((item) => item.id)
const sectionKinds = (model: QuickSearchModel) => model.sections.peek().map((s) => s.kind)

const hit = (chat: number, message: number, fields: Partial<MessageHit> = {}): MessageHit => ({
  chatId: chatId(chat),
  messageId: messageId(message),
  chatTitle: `Chat ${chat}`,
  date: message,
  snippet: `message ${message}`,
  ...fields,
})

describe("empty query", () => {
  it("shows suggestions from usage, the top of the sidebar, and every palette command", () => {
    const { model, usage } = setup()
    usage.recordSwitch("chat:4")
    usage.recordSwitch("chat:4")
    usage.recordSwitch("user:10")
    model.open()
    expect(sectionKinds(model)).toEqual(["suggestions", "chats", "commands"])
    const [suggestions, chats, commands] = model.sections.peek()
    expect(ids(suggestions?.items ?? [])).toEqual(["chat:4", "user:10"])
    expect(ids(chats?.items ?? [])).toEqual(["chat:2", "chat:3", "chat:5", "chat:6", "chat:7"])
    expect(ids(commands?.items ?? [])).toEqual(["command:app.settings", "command:chat.markRead"])
    expect(model.activeId.peek()).toBe("chat:4")
    expect(model.emptyState.peek()).toBe("results")
  })

  it("follows usage recorded while open", () => {
    const { model, usage } = setup()
    model.open()
    expect(sectionKinds(model)).toEqual(["chats", "commands"])
    usage.recordSwitch("chat:7")
    expect(ids(model.sections.peek()[0]?.items ?? [])).toEqual(["chat:7"])
  })

  it("starts no async search", () => {
    const { model, time, messages, remote } = setup()
    model.open()
    model.setQuery("   ")
    time.advance(1000)
    expect(messages.calls).toHaveLength(0)
    expect(remote.calls).toHaveLength(0)
    expect(model.isLoading.peek()).toBe(false)
  })
})

describe("local results", () => {
  it("update in the same task as the query", () => {
    const { model, messages } = setup()
    model.open()
    model.setQuery("des")
    expect(model.query.peek()).toBe("des")
    expect(sectionKinds(model)).toEqual(["chats", "spaces"])
    // "Ops daily" matches through its space's name, a low-priority field.
    expect(ids(model.items.peek())).toEqual(["chat:2", "chat:9", "space:9"])
    expect(model.activeId.peek()).toBe("chat:2")
    expect(messages.calls).toHaveLength(0)
    expect(model.messagesState.peek().status).toBe("pending")
    expect(model.isLoading.peek()).toBe(true)
  })

  it("rank chats the Mac way and mix in people without a chat", () => {
    const { model } = setup()
    model.open()
    model.setQuery("a")
    const chats = model.sections.peek().find((s) => s.kind === "chats")
    // Both are prefix matches; a known person's username (600) outranks a
    // chat's username (500), as on the Mac. The title is highlighted either way.
    expect(ids(chats?.items ?? []).slice(0, 2)).toEqual(["user:12", "user:10"])
    expect(chats?.items[0]).toMatchObject({ kind: "user", remote: false, titleRanges: [[0, 1]] })
    expect(chats?.items[1]).toMatchObject({ kind: "chat", chatId: chatId(1), titleRanges: [[0, 1]] })
  })

  it("find a chat by acronym and highlight the initials", () => {
    const { model } = setup()
    model.open()
    model.setQuery("pm")
    const first = model.items.peek()[0]
    expect(first).toMatchObject({ id: "chat:3", titleRanges: [[0, 1], [8, 9]] })
  })

  it("rank the chat picked for a query first next time", () => {
    const { model } = setup()
    model.open()
    model.setQuery("ops")
    expect(ids(model.items.peek()).slice(0, 2)).toEqual(["chat:8", "chat:9"])
    const daily = model.items.peek().find((item) => item.id === "chat:9")
    expect(model.activate(daily)).toMatchObject({ kind: "open", destination: { kind: "chat", chatId: chatId(9) } })
    model.open()
    model.setQuery("op")
    expect(ids(model.items.peek()).slice(0, 2)).toEqual(["chat:9", "chat:8"])
  })

  it("prefer chats in the current space", () => {
    const { model, context } = setup()
    context.set({ spaceId: design.id })
    model.open()
    model.setQuery("ops")
    expect(model.items.peek()[0]?.id).toBe("chat:9")
  })

  it("list matching commands only, never disabled or hidden ones", () => {
    const { model } = setup()
    model.open()
    model.setQuery("settings")
    expect(ids(model.items.peek())).toEqual(["command:app.settings"])
    model.setQuery("hidden")
    expect(model.items.peek()).toHaveLength(0)
    model.setQuery("disabled")
    expect(model.items.peek()).toHaveLength(0)
  })
})

describe("async timing", () => {
  it("searches messages after 120 ms and the server after 250 ms", async () => {
    const { model, time, messages, remote } = setup()
    model.open()
    model.setQuery("rel")
    time.advance(119)
    expect(messages.calls).toHaveLength(0)
    time.advance(1)
    expect(messages.calls.map((c) => c.request)).toEqual([{ query: "rel", limit: 20, includeArchived: true, sort: "newest" }])
    time.advance(129)
    expect(remote.calls).toHaveLength(0)
    time.advance(1)
    expect(remote.calls.map((c) => c.request)).toEqual([{ query: "rel", limit: 20 }])

    messages.calls[0]?.resolve([hit(3, 1)])
    await flush()
    expect(model.messagesState.peek().status).toBe("done")
    expect(model.isLoading.peek()).toBe(true)
    remote.calls[0]?.resolve({ users: [] })
    await flush()
    expect(model.isLoading.peek()).toBe(false)
    expect(sectionKinds(model)).toEqual(["messages"])
  })

  it("debounces: quick typing searches once, for the last query", () => {
    const { model, time, messages, remote } = setup()
    model.open()
    for (const text of ["d", "de", "des", "desi"]) {
      model.setQuery(text)
      time.advance(50)
    }
    time.advance(300)
    expect(messages.calls.map((c) => c.request.query)).toEqual(["desi"])
    expect(remote.calls.map((c) => c.request.query)).toEqual(["desi"])
  })

  it("does not restart for whitespace-only edits", () => {
    const { model, time, messages } = setup()
    model.open()
    model.setQuery("design")
    time.advance(100)
    model.setQuery("design ")
    expect(model.text.peek()).toBe("design ")
    time.advance(20)
    expect(messages.calls).toHaveLength(1)
  })

  it("aborts requests for an older query and drops their late results", async () => {
    const late: { resolve: (hits: MessageHit[]) => void; signal: AbortSignal }[] = []
    const stubborn: QuickSearchMessageSource = {
      // Ignores abort on purpose: the model must still discard the result.
      search: (_request, signal) => new Promise((resolve) => late.push({ resolve, signal })),
    }
    const { model, time } = setup({ messages: stubborn })
    model.open()
    model.setQuery("rel")
    time.advance(120)
    model.setQuery("rele")
    expect(late[0]?.signal.aborted).toBe(true)
    late[0]?.resolve([hit(1, 1)])
    await flush()
    expect(model.items.peek().some((item) => item.kind === "message")).toBe(false)
    expect(model.messagesState.peek().status).toBe("pending")

    time.advance(120)
    late[1]?.resolve([hit(1, 2)])
    await flush()
    expect(ids(model.items.peek())).toContain(`message:${chatId(1)}:${messageId(2)}`)
  })

  it("reports a failed search per section without touching the others", async () => {
    const { model, time, messages, remote } = setup()
    model.open()
    model.setQuery("zzzz")
    time.advance(250)
    messages.calls[0]?.reject(new Error("fts down"))
    remote.calls[0]?.resolve({ users: [] })
    await flush()
    expect(model.messagesState.peek()).toMatchObject({ status: "error" })
    expect(model.globalState.peek().status).toBe("done")
    expect(model.emptyState.peek()).toBe("error")
  })

  it("skips message search below two letters and the server below two", () => {
    const { model, time, messages, remote } = setup()
    model.open()
    model.setQuery("a")
    time.advance(500)
    expect(messages.calls).toHaveLength(0)
    expect(remote.calls).toHaveLength(0)
    expect(model.messagesState.peek().status).toBe("idle")
  })

  it("passes the selected space to message search", () => {
    const { model, time, messages, context } = setup()
    context.set({ spaceId: design.id })
    model.open()
    model.setQuery("review")
    time.advance(120)
    expect(messages.calls[0]?.request.spaceId).toBe(design.id)
  })
})

describe("stability", () => {
  it("never moves shown items: async sections append below in arrival order", async () => {
    const { model, time, messages, remote } = setup()
    model.open()
    model.setQuery("de")
    const before = model.items.peek()
    expect(before.length).toBeGreaterThan(0)
    model.next()
    const active = model.activeId.peek()

    time.advance(250)
    // The server answers first; messages come later and go below it.
    remote.calls[0]?.resolve({ users: [user(50, "Devon", "Remote", "devon")] })
    await flush()
    const afterRemote = model.items.peek()
    expect(afterRemote.slice(0, before.length)).toEqual(before)
    afterRemote.slice(0, before.length).forEach((item, index) => expect(item).toBe(before[index]))
    expect(model.activeId.peek()).toBe(active)

    messages.calls[0]?.resolve([hit(2, 9)])
    await flush()
    const afterMessages = model.items.peek()
    afterRemote.forEach((item, index) => expect(afterMessages[index]).toBe(item))
    expect(sectionKinds(model).slice(-2)).toEqual(["global", "messages"])
    expect(model.activeId.peek()).toBe(active)
  })

  it("keeps the first item active when results arrive into an empty list", async () => {
    const { model, time, messages, remote } = setup()
    model.open()
    model.setQuery("zebra")
    expect(model.activeId.peek()).toBeUndefined()
    time.advance(250)
    messages.calls[0]?.resolve([hit(4, 1)])
    await flush()
    expect(model.activeId.peek()).toBe(`message:${chatId(4)}:${messageId(1)}`)
    remote.calls[0]?.resolve({ users: [user(60, "Zebra", "Stripes")] })
    await flush()
    expect(model.activeId.peek()).toBe(`message:${chatId(4)}:${messageId(1)}`)
  })

  it("keeps the active item across a store update while it exists, else falls back to the first", () => {
    const rows = fixture().rows
    const { model } = setup({ local: createRowLocalSource(rows) })
    model.open()
    model.setQuery("i")
    model.setActive("chat:5")
    rows.set({ ...rows.peek() })
    expect(model.activeId.peek()).toBe("chat:5")
    rows.set({ ...rows.peek(), dialogs: rows.peek().dialogs.filter((d) => d.chatId !== chatId(5)) })
    expect(model.items.peek().some((item) => item.id === "chat:5")).toBe(false)
    expect(model.activeId.peek()).toBe(model.items.peek()[0]?.id)
  })

  it("shows people from the server once: not those already shown locally, not those the query misses", async () => {
    const { model, time, remote } = setup()
    model.open()
    model.setQuery("ada")
    time.advance(250)
    remote.calls[0]?.resolve({ users: [user(10, "Ada", "Lovelace", "ada"), user(70, "Adam", "Smith"), user(71, "Nobody")] })
    await flush()
    const global = model.sections.peek().find((s) => s.kind === "global")
    expect(ids(global?.items ?? [])).toEqual(["user:70"])
    expect(global?.items[0]).toMatchObject({ kind: "user", remote: true, titleRanges: [[0, 3]] })
  })
})

describe("navigation", () => {
  it("moves within bounds and jumps between sections", () => {
    const { model, usage } = setup()
    usage.recordSwitch("chat:4")
    model.open()
    // suggestions: chat:4 | chats: 1,2,3,5,6 | commands: settings, markRead
    expect(model.activeId.peek()).toBe("chat:4")
    model.previous()
    expect(model.activeId.peek()).toBe("chat:4")
    model.next()
    expect(model.activeId.peek()).toBe("user:10")
    model.nextSection()
    expect(model.activeId.peek()).toBe("command:app.settings")
    model.nextSection()
    expect(model.activeId.peek()).toBe("command:app.settings")
    model.next()
    model.next()
    expect(model.activeId.peek()).toBe("command:chat.markRead")
    model.previousSection()
    expect(model.activeId.peek()).toBe("command:app.settings")
    model.previousSection()
    expect(model.activeId.peek()).toBe("user:10")
    model.last()
    expect(model.activeId.peek()).toBe("command:chat.markRead")
    model.first()
    expect(model.activeId.peek()).toBe("chat:4")
    model.setActive("chat:3")
    expect(model.activeId.peek()).toBe("chat:3")
    model.setActive("nope")
    expect(model.activeId.peek()).toBe("chat:3")
  })

  it("resets to the first item when the query changes", () => {
    const { model } = setup()
    model.open()
    model.last()
    model.setQuery("in")
    expect(model.activeId.peek()).toBe(model.items.peek()[0]?.id)
  })
})

describe("the Create row", () => {
  it("appears once every search finished with nothing found, in a space", async () => {
    const { model, time, messages, remote, context } = setup()
    context.set({ spaceId: design.id })
    model.open()
    model.setQuery("Quarterly offsite")
    expect(model.items.peek()).toHaveLength(0)
    time.advance(250)
    messages.calls[0]?.resolve([])
    await flush()
    expect(model.items.peek()).toHaveLength(0)
    remote.calls[0]?.resolve({ users: [] })
    await flush()
    expect(model.items.peek()).toEqual([
      expect.objectContaining({
        kind: "createThread",
        id: `create:${design.id}:quarterly offsite`,
        title: 'Create "Quarterly offsite"',
        threadTitle: "Quarterly offsite",
        section: "commands",
      }),
    ])
    expect(model.activate()).toEqual({ kind: "createThread", spaceId: design.id, title: "Quarterly offsite" })
  })

  it("does not appear outside a space, after an error, or when anything matched", async () => {
    const outside = setup()
    outside.model.open()
    outside.model.setQuery("Quarterly offsite")
    outside.time.advance(250)
    outside.messages.calls[0]?.resolve([])
    outside.remote.calls[0]?.resolve({ users: [] })
    await flush()
    expect(outside.model.items.peek()).toHaveLength(0)

    const failed = setup()
    failed.context.set({ spaceId: design.id })
    failed.model.open()
    failed.model.setQuery("Quarterly offsite")
    failed.time.advance(250)
    failed.messages.calls[0]?.resolve([])
    failed.remote.calls[0]?.reject(new Error("offline"))
    await flush()
    expect(failed.model.items.peek()).toHaveLength(0)

    const matched = setup()
    matched.context.set({ spaceId: design.id })
    matched.model.open()
    matched.model.setQuery("launch")
    matched.time.advance(250)
    matched.messages.calls[0]?.resolve([])
    matched.remote.calls[0]?.resolve({ users: [] })
    await flush()
    expect(matched.model.items.peek().some((item) => item.kind === "createThread")).toBe(false)
  })

  it("appears without async sources once the local search found nothing", () => {
    const { model, context } = setup({ messages: undefined, remote: undefined })
    context.set({ spaceId: design.id })
    model.open()
    model.setQuery("Quarterly offsite")
    expect(model.items.peek().map((item) => item.kind)).toEqual(["createThread"])
  })
})

describe("activate", () => {
  it("returns what to do for each kind and records usage", async () => {
    const { model, time, messages, remote, usage } = setup()
    model.open()
    model.setQuery("ada")
    expect(model.activate(undefined, "otherPane")).toEqual({
      kind: "open",
      destination: { kind: "chat", chatId: chatId(1) },
      intent: "otherPane",
    })
    expect(usage.signals("ad").get("user:10")?.queryAffinity).toBeGreaterThan(0)
    expect(model.isOpen.peek()).toBe(false)

    model.open()
    model.setQuery("alan")
    expect(model.activate()).toEqual({ kind: "openUser", userId: userId(12), intent: "here" })

    model.open()
    model.setQuery("design team")
    model.nextSection()
    expect(model.activate()).toEqual({ kind: "openSpace", spaceId: design.id })

    model.open()
    model.setQuery("mark")
    expect(model.activate()).toEqual({ kind: "runCommand", commandId: "chat.markRead" })

    model.open()
    model.setQuery("rollout")
    time.advance(250)
    messages.calls.at(-1)?.resolve([hit(3, 42, { peerUserId: userId(11) })])
    remote.calls.at(-1)?.resolve({ users: [user(80, "Rollout", "Bot")] })
    await flush()
    model.setActive(`message:${chatId(3)}:${messageId(42)}`)
    expect(model.activate()).toEqual({
      kind: "open",
      destination: { kind: "message", chatId: chatId(3), messageId: messageId(42) },
      intent: "here",
    })
    expect(usage.signals("ro").get("user:11")?.queryAffinity).toBeGreaterThan(0)

    model.open()
    model.setQuery("rollout")
    time.advance(250)
    messages.calls.at(-1)?.resolve([])
    remote.calls.at(-1)?.resolve({ users: [user(80, "Rollout", "Bot")] })
    await flush()
    expect(model.activate()).toEqual({ kind: "openUser", userId: userId(80), intent: "here" })
  })

  it("ignores an item from an older list and an empty list", () => {
    const { model } = setup()
    model.open()
    model.setQuery("hiring")
    const stale = model.items.peek()[0]
    model.setQuery("infra")
    expect(model.activate(stale)).toEqual({ kind: "none" })
    expect(model.isOpen.peek()).toBe(true)
    model.setQuery("zzzzzz")
    expect(model.activate()).toEqual({ kind: "none" })
  })
})

describe("open and close", () => {
  it("close cancels timers and requests; open starts clean", () => {
    const { model, time, messages } = setup()
    model.open()
    model.setQuery("design")
    time.advance(120)
    const inflight = messages.calls[0]
    model.close()
    expect(inflight?.signal.aborted).toBe(true)
    expect(time.pendingTimers()).toBe(0)
    expect(model.isOpen.peek()).toBe(false)
    expect(model.query.peek()).toBe("")
    expect(model.isLoading.peek()).toBe(false)

    model.open()
    expect(model.isOpen.peek()).toBe(true)
    expect(model.text.peek()).toBe("")
    expect(model.messagesState.peek().status).toBe("idle")
    expect(sectionKinds(model)).toEqual(["chats", "commands"])
  })

  it("turns newlines into spaces", () => {
    const { model } = setup()
    model.open()
    model.setQuery("design\nreview")
    expect(model.text.peek()).toBe("design review")
    expect(model.items.peek()[0]?.id).toBe("chat:2")
  })
})

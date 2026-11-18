import { describe, expect, it } from "vitest"
import { rowKeyOf, type ChatRow, type DialogRow, type QueryDescriptor, type Row, type SpaceRow, type SubId, type UserRow } from "@inline/core-protocol"
import type { ChatID, DialogID, MessageID, SpaceID, UserID } from "@inline/ids"
import { createScheduler, createStoreClient, manualTime } from "@inline/reactive"
import { scriptedEndpoint } from "@inline/reactive/testing"
import { navigationCommandIds } from "@inline/view"
import { AccountSession } from "@inline/view/features"
import type { MessageHit, MessageSearchRequest, QuickSearchMessageSource, QuickSearchOutcome } from "@inline/view/quick-search"
import { quickSearchUsageStorageKey, wireQuickSearch, type QuickSearchWiringOptions } from "./wiring"

// ---------------------------------------------------------------------------
// Fixtures: a real AccountSession over a scripted core and a manual clock.

const uid = (n: number) => String(n) as UserID
const cid = (n: number) => String(n) as ChatID
const did = (n: number) => String(n) as DialogID
const sid = (n: number) => String(n) as SpaceID

const NOW = Date.UTC(2026, 10, 17, 12)

const user = (n: number, firstName: string, lastName?: string, extra: Partial<UserRow> = {}): UserRow => ({
  kind: "user",
  id: uid(n),
  firstName,
  ...(lastName ? { lastName } : {}),
  ...extra,
})
const chat = (n: number, extra: Partial<ChatRow> = {}): ChatRow => ({ kind: "chat", id: cid(n), ...extra })
const dialog = (n: number, extra: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: did(n),
  chatId: cid(n),
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...extra,
})
const space = (n: number, name: string): SpaceRow => ({ kind: "space", id: sid(n), name })

const memoryStorage = () => {
  const data = new Map<string, string>()
  return { data, getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => void data.set(key, value) }
}

const microtasks = async (rounds = 8) => {
  for (let i = 0; i < rounds; i++) await Promise.resolve()
}

/** A message source whose calls settle when the test says so. */
const scriptedMessages = () => {
  const calls: { request: MessageSearchRequest; signal: AbortSignal; resolve: (hits: readonly MessageHit[]) => void }[] = []
  const source: QuickSearchMessageSource = {
    search: (request, signal) =>
      new Promise((resolve, reject) => {
        calls.push({ request, signal, resolve })
        signal.addEventListener("abort", () => reject(Object.assign(new Error("Aborted"), { name: "AbortError" })), { once: true })
      }),
  }
  return { source, calls }
}

const setup = (options: Partial<QuickSearchWiringOptions> = {}, before?: (session: AccountSession) => void) => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler })
  const session = new AccountSession({
    userId: uid(1),
    token: "token",
    clock: time,
    connect: () => ({
      core: endpoint,
      client,
      close: () => {
        client.dispose()
        endpoint.close()
      },
    }),
  })
  const view: string[] = []
  session.attachView({
    focusRegion: (region) => view.push(`focus ${region}`),
    openQuickSearch: () => view.push("quickSearch"),
    toggleSidebar: () => view.push("toggleSidebar"),
  })
  before?.(session)
  const storage = memoryStorage()
  const layers: string[] = []
  const performed: QuickSearchOutcome[] = []
  const quickSearch = wireQuickSearch(session, {
    clock: time,
    now: () => NOW,
    storage,
    platform: { os: "mac", surface: "browser" },
    keyboard: {
      pushLayer: (scope, layerOptions) => {
        const entry = `${scope}${layerOptions?.modal ? " modal" : ""}`
        layers.push(entry)
        return () => {
          layers.splice(layers.indexOf(entry), 1)
        }
      },
    },
    onPerform: (outcome) => performed.push(outcome),
    ...options,
  })

  const live = () => {
    const subs = new Map<SubId, QueryDescriptor>()
    for (const command of endpoint.posted) {
      if (command.kind === "subscribe") subs.set(command.sub, command.query)
      if (command.kind === "unsubscribe") subs.delete(command.sub)
    }
    return subs
  }
  /** Every live sidebar subscription of a mode (the session's badge list and ours are both `all`). */
  const subs = (mode: "inbox" | "all" | "archived") =>
    [...live()].filter(([, query]) => query.kind === "sidebar" && query.mode === mode).map(([id]) => id)
  const flush = async () => {
    time.frame()
    await microtasks()
  }

  /** Deliver rows and the three sidebar lists. */
  const seed = async (data: { rows: Row[]; inbox: DialogRow[]; all?: DialogRow[]; archived?: DialogRow[] }) => {
    const keysOf = { inbox: data.inbox, all: data.all ?? data.inbox, archived: data.archived ?? [] }
    const lists = (["inbox", "all", "archived"] as const).flatMap((mode) =>
      subs(mode).map((sub) => ({ sub, op: "replace" as const, keys: keysOf[mode].map(rowKeyOf) })),
    )
    endpoint.patch({ rows: data.rows.map((row) => ({ op: "upsert" as const, row })), lists })
    await flush()
  }

  return { time, endpoint, client, session, quickSearch, storage, layers, performed, view, live, subs, flush, seed }
}

/** Ada (DM), a thread "Design review" in Platform, an archived thread "Deploy plans", and Grace with no chat. */
const standardData = () => {
  const ada = user(2, "Ada", "Lovelace", { username: "ada" })
  const grace = user(3, "Grace", "Hopper")
  const platform = space(5, "Platform")
  const dm = chat(10, { peerUserId: ada.id })
  const design = chat(11, { title: "Design review", spaceId: platform.id })
  const deploy = chat(12, { title: "Deploy plans", spaceId: platform.id })
  const d10 = dialog(10, { peerUserId: ada.id })
  const d11 = dialog(11, { spaceId: platform.id })
  const d12 = dialog(12, { spaceId: platform.id, archived: true })
  return {
    ada,
    grace,
    platform,
    rows: [ada, grace, platform, dm, design, deploy, d10, d11, d12] as Row[],
    inbox: [d10, d11],
    archived: [d12],
  }
}

const titles = (s: ReturnType<typeof setup>) => s.quickSearch.model.items.peek().map((item) => `${item.section}:${item.title}`)

// ---------------------------------------------------------------------------

describe("wireQuickSearch", () => {
  it("subscribes the all and archived lists and finds archived chats and spaces in the same task", async () => {
    const s = setup()
    expect([...s.live().values()].filter((q) => q.kind === "sidebar")).toEqual([
      { kind: "sidebar", mode: "inbox" },
      { kind: "sidebar", mode: "all" },
      { kind: "sidebar", mode: "all" },
      { kind: "sidebar", mode: "archived" },
    ])
    const data = standardData()
    await s.seed(data)
    const { model } = s.quickSearch
    s.quickSearch.open()
    expect(titles(s)).toContain("chats:Ada Lovelace")
    expect(titles(s)).toContain("chats:Design review")
    model.setQuery("dep")
    // Readable as soon as setQuery returns.
    expect(titles(s)[0]).toBe("chats:Deploy plans")
    model.setQuery("plat")
    expect(titles(s)).toContain("spaces:Platform")
    // Each chat once, even though it is in two lists.
    model.setQuery("design")
    expect(titles(s).filter((title) => title === "chats:Design review")).toHaveLength(1)
  })

  it("skips the extra lists when asked, searching the visible sidebar only", async () => {
    const s = setup({ includeAllChats: false })
    expect([...s.live().values()].filter((q) => q.kind === "sidebar")).toHaveLength(2)
    await s.seed(standardData())
    s.quickSearch.open()
    s.quickSearch.model.setQuery("deploy")
    expect(titles(s)).not.toContain("chats:Deploy plans")
  })

  it("pushes a modal keyboard layer while open and pops it on close", () => {
    const s = setup()
    expect(s.layers).toEqual([])
    s.quickSearch.open()
    expect(s.quickSearch.isOpen.peek()).toBe(true)
    expect(s.layers).toEqual(["dialog modal"])
    s.quickSearch.open()
    expect(s.layers).toEqual(["dialog modal"])
    s.quickSearch.toggle()
    expect(s.quickSearch.isOpen.peek()).toBe(false)
    expect(s.layers).toEqual([])
    s.quickSearch.toggle()
    expect(s.layers).toEqual(["dialog modal"])
    s.quickSearch.dispose()
    expect(s.layers).toEqual([])
  })

  it("opens a chat here or in the other pane and records the pick for the query", async () => {
    const s = setup()
    await s.seed(standardData())
    const { model, workspace } = { model: s.quickSearch.model, workspace: s.session.workspace }
    s.quickSearch.open()
    model.setQuery("design")
    const outcome = s.quickSearch.activate()
    expect(outcome).toEqual({ kind: "open", destination: { kind: "chat", chatId: cid(11) }, intent: "here" })
    expect(model.isOpen.peek()).toBe(false)
    expect(workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(11) })
    expect(s.quickSearch.usage.signals("design").get("chat:11")?.queryAffinity).toBeGreaterThan(0)
    // Saved under the account's key after the debounce.
    s.time.advance(350)
    expect(s.storage.data.has(quickSearchUsageStorageKey(uid(1)))).toBe(true)

    s.quickSearch.open()
    model.setQuery("ada")
    s.quickSearch.activate(undefined, "otherPane")
    expect(workspace.panes.peek()).toHaveLength(2)
    expect(workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(10) })
    expect(s.performed.map((outcome) => outcome.kind)).toEqual(["open", "open"])
  })

  it("runs a command through the registry with the palette as source", async () => {
    const s = setup()
    await s.seed(standardData())
    s.quickSearch.open()
    s.quickSearch.model.setQuery("toggle sidebar")
    const item = s.quickSearch.model.activeItem.peek()
    expect(item).toMatchObject({ kind: "command", commandId: navigationCommandIds.toggleSidebar })
    expect(s.quickSearch.activate()).toEqual({ kind: "runCommand", commandId: navigationCommandIds.toggleSidebar })
    expect(s.view).toEqual(["toggleSidebar"])
    // Quick Search itself is never listed.
    s.quickSearch.open()
    s.quickSearch.model.setQuery("quick search")
    expect(s.quickSearch.model.items.peek().some((i) => i.kind === "command" && i.commandId === navigationCommandIds.quickSearch)).toBe(false)
  })

  it("opens a person's direct chat, else their page or the injected opener", async () => {
    const s = setup()
    const data = standardData()
    await s.seed(data)
    expect(s.quickSearch.perform({ kind: "openUser", userId: data.ada.id, intent: "here" })).toBe(true)
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: cid(10) })
    s.quickSearch.perform({ kind: "openUser", userId: data.grace.id, intent: "here" })
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "user", userId: data.grace.id })

    const opened: string[] = []
    const t = setup({ openUser: (userId, intent) => opened.push(`${userId} ${intent}`) })
    await t.seed(data)
    t.quickSearch.perform({ kind: "openUser", userId: data.grace.id, intent: "otherPane" })
    expect(opened).toEqual(["3 otherPane"])
  })

  it("selects a space, and offers Create in the focused chat's space when nothing matches", async () => {
    const s = setup()
    const data = standardData()
    await s.seed(data)
    s.quickSearch.open()
    s.quickSearch.model.setQuery("platform")
    const spaceItem = s.quickSearch.model.items.peek().find((item) => item.kind === "space")
    expect(spaceItem).toBeDefined()
    s.quickSearch.activate(spaceItem)
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "space", spaceId: data.platform.id, page: "members" })

    // No space in context: no Create row.
    s.session.workspace.open({ kind: "allChats" })
    s.quickSearch.open()
    s.quickSearch.model.setQuery("zzqx")
    expect(s.quickSearch.model.items.peek()).toEqual([])
    expect(s.quickSearch.model.emptyState.peek()).toBe("noResults")
    s.quickSearch.close()

    // Focused chat in Platform: Create "zzqx" there.
    s.session.workspace.open({ kind: "chat", chatId: cid(11) })
    expect(s.quickSearch.context.peek()).toEqual({ spaceId: data.platform.id })
    s.quickSearch.open()
    s.quickSearch.model.setQuery("zzqx")
    expect(titles(s)).toEqual(['commands:Create "zzqx"'])
    s.quickSearch.activate()
    expect(s.session.workspace.focusedDestination.peek()).toEqual({ kind: "newThread", spaceId: data.platform.id })

    const created: string[] = []
    const t = setup({ createThread: (spaceId, title) => created.push(`${spaceId} ${title}`) })
    await t.seed(data)
    t.quickSearch.perform({ kind: "createThread", spaceId: data.platform.id, title: "Launch" })
    expect(created).toEqual(["5 Launch"])
  })

  it("records a switch whenever the visible chat changes, not the chat restored at start", async () => {
    const s = setup()
    await s.seed(standardData())
    const frecency = (key: string) => s.quickSearch.usage.signals("").get(key)?.switchFrecency ?? 0
    s.session.workspace.open({ kind: "chat", chatId: cid(11) })
    expect(frecency("chat:11")).toBeGreaterThan(0)
    s.session.workspace.open({ kind: "chat", chatId: cid(10) })
    // A direct chat is recorded for its person, the key a DM and its user share.
    expect(frecency("user:2")).toBeGreaterThan(0)
    // The empty query now suggests what was visited.
    s.quickSearch.open()
    expect(s.quickSearch.model.sections.peek()[0]?.kind).toBe("suggestions")
  })

  it("does not record the chat already visible when it is wired (a restored workspace)", async () => {
    const s = setup({}, (session) => session.workspace.open({ kind: "chat", chatId: cid(11) }))
    await s.seed(standardData())
    expect(s.quickSearch.usage.signals("").size).toBe(0)
    s.session.workspace.open({ kind: "chat", chatId: cid(11) })
    expect(s.quickSearch.usage.signals("").size).toBe(0)
    s.session.workspace.open({ kind: "chat", chatId: cid(10) })
    expect(s.quickSearch.usage.signals("").size).toBe(1)
  })

  it("searches messages in the context space after the debounce and drops everything on dispose", async () => {
    const messages = scriptedMessages()
    const s = setup({ messages: messages.source })
    const data = standardData()
    await s.seed(data)
    s.session.workspace.open({ kind: "chat", chatId: cid(11) })
    s.quickSearch.open()
    s.quickSearch.model.setQuery("rollout")
    expect(s.quickSearch.model.messagesState.peek().status).toBe("pending")
    expect(messages.calls).toHaveLength(0)
    s.time.advance(120)
    expect(messages.calls).toHaveLength(1)
    expect(messages.calls[0]?.request).toMatchObject({ query: "rollout", spaceId: data.platform.id, sort: "newest" })
    messages.calls[0]?.resolve([
      { chatId: cid(11), messageId: "77" as MessageID, chatTitle: "Design review", date: NOW / 1000, snippet: "the rollout is done", snippetRanges: [[4, 11]] },
    ])
    await microtasks()
    const hit = s.quickSearch.model.items.peek().find((item) => item.kind === "message")
    expect(hit).toMatchObject({ title: "Design review", snippet: "the rollout is done" })
    expect(s.quickSearch.activate(hit)).toEqual({
      kind: "open",
      destination: { kind: "message", chatId: cid(11), messageId: "77" },
      intent: "here",
    })

    s.quickSearch.open()
    s.quickSearch.model.setQuery("pending")
    s.time.advance(120)
    expect(messages.calls).toHaveLength(2)
    const inFlight = messages.calls[1]
    const subs = s.live().size
    s.quickSearch.dispose()
    expect(inFlight?.signal.aborted).toBe(true)
    expect(s.quickSearch.isOpen.peek()).toBe(false)
    // The all and archived lists are released.
    expect(s.live().size).toBe(subs - 2)
    // Disposed: open does nothing.
    s.quickSearch.open()
    expect(s.quickSearch.isOpen.peek()).toBe(false)
  })

  it("reads a person's photo from the rows and clears usage on request", async () => {
    const s = setup()
    const data = standardData()
    data.rows.push(user(4, "Lin", undefined, { photoUrl: "https://media.example/lin.jpg" }))
    await s.seed(data)
    expect(s.quickSearch.photoUrl(uid(4))).toBe("https://media.example/lin.jpg")
    expect(s.quickSearch.photoUrl(uid(99))).toBeUndefined()
    s.session.workspace.open({ kind: "chat", chatId: cid(11) })
    expect(s.quickSearch.usage.signals("").size).toBeGreaterThan(0)
    s.quickSearch.clearUsage()
    expect(s.quickSearch.usage.signals("").size).toBe(0)
  })

  it("returns false for a stale item and a command that did not run", async () => {
    const s = setup()
    await s.seed(standardData())
    expect(s.quickSearch.perform({ kind: "none" })).toBe(false)
    expect(s.quickSearch.perform({ kind: "runCommand", commandId: "missing.command" })).toBe(false)
    s.quickSearch.open()
    const outcome = s.quickSearch.activate({ kind: "space", id: "space:999", section: "spaces", title: "Gone", titleRanges: [], spaceId: sid(999) })
    expect(outcome).toEqual({ kind: "none" })
  })
})

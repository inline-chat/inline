import { describe, expect, it } from "vitest"
import type {
  ChatRow,
  CoreResource,
  DialogRow,
  QueryDescriptor,
  RemoteSearchResource,
  SearchMessageHit,
  SearchResource,
  SubId,
  UserRow,
} from "@inline/core-protocol"
import { chatId, dialogId, userId, type ChatID, type MessageID, type SpaceID, type UserID } from "@inline/ids"
import { createScheduler, createStoreClient, manualTime, signal } from "@inline/reactive"
import { scriptedEndpoint } from "@inline/reactive/testing"
import { createRowLocalSource, QuickSearchModel, type QuickSearchRows } from "@inline/view/quick-search"
import {
  CoreRemoteSearchError,
  coreRemoteRequest,
  CoreSearchError,
  coreSearchRequest,
  createCoreMessageSource,
  createCoreRemoteSource,
  createNoopRemoteSource,
  isAbortError,
} from "./core-sources"

const microtasks = async (rounds = 8) => {
  for (let i = 0; i < rounds; i++) await Promise.resolve()
}

const setup = () => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler })
  const subscribed = () =>
    endpoint.commands("subscribe").map((command) => ({ sub: command.sub, query: command.query }))
  const live = () => {
    const subs = new Map<SubId, QueryDescriptor>()
    for (const command of endpoint.posted) {
      if (command.kind === "subscribe") subs.set(command.sub, command.query)
      if (command.kind === "unsubscribe") subs.delete(command.sub)
    }
    return subs
  }
  /** The core answers a subscription; the store applies it in the next frame. */
  const answer = async (sub: SubId, value: SearchResource | RemoteSearchResource) => {
    endpoint.patch({ resources: [{ sub, value }] })
    time.frame()
    await microtasks()
  }
  return { time, endpoint, client, subscribed, live, answer }
}

const hit = (n: number, extra: Partial<SearchMessageHit> = {}): SearchMessageHit => ({
  chatId: "7" as ChatID,
  messageId: String(n) as MessageID,
  chatTitle: "Design",
  fromId: "2" as UserID,
  date: 1_700_000_000 + n,
  snippet: `deploy ${n}`,
  snippetRanges: [[0, 6]],
  ...extra,
})

describe("coreSearchRequest", () => {
  it("subscribes once, resolves with the first answer, then unsubscribes", async () => {
    const { client, subscribed, live, answer } = setup()
    const promise = coreSearchRequest(client, { kind: "countMessages", request: { query: "deploy" } })
    const [first] = subscribed()
    expect(first?.query).toEqual({ kind: "countMessages", request: { query: "deploy" } })
    await answer(first!.sub, { kind: "search", status: "pending" })
    await answer(first!.sub, { kind: "search", status: "done", result: { kind: "count", count: 12, capped: false, indexComplete: true } })
    await expect(promise).resolves.toEqual({ kind: "count", count: 12, capped: false, indexComplete: true })
    expect(live().size).toBe(0)
  })

  it("rejects with the core's reason when the request failed", async () => {
    const { client, subscribed, live, answer } = setup()
    const promise = coreSearchRequest(client, { kind: "findInChat", request: { chatId: "1" as ChatID, query: "x y" } })
    await answer(subscribed()[0]!.sub, { kind: "search", status: "failed", reason: "unavailable" })
    const error = await promise.catch((e: unknown) => e)
    expect(error).toBeInstanceOf(CoreSearchError)
    expect((error as CoreSearchError).reason).toBe("unavailable")
    expect(live().size).toBe(0)
  })

  it("rejects an answer of the wrong kind", async () => {
    const { client, subscribed, answer } = setup()
    const promise = coreSearchRequest(client, { kind: "countMessages", request: { query: "deploy" } })
    await answer(subscribed()[0]!.sub, {
      kind: "search",
      status: "done",
      result: { kind: "messages", hits: [], indexComplete: true, truncated: false },
    })
    await expect(promise).rejects.toBeInstanceOf(CoreSearchError)
  })

  it("aborting unsubscribes at once and a late answer is never delivered", async () => {
    const { client, subscribed, live, answer, endpoint } = setup()
    const abort = new AbortController()
    const promise = coreSearchRequest(client, { kind: "countMessages", request: { query: "deploy" } }, abort.signal)
    const sub = subscribed()[0]!.sub
    abort.abort()
    expect(live().size).toBe(0)
    expect(endpoint.commands("unsubscribe")).toEqual([{ kind: "unsubscribe", sub }])
    const error = await promise.catch((e: unknown) => e)
    expect(isAbortError(error)).toBe(true)
    // A core that answers anyway changes nothing.
    await answer(sub, { kind: "search", status: "done", result: { kind: "count", count: 1, capped: false, indexComplete: true } })
    expect(endpoint.commands("unsubscribe")).toHaveLength(1)
  })

  it("rejects without subscribing when the signal is already aborted", async () => {
    const { client, subscribed } = setup()
    const abort = new AbortController()
    abort.abort()
    await expect(coreSearchRequest(client, { kind: "countMessages", request: { query: "x" } }, abort.signal)).rejects.toSatisfy(isAbortError)
    expect(subscribed()).toHaveLength(0)
  })
})

describe("createCoreMessageSource", () => {
  it("maps the request to searchMessages and the hits to MessageHit", async () => {
    const { client, subscribed, answer } = setup()
    const source = createCoreMessageSource({ client })
    const abort = new AbortController()
    const promise = source.search(
      { query: "deploy", spaceId: "3" as SpaceID, limit: 20, includeArchived: true, sort: "newest" },
      abort.signal,
    )
    const [request] = subscribed()
    expect(request?.query).toEqual({
      kind: "searchMessages",
      request: { query: "deploy", spaceId: "3", limit: 20, includeArchived: true, sort: "newest" },
    })
    const extra = { ...hit(1, { peerUserId: "9" as UserID, spaceId: "3" as SpaceID }), cursor: "c1" } as SearchMessageHit
    await answer(request!.sub, {
      kind: "search",
      status: "done",
      result: { kind: "messages", hits: [extra, hit(2, { fromId: undefined, snippetRanges: undefined })], indexComplete: true, truncated: false },
    })
    const hits = await promise
    expect(hits).toEqual([
      {
        chatId: "7",
        messageId: "1",
        chatTitle: "Design",
        peerUserId: "9",
        spaceId: "3",
        fromId: "2",
        date: 1_700_000_001,
        snippet: "deploy 1",
        snippetRanges: [[0, 6]],
      },
      { chatId: "7", messageId: "2", chatTitle: "Design", date: 1_700_000_002, snippet: "deploy 2" },
    ])
    // Fields the core may add never leak into the model's hits.
    expect("cursor" in (hits[0] as object)).toBe(false)
    expect(Object.keys(hits[1] as object)).not.toContain("fromId")
    expect(source.resultsComplete.peek()).toBe(true)
    expect(source.stats()).toEqual({ answered: 1, cancelled: 0, failed: 0 })
  })

  it("omits the space when the request has none", () => {
    const { client, subscribed } = setup()
    const source = createCoreMessageSource({ client })
    void source.search({ query: "de", limit: 20, includeArchived: true, sort: "relevance" }, new AbortController().signal)
    expect(subscribed()[0]?.query).toEqual({
      kind: "searchMessages",
      request: { query: "de", limit: 20, includeArchived: true, sort: "relevance" },
    })
  })

  it("reports an incomplete index from the answer and from the core resource", async () => {
    const { client, subscribed, answer } = setup()
    const core = signal<CoreResource | undefined>({
      kind: "core",
      phase: "ready",
      connection: "connected",
      storage: "persistent",
      buildId: "b",
      searchIndex: { state: "building", indexed: 40, total: 100 },
    })
    const source = createCoreMessageSource({ client, coreResource: core })
    expect(source.searchIndex.get()).toEqual({ state: "building", indexed: 40, total: 100 })
    expect(source.resultsComplete.get()).toBeUndefined()
    const promise = source.search({ query: "deploy", limit: 20, includeArchived: true, sort: "newest" }, new AbortController().signal)
    await answer(subscribed()[0]!.sub, {
      kind: "search",
      status: "done",
      result: { kind: "messages", hits: [hit(1)], indexComplete: false, truncated: false },
    })
    await promise
    expect(source.resultsComplete.get()).toBe(false)
    core.set({ ...core.peek()!, searchIndex: { state: "ready" } })
    expect(source.searchIndex.get()).toEqual({ state: "ready" })
  })

  it("aborting the model's signal cancels the core request", async () => {
    const { client, live } = setup()
    const source = createCoreMessageSource({ client })
    const abort = new AbortController()
    const promise = source.search({ query: "deploy", limit: 20, includeArchived: true, sort: "newest" }, abort.signal)
    expect(live().size).toBe(1)
    abort.abort()
    expect(live().size).toBe(0)
    await expect(promise).rejects.toSatisfy(isAbortError)
    expect(source.stats()).toEqual({ answered: 0, cancelled: 1, failed: 0 })
  })

  it("counts a failure", async () => {
    const { client, subscribed, answer } = setup()
    const source = createCoreMessageSource({ client })
    const promise = source.search({ query: "deploy", limit: 20, includeArchived: true, sort: "newest" }, new AbortController().signal)
    await answer(subscribed()[0]!.sub, { kind: "search", status: "failed", reason: "storage" })
    await expect(promise).rejects.toBeInstanceOf(CoreSearchError)
    expect(source.stats()).toEqual({ answered: 0, cancelled: 0, failed: 1 })
  })
})

describe("createNoopRemoteSource", () => {
  it("finds nothing and honors an aborted signal", async () => {
    const remote = createNoopRemoteSource()
    await expect(remote.search({ query: "ada", limit: 20 }, new AbortController().signal)).resolves.toEqual({ users: [] })
    const abort = new AbortController()
    abort.abort()
    await expect(remote.search({ query: "ada", limit: 20 }, abort.signal)).rejects.toSatisfy(isAbortError)
  })
})

// ---------------------------------------------------------------------------
// Server people

const person = (id: number, firstName: string, username?: string): UserRow => ({
  kind: "user",
  id: userId(id),
  firstName,
  ...(username ? { username } : {}),
})

const remoteDone = (users: UserRow[]): RemoteSearchResource => ({ kind: "remoteSearch", status: "done", result: { kind: "users", users } })

describe("coreRemoteRequest", () => {
  it("resolves the first remoteSearch answer and unsubscribes; failure carries the reason", async () => {
    const { client, subscribed, live, answer } = setup()
    const ok = coreRemoteRequest(client, { kind: "searchUsers", request: { query: "ada" } })
    await answer(subscribed()[0]!.sub, remoteDone([person(10, "Ada")]))
    await expect(ok).resolves.toEqual({ kind: "users", users: [person(10, "Ada")] })
    const failed = coreRemoteRequest(client, { kind: "searchUsers", request: { query: "ada" } })
    await answer(subscribed()[1]!.sub, { kind: "remoteSearch", status: "failed", reason: "offline" })
    const error = await failed.catch((e: unknown) => e)
    expect(error).toBeInstanceOf(CoreRemoteSearchError)
    expect((error as CoreRemoteSearchError).reason).toBe("offline")
    expect(live().size).toBe(0)
  })
})

describe("createCoreRemoteSource", () => {
  it("asks searchUsers without the leading @, capped at 20, and dedupes people by ID", async () => {
    const { client, subscribed, answer } = setup()
    const remote = createCoreRemoteSource({ client })
    const promise = remote.search({ query: " @ada ", limit: 50 }, new AbortController().signal)
    expect(subscribed()[0]?.query).toEqual({ kind: "searchUsers", request: { query: "ada", limit: 20 } })
    expect(remote.state.peek()).toEqual({ status: "pending", query: "ada" })
    await answer(subscribed()[0]!.sub, remoteDone([person(10, "Ada"), person(11, "Adam"), person(10, "Ada")]))
    expect(await promise).toEqual({ users: [person(10, "Ada"), person(11, "Adam")] })
    expect(remote.state.peek()).toEqual({ status: "done", query: "ada", count: 2 })
  })

  it("does not ask the server for fewer than two characters", async () => {
    const { client, subscribed } = setup()
    const remote = createCoreRemoteSource({ client })
    await expect(remote.search({ query: "@a", limit: 20 }, new AbortController().signal)).resolves.toEqual({ users: [] })
    expect(subscribed()).toHaveLength(0)
  })

  it("fails quietly: no people, the reason in state", async () => {
    const { client, subscribed, answer } = setup()
    const remote = createCoreRemoteSource({ client })
    const promise = remote.search({ query: "ada", limit: 20 }, new AbortController().signal)
    await answer(subscribed()[0]!.sub, { kind: "remoteSearch", status: "failed", reason: "offline" })
    await expect(promise).resolves.toEqual({ users: [] })
    expect(remote.state.peek()).toEqual({ status: "failed", query: "ada", reason: "offline" })
    expect(remote.stats()).toEqual({ answered: 0, cancelled: 0, failed: 1 })
  })
})

describe("server people in the Quick Search model", () => {
  const rows = (): QuickSearchRows => {
    const ada = person(10, "Ada", "ada")
    const dm: ChatRow = { kind: "chat", id: chatId(1), peerUserId: ada.id, lastActivityDate: 10 }
    const dmDialog: DialogRow = {
      kind: "dialog",
      id: dialogId(1),
      chatId: chatId(1),
      peerUserId: ada.id,
      pinned: false,
      archived: false,
      open: true,
      unreadCount: 0,
      unreadMark: false,
    }
    return {
      dialogs: [dmDialog],
      chat: (id) => (id === dm.id ? dm : undefined),
      user: (id) => (id === ada.id ? ada : undefined),
      space: () => undefined,
      users: [ada],
      spaces: [],
    }
  }

  const harness = () => {
    const base = setup()
    const remote = createCoreRemoteSource({ client: base.client })
    const model = new QuickSearchModel({ clock: base.time, local: createRowLocalSource(signal(rows())), remote })
    const searchUsers = () => base.subscribed().filter((entry) => entry.query.kind === "searchUsers")
    return { ...base, remote, model, searchUsers }
  }

  it("waits 250 ms after the last keystroke (the Mac's delay) before asking the server", () => {
    const { model, time, searchUsers } = harness()
    model.open()
    model.setQuery("ad")
    time.advance(200)
    model.setQuery("ada")
    time.advance(249)
    expect(searchUsers()).toHaveLength(0)
    time.advance(1)
    expect(searchUsers().map((entry) => entry.query)).toEqual([{ kind: "searchUsers", request: { query: "ada", limit: 20 } }])
  })

  it("cancels the request in flight on a new query and never shows its answer", async () => {
    const { model, time, searchUsers, live, answer, endpoint } = harness()
    model.open()
    model.setQuery("ada")
    time.advance(250)
    const first = searchUsers()[0]!.sub
    model.setQuery("gra")
    expect(endpoint.commands("unsubscribe")).toContainEqual({ kind: "unsubscribe", sub: first })
    // The core answers the cancelled request anyway: nothing shows.
    await answer(first, remoteDone([person(20, "Adalbert")]))
    expect(model.sections.peek().some((section) => section.kind === "global")).toBe(false)
    time.advance(250)
    const second = searchUsers()[1]!.sub
    expect([...live().keys()]).toContain(second)
    await answer(second, remoteDone([person(30, "Grace", "grace")]))
    const global = model.sections.peek().find((section) => section.kind === "global")
    expect(global?.items.map((item) => item.id)).toEqual(["user:30"])
  })

  it("lists server people below the local results, without the people already shown", async () => {
    const { model, time, searchUsers, answer } = harness()
    model.open()
    model.setQuery("ada")
    time.advance(250)
    await answer(searchUsers()[0]!.sub, remoteDone([person(10, "Ada", "ada"), person(40, "Adaline")]))
    const sections = model.sections.peek()
    expect(sections[sections.length - 1]?.kind).toBe("global")
    expect(sections.slice(0, -1).flatMap((section) => section.items.map((item) => item.id))).toContain("user:10")
    expect(sections[sections.length - 1]?.items.map((item) => item.id)).toEqual(["user:40"])
  })

  it("an offline failure keeps the local results and shows no error", async () => {
    const { model, time, searchUsers, answer, remote } = harness()
    model.open()
    model.setQuery("ada")
    const before = model.sections.peek().map((section) => section.kind)
    time.advance(250)
    await answer(searchUsers()[0]!.sub, { kind: "remoteSearch", status: "failed", reason: "offline" })
    expect(model.globalState.peek().status).toBe("done")
    expect(model.sections.peek().map((section) => section.kind)).toEqual(before)
    expect(model.emptyState.peek()).toBe("results")
    expect(remote.state.peek()).toMatchObject({ status: "failed", reason: "offline" })
  })
})

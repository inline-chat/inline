import { describe, expect, it } from "vitest"
import type {
  FindInChatHit,
  FindInChatRequestValue,
  QueryDescriptor,
  RemoteSearchResource,
  SearchResource,
  ServerMessageSearchRequest,
  SubId,
} from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { createScheduler, createStoreClient, manualTime } from "@inline/reactive"
import { scriptedEndpoint } from "@inline/reactive/testing"
import { FindInChatModel, selectionSeed, type FindJump, type FindModelOptions } from "./find-model"
import { coreFindSource, coreServerFindSource, type FindCount, type FindInChatSource, type FindPage } from "./find-source"

const CHAT = "42" as ChatID

const microtasks = async (rounds = 10) => {
  for (let i = 0; i < rounds; i++) await Promise.resolve()
}

const hit = (n: number): FindInChatHit => ({
  messageId: String(n) as MessageID,
  fromId: "2" as UserID,
  date: 1_700_000_000 + n,
  out: false,
  text: `please deploy build ${n}`,
  ranges: [[7, 13]],
  cursor: `c${n}`,
})

/** Hits `from`, `from - 1`, ... newest first. */
const hits = (from: number, count: number): FindInChatHit[] => Array.from({ length: count }, (_, i) => hit(from - i))

const setup = (options: Partial<FindModelOptions> = {}) => {
  const time = manualTime()
  const scheduler = createScheduler({ clock: time, frames: time.frames, idleSource: time.idleSource })
  const endpoint = scriptedEndpoint()
  const client = createStoreClient({ endpoint, scheduler })
  const jumps: FindJump[] = []
  const focus: string[] = []
  const model = new FindInChatModel({
    chatId: CHAT,
    source: coreFindSource(client),
    clock: time,
    jump: (target) => jumps.push(target),
    captureFocus: () => {
      focus.push("capture")
      return () => focus.push("restore")
    },
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
  const pending = (kind: "findInChat" | "countMessages") =>
    [...live()]
      .filter(([, query]) => query.kind === kind)
      .map(([sub, query]) => ({ sub, request: (query as Extract<QueryDescriptor, { kind: "findInChat" | "countMessages" }>).request }))
  const allRequests = (kind: "findInChat" | "countMessages") =>
    endpoint.commands("subscribe").filter((command) => command.query.kind === kind)

  const deliver = async (sub: SubId, value: SearchResource) => {
    endpoint.patch({ resources: [{ sub, value }] })
    time.frame()
    await microtasks()
  }
  /** Answer the live find request (there must be exactly one). */
  const answerFind = async (
    page: FindInChatHit[],
    extra: { hasOlder?: boolean; olderCursor?: string; indexComplete?: boolean; truncated?: boolean } = {},
  ) => {
    const requests = pending("findInChat")
    expect(requests).toHaveLength(1)
    const last = page[page.length - 1]
    await deliver(requests[0]!.sub, {
      kind: "search",
      status: "done",
      result: {
        kind: "findInChat",
        hits: page,
        hasOlder: extra.hasOlder ?? false,
        hasNewer: false,
        ...(extra.olderCursor !== undefined ? { olderCursor: extra.olderCursor } : last && extra.hasOlder ? { olderCursor: last.cursor } : {}),
        indexComplete: extra.indexComplete ?? true,
        truncated: extra.truncated ?? false,
      },
    })
    return requests[0]!.request as FindInChatRequestValue
  }
  const answerCount = async (count: number, capped = false, indexComplete = true) => {
    const requests = pending("countMessages")
    expect(requests).toHaveLength(1)
    await deliver(requests[0]!.sub, { kind: "search", status: "done", result: { kind: "count", count, capped, indexComplete } })
  }
  const fail = async (kind: "findInChat" | "countMessages" = "findInChat") => {
    const requests = pending(kind)
    expect(requests).toHaveLength(1)
    await deliver(requests[0]!.sub, { kind: "search", status: "failed", reason: "storage" })
  }
  /** Open, type, and let the debounce run. */
  const search = (text: string) => {
    if (!model.isOpen.peek()) model.open()
    model.setText(text)
    time.advance(120)
  }
  return { time, endpoint, client, model, jumps, focus, live, pending, allRequests, deliver, answerFind, answerCount, fail, search }
}

describe("FindInChatModel: query and debounce", () => {
  it("asks for the first page and the count 120 ms after the last change", () => {
    const { model, time, pending, allRequests } = setup()
    model.open()
    model.setText("de")
    expect(model.state.get()).toBe("searching")
    time.advance(100)
    model.setText("dep")
    time.advance(100)
    expect(allRequests("findInChat")).toHaveLength(0)
    time.advance(20)
    expect(pending("findInChat").map((r) => r.request)).toEqual([{ chatId: CHAT, query: "dep", direction: "older", limit: 100 }])
    expect(pending("countMessages").map((r) => r.request)).toEqual([{ chatId: CHAT, query: "dep" }])
  })

  it("does not restart for spaces at either end", () => {
    const { model, search, time, allRequests } = setup()
    search("deploy")
    model.setText("  deploy ")
    time.advance(500)
    expect(allRequests("findInChat")).toHaveLength(1)
    expect(model.text.get()).toBe("  deploy ")
    expect(model.query.get()).toBe("deploy")
  })

  it("is idle for an empty query or a single letter, and asks nothing", () => {
    const { model, time, allRequests } = setup()
    model.open()
    model.setText("d")
    time.advance(500)
    expect(model.state.get()).toBe("idle")
    expect(model.showsResults.get()).toBe(false)
    expect(model.counterText.get()).toBeUndefined()
    expect(allRequests("findInChat")).toHaveLength(0)
  })

  it("cancels a superseded query and never shows its late result", async () => {
    const { model, search, pending, live, deliver, answerFind } = setup()
    search("deploy")
    const old = pending("findInChat")[0]!
    search("release")
    // The old request and its count were unsubscribed.
    expect([...live().values()].map((q) => (q as { request: { query: string } }).request.query)).toEqual(["release", "release"])
    // A core that answers the old request anyway changes nothing.
    await deliver(old.sub, {
      kind: "search",
      status: "done",
      result: { kind: "findInChat", hits: hits(10, 3), hasOlder: false, hasNewer: false, indexComplete: true, truncated: false },
    })
    expect(model.hits.get()).toEqual([])
    expect(model.state.get()).toBe("searching")
    await answerFind([hit(5)])
    expect(model.hits.get().map((h) => h.messageId)).toEqual(["5"])
  })

  it("drops a result for an older query even if the source ignored the abort", async () => {
    const calls: { query: string; resolve: (page: FindPage) => void }[] = []
    const source: FindInChatSource = {
      find: (request) => new Promise((resolve) => calls.push({ query: request.query, resolve })),
      count: () => new Promise<FindCount>(() => {}),
    }
    const { model, search } = setup({ source })
    search("deploy")
    search("release")
    calls[0]!.resolve({ hits: hits(9, 2), hasOlder: false, indexComplete: true, truncated: false })
    await microtasks()
    expect(model.hits.get()).toEqual([])
    calls[1]!.resolve({ hits: [hit(3)], hasOlder: false, indexComplete: true, truncated: false })
    await microtasks()
    expect(model.hits.get().map((h) => h.messageId)).toEqual(["3"])
  })

  it("keeps the previous query's matches listed, unstepable, until the new first page", async () => {
    const { model, search, answerFind, jumps } = setup()
    search("deploy")
    await answerFind(hits(10, 3))
    model.setText("deploys")
    expect(model.stale.get()).toBe(true)
    expect(model.hits.get()).toHaveLength(3)
    expect(model.state.get()).toBe("searching")
    expect(model.currentIndex.get()).toBeUndefined()
    expect(model.canGoOlder.get()).toBe(false)
    model.activate(model.hits.get()[1]!)
    expect(jumps).toEqual([])
  })
})

describe("FindInChatModel: count, position and stepping", () => {
  it("selects the newest match, counts, and steps with jumps carrying the ranges", async () => {
    const { model, search, answerFind, answerCount, jumps } = setup()
    search("deploy")
    await answerFind(hits(10, 3))
    expect(model.state.get()).toBe("results")
    expect(model.current.get()?.messageId).toBe("10")
    // The list shows: the newest is chosen but the chat does not move yet.
    expect(model.showsResults.get()).toBe(true)
    expect(jumps).toEqual([])
    expect(model.counterText.get()).toBe("3 messages")
    await answerCount(128)
    expect(model.total.get()).toEqual({ count: 128, capped: false })
    expect(model.counterText.get()).toBe("128 messages")

    // Enter over the list shows the chosen match in the chat.
    model.submit()
    expect(model.showsResults.get()).toBe(false)
    expect(jumps).toEqual([{ chatId: CHAT, messageId: "10", ranges: [[7, 13]], query: "deploy" }])
    expect(model.position.get()).toEqual({ index: 1, total: 128, capped: false })
    expect(model.counterText.get()).toBe("1 of 128")

    model.next()
    expect(model.counterText.get()).toBe("2 of 128")
    expect(jumps.at(-1)?.messageId).toBe("9")
    model.previous()
    expect(jumps.at(-1)?.messageId).toBe("10")
    expect(jumps).toHaveLength(3)
  })

  it("shows a capped count with a plus", async () => {
    const { model, search, answerFind, answerCount } = setup()
    search("deploy")
    await answerFind(hits(20_000, 100), { hasOlder: true })
    await answerCount(10_000, true)
    model.submit()
    expect(model.counterText.get()).toBe("1 of 10,000+")
    expect(model.position.get()).toEqual({ index: 1, total: 10_000, capped: true })
  })

  it("never shows a total below what is loaded, and without a count shows what is loaded", async () => {
    const { model, search, answerFind, answerCount, fail } = setup()
    search("deploy")
    await answerFind(hits(10, 5))
    await fail("countMessages")
    model.submit()
    expect(model.counterText.get()).toBe("1 of 5")
    search("release")
    await answerFind(hits(10, 5))
    await answerCount(2)
    expect(model.total.get()).toEqual({ count: 5, capped: false })
  })

  it("does not wrap around at either end", async () => {
    const { model, search, answerFind, jumps } = setup()
    search("deploy")
    await answerFind(hits(10, 2))
    model.submit()
    expect(model.canGoNewer.get()).toBe(false)
    model.previous()
    expect(jumps.map((j) => j.messageId)).toEqual(["10"])
    model.next()
    expect(model.canGoOlder.get()).toBe(false)
    model.next()
    expect(jumps.map((j) => j.messageId)).toEqual(["10", "9"])
    expect(model.counterText.get()).toBe("2 of 2")
  })

  it("moves through the list without jumping, then jumps when the list hides", async () => {
    const { model, search, answerFind, jumps } = setup()
    search("deploy")
    await answerFind(hits(10, 5))
    model.moveActive(1)
    model.moveActive(1)
    model.moveActive(-1)
    expect(model.current.get()?.messageId).toBe("9")
    expect(jumps).toEqual([])
    model.setShowsResults(false)
    expect(jumps.map((j) => j.messageId)).toEqual(["9"])
    // Re-showing and hiding the list without moving does not jump again.
    model.toggleResults()
    model.toggleResults()
    expect(jumps).toHaveLength(1)
  })

  it("activates a preview: it becomes current, the list hides, the chat jumps", async () => {
    const { model, search, answerFind, jumps } = setup()
    search("deploy")
    await answerFind(hits(10, 5))
    model.activate(model.hits.get()[3]!)
    expect(model.showsResults.get()).toBe(false)
    expect(model.position.get()?.index).toBe(4)
    expect(jumps.map((j) => j.messageId)).toEqual(["7"])
  })

  it("a step made before any match loaded lands on the newest match", async () => {
    const { model, answerFind, jumps, time } = setup()
    model.open()
    model.setText("deploy")
    model.submit()
    time.advance(120)
    await answerFind(hits(10, 3))
    expect(jumps.map((j) => j.messageId)).toEqual(["10"])
    expect(model.showsResults.get()).toBe(false)
    // Later pages no longer move the selection.
    model.next()
    expect(jumps.map((j) => j.messageId)).toEqual(["10", "9"])
  })
})

describe("FindInChatModel: paging", () => {
  it("loads the next page when a step goes past the loaded matches", async () => {
    const { model, search, answerFind, pending, jumps } = setup()
    search("deploy")
    const first = await answerFind(hits(1000, 100), { hasOlder: true })
    expect(first.cursor).toBeUndefined()
    model.submit()
    for (let i = 0; i < 99; i++) model.next()
    expect(model.position.get()?.index).toBe(100)
    expect(model.canGoOlder.get()).toBe(true)
    model.next()
    // Waiting for the page: nothing moved yet.
    expect(model.position.get()?.index).toBe(100)
    expect(pending("findInChat").map((r) => r.request)).toEqual([
      { chatId: CHAT, query: "deploy", cursor: "c901", direction: "older", limit: 100 },
    ])
    expect(model.loadingMore.get()).toBe(true)
    await answerFind(hits(900, 50))
    expect(model.hits.get()).toHaveLength(150)
    expect(model.position.get()?.index).toBe(101)
    expect(jumps.at(-1)?.messageId).toBe("900")
    expect(model.hasOlder.get()).toBe(false)
  })

  it("prefetches when the list shows a row near the end, once at a time", async () => {
    const { model, search, answerFind, pending } = setup()
    search("deploy")
    await answerFind(hits(1000, 100), { hasOlder: true })
    model.loadMoreIfNeeded(50)
    expect(pending("findInChat")).toHaveLength(0)
    model.loadMoreIfNeeded(90)
    model.loadMoreIfNeeded(95)
    expect(pending("findInChat")).toHaveLength(1)
    await answerFind(hits(900, 100), { hasOlder: true })
    expect(model.hits.get()).toHaveLength(200)
    // The selection stays on the match the user had (the newest), and nothing jumped while the list shows.
    expect(model.current.get()?.messageId).toBe("1000")
  })

  it("stops paging when the cursor does not move", async () => {
    const { model, search, answerFind, pending } = setup()
    search("deploy")
    await answerFind(hits(1000, 100), { hasOlder: true, olderCursor: "same" })
    model.loadMoreIfNeeded(99)
    await answerFind(hits(900, 10), { hasOlder: true, olderCursor: "same" })
    expect(model.hasOlder.get()).toBe(false)
    model.loadMoreIfNeeded(109)
    expect(pending("findInChat")).toHaveLength(0)
  })

  it("follows empty pages from a capped source until a match, a bounded number of times", async () => {
    const { model, search, answerFind } = setup({ timing: { maxEmptyPages: 2 } })
    search("deploy")
    await answerFind([], { hasOlder: true, olderCursor: "a", truncated: true })
    expect(model.state.get()).toBe("searching")
    await answerFind([], { hasOlder: true, olderCursor: "b", truncated: true })
    await answerFind([], { hasOlder: true, olderCursor: "c", truncated: true })
    expect(model.state.get()).toBe("noResults")
    expect(model.hasOlder.get()).toBe(false)

    search("release")
    await answerFind([], { hasOlder: true, olderCursor: "a", truncated: true })
    await answerFind([hit(4)])
    expect(model.state.get()).toBe("results")
  })
})

describe("FindInChatModel: states", () => {
  it("says the index is incomplete when nothing matched while indexing", async () => {
    const { model, search, answerFind } = setup()
    search("deploy")
    await answerFind([], { indexComplete: false })
    expect(model.state.get()).toBe("indexIncomplete")
    expect(model.indexComplete.get()).toBe(false)
    expect(model.counterText.get()).toBe("No results")
    search("release")
    await answerFind([hit(3)], { indexComplete: false })
    expect(model.state.get()).toBe("results")
    expect(model.indexComplete.get()).toBe(false)
    search("other")
    await answerFind([])
    expect(model.state.get()).toBe("noResults")
  })

  it("reports a failed first page and recovers on retry", async () => {
    const { model, search, answerFind, fail, pending } = setup()
    search("deploy")
    await fail()
    expect(model.state.get()).toBe("error")
    expect(model.counterText.get()).toBeUndefined()
    model.retry()
    expect(pending("findInChat")).toHaveLength(1)
    await answerFind([hit(3)])
    expect(model.state.get()).toBe("results")
  })

  it("keeps loaded matches when a later page fails", async () => {
    const { model, search, answerFind, fail, pending } = setup()
    search("deploy")
    await answerFind(hits(1000, 100), { hasOlder: true })
    model.loadMoreIfNeeded(99)
    await fail()
    expect(model.state.get()).toBe("results")
    expect(model.pagingFailed.get()).toBe(true)
    expect(model.hits.get()).toHaveLength(100)
    model.retry()
    expect(model.pagingFailed.get()).toBe(false)
    expect(pending("findInChat")[0]?.request).toMatchObject({ cursor: "c901" })
  })

  it("a failure while the previous query's matches show clears them", async () => {
    const { model, search, answerFind, fail } = setup()
    search("deploy")
    await answerFind(hits(10, 3))
    search("release")
    await fail()
    expect(model.state.get()).toBe("error")
    expect(model.hits.get()).toEqual([])
  })
})

describe("FindInChatModel: open, close, focus", () => {
  it("opens seeded with the selection's first line", () => {
    const { model, time, pending } = setup()
    model.open({ seed: "  deploy   the\nbuild  " })
    expect(model.isOpen.get()).toBe(true)
    expect(model.text.get()).toBe("deploy the")
    time.advance(120)
    expect(pending("findInChat")[0]?.request.query).toBe("deploy the")
  })

  it("open while open requests focus again and keeps the first focus to restore", () => {
    const { model, focus } = setup()
    model.open()
    const first = model.focusRequest.get()
    model.setText("deploy")
    model.open()
    expect(model.focusRequest.get()).toBe(first + 1)
    expect(model.text.get()).toBe("deploy")
    model.open({ seed: "release" })
    expect(model.text.get()).toBe("release")
    expect(focus).toEqual(["capture"])
  })

  it("close cancels everything, clears the query and restores focus through the callback", async () => {
    const closed: string[] = []
    const { model, search, answerFind, live, focus, time } = setup({ onClose: () => closed.push("closed") })
    search("deploy")
    await answerFind(hits(10, 3))
    model.setFieldFocused(true)
    search("release")
    model.close()
    expect(model.isOpen.get()).toBe(false)
    expect(model.text.get()).toBe("")
    expect(model.hits.get()).toEqual([])
    expect(model.state.get()).toBe("idle")
    expect(model.fieldFocused.get()).toBe(false)
    expect(live().size).toBe(0)
    expect(focus).toEqual(["capture", "restore"])
    expect(closed).toEqual(["closed"])
    expect(time.pendingTimers()).toBe(0)
    // Closing again does nothing.
    model.close()
    expect(focus).toEqual(["capture", "restore"])
  })

  it("does nothing after dispose", () => {
    const { model, time, allRequests } = setup()
    model.open()
    model.setText("deploy")
    model.dispose()
    time.advance(500)
    expect(allRequests("findInChat")).toHaveLength(0)
    model.open()
    expect(model.isOpen.get()).toBe(false)
  })
})

describe("selectionSeed", () => {
  it("takes the first line, collapses spaces, caps the length without splitting a pair", () => {
    expect(selectionSeed(undefined)).toBeUndefined()
    expect(selectionSeed(" \n ")).toBeUndefined()
    expect(selectionSeed("a  b\r\nc")).toBe("a b")
    expect(selectionSeed("x".repeat(200))).toHaveLength(128)
    const emoji = `${"x".repeat(127)}😀tail`
    expect(selectionSeed(emoji)).toBe("x".repeat(127))
  })
})

describe("FindInChatModel: server hits", () => {
  const serverSetup = () => {
    const base = setup()
    const model = new FindInChatModel({
      chatId: CHAT,
      source: coreFindSource(base.client),
      server: coreServerFindSource(base.client),
      clock: base.time,
      jump: (target) => base.jumps.push(target),
    })
    base.model.dispose()
    const serverRequests = () =>
      [...base.live()]
        .filter(([, query]) => query.kind === "searchServerMessages")
        .map(([sub, query]) => ({ sub, request: (query as Extract<QueryDescriptor, { kind: "searchServerMessages" }>).request }))
    const pages = () => serverRequests().filter((entry) => entry.request.countOnly !== true)
    const deliverRemote = async (sub: SubId, value: RemoteSearchResource) => {
      base.endpoint.patch({ resources: [{ sub, value }] })
      base.time.frame()
      await microtasks()
    }
    const answerServer = async (page: FindInChatHit[], nextOffsetId?: string): Promise<ServerMessageSearchRequest> => {
      const live = pages()
      expect(live).toHaveLength(1)
      const hitsOut = page.map(({ cursor: _cursor, ...rest }) => rest)
      await deliverRemote(live[0]!.sub, {
        kind: "remoteSearch",
        status: "done",
        result: { kind: "messages", chatId: CHAT, hits: hitsOut, ...(nextOffsetId !== undefined ? { nextOffsetId: nextOffsetId as MessageID } : {}) },
      })
      return live[0]!.request
    }
    const answerServerCount = async (count: number) => {
      const live = serverRequests().filter((entry) => entry.request.countOnly === true)
      expect(live).toHaveLength(1)
      await deliverRemote(live[0]!.sub, { kind: "remoteSearch", status: "done", result: { kind: "count", chatId: CHAT, count } })
    }
    const failServer = async () => {
      const live = pages()
      expect(live).toHaveLength(1)
      await deliverRemote(live[0]!.sub, { kind: "remoteSearch", status: "failed", reason: "offline" })
    }
    const search = (text: string) => {
      if (!model.isOpen.peek()) model.open()
      model.setText(text)
      base.time.advance(120)
    }
    const ids = () => model.hits.peek().map((hit) => hit.messageId)
    return { ...base, model, serverRequests, pages, deliverRemote, answerServer, answerServerCount, failServer, search, ids }
  }

  it("local only: device matches show at once, before the server is asked; the server's copies of them change nothing", async () => {
    const { model, search, answerFind, pages, answerServer, time, ids } = serverSetup()
    search("deploy")
    await answerFind(hits(100, 3))
    expect(model.state.get()).toBe("results")
    expect(ids()).toEqual(["100", "99", "98"])
    expect(pages()).toHaveLength(0)
    expect(model.serverSearching.get()).toBe(true)
    const before = model.hits.peek()
    time.advance(230)
    expect(pages().map((entry) => entry.request)).toEqual([{ chatId: CHAT, query: "deploy", limit: 100 }])
    await answerServer(hits(100, 3))
    expect(model.hits.peek()).toBe(before)
    expect(model.hits.peek().some((hit) => hit.remote)).toBe(false)
    expect(model.hasOlder.get()).toBe(false)
    expect(model.serverSearching.get()).toBe(false)
  })

  it("server adds older hits: merged by message ID, the active match and its index stay, a step reaches them through jump", async () => {
    const { model, search, answerFind, answerCount, answerServer, answerServerCount, time, pages, jumps, ids } = serverSetup()
    search("deploy")
    await answerFind(hits(100, 3))
    await answerCount(3)
    model.next() // from the newest (100) to 99
    expect(model.currentIndex.get()).toBe(1)
    time.advance(230)
    await answerServer([hit(99), hit(98), hit(50), hit(49)], "49")
    await answerServerCount(240)
    expect(ids()).toEqual(["100", "99", "98", "50", "49"])
    expect(model.current.get()?.messageId).toBe("99")
    expect(model.currentIndex.get()).toBe(1)
    expect(model.hits.peek()[3]?.remote).toBe(true)
    expect(model.hits.peek()[1]?.remote).toBeUndefined()
    expect(model.total.get()).toEqual({ count: 240, capped: false })
    expect(model.hasOlder.get()).toBe(true)
    model.next() // 98
    model.next() // 50, from the server
    expect(jumps.at(-1)).toMatchObject({ messageId: "50", query: "deploy" })
    model.next() // 49
    model.next() // past the loaded matches: the server's next page
    expect(pages().map((entry) => entry.request.offsetId)).toEqual(["49"])
    await answerServer([hit(20)])
    expect(jumps.at(-1)?.messageId).toBe("20")
    expect(model.hasOlder.get()).toBe(false)
    expect(model.canGoOlder.get()).toBe(false)
  })

  it("a step at the oldest local match asks the server at once rather than after the debounce", async () => {
    const { model, search, answerFind, pages, answerServer, jumps } = serverSetup()
    search("deploy")
    await answerFind(hits(100, 2))
    model.next()
    model.next()
    expect(model.current.get()?.messageId).toBe("99")
    model.next()
    expect(pages()).toHaveLength(1)
    expect(jumps.at(-1)?.messageId).toBe("99")
    await answerServer([hit(40)])
    expect(jumps.at(-1)?.messageId).toBe("40")
  })

  it("server fails: quiet, local matches stay, retry asks again", async () => {
    const { model, search, answerFind, failServer, time, answerServer, ids } = serverSetup()
    search("deploy")
    await answerFind(hits(100, 2))
    time.advance(230)
    await failServer()
    expect(model.serverFailed.get()).toBe(true)
    expect(model.state.get()).toBe("results")
    expect(ids()).toEqual(["100", "99"])
    expect(model.hasOlder.get()).toBe(false)
    model.next()
    model.next()
    expect(model.canGoOlder.get()).toBe(false)
    model.retry()
    expect(model.serverFailed.get()).toBe(false)
    await answerServer([hit(30)])
    expect(ids()).toEqual(["100", "99", "30"])
  })

  it("nothing on the device: searching until the server answers, then its matches or no results", async () => {
    const { model, search, answerFind, answerServer, failServer, time } = serverSetup()
    search("deploy")
    await answerFind([])
    expect(model.state.get()).toBe("searching")
    time.advance(230)
    await answerServer([hit(7)])
    expect(model.state.get()).toBe("results")
    expect(model.current.get()?.messageId).toBe("7")
    search("deplox")
    await answerFind([])
    time.advance(230)
    await failServer()
    expect(model.state.get()).toBe("noResults")
    expect(model.hits.get()).toEqual([])
  })

  it("the query changes while a server page is in flight: it is cancelled and a late answer is dropped", async () => {
    const { model, search, answerFind, pages, deliverRemote, answerServer, time, ids, endpoint } = serverSetup()
    search("deploy")
    await answerFind(hits(100, 2))
    time.advance(230)
    const [inFlight] = pages()
    expect(inFlight).toBeDefined()
    model.setText("release")
    expect(endpoint.commands("unsubscribe").map((command) => command.sub)).toContain(inFlight!.sub)
    await deliverRemote(inFlight!.sub, {
      kind: "remoteSearch",
      status: "done",
      result: { kind: "messages", chatId: CHAT, hits: [{ ...hit(5), text: "deploy" }].map(({ cursor: _c, ...rest }) => rest) },
    })
    expect(ids().includes("5" as MessageID)).toBe(false)
    time.advance(120)
    await answerFind([hit(90)])
    time.advance(230)
    const request = await answerServer([hit(60)])
    expect(request.query).toBe("release")
    expect(ids()).toEqual(["90", "60"])
  })
})

import {
  Db,
  DbObjectKind,
  messageKey,
  type Dialog,
  type Message,
} from "@inline/client/core"
import {
  chatId,
  dialogId,
  messageId,
  userId,
} from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  INLINE_CORE_PROTOCOL_VERSION,
  type InlineCoreSnapshot,
} from "../inline/core/InlineCoreProtocol"
import type { InlineRuntimeCore } from "../inline/runtime/InlineRuntimeCore"
import {
  ChatOpenPreloader,
  likelyVisibleMessagesForChatOpen,
} from "./ChatOpenPreloader"
import { ChatOpenPerformance } from "./ChatOpenPerformance"

const peer = { peerKind: "chat", peerId: chatId(10) } as const

const makeDatabase = () => {
  const db = new Db({ autoHydrate: false, persistence: false })
  const dialog: Dialog = {
    kind: DbObjectKind.Dialog,
    id: dialogId(100),
    chatId: chatId(10),
    peerThreadId: chatId(10),
  }
  const messages: Message[] = [1, 2].map((id) => ({
    kind: DbObjectKind.Message,
    id: messageKey(chatId(10), messageId(id)),
    messageId: messageId(id),
    chatId: chatId(10),
    fromId: userId(7),
    message: `message ${id}`,
    date: id,
  }))
  db.batch(() => {
    db.insert(dialog)
    for (const message of messages) db.insert(message)
  })
  return db
}

const makeCore = (
  db: Db,
  initialSnapshot?: Partial<InlineCoreSnapshot>,
) => {
  let snapshot: InlineCoreSnapshot = {
    protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
    ownerId: "preloader-test-owner",
    accountId: userId(7),
    phase: "cacheReady",
    cacheReady: true,
    connectionState: "idle",
    ...initialSnapshot,
  }
  const listeners = new Set<() => void>()
  const releaseChat = vi.fn()
  const activateChat = vi.fn(() => releaseChat)
  const query = vi.fn(async () => undefined)
  const loadMessageReferences = vi.fn(async () => [])
  const promoteCached = vi.fn(async (_key: string) => true)
  const core = {
    client: { db, realtime: { query } },
    mediaRepository: { promoteCached },
    fullChatProgressive: { activateChat },
    messageReferences: { load: loadMessageReferences },
    start: vi.fn(async () => undefined),
    getSnapshot: () => snapshot,
    subscribe: (listener: () => void) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  } as unknown as InlineRuntimeCore
  return {
    core,
    activateChat,
    releaseChat,
    query,
    loadMessageReferences,
    promoteCached,
    setSnapshot(next: Partial<InlineCoreSnapshot>) {
      snapshot = { ...snapshot, ...next }
      for (const listener of listeners) listener()
    },
  }
}

const activePreloaders: ChatOpenPreloader[] = []

afterEach(() => {
  for (const preloader of activePreloaders.splice(0)) {
    preloader.clear()
  }
  vi.useRealTimers()
})

describe("ChatOpenPreloader", () => {
  it("matches Inline macOS's bounded latest and target-biased first-presentation windows", () => {
    const messages: Message[] = Array.from(
      { length: 20 },
      (_, index) => {
        const id = index + 1
        return {
          kind: DbObjectKind.Message,
          id: messageKey(chatId(10), messageId(id)),
          messageId: messageId(id),
          chatId: chatId(10),
          fromId: userId(7),
          date: id,
        }
      },
    )

    expect(
      likelyVisibleMessagesForChatOpen(messages).map(
        (message) => message.messageId,
      ),
    ).toEqual(Array.from({ length: 12 }, (_, index) => messageId(index + 9)))
    expect(
      likelyVisibleMessagesForChatOpen(
        messages,
        messageId(10),
      ).map((message) => message.messageId),
    ).toEqual(Array.from({ length: 12 }, (_, index) => messageId(index + 6)))
  })

  it("deduplicates intent and route loads while retaining one core owner", async () => {
    const db = makeDatabase()
    const order: string[] = []
    const hydrate = vi
      .spyOn(db, "hydrateMessageWindow")
      .mockImplementation(async () => {
        order.push("hydrate")
        return 0
      })
    const { core, activateChat, releaseChat } = makeCore(db)
    activateChat.mockImplementation(() => {
      order.push("activate")
      return releaseChat
    })
    const release = vi.fn()
    const acquireCore = vi.fn(() => ({ core, release }))
    const preloader = new ChatOpenPreloader({
      acquireCore,
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    const [intent, route] = await Promise.all([
      preloader.prepare(userId(7), peer),
      preloader.prepare(userId(7), peer),
    ])

    expect(intent).toEqual(route)
    expect(intent).toEqual(
      expect.objectContaining({
        preparationId: "prepared-chat-1",
        peer,
        accountId: userId(7),
        dialogId: dialogId(100),
        chatId: chatId(10),
        preparedMessageIds: [messageId(1), messageId(2)],
        source: "latest",
        preparedMessageCount: 2,
      }),
    )
    expect(acquireCore).toHaveBeenCalledOnce()
    expect(activateChat).toHaveBeenCalledOnce()
    expect(activateChat).toHaveBeenCalledWith(chatId(10))
    expect(order).toEqual(["activate", "hydrate"])
    expect(hydrate).toHaveBeenCalledOnce()
    expect(hydrate).toHaveBeenCalledWith(chatId(10), {
      limit: 60,
    })
    expect(release).not.toHaveBeenCalled()
    expect(releaseChat).not.toHaveBeenCalled()

    preloader.clear()
    expect(releaseChat).toHaveBeenCalledOnce()
    expect(release).toHaveBeenCalledOnce()
  })

  it("hands the prepared projection lease to the mounted chat exactly once", async () => {
    const db = makeDatabase()
    vi.spyOn(db, "hydrateMessageWindow").mockResolvedValue(0)
    const state = makeCore(db)
    const releaseCore = vi.fn()
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({
        core: state.core,
        release: releaseCore,
      }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)
    const prepared = await preloader.prepare(userId(7), peer)
    expect(prepared).toBeDefined()

    expect(preloader.releasePreparedLease(prepared!)).toBe(true)
    expect(state.releaseChat).toHaveBeenCalledOnce()
    expect(releaseCore).toHaveBeenCalledOnce()
    expect(preloader.releasePreparedLease(prepared!)).toBe(false)

    preloader.clear()
    expect(state.releaseChat).toHaveBeenCalledOnce()
    expect(releaseCore).toHaveBeenCalledOnce()
  })

  it("exposes only a completed intent presentation without making the route wait", async () => {
    const db = makeDatabase()
    let finishHydration!: () => void
    let markHydrationStarted!: () => void
    const hydrationStarted = new Promise<void>((resolve) => {
      markHydrationStarted = resolve
    })
    vi.spyOn(db, "hydrateMessageWindow").mockImplementation(
      () => new Promise<number>((resolve) => {
        markHydrationStarted()
        finishHydration = () => resolve(0)
      }),
    )
    const state = makeCore(db)
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core: state.core, release: vi.fn() }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    const intent = preloader.prepare(userId(7), peer)
    await hydrationStarted
    expect(
      preloader.preparedPresentation(userId(7), peer),
    ).toBeUndefined()

    finishHydration()
    const prepared = await intent
    expect(
      preloader.preparedPresentation(userId(7), peer),
    ).toBe(prepared)
  })

  it("never reuses a prepared chat projection across Inline accounts", async () => {
    const first = makeCore(makeDatabase())
    const second = makeCore(makeDatabase())
    const firstRelease = vi.fn()
    const secondRelease = vi.fn()
    const acquireCore = vi.fn((accountId) =>
      accountId === userId(7)
        ? { core: first.core, release: firstRelease }
        : { core: second.core, release: secondRelease },
    )
    const preloader = new ChatOpenPreloader({
      acquireCore,
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    const [firstAccount, secondAccount] = await Promise.all([
      preloader.prepare(userId(7), peer),
      preloader.prepare(userId(8), peer),
    ])

    expect(firstAccount?.accountId).toBe(userId(7))
    expect(secondAccount?.accountId).toBe(userId(8))
    expect(acquireCore).toHaveBeenCalledTimes(2)
    expect(first.activateChat).toHaveBeenCalledOnce()
    expect(second.activateChat).toHaveBeenCalledOnce()

    preloader.clear()
    expect(firstRelease).toHaveBeenCalledOnce()
    expect(secondRelease).toHaveBeenCalledOnce()
  })

  it("lets a genuinely cold direct route mount without waiting for realtime", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    vi.spyOn(db, "hydrateMessageWindow").mockResolvedValue(0)
    const state = makeCore(db)
    state.query.mockImplementation(() => new Promise(() => undefined))
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core: state.core, release: vi.fn() }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    await expect(preloader.prepare(userId(7), peer)).resolves.toBeUndefined()
    expect(state.query).not.toHaveBeenCalled()
    expect(state.activateChat).not.toHaveBeenCalled()
    expect(db.hydrateMessageWindow).not.toHaveBeenCalled()
  })

  it("hands an empty cached projection to the view without waiting for history", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    db.batch(() => {
      db.insert({
        kind: DbObjectKind.Dialog,
        id: dialogId(100),
        chatId: chatId(10),
        peerThreadId: chatId(10),
      })
      db.insert({
        kind: DbObjectKind.Chat,
        id: chatId(10),
        title: "Cached thread",
        lastMsgId: messageId(3),
        date: 3,
      })
    })
    const hydrate = vi
      .spyOn(db, "hydrateMessageWindow")
      .mockResolvedValueOnce(0)
    const state = makeCore(db)
    state.query.mockImplementation(() => new Promise(() => undefined))
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core: state.core, release: vi.fn() }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    await expect(preloader.prepare(userId(7), peer)).resolves.toEqual(
      expect.objectContaining({
        preparedMessageIds: [],
        preparedMessageCount: 0,
        needsHistoryRefresh: true,
      }),
    )
    expect(state.query).not.toHaveBeenCalled()
    expect(hydrate).toHaveBeenCalledOnce()
  })

  it("does not make an off-window pinned reference a route-readiness dependency", async () => {
    const db = makeDatabase()
    db.insert({
      kind: DbObjectKind.Chat,
      id: chatId(10),
      title: "Pinned thread",
      pinnedMessageIds: [messageId(99)],
    })
    vi.spyOn(db, "hydrateMessageWindow").mockResolvedValue(0)
    const state = makeCore(db)
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core: state.core, release: vi.fn() }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    await expect(preloader.prepare(userId(7), peer)).resolves.toEqual(
      expect.objectContaining({ pinnedMessageId: messageId(99) }),
    )
    expect(state.loadMessageReferences).not.toHaveBeenCalled()
  })

  it("promotes likely-visible cached media and avatars before chat route commit", async () => {
    const db = makeDatabase()
    const firstMessage = db.get(
      db.ref(DbObjectKind.Message, messageKey(chatId(10), messageId(1))),
    )!
    db.batch(() => {
      db.replace({
        ...firstMessage,
        media: {
          media: {
            oneofKind: "photo",
            photo: {
              photo: {
                id: 500n,
                date: 1n,
                format: 1,
                sizes: [
                  {
                    type: "d",
                    w: 800,
                    h: 600,
                    size: 80,
                    cdnUrl: "https://cdn.inline.chat/photo-500",
                  },
                ],
              },
            },
          },
        },
      })
      db.insert({
        kind: DbObjectKind.User,
        id: userId(7),
        profilePhoto: { fileUniqueId: "avatar:7" },
      })
    })
    vi.spyOn(db, "hydrateMessageWindow").mockResolvedValue(0)
    const state = makeCore(db)
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core: state.core, release: vi.fn() }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    const prepared = await preloader.prepare(userId(7), peer)

    expect(state.promoteCached.mock.calls.map(([key]) => key)).toEqual([
      "photo:500:d",
      "avatar:7",
    ])
    expect(prepared?.promotedMediaCount).toBe(2)
  })

  it("uses the bounded local around-target path and falls back to latest on a cache miss", async () => {
    const db = makeDatabase()
    const around = vi
      .spyOn(db, "loadLocalWindowAroundMessage")
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(false)
    const hydrate = vi
      .spyOn(db, "hydrateMessageWindow")
      .mockResolvedValue(0)
    const { core } = makeCore(db)
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core, release: vi.fn() }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    await expect(
      preloader.prepare(userId(7), peer, { targetMessageId: messageId(1) }),
    ).resolves.toEqual(
      expect.objectContaining({ source: "around" }),
    )
    await expect(
      preloader.prepare(userId(7), peer, { targetMessageId: messageId(2) }),
    ).resolves.toEqual(
      expect.objectContaining({ source: "latest" }),
    )
    expect(around).toHaveBeenNthCalledWith(1, chatId(10), {
      messageId: messageId(1),
      beforeLimit: 30,
      afterLimit: 29,
    })
    expect(hydrate).toHaveBeenCalledOnce()
  })

  it("resolves at cache-ready without waiting for network bootstrap", async () => {
    const db = makeDatabase()
    vi.spyOn(db, "hydrateMessageWindow").mockResolvedValue(0)
    const state = makeCore(db, {
      phase: "openingStorage",
      cacheReady: false,
    })
    const neverNetworkReady = new Promise<void>(() => undefined)
    vi.mocked(state.core.start).mockImplementation(() => {
      queueMicrotask(() => {
        state.setSnapshot({
          phase: "cacheReady",
          cacheReady: true,
        })
      })
      return neverNetworkReady
    })
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({
        core: state.core,
        release: vi.fn(),
      }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    await expect(preloader.prepare(userId(7), peer)).resolves.toEqual(
      expect.objectContaining({ source: "latest" }),
    )
  })

  it("surfaces a failed boot owner instead of replacing it", async () => {
    const failed = makeCore(makeDatabase(), {
      phase: "error",
      cacheReady: false,
      blockingFailure: {
        code: "owner-unresponsive",
        message: "Inline core worker did not complete its handshake",
        recoveryAction: "reload",
      },
    })
    const releaseFailed = vi.fn()
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({
        core: failed.core,
        release: releaseFailed,
      }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    await expect(preloader.prepare(userId(7), peer)).rejects.toThrow(
      "Inline core worker did not complete its handshake",
    )
    expect(releaseFailed).toHaveBeenCalledOnce()
    expect(failed.activateChat).not.toHaveBeenCalled()
  })

  it("does not expire its core or chat lease while cache hydration is pending", async () => {
    vi.useFakeTimers()
    const db = makeDatabase()
    vi.spyOn(db, "hydrateMessageWindow").mockResolvedValue(0)
    const state = makeCore(db, {
      phase: "openingStorage",
      cacheReady: false,
    })
    const release = vi.fn()
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core: state.core, release }),
      payloadTtlMs: 5,
      cacheReadyTimeoutMs: 10_000,
    })
    activePreloaders.push(preloader)

    const prepared = preloader.prepare(userId(7), peer)
    await vi.advanceTimersByTimeAsync(50)
    expect(release).not.toHaveBeenCalled()
    expect(state.releaseChat).not.toHaveBeenCalled()

    state.setSnapshot({ phase: "cacheReady", cacheReady: true })
    await expect(prepared).resolves.toEqual(
      expect.objectContaining({ chatId: chatId(10) }),
    )
    expect(state.activateChat).toHaveBeenCalledOnce()

    await vi.advanceTimersByTimeAsync(5)
    expect(state.releaseChat).toHaveBeenCalledOnce()
    expect(release).toHaveBeenCalledOnce()
  })

  it("carries one preload trace through cache and projection readiness", async () => {
    let now = 10
    const performance = new ChatOpenPerformance({ now: () => now++ })
    const db = makeDatabase()
    vi.spyOn(db, "hydrateMessageWindow").mockResolvedValue(0)
    const { core } = makeCore(db)
    const preloader = new ChatOpenPreloader({
      acquireCore: () => ({ core, release: vi.fn() }),
      performance,
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    const prepared = await preloader.prepare(userId(7), peer)
    expect(prepared).toBeDefined()
    expect(prepared!.performanceTraceId).toMatch(/^chat-open-/)
    expect(performance.get(prepared!.performanceTraceId)).toEqual(
      expect.objectContaining({
        cacheReadyMs: 1,
        projectionReadyMs: 2,
        source: "latest",
        preparedMessageCount: 2,
        outcome: "preparing",
      }),
    )
  })
})

import {
  AuthStore,
  Db,
  DbObjectKind,
  MessageSendingStatus,
  messageKey,
  messageDraftKey,
  sendMessage,
  updateDialogOpen,
  applyUpdates,
  type AuthSession,
  type Message,
  type RealtimeConnectionState,
  type Transaction,
} from "@inline/client"
import { Method, Update } from "@inline-chat/protocol/core"
import {
  chatId,
  dialogId,
  messageId,
  userId,
  type UserID,
} from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import type {
  InlineCoreClientMessage,
  InlineCoreHostMessage,
  InlineCoreSnapshot,
} from "./InlineCoreProtocol"
import { INLINE_CORE_PROTOCOL_VERSION } from "./InlineCoreProtocol"
import { InlineMediaLoader } from "../media/InlineMediaLoader"
import { InlineMediaAcquireCancelled } from "../media/InlineMediaRepository"
import { InlineMessageDrafts } from "../drafts/InlineMessageDrafts"
import {
  InlineCoreHost,
  type InlineCoreMessageEvent,
  type InlineCoreOwnedAccount,
} from "./InlineCoreHost"
import { InlineCoreRendererClient } from "./InlineCoreRendererClient"
import {
  createInlineCoreAccountOwnershipAcquirer,
  type InlineCoreLockManager,
} from "./InlineCoreAccountOwnership"

class HostFakeLockManager implements InlineCoreLockManager {
  private held = false

  async request<T>(
    _name: string,
    _options: { mode: "exclusive"; ifAvailable: true },
    callback: (lock: unknown | null) => Promise<T>,
  ): Promise<T> {
    if (this.held) return callback(null)
    this.held = true
    try {
      return await callback({ name: "inline-core-account" })
    } finally {
      this.held = false
    }
  }
}

class TestPort {
  peer?: TestPort
  private listeners = new Set<
    (event: InlineCoreMessageEvent) => void
  >()

  postMessage(
    message: InlineCoreClientMessage | InlineCoreHostMessage,
  ) {
    const cloned = structuredClone(message)
    // Node cannot structured-clone jsdom's Blob implementation. Browsers
    // preserve Blob across MessagePort, so keep the immutable test Blob while
    // cloning every other protocol field.
    if (
      message.type === "inlineCoreResult" &&
      message.media?.kind === "blob" &&
      cloned.type === "inlineCoreResult" &&
      cloned.media?.kind === "blob"
    ) {
      cloned.media.blob = message.media.blob
    }
    queueMicrotask(() => {
      this.peer?.emit(cloned)
    })
  }

  addEventListener(
    _type: "message",
    listener: (event: InlineCoreMessageEvent) => void,
  ) {
    this.listeners.add(listener)
  }

  removeEventListener(
    _type: "message",
    listener: (event: InlineCoreMessageEvent) => void,
  ) {
    this.listeners.delete(listener)
  }

  start() {}

  close() {
    this.listeners.clear()
  }

  private emit(message: unknown) {
    for (const listener of this.listeners) {
      listener({ data: message })
    }
  }
}

const portPair = () => {
  const client = new TestPort()
  const host = new TestPort()
  client.peer = host
  host.peer = client
  return { client, host }
}

class FakeOwnedAccount implements InlineCoreOwnedAccount {
  readonly ownerId = "shared-owner"
  readonly auth = new AuthStore({ persistence: "memory" })
  readonly db = new Db({
    autoHydrate: false,
    storageByKind: {
      [DbObjectKind.User]: null,
    },
  })
  readonly execute = vi.fn(
    async (transaction: Transaction) => {
      if (transaction.method === Method.GET_ME) {
        this.db.replace({
          kind: DbObjectKind.User,
          id: this.accountId,
          firstName: "Core",
        })
      }
      return undefined
    },
  )
  readonly connection = {
    setAppActive: vi.fn(async (_active: boolean) => undefined),
    setNetworkAvailable: vi.fn(
      async (_available: boolean) => undefined,
    ),
    systemDidWake: vi.fn(async () => undefined),
  }
  readonly resendMessage = vi.fn(
    async (chat: ReturnType<typeof chatId>, id: ReturnType<typeof messageId>) => {
      const ref = this.db.ref(
        DbObjectKind.Message,
        messageKey(chat, id),
      )
      const message = this.db.get(ref)
      if (!message) throw new Error("failed message missing")
      this.db.update({
        ...message,
        status: MessageSendingStatus.Sending,
      })
      return undefined
    },
  )
  readonly mutateAccepted = vi.fn(
    async (transaction: Transaction) => {
      this.db.batch(() => {
        transaction.prepare?.(this.db, this.auth)
        transaction.optimistic?.(this.db, this.auth)
      })
    },
  )
  readonly createThread = vi.fn(async () => chatId(801))
  readonly realtime = {
    connectionState: "idle" as RealtimeConnectionState,
    connection: this.connection,
    start: async () => undefined,
    stop: async () => undefined,
    execute: this.execute,
    query: this.execute,
    mutate: this.execute,
    mutateAccepted: this.mutateAccepted,
    createThread: this.createThread,
    resendMessage: this.resendMessage,
    onConnectionState: () => () => undefined,
  }
  readonly mediaLoader: InlineCoreOwnedAccount["mediaLoader"]
  readonly messageDrafts = new InlineMessageDrafts(this.db)
  readonly messageReferences = {
    load: vi.fn(async (): Promise<Message[]> => []),
    peek: vi.fn(() => undefined),
    subscribe: vi.fn((_listener: () => void) => () => undefined),
    getSnapshot: vi.fn(() => 0),
  }
  starts = 0
  stops = 0
  private running = false
  private listeners = new Set<() => void>()
  private snapshot: InlineCoreSnapshot

  constructor(
    readonly accountId: UserID,
    mediaLoader: InlineCoreOwnedAccount["mediaLoader"] = {
      load: async (_key, remoteUrl) => ({
        kind: "remote",
        url: remoteUrl,
      }),
      loadCached: async () => undefined,
    },
  ) {
    this.mediaLoader = mediaLoader
    this.auth.login({
      token: "token",
      userId: accountId,
    })
    this.snapshot = {
      protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
      ownerId: this.ownerId,
      accountId,
      phase: "idle",
      cacheReady: false,
      connectionState: "idle",
    }
  }

  getSnapshot = () => this.snapshot

  subscribe(listener: () => void) {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  async updateSession(session: AuthSession) {
    this.auth.login(session)
  }

  async start() {
    if (this.running) return
    this.running = true
    this.starts += 1
    this.snapshot = {
      ...this.snapshot,
      phase: "ready",
      cacheReady: true,
      connectionState: "connected",
    }
    for (const listener of this.listeners) listener()
  }

  async stop() {
    if (!this.running) return
    this.running = false
    this.stops += 1
    this.snapshot = {
      ...this.snapshot,
      phase: "stopped",
      connectionState: "idle",
    }
    for (const listener of this.listeners) listener()
  }
}

const session = {
  token: "token",
  userId: userId(7),
}

const renderer = (
  port: TestPort,
  options: {
    heartbeatIntervalMs?: number
    heartbeatTimeoutMs?: number
    requestTimeoutMs?: number
    owner?: EventTarget
  } = {},
) => {
  const auth = new AuthStore({ persistence: "memory" })
  auth.login(session)
  return new InlineCoreRendererClient({
    port,
    owner: options.owner,
    auth,
    session,
    bootTimeoutMs: 3_000,
    requestTimeoutMs: options.requestTimeoutMs ?? 3_000,
    heartbeatIntervalMs: options.heartbeatIntervalMs,
    heartbeatTimeoutMs: options.heartbeatTimeoutMs,
  })
}

const waitFor = async (
  predicate: () => boolean,
  timeoutMs = 1_000,
) => {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 2))
  }
  throw new Error("Timed out waiting for Inline core state")
}

describe("InlineCoreHost", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("shares one account owner and ordered projection across clients", async () => {
    let account: FakeOwnedAccount | undefined
    const createAccount = vi.fn((nextSession: AuthSession) => {
      account = new FakeOwnedAccount(nextSession.userId)
      return account
    })
    const host = new InlineCoreHost({ createAccount })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)

    await Promise.all([first.start(), second.start()])
    await waitFor(
      () =>
        first.getSnapshot().phase === "ready" &&
        second.getSnapshot().phase === "ready",
    )

    expect(createAccount).toHaveBeenCalledOnce()
    expect(first.getSnapshot().ownerId).toBe(
      second.getSnapshot().ownerId,
    )
    expect(account?.starts).toBe(1)

    account?.db.replace({
      kind: DbObjectKind.User,
      id: userId(8),
      firstName: "Dena",
    })
    await waitFor(
      () =>
        first.db.get(
          first.db.ref(DbObjectKind.User, userId(8)),
        )?.firstName === "Dena" &&
        second.db.get(
          second.db.ref(DbObjectKind.User, userId(8)),
        )?.firstName === "Dena",
    )

    first.detach()
    second.detach()
  })

  it("requires a fresh renderer after a competing bundle owner stops", async () => {
    const locks = new HostFakeLockManager()
    const acquireAccountOwnership =
      createInlineCoreAccountOwnershipAcquirer(locks)
    const firstAccount = new FakeOwnedAccount(session.userId)
    const secondAccount = new FakeOwnedAccount(session.userId)
    const firstHost = new InlineCoreHost({
      createAccount: () => firstAccount,
      acquireAccountOwnership,
    })
    const secondCreateAccount = vi.fn(() => secondAccount)
    const secondHost = new InlineCoreHost({
      createAccount: secondCreateAccount,
      acquireAccountOwnership,
    })
    const firstPair = portPair()
    const secondPair = portPair()
    firstHost.attachPort(firstPair.host)
    secondHost.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)

    await first.start()
    await expect(second.start()).rejects.toMatchObject({
      code: "owner-failed",
    })
    expect(second.getSnapshot()).toMatchObject({
      phase: "error",
      blockingFailure: {
        code: "owner-unavailable",
        recoveryAction: "reload",
      },
    })
    expect(secondCreateAccount).not.toHaveBeenCalled()

    await firstHost.shutdown()
    expect(firstAccount.stops).toBe(1)
    await expect(second.start()).rejects.toMatchObject({
      code: "owner-unavailable",
    })

    const reloadedPair = portPair()
    secondHost.attachPort(reloadedPair.host)
    const reloaded = renderer(reloadedPair.client)
    await reloaded.start()
    expect(secondCreateAccount).toHaveBeenCalledOnce()
    expect(reloaded.getSnapshot().phase).toBe("ready")

    first.detach()
    second.detach()
    reloaded.detach()
    await secondHost.shutdown()
  })

  it("single-flights logout when the auth observer reenters stop", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    const first = client.stop()
    const second = client.stop()
    expect(second).toBe(first)
    await first

    expect(client.auth.isLoggedIn()).toBe(false)
    expect(account?.stops).toBe(1)
    client.detach()
  })

  it("clears local credentials before an unresponsive owner stop times out", async () => {
    vi.useFakeTimers()
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    pair.host.close()

    const stopping = client.stop()
    const stopped = expect(stopping).rejects.toThrow(
      "Inline core request timed out",
    )
    expect(client.auth.isLoggedIn()).toBe(false)
    await vi.advanceTimersByTimeAsync(3_000)
    await stopped

    client.detach()
  })

  it("fails a wedged local chat projection before the general owner-command timeout", async () => {
    vi.useFakeTimers()
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client, {
      requestTimeoutMs: 30_000,
    })
    await client.start()
    pair.host.close()

    const hydration = expect(
      client.db.hydrateMessageWindow(chatId(10), { limit: 60 }),
    ).rejects.toThrow("Inline core request timed out")
    await vi.advanceTimersByTimeAsync(5_000)
    await hydration

    client.detach()
  })

  it("single-flights account ownership across simultaneous hellos", async () => {
    const locks = new HostFakeLockManager()
    const acquire = vi.fn(
      createInlineCoreAccountOwnershipAcquirer(locks),
    )
    const createAccount = vi.fn(
      () => new FakeOwnedAccount(session.userId),
    )
    const host = new InlineCoreHost({
      createAccount,
      acquireAccountOwnership: acquire,
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)

    await Promise.all([first.start(), second.start()])
    expect(acquire).toHaveBeenCalledOnce()
    expect(createAccount).toHaveBeenCalledOnce()

    first.detach()
    second.detach()
    await host.shutdown()
  })

  it("projects a post-message attachment update from the sole owner", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)
    await Promise.all([first.start(), second.start()])
    const releaseFirst = first.fullChatProgressive.activateChat(chatId(10))
    const releaseSecond = second.fullChatProgressive.activateChat(chatId(10))
    const key = messageKey(chatId(10), messageId(42))
    account!.db.replace({
      kind: DbObjectKind.Message,
      id: key,
      messageId: messageId(42),
      chatId: chatId(10),
      fromId: userId(8),
      message: "Preview arrives later",
      date: 1_000,
    })
    await waitFor(
      () =>
        first.db.get(first.db.ref(DbObjectKind.Message, key)) != null &&
        second.db.get(second.db.ref(DbObjectKind.Message, key)) != null,
    )

    applyUpdates(account!.db, [
      Update.create({
        update: {
          oneofKind: "messageAttachment",
          messageAttachment: {
            chatId: 10n,
            messageId: 42n,
            attachment: {
              id: 70n,
              attachment: {
                oneofKind: "urlPreview",
                urlPreview: {
                  id: 700n,
                  url: "https://inline.chat",
                  title: "Inline",
                },
              },
            },
          },
        },
      }),
    ])
    await waitFor(
      () =>
        first.db
          .get(first.db.ref(DbObjectKind.Message, key))
          ?.attachments?.attachments[0]?.attachment.oneofKind ===
          "urlPreview" &&
        second.db
          .get(second.db.ref(DbObjectKind.Message, key))
          ?.attachments?.attachments[0]?.attachment.oneofKind ===
          "urlPreview",
    )

    releaseFirst()
    releaseSecond()
    first.detach()
    second.detach()
  })

  it("keeps an open chat resident until the final renderer releases it", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)
    await Promise.all([first.start(), second.start()])
    const releaseWindow = vi.spyOn(
      account!.db,
      "releaseResidentMessageWindow",
    )

    const releaseFirst =
      first.fullChatProgressive.activateChat(chatId(10))
    const releaseSecond =
      second.fullChatProgressive.activateChat(chatId(10))
    await Promise.all([
      first.db.hydrateMessageWindow(chatId(10), { limit: 1 }),
      second.db.hydrateMessageWindow(chatId(10), { limit: 1 }),
    ])

    releaseFirst()
    await first.db.hydrateMessageWindow(chatId(10), { limit: 1 })
    expect(releaseWindow).not.toHaveBeenCalled()

    releaseSecond()
    await second.db.hydrateMessageWindow(chatId(10), { limit: 1 })
    await waitFor(() => releaseWindow.mock.calls.length === 1)
    expect(releaseWindow).toHaveBeenCalledWith(chatId(10))

    first.detach()
    second.detach()
  })

  it("rehydrates a released chat window on its second open without a realtime query", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    const targetChatId = chatId(10)
    account!.db.batch(() => {
      account!.db.replace({
        kind: DbObjectKind.Chat,
        id: targetChatId,
        lastMsgId: messageId(120),
        date: 120,
      })
      for (let value = 1; value <= 120; value += 1) {
        account!.db.replace({
          kind: DbObjectKind.Message,
          id: messageKey(targetChatId, messageId(value)),
          chatId: targetChatId,
          messageId: messageId(value),
          fromId: userId(8),
          date: value,
          message: `Persisted message ${value}`,
        })
      }
    })
    await account!.db.flushPersistence()

    const releaseFirst =
      client.fullChatProgressive.activateChat(targetChatId)
    await client.db.hydrateMessageWindow(targetChatId, { limit: 60 })
    await waitFor(() =>
      client.db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, messageId(120)),
      ),
    )
    releaseFirst()
    await waitFor(
      () =>
        account!.db.residentSnapshot([DbObjectKind.Message])
          .objects.length === 1,
    )
    expect(
      account!.db.get(
        account!.db.ref(
          DbObjectKind.Message,
          messageKey(targetChatId, messageId(120)),
        ),
      ),
    ).toBeDefined()

    const releaseSecond =
      client.fullChatProgressive.activateChat(targetChatId)
    await expect(
      client.db.hydrateMessageWindow(targetChatId, { limit: 60 }),
    ).resolves.toBe(60)
    await waitFor(() =>
      client.db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, messageId(120)),
      ),
    )

    const projectedMessages = client.db
      .residentSnapshot([DbObjectKind.Message])
      .objects.filter(
        (object): object is Message =>
          object.kind === DbObjectKind.Message &&
          object.chatId === targetChatId,
      )
    expect(projectedMessages).toHaveLength(60)
    expect(account!.execute).not.toHaveBeenCalled()

    releaseSecond()
    client.detach()
  })

  it("keeps independent contiguous windows for two renderers and reclaims only their union", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)
    await Promise.all([first.start(), second.start()])

    const targetChatId = chatId(10)
    account!.db.batch(() => {
      account!.db.replace({
        kind: DbObjectKind.Chat,
        id: targetChatId,
        lastMsgId: messageId(502),
        date: 502,
      })
      for (let value = 1; value <= 502; value += 1) {
        account!.db.replace({
          kind: DbObjectKind.Message,
          id: messageKey(targetChatId, messageId(value)),
          chatId: targetChatId,
          messageId: messageId(value),
          fromId: userId(8),
          date: value,
          message: `Message ${value}`,
        })
      }
    })

    const releaseFirst =
      first.fullChatProgressive.activateChat(targetChatId)
    const releaseSecond =
      second.fullChatProgressive.activateChat(targetChatId)
    await waitFor(
      () =>
        first.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(1)),
        ) &&
        second.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(502)),
        ),
    )

    first.fullChatProgressive.updateVisibleRange(
      targetChatId,
      messageId(480),
      messageId(500),
    )
    second.fullChatProgressive.updateVisibleRange(
      targetChatId,
      messageId(20),
      messageId(40),
    )
    await waitFor(
      () =>
        !first.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(1)),
        ) &&
        first.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(502)),
        ) &&
        second.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(1)),
        ) &&
        !second.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(502)),
        ),
    )
    expect(
      account!.db.residentSnapshot([DbObjectKind.Message])
        .objects,
    ).toHaveLength(502)

    releaseSecond()
    await waitFor(
      () =>
        account!.db.residentSnapshot([DbObjectKind.Message])
          .objects.length === 500,
    )
    expect(
      account!.db.get(
        account!.db.ref(
          DbObjectKind.Message,
          messageKey(targetChatId, messageId(1)),
        ),
      ),
    ).toBeUndefined()
    expect(
      account!.db.get(
        account!.db.ref(
          DbObjectKind.Message,
          messageKey(targetChatId, messageId(502)),
        ),
      ),
    ).toBeDefined()

    releaseFirst()
    first.detach()
    second.detach()
  })

  it("accepts an optimistic send from old history without waiting for latest-window hydration", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    const targetChatId = chatId(10)
    account!.db.batch(() => {
      account!.db.replace({
        kind: DbObjectKind.Chat,
        id: targetChatId,
        lastMsgId: messageId(502),
        date: 502,
      })
      for (let value = 1; value <= 502; value += 1) {
        account!.db.replace({
          kind: DbObjectKind.Message,
          id: messageKey(targetChatId, messageId(value)),
          chatId: targetChatId,
          messageId: messageId(value),
          fromId: userId(8),
          date: value,
          message: `Message ${value}`,
        })
      }
    })
    await account!.db.flushPersistence()

    const releaseChat =
      client.fullChatProgressive.activateChat(targetChatId)
    await waitFor(() =>
      client.db.isMessageInHistoryWindow(
        targetChatId,
        messageKey(targetChatId, messageId(502)),
      ),
    )
    client.fullChatProgressive.updateVisibleRange(
      targetChatId,
      messageId(20),
      messageId(40),
    )
    await waitFor(
      () =>
        client.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(1)),
        ) &&
        !client.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(502)),
        ),
    )

    const originalHydrate =
      account!.db.hydrateMessageWindowDetails.bind(account!.db)
    let continueHydration!: () => void
    const hydrationGate = new Promise<void>((resolve) => {
      continueHydration = resolve
    })
    const hydrate = vi
      .spyOn(account!.db, "hydrateMessageWindowDetails")
      .mockImplementation(async (...arguments_) => {
        await hydrationGate
        return originalHydrate(...arguments_)
      })
    account!.execute.mockImplementation(async (transaction) => {
      account!.db.batch(() => {
        transaction.optimistic?.(account!.db, account!.auth)
      })
      return undefined
    })

    const temporaryMessageId = messageId(9_001)
    const temporaryKey = messageKey(
      targetChatId,
      temporaryMessageId,
    )
    const send = client.mutate(
      sendMessage({
        chatId: targetChatId,
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 10n },
          },
        },
        text: "From old history",
        randomId: 91n,
        temporaryMessageId,
        temporarySendDate: 1_000,
      }),
    )
    await waitFor(() => hydrate.mock.calls.length === 1)
    // Keep the latest-window hydration gate closed while acceptance resolves.
    // If execute ever starts awaiting that background read, this assertion
    // reaches Vitest's test deadline instead of depending on a load-sensitive
    // 100 ms race.
    await expect(send).resolves.toBeUndefined()
    await waitFor(
      () =>
        client.db.isMessageInHistoryWindow(
          targetChatId,
          temporaryKey,
        ) &&
        !client.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(1)),
        ),
    )
    expect(
      client.db.get(
        client.db.ref(DbObjectKind.Message, temporaryKey),
      )?.message,
    ).toBe("From old history")

    continueHydration()
    await waitFor(
      () =>
        client.db.isMessageInHistoryWindow(
          targetChatId,
          messageKey(targetChatId, messageId(444)),
        ) &&
        client.db.isMessageInHistoryWindow(
          targetChatId,
          temporaryKey,
        ),
    )
    expect(account!.execute).toHaveBeenCalledOnce()

    releaseChat()
    client.detach()
  }, 10_000)

  it("does not fail a send when latest-window cache hydration fails", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const targetChatId = chatId(10)
    account!.db.replace({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: messageId(10),
      date: 10,
    })
    const releaseChat =
      client.fullChatProgressive.activateChat(targetChatId)
    await new Promise((resolve) => setTimeout(resolve, 0))
    vi.spyOn(
      account!.db,
      "hydrateMessageWindowDetails",
    ).mockRejectedValue(new Error("cache unavailable"))
    account!.execute.mockImplementation(async (transaction) => {
      account!.db.batch(() => {
        transaction.optimistic?.(account!.db, account!.auth)
      })
      return undefined
    })

    const temporaryMessageId = messageId(9_002)
    const temporaryKey = messageKey(
      targetChatId,
      temporaryMessageId,
    )
    await expect(
      client.mutate(
        sendMessage({
          chatId: targetChatId,
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 10n },
            },
          },
          text: "Cache-independent send",
          randomId: 92n,
          temporaryMessageId,
          temporarySendDate: 1_001,
        }),
      ),
    ).resolves.toBeUndefined()
    await waitFor(() =>
      client.db.isMessageInHistoryWindow(
        targetChatId,
        temporaryKey,
      ),
    )
    expect(account!.execute).toHaveBeenCalledOnce()

    releaseChat()
    client.detach()
  })

  it("routes resend through the sole owner and projects the failed message as sending", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const targetChatId = chatId(10)
    const temporaryMessageId = messageId(-9_004)
    const temporaryKey = messageKey(
      targetChatId,
      temporaryMessageId,
    )
    account!.db.replace({
      kind: DbObjectKind.Message,
      id: temporaryKey,
      chatId: targetChatId,
      messageId: temporaryMessageId,
      fromId: session.userId,
      out: true,
      message: "Resend through owner",
      randomId: 94n,
      status: MessageSendingStatus.Failed,
    })
    const releaseChat =
      client.fullChatProgressive.activateChat(targetChatId)
    await waitFor(() =>
      client.db.get(
        client.db.ref(DbObjectKind.Message, temporaryKey),
      )?.status === "failed",
    )
    client.fullChatProgressive.updateVisibleRange(
      targetChatId,
      temporaryMessageId,
      temporaryMessageId,
    )
    await Promise.resolve()
    expect(client.getSnapshot().blockingFailure).toBeUndefined()
    vi.spyOn(
      account!.db,
      "hydrateMessageWindowDetails",
    ).mockRejectedValue(new Error("cache unavailable"))

    await expect(
      client.resendMessage(
        targetChatId,
        temporaryMessageId,
      ),
    ).resolves.toBeUndefined()
    await waitFor(() =>
      client.db.get(
        client.db.ref(DbObjectKind.Message, temporaryKey),
      )?.status === "sending",
    )
    expect(account!.resendMessage).toHaveBeenCalledOnce()
    expect(account!.resendMessage).toHaveBeenCalledWith(
      targetChatId,
      temporaryMessageId,
    )

    releaseChat()
    client.detach()
  })

  it("routes durable local acceptance through the sole owner even when dialog is already open", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    account!.db.replace({
      kind: DbObjectKind.Dialog,
      id: dialogId(-801),
      chatId: chatId(801),
      peerThreadId: chatId(801),
      open: true,
      order: "server-order",
    })

    await expect(
      client.mutateAccepted(
        updateDialogOpen({
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 801n },
            },
          },
          open: true,
        }),
      ),
    ).resolves.toBeUndefined()

    expect(account!.mutateAccepted).toHaveBeenCalledOnce()
    expect(account!.execute).not.toHaveBeenCalled()
    client.detach()
  })

  it("routes local thread creation through the sole account owner", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    await expect(
      client.createThread({
        title: "",
        isPublic: false,
        participants: [userId(42)],
      }),
    ).resolves.toBe(chatId(801))
    expect(account!.createThread).toHaveBeenCalledWith({
      title: "",
      isPublic: false,
      participants: [userId(42)],
    })
    expect(account!.execute).not.toHaveBeenCalled()
    client.detach()
  })

  it("keeps the newest message-window intent when an older around request finishes after send", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const targetChatId = chatId(10)
    account!.db.replace({
      kind: DbObjectKind.Chat,
      id: targetChatId,
      lastMsgId: messageId(10),
      date: 10,
    })
    const releaseChat =
      client.fullChatProgressive.activateChat(targetChatId)
    await new Promise((resolve) => setTimeout(resolve, 0))

    let completeAround!: () => void
    const aroundGate = new Promise<void>((resolve) => {
      completeAround = resolve
    })
    const aroundKey = messageKey(
      targetChatId,
      messageId(4),
    )
    const loadAround = vi
      .spyOn(
        account!.db,
        "loadLocalWindowAroundMessageDetails",
      )
      .mockImplementation(async () => {
        await aroundGate
        return { found: true, messageKeys: [aroundKey] }
      })
    vi.spyOn(
      account!.db,
      "hydrateMessageWindowDetails",
    ).mockRejectedValue(new Error("cache unavailable"))
    account!.execute.mockImplementation(async (transaction) => {
      account!.db.batch(() => {
        transaction.optimistic?.(account!.db, account!.auth)
      })
      return undefined
    })

    const around = client.db.loadLocalWindowAroundMessage(
      targetChatId,
      {
        messageId: messageId(4),
        beforeLimit: 2,
        afterLimit: 2,
      },
    )
    await waitFor(() => loadAround.mock.calls.length === 1)

    const temporaryMessageId = messageId(9_003)
    const temporaryKey = messageKey(
      targetChatId,
      temporaryMessageId,
    )
    await client.mutate(
      sendMessage({
        chatId: targetChatId,
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 10n },
          },
        },
        text: "Newer intent wins",
        randomId: 93n,
        temporaryMessageId,
        temporarySendDate: 1_002,
      }),
    )
    await waitFor(() =>
      client.db.isMessageInHistoryWindow(
        targetChatId,
        temporaryKey,
      ),
    )

    completeAround()
    await expect(around).resolves.toBe(true)
    expect(
      client.db.isMessageInHistoryWindow(
        targetChatId,
        temporaryKey,
      ),
    ).toBe(true)
    expect(
      client.db.isMessageInHistoryWindow(
        targetChatId,
        aroundKey,
      ),
    ).toBe(false)

    releaseChat()
    client.detach()
  })

  it("persists a draft only in the owner and projects it across renderers", async () => {
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)
    await Promise.all([first.start(), second.start()])
    const peer = {
      peerKind: "chat" as const,
      peerThreadId: chatId(81),
    }

    await first.messageDrafts.update(peer, "Shared draft")
    await waitFor(
      () =>
        second.db.get(
          second.db.ref(
            DbObjectKind.MessageDraft,
            messageDraftKey(peer),
          ),
        )?.text === "Shared draft",
    )
    expect((await second.messageDrafts.load(peer))?.text).toBe(
      "Shared draft",
    )

    await second.messageDrafts.clear(peer)
    await waitFor(
      () =>
        first.db.get(
          first.db.ref(
            DbObjectKind.MessageDraft,
            messageDraftKey(peer),
          ),
        ) == null,
    )

    first.detach()
    second.detach()
  })

  it("executes a renderer transaction only in the owner", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    await client.query({
      method: Method.GET_ME,
      kind: { kind: "query", config: {} },
      context: {},
      input: () => ({ oneofKind: "getMe", getMe: {} }),
      apply: () => undefined,
    })
    await waitFor(
      () =>
        client.db.get(
          client.db.ref(DbObjectKind.User, userId(7)),
        )?.firstName === "Core",
    )

    expect(account?.execute).toHaveBeenCalledOnce()
    client.detach()
  })

  it("loads embedded reply references without projecting them into history", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const referenced = {
      kind: DbObjectKind.Message as const,
      id: messageKey(chatId(10), messageId(42)),
      chatId: chatId(10),
      messageId: messageId(42),
      fromId: userId(8),
      message: "Referenced",
    }
    account!.messageReferences.load.mockResolvedValueOnce([
      referenced,
    ])

    await expect(
      client.messageReferences.load({
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 10n },
          },
        },
        chatId: chatId(10),
        messageIds: [messageId(42)],
      }),
    ).resolves.toEqual([referenced])
    expect(account!.messageReferences.load).toHaveBeenCalledWith({
      peerId: {
        type: {
          oneofKind: "chat",
          chat: { chatId: 10n },
        },
      },
      chatId: chatId(10),
      messageIds: [messageId(42)],
    })
    expect(
      client.db.get(
        client.db.ref(DbObjectKind.Message, referenced.id),
      ),
    ).toBeUndefined()
    client.detach()
  })

  it("keeps the owner until the final client detaches", async () => {
    vi.useFakeTimers()
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      ownerIdleMs: 10,
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)
    await Promise.all([first.start(), second.start()])

    first.detach()
    await vi.advanceTimersByTimeAsync(11)
    expect(account?.stops).toBe(0)

    second.detach()
    await vi.advanceTimersByTimeAsync(11)
    expect(account?.stops).toBe(1)
  })

  it("closes the host-side port after an explicit renderer detach", async () => {
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
    })
    const pair = portPair()
    const closeHostPort = vi.spyOn(pair.host, "close")
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    client.detach()
    await vi.waitFor(() => expect(closeHostPort).toHaveBeenCalledOnce())
  })

  it("delivers page-discard detach before the renderer port disappears", async () => {
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
    })
    const pair = portPair()
    const closeRendererPort = vi.spyOn(pair.client, "close")
    const closeHostPort = vi.spyOn(pair.host, "close")
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    window.dispatchEvent(
      new PageTransitionEvent("pagehide", { persisted: false }),
    )

    await vi.waitFor(() => expect(closeHostPort).toHaveBeenCalledOnce())
    expect(closeRendererPort).not.toHaveBeenCalled()
  })

  it("abandons renderer continuations without reporting failures while the page is discarded", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    account!.execute.mockImplementationOnce(
      () => new Promise(() => undefined),
    )
    const rejected = vi.fn()

    void client.query({
      method: Method.GET_ME,
      kind: { kind: "query", config: {} },
      context: {},
      input: () => ({ oneofKind: "getMe", getMe: {} }),
      apply: () => undefined,
    }).catch(rejected)
    await waitFor(() => account!.execute.mock.calls.length === 1)

    window.dispatchEvent(
      new PageTransitionEvent("pagehide", { persisted: false }),
    )
    await Promise.resolve()
    await Promise.resolve()

    expect(rejected).not.toHaveBeenCalled()
    await host.shutdown()
  })

  it("stops every owned account before shutdown resolves", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      ownerIdleMs: 60_000,
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()

    const firstShutdown = host.shutdown()
    const secondShutdown = host.shutdown()

    expect(secondShutdown).toBe(firstShutdown)
    await firstShutdown
    expect(account?.starts).toBe(1)
    expect(account?.stops).toBe(1)

    await host.shutdown()
    expect(account?.stops).toBe(1)
    client.detach()
  })

  it("reattaches an active renderer after its host lease expires", async () => {
    vi.useFakeTimers()
    let account: FakeOwnedAccount | undefined
    const createAccount = vi.fn((nextSession: AuthSession) => {
      account = new FakeOwnedAccount(nextSession.userId)
      return account
    })
    const host = new InlineCoreHost({
      createAccount,
      clientLeaseMs: 10,
      ownerIdleMs: 100,
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client, {
      heartbeatIntervalMs: 20,
    })
    await client.start()

    await vi.advanceTimersByTimeAsync(25)
    const query = client.query({
      method: Method.GET_ME,
      kind: { kind: "query", config: {} },
      context: {},
      input: () => ({ oneofKind: "getMe", getMe: {} }),
      apply: () => undefined,
    })
    await vi.advanceTimersByTimeAsync(1)
    await query

    expect(createAccount).toHaveBeenCalledOnce()
    expect(account?.starts).toBe(1)
    expect(account?.execute).toHaveBeenCalledOnce()
    client.detach()
  })

  it("closes an abandoned port when no renderer answers the lease probe", async () => {
    vi.useFakeTimers()
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
      clientLeaseMs: 10,
      clientLeaseGraceMs: 5,
      ownerIdleMs: 100,
    })
    const pair = portPair()
    const closeHostPort = vi.spyOn(pair.host, "close")
    host.attachPort(pair.host)
    const client = renderer(pair.client, {
      heartbeatIntervalMs: 20,
    })
    await client.start()

    // Simulate a renderer context disappearing without delivering detach.
    pair.client.close()
    await vi.advanceTimersByTimeAsync(16)

    expect(closeHostPort).toHaveBeenCalledOnce()
    client.detach()
  })

  it("rejects an incompatible protocol before creating an owner", async () => {
    const createAccount = vi.fn(
      (nextSession: AuthSession) =>
        new FakeOwnedAccount(nextSession.userId),
    )
    const host = new InlineCoreHost({ createAccount })
    const pair = portPair()
    const messages: InlineCoreHostMessage[] = []
    pair.client.addEventListener("message", (event) => {
      messages.push(event.data as InlineCoreHostMessage)
    })
    host.attachPort(pair.host)

    pair.client.postMessage({
      type: "inlineCoreHello",
      protocolVersion: 99,
      clientId: "client",
      accountId: session.userId,
      session,
      lifecycle: { visible: true, online: true },
    } as unknown as InlineCoreClientMessage)
    await waitFor(() => messages.length > 0)

    expect(messages[0]).toMatchObject({
      type: "inlineCoreError",
      code: "incompatible-version",
    })
    expect(createAccount).not.toHaveBeenCalled()
  })

  it("surfaces a terminal SharedWorker failure without recreating or replaying the owner", async () => {
    const createAccount = vi.fn(
      (nextSession: AuthSession) =>
        new FakeOwnedAccount(nextSession.userId),
    )
    const host = new InlineCoreHost({ createAccount })
    const pair = portPair()
    const owner = new EventTarget()
    host.attachPort(pair.host)
    const client = renderer(pair.client, { owner })
    await client.start()

    owner.dispatchEvent(
      new ErrorEvent("error", {
        message: "worker process exited",
      }),
    )

    expect(client.getSnapshot()).toMatchObject({
      phase: "error",
      connectionState: "idle",
      blockingFailure: {
        code: "owner-unavailable",
        recoveryAction: "reload",
        message: expect.stringContaining("worker process exited"),
      },
    })
    await expect(client.start()).rejects.toMatchObject({
      code: "owner-failed",
    })
    expect(createAccount).toHaveBeenCalledOnce()

    client.detach()
  })

  it("rejects an in-flight request when the worker fails and never replays it", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    const owner = new EventTarget()
    host.attachPort(pair.host)
    const client = renderer(pair.client, { owner })
    await client.start()
    account!.execute.mockImplementationOnce(
      () => new Promise(() => undefined),
    )

    const request = client.query({
      method: Method.GET_ME,
      kind: { kind: "query", config: {} },
      context: {},
      input: () => ({ oneofKind: "getMe", getMe: {} }),
      apply: () => undefined,
    })
    await waitFor(() => account!.execute.mock.calls.length === 1)
    owner.dispatchEvent(
      new ErrorEvent("error", {
        message: "worker process exited",
      }),
    )

    await expect(request).rejects.toMatchObject({
      code: "owner-failed",
    })
    expect(account!.execute).toHaveBeenCalledOnce()
    await expect(client.start()).rejects.toMatchObject({
      code: "owner-failed",
    })
    expect(account!.execute).toHaveBeenCalledOnce()

    client.detach()
  })

  it("turns a silently terminated worker into explicit recovery state", async () => {
    vi.useFakeTimers()
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client, {
      heartbeatIntervalMs: 10,
      heartbeatTimeoutMs: 5,
    })
    await client.start()
    await vi.advanceTimersByTimeAsync(1)

    pair.host.close()
    await vi.advanceTimersByTimeAsync(15)

    expect(client.getSnapshot()).toMatchObject({
      phase: "error",
      blockingFailure: {
        code: "owner-unresponsive",
        recoveryAction: "reload",
        message: "Inline core worker stopped responding",
      },
    })
    await expect(client.start()).rejects.toMatchObject({
      code: "owner-failed",
    })

    client.detach()
  })

  it("defers silent-worker failure while hidden and probes on foreground", async () => {
    vi.useFakeTimers()
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId),
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client, {
      heartbeatIntervalMs: 10,
      heartbeatTimeoutMs: 5,
    })
    await client.start()
    await vi.advanceTimersByTimeAsync(1)
    const background = client.setAppActive(false)
    await vi.advanceTimersByTimeAsync(1)
    await background

    pair.host.close()
    await vi.advanceTimersByTimeAsync(100)
    expect(client.getSnapshot().blockingFailure).toBeUndefined()

    const foreground = client.setAppActive(true)
    const foregroundFailure = expect(foreground).rejects.toMatchObject({
      code: "owner-failed",
    })
    await vi.advanceTimersByTimeAsync(5)
    await foregroundFailure
    expect(client.getSnapshot()).toMatchObject({
      phase: "error",
      blockingFailure: {
        code: "owner-unresponsive",
        recoveryAction: "reload",
      },
    })

    client.detach()
  })

  it("rejects unbounded message hydration before storage is touched", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    const messages: InlineCoreHostMessage[] = []
    pair.client.addEventListener("message", (event) => {
      messages.push(event.data as InlineCoreHostMessage)
    })
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const hydrate = vi.spyOn(
      account!.db,
      "hydrateMessageWindow",
    )

    pair.client.postMessage({
      type: "inlineCoreHydrateMessageWindow",
      requestId: "oversized-window",
      chatId: chatId(10),
      limit: 10_000,
    })
    await waitFor(() =>
      messages.some(
        (message) =>
          message.type === "inlineCoreError" &&
          message.requestId === "oversized-window",
      ),
    )

    expect(hydrate).not.toHaveBeenCalled()
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "inlineCoreError",
        code: "invalid-message",
        requestId: "oversized-window",
      }),
    )
    client.detach()
  })

  it("validates and forwards the complete local message-window cursor", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    const hostMessages: InlineCoreHostMessage[] = []
    pair.client.addEventListener("message", (event) => {
      hostMessages.push(event.data as InlineCoreHostMessage)
    })
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const releaseChat = client.fullChatProgressive.activateChat(
      chatId(10),
    )
    await new Promise((resolve) => setTimeout(resolve, 0))
    const hydratedKey = messageKey(chatId(10), messageId(41))
    const hydrate = vi
      .spyOn(account!.db, "hydrateMessageWindowDetails")
      .mockResolvedValue({
        count: 20,
        messageKeys: [hydratedKey],
      })

    await expect(
      client.db.hydrateMessageWindow(chatId(10), {
        limit: 20,
        before: {
          date: 1_700_000_000,
          messageId: messageId(42),
        },
      }),
    ).resolves.toBe(20)
    expect(hydrate).toHaveBeenCalledWith(chatId(10), {
      limit: 20,
      before: {
        date: 1_700_000_000,
        messageId: messageId(42),
      },
    })
    expect(
      client.db.isMessageInHistoryWindow(
        chatId(10),
        hydratedKey,
      ),
    ).toBe(true)

    await expect(
      client.db.hydrateMessageWindow(chatId(10), {
        limit: 20,
        after: {
          date: 1_700_000_000,
          messageId: messageId(42),
        },
      }),
    ).resolves.toBe(20)
    expect(hydrate).toHaveBeenLastCalledWith(chatId(10), {
      limit: 20,
      after: {
        date: 1_700_000_000,
        messageId: messageId(42),
      },
    })

    pair.client.postMessage({
      type: "inlineCoreHydrateMessageWindow",
      requestId: "invalid-cursor",
      chatId: chatId(10),
      limit: 20,
      before: {
        date: 1.5,
        messageId: messageId(42),
      },
    })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(hydrate).toHaveBeenCalledTimes(2)
    expect(hostMessages).toContainEqual(
      expect.objectContaining({
        type: "inlineCoreError",
        code: "invalid-message",
        requestId: "invalid-cursor",
      }),
    )
    pair.client.postMessage({
      type: "inlineCoreHydrateMessageWindow",
      requestId: "ambiguous-cursor",
      chatId: chatId(10),
      limit: 20,
      before: {
        date: 1_700_000_000,
        messageId: messageId(40),
      },
      after: {
        date: 1_700_000_000,
        messageId: messageId(42),
      },
    })
    await waitFor(() =>
      hostMessages.some(
        (hostMessage) =>
          hostMessage.type === "inlineCoreError" &&
          hostMessage.requestId === "ambiguous-cursor",
      ),
    )
    expect(hydrate).toHaveBeenCalledTimes(2)
    releaseChat()
    client.detach()
  })

  it("validates and forwards bounded local around-target windows", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    const hostMessages: InlineCoreHostMessage[] = []
    pair.client.addEventListener("message", (event) => {
      hostMessages.push(event.data as InlineCoreHostMessage)
    })
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const releaseChat = client.fullChatProgressive.activateChat(
      chatId(10),
    )
    await new Promise((resolve) => setTimeout(resolve, 0))
    const anchorKey = messageKey(chatId(10), messageId(42))
    const loadAround = vi
      .spyOn(
        account!.db,
        "loadLocalWindowAroundMessageDetails",
      )
      .mockResolvedValue({
        found: true,
        messageKeys: [anchorKey],
      })

    await expect(
      client.db.loadLocalWindowAroundMessage(chatId(10), {
        messageId: messageId(42),
        beforeLimit: 30,
        afterLimit: 29,
      }),
    ).resolves.toBe(true)
    expect(loadAround).toHaveBeenCalledWith(
      chatId(10),
      {
        messageId: messageId(42),
        beforeLimit: 30,
        afterLimit: 29,
      },
      false,
    )
    expect(
      client.db.isMessageInHistoryWindow(
        chatId(10),
        anchorKey,
      ),
    ).toBe(true)

    pair.client.postMessage({
      type: "inlineCoreLoadLocalWindowAroundMessage",
      requestId: "oversized-around-window",
      chatId: chatId(10),
      window: {
        messageId: messageId(42),
        beforeLimit: 100,
        afterLimit: 100,
      },
    })
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(loadAround).toHaveBeenCalledTimes(1)
    expect(hostMessages).toContainEqual(
      expect.objectContaining({
        type: "inlineCoreError",
        code: "invalid-message",
        requestId: "oversized-around-window",
      }),
    )
    releaseChat()
    client.detach()
  })

  it("deduplicates media cache and download work across renderers while keeping object URLs local", async () => {
    const cache = {
      get: vi.fn(async () => undefined),
      put: vi.fn(async () => undefined),
    }
    const fetcher = vi.fn(async () =>
      new Response(new Blob(["avatar"]), { status: 200 }),
    )
    const mediaLoader = new InlineMediaLoader({
      cache,
      fetcher,
    })
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(
          nextSession.userId,
          mediaLoader,
        ),
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)
    let objectUrl = 0
    const createObjectUrl = vi
      .spyOn(URL, "createObjectURL")
      .mockImplementation(
        () => `blob:inline-renderer-${++objectUrl}`,
      )
    const revokeObjectUrl = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => undefined)
    await Promise.all([first.start(), second.start()])

    const [firstMedia, secondMedia] = await Promise.all([
      first.mediaRepository.acquire(
        "photo-1",
        "https://cdn.inline.chat/photo-1",
      ),
      second.mediaRepository.acquire(
        "photo-1",
        "https://cdn.inline.chat/photo-1",
      ),
    ])

    expect(cache.get).toHaveBeenCalledOnce()
    expect(fetcher).toHaveBeenCalledOnce()
    expect(cache.put).toHaveBeenCalledOnce()
    expect(createObjectUrl).toHaveBeenCalledTimes(2)
    expect(firstMedia.url).not.toBe(secondMedia.url)

    firstMedia.release()
    secondMedia.release()
    expect(revokeObjectUrl).not.toHaveBeenCalled()
    first.detach()
    second.detach()
    expect(revokeObjectUrl).toHaveBeenCalledTimes(2)
  })

  it("promotes owner-cached bytes into a renderer without starting network work", async () => {
    const cached = new Blob(["cached-avatar"])
    const cache = {
      get: vi.fn(async () => cached),
      put: vi.fn(async () => undefined),
    }
    const fetcher = vi.fn()
    const mediaLoader = new InlineMediaLoader({ cache, fetcher })
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(nextSession.userId, mediaLoader),
    })
    const pair = portPair()
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    vi.spyOn(URL, "createObjectURL").mockReturnValue(
      "blob:cached-avatar",
    )
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(
      () => undefined,
    )
    await client.start()

    await expect(
      client.mediaRepository.promoteCached("avatar-1"),
    ).resolves.toBe(true)
    expect(client.mediaRepository.peek("avatar-1")).toBe(
      "blob:cached-avatar",
    )
    expect(cache.get).toHaveBeenCalledOnce()
    expect(fetcher).not.toHaveBeenCalled()

    client.detach()
  })

  it("cancels shared media work only after the final renderer consumer leaves", async () => {
    let downloadSignal: AbortSignal | undefined
    const fetcher = vi.fn(
      (_input: RequestInfo | URL, init?: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          downloadSignal = init?.signal ?? undefined
          downloadSignal?.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true },
          )
        }),
    )
    const mediaLoader = new InlineMediaLoader({
      cache: {
        get: vi.fn(async () => undefined),
        put: vi.fn(async () => undefined),
      },
      fetcher,
    })
    const host = new InlineCoreHost({
      createAccount: (nextSession) =>
        new FakeOwnedAccount(
          nextSession.userId,
          mediaLoader,
        ),
    })
    const firstPair = portPair()
    const secondPair = portPair()
    host.attachPort(firstPair.host)
    host.attachPort(secondPair.host)
    const first = renderer(firstPair.client)
    const second = renderer(secondPair.client)
    await Promise.all([first.start(), second.start()])
    const firstConsumer = new AbortController()
    const secondConsumer = new AbortController()

    const firstMedia = first.mediaRepository.acquire(
      "photo-1",
      "https://cdn.inline.chat/photo-1",
      { signal: firstConsumer.signal },
    )
    const secondMedia = second.mediaRepository.acquire(
      "photo-1",
      "https://cdn.inline.chat/photo-1",
      { signal: secondConsumer.signal },
    )
    await waitFor(() => fetcher.mock.calls.length === 1)

    firstConsumer.abort()
    await expect(firstMedia).rejects.toBeInstanceOf(
      InlineMediaAcquireCancelled,
    )
    await new Promise((resolve) => setTimeout(resolve, 2))
    expect(downloadSignal?.aborted).toBe(false)

    secondConsumer.abort()
    await expect(secondMedia).rejects.toBeInstanceOf(
      InlineMediaAcquireCancelled,
    )
    await waitFor(() => downloadSignal?.aborted === true)
    expect(fetcher).toHaveBeenCalledOnce()

    first.detach()
    second.detach()
  })

  it("rejects non-network media URLs before the account loader is touched", async () => {
    let account: FakeOwnedAccount | undefined
    const host = new InlineCoreHost({
      createAccount: (nextSession) => {
        account = new FakeOwnedAccount(nextSession.userId)
        return account
      },
    })
    const pair = portPair()
    const messages: InlineCoreHostMessage[] = []
    pair.client.addEventListener("message", (event) => {
      messages.push(event.data as InlineCoreHostMessage)
    })
    host.attachPort(pair.host)
    const client = renderer(pair.client)
    await client.start()
    const load = vi.spyOn(account!.mediaLoader, "load")

    pair.client.postMessage({
      type: "inlineCoreLoadMedia",
      requestId: "unsafe-media",
      key: "photo-1",
      remoteUrl: "javascript:alert(1)",
    })
    await waitFor(() =>
      messages.some(
        (message) =>
          message.type === "inlineCoreError" &&
          message.requestId === "unsafe-media",
      ),
    )

    expect(load).not.toHaveBeenCalled()
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "inlineCoreError",
        code: "invalid-message",
        requestId: "unsafe-media",
      }),
    )
    client.detach()
  })
})

import {
  AuthStore,
  DbObjectKind,
  DbQueryPlanType,
  FullChatWindowState,
  MessageSendingStatus,
  compareMessagesByWindow,
  decodeCoreTransaction,
  messageKey,
  protocolMessageKey,
  parseMessageWindowCursor,
  type AuthSession,
  type Db,
  type Message,
  type MessageKey,
  type DbResidentChangeBatch,
  type MessageDraftPeer,
  type RealtimeService,
  type CreateThreadInput,
} from "@inline/client/core"
import {
  GetChatHistoryMode,
  Method,
  type RpcResult,
} from "@inline-chat/protocol/core"
import {
  parseInlineId,
  type ChatID,
  type MessageID,
  type UserID,
} from "@inline/ids"
import { InlineAccountCore } from "./InlineAccountCore"
import type {
  InlineMediaLoader,
  InlineMediaResource,
} from "../media/InlineMediaLoader"
import {
  INLINE_CORE_PROTOCOL_VERSION,
  INLINE_CORE_RENDERER_KINDS,
  type InlineCoreClientLifecycle,
  type InlineCoreClientMessage,
  type InlineCoreHostMessage,
  type InlineCoreProjection,
  type InlineCoreProjectionChanges,
  type InlineCoreSnapshot,
} from "./InlineCoreProtocol"
import type { InlineMessageDraftsService } from "../drafts/InlineMessageDrafts"
import { isInlineMessageEntities } from "../messages/InlineMessageEntities"
import type { InlineMessageReferencesService } from "../messages/InlineMessageReferences"
import { FULL_CHAT_RESIDENT_MESSAGE_LIMIT } from "./FullChatProgressiveService"
import type {
  InlineCoreAccountOwnership,
  InlineCoreAccountOwnershipAcquirer,
} from "./InlineCoreAccountOwnership"

export type InlineCoreMessageEvent = {
  data: unknown
}

export type InlineCoreMessagePort = {
  postMessage(message: InlineCoreHostMessage): void
  addEventListener(
    type: "message",
    listener: (event: InlineCoreMessageEvent) => void,
  ): void
  removeEventListener?(
    type: "message",
    listener: (event: InlineCoreMessageEvent) => void,
  ): void
  start?(): void
  close?(): void
}

type OwnedRealtime = RealtimeService & {
  connection: {
    setAppActive(active: boolean): Promise<void>
    setNetworkAvailable(available: boolean): Promise<void>
    systemDidWake(): Promise<void>
  }
}

export type InlineCoreOwnedAccount = {
  readonly accountId: UserID
  readonly ownerId: string
  readonly auth: AuthStore
  readonly db: Db
  readonly realtime: OwnedRealtime
  readonly mediaLoader: Pick<
    InlineMediaLoader,
    "load" | "loadCached"
  >
  readonly messageDrafts: InlineMessageDraftsService
  readonly messageReferences: InlineMessageReferencesService
  getSnapshot(): InlineCoreSnapshot
  subscribe(listener: () => void): () => void
  updateSession(session: AuthSession): Promise<void>
  start(): Promise<void>
  stop(): Promise<void>
}

export class InlineCoreAccountOwnershipUnavailableError extends Error {
  constructor(readonly accountId: UserID) {
    super(
      "Another Inline version currently owns this account; close or reload the other Inline tabs",
    )
    this.name = "InlineCoreAccountOwnershipUnavailableError"
  }
}

export type InlineCoreHostOptions = {
  createAccount?: (
    session: AuthSession,
  ) => InlineCoreOwnedAccount
  ownerIdleMs?: number
  clientLeaseMs?: number
  clientLeaseGraceMs?: number
  acquireAccountOwnership?: InlineCoreAccountOwnershipAcquirer
}

type AttachedClient = {
  port: InlineCoreMessagePort
  clientId: string
  accountId: UserID
  lifecycle: InlineCoreClientLifecycle
  activeChatIds: Set<ChatID>
  fullChatWindows: FullChatWindowState
  projectedMessageKeys: Set<MessageKey>
  pendingSendToLatestIntents: Map<ChatID, number>
  messageWindowIntentVersions: Map<ChatID, number>
  sendWindowRequests: Map<
    ChatID,
    { request: symbol; intentVersion: number }
  >
  leaseTimer: ReturnType<typeof setTimeout> | null
}

type OwnedAccount = {
  core: InlineCoreOwnedAccount
  clients: Set<AttachedClient>
  unsubscribeSnapshot: () => void
  unsubscribeChanges: () => void
  unsubscribeAuth: () => void
  idleTimer: ReturnType<typeof setTimeout> | null
  lifecycleTask: Promise<void>
  ownership?: InlineCoreAccountOwnership
}

const rendererKindSet = new Set<DbObjectKind>(
  INLINE_CORE_RENDERER_KINDS,
)
const MAX_MESSAGE_WINDOW_SIZE = 200
const MAX_MESSAGE_REFERENCE_BATCH = 64
const MAX_ACTIVE_CHATS_PER_RENDERER = 8

const defaultCreateAccount = (
  session: AuthSession,
): InlineCoreOwnedAccount => {
  const auth = new AuthStore({ persistence: "memory" })
  auth.login(session)
  return new InlineAccountCore(session.userId, {
    auth,
    observeBrowserLifecycle: false,
  })
}

const isRecord = (
  value: unknown,
): value is Record<string, unknown> =>
  typeof value === "object" && value != null

const messageType = (value: unknown) =>
  isRecord(value) && typeof value.type === "string"
    ? value.type
    : undefined

export class InlineCoreHost {
  private readonly accounts = new Map<UserID, OwnedAccount>()
  private readonly clients = new Map<
    InlineCoreMessagePort,
    AttachedClient
  >()
  private readonly portListeners = new Map<
    InlineCoreMessagePort,
    (event: InlineCoreMessageEvent) => void
  >()
  private readonly mediaRequests = new Map<
    InlineCoreMessagePort,
    Map<string, AbortController>
  >()
  private readonly createAccount: (
    session: AuthSession,
  ) => InlineCoreOwnedAccount
  private readonly ownerIdleMs: number
  private readonly clientLeaseMs: number
  private readonly clientLeaseGraceMs: number
  private readonly acquireAccountOwnership?: InlineCoreAccountOwnershipAcquirer
  private readonly accountCreationTasks = new Map<
    UserID,
    Promise<OwnedAccount>
  >()
  private readonly accountOwnershipReleaseTasks = new Map<
    UserID,
    Promise<void>
  >()
  private readonly portLeaseGraceTimers = new Map<
    InlineCoreMessagePort,
    ReturnType<typeof setTimeout>
  >()
  private shutdownTask: Promise<void> | null = null
  private shuttingDown = false

  constructor(options: InlineCoreHostOptions = {}) {
    this.createAccount =
      options.createAccount ?? defaultCreateAccount
    this.ownerIdleMs = options.ownerIdleMs ?? 30_000
    this.clientLeaseMs = options.clientLeaseMs ?? 120_000
    this.clientLeaseGraceMs = options.clientLeaseGraceMs ?? 5_000
    this.acquireAccountOwnership = options.acquireAccountOwnership
  }

  attachPort(port: InlineCoreMessagePort) {
    if (this.portListeners.has(port)) return
    const listener = (event: InlineCoreMessageEvent) => {
      void this.handleMessage(port, event.data).catch(
        (error: unknown) => {
          this.sendError(
            port,
            "request-failed",
            error instanceof Error
              ? error.message
              : "Inline core host failed to process a message",
          )
        },
      )
    }
    this.portListeners.set(port, listener)
    port.addEventListener("message", listener)
    port.start?.()
  }

  /**
   * Stops every account before an external ownership primitive is released.
   * SharedWorker lifetime normally owns this implicitly; BroadcastChannel's
   * Web-Lock fallback needs an explicit awaited handoff boundary.
   */
  shutdown(): Promise<void> {
    if (this.shutdownTask) return this.shutdownTask
    this.shuttingDown = true
    this.shutdownTask = this.finishShutdown()
    return this.shutdownTask
  }

  private async finishShutdown() {
    for (const port of Array.from(this.portListeners.keys())) {
      this.detachPort(port)
    }
    await Promise.allSettled(this.accountCreationTasks.values())
    for (const account of Array.from(this.accounts.values())) {
      if (account.idleTimer) {
        clearTimeout(account.idleTimer)
        account.idleTimer = null
      }
      await account.lifecycleTask.catch(() => undefined)
      await account.core.stop().catch(() => undefined)
      account.unsubscribeSnapshot()
      account.unsubscribeChanges()
      account.unsubscribeAuth()
      this.accounts.delete(account.core.accountId)
      await account.ownership?.release().catch(() => undefined)
    }
  }

  detachPort(port: InlineCoreMessagePort) {
    const graceTimer = this.portLeaseGraceTimers.get(port)
    if (graceTimer) {
      clearTimeout(graceTimer)
      this.portLeaseGraceTimers.delete(port)
    }
    const listener = this.portListeners.get(port)
    if (listener) {
      port.removeEventListener?.("message", listener)
      this.portListeners.delete(port)
    }
    this.detachClient(port)
    port.close?.()
  }

  private async handleMessage(
    port: InlineCoreMessagePort,
    rawMessage: unknown,
  ) {
    if (messageType(rawMessage) === "inlineCoreHello") {
      await this.handleHello(
        port,
        rawMessage as InlineCoreClientMessage,
      )
      return
    }

    const client = this.clients.get(port)
    if (!client) {
      this.sendError(
        port,
        "not-attached",
        "Inline core client must complete its handshake first",
      )
      return
    }
    if (!isRecord(rawMessage)) {
      this.sendError(
        port,
        "invalid-message",
        "Inline core message is not an object",
      )
      return
    }

    const account = this.accounts.get(client.accountId)
    if (!account) {
      this.sendError(
        port,
        "not-attached",
        "Inline account owner is unavailable",
      )
      return
    }
    this.refreshClientLease(client)

    switch (rawMessage.type) {
      case "inlineCoreExecute":
        await this.execute(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreExecute" }
          >,
        )
        return
      case "inlineCoreMutateAccepted":
        await this.mutateAccepted(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreMutateAccepted" }
          >,
        )
        return
      case "inlineCoreCreateThread":
        await this.createThread(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreCreateThread" }
          >,
        )
        return
      case "inlineCoreResendMessage":
        await this.resendMessage(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreResendMessage" }
          >,
        )
        return
      case "inlineCoreHydrateMessageWindow":
        await this.hydrateMessageWindow(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreHydrateMessageWindow" }
          >,
        )
        return
      case "inlineCoreLoadLocalWindowAroundMessage":
        await this.loadLocalWindowAroundMessage(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreLoadLocalWindowAroundMessage" }
          >,
        )
        return
      case "inlineCoreLoadMedia":
        await this.loadMedia(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreLoadMedia" }
          >,
        )
        return
      case "inlineCoreLoadCachedMedia":
        await this.loadCachedMedia(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreLoadCachedMedia" }
          >,
        )
        return
      case "inlineCoreCancelMedia":
        this.cancelMedia(
          port,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreCancelMedia" }
          >,
        )
        return
      case "inlineCoreLoadMessageDraft":
        await this.loadMessageDraft(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreLoadMessageDraft" }
          >,
        )
        return
      case "inlineCoreLoadMessageReferences":
        await this.loadMessageReferences(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreLoadMessageReferences" }
          >,
        )
        return
      case "inlineCoreUpdateMessageDraft":
        await this.updateMessageDraft(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreUpdateMessageDraft" }
          >,
        )
        return
      case "inlineCoreClearMessageDraft":
        await this.clearMessageDraft(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreClearMessageDraft" }
          >,
        )
        return
      case "inlineCoreLifecycle": {
        const message = rawMessage as Extract<
          InlineCoreClientMessage,
          { type: "inlineCoreLifecycle" }
        >
        if (
          typeof message.lifecycle?.visible !== "boolean" ||
          typeof message.lifecycle?.online !== "boolean"
        ) {
          this.sendError(
            port,
            "invalid-message",
            "Inline core lifecycle is invalid",
          )
          return
        }
        await this.respond(port, message.requestId, async () => {
          client.lifecycle = message.lifecycle
          await this.applyAggregateLifecycle(account)
          return {}
        })
        return
      }
      case "inlineCoreSetActiveChats": {
        if (
          !Array.isArray(rawMessage.chatIds) ||
          rawMessage.chatIds.length >
            MAX_ACTIVE_CHATS_PER_RENDERER
        ) {
          this.sendError(
            port,
            "invalid-message",
            "Inline active chats are invalid",
          )
          return
        }
        const activeChatIds = new Set<ChatID>()
        for (const rawChatId of rawMessage.chatIds) {
          const chatId = parseInlineId<"chat">(rawChatId, {
            positive: true,
          })
          if (!chatId) {
            this.sendError(
              port,
              "invalid-message",
              "Inline active chats are invalid",
            )
            return
          }
          activeChatIds.add(chatId as ChatID)
        }
        const releasedChatIds = Array.from(
          client.activeChatIds,
        ).filter((chatId) => !activeChatIds.has(chatId))
        for (const chatId of activeChatIds) {
          if (client.fullChatWindows.isActive(chatId)) continue
          client.fullChatWindows.activate(
            chatId,
            this.residentMessagesForChat(account, chatId).map(
              (residentMessage) => residentMessage.id,
            ),
          )
        }
        for (const chatId of releasedChatIds) {
          client.fullChatWindows.release(chatId)
          client.pendingSendToLatestIntents.delete(chatId)
          client.messageWindowIntentVersions.delete(chatId)
          client.sendWindowRequests.delete(chatId)
        }
        client.activeChatIds = activeChatIds
        this.sendProjection(account, client)
        this.releaseInactiveChatWindows(
          account,
          releasedChatIds,
        )
        return
      }
      case "inlineCoreVisibleMessageRange": {
        const chatId = parseInlineId<"chat">(rawMessage.chatId, {
          positive: true,
        })
        const firstVisibleMessageId = parseInlineId<"message">(
          rawMessage.firstVisibleMessageId,
          { positive: true },
        )
        const lastVisibleMessageId = parseInlineId<"message">(
          rawMessage.lastVisibleMessageId,
          { positive: true },
        )
        if (
          !chatId ||
          !firstVisibleMessageId ||
          !lastVisibleMessageId ||
          !client.fullChatWindows.isActive(chatId as ChatID)
        ) {
          // Visible ranges are renderer hints, not state-changing commands.
          // They can legitimately be stale while a route is closing or can
          // contain a local negative optimistic ID before send convergence.
          // Dropping that hint is safe; treating it as a protocol failure
          // would poison an otherwise healthy account core.
          return
        }
        const ordered = this.windowMessagesForClient(
          account,
          client,
          chatId as ChatID,
        )
        const removed = client.fullChatWindows.compact(
          chatId as ChatID,
          ordered.map((residentMessage) => residentMessage.id),
          messageKey(
            chatId as ChatID,
            firstVisibleMessageId,
          ),
          messageKey(
            chatId as ChatID,
            lastVisibleMessageId,
          ),
          FULL_CHAT_RESIDENT_MESSAGE_LIMIT,
        )
        if (removed.length > 0) {
          this.sendProjection(account, client)
          this.reconcileOwnedMessageWindow(
            account,
            chatId as ChatID,
          )
        }
        return
      }
      case "inlineCoreHeartbeat": {
        const nonce = this.validRequestId(rawMessage.nonce)
        if (!nonce) {
          this.sendError(
            port,
            "invalid-message",
            "Inline core heartbeat nonce is invalid",
          )
          return
        }
        port.postMessage({
          type: "inlineCoreHeartbeatAck",
          nonce,
          ownerId: account.core.ownerId,
        })
        return
      }
      case "inlineCoreWake":
        if (client.lifecycle.visible) {
          await account.core.realtime.connection.systemDidWake()
        }
        return
      case "inlineCoreResync":
        port.postMessage({
          type: "inlineCoreProjection",
          projection: this.projectionForClient(account, client),
        })
        return
      case "inlineCoreStopSession":
        await this.stopSession(
          port,
          account,
          rawMessage as Extract<
            InlineCoreClientMessage,
            { type: "inlineCoreStopSession" }
          >,
        )
        return
      case "inlineCoreDetach":
        this.detachPort(port)
        return
      default:
        this.sendError(
          port,
          "invalid-message",
          `Unknown Inline core message: ${String(rawMessage.type)}`,
        )
    }
  }

  private async handleHello(
    port: InlineCoreMessagePort,
    rawMessage: InlineCoreClientMessage,
  ) {
    if (rawMessage.type !== "inlineCoreHello") return
    if (this.shuttingDown) {
      this.sendError(
        port,
        "owner-failed",
        "Inline core owner is shutting down",
      )
      return
    }
    if (
      rawMessage.protocolVersion !==
      INLINE_CORE_PROTOCOL_VERSION
    ) {
      this.sendError(
        port,
        "incompatible-version",
        "Inline core protocol version is incompatible",
      )
      return
    }

    const accountId = parseInlineId<"user">(
      rawMessage.accountId,
      { positive: true },
    )
    const sessionUserId = parseInlineId<"user">(
      rawMessage.session?.userId,
      { positive: true },
    )
    if (
      !accountId ||
      sessionUserId !== accountId ||
      typeof rawMessage.session?.token !== "string" ||
      rawMessage.session.token.length === 0 ||
      typeof rawMessage.clientId !== "string" ||
      rawMessage.clientId.length === 0 ||
      typeof rawMessage.lifecycle?.visible !== "boolean" ||
      typeof rawMessage.lifecycle?.online !== "boolean"
    ) {
      this.sendError(
        port,
        "invalid-message",
        "Inline core handshake is invalid",
      )
      return
    }

    // Acknowledge the validated MessagePort before account-lock adoption or
    // cache ownership. Those phases can legitimately outlive the renderer's
    // transport handshake timeout and are observed separately through the
    // core snapshot/readiness boundary.
    port.postMessage({
      type: "inlineCoreHandshakeAccepted",
      protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
      accountId,
    })

    this.detachClient(port)
    let account: OwnedAccount
    try {
      account = await this.getOrCreateOwnedAccount({
        token: rawMessage.session.token,
        userId: accountId,
      })
    } catch (error) {
      if (error instanceof InlineCoreAccountOwnershipUnavailableError) {
        this.sendError(port, "owner-failed", error.message)
        return
      }
      throw error
    }
    if (account.idleTimer) {
      clearTimeout(account.idleTimer)
      account.idleTimer = null
    }

    const client: AttachedClient = {
      port,
      clientId: rawMessage.clientId,
      accountId,
      lifecycle: rawMessage.lifecycle,
      activeChatIds: new Set(),
      fullChatWindows: new FullChatWindowState(),
      projectedMessageKeys: new Set(),
      pendingSendToLatestIntents: new Map(),
      messageWindowIntentVersions: new Map(),
      sendWindowRequests: new Map(),
      leaseTimer: null,
    }
    this.clients.set(port, client)
    account.clients.add(client)
    this.refreshClientLease(client)

    port.postMessage({
      type: "inlineCoreReady",
      identity: {
        protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
        ownerId: account.core.ownerId,
        accountId,
      },
      snapshot: account.core.getSnapshot(),
      projection: this.projectionForClient(account, client),
    })
    this.applyAggregateLifecycle(account)
    void account.core.start()
  }

  private async getOrCreateOwnedAccount(
    session: AuthSession,
  ): Promise<OwnedAccount> {
    const existing = this.accounts.get(session.userId)
    if (existing) {
      await existing.core.updateSession(session)
      return existing
    }
    await this.accountOwnershipReleaseTasks.get(session.userId)

    let task = this.accountCreationTasks.get(session.userId)
    if (!task) {
      task = this.createOwnedAccount(session).then((account) => {
        if (!this.accounts.has(session.userId)) {
          this.accounts.set(session.userId, account)
        }
        return account
      })
      this.accountCreationTasks.set(session.userId, task)
    }
    try {
      const account = await task
      await account.core.updateSession(session)
      return account
    } finally {
      if (this.accountCreationTasks.get(session.userId) === task) {
        this.accountCreationTasks.delete(session.userId)
      }
    }
  }

  private async createOwnedAccount(
    session: AuthSession,
  ): Promise<OwnedAccount> {
    const acquiredOwnership = this.acquireAccountOwnership
      ? await this.acquireAccountOwnership(session.userId)
      : undefined
    if (this.acquireAccountOwnership && !acquiredOwnership) {
      throw new InlineCoreAccountOwnershipUnavailableError(
        session.userId,
      )
    }
    const ownership = acquiredOwnership ?? undefined
    try {
      const core = this.createAccount(session)
      const account: OwnedAccount = {
        core,
        clients: new Set(),
        unsubscribeSnapshot: () => undefined,
        unsubscribeChanges: () => undefined,
        unsubscribeAuth: () => undefined,
        idleTimer: null,
        lifecycleTask: Promise.resolve(),
        ownership,
      }
      account.unsubscribeSnapshot = core.subscribe(() => {
        this.broadcast(account, {
          type: "inlineCoreSnapshot",
          snapshot: core.getSnapshot(),
        })
      })
      account.unsubscribeChanges =
        core.db.subscribeToResidentChanges((batch) => {
          for (const client of account.clients) {
            client.port.postMessage({
              type: "inlineCoreChanges",
              batch: this.rendererBatchForClient(
                account,
                client,
                batch,
              ),
            })
          }
        })
      let hadSession = core.auth.isLoggedIn()
      account.unsubscribeAuth = core.auth.subscribe((state) => {
        const hasSession =
          state.token != null && state.currentUserId != null
        if (hadSession && !hasSession) {
          this.broadcast(account, {
            type: "inlineCoreAuthInvalidated",
          })
        }
        hadSession = hasSession
      })
      return account
    } catch (error) {
      await ownership?.release().catch(() => undefined)
      throw error
    }
  }

  private rendererBatchForClient(
    account: OwnedAccount,
    client: AttachedClient,
    batch: DbResidentChangeBatch,
  ): InlineCoreProjectionChanges {
    for (const change of batch.changes) {
      if (
        change.object?.kind !== DbObjectKind.Message ||
        !change.object.out ||
        change.object.status !== MessageSendingStatus.Sending ||
        client.pendingSendToLatestIntents.get(
          change.object.chatId,
        ) !==
          client.messageWindowIntentVersions.get(
            change.object.chatId,
          ) ||
        !client.fullChatWindows.isActive(change.object.chatId)
      ) {
        continue
      }
      if (
        !client.fullChatWindows.isAtLatest(
          change.object.chatId,
        )
      ) {
        client.fullChatWindows.replace(
          change.object.chatId,
          this.pendingSendMessageKeys(
            account,
            change.object.chatId,
          ),
          true,
        )
      }
    }

    for (const change of batch.changes) {
      if (
        change.object?.kind !== DbObjectKind.Message ||
        !client.fullChatWindows.isAtLatest(
          change.object.chatId,
        )
      ) {
        continue
      }
      const chat = account.core.db.get(
        account.core.db.ref(
          DbObjectKind.Chat,
          change.object.chatId,
        ),
      )
      if (chat?.lastMsgId === change.object.messageId) {
        client.fullChatWindows.extend(
          change.object.chatId,
          [change.object.id],
        )
      }
    }

    const desiredMessageKeys = this.desiredMessageKeys(
      account,
      client,
    )
    const changes = new Map<string, DbResidentChangeBatch["changes"][number]>()
    for (const change of batch.changes) {
      if (!rendererKindSet.has(change.kind)) continue
      if (
        change.kind === DbObjectKind.Message &&
        !desiredMessageKeys.has(change.id as MessageKey)
      ) {
        continue
      }
      changes.set(`${change.kind}:${change.id}`, change)
    }
    for (const key of client.projectedMessageKeys) {
      if (!desiredMessageKeys.has(key)) {
        changes.set(`message:${key}`, {
          kind: DbObjectKind.Message,
          id: key,
        })
      }
    }
    for (const key of desiredMessageKeys) {
      if (client.projectedMessageKeys.has(key)) continue
      const object = account.core.db.get(
        account.core.db.ref(DbObjectKind.Message, key),
      )
      if (object) {
        changes.set(`message:${key}`, {
          kind: DbObjectKind.Message,
          id: key,
          object,
        })
      }
    }
    client.projectedMessageKeys = desiredMessageKeys
    return {
      revision: batch.revision,
      changes: Array.from(changes.values()),
      messageWindowKeys: Array.from(
        client.fullChatWindows.allKeys(),
      ),
    }
  }

  private projectionForClient(
    account: OwnedAccount,
    client: AttachedClient,
  ): InlineCoreProjection {
    const snapshot = account.core.db.residentSnapshot(
      INLINE_CORE_RENDERER_KINDS,
    )
    const desiredMessageKeys = this.desiredMessageKeys(
      account,
      client,
    )
    client.projectedMessageKeys = desiredMessageKeys
    return {
      revision: snapshot.revision,
      objects: snapshot.objects.filter(
        (object) =>
          object.kind !== DbObjectKind.Message ||
          desiredMessageKeys.has(object.id),
      ),
      messageWindowKeys: Array.from(
        client.fullChatWindows.allKeys(),
      ),
    }
  }

  private desiredMessageKeys(
    account: OwnedAccount,
    client: AttachedClient,
  ) {
    const desired = client.fullChatWindows.allKeys()
    const snapshot = account.core.db.residentSnapshot([
      DbObjectKind.Chat,
      DbObjectKind.Message,
    ])
    for (const object of snapshot.objects) {
      if (
        object.kind === DbObjectKind.Chat &&
        object.lastMsgId != null
      ) {
        desired.add(messageKey(object.id, object.lastMsgId))
      }
      if (
        object.kind === DbObjectKind.Message &&
        (object.status === MessageSendingStatus.Sending ||
          object.status === MessageSendingStatus.Failed ||
          (object.reactionIntents?.length ?? 0) > 0)
      ) {
        desired.add(object.id)
      }
    }
    return desired
  }

  private residentMessagesForChat(
    account: OwnedAccount,
    chatId: ChatID,
  ) {
    return account.core.db
      .queryCollection<
        DbObjectKind.Message,
        Message,
        DbQueryPlanType.Objects
      >(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
        (message) => message.chatId === chatId,
      )
      .sort(compareMessagesByWindow)
  }

  private pendingSendMessageKeys(
    account: OwnedAccount,
    chatId: ChatID,
  ) {
    return this.residentMessagesForChat(account, chatId)
      .filter(
        (message) =>
          message.status === MessageSendingStatus.Sending ||
          message.status === MessageSendingStatus.Failed,
      )
      .map((message) => message.id)
  }

  private prepareSendWindow(
    account: OwnedAccount,
    client: AttachedClient,
    chatId: ChatID,
  ) {
    const intentVersion = this.beginMessageWindowIntent(
      client,
      chatId,
    )
    client.pendingSendToLatestIntents.set(
      chatId,
      intentVersion,
    )
    const request = Symbol(`send-window-${chatId}`)
    client.sendWindowRequests.set(chatId, {
      request,
      intentVersion,
    })

    void account.core.db
      .hydrateMessageWindowDetails(chatId, { limit: 60 })
      .then((latest) => {
        if (
          this.clients.get(client.port) !== client ||
          !client.fullChatWindows.isActive(chatId) ||
          client.sendWindowRequests.get(chatId)?.request !==
            request ||
          !this.isCurrentMessageWindowIntent(
            client,
            chatId,
            intentVersion,
          )
        ) {
          return
        }
        client.sendWindowRequests.delete(chatId)
        client.fullChatWindows.replace(
          chatId,
          Array.from(
            new Set([
              ...latest.messageKeys,
              ...this.pendingSendMessageKeys(account, chatId),
            ]),
          ),
          true,
        )
        this.reconcileOwnedMessageWindow(account, chatId)
        this.sendProjection(account, client)
      })
      .catch(() => {
        if (
          client.sendWindowRequests.get(chatId)?.request ===
          request
        ) {
          client.sendWindowRequests.delete(chatId)
        }
      })
    return intentVersion
  }

  private beginMessageWindowIntent(
    client: AttachedClient,
    chatId: ChatID,
  ) {
    const version =
      (client.messageWindowIntentVersions.get(chatId) ?? 0) + 1
    client.messageWindowIntentVersions.set(chatId, version)
    client.sendWindowRequests.delete(chatId)
    return version
  }

  private isCurrentMessageWindowIntent(
    client: AttachedClient,
    chatId: ChatID,
    version: number,
  ) {
    return (
      (client.messageWindowIntentVersions.get(chatId) ?? 0) ===
      version
    )
  }

  private windowMessagesForClient(
    account: OwnedAccount,
    client: AttachedClient,
    chatId: ChatID,
  ) {
    const keys = new Set(client.fullChatWindows.keys(chatId))
    return this.residentMessagesForChat(account, chatId).filter(
      (message) => keys.has(message.id),
    )
  }

  private sendProjection(
    account: OwnedAccount,
    client: AttachedClient,
  ) {
    client.port.postMessage({
      type: "inlineCoreProjection",
      projection: this.projectionForClient(account, client),
    })
  }

  private reconcileOwnedMessageWindow(
    account: OwnedAccount,
    chatId: ChatID,
  ) {
    const retained = new Set<MessageKey>()
    for (const client of account.clients) {
      for (const key of client.fullChatWindows.keys(chatId)) {
        retained.add(key)
      }
    }
    account.core.db.reconcileResidentMessageWindow(
      chatId,
      retained,
    )
  }

  private execute(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreExecute" }
    >,
  ) {
    return this.respond(port, message.requestId, async () => {
      const transaction = decodeCoreTransaction(
        message.transaction,
      )
      const client = this.clients.get(port)
      let sendChatId: ChatID | undefined
      let sendIntentVersion: number | undefined
      const historyIntentVersions =
        client &&
        message.transaction.method === Method.GET_CHAT_HISTORY
          ? new Map(
              Array.from(client.activeChatIds, (chatId) => [
                chatId,
                client.messageWindowIntentVersions.get(chatId) ??
                  0,
              ]),
            )
          : undefined
      if (
        client &&
        message.transaction.method === Method.SEND_MESSAGE &&
        isRecord(message.transaction.context)
      ) {
        const chatId = parseInlineId<"chat">(
          message.transaction.context.chatId,
          { positive: true },
        )
        if (chatId && client.fullChatWindows.isActive(chatId)) {
          sendChatId = chatId as ChatID
          sendIntentVersion = this.prepareSendWindow(
            account,
            client,
            sendChatId,
          )
        }
      }

      let result: RpcResult["result"] | undefined
      try {
        result = await account.core.realtime.execute(transaction)
      } finally {
        if (sendChatId && client) {
          if (
            client.pendingSendToLatestIntents.get(sendChatId) ===
            sendIntentVersion
          ) {
            client.pendingSendToLatestIntents.delete(sendChatId)
          }
        }
      }
      if (
        client &&
        message.transaction.method === Method.GET_CHAT_HISTORY &&
        result?.oneofKind === "getChatHistory"
      ) {
        const keysByChat = new Map<ChatID, MessageKey[]>()
        for (const protocolMessage of result.getChatHistory.messages) {
          const key = protocolMessageKey(protocolMessage)
          const exactChatId = parseInlineId<"chat">(
            protocolMessage.chatId,
            { positive: true },
          )
          if (!exactChatId) continue
          const keys = keysByChat.get(exactChatId) ?? []
          keys.push(key)
          keysByChat.set(exactChatId, keys)
        }
        const context = isRecord(message.transaction.context)
          ? message.transaction.context
          : {}
        const mode = context.mode
        for (const [chatId, keys] of keysByChat) {
          const historyIntentVersion =
            historyIntentVersions?.get(chatId)
          if (
            historyIntentVersion == null ||
            !this.isCurrentMessageWindowIntent(
              client,
              chatId,
              historyIntentVersion,
            )
          ) {
            continue
          }
          if (
            mode === GetChatHistoryMode.HISTORY_MODE_LATEST ||
            mode === GetChatHistoryMode.HISTORY_MODE_AROUND
          ) {
            client.fullChatWindows.replace(
              chatId,
              mode === GetChatHistoryMode.HISTORY_MODE_LATEST
                ? Array.from(
                    new Set([
                      ...keys,
                      ...this.pendingSendMessageKeys(
                        account,
                        chatId,
                      ),
                    ]),
                  )
                : keys,
              mode === GetChatHistoryMode.HISTORY_MODE_LATEST,
            )
          } else {
            client.fullChatWindows.extend(chatId, keys)
            const chat = account.core.db.get(
              account.core.db.ref(DbObjectKind.Chat, chatId),
            )
            if (
              chat?.lastMsgId != null &&
              keys.includes(messageKey(chatId, chat.lastMsgId))
            ) {
              client.fullChatWindows.setAtLatest(chatId, true)
            }
          }
          this.reconcileOwnedMessageWindow(account, chatId)
        }
        this.sendProjection(account, client)
      }
      return { result }
    })
  }

  private mutateAccepted(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreMutateAccepted" }
    >,
  ) {
    return this.respond(port, message.requestId, async () => {
      const transaction = decodeCoreTransaction(
        message.transaction,
      )
      await account.core.realtime.mutateAccepted(transaction)
      return {}
    })
  }

  private createThread(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreCreateThread" }
    >,
  ) {
    const requestId = this.validRequestId(message.requestId)
    if (!requestId || !this.isValidCreateThreadInput(message.input)) {
      this.sendError(
        port,
        "invalid-message",
        "Inline create-thread request is invalid",
        requestId,
      )
      return
    }
    return this.respond(port, requestId, async () => ({
      chatId: await account.core.realtime.createThread(message.input),
    }))
  }

  private isValidCreateThreadInput(
    value: unknown,
  ): value is CreateThreadInput {
    if (!value || typeof value !== "object") return false
    const input = value as Partial<CreateThreadInput>
    if (
      typeof input.isPublic !== "boolean" ||
      !Array.isArray(input.participants) ||
      input.participants.length === 0 ||
      input.participants.length > 100 ||
      (input.title != null && typeof input.title !== "string") ||
      (input.emoji != null && typeof input.emoji !== "string")
    ) {
      return false
    }
    if (
      input.spaceId != null &&
      parseInlineId<"space">(input.spaceId, { positive: true }) == null
    ) {
      return false
    }
    return input.participants.every(
      (value) =>
        parseInlineId<"user">(value, { positive: true }) != null,
    )
  }

  private resendMessage(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreResendMessage" }
    >,
  ) {
    const chatId = parseInlineId<"chat">(message.chatId, {
      positive: true,
    })
    const messageId = parseInlineId<"message">(
      message.messageId,
    )
    if (!chatId || !messageId || BigInt(messageId) === 0n) {
      this.sendError(
        port,
        "invalid-message",
        "Inline failed message identity is invalid",
        this.validRequestId(message.requestId),
      )
      return Promise.resolve()
    }

    const client = this.clients.get(port)
    const sendIntentVersion =
      client?.fullChatWindows.isActive(chatId as ChatID)
        ? this.prepareSendWindow(
            account,
            client,
            chatId as ChatID,
          )
        : undefined
    return this.respond(port, message.requestId, async () => {
      try {
        const result =
          await account.core.realtime.resendMessage(
            chatId as ChatID,
            messageId as MessageID,
          )
        return { result }
      } finally {
        if (
          client &&
          client.pendingSendToLatestIntents.get(
            chatId as ChatID,
          ) === sendIntentVersion
        ) {
          client.pendingSendToLatestIntents.delete(
            chatId as ChatID,
          )
        }
      }
    })
  }

  private hydrateMessageWindow(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreHydrateMessageWindow" }
    >,
  ) {
    const chatId = parseInlineId<"chat">(
      message.chatId,
      { positive: true },
    )
    const before =
      message.before == null
        ? undefined
        : parseMessageWindowCursor(message.before)
    const after =
      message.after == null
        ? undefined
        : parseMessageWindowCursor(message.after)
    if (
      !chatId ||
      !Number.isInteger(message.limit) ||
      message.limit < 1 ||
      message.limit > MAX_MESSAGE_WINDOW_SIZE ||
      (message.before != null && !before) ||
      (message.after != null && !after) ||
      (before != null && after != null)
    ) {
      this.sendError(
        port,
        "invalid-message",
        "Inline message window is invalid",
        this.validRequestId(message.requestId),
      )
      return Promise.resolve()
    }
    return this.respond(
      port,
      message.requestId,
      async () => {
        const intentClient = this.clients.get(port)
        const intentVersion = intentClient
          ? this.beginMessageWindowIntent(
              intentClient,
              chatId as ChatID,
            )
          : undefined
        const result =
          await account.core.db.hydrateMessageWindowDetails(
            chatId as ChatID,
            {
              limit: message.limit,
              before,
              after,
            },
          )
        const client = this.clients.get(port)
        if (
          !client ||
          client !== intentClient ||
          intentVersion == null ||
          !this.isCurrentMessageWindowIntent(
            client,
            chatId as ChatID,
            intentVersion,
          )
        ) {
          return { count: result.count }
        }
        if (before == null && after == null) {
          client.fullChatWindows.replace(
            chatId as ChatID,
            Array.from(
              new Set([
                ...result.messageKeys,
                ...this.pendingSendMessageKeys(
                  account,
                  chatId as ChatID,
                ),
              ]),
            ),
            true,
          )
        } else {
          client.fullChatWindows.extend(
            chatId as ChatID,
            result.messageKeys,
          )
          const chat = account.core.db.get(
            account.core.db.ref(
              DbObjectKind.Chat,
              chatId as ChatID,
            ),
          )
          if (
            chat?.lastMsgId != null &&
            result.messageKeys.includes(
              messageKey(
                chatId as ChatID,
                chat.lastMsgId,
              ),
            )
          ) {
            client.fullChatWindows.setAtLatest(
              chatId as ChatID,
              true,
            )
          }
        }
        this.sendProjection(account, client)
        return { count: result.count }
      },
    )
  }

  private loadLocalWindowAroundMessage(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreLoadLocalWindowAroundMessage" }
    >,
  ) {
    const chatId = parseInlineId<"chat">(
      message.chatId,
      { positive: true },
    )
    const anchorMessageId = parseInlineId<"message">(
      message.window?.messageId,
      { positive: true },
    )
    const beforeLimit = message.window?.beforeLimit
    const afterLimit = message.window?.afterLimit
    if (
      !chatId ||
      !anchorMessageId ||
      !Number.isInteger(beforeLimit) ||
      !Number.isInteger(afterLimit) ||
      beforeLimit < 0 ||
      afterLimit < 0 ||
      beforeLimit + afterLimit + 1 > MAX_MESSAGE_WINDOW_SIZE
    ) {
      this.sendError(
        port,
        "invalid-message",
        "Inline around-target message window is invalid",
        this.validRequestId(message.requestId),
      )
      return Promise.resolve()
    }
    return this.respond(
      port,
      message.requestId,
      async () => {
        const intentClient = this.clients.get(port)
        const intentVersion = intentClient
          ? this.beginMessageWindowIntent(
              intentClient,
              chatId as ChatID,
            )
          : undefined
        const result =
          await account.core.db.loadLocalWindowAroundMessageDetails(
            chatId as ChatID,
            {
              messageId: anchorMessageId,
              beforeLimit,
              afterLimit,
            },
            false,
          )
        const client = this.clients.get(port)
        if (
          !client ||
          client !== intentClient ||
          intentVersion == null ||
          !this.isCurrentMessageWindowIntent(
            client,
            chatId as ChatID,
            intentVersion,
          )
        ) {
          return { found: result.found }
        }
        client.fullChatWindows.replace(
          chatId as ChatID,
          result.messageKeys,
          false,
        )
        this.sendProjection(account, client)
        this.reconcileOwnedMessageWindow(
          account,
          chatId as ChatID,
        )
        return { found: result.found }
      },
    )
  }

  private stopSession(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreStopSession" }
    >,
  ) {
    return this.respond(
      port,
      message.requestId,
      async () => {
        await account.core.stop()
        account.core.auth.logout()
        return {}
      },
    )
  }

  private loadMessageReferences(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreLoadMessageReferences" }
    >,
  ) {
    const chatId = parseInlineId<"chat">(message.chatId, {
      positive: true,
    })
    const messageIds = Array.isArray(message.messageIds)
      ? message.messageIds.map((id) =>
          parseInlineId<"message">(id, { positive: true }),
        )
      : []
    const peer = message.peerId?.type
    const peerValid =
      peer?.oneofKind === "user"
        ? Boolean(
            parseInlineId<"user">(peer.user.userId, {
              positive: true,
            }),
          )
        : peer?.oneofKind === "chat"
          ? Boolean(
              parseInlineId<"chat">(peer.chat.chatId, {
                positive: true,
              }),
            )
          : false
    if (
      !chatId ||
      !peerValid ||
      messageIds.length === 0 ||
      messageIds.length > MAX_MESSAGE_REFERENCE_BATCH ||
      messageIds.some((id) => id == null)
    ) {
      this.sendError(
        port,
        "invalid-message",
        "Inline message reference request is invalid",
        this.validRequestId(message.requestId),
      )
      return Promise.resolve()
    }
    return this.respond(port, message.requestId, async () => ({
      messageReferences: await account.core.messageReferences.load({
        peerId: message.peerId,
        chatId,
        messageIds: messageIds as NonNullable<(typeof messageIds)[number]>[],
      }),
    }))
  }

  private loadMessageDraft(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreLoadMessageDraft" }
    >,
  ) {
    const peer = this.validMessageDraftPeer(message.peer)
    if (!peer) {
      this.sendError(
        port,
        "invalid-message",
        "Inline message draft peer is invalid",
        this.validRequestId(message.requestId),
      )
      return Promise.resolve()
    }
    return this.respond(port, message.requestId, async () => {
      await account.core.messageDrafts.load(peer)
      return {}
    })
  }

  private updateMessageDraft(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreUpdateMessageDraft" }
    >,
  ) {
    const peer = this.validMessageDraftPeer(message.peer)
    if (
      !peer ||
      typeof message.text !== "string" ||
      message.text.length > 100_000 ||
      !isInlineMessageEntities(message.entities, message.text)
    ) {
      this.sendError(
        port,
        "invalid-message",
        "Inline message draft update is invalid",
        this.validRequestId(message.requestId),
      )
      return Promise.resolve()
    }
    return this.respond(port, message.requestId, async () => {
      await account.core.messageDrafts.update(
        peer,
        message.text,
        message.entities,
      )
      return {}
    })
  }

  private clearMessageDraft(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreClearMessageDraft" }
    >,
  ) {
    const peer = this.validMessageDraftPeer(message.peer)
    if (!peer) {
      this.sendError(
        port,
        "invalid-message",
        "Inline message draft clear is invalid",
        this.validRequestId(message.requestId),
      )
      return Promise.resolve()
    }
    return this.respond(port, message.requestId, async () => {
      await account.core.messageDrafts.clear(peer)
      return {}
    })
  }

  private loadMedia(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreLoadMedia" }
    >,
  ) {
    const requestId = this.validRequestId(
      message.requestId,
    )
    const remoteUrl = this.validRemoteMediaUrl(
      message.remoteUrl,
    )
    if (
      !requestId ||
      typeof message.key !== "string" ||
      message.key.length === 0 ||
      message.key.length > 1_024 ||
      !remoteUrl
    ) {
      this.sendError(
        port,
        "invalid-message",
        "Inline media request is invalid",
        requestId,
      )
      return Promise.resolve()
    }

    return this.runMediaRequest(
      port,
      requestId,
      (signal) =>
        account.core.mediaLoader.load(message.key, remoteUrl, {
          signal,
        }),
    )
  }

  private loadCachedMedia(
    port: InlineCoreMessagePort,
    account: OwnedAccount,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreLoadCachedMedia" }
    >,
  ) {
    const requestId = this.validRequestId(message.requestId)
    if (
      !requestId ||
      typeof message.key !== "string" ||
      message.key.length === 0 ||
      message.key.length > 1_024
    ) {
      this.sendError(
        port,
        "invalid-message",
        "Inline cached media request is invalid",
        requestId,
      )
      return Promise.resolve()
    }
    return this.runMediaRequest(
      port,
      requestId,
      (signal) =>
        account.core.mediaLoader.loadCached(message.key, {
          signal,
        }),
    )
  }

  private runMediaRequest(
    port: InlineCoreMessagePort,
    requestId: string,
    operation: (
      signal: AbortSignal,
    ) => Promise<InlineMediaResource | undefined>,
  ) {
    let requests = this.mediaRequests.get(port)
    if (!requests) {
      requests = new Map()
      this.mediaRequests.set(port, requests)
    }
    if (requests.has(requestId)) {
      this.sendError(
        port,
        "invalid-message",
        "Inline media request ID is already active",
        requestId,
      )
      return Promise.resolve()
    }
    const controller = new AbortController()
    requests.set(requestId, controller)
    const response = this.respond(port, requestId, async () => {
      const media = await operation(controller.signal)
      return media ? { media } : {}
    })
    return response.finally(() => {
      const active = this.mediaRequests.get(port)
      if (active?.get(requestId) === controller) {
        active.delete(requestId)
        if (active.size === 0) {
          this.mediaRequests.delete(port)
        }
      }
    })
  }

  private cancelMedia(
    port: InlineCoreMessagePort,
    message: Extract<
      InlineCoreClientMessage,
      { type: "inlineCoreCancelMedia" }
    >,
  ) {
    const requestId = this.validRequestId(
      message.requestId,
    )
    if (!requestId) {
      this.sendError(
        port,
        "invalid-message",
        "Inline media cancellation is invalid",
      )
      return
    }
    this.mediaRequests.get(port)?.get(requestId)?.abort()
  }

  private async respond(
    port: InlineCoreMessagePort,
    requestId: string,
    operation: () => Promise<{
      result?: RpcResult["result"]
      chatId?: ChatID
      count?: number
      found?: boolean
      media?: InlineMediaResource
      messageReferences?: Message[]
    }>,
  ) {
    if (!this.validRequestId(requestId)) {
      this.sendError(
        port,
        "invalid-message",
        "Inline core request ID is invalid",
      )
      return
    }
    try {
      const payload = await operation()
      port.postMessage({
        type: "inlineCoreResult",
        requestId,
        ...payload,
      })
    } catch (error) {
      this.sendError(
        port,
        "request-failed",
        error instanceof Error
          ? error.message
          : "Inline core request failed",
        requestId,
      )
    }
  }

  private applyAggregateLifecycle(account: OwnedAccount) {
    const clients = Array.from(account.clients)
    const visible = clients.some(
      (client) => client.lifecycle.visible,
    )
    const online = clients.some(
      (client) => client.lifecycle.online,
    )
    account.lifecycleTask = account.lifecycleTask
      .catch(() => undefined)
      .then(async () => {
        await account.core.realtime.connection.setNetworkAvailable(
          online,
        )
        await account.core.realtime.connection.setAppActive(
          visible,
        )
      })
    return account.lifecycleTask
  }

  private detachClient(port: InlineCoreMessagePort) {
    const mediaRequests = this.mediaRequests.get(port)
    if (mediaRequests) {
      this.mediaRequests.delete(port)
      for (const controller of mediaRequests.values()) {
        controller.abort()
      }
    }
    const client = this.clients.get(port)
    if (!client) return
    this.clients.delete(port)
    if (client.leaseTimer) {
      clearTimeout(client.leaseTimer)
      client.leaseTimer = null
    }
    const account = this.accounts.get(client.accountId)
    if (!account) return
    account.clients.delete(client)
    this.releaseInactiveChatWindows(
      account,
      Array.from(client.activeChatIds),
    )
    this.applyAggregateLifecycle(account)
    if (account.clients.size > 0 || account.idleTimer) return
    account.idleTimer = setTimeout(() => {
      account.idleTimer = null
      if (account.clients.size > 0) return
      const finish = () => {
        if (account.clients.size > 0) {
          void account.core.start()
          return
        }
        account.unsubscribeSnapshot()
        account.unsubscribeChanges()
        account.unsubscribeAuth()
        this.accounts.delete(account.core.accountId)
        this.releaseAccountOwnership(account)
      }
      void account.core.stop().then(finish, finish)
    }, this.ownerIdleMs)
  }

  private releaseAccountOwnership(account: OwnedAccount) {
    if (!account.ownership) return
    const accountId = account.core.accountId
    const release = account.ownership.release()
    this.accountOwnershipReleaseTasks.set(accountId, release)
    const clearRelease = () => {
      if (this.accountOwnershipReleaseTasks.get(accountId) === release) {
        this.accountOwnershipReleaseTasks.delete(accountId)
      }
    }
    void release.then(clearRelease, clearRelease)
  }

  private releaseInactiveChatWindows(
    account: OwnedAccount,
    candidateChatIds: readonly ChatID[],
  ) {
    for (const chatId of candidateChatIds) {
      const stillActive = Array.from(account.clients).some(
        (client) => client.activeChatIds.has(chatId),
      )
      if (!stillActive) {
        account.core.db.releaseResidentMessageWindow(chatId)
      } else {
        this.reconcileOwnedMessageWindow(account, chatId)
      }
    }
  }

  private refreshClientLease(client: AttachedClient) {
    const graceTimer = this.portLeaseGraceTimers.get(client.port)
    if (graceTimer) {
      clearTimeout(graceTimer)
      this.portLeaseGraceTimers.delete(client.port)
    }
    if (client.leaseTimer) {
      clearTimeout(client.leaseTimer)
    }
    client.leaseTimer = setTimeout(() => {
      client.leaseTimer = null
      // Let a throttled but live renderer re-handshake on the same port. A
      // renderer that disappeared without its explicit detach cannot answer;
      // close that abandoned endpoint after one bounded grace so it cannot
      // pin the SharedWorker after the account lock is released.
      this.detachClient(client.port)
      this.sendError(
        client.port,
        "not-attached",
        "Inline core renderer lease expired",
      )
      const graceTimer = setTimeout(() => {
        this.portLeaseGraceTimers.delete(client.port)
        if (!this.clients.has(client.port)) {
          this.detachPort(client.port)
        }
      }, this.clientLeaseGraceMs)
      this.portLeaseGraceTimers.set(client.port, graceTimer)
    }, this.clientLeaseMs)
  }

  private broadcast(
    account: OwnedAccount,
    message: InlineCoreHostMessage,
  ) {
    for (const client of Array.from(account.clients)) {
      try {
        client.port.postMessage(message)
      } catch {
        this.detachPort(client.port)
      }
    }
  }

  private sendError(
    port: InlineCoreMessagePort,
    code: Extract<
      InlineCoreHostMessage,
      { type: "inlineCoreError" }
    >["code"],
    message: string,
    requestId?: string,
  ) {
    try {
      port.postMessage({
        type: "inlineCoreError",
        code,
        message,
        ...(requestId ? { requestId } : {}),
      })
    } catch {
      this.detachPort(port)
    }
  }

  private validRequestId(value: unknown) {
    return typeof value === "string" &&
      value.length > 0 &&
      value.length <= 200
      ? value
      : undefined
  }

  private validMessageDraftPeer(
    value: unknown,
  ): MessageDraftPeer | undefined {
    if (!isRecord(value)) return undefined
    if (value.peerKind === "user") {
      const peerUserId = parseInlineId<"user">(
        value.peerUserId,
        { positive: true },
      )
      return peerUserId
        ? { peerKind: "user", peerUserId }
        : undefined
    }
    if (value.peerKind === "chat") {
      const peerThreadId = parseInlineId<"chat">(
        value.peerThreadId,
        { positive: true },
      )
      return peerThreadId
        ? { peerKind: "chat", peerThreadId }
        : undefined
    }
    return undefined
  }

  private validRemoteMediaUrl(value: unknown) {
    if (
      typeof value !== "string" ||
      value.length === 0 ||
      value.length > 16_384
    ) {
      return undefined
    }
    try {
      const url = new URL(
        value,
        globalThis.location?.href,
      )
      return url.protocol === "https:" ||
        url.protocol === "http:"
        ? value
        : undefined
    } catch {
      return undefined
    }
  }
}

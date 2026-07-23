import {
  encodeCoreTransaction,
  type AuthSession,
  type AuthStore,
  type InlineClientContextValue,
  type LocalMessageWindowAroundOptions,
  type MessageWindowOptions,
  type RealtimeConnectionState,
  type RealtimeService,
  type CreateThreadInput,
  type Transaction,
  messageDraftKey,
  DbObjectKind,
} from "@inline/client/core"
import type { RpcResult } from "@inline-chat/protocol/core"
import {
  parseInlineId,
  type ChatID,
  type MessageID,
  type UserID,
} from "@inline/ids"
import type { InlineMediaResource } from "../media/InlineMediaLoader"
import type { InlineMessageDraftsService } from "../drafts/InlineMessageDrafts"
import { InlineMediaRepository } from "../media/InlineMediaRepository"
import {
  InlineMessageReferences,
  type InlineMessageReferenceRequest,
} from "../messages/InlineMessageReferences"
import { BrowserConnectionLifecycle } from "../runtime/BrowserConnectionLifecycle"
import { InlineProjectionDb } from "./InlineProjectionDb"
import {
  FullChatProgressiveLeases,
  type FullChatProgressiveService,
} from "./FullChatProgressiveService"
import {
  INLINE_CORE_PROTOCOL_VERSION,
  isCompatibleInlineCore,
  type InlineCoreClientLifecycle,
  type InlineCoreClientMessage,
  type InlineCoreBlockingFailure,
  type InlineCoreHostMessage,
  type InlineCoreSnapshot,
} from "./InlineCoreProtocol"

export type InlineCoreClientMessageEvent = {
  data: unknown
}

export type InlineCoreClientPort = {
  postMessage(message: InlineCoreClientMessage): void
  addEventListener(
    type: "message",
    listener: (event: InlineCoreClientMessageEvent) => void,
  ): void
  removeEventListener?(
    type: "message",
    listener: (event: InlineCoreClientMessageEvent) => void,
  ): void
  start?(): void
  close?(): void
}

export type InlineCoreRendererClientOptions = {
  port: InlineCoreClientPort
  /**
   * Retained for the lifetime of the facade so the browser cannot collect the
   * SharedWorker handle while its MessagePort is active. Worker-level errors
   * are terminal for this facade; callers may explicitly construct a fresh
   * owner, but in-flight mutations are never replayed automatically.
   */
  owner?: EventTarget
  ownerName?: string
  auth: AuthStore
  session: AuthSession
  bootTimeoutMs?: number
  ownerReadyTimeoutMs?: number
  requestTimeoutMs?: number
  heartbeatIntervalMs?: number
  heartbeatTimeoutMs?: number
}

type RequestResult = Extract<
  InlineCoreHostMessage,
  { type: "inlineCoreResult" }
>

type RequestContinuation = {
  resolve: (message: RequestResult) => void
  reject: (error: Error) => void
  timeout: ReturnType<typeof setTimeout>
}

type SnapshotListener = () => void

const LOCAL_PROJECTION_REQUEST_TIMEOUT_MS = 5_000

const makeId = (prefix: string) => {
  if (
    typeof crypto !== "undefined" &&
    "randomUUID" in crypto
  ) {
    return `${prefix}-${crypto.randomUUID()}`
  }
  return `${prefix}-${Date.now()}-${Math.random()
    .toString(36)
    .slice(2)}`
}

export class InlineCoreProtocolError extends Error {
  constructor(
    message: string,
    readonly code?: string,
  ) {
    super(message)
    this.name = "InlineCoreProtocolError"
  }
}

/**
 * Renderer-side facade over the worker owner. Views keep synchronous reads
 * from InlineProjectionDb while all persistence, sync, and mutations execute
 * in the core owner.
 */
export class InlineCoreRendererClient
  implements RealtimeService
{
  readonly accountId: UserID
  readonly auth: AuthStore
  readonly db: InlineProjectionDb
  readonly mediaRepository: InlineMediaRepository
  readonly messageDrafts: InlineMessageDraftsService
  readonly messageReferences: InlineMessageReferences
  readonly fullChatProgressive: FullChatProgressiveService
  readonly client: InlineClientContextValue
  readonly ownerName?: string

  connectionState: RealtimeConnectionState = "idle"

  private readonly port: InlineCoreClientPort
  private readonly owner?: EventTarget
  private readonly session: AuthSession
  private readonly clientId = makeId("inline-core-client")
  private readonly bootTimeoutMs: number
  private readonly ownerReadyTimeoutMs: number
  private readonly requestTimeoutMs: number
  private readonly heartbeatIntervalMs: number
  private readonly heartbeatTimeoutMs: number
  private readonly browserLifecycle: BrowserConnectionLifecycle
  private readonly snapshotListeners = new Set<SnapshotListener>()
  private readonly connectionListeners = new Set<
    (state: RealtimeConnectionState) => void
  >()
  private readonly requests = new Map<
    string,
    RequestContinuation
  >()
  private stopTask: Promise<void> | null = null
  private readonly handlePortMessage = (
    event: InlineCoreClientMessageEvent,
  ) => {
    this.receive(event.data)
  }
  private readonly handleOwnerError = (event: Event) => {
    const message =
      event instanceof ErrorEvent && event.message
        ? `Inline core worker failed: ${event.message}`
        : "Inline core worker failed"
    this.failOwner(message)
  }
  private lifecycle: InlineCoreClientLifecycle = {
    visible: true,
    online: true,
  }
  private snapshot: InlineCoreSnapshot
  private connectPromise: Promise<void> | null = null
  private resolveConnect: (() => void) | null = null
  private rejectConnect: ((error: Error) => void) | null = null
  private bootTimer: ReturnType<typeof setTimeout> | null = null
  private heartbeatTimer: ReturnType<typeof setInterval> | null =
    null
  private heartbeatTimeout: ReturnType<typeof setTimeout> | null =
    null
  private pendingHeartbeatNonce: string | null = null
  private detachBrowserLifecycle: (() => void) | null = null
  private attached = false
  private handshakeAccepted = false
  private detached = false
  private activeChatIds: ChatID[] = []
  private ownerFailure: InlineCoreProtocolError | null = null

  constructor(options: InlineCoreRendererClientOptions) {
    this.port = options.port
    this.owner = options.owner
    this.ownerName = options.ownerName
    this.auth = options.auth
    this.session = options.session
    this.accountId = options.session.userId
    this.bootTimeoutMs = options.bootTimeoutMs ?? 2_000
    this.ownerReadyTimeoutMs =
      options.ownerReadyTimeoutMs ?? 30_000
    this.requestTimeoutMs =
      options.requestTimeoutMs ?? 30_000
    this.heartbeatIntervalMs =
      options.heartbeatIntervalMs ?? 5_000
    this.heartbeatTimeoutMs =
      options.heartbeatTimeoutMs ?? 6_000
    this.db = new InlineProjectionDb({
      hydrateMessageWindow: (chatId, window) =>
        this.hydrateMessageWindow(chatId, window),
      loadLocalWindowAroundMessage: (chatId, window) =>
        this.loadLocalWindowAroundMessage(chatId, window),
      requestResync: () => {
        if (this.attached) {
          this.port.postMessage({
            type: "inlineCoreResync",
          })
        }
      },
    })
    this.mediaRepository = new InlineMediaRepository({
      load: (key, remoteUrl, options) =>
        this.loadMedia(key, remoteUrl, options?.signal),
      loadCached: (key, options) =>
        this.loadCachedMedia(key, options?.signal),
    })
    this.messageDrafts = {
      load: async (peer) => {
        await this.start()
        await this.request({
          type: "inlineCoreLoadMessageDraft",
          requestId: this.nextRequestId(),
          peer,
        })
        return this.db.get(
          this.db.ref(
            DbObjectKind.MessageDraft,
            messageDraftKey(peer),
          ),
        )
      },
      update: async (peer, text, entities) => {
        await this.start()
        await this.request({
          type: "inlineCoreUpdateMessageDraft",
          requestId: this.nextRequestId(),
          peer,
          text,
          entities,
        })
      },
      clear: async (peer) => {
        await this.start()
        await this.request({
          type: "inlineCoreClearMessageDraft",
          requestId: this.nextRequestId(),
          peer,
        })
      },
    }
    this.messageReferences = new InlineMessageReferences(
      (request) => this.loadMessageReferences(request),
    )
    this.fullChatProgressive = new FullChatProgressiveLeases(
      (activeChatIds) => {
        this.activeChatIds = [...activeChatIds]
        void this.start().then(() => {
          if (this.detached) return
          this.port.postMessage({
            type: "inlineCoreSetActiveChats",
            chatIds: this.activeChatIds,
          })
        }, () => undefined)
      },
      (
        chatId,
        firstVisibleMessageId,
        lastVisibleMessageId,
      ) => {
        if (!this.attached || this.detached) return
        this.port.postMessage({
          type: "inlineCoreVisibleMessageRange",
          chatId,
          firstVisibleMessageId,
          lastVisibleMessageId,
        })
      },
    )
    this.client = {
      auth: this.auth,
      db: this.db,
      realtime: this,
    }
    this.browserLifecycle = new BrowserConnectionLifecycle({
      connection: this,
      onPageDiscard: () => this.detach(false),
    })
    this.snapshot = {
      protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
      ownerId: "pending",
      accountId: this.accountId,
      phase: "idle",
      cacheReady: false,
      connectionState: "idle",
    }
    this.port.addEventListener(
      "message",
      this.handlePortMessage,
    )
    this.owner?.addEventListener(
      "error",
      this.handleOwnerError,
    )
    this.port.start?.()
  }

  getSnapshot = () => this.snapshot

  canReplaceUnresponsiveBootOwner() {
    return (
      !this.attached &&
      !this.handshakeAccepted &&
      this.snapshot.ownerId === "pending" &&
      this.snapshot.blockingFailure?.code === "owner-unresponsive" &&
      this.snapshot.blockingFailure.message ===
        "Inline core worker did not complete its handshake"
    )
  }

  subscribe = (listener: SnapshotListener) => {
    this.snapshotListeners.add(listener)
    return () => {
      this.snapshotListeners.delete(listener)
    }
  }

  start(): Promise<void> {
    if (this.detached) {
      return Promise.reject(
        new InlineCoreProtocolError(
          "Inline core renderer client was detached",
        ),
      )
    }
    if (this.ownerFailure) {
      return Promise.reject(this.ownerFailure)
    }
    if (this.attached) return Promise.resolve()
    if (this.connectPromise) return this.connectPromise

    if (this.snapshot.blockingFailure) {
      return Promise.reject(
        new InlineCoreProtocolError(
          this.snapshot.blockingFailure.message,
          this.snapshot.blockingFailure.code,
        ),
      )
    }

    this.detachBrowserLifecycle =
      this.browserLifecycle.attach()
    this.connectPromise = new Promise<void>((resolve, reject) => {
      this.resolveConnect = resolve
      this.rejectConnect = reject
    })
    this.bootTimer = setTimeout(() => {
      this.bootTimer = null
      this.failConnect(
        new InlineCoreProtocolError(
          "Inline core worker did not complete its handshake",
          "boot-timeout",
        ),
        "owner-unresponsive",
      )
    }, this.bootTimeoutMs)
    this.port.postMessage({
      type: "inlineCoreHello",
      protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
      clientId: this.clientId,
      accountId: this.accountId,
      session: this.session,
      lifecycle: this.lifecycle,
    })
    return this.connectPromise
  }

  stop() {
    if (this.stopTask) return this.stopTask

    let resolve!: () => void
    let reject!: (cause: unknown) => void
    const task = new Promise<void>((nextResolve, nextReject) => {
      resolve = nextResolve
      reject = nextReject
    })
    // Install the task before AuthStore emits. The provider observes logout
    // synchronously and calls stop() again; both paths must share one owner
    // request rather than enqueue two stop-session commands.
    this.stopTask = task
    void this.stopSessionLocally().then(resolve, reject)
    return task
  }

  private async stopSessionLocally() {
    const ownerStop = this.attached
      ? this.request({
          type: "inlineCoreStopSession",
          requestId: this.nextRequestId(),
        })
      : Promise.resolve()
    // Local credential removal is authoritative and must not wait for a hung
    // or already-terminated SharedWorker. Still await and surface both results
    // so owner lifecycle failures remain diagnosable.
    const [logout, owner] = await Promise.allSettled([
      this.auth.logout(),
      ownerStop,
    ])
    if (logout.status === "rejected") throw logout.reason
    if (owner.status === "rejected") throw owner.reason
  }

  execute(
    transaction: Transaction,
  ): Promise<RpcResult["result"] | undefined> {
    return this.executeRemote(transaction)
  }

  query(
    transaction: Transaction,
  ): Promise<RpcResult["result"] | undefined> {
    return this.executeRemote(transaction)
  }

  mutate(
    transaction: Transaction,
  ): Promise<RpcResult["result"] | undefined> {
    return this.executeRemote(transaction)
  }

  async mutateAccepted(transaction: Transaction): Promise<void> {
    await this.start()
    await this.request({
      type: "inlineCoreMutateAccepted",
      requestId: this.nextRequestId(),
      transaction: encodeCoreTransaction(transaction),
    })
  }

  async createThread(input: CreateThreadInput): Promise<ChatID> {
    await this.start()
    const response = await this.request({
      type: "inlineCoreCreateThread",
      requestId: this.nextRequestId(),
      input,
    })
    const exactChatId = parseInlineId<"chat">(response.chatId, {
      positive: true,
    })
    if (exactChatId == null) {
      throw new InlineCoreProtocolError(
        "Inline core returned an invalid thread identity",
        "invalid-message",
      )
    }
    return exactChatId
  }

  async resendMessage(
    chatId: ChatID,
    messageId: MessageID,
  ): Promise<RpcResult["result"] | undefined> {
    await this.start()
    const response = await this.request({
      type: "inlineCoreResendMessage",
      requestId: this.nextRequestId(),
      chatId,
      messageId,
    })
    return response.result
  }

  onConnectionState(
    listener: (state: RealtimeConnectionState) => void,
  ) {
    this.connectionListeners.add(listener)
    return () => {
      this.connectionListeners.delete(listener)
    }
  }

  async setNetworkAvailable(available: boolean) {
    this.lifecycle = {
      ...this.lifecycle,
      online: available,
    }
    await this.sendLifecycle()
  }

  async setAppActive(active: boolean) {
    this.lifecycle = {
      ...this.lifecycle,
      visible: active,
    }
    const applied = this.sendLifecycle()
    if (active) this.probeOwner()
    await applied
  }

  async systemDidWake() {
    if (!this.attached) return
    this.port.postMessage({ type: "inlineCoreWake" })
    this.probeOwner()
  }

  detach(closePort = true) {
    if (this.detached) return
    this.detached = true
    this.mediaRepository.clear()
    this.detachBrowserLifecycle?.()
    this.detachBrowserLifecycle = null
    if (this.attached) {
      this.port.postMessage({ type: "inlineCoreDetach" })
    }
    this.attached = false
    this.stopHeartbeat()
    this.port.removeEventListener?.(
      "message",
      this.handlePortMessage,
    )
    this.owner?.removeEventListener(
      "error",
      this.handleOwnerError,
    )
    // During page discard, leave the renderer side open for the remainder of
    // the unloading task so the final detach message can cross to the host.
    // Browser context teardown closes it immediately afterward. Explicit
    // runtime/registry detach still closes synchronously.
    if (closePort) this.port.close?.()
    if (!closePort) {
      // A non-persisted pagehide destroys this renderer. Settling application
      // promises during that teardown only runs stale error handlers against a
      // document which is already leaving. The owner has received its detach;
      // abandon local continuations and their timers without presenting a
      // product failure. Explicit runtime/logout detach still rejects below.
      this.abandonConnect()
      this.abandonRequests()
      return
    }
    const error = new InlineCoreProtocolError(
      "Inline core renderer client detached",
    )
    this.failConnect(error)
    this.rejectRequests(error)
  }

  private async executeRemote(transaction: Transaction) {
    await this.start()
    const response = await this.request({
      type: "inlineCoreExecute",
      requestId: this.nextRequestId(),
      transaction: encodeCoreTransaction(transaction),
    })
    return response.result
  }

  private async hydrateMessageWindow(
    chatId: ChatID,
    options: MessageWindowOptions,
  ) {
    await this.start()
    const response = await this.request(
      {
        type: "inlineCoreHydrateMessageWindow",
        requestId: this.nextRequestId(),
        chatId,
        limit: options.limit,
        before: options.before,
        after: options.after,
      },
      Math.min(
        this.requestTimeoutMs,
        LOCAL_PROJECTION_REQUEST_TIMEOUT_MS,
      ),
    )
    return response.count ?? 0
  }

  private async loadLocalWindowAroundMessage(
    chatId: ChatID,
    window: LocalMessageWindowAroundOptions,
  ) {
    await this.start()
    const response = await this.request(
      {
        type: "inlineCoreLoadLocalWindowAroundMessage",
        requestId: this.nextRequestId(),
        chatId,
        window,
      },
      Math.min(
        this.requestTimeoutMs,
        LOCAL_PROJECTION_REQUEST_TIMEOUT_MS,
      ),
    )
    return response.found === true
  }

  private async loadMessageReferences(
    request: InlineMessageReferenceRequest,
  ) {
    await this.start()
    const response = await this.request({
      type: "inlineCoreLoadMessageReferences",
      requestId: this.nextRequestId(),
      ...request,
    })
    return response.messageReferences ?? []
  }

  private async loadMedia(
    key: string,
    remoteUrl: string,
    signal?: AbortSignal,
  ): Promise<InlineMediaResource> {
    const response = await this.requestMedia(
      (requestId) => ({
        type: "inlineCoreLoadMedia",
        requestId,
        key,
        remoteUrl,
      }),
      signal,
    )
    const media = response.media
    if (
      media?.kind === "blob" &&
      media.blob instanceof Blob
    ) {
      return media
    }
    if (
      media?.kind === "remote" &&
      typeof media.url === "string"
    ) {
      return media
    }
    throw new InlineCoreProtocolError(
      "Inline core returned an invalid media resource",
      "invalid-message",
    )
  }

  private async loadCachedMedia(
    key: string,
    signal?: AbortSignal,
  ): Promise<InlineMediaResource | undefined> {
    const response = await this.requestMedia(
      (requestId) => ({
        type: "inlineCoreLoadCachedMedia",
        requestId,
        key,
      }),
      signal,
    )
    const media = response.media
    if (media == null) return undefined
    if (media.kind === "blob" && media.blob instanceof Blob) {
      return media
    }
    throw new InlineCoreProtocolError(
      "Inline core returned an invalid cached media resource",
      "invalid-message",
    )
  }

  private async requestMedia(
    message: (
      requestId: string,
    ) => Extract<
      InlineCoreClientMessage,
      {
        type:
          | "inlineCoreLoadMedia"
          | "inlineCoreLoadCachedMedia"
      }
    >,
    signal?: AbortSignal,
  ) {
    if (signal?.aborted) {
      throw new InlineCoreProtocolError(
        "Inline media request was cancelled",
        "request-cancelled",
      )
    }
    await this.start()
    if (signal?.aborted) {
      throw new InlineCoreProtocolError(
        "Inline media request was cancelled",
        "request-cancelled",
      )
    }
    const requestId = this.nextRequestId()
    const handleAbort = () => {
      const error = new InlineCoreProtocolError(
        "Inline media request was cancelled",
        "request-cancelled",
      )
      this.cancelRequest(requestId, error)
      if (!this.attached) return
      try {
        this.port.postMessage({
          type: "inlineCoreCancelMedia",
          requestId,
        })
      } catch {
        // The request is already rejected locally. Worker/port failure is
        // handled by the owner error and request timeout paths.
      }
    }
    signal?.addEventListener("abort", handleAbort, { once: true })
    try {
      return await this.request(message(requestId))
    } finally {
      signal?.removeEventListener("abort", handleAbort)
    }
  }

  private cancelRequest(requestId: string, error: Error) {
    const continuation = this.requests.get(requestId)
    if (!continuation) return
    clearTimeout(continuation.timeout)
    this.requests.delete(requestId)
    continuation.reject(error)
  }

  private request(
    message: Extract<
      InlineCoreClientMessage,
      { requestId: string }
    >,
    timeoutMs = this.requestTimeoutMs,
  ) {
    return new Promise<RequestResult>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.requests.delete(message.requestId)
        reject(
          new InlineCoreProtocolError(
            "Inline core request timed out",
            "request-timeout",
          ),
        )
      }, timeoutMs)
      this.requests.set(message.requestId, {
        resolve,
        reject,
        timeout,
      })
      try {
        this.port.postMessage(message)
      } catch (error) {
        clearTimeout(timeout)
        this.requests.delete(message.requestId)
        reject(
          error instanceof Error
            ? error
            : new InlineCoreProtocolError(
                "Inline core request could not be sent",
              ),
        )
      }
    })
  }

  private receive(rawMessage: unknown) {
    if (this.ownerFailure) return
    if (
      typeof rawMessage !== "object" ||
      rawMessage == null ||
      !("type" in rawMessage)
    ) {
      return
    }
    const message = rawMessage as InlineCoreHostMessage
    switch (message.type) {
      case "inlineCoreHandshakeAccepted":
        if (
          message.protocolVersion !== INLINE_CORE_PROTOCOL_VERSION ||
          message.accountId !== this.accountId
        ) {
          this.failConnect(
            new InlineCoreProtocolError(
              "Inline core worker acknowledged an incompatible session",
              "incompatible-owner",
            ),
            "protocol-incompatible",
          )
          return
        }
        this.handshakeAccepted = true
        this.updateSnapshot({
          ...this.snapshot,
          phase: "openingStorage",
          blockingFailure: undefined,
        })
        if (this.bootTimer) clearTimeout(this.bootTimer)
        this.bootTimer = setTimeout(() => {
          this.bootTimer = null
          this.failConnect(
            new InlineCoreProtocolError(
              "Inline core owner did not become ready",
              "owner-ready-timeout",
            ),
            "owner-unresponsive",
          )
        }, this.ownerReadyTimeoutMs)
        return
      case "inlineCoreReady":
        if (
          !isCompatibleInlineCore(message) ||
          message.identity.accountId !== this.accountId
        ) {
          this.failConnect(
            new InlineCoreProtocolError(
              "Inline core worker identity is incompatible",
              "incompatible-owner",
            ),
            "protocol-incompatible",
          )
          return
        }
        this.db.applyProjection(message.projection)
        this.handshakeAccepted = false
        this.attached = true
        this.updateSnapshot(message.snapshot)
        this.startHeartbeat()
        this.completeConnect()
        return
      case "inlineCoreSnapshot":
        this.updateSnapshot(message.snapshot)
        return
      case "inlineCoreProjection":
        this.db.applyProjection(message.projection)
        return
      case "inlineCoreChanges":
        this.db.applyChanges(message.batch)
        return
      case "inlineCoreResult": {
        const continuation = this.requests.get(
          message.requestId,
        )
        if (!continuation) return
        clearTimeout(continuation.timeout)
        this.requests.delete(message.requestId)
        continuation.resolve(message)
        return
      }
      case "inlineCoreAuthInvalidated":
        this.auth.logout()
        return
      case "inlineCoreHeartbeatAck":
        if (
          message.ownerId !== this.snapshot.ownerId ||
          message.nonce !== this.pendingHeartbeatNonce
        ) {
          return
        }
        this.clearHeartbeatTimeout()
        return
      case "inlineCoreError": {
        const error = new InlineCoreProtocolError(
          message.message,
          message.code,
        )
        if (message.requestId) {
          const continuation = this.requests.get(
            message.requestId,
          )
          if (continuation) {
            clearTimeout(continuation.timeout)
            this.requests.delete(message.requestId)
            continuation.reject(error)
          }
          if (message.code === "not-attached") {
            this.reattach()
          }
          return
        }
        if (
          message.code === "not-attached" &&
          !this.detached
        ) {
          this.reattach()
          return
        }
        this.failConnect(
          error,
          message.code === "owner-failed"
            ? "owner-unavailable"
            : "protocol-incompatible",
        )
      }
    }
  }

  private async sendLifecycle() {
    if (!this.attached) return
    await this.request({
      type: "inlineCoreLifecycle",
      requestId: this.nextRequestId(),
      lifecycle: this.lifecycle,
    })
  }

  private updateSnapshot(snapshot: InlineCoreSnapshot) {
    if (
      snapshot.accountId !== this.accountId ||
      snapshot.protocolVersion !==
        INLINE_CORE_PROTOCOL_VERSION
    ) {
      return
    }
    const previousConnectionState = this.connectionState
    this.snapshot = snapshot
    this.connectionState = snapshot.connectionState
    for (const listener of this.snapshotListeners) listener()
    if (previousConnectionState !== this.connectionState) {
      for (const listener of this.connectionListeners) {
        listener(this.connectionState)
      }
    }
  }

  private completeConnect() {
    if (this.bootTimer) {
      clearTimeout(this.bootTimer)
      this.bootTimer = null
    }
    const resolve = this.resolveConnect
    this.resolveConnect = null
    this.rejectConnect = null
    this.connectPromise = null
    resolve?.()
  }

  private failConnect(
    error: Error,
    failureCode: InlineCoreBlockingFailure["code"] =
      "owner-unavailable",
  ) {
    this.handshakeAccepted = false
    if (this.bootTimer) {
      clearTimeout(this.bootTimer)
      this.bootTimer = null
    }
    this.rejectConnect?.(error)
    this.resolveConnect = null
    this.rejectConnect = null
    this.connectPromise = null
    if (!this.detached) {
      this.updateSnapshot({
        ...this.snapshot,
        phase: "error",
        connectionState: "idle",
        blockingFailure: {
          code: failureCode,
          message: error.message,
          recoveryAction: "reload",
        },
      })
    }
  }

  private rejectRequests(error: Error) {
    for (const continuation of this.requests.values()) {
      clearTimeout(continuation.timeout)
      continuation.reject(error)
    }
    this.requests.clear()
  }

  private abandonConnect() {
    if (this.bootTimer) {
      clearTimeout(this.bootTimer)
      this.bootTimer = null
    }
    this.resolveConnect = null
    this.rejectConnect = null
    this.connectPromise = null
  }

  private abandonRequests() {
    for (const continuation of this.requests.values()) {
      clearTimeout(continuation.timeout)
    }
    this.requests.clear()
  }

  private nextRequestId() {
    return makeId("inline-core-request")
  }

  private startHeartbeat() {
    if (this.heartbeatTimer) return
    this.heartbeatTimer = setInterval(() => {
      this.probeOwner()
    }, this.heartbeatIntervalMs)
    this.probeOwner()
  }

  private probeOwner() {
    if (
      !this.attached ||
      !this.lifecycle.visible ||
      this.pendingHeartbeatNonce
    ) {
      return
    }
    const nonce = makeId("inline-core-heartbeat")
    this.pendingHeartbeatNonce = nonce
    try {
      this.port.postMessage({
        type: "inlineCoreHeartbeat",
        nonce,
      })
    } catch (error) {
      this.clearHeartbeatTimeout()
      this.failOwner(
        error instanceof Error
          ? `Inline core worker failed: ${error.message}`
          : "Inline core worker failed",
      )
      return
    }
    this.heartbeatTimeout = setTimeout(() => {
      if (this.pendingHeartbeatNonce !== nonce) return
      this.clearHeartbeatTimeout()
      this.failOwner(
        "Inline core worker stopped responding",
        "owner-unresponsive",
      )
    }, this.heartbeatTimeoutMs)
  }

  private reattach() {
    if (this.ownerFailure) return
    this.attached = false
    this.stopHeartbeat()
    void this.start().catch(() => undefined)
  }

  private stopHeartbeat() {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = null
    }
    this.clearHeartbeatTimeout()
  }

  private clearHeartbeatTimeout() {
    if (this.heartbeatTimeout) {
      clearTimeout(this.heartbeatTimeout)
      this.heartbeatTimeout = null
    }
    this.pendingHeartbeatNonce = null
  }

  private failOwner(
    message: string,
    failureCode: InlineCoreBlockingFailure["code"] =
      "owner-unavailable",
  ) {
    if (this.ownerFailure || this.detached) return
    this.ownerFailure = new InlineCoreProtocolError(
      message,
      "owner-failed",
    )
    this.attached = false
    this.stopHeartbeat()
    this.rejectRequests(this.ownerFailure)
    this.failConnect(this.ownerFailure, failureCode)
  }
}

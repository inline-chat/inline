import type { ConnectionInit, RpcError, RpcResult } from "@inline-chat/protocol/core"
import {
  parseInlineId,
  protocolId,
  type ChatID,
  type MessageID,
  type UserID,
} from "@inline/ids"
import { Log, type LogLevel } from "@inline/log"
import { getRealtimeUrl } from "@inline/config"
import { AsyncChannel } from "../utils/async-channel"
import { Emitter } from "../utils/emitter"
import type { AuthSession, AuthStore } from "../auth"
import {
  DatabaseCommitError,
  type Db,
} from "../database"
import {
  DbObjectKind,
  messageKey,
  type Message,
  type PendingTransaction,
} from "../database/models"
import { DbQueryPlanType } from "../database/types"
import { ProtocolClient } from "./client/protocol-client"
import { ConnectionManager } from "./connection/connection-manager"
import type { ClientEvent, RealtimeConnectionState } from "./types"
import { WebSocketTransport } from "./transport/ws-transport"
import { TransportError, type Transport } from "./transport/transport"
import type {
  LocalTransaction,
  Transaction,
  TransactionBlocker,
  TransactionBlockerState,
  TransactionError,
  TransactionWrapper,
} from "./transactions"
import {
  createChat,
  decodePendingTransaction,
  SendMessageTransaction,
  Transactions,
  TransactionErrors,
  TransactionFailure,
} from "./transactions"
import { TransactionId as TransactionIdFactory } from "./transactions/transaction-id"
import {
  applyUpdates,
  DeferredMessageUpdateOwner,
  deferredMessageKeysFromRpcResult,
  deferredMessageKeysFromUpdates,
} from "./updates"
import { SyncEngine } from "./sync"
import {
  failedMessageResend,
  stageFailedMessageResend,
} from "./message-resend"
import type {
  CreateThreadInput,
  MessageActionAnswer,
} from "./realtime-service"
import { ReservedChatIDPool } from "./reserved-chat-id-pool"

export type RealtimeClientOptions = {
  auth: AuthStore
  db: Db
  url?: string
  logLevel?: LogLevel
  logger?: Log
  transport?: Transport
  buildNumber?: number
  layer?: number
  /** Enabled by default. Pass false only for isolated transaction tests/tools. */
  sync?: SyncEngine | false
  connection?: {
    authTimeoutMs?: number
    backgroundGraceMs?: number
    wakeProbeTimeoutMs?: number
    backoffDelayMs?: (attempt: number) => number
  }
}

type TransactionContinuation = {
  resolve: (value: RpcResult["result"] | undefined) => void
  reject: (error: Error) => void
}

type PendingResultSettlement = {
  wrapper: TransactionWrapper
  rpcResult: RpcResult["result"]
  attempt: number
  timer: ReturnType<typeof setTimeout> | null
}

type MessageActionAnswerWaiter = {
  resolve: (answer: MessageActionAnswer | undefined) => void
  timer: ReturnType<typeof setTimeout>
}

type RealtimeLifecycleState =
  | "starting"
  | "running"
  | "stopping"
  | "stopped"

const isLocalTransaction = (transaction: Transaction): transaction is LocalTransaction =>
  (transaction as LocalTransaction).localOnly === true

const validateCreateThreadInput = (
  value: CreateThreadInput,
): CreateThreadInput => {
  const input = value as Partial<CreateThreadInput>
  const participants = Array.isArray(input.participants)
    ? input.participants.map((participant) =>
        parseInlineId<"user">(participant, { positive: true }),
      )
    : []
  const spaceId =
    input.spaceId == null
      ? undefined
      : parseInlineId<"space">(input.spaceId, {
          positive: true,
        })
  if (
    typeof input.isPublic !== "boolean" ||
    participants.length === 0 ||
    participants.length > 100 ||
    participants.some((participant) => participant == null) ||
    (input.title != null && typeof input.title !== "string") ||
    (input.emoji != null && typeof input.emoji !== "string") ||
    (input.spaceId != null && spaceId == null)
  ) {
    throw new TypeError("Invalid Inline create-thread input")
  }
  return {
    isPublic: input.isPublic,
    participants: participants as UserID[],
    ...(typeof input.title === "string"
      ? { title: input.title }
      : {}),
    ...(typeof input.emoji === "string"
      ? { emoji: input.emoji }
      : {}),
    ...(spaceId ? { spaceId } : {}),
  }
}

export class RealtimeClient {
  readonly transport: Transport
  readonly client: ProtocolClient
  readonly connection: ConnectionManager
  readonly auth: AuthStore
  readonly db: Db
  readonly sync?: SyncEngine

  connectionState: RealtimeConnectionState = "idle"

  private readonly connectionInfo: { buildNumber?: number; layer?: number }
  private readonly log: Log
  private readonly stateChannel = new AsyncChannel<RealtimeConnectionState>()
  private readonly stateEmitter = new Emitter<RealtimeConnectionState>()
  private readonly transactions: Transactions
  private readonly deferredMessageUpdates: DeferredMessageUpdateOwner
  private readonly reservedChatIDPool: ReservedChatIDPool
  private readonly transactionContinuations = new Map<string, TransactionContinuation>()
  private readonly pendingResultSettlements = new Map<
    string,
    PendingResultSettlement
  >()
  private flushTask: Promise<void> | null = null
  private listenersStarted = false
  private lifecycleState: RealtimeLifecycleState = "stopped"
  private lifecycleGeneration = 0
  private startTask: Promise<void> | null = null
  private stopTask: Promise<void> | null = null
  private readonly activeClientEventTasks = new Set<Promise<void>>()
  private readonly activeOwnerTasks = new Set<Promise<unknown>>()
  private readonly messageActionAnswers = new Map<bigint, MessageActionAnswer>()
  private readonly messageActionAnswerWaiters = new Map<
    bigint,
    Set<MessageActionAnswerWaiter>
  >()
  private restoredTransactions = false
  private lastPendingTransactionCreatedAt = 0

  constructor(options: RealtimeClientOptions) {
    const baseLogger = options.logger ?? new Log("RealtimeV2", options.logLevel)
    this.log = baseLogger

    this.auth = options.auth
    this.db = options.db
    this.deferredMessageUpdates = new DeferredMessageUpdateOwner(
      this.db,
    )

    const resolvedLayer = options.layer ?? 2
    this.connectionInfo = {
      ...(options.buildNumber != null ? { buildNumber: options.buildNumber } : {}),
      layer: resolvedLayer,
    }

    const url = options.url ?? getRealtimeUrl()

    this.transport =
      options.transport ??
      new WebSocketTransport({
        url,
        logLevel: options.logLevel,
        logger: baseLogger.withScope("WebSocketTransport"),
      })

    this.client = new ProtocolClient({
      transport: this.transport,
      getConnectionInit: () => this.getConnectionInit(),
      logLevel: options.logLevel,
      logger: baseLogger.withScope("ProtocolClient"),
    })
    this.connection = new ConnectionManager({
      session: this.client,
      logger: baseLogger.withScope("ConnectionManager"),
      authTimeoutMs: options.connection?.authTimeoutMs,
      backgroundGraceMs:
        options.connection?.backgroundGraceMs,
      wakeProbeTimeoutMs:
        options.connection?.wakeProbeTimeoutMs,
      backoffDelayMs: options.connection?.backoffDelayMs,
    })

    this.sync =
      options.sync === false
        ? undefined
        : options.sync ??
          new SyncEngine({
            db: this.db,
            client: this.client,
            logger: baseLogger.withScope("Sync"),
          })
    this.transactions = new Transactions(baseLogger.withScope("Transactions"))
    this.reservedChatIDPool = new ReservedChatIDPool(
      this.db,
      this,
      baseLogger.withScope("ReservedChatIDPool"),
    )

    this.startListeners()
  }

  async start(): Promise<void> {
    if (this.stopTask) {
      await this.stopTask
      return await this.start()
    }
    if (this.lifecycleState === "running") return
    if (this.startTask) return await this.startTask

    const generation = ++this.lifecycleGeneration
    this.lifecycleState = "starting"
    const task = this.performStart(generation)
    this.startTask = task
    try {
      await task
    } finally {
      if (this.startTask === task) this.startTask = null
    }
  }

  async stop() {
    if (this.stopTask) return await this.stopTask
    if (
      this.lifecycleState === "stopped" &&
      this.activeClientEventTasks.size === 0 &&
      this.activeOwnerTasks.size === 0 &&
      !this.flushTask
    ) {
      return
    }

    const startTask = this.startTask
    this.lifecycleState = "stopping"
    this.lifecycleGeneration += 1
    this.updateConnectionState("idle")
    this.sync?.connectionInterrupted()
    const task = this.performStop(startTask)
    this.stopTask = task
    try {
      await task
    } finally {
      if (this.stopTask === task) this.stopTask = null
    }
  }

  private async performStart(generation: number) {
    try {
      await this.drainTrackedTasks(this.activeOwnerTasks)
      if (!this.isCurrentLifecycle(generation, "starting")) return
      if (!this.getConnectionInit()) {
        throw new Error("not-authorized")
      }
      await this.restorePendingTransactions()
      if (!this.isCurrentLifecycle(generation, "starting")) return
      this.updateConnectionState("connecting")
      await this.connection.setAuthAvailable(true)
      if (!this.isCurrentLifecycle(generation, "starting")) return
      await this.connection.start()
      if (!this.isCurrentLifecycle(generation, "starting")) return
      this.lifecycleState = "running"
    } catch (error) {
      if (this.isCurrentLifecycle(generation, "starting")) {
        this.lifecycleState = "stopped"
        this.updateConnectionState("idle")
        await this.connection.stop().catch(() => undefined)
      }
      throw error
    }
  }

  private async performStop(startTask: Promise<void> | null) {
    const errors: unknown[] = []
    try {
      await this.connection.stop()
    } catch (error) {
      errors.push(error)
    }
    if (startTask) {
      try {
        await startTask
      } catch (error) {
        errors.push(error)
      }
    }
    try {
      await this.connection.stop()
    } catch (error) {
      errors.push(error)
    }
    await this.drainTrackedTasks(this.activeClientEventTasks)
    if (this.flushTask) await Promise.allSettled([this.flushTask])
    try {
      await this.sync?.stop()
    } catch (error) {
      errors.push(error)
    }

    for (const [id, settlement] of this.pendingResultSettlements) {
      if (settlement.timer) clearTimeout(settlement.timer)
      const continuation = this.transactionContinuations.get(id)
      continuation?.reject(
        new TransactionFailure(TransactionErrors.stopped()),
      )
      this.transactionContinuations.delete(id)
    }
    this.pendingResultSettlements.clear()
    for (const waiters of this.messageActionAnswerWaiters.values()) {
      for (const waiter of waiters) {
        clearTimeout(waiter.timer)
        waiter.resolve(undefined)
      }
    }
    this.messageActionAnswerWaiters.clear()
    this.messageActionAnswers.clear()

    const pending = this.transactions.reset()
    for (const wrapper of pending) {
      if (!wrapper.transaction.persistence) {
        try {
          await wrapper.transaction.cancelled?.(this.db, this.auth)
        } catch (error) {
          errors.push(error)
        }
      }
      const continuation = this.transactionContinuations.get(wrapper.id)
      if (continuation) {
        continuation.reject(new TransactionFailure(TransactionErrors.stopped()))
        this.transactionContinuations.delete(wrapper.id)
      }
    }
    this.restoredTransactions = false
    await this.drainTrackedTasks(this.activeOwnerTasks)
    this.lifecycleState = "stopped"
    if (errors.length === 1) throw errors[0]
    if (errors.length > 1) {
      throw new AggregateError(
        errors,
        "Inline realtime could not stop cleanly",
      )
    }
  }

  async startSession(session: AuthSession) {
    await this.auth.login(session)
    await this.start()
  }

  async stopSession() {
    await this.stop()
    await this.connection.setAuthAvailable(false)
    await this.auth.logout()
  }

  private getConnectionInit(): ConnectionInit | null {
    const token = this.auth.getToken()
    if (!token) return null

    return {
      token,
      ...(this.connectionInfo.buildNumber != null ? { buildNumber: this.connectionInfo.buildNumber } : {}),
      ...(this.connectionInfo.layer != null ? { layer: this.connectionInfo.layer } : {}),
    }
  }

  connectionStates() {
    return this.stateChannel
  }

  onConnectionState(listener: (state: RealtimeConnectionState) => void) {
    return this.stateEmitter.subscribe(listener)
  }

  waitForMessageActionAnswer(
    interactionId: bigint,
    options: { timeoutMs?: number } = {},
  ): Promise<MessageActionAnswer | undefined> {
    if (interactionId <= 0n || !this.isRealtimeActive()) {
      return Promise.resolve(undefined)
    }
    const cached = this.messageActionAnswers.get(interactionId)
    if (cached) {
      this.messageActionAnswers.delete(interactionId)
      return Promise.resolve(cached)
    }
    return new Promise((resolve) => {
      const waiters =
        this.messageActionAnswerWaiters.get(interactionId) ?? new Set()
      const waiter: MessageActionAnswerWaiter = {
        resolve,
        timer: setTimeout(() => {
          waiters.delete(waiter)
          if (waiters.size === 0) {
            this.messageActionAnswerWaiters.delete(interactionId)
          }
          resolve(undefined)
        }, options.timeoutMs ?? 15_000),
      }
      waiters.add(waiter)
      this.messageActionAnswerWaiters.set(interactionId, waiters)
    })
  }

  execute(transaction: Transaction): Promise<RpcResult["result"] | undefined> {
    return this.executeTransaction(transaction)
  }

  async mutateAccepted(transaction: Transaction): Promise<void> {
    if (!transaction.persistence) {
      throw new TypeError(
        "Only durable Inline mutations expose local acceptance",
      )
    }
    let accepted = false
    let resolveAcceptance!: () => void
    let rejectAcceptance!: (error: unknown) => void
    const acceptance = new Promise<void>((resolve, reject) => {
      resolveAcceptance = resolve
      rejectAcceptance = reject
    })
    const result = this.executeTransaction(transaction, () => {
      accepted = true
      resolveAcceptance()
    })
    void result.catch((error: unknown) => {
      if (!accepted) {
        rejectAcceptance(error)
      } else if (
        error instanceof TransactionFailure &&
        error.kind === "stopped"
      ) {
        this.log.debug("transaction.accepted.deferred", {
          method: transaction.method,
        })
      } else {
        this.log.warn("transaction.accepted.failed", {
          method: transaction.method,
          error,
        })
      }
    })
    return acceptance
  }

  async createThread(input: CreateThreadInput): Promise<ChatID> {
    const validatedInput = validateCreateThreadInput(input)
    const context = {
      title: validatedInput.title,
      emoji: validatedInput.emoji,
      isPublic: validatedInput.isPublic,
      spaceId: validatedInput.spaceId,
      participants: validatedInput.participants.map((userId) => ({
        userId: protocolId(userId),
      })),
    }

    try {
      const consumption = await this.reservedChatIDPool.consumeCached(
        async (reservation) => {
          await this.mutateAccepted(
            createChat({
              ...context,
              reservedChatId: reservation.chatId,
            }),
          )
          return reservation.chatId
        },
      )
      if (consumption.consumed) return consumption.value
    } catch (error) {
      this.log.warn("transaction.create.reservation_fallback", {
        error,
      })
    }

    const result = await this.mutate(createChat(context))
    if (
      !result ||
      result.oneofKind !== "createChat" ||
      !result.createChat.chat ||
      !result.createChat.dialog ||
      result.createChat.dialog.chatId !== result.createChat.chat.id
    ) {
      throw new TransactionFailure(TransactionErrors.invalid())
    }
    const exactChatId = parseInlineId<"chat">(
      result.createChat.chat.id,
      { positive: true },
    )
    if (exactChatId == null) {
      throw new TransactionFailure(TransactionErrors.invalid())
    }
    return exactChatId
  }

  private async executeTransaction(
    transaction: Transaction,
    onAccepted?: () => void,
  ): Promise<RpcResult["result"] | undefined> {
    const lifecycleGeneration = this.lifecycleGeneration
    if (!this.acceptsTransactions()) {
      throw new TransactionFailure(TransactionErrors.stopped())
    }
    if (
      transaction.kind.kind === "mutation" &&
      transaction.kind.config.transient === true &&
      this.connectionState !== "connected"
    ) {
      throw new TransactionFailure(
        TransactionErrors.notConnected(),
      )
    }
    transaction.beforeExecute?.(this.db)

    if (isLocalTransaction(transaction)) {
      this.db.batch(() => {
        transaction.optimistic?.(this.db, this.auth)
      })
      await transaction.runLocal({ auth: this.auth, db: this.db, stopRealtime: () => this.stop() })
      return undefined
    }

    const transactionId = TransactionIdFactory.generate()
    const transactionCreatedAt = Math.max(
      Date.now(),
      this.lastPendingTransactionCreatedAt + 1,
    )
    this.lastPendingTransactionCreatedAt = transactionCreatedAt
    try {
      if (transaction.persistence || transaction.optimistic) {
        await this.db.commit(() => {
          transaction.prepare?.(this.db, this.auth)
          if (transaction.persistence) {
            this.db.insert({
              kind: DbObjectKind.PendingTransaction,
              id: transactionId,
              type: transaction.persistence.type,
              replayPolicy:
                transaction.persistence.replayPolicy,
              context: transaction.context,
              createdAt: transactionCreatedAt,
              status: "pending",
            })
          }
          transaction.optimistic?.(this.db, this.auth)
        })
      }
    } catch (error) {
      await transaction.failed?.(
        TransactionErrors.invalid(),
        this.db,
        this.auth,
      )
      throw new TransactionFailure(TransactionErrors.invalid(), {
        cause: error,
      })
    }
    this.prepareAcceptedMessageWindow(transaction)
    onAccepted?.()

    if (
      lifecycleGeneration !== this.lifecycleGeneration ||
      !this.acceptsTransactions()
    ) {
      throw new TransactionFailure(TransactionErrors.stopped())
    }

    return await new Promise<RpcResult["result"] | undefined>((resolve, reject) => {
      this.transactionContinuations.set(transactionId, { resolve, reject })
      this.transactions.enqueue(transaction, { id: transactionId })
      this.log.trace("transaction.queued", {
        method: transaction.method,
      })
      if (this.connectionState === "connected") {
        void this.flushQueue()
      }
    })
  }

  async query(transaction: Transaction): Promise<RpcResult["result"] | undefined> {
    return await this.execute(transaction)
  }

  async mutate(transaction: Transaction): Promise<RpcResult["result"] | undefined> {
    return await this.execute(transaction)
  }

  async resendMessage(
    chatId: ChatID,
    messageId: MessageID,
  ): Promise<RpcResult["result"] | undefined> {
    const exactChatId = parseInlineId<"chat">(chatId, {
      positive: true,
    })
    const exactMessageId = parseInlineId<"message">(messageId)
    if (
      exactChatId == null ||
      exactMessageId == null ||
      BigInt(exactMessageId) === 0n
    ) {
      throw new TypeError("Invalid Inline failed-message identity")
    }
    if (!this.isRealtimeActive()) {
      throw new Error("Inline realtime must be started before resending")
    }
    const resend = failedMessageResend(
      this.db,
      exactChatId,
      exactMessageId,
    )
    if (this.transactionContinuations.has(resend.outbox.id)) {
      throw new Error("Inline failed message is already being resent")
    }

    await this.db.commit(() => {
      stageFailedMessageResend(this.db, resend)
    })
    this.prepareAcceptedMessageWindow(resend.transaction)
    if (!this.isRealtimeActive()) {
      throw new TransactionFailure(TransactionErrors.stopped())
    }

    return await new Promise<RpcResult["result"] | undefined>((resolve, reject) => {
      this.transactionContinuations.set(resend.outbox.id, {
        resolve,
        reject,
      })
      this.transactions.enqueue(resend.transaction, {
        id: resend.outbox.id,
        date: new Date(resend.outbox.createdAt),
      })
      if (this.connectionState === "connected") {
        void this.flushQueue()
      }
    })
  }

  async cancelPendingMessage(
    chatId: ChatID,
    messageId: MessageID,
  ): Promise<boolean> {
    if (!this.acceptsTransactions()) {
      throw new TransactionFailure(TransactionErrors.stopped())
    }
    const exactChatId = parseInlineId<"chat">(chatId, { positive: true })
    const exactMessageId = parseInlineId<"message">(messageId)
    if (
      exactChatId == null ||
      exactMessageId == null ||
      BigInt(exactMessageId) === 0n
    ) {
      throw new TypeError("Invalid Inline pending-message identity")
    }

    const queued = this.transactions.holdQueued(
      ({ transaction }) =>
        transaction instanceof SendMessageTransaction &&
        transaction.context.chatId === exactChatId &&
        transaction.context.temporaryMessageId === exactMessageId,
    )
    if (queued.length > 1) {
      this.transactions.releaseHeldQueued(
        queued.map((wrapper) => wrapper.id),
      )
      throw new Error("Inline pending message has ambiguous durable sends")
    }
    if (queued.length === 1) {
      const wrapper = queued[0]!
      try {
        await this.db.commit(() => {
          this.removePendingTransaction(wrapper.id, wrapper.transaction)
          this.removeLocalMessageAndRepairChat(exactChatId, exactMessageId)
        })
      } catch (error) {
        this.transactions.releaseHeldQueued([wrapper.id])
        throw error
      }
      this.transactions.removeHeldQueued(wrapper.id)
      const continuation = this.transactionContinuations.get(wrapper.id)
      this.transactionContinuations.delete(wrapper.id)
      continuation?.reject(
        new TransactionFailure(TransactionErrors.stopped()),
      )
      return true
    }

    let failed: ReturnType<typeof failedMessageResend>
    try {
      failed = failedMessageResend(
        this.db,
        exactChatId,
        exactMessageId,
      )
    } catch {
      return false
    }
    await this.db.commit(() => {
      this.db.delete(
        this.db.ref(DbObjectKind.PendingTransaction, failed.outbox.id),
      )
      this.removeLocalMessageAndRepairChat(exactChatId, exactMessageId)
    })
    return true
  }

  private removeLocalMessageAndRepairChat(
    chatId: ChatID,
    messageId: MessageID,
  ) {
    this.db.delete(
      this.db.ref(
        DbObjectKind.Message,
        messageKey(chatId, messageId),
      ),
    )
    const chatRef = this.db.ref(DbObjectKind.Chat, chatId)
    const chat = this.db.get(chatRef)
    if (chat?.lastMsgId !== messageId) return
    const previous = this.db
      .queryCollection<
        DbObjectKind.Message,
        Message,
        DbQueryPlanType.Objects
      >(
        DbQueryPlanType.Objects,
        DbObjectKind.Message,
        (message) =>
          message.chatId === chatId && message.messageId !== messageId,
      )
      .sort((left, right) => {
        const date = (left.date ?? 0) - (right.date ?? 0)
        return date || (BigInt(left.messageId) < BigInt(right.messageId) ? -1 : 1)
      })
      .at(-1)
    this.db.update({
      ...chat,
      lastMsgId: previous?.messageId,
      date: previous?.date,
    })
  }

  cancelTransactions(predicate: (transaction: Transaction) => boolean) {
    const cancelled = this.transactions.cancel((wrapper) => predicate(wrapper.transaction))
    for (const wrapper of cancelled) {
      void wrapper.transaction.cancelled?.(this.db, this.auth)
      const continuation = this.transactionContinuations.get(wrapper.id)
      if (continuation) {
        continuation.reject(new TransactionFailure(TransactionErrors.stopped()))
        this.transactionContinuations.delete(wrapper.id)
      }
    }
  }

  private async startListeners() {
    if (this.listenersStarted) return
    this.listenersStarted = true

    ;(async () => {
      for await (const event of this.connection.events) {
        if (!this.isRealtimeActive()) continue
        const task = this.handleClientEvent(event)
        this.activeClientEventTasks.add(task)
        try {
          await task
        } finally {
          this.activeClientEventTasks.delete(task)
        }
      }
    })().catch((error) => {
      this.log.error("realtime.listener.crashed", { error })
    })

    ;(async () => {
      for await (const _ of this.transactions.queueStream) {
        if (
          !this.isRealtimeActive() ||
          this.connectionState !== "connected"
        ) {
          continue
        }
        await this.flushQueue()
      }
    })().catch((error) => {
      this.log.error("transaction.loop.crashed", { error })
    })
  }

  private async handleClientEvent(event: ClientEvent) {
    switch (event.type) {
      case "open":
        this.log.trace("realtime.connection.open")
        this.updateConnectionState("connected")
        await this.failAmbiguousTransactions(this.transactions.requeueAll())
        await this.flushQueue()
        if (this.sync) await this.sync.connectionOpened()
        if (this.sync) {
          this.trackOwnerTask(
            this.reservedChatIDPool.refillIfNeeded(),
            (error) => {
              this.log.warn("reserved_chat_ids.refill.failed", {
                error,
              })
            },
          )
        }
        break

      case "connecting":
        this.sync?.connectionInterrupted()
        this.updateConnectionState("connecting")
        break

      case "ack":
        this.transactions.ack(event.msgId)
        break

      case "rpcResult":
        await this.completeTransaction(event.msgId, event.rpcResult)
        break

      case "rpcError":
        await this.failTransaction(event.msgId, event.rpcError)
        break

      case "updates":
        this.log.trace("realtime.updates.received", {
          count: event.updates.updates.length,
        })
        this.captureMessageActionAnswers(event.updates.updates)
        if (this.sync) {
          await this.sync.processPush(event.updates.updates)
        } else {
          await this.db.hydrateDeferredUpdatesForMessageKeys(
            deferredMessageKeysFromUpdates(
              event.updates.updates,
            ),
          )
          applyUpdates(this.db, event.updates.updates)
        }
        break

      case "authInvalidated":
        this.log.warn("realtime.auth.invalidated", {
          reason: event.reason,
        })
        void this.stopSession().catch((error: unknown) => {
          this.log.error("realtime.auth.stop_failed", { error })
        })
        break

      default:
        break
    }
  }

  private flushQueue(): Promise<void> {
    if (this.flushTask) return this.flushTask

    const task = this.drainQueue()
    this.flushTask = task
    void task.then(
      () => {
        if (this.flushTask === task) this.flushTask = null
      },
      () => {
        if (this.flushTask === task) this.flushTask = null
      },
    )

    return task
  }

  private async drainQueue() {
    while (
      this.isRealtimeActive() &&
      this.connectionState === "connected"
    ) {
      const dequeued = this.transactions.dequeue((blocker) =>
        this.resolveTransactionBlocker(blocker),
      )
      if (!dequeued) return
      if (dequeued.state === "failed") {
        await this.failBlockedTransaction(dequeued.wrapper)
        continue
      }
      const outcome = await this.runTransaction(dequeued.wrapper)
      if (outcome === "paused") return
    }
  }

  private resolveTransactionBlocker(
    blocker: TransactionBlocker,
  ): TransactionBlockerState {
    switch (blocker.type) {
      case "chatCreated": {
        const chat = this.db.get(
          this.db.ref(DbObjectKind.Chat, blocker.chatId),
        )
        if (!chat) return "failed"
        if (chat.createState === "pending") return "blocked"
        if (chat.createState === "failed") return "failed"
        return "satisfied"
      }
    }
  }

  private async failBlockedTransaction(wrapper: {
    id: string
    transaction: Transaction
  }) {
    const error = TransactionErrors.dependencyFailed()
    try {
      await this.commitTransactionFailure(
        wrapper.id,
        wrapper.transaction,
        error,
      )
    } catch (failureError) {
      this.log.error("transaction.blocked.persist_failed", {
        method: wrapper.transaction.method,
        error: failureError,
      })
    }
    const continuation = this.transactionContinuations.get(wrapper.id)
    this.transactionContinuations.delete(wrapper.id)
    continuation?.reject(new TransactionFailure(error))
  }

  private async runTransaction(
    wrapper: { id: string; transaction: Transaction },
  ): Promise<"processed" | "paused"> {
    const transaction = wrapper.transaction
    try {
      const msgId = await this.client.sendRpc(transaction.method, transaction.input(transaction.context))
      this.transactions.running(wrapper.id, msgId)
      return "processed"
    } catch (error) {
      if (!(error instanceof TransportError)) {
        this.log.error("transaction.send.invalid", {
          method: transaction.method,
          error,
        })
        await this.failUnsendableTransaction(wrapper)
        return "processed"
      }

      this.log.warn("transaction.send.paused", {
        method: transaction.method,
        error,
      })
      this.transactions.requeue(wrapper.id)

      if (!this.isRealtimeActive()) return "paused"

      this.updateConnectionState("connecting")
      try {
        await this.connection.reconnectAfterFailure(
          "transaction-send-failed",
        )
      } catch (reconnectError) {
        this.log.error("realtime.reconnect.failed", {
          error: reconnectError,
        })
      }
      return "paused"
    }
  }

  private async failUnsendableTransaction(wrapper: { id: string; transaction: Transaction }) {
    const [failedWrapper] = this.transactions.cancel((candidate) => candidate.id === wrapper.id)
    if (!failedWrapper) return

    const txError = TransactionErrors.invalid()
    try {
      await this.commitTransactionFailure(
        wrapper.id,
        failedWrapper.transaction,
        txError,
      )
    } catch (error) {
      this.log.error("transaction.unsendable.persist_failed", {
        method: failedWrapper.transaction.method,
        error,
      })
    }

    const continuation = this.transactionContinuations.get(wrapper.id)
    this.transactionContinuations.delete(wrapper.id)
    continuation?.reject(new TransactionFailure(txError))
  }

  private async failAmbiguousTransactions(
    wrappers: Array<{ id: string; transaction: Transaction }>,
  ) {
    const error = TransactionErrors.ambiguousResult()
    for (const wrapper of wrappers) {
      this.log.warn("transaction.result.ambiguous", {
        method: wrapper.transaction.method,
      })
      try {
        await this.commitTransactionFailure(
          wrapper.id,
          wrapper.transaction,
          error,
        )
      } catch (failureError) {
        this.log.error("transaction.ambiguous.persist_failed", {
          method: wrapper.transaction.method,
          error: failureError,
        })
      }
      const continuation = this.transactionContinuations.get(wrapper.id)
      this.transactionContinuations.delete(wrapper.id)
      continuation?.reject(new TransactionFailure(error))
    }
  }

  private async completeTransaction(msgId: bigint, rpcResult: RpcResult["result"]) {
    const wrapper = this.transactions.complete(msgId)
    if (!wrapper) return

    await this.settleTransactionResult(wrapper, rpcResult)
  }

  private async settleTransactionResult(
    wrapper: TransactionWrapper,
    rpcResult: RpcResult["result"],
  ) {

    const transaction = wrapper.transaction
    const continuation = this.transactionContinuations.get(wrapper.id)

    try {
      await this.db.hydrateDeferredUpdatesForMessageKeys(
        deferredMessageKeysFromRpcResult(rpcResult),
      )
      await this.db.commit(() => {
        transaction.apply(rpcResult, this.db)
        this.removePendingTransaction(
          wrapper.id,
          transaction,
        )
      })
      try {
        transaction.afterCommit?.(rpcResult, this.db)
      } catch (error) {
        this.log.error("transaction.after_commit.failed", {
          method: transaction.method,
          error,
        })
      }
      this.transactions.satisfy(
        transaction.satisfiedBlockersOnSuccess ?? [],
      )
      this.clearPendingResultSettlement(wrapper.id)
      this.transactionContinuations.delete(wrapper.id)
      continuation?.resolve(rpcResult)
      await this.flushQueue()
    } catch (error) {
      if (
        error instanceof DatabaseCommitError ||
        error instanceof AggregateError
      ) {
        this.scheduleResultSettlement(wrapper, rpcResult)
        return
      }
      this.log.error("transaction.apply.failed", {
        method: transaction.method,
        error,
      })
      const txError = TransactionErrors.invalid()
      this.clearPendingResultSettlement(wrapper.id)
      this.transactionContinuations.delete(wrapper.id)
      try {
        await this.commitTransactionFailure(
          wrapper.id,
          transaction,
          txError,
        )
      } catch (failureError) {
        this.log.error("transaction.invalid.persist_failed", {
          method: transaction.method,
          error: failureError,
        })
      }
      continuation?.reject(new TransactionFailure(txError))
      await this.flushQueue()
    }
  }

  private scheduleResultSettlement(
    wrapper: TransactionWrapper,
    rpcResult: RpcResult["result"],
  ) {
    const previous = this.pendingResultSettlements.get(wrapper.id)
    if (previous?.timer) return
    const attempt = (previous?.attempt ?? 0) + 1
    const delayMs = Math.min(5_000, 50 * 2 ** (attempt - 1))
    const settlement: PendingResultSettlement = {
      wrapper,
      rpcResult,
      attempt,
      timer: null,
    }
    settlement.timer = setTimeout(() => {
      settlement.timer = null
      if (!this.isRealtimeActive()) return
      const task = this.settleTransactionResult(
        settlement.wrapper,
        settlement.rpcResult,
      )
      this.activeClientEventTasks.add(task)
      void task.finally(() => {
        this.activeClientEventTasks.delete(task)
      })
    }, delayMs)
    this.pendingResultSettlements.set(wrapper.id, settlement)
    if (attempt <= 3 || attempt % 12 === 0) {
      this.log.warn("transaction.result.persist_retry", {
        method: wrapper.transaction.method,
        attempt,
        delayMs,
      })
    }
  }

  private clearPendingResultSettlement(id: string) {
    const settlement = this.pendingResultSettlements.get(id)
    if (settlement?.timer) clearTimeout(settlement.timer)
    this.pendingResultSettlements.delete(id)
  }

  private async failTransaction(msgId: bigint, rpcError: RpcError) {
    const wrapper = this.transactions.complete(msgId)
    if (!wrapper) return

    const transaction = wrapper.transaction
    const continuation = this.transactionContinuations.get(wrapper.id)
    this.transactionContinuations.delete(wrapper.id)

    const error = TransactionErrors.rpcError(rpcError.code, rpcError.message)
    try {
      await this.commitTransactionFailure(
        wrapper.id,
        transaction,
        error,
      )
    } catch (failureError) {
      this.log.error("transaction.rpc_failure.persist_failed", {
        method: transaction.method,
        error: failureError,
      })
    }
    continuation?.reject(new TransactionFailure(error))
    await this.flushQueue()
  }

  private async restorePendingTransactions() {
    if (this.restoredTransactions) return
    await this.db.hydrateKinds([DbObjectKind.PendingTransaction])
    const records = this.db
      .queryCollection<
        DbObjectKind.PendingTransaction,
        PendingTransaction,
        DbQueryPlanType.Objects
      >(
        DbQueryPlanType.Objects,
        DbObjectKind.PendingTransaction,
        (record) => record.status === "pending",
      )
      .sort((left, right) => left.createdAt - right.createdAt)
    this.lastPendingTransactionCreatedAt = Math.max(
      this.lastPendingTransactionCreatedAt,
      ...records.map((record) => record.createdAt),
    )

    const restored: Array<{
      record: PendingTransaction
      transaction: Transaction
    }> = []
    try {
      for (const record of records) {
        const transaction = decodePendingTransaction(record)
        if (!transaction) {
          this.log.warn("outbox.restore.unsupported", {
            type: record.type,
          })
          await this.db.commit(() => {
            this.db.replace({ ...record, status: "failed" })
          })
          continue
        }
        await this.db.commit(() => {
          transaction.optimistic?.(this.db, this.auth)
        })
        restored.push({ record, transaction })
      }
      for (const { record, transaction } of restored) {
        this.prepareAcceptedMessageWindow(transaction)
        this.transactions.enqueue(transaction, {
          id: record.id,
          date: new Date(record.createdAt),
        })
      }
      this.restoredTransactions = true
    } catch (error) {
      this.restoredTransactions = false
      this.log.error("outbox.restore.failed", { error })
      throw error
    }
  }

  private removePendingTransaction(
    id: string,
    transaction: Transaction,
  ) {
    if (!transaction.persistence) return
    this.db.delete(this.db.ref(DbObjectKind.PendingTransaction, id))
  }

  private markPendingTransactionFailedInRecipe(
    id: string,
    transaction: Transaction,
  ) {
    if (!transaction.persistence) return
    const ref = this.db.ref(DbObjectKind.PendingTransaction, id)
    const record = this.db.get(ref)
    if (!record) return
    this.db.replace({ ...record, status: "failed" })
  }

  private commitTransactionFailure(
    id: string,
    transaction: Transaction,
    error: TransactionError,
  ) {
    return this.db.commit(() => {
      transaction.failed?.(error, this.db, this.auth)
      this.markPendingTransactionFailedInRecipe(id, transaction)
    })
  }

  private prepareAcceptedMessageWindow(
    transaction: Transaction,
  ) {
    const intent = transaction.messageWindowIntent
    if (!intent || intent.type !== "promote-latest") return
    this.trackOwnerTask(
      this.db.promoteResidentMessageWindowToLatest(intent.chatId),
      (error) => {
        this.log.warn("message_window.promote_latest.failed", {
          method: transaction.method,
          error,
        })
      },
    )
  }

  private captureMessageActionAnswers(
    updates: Parameters<typeof applyUpdates>[1],
  ) {
    for (const update of updates) {
      if (update.update.oneofKind !== "messageActionAnswered") {
        continue
      }
      const answer: MessageActionAnswer = {
        interactionId:
          update.update.messageActionAnswered.interactionId,
        ui: update.update.messageActionAnswered.ui,
      }
      if (answer.interactionId <= 0n) continue
      const waiters = this.messageActionAnswerWaiters.get(
        answer.interactionId,
      )
      if (!waiters || waiters.size === 0) {
        this.messageActionAnswers.set(answer.interactionId, answer)
        while (this.messageActionAnswers.size > 64) {
          const oldest = this.messageActionAnswers.keys().next().value
          if (oldest == null) break
          this.messageActionAnswers.delete(oldest)
        }
        continue
      }
      this.messageActionAnswerWaiters.delete(answer.interactionId)
      for (const waiter of waiters) {
        clearTimeout(waiter.timer)
        waiter.resolve(answer)
      }
    }
  }

  private acceptsTransactions() {
    return (
      this.lifecycleState === "starting" ||
      this.lifecycleState === "running"
    )
  }

  private isRealtimeActive() {
    return (
      this.lifecycleState === "starting" ||
      this.lifecycleState === "running"
    )
  }

  private isCurrentLifecycle(
    generation: number,
    state: RealtimeLifecycleState,
  ) {
    return (
      generation === this.lifecycleGeneration &&
      this.lifecycleState === state
    )
  }

  private trackOwnerTask(
    task: Promise<unknown>,
    onError: (error: unknown) => void,
  ) {
    this.activeOwnerTasks.add(task)
    void task.then(
      () => {
        this.activeOwnerTasks.delete(task)
      },
      (error: unknown) => {
        this.activeOwnerTasks.delete(task)
        onError(error)
      },
    )
  }

  private async drainTrackedTasks<T>(
    tasks: Set<Promise<T>>,
  ) {
    while (tasks.size > 0) {
      await Promise.allSettled(Array.from(tasks))
    }
  }

  private updateConnectionState(state: RealtimeConnectionState) {
    if (this.connectionState === state) return
    this.connectionState = state
    void this.stateChannel.send(state)
    this.stateEmitter.emit(state)
  }
}

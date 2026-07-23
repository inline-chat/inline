import type { ConnectionInit, RpcError, RpcResult } from "@inline-chat/protocol/core"
import {
  parseInlineId,
  protocolId,
  type ChatID,
  type MessageID,
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
  TransactionWrapper,
} from "./transactions"
import {
  createChat,
  decodePendingTransaction,
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
import type { CreateThreadInput } from "./realtime-service"
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

const isLocalTransaction = (transaction: Transaction): transaction is LocalTransaction =>
  (transaction as LocalTransaction).localOnly === true

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
  private started = false
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
    this.reservedChatIDPool = new ReservedChatIDPool(this.db, this)

    this.startListeners()
  }

  async start() {
    if (this.started) return
    if (!this.getConnectionInit()) {
      throw new Error("not-authorized")
    }

    await this.restorePendingTransactions()
    this.started = true
    this.updateConnectionState("connecting")
    await this.connection.setAuthAvailable(true)
    await this.connection.start()
  }

  async stop() {
    if (!this.started) return
    this.started = false
    this.sync?.connectionInterrupted()
    await this.connection.stop()
    await this.sync?.stop()
    this.updateConnectionState("idle")

    for (const [id, settlement] of this.pendingResultSettlements) {
      if (settlement.timer) clearTimeout(settlement.timer)
      const continuation = this.transactionContinuations.get(id)
      continuation?.reject(
        new TransactionFailure(TransactionErrors.stopped()),
      )
      this.transactionContinuations.delete(id)
    }
    this.pendingResultSettlements.clear()

    const pending = this.transactions.reset()
    for (const wrapper of pending) {
      if (!wrapper.transaction.persistence) {
        await wrapper.transaction.cancelled?.(this.db, this.auth)
      }
      const continuation = this.transactionContinuations.get(wrapper.id)
      if (continuation) {
        continuation.reject(new TransactionFailure(TransactionErrors.stopped()))
        this.transactionContinuations.delete(wrapper.id)
      }
    }
    this.restoredTransactions = false
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
      } else {
        this.log.warn(
          "Locally accepted transaction later failed",
          transaction.describe?.() ?? transaction.method,
          error,
        )
      }
    })
    return acceptance
  }

  async createThread(input: CreateThreadInput): Promise<ChatID> {
    const context = {
      title: input.title,
      emoji: input.emoji,
      isPublic: input.isPublic,
      spaceId: input.spaceId,
      participants: input.participants.map((userId) => ({
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
      this.log.warn(
        "Reserved chat ID create was not locally accepted; falling back to direct create",
        error,
      )
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
    const startedWhenExecutionBegan = this.started

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

    if (startedWhenExecutionBegan && !this.started) {
      throw new TransactionFailure(TransactionErrors.stopped())
    }

    return await new Promise<RpcResult["result"] | undefined>((resolve, reject) => {
      this.transactionContinuations.set(transactionId, { resolve, reject })
      this.transactions.enqueue(transaction, { id: transactionId })
      this.log.trace("Queued transaction", transaction.describe?.() ?? transaction.method)
      onAccepted?.()
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
    if (!this.started) {
      throw new Error("Inline realtime must be started before resending")
    }
    const resend = failedMessageResend(this.db, chatId, messageId)
    if (this.transactionContinuations.has(resend.outbox.id)) {
      throw new Error("Inline failed message is already being resent")
    }

    await this.db.commit(() => {
      stageFailedMessageResend(this.db, resend)
    })
    if (!this.started) {
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
        await this.handleClientEvent(event)
      }
    })().catch((error) => {
      this.log.error("Realtime listener crashed", error)
    })

    ;(async () => {
      for await (const _ of this.transactions.queueStream) {
        if (this.connectionState !== "connected") continue
        await this.flushQueue()
      }
    })().catch((error) => {
      this.log.error("Transaction loop crashed", error)
    })
  }

  private async handleClientEvent(event: ClientEvent) {
    switch (event.type) {
      case "open":
        this.log.trace("Protocol client open")
        this.updateConnectionState("connected")
        await this.failAmbiguousTransactions(this.transactions.requeueAll())
        await this.flushQueue()
        void this.sync?.connectionOpened().catch((error: unknown) => {
          this.log.warn("Initial sync could not start", error)
        })
        if (this.sync) {
          void this.reservedChatIDPool
            .refillIfNeeded()
            .catch((error: unknown) => {
              this.log.warn("Reserved chat IDs could not be refilled", error)
            })
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
        this.log.trace("Updates received", event.updates)
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
        this.log.warn(
          "Realtime credentials were invalidated",
          event.reason,
        )
        await this.stopSession()
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
    while (this.connectionState === "connected") {
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
    await wrapper.transaction.failed?.(error, this.db, this.auth)
    await this.markPendingTransactionFailed(
      wrapper.id,
      wrapper.transaction,
    )
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
        this.log.error("Transaction could not be encoded or sent", error)
        await this.failUnsendableTransaction(wrapper)
        return "processed"
      }

      this.log.warn("Transaction send paused until the connection recovers", error)
      this.transactions.requeue(wrapper.id)

      if (!this.started) return "paused"

      this.updateConnectionState("connecting")
      try {
        await this.connection.reconnectAfterFailure(
          "transaction-send-failed",
        )
      } catch (reconnectError) {
        this.log.error("Failed to restart realtime transport", reconnectError)
      }
      return "paused"
    }
  }

  private async failUnsendableTransaction(wrapper: { id: string; transaction: Transaction }) {
    const [failedWrapper] = this.transactions.cancel((candidate) => candidate.id === wrapper.id)
    if (!failedWrapper) return

    const txError = TransactionErrors.invalid()
    await this.markPendingTransactionFailed(wrapper.id, wrapper.transaction)
    try {
      await failedWrapper.transaction.failed?.(txError, this.db, this.auth)
    } catch (error) {
      this.log.error("Failed to apply transaction failure state", error)
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
      this.log.warn(
        "Transaction result was ambiguous after reconnect; refusing unsafe replay",
        wrapper.transaction.describe?.() ?? wrapper.transaction.method,
      )
      try {
        await wrapper.transaction.failed?.(error, this.db, this.auth)
        await this.markPendingTransactionFailed(
          wrapper.id,
          wrapper.transaction,
        )
      } catch (failureError) {
        this.log.error(
          "Failed to apply ambiguous transaction failure state",
          failureError,
        )
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
      this.log.error("Failed to apply transaction", error)
      const txError = TransactionErrors.invalid()
      this.clearPendingResultSettlement(wrapper.id)
      this.transactionContinuations.delete(wrapper.id)
      await this.markPendingTransactionFailed(wrapper.id, transaction)
      await transaction.failed?.(txError, this.db, this.auth)
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
      if (!this.started) return
      void this.settleTransactionResult(
        settlement.wrapper,
        settlement.rpcResult,
      )
    }, delayMs)
    this.pendingResultSettlements.set(wrapper.id, settlement)
    if (attempt <= 3 || attempt % 12 === 0) {
      this.log.warn(
        `Retrying local transaction result persistence in ${delayMs}ms (attempt ${attempt})`,
        wrapper.transaction.describe?.() ?? wrapper.transaction.method,
      )
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
    await transaction.failed?.(error, this.db, this.auth)
    await this.markPendingTransactionFailed(wrapper.id, transaction)
    continuation?.reject(new TransactionFailure(error))
    await this.flushQueue()
  }

  private async restorePendingTransactions() {
    if (this.restoredTransactions) return
    this.restoredTransactions = true
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

    for (const record of records) {
      const transaction = decodePendingTransaction(record)
      if (!transaction) {
        this.log.warn(
          `Pending transaction ${record.id} has an unknown type ${record.type}`,
        )
        continue
      }
      try {
        await transaction.optimistic?.(this.db, this.auth)
        await this.db.flushPersistence()
        this.transactions.enqueue(transaction, {
          id: record.id,
          date: new Date(record.createdAt),
        })
      } catch (error) {
        this.log.warn(
          `Pending transaction ${record.id} could not be restored`,
          error,
        )
      }
    }
  }

  private removePendingTransaction(
    id: string,
    transaction: Transaction,
  ) {
    if (!transaction.persistence) return
    this.db.delete(this.db.ref(DbObjectKind.PendingTransaction, id))
  }

  private async markPendingTransactionFailed(
    id: string,
    transaction: Transaction,
  ) {
    if (!transaction.persistence) return
    const ref = this.db.ref(DbObjectKind.PendingTransaction, id)
    const record = this.db.get(ref)
    if (!record) return
    this.db.replace({ ...record, status: "failed" })
    try {
      await this.db.flushPersistence()
    } catch (error) {
      this.log.warn(`Could not mark outbox item ${id} failed`, error)
    }
  }

  private updateConnectionState(state: RealtimeConnectionState) {
    if (this.connectionState === state) return
    this.connectionState = state
    void this.stateChannel.send(state)
    this.stateEmitter.emit(state)
  }
}

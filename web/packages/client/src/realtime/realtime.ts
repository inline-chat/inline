import type { ConnectionInit, RpcError, RpcResult } from "@in/protocol/core"
import { Log, type LogLevel } from "@inline/log"
import { getRealtimeUrl } from "@inline/config"
import { AsyncChannel } from "../utils/async-channel"
import { Emitter } from "../utils/emitter"
import { auth as defaultAuth, type AuthSession, type AuthStore } from "../auth"
import { db as defaultDb, type Db } from "../database"
import { ProtocolClient } from "./client/protocol-client"
import type { ClientEvent, RealtimeConnectionState } from "./types"
import { WebSocketTransport } from "./transport/ws-transport"
import type { Transport } from "./transport/transport"
import type { LocalTransaction, Transaction } from "./transactions"
import { Transactions, TransactionErrors, TransactionFailure } from "./transactions"
import { applyUpdates } from "./updates"

export type RealtimeClientOptions = {
  url?: string
  logLevel?: LogLevel
  logger?: Log
  transport?: Transport
  auth?: AuthStore
  db?: Db
  buildNumber?: number
  layer?: number
}

type TransactionContinuation = {
  resolve: (value: RpcResult["result"] | undefined) => void
  reject: (error: Error) => void
}

const isLocalTransaction = (transaction: Transaction): transaction is LocalTransaction =>
  (transaction as LocalTransaction).localOnly === true

export class RealtimeClient {
  readonly transport: Transport
  readonly client: ProtocolClient
  readonly auth: AuthStore
  readonly db: Db

  connectionState: RealtimeConnectionState = "idle"

  private readonly connectionInfo: { buildNumber?: number; layer?: number }
  private readonly log: Log
  private readonly stateChannel = new AsyncChannel<RealtimeConnectionState>()
  private readonly stateEmitter = new Emitter<RealtimeConnectionState>()
  private readonly transactions: Transactions
  private readonly transactionContinuations = new Map<string, TransactionContinuation>()
  private listenersStarted = false
  private started = false

  constructor(options: RealtimeClientOptions = {}) {
    const baseLogger = options.logger ?? new Log("RealtimeV2", options.logLevel)
    this.log = baseLogger

    this.auth = options.auth ?? defaultAuth
    this.db = options.db ?? defaultDb

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

    this.transactions = new Transactions(baseLogger.withScope("Transactions"))

    this.startListeners()
  }

  async start() {
    if (this.started) return
    if (!this.getConnectionInit()) {
      throw new Error("not-authorized")
    }

    this.started = true
    this.updateConnectionState("connecting")
    await this.client.startTransport()
  }

  async stop() {
    if (!this.started) return
    this.started = false
    await this.client.stopTransport()
    this.updateConnectionState("idle")

    const pending = this.transactions.reset()
    for (const wrapper of pending) {
      await wrapper.transaction.cancelled?.(this.db, this.auth)
      const continuation = this.transactionContinuations.get(wrapper.id)
      if (continuation) {
        continuation.reject(new TransactionFailure(TransactionErrors.stopped()))
        this.transactionContinuations.delete(wrapper.id)
      }
    }
  }

  async startSession(session: AuthSession) {
    this.auth.login(session)
    await this.start()
  }

  async stopSession() {
    await this.stop()
    this.auth.logout()
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

  async execute(transaction: Transaction): Promise<RpcResult["result"] | undefined> {
    await transaction.optimistic?.(this.db, this.auth)

    if (isLocalTransaction(transaction)) {
      await transaction.runLocal({ auth: this.auth, db: this.db, stopRealtime: () => this.stop() })
      return undefined
    }

    const transactionId = this.transactions.enqueue(transaction)
    this.log.trace("Queued transaction", transaction.describe?.() ?? transaction.method)

    return await new Promise<RpcResult["result"] | undefined>((resolve, reject) => {
      this.transactionContinuations.set(transactionId, { resolve, reject })
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
      for await (const event of this.client.events) {
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
        this.transactions.requeueAll()
        await this.flushQueue()
        break

      case "connecting":
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
        applyUpdates(this.db, event.updates.updates)
        break

      default:
        break
    }
  }

  private async flushQueue() {
    if (this.connectionState !== "connected") return
    while (this.connectionState === "connected") {
      const wrapper = this.transactions.dequeue()
      if (!wrapper) return
      await this.runTransaction(wrapper)
    }
  }

  private async runTransaction(wrapper: { id: string; transaction: Transaction }) {
    const transaction = wrapper.transaction
    try {
      const msgId = await this.client.sendRpc(transaction.method, transaction.input(transaction.context))
      this.transactions.running(wrapper.id, msgId)
    } catch (error) {
      this.log.error("Failed to send transaction", error)
      this.transactions.requeue(wrapper.id)
    }
  }

  private async completeTransaction(msgId: bigint, rpcResult: RpcResult["result"]) {
    const wrapper = this.transactions.complete(msgId)
    if (!wrapper) return

    const transaction = wrapper.transaction
    const continuation = this.transactionContinuations.get(wrapper.id)
    this.transactionContinuations.delete(wrapper.id)

    try {
      await transaction.apply(rpcResult, this.db)
      continuation?.resolve(rpcResult)
    } catch (error) {
      this.log.error("Failed to apply transaction", error)
      const txError = TransactionErrors.invalid()
      await transaction.failed?.(txError, this.db, this.auth)
      continuation?.reject(new TransactionFailure(txError))
    }
  }

  private async failTransaction(msgId: bigint, rpcError: RpcError) {
    const wrapper = this.transactions.complete(msgId)
    if (!wrapper) return

    const transaction = wrapper.transaction
    const continuation = this.transactionContinuations.get(wrapper.id)
    this.transactionContinuations.delete(wrapper.id)

    const error = TransactionErrors.rpcError(rpcError.code, rpcError.message)
    await transaction.failed?.(error, this.db, this.auth)
    continuation?.reject(new TransactionFailure(error))
  }

  private updateConnectionState(state: RealtimeConnectionState) {
    if (this.connectionState === state) return
    this.connectionState = state
    void this.stateChannel.send(state)
    this.stateEmitter.emit(state)
  }
}

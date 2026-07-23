import { Log } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import type {
  Transaction,
  TransactionBlocker,
  TransactionBlockerState,
} from "./transaction"
import type { TransactionId } from "./transaction-id"
import { TransactionId as TransactionIdFactory } from "./transaction-id"
import type { TransactionWrapper } from "./transaction-wrapper"
import { wrapTransaction } from "./transaction-wrapper"

export class Transactions {
  readonly queueStream = new AsyncChannel<void>()

  private queue = new Map<TransactionId, TransactionWrapper>()
  private inFlight = new Map<TransactionId, TransactionWrapper>()
  private sent = new Map<TransactionId, TransactionWrapper>()
  private rpcMap = new Map<bigint, TransactionId>()
  private satisfiedBlockers = new Set<string>()

  private readonly log: Log

  constructor(log?: Log) {
    this.log = log ?? new Log("RealtimeV2.Transactions")
  }

  enqueue(
    transaction: Transaction,
    options: { id?: TransactionId; date?: Date } = {},
  ): TransactionId {
    const id = options.id ?? TransactionIdFactory.generate()
    const wrapper = wrapTransaction(transaction, id, options.date)
    this.queue.set(id, wrapper)
    void this.queueStream.send(undefined)
    return id
  }

  dequeue(
    resolveBlocker: (
      blocker: TransactionBlocker,
    ) => TransactionBlockerState = () => "blocked",
  ):
    | { state: "ready"; wrapper: TransactionWrapper }
    | { state: "failed"; wrapper: TransactionWrapper }
    | null {
    for (const wrapper of this.queue.values()) {
      const state = this.blockerState(
        wrapper.transaction,
        resolveBlocker,
      )
      if (state === "blocked") continue
      this.queue.delete(wrapper.id)
      if (state === "failed") {
        return { state, wrapper }
      }
      this.inFlight.set(wrapper.id, wrapper)
      return { state: "ready", wrapper }
    }
    return null
  }

  satisfy(blockers: readonly TransactionBlocker[]) {
    let changed = false
    for (const blocker of blockers) {
      const key = this.blockerKey(blocker)
      if (this.satisfiedBlockers.has(key)) continue
      this.satisfiedBlockers.add(key)
      changed = true
    }
    if (changed) void this.queueStream.send(undefined)
  }

  running(transactionId: TransactionId, rpcMsgId: bigint) {
    const wrapper = this.inFlight.get(transactionId)
    if (!wrapper) {
      this.log.trace("Transaction missing when marking running", transactionId)
      return
    }
    this.rpcMap.set(rpcMsgId, transactionId)
  }

  ack(rpcMsgId: bigint) {
    const transactionId = this.rpcMap.get(rpcMsgId)
    if (!transactionId) return
    const wrapper = this.inFlight.get(transactionId)
    if (!wrapper) return
    this.inFlight.delete(transactionId)
    this.sent.set(transactionId, wrapper)
  }

  complete(rpcMsgId: bigint): TransactionWrapper | null {
    const transactionId = this.rpcMap.get(rpcMsgId)
    if (!transactionId) return null

    const wrapper = this.sent.get(transactionId) ?? this.inFlight.get(transactionId)
    this.sent.delete(transactionId)
    this.inFlight.delete(transactionId)
    this.rpcMap.delete(rpcMsgId)

    return wrapper ?? null
  }

  requeue(transactionId: TransactionId) {
    const wrapper = this.inFlight.get(transactionId) ?? this.sent.get(transactionId)
    if (!wrapper) return
    this.inFlight.delete(transactionId)
    this.sent.delete(transactionId)
    this.queue.set(transactionId, wrapper)
    void this.queueStream.send(undefined)
  }

  /**
   * Requeue work after a new protocol session opens.
   *
   * Queued work was never handed to transport and is always safe to retain.
   * In-flight and ACKed work crossed an ambiguity boundary and is retried only
   * when its transaction contract explicitly allows it.
   */
  requeueAll(): TransactionWrapper[] {
    const dropped: TransactionWrapper[] = []
    const affectedIds = new Set<TransactionId>()

    for (const [id, wrapper] of this.inFlight) {
      affectedIds.add(id)
      if (this.shouldRetryAfterTransportLoss(wrapper.transaction)) {
        this.queue.set(id, wrapper)
      } else {
        dropped.push(wrapper)
      }
    }
    for (const [id, wrapper] of this.sent) {
      affectedIds.add(id)
      if (this.shouldRetryAfterAck(wrapper.transaction)) {
        this.queue.set(id, wrapper)
      } else {
        dropped.push(wrapper)
      }
    }
    this.inFlight.clear()
    this.sent.clear()
    if (affectedIds.size > 0) {
      for (const [rpcId, transactionId] of this.rpcMap) {
        if (affectedIds.has(transactionId)) {
          this.rpcMap.delete(rpcId)
        }
      }
    }
    if (this.queue.size > 0) {
      void this.queueStream.send(undefined)
    }
    return dropped
  }

  cancel(where: (wrapper: TransactionWrapper) => boolean): TransactionWrapper[] {
    const cancelled: TransactionWrapper[] = []
    const cancelledIds = new Set<TransactionId>()
    for (const [id, wrapper] of this.queue) {
      if (!where(wrapper)) continue
      cancelled.push(wrapper)
      cancelledIds.add(id)
      this.queue.delete(id)
    }
    for (const [id, wrapper] of this.inFlight) {
      if (!where(wrapper)) continue
      cancelled.push(wrapper)
      cancelledIds.add(id)
      this.inFlight.delete(id)
    }
    for (const [id, wrapper] of this.sent) {
      if (!where(wrapper)) continue
      cancelled.push(wrapper)
      cancelledIds.add(id)
      this.sent.delete(id)
    }
    if (cancelledIds.size > 0) {
      for (const [rpcId, transactionId] of this.rpcMap) {
        if (cancelledIds.has(transactionId)) {
          this.rpcMap.delete(rpcId)
        }
      }
    }
    return cancelled
  }

  reset(): TransactionWrapper[] {
    const wrappers = [...this.queue.values(), ...this.inFlight.values(), ...this.sent.values()]
    this.queue.clear()
    this.inFlight.clear()
    this.sent.clear()
    this.rpcMap.clear()
    this.satisfiedBlockers.clear()
    return wrappers
  }

  private shouldRetryAfterTransportLoss(transaction: Transaction) {
    if (transaction.kind.kind === "query") return true
    return transaction.kind.config.retryAfterTransportLoss === true
  }

  private blockerState(
    transaction: Transaction,
    resolveBlocker: (
      blocker: TransactionBlocker,
    ) => TransactionBlockerState,
  ): TransactionBlockerState {
    for (const blocker of transaction.blockers ?? []) {
      if (this.satisfiedBlockers.has(this.blockerKey(blocker))) {
        continue
      }
      const state = resolveBlocker(blocker)
      if (state === "satisfied") {
        this.satisfiedBlockers.add(this.blockerKey(blocker))
        continue
      }
      return state
    }
    return "satisfied"
  }

  private blockerKey(blocker: TransactionBlocker) {
    switch (blocker.type) {
      case "chatCreated":
        return `chatCreated:${blocker.chatId}`
    }
  }

  private shouldRetryAfterAck(transaction: Transaction) {
    if (transaction.kind.kind === "query") return true
    return transaction.kind.config.retryAfterAck === true
  }
}

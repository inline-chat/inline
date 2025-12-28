import { Log } from "@inline/log"
import { AsyncChannel } from "../../utils/async-channel"
import type { Transaction } from "./transaction"
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

  private readonly log: Log

  constructor(log?: Log) {
    this.log = log ?? new Log("RealtimeV2.Transactions")
  }

  enqueue(transaction: Transaction): TransactionId {
    const id = TransactionIdFactory.generate()
    const wrapper = wrapTransaction(transaction, id)
    this.queue.set(id, wrapper)
    void this.queueStream.send(undefined)
    return id
  }

  dequeue(): TransactionWrapper | null {
    const iterator = this.queue.values().next()
    if (iterator.done || !iterator.value) return null
    const wrapper = iterator.value
    this.queue.delete(wrapper.id)
    this.inFlight.set(wrapper.id, wrapper)
    return wrapper
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

  requeueAll() {
    for (const [id, wrapper] of this.inFlight) {
      this.queue.set(id, wrapper)
    }
    for (const [id, wrapper] of this.sent) {
      this.queue.set(id, wrapper)
    }
    this.inFlight.clear()
    this.sent.clear()
    this.rpcMap.clear()
    if (this.queue.size > 0) {
      void this.queueStream.send(undefined)
    }
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
    return wrappers
  }
}
